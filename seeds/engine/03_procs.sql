-- =============================================================================
-- guppi-platform v3.6.0 — Engine Seed 03: Procedures
-- TIER 1 (DEFAULT): proc shapes are ours and yours to re-author — EXCEPT the Tier 0
--   guarantee they enforce: CREATE_ARTIFACT is the single gated write path with
--   gap-free atomic ID allocation. Keep the chokepoint; restyle the rest. See COCO.md.
-- All CREATE OR REPLACE. Safe to re-run.
-- =============================================================================

-- =============================================================================
-- ADVANCE_STAGE — universal gate
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.ADVANCE_STAGE(
    P_ARTIFACT_ID VARCHAR, P_TARGET_STAGE VARCHAR, P_OVERRIDE_REASON VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
'
import json

def run(session, p_artifact_id, p_target_stage, p_override_reason):
    art = session.sql("SELECT TYPE, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[p_artifact_id]).collect()
    if not art:
        return json.dumps({"success": False, "error": f"Artifact not found: {p_artifact_id}"})
    current_type = art[0]["TYPE"]
    current_stage = art[0]["STAGE"]
    if current_stage == p_target_stage:
        return json.dumps({"success": False, "error": f"Already at stage: {p_target_stage}"})

    rules = session.sql(
        "SELECT RULE_ID, CONDITION_SQL, ENFORCEMENT, OVERRIDABLE, MESSAGE "
        "FROM GUPPIWHEEL.PUBLIC.RULES WHERE ENABLED = TRUE AND RULE_TYPE = ''stage_transition'' "
        "AND (APPLIES_TO_TYPE = ''ALL'' OR APPLIES_TO_TYPE = ?) "
        "AND (FROM_STAGE IS NULL OR FROM_STAGE = ?) "
        "AND (TO_STAGE IS NULL OR TO_STAGE = ?)",
        params=[current_type, current_stage, p_target_stage]
    ).collect()

    blocked = False
    blockers = []
    warnings = []
    overrides_used = []

    for rule in rules:
        rule_id = rule["RULE_ID"]
        condition = rule["CONDITION_SQL"]
        enforcement = rule["ENFORCEMENT"]
        overridable = rule["OVERRIDABLE"]
        message = rule["MESSAGE"]
        eval_sql = f"SELECT ({condition.replace('':artifact_id'', chr(39) + p_artifact_id + chr(39))}) AS PASSES"
        try:
            result = session.sql(eval_sql).collect()
            passes = result[0]["PASSES"] if result else False
        except Exception:
            passes = False
        if not passes:
            if enforcement == "block":
                if overridable and p_override_reason:
                    overrides_used.append({"rule": rule_id, "message": message, "reason": p_override_reason})
                    session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS, OVERRIDE_REASON) VALUES (?, ?, ''overridden'', ?)", params=[rule_id, p_artifact_id, p_override_reason]).collect()
                else:
                    blocked = True
                    blockers.append({"rule": rule_id, "message": message, "overridable": overridable})
            else:
                warnings.append({"rule": rule_id, "message": message})
                session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS) VALUES (?, ?, ''open'')", params=[rule_id, p_artifact_id]).collect()

    if blocked:
        return json.dumps({"success": False, "blocked": True, "blockers": blockers, "warnings": warnings})

    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = ?, UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?", params=[p_target_stage, p_artifact_id]).collect()
    return json.dumps({"success": True, "artifact_id": p_artifact_id, "from_stage": current_stage, "to_stage": p_target_stage, "warnings": warnings, "overrides_used": overrides_used})
';

-- =============================================================================
-- SUBMIT_INITIATIVE — single-write to ARTIFACTS
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  "TITLE" VARCHAR, "HYPOTHESIS" VARCHAR, "INSTRUCTIONS" VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER  -- RULE-028: procedure-mediated write; runs as owner so contributors need no direct ARTIFACTS DML
AS
BEGIN
    -- atomic allocation (RULE-029): increment first, then read, so concurrent calls cannot collide
    UPDATE GUPPIWHEEL.PUBLIC.ID_CONVENTIONS SET NEXT_SEQ = NEXT_SEQ + 1 WHERE ENTITY = 'INITIATIVE';
    LET next_id NUMBER := (SELECT NEXT_SEQ - 1 FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = 'INITIATIVE');
    LET init_id VARCHAR := 'INIT-' || :next_id::VARCHAR;
    INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS (ID, TYPE, STAGE, TITLE, OWNER, CONTENT, METADATA)
    SELECT :init_id, 'INITIATIVE', 'Initiate', :TITLE, CURRENT_USER(),
      PARSE_JSON(OBJECT_CONSTRUCT('hypothesis', :HYPOTHESIS, 'instructions', :INSTRUCTIONS)::VARCHAR),
      PARSE_JSON(OBJECT_CONSTRUCT('priority', 'P2', 'submitted_via', 'SUBMIT_INITIATIVE')::VARCHAR);
    RETURN 'Submitted: ' || :init_id || ' (Initiate). Rocky picks up within 5 minutes.';
END;

-- =============================================================================
-- ROCKY_EXECUTE — Rocky processes one queued initiative
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
'
import json
def run(session):
    rows = session.sql(
        "SELECT ID, TITLE, CONTENT:hypothesis::VARCHAR AS HYPOTHESIS, "
        "CONTENT:instructions::VARCHAR AS INSTRUCTIONS, METADATA:priority::VARCHAR AS PRIORITY "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = ''INITIATIVE'' AND STAGE = ''Initiate'' "
        "ORDER BY METADATA:priority NULLS LAST, CREATED_AT LIMIT 1"
    ).collect()
    if not rows:
        return "No queued initiatives."
    init = rows[0]
    init_id = init["ID"]
    title = init["TITLE"]
    hypothesis = init["HYPOTHESIS"] or "N/A"
    instructions = init["INSTRUCTIONS"] or ""
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = ''Research'', UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?", params=[init_id]).collect()
    prompt = (
        "Execute this research initiative autonomously.\\n\\n"
        "TITLE: " + title + "\\n"
        "HYPOTHESIS: " + hypothesis + "\\n\\n"
        "INSTRUCTIONS:\\n" + instructions + "\\n\\n"
        "Use web search to find current, specific information.\\n"
        "When complete provide:\\n"
        "1. VERDICT (supported / partially supported / refuted)\\n"
        "2. KEY FINDINGS (3-5 bullets with specifics)\\n"
        "3. RECOMMENDED NEXT STEPS\\n\\n"
        "IMPORTANT: Do NOT call submit_initiative. Provide research findings as text only."
    )
    message_payload = {"messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}]}
    message_json = json.dumps(message_payload)
    try:
        result = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)",
                             params=["GUPPIWHEEL.PUBLIC.ROCKY_AGENT", message_json]).collect()
        response = str(result[0][0]) if result else "No response from agent"
    except Exception as e:
        response = "Agent execution error: " + str(e)
    synthesis = response
    try:
        resp_json = json.loads(response)
        text_parts = []
        for item in resp_json.get("content", []):
            if isinstance(item, dict) and item.get("type") == "text":
                text_parts.append(item.get("text", ""))
        if text_parts:
            synthesis = "\\n".join(text_parts)
    except (json.JSONDecodeError, KeyError, TypeError):
        pass
    base_id = "RES-" + init_id.replace("INIT-", "") + "-ROCKY"
    res_id = base_id
    v = 2
    while session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[res_id]).collect()[0]["C"] > 0:
        res_id = base_id + "-V" + str(v)
        v += 1
    fw_content = json.dumps({"synthesis": synthesis[:12000], "executor": "rocky-cortex-agent-v3"})
    fw_meta = json.dumps({"model": "auto", "has_web_search": True})
    try:
        session.sql(
            "INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS (ID, TYPE, STAGE, TITLE, OWNER, PARENT_ID, CONTENT, METADATA) "
            "SELECT ?, ''RESEARCH'', ''Built'', ?, ''ROCKY'', ?, PARSE_JSON(?), PARSE_JSON(?)",
            params=[res_id, "Rocky Research: " + title[:200], init_id, fw_content, fw_meta]
        ).collect()
    except Exception as e:
        return "ERROR writing research: " + str(e)
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = ''Built'', UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?", params=[init_id]).collect()
    return "COMPLETE: " + init_id + " | " + title
';

-- =============================================================================
-- PUBLISH_ARTIFACT — register a launchable artifact (NARRATIVE/APP/MODEL/DASHBOARD)
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(
  P_TYPE VARCHAR,
  P_TITLE VARCHAR,
  P_DESCRIPTION VARCHAR,
  P_LAUNCH_SPEC VARIANT,
  P_PARENT_ID VARCHAR DEFAULT NULL,
  P_OWNER VARCHAR DEFAULT NULL,
  P_SENSITIVITY VARCHAR DEFAULT 'internal'
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER  -- RULE-028: procedure-mediated write; runs as owner so contributors need no direct ARTIFACTS DML
AS
'
import json
def run(session, p_type, p_title, p_description, p_launch_spec, p_parent_id, p_owner, p_sensitivity):
    art_type = (p_type or "").upper()
    if art_type not in ("NARRATIVE", "APP", "MODEL", "DASHBOARD"):
        return {"error": "TYPE must be NARRATIVE, APP, MODEL, or DASHBOARD", "got": p_type}
    if isinstance(p_launch_spec, str):
        try: launch = json.loads(p_launch_spec)
        except Exception: return {"error": "LAUNCH_SPEC is not valid JSON"}
    else:
        launch = dict(p_launch_spec) if p_launch_spec else {}
    app_type = launch.get("app_type")
    if not app_type:
        return {"error": "launch_spec.app_type required"}
    valid_types = {"static_html","pdf","spcs_service","external_url","cortex_agent","streamlit","streamlit_url","native_app"}
    if app_type not in valid_types:
        return {"error": "app_type must be one of " + ", ".join(sorted(valid_types)), "got": app_type}
    if app_type in ("static_html","pdf") and not launch.get("stage_path"):
        return {"error": app_type + " requires stage_path"}
    if app_type in ("spcs_service","external_url","streamlit_url") and not launch.get("url"):
        return {"error": app_type + " requires url"}
    if app_type in ("cortex_agent","streamlit","native_app") and not launch.get("identifier"):
        return {"error": app_type + " requires identifier"}

    type_to_seq = {"NARRATIVE": "NARRATIVE", "APP": "APP", "MODEL": "APP", "DASHBOARD": "APP"}
    seq_key = type_to_seq.get(art_type, art_type)
    cnt = session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = ?", params=[seq_key]).collect()
    if cnt[0]["C"] == 0:
        session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.ID_CONVENTIONS (ENTITY, NEXT_SEQ) VALUES (?, 1)", params=[seq_key]).collect()
    seq_rows = session.sql("SELECT NEXT_SEQ FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = ?", params=[seq_key]).collect()
    next_seq = seq_rows[0]["NEXT_SEQ"]
    prefix = "NAR" if art_type == "NARRATIVE" else "APP" if art_type == "APP" else "MOD" if art_type == "MODEL" else "DASH"
    artifact_id = prefix + "-" + str(next_seq)
    metadata = {"launch": launch, "sensitivity": p_sensitivity or "internal"}
    content = {"description": p_description or ""}
    owner = p_owner or session.sql("SELECT CURRENT_USER() AS U").collect()[0]["U"]
    session.sql(
        "INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS (ID, TYPE, STAGE, PARENT_ID, TITLE, OWNER, CONTENT, METADATA) "
        "SELECT ?, ?, ''Built'', ?, ?, ?, PARSE_JSON(?), PARSE_JSON(?)",
        params=[artifact_id, art_type, p_parent_id, p_title, owner, json.dumps(content), json.dumps(metadata)]
    ).collect()
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ID_CONVENTIONS SET NEXT_SEQ = ? WHERE ENTITY = ?", params=[next_seq + 1, seq_key]).collect()
    return {"artifact_id": artifact_id, "type": art_type, "launch": launch}
';

-- =============================================================================
-- GET_ARTIFACT_LAUNCH — resolve any launchable to URL/identifier
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(
  P_ARTIFACT_ID VARCHAR,
  P_TTL_SECONDS NUMBER DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
'
import json
import re
def _safe(s): return bool(re.match(r"^[A-Za-z0-9_./-]+$", s or ""))
def run(session, p_artifact_id, p_ttl_seconds):
    rows = session.sql("SELECT TYPE, METADATA FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[p_artifact_id]).collect()
    if not rows: return {"error": "artifact not found", "artifact_id": p_artifact_id}
    art_type = rows[0]["TYPE"]; md = rows[0]["METADATA"]
    if isinstance(md, str):
        try: md = json.loads(md)
        except Exception: md = {}
    md = md or {}
    launch = md.get("launch") or {}
    app_type = launch.get("app_type")
    if not app_type: return {"error": "no metadata.launch.app_type", "artifact_id": p_artifact_id}
    ttl = p_ttl_seconds if p_ttl_seconds else (launch.get("default_ttl_seconds") or 3600)
    if ttl > 86400: ttl = 86400
    result = {"artifact_id": p_artifact_id, "type": art_type, "app_type": app_type}
    result_type = None; result_value = None
    if app_type in ("static_html", "pdf"):
        sp = launch.get("stage_path") or ""
        if not sp.startswith("@"): return {"error": "stage_path must start with @"}
        s = sp[1:]; idx = s.find("/")
        if idx < 0: return {"error": "stage_path missing relative path"}
        stage_name = s[:idx]; rel = s[idx+1:]
        if not _safe(stage_name) or not _safe(rel): return {"error": "unsafe characters"}
        sql = "SELECT GET_PRESIGNED_URL(@" + stage_name + ", ''" + rel + "'', " + str(int(ttl)) + ") AS URL"
        ur = session.sql(sql).collect()
        result["url"] = ur[0]["URL"] if ur else None
        result["expires_in_seconds"] = ttl
        result_type = "presigned_url"; result_value = (result["url"] or "")[:1900]
    elif app_type in ("spcs_service", "external_url", "streamlit_url"):
        url = launch.get("url")
        if not url: return {"error": "url required for " + app_type}
        result["url"] = url; result_type = "url"; result_value = url[:1900]
    elif app_type in ("cortex_agent", "streamlit", "native_app"):
        ident = launch.get("identifier")
        if not ident: return {"error": "identifier required for " + app_type}
        result["identifier"] = ident
        if launch.get("snowsight_url"): result["snowsight_url"] = launch["snowsight_url"]
        result_type = "identifier"; result_value = ident[:1900]
    else:
        return {"error": "unknown app_type: " + str(app_type)}
    try:
        session.sql(
            "INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACT_LAUNCHES "
            "(ARTIFACT_ID, APP_TYPE, RESULT_TYPE, RESULT_VALUE, TTL_SECONDS, EXPIRES_AT) "
            "SELECT ?, ?, ?, ?, ?, DATEADD(second, ?, CURRENT_TIMESTAMP())",
            params=[p_artifact_id, app_type, result_type, result_value,
                    ttl if result_type == "presigned_url" else None,
                    ttl if result_type == "presigned_url" else 0]
        ).collect()
    except Exception:
        pass
    return result
';

-- =============================================================================
-- UPDATE_OWN_ARTIFACT — owner-scoped self-edit (RULE-028)
-- Lets a contributor edit ONLY their own draft. Cannot change STAGE, SUPERSEDED_BY,
-- TYPE, or OWNER. The only sanctioned in-place edit path once direct ARTIFACTS DML
-- is removed from contributors.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(
  P_ARTIFACT_ID VARCHAR, P_TITLE VARCHAR DEFAULT NULL, P_CONTENT VARIANT DEFAULT NULL, P_TAGS ARRAY DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
BEGIN
    LET owner_check VARCHAR := (SELECT OWNER FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_ARTIFACT_ID);
    IF (:owner_check IS NULL) THEN
        RETURN 'ERROR: artifact not found: ' || :P_ARTIFACT_ID;
    END IF;
    IF (:owner_check <> CURRENT_USER()) THEN
        RETURN 'DENIED: not your artifact (owner=' || :owner_check || ')';
    END IF;
    UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
       SET TITLE = COALESCE(:P_TITLE, TITLE),
           CONTENT = COALESCE(:P_CONTENT, CONTENT),
           TAGS = COALESCE(:P_TAGS, TAGS),
           UPDATED_AT = CURRENT_TIMESTAMP()
     WHERE ID = :P_ARTIFACT_ID;
    RETURN 'OK: updated ' || :P_ARTIFACT_ID;
END;

-- Grants
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ADVANCE_STAGE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(VARCHAR,VARCHAR,VARIANT,ARRAY) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(VARCHAR,NUMBER) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE() TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- CREATE_ARTIFACT — the single gated write path (RULE-029)
-- Registry-driven gap-free allocation from ID_CONVENTIONS; refuses existing IDs.
-- Dual mode: P_EXPLICIT_ID (descriptive, uniqueness-checked) or auto from (TYPE, PRODUCT).
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(
  P_TYPE VARCHAR,
  P_TITLE VARCHAR,
  P_PRODUCT VARCHAR DEFAULT NULL,
  P_CONTENT VARIANT DEFAULT NULL,
  P_PARENT_ID VARCHAR DEFAULT NULL,
  P_STAGE VARCHAR DEFAULT NULL,
  P_TAGS ARRAY DEFAULT NULL,
  P_EXPLICIT_ID VARCHAR DEFAULT NULL,
  P_METADATA VARIANT DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

VALID_TYPES = {"INITIATIVE","RESEARCH","STORY","EPIC","APP","MODEL","DASHBOARD",
               "NARRATIVE","DEFECT","INCIDENT","AUDIT","OPS_EVENT","OUTCOME","SKILL"}
VALID_STAGES = {"Initiate","Research","Building","Built","Narrated","Resolved",
                "ASPIRATIONAL","SELECTED","TRACKED","RESOLVED"}

def _count(session, sql, params):
    return session.sql(sql, params=params).collect()[0]["C"]

def _asobj(v, default):
    if v is None:
        return default
    if isinstance(v, (dict, list)):
        return v
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return default
    return default

def run(session, p_type, p_title, p_product, p_content, p_parent_id, p_stage, p_tags, p_explicit_id, p_metadata):
    t = (p_type or "").upper().strip()
    if t not in VALID_TYPES:
        return {"error": "invalid TYPE", "got": p_type, "allowed": sorted(VALID_TYPES)}
    if not p_title:
        return {"error": "TITLE required"}
    stage = (p_stage if isinstance(p_stage, str) else None) or "Initiate"
    if stage not in VALID_STAGES:
        return {"error": "invalid STAGE", "got": stage, "allowed": sorted(VALID_STAGES)}

    if isinstance(p_explicit_id, str) and p_explicit_id.strip():
        new_id = p_explicit_id.strip()
        if _count(session, "SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", [new_id]) > 0:
            return {"error": "DUPLICATE: id already exists", "id": new_id}
    else:
        prod = (p_product if isinstance(p_product, str) else "").upper().strip()
        if t == "STORY":
            ent = "STORY_" + prod
        elif t == "DEFECT":
            ent = "DEFECT_" + prod
        elif t in ("APP","MODEL","DASHBOARD"):
            ent = "APP"
        else:
            ent = t
        reg = session.sql(
            "SELECT ID_PREFIX, NEXT_SEQ FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = ?",
            params=[ent]
        ).collect()
        if not reg or reg[0]["ID_PREFIX"] is None or reg[0]["NEXT_SEQ"] is None:
            return {"error": "no registered series; supply P_EXPLICIT_ID or register a convention",
                    "entity": ent, "hint": "STORY/DEFECT require P_PRODUCT"}
        prefix = reg[0]["ID_PREFIX"]
        session.sql("UPDATE GUPPIWHEEL.PUBLIC.ID_CONVENTIONS SET NEXT_SEQ = NEXT_SEQ + 1 WHERE ENTITY = ?", params=[ent]).collect()
        nv = session.sql("SELECT NEXT_SEQ - 1 AS C FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = ?", params=[ent]).collect()[0]["C"]
        new_id = prefix + str(nv)
        if _count(session, "SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", [new_id]) > 0:
            return {"error": "ALLOCATION COLLISION (counter behind data)", "id": new_id, "entity": ent}

    owner = session.sql("SELECT CURRENT_USER() AS C").collect()[0]["C"]
    content = _asobj(p_content, {})
    meta = _asobj(p_metadata, {})
    tags = _asobj(p_tags, [])
    if not isinstance(tags, list):
        tags = []

    session.sql(
        "INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS "
        "(ID, TYPE, STAGE, PARENT_ID, TITLE, OWNER, CONTENT, TAGS, METADATA, CREATED_AT, UPDATED_AT) "
        "SELECT ?, ?, ?, NULLIF(?, 'None'), ?, ?, PARSE_JSON(?), PARSE_JSON(?)::ARRAY, PARSE_JSON(?), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()",
        params=[new_id, t, stage, (p_parent_id if (isinstance(p_parent_id, str) and p_parent_id.strip() and p_parent_id.strip() != 'None') else None), p_title, owner,
                json.dumps(content), json.dumps(tags), json.dumps(meta)]
    ).collect()
    return {"artifact_id": new_id, "type": t, "stage": stage, "owner": owner}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARCHAR,ARRAY,VARCHAR,VARIANT) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARCHAR,ARRAY,VARCHAR,VARIANT) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- =============================================================================
-- STEWART_AUDIT — Stewart's read-only grounding/hygiene scan (RULE-027).
-- Writes ONE AUDIT scan-record artifact (tagged guppi). Proposes nothing here.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.STEWART_AUDIT()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
def run(session):
    rows = session.sql("SELECT signal, severity, n, detail FROM GUPPIWHEEL.PUBLIC.GROUNDING_HEALTH_V WHERE n > 0").collect()
    findings = [{"signal": r["SIGNAL"], "severity": r["SEVERITY"], "n": int(r["N"]), "detail": r["DETAIL"]} for r in rows]
    known_open = [{"id": "STO-SUBSTRATE-9", "issue": "seed vs live audit-grounding model fork (in-wheel AUDIT artifacts vs AUDIT_RUNS tables)"}]
    verdict = "issues" if findings else "clean"
    ts = session.sql("SELECT TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISS') AS C").collect()[0]["C"]
    audit_id = "STEWART-AUDIT-" + ts
    content = json.dumps({"verdict": verdict, "grounding_health": findings, "known_open": known_open,
        "scanned_surfaces": ["ARTIFACTS", "RULES", "ID_CONVENTIONS"],
        "note": "Read-only scan. Stewart proposes corrections via STORY children; it does not apply fixes (RULE-027)."})
    meta = json.dumps({"agent": "Stewart", "kind": "grounding_health"})
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('AUDIT', ?, NULL, PARSE_JSON(?), NULL, 'Built', ARRAY_CONSTRUCT('guppi'), ?, PARSE_JSON(?))",
        params=["Stewart grounding audit " + ts, content, audit_id, meta]).collect()
    return {"audit_id": audit_id, "verdict": verdict, "issue_count": len(findings), "findings": findings}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.STEWART_AUDIT() TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- PROPOSE_CORRECTION — Stewart files a STORY proposal (tagged guppi) under an audit.
-- Proposal ONLY: routes through CREATE_ARTIFACT; cannot write RULES/SUPERSEDED_BY (RULE-027).
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.PROPOSE_CORRECTION(
  P_AUDIT_ID VARCHAR, P_TITLE VARCHAR, P_FINDING VARCHAR, P_PROPOSED_FIX VARCHAR, P_TARGET_REF VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
def run(session, p_audit_id, p_title, p_finding, p_proposed_fix, p_target_ref):
    tref = p_target_ref if isinstance(p_target_ref, str) else None
    parent = p_audit_id if (isinstance(p_audit_id, str) and p_audit_id.strip()) else None
    content = json.dumps({"finding": p_finding, "proposed_fix": p_proposed_fix, "target_ref": tref, "proposed_by": "Stewart"})
    meta = json.dumps({"agent": "Stewart", "proposal": True, "status": "proposed", "authority": "sub-agent propose-only per RULE-027"})
    r = session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('STORY', ?, 'STEWART', PARSE_JSON(?), ?, 'Initiate', ARRAY_CONSTRUCT('guppi'), NULL, PARSE_JSON(?))",
        params=[p_title, content, parent, meta]).collect()
    out = r[0][0] if r else None
    return {"proposed_story": out, "parent_audit": parent, "note": "Proposal only. Human/orchestrator reviews + applies. Stewart cannot change doctrine (RULE-027)."}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.PROPOSE_CORRECTION(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
