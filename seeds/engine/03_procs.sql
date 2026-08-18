-- =============================================================================
-- guppi-platform v3.20.1 — Engine Seed 03: Procedures
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
    session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.STAGE_TRANSITIONS (ARTIFACT_ID, ARTIFACT_TYPE, FROM_STAGE, TO_STAGE, OVERRIDE_REASON, SOURCE) VALUES (?, ?, ?, ?, ?, ''advance'')", params=[p_artifact_id, current_type, current_stage, p_target_stage, p_override_reason]).collect()
    return json.dumps({"success": True, "artifact_id": p_artifact_id, "from_stage": current_stage, "to_stage": p_target_stage, "warnings": warnings, "overrides_used": overrides_used})
';

-- =============================================================================
-- SUBMIT_INITIATIVE — single-write to ARTIFACTS
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  "TITLE" VARCHAR, "HYPOTHESIS" VARCHAR, "INSTRUCTIONS" VARCHAR, "P_FORCE" BOOLEAN, "P_FORCE_REASON" VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER  -- RULE-028: procedure-mediated write; runs as owner so contributors need no direct ARTIFACTS DML
AS
$$
import json

# Warn-hard threshold for near-duplicate INITIATIVEs (calibrated: true dup INIT-80/81 = 0.93;
# related-but-distinct <= 0.53). >= this against an existing live INITIATIVE => HOLD unless P_FORCE.
DUP_SIMILARITY_THRESHOLD = 0.80

def _search(session, svc, qtext, cols, limit):
    # Advisory prior-art lookup. Fails SAFE: never let a search hiccup block a submission.
    try:
        q = json.dumps({"query": (qtext or "")[:900], "columns": cols, "limit": limit})
        r = session.sql("SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(?, ?)", params=[svc, q]).collect()
        return json.loads(str(r[0][0])).get("results", []) or []
    except Exception:
        return []

def run(session, title, hypothesis, instructions, p_force, p_force_reason):
    # RULE-031 No Unilateral Duplicate-Override: forcing past a dup HOLD requires an explicit,
    # non-empty reason (stamped to metadata.dup_override for audit). Empty reason on force = reject.
    if p_force and not (p_force_reason and str(p_force_reason).strip()):
        return ("ERROR: P_FORCE requires a non-empty P_FORCE_REASON. On a duplicate HOLD the default is "
                "to add your work under the existing initiative; only a human may force a separate one, "
                "with a recorded reason (RULE-031).")
    qtext = (title or "") + ". " + (hypothesis or "")

    # Duplicate GATE (warn-hard, overridable). Semantic-similarity check against existing LIVE
    # initiatives via AI_SIMILARITY; if the closest one is >= threshold and the caller did not
    # force, HOLD and surface it so the human decides (add to it, or resubmit with P_FORCE => TRUE).
    # Fails SAFE: any scoring hiccup falls through to a normal submit (never blocks on a nicety).
    dup = None
    if not p_force:
        try:
            top = session.sql(
                "SELECT ID, TITLE, AI_SIMILARITY(?, TITLE || '. ' || COALESCE(CONTENT:hypothesis::string, '')) AS SIM "
                "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS "
                "WHERE TYPE = 'INITIATIVE' AND SUPERSEDED_BY IS NULL "
                "ORDER BY SIM DESC NULLS LAST LIMIT 1",
                params=[qtext]
            ).collect()
            if top and top[0]["SIM"] is not None and float(top[0]["SIM"]) >= DUP_SIMILARITY_THRESHOLD:
                dup = {"id": top[0]["ID"], "title": top[0]["TITLE"] or "", "sim": round(float(top[0]["SIM"]), 3)}
        except Exception:
            dup = None
    if dup:
        return ("HOLD - not submitted. This looks very similar (" + str(dup["sim"]) + ") to "
                + dup["id"] + " '" + dup["title"] + "'. If it is genuinely different, resubmit with "
                "P_FORCE => TRUE. Otherwise add your work under " + dup["id"] + ".")

    # Prior-art scan (advisory, non-blocking): surface what we already know (RESEARCH/NARRATIVE + Radar).
    art = [{"id": h.get("ID"), "kind": h.get("TYPE"), "title": (h.get("TITLE") or "")[:160]}
           for h in _search(session, "GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_SVC", qtext, ["ID", "TYPE", "TITLE"], 4)]
    rad = [{"id": h.get("ID"), "kind": "RADAR:" + (h.get("SOURCE_NAME") or ""), "title": (h.get("TITLE") or "")[:160]}
           for h in _search(session, "GUPPIWHEEL.PUBLIC.RADAR_SEARCH_SVC", qtext, ["ID", "TITLE", "SOURCE_NAME"], 3)]
    prior = art + rad

    # Single write chokepoint (RULE-029): delegate INSERT + atomic INIT- allocation to CREATE_ARTIFACT.
    content = {"hypothesis": hypothesis or "", "instructions": instructions or ""}
    meta = {"priority": "P2", "submitted_via": "SUBMIT_INITIATIVE"}
    if prior:
        meta["related_prior_art"] = prior[:7]
    if p_force:
        meta["dup_override"] = {"reason": str(p_force_reason).strip(), "forced": True}
    res = session.sql(
        "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?, ?, NULL, ?, NULL, 'Initiate', NULL, NULL, ?)",
        params=["INITIATIVE", title, json.dumps(content), json.dumps(meta)]
    ).collect()
    out = str(res[0][0]) if res else ""
    try:
        r = json.loads(out) if out else {}
    except Exception:
        r = {}
    if isinstance(r, dict) and r.get("error"):
        return "ERROR: " + out
    init_id = r.get("artifact_id", "INIT-?") if isinstance(r, dict) else "INIT-?"
    msg = "Submitted: " + init_id + " (Initiate). Rocky picks up within 5 minutes."
    if p_force:
        msg += " [dup-override]"
    preview = art[:2] + rad[:2]
    if preview:
        msg += " | Related prior art (advisory): " + "; ".join([(p["id"] or "?") + " " + (p["title"] or "") for p in preview])
    return msg
$$;

-- 4-arg force signature (legacy): delegates to the 5-arg core with NO reason.
-- Forcing without a reason is REJECTED by the core (RULE-031) — a reason is mandatory to force.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  "TITLE" VARCHAR, "HYPOTHESIS" VARCHAR, "INSTRUCTIONS" VARCHAR, "P_FORCE" BOOLEAN
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session, title, hypothesis, instructions, p_force):
    r = session.sql(
        "CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(?, ?, ?, ?, ?)",
        params=[title, hypothesis, instructions, p_force, None]
    ).collect()
    return str(r[0][0]) if r else ""
$$;

-- 3-arg entry point (viewer + COWORK agent call this): thin wrapper -> guarded 4-arg with P_FORCE=FALSE.
-- Keeps every existing caller on the dup-gated path automatically; overriding requires the explicit 4-arg call.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  "TITLE" VARCHAR, "HYPOTHESIS" VARCHAR, "INSTRUCTIONS" VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session, title, hypothesis, instructions):
    r = session.sql(
        "CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(?, ?, ?, ?)",
        params=[title, hypothesis, instructions, False]
    ).collect()
    return str(r[0][0]) if r else ""
$$;

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
import json, re, time

def _agent_text(session, prompt):
    payload = {"messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}]}
    try:
        result = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)",
                             params=["GUPPIWHEEL.PUBLIC.ROCKY_AGENT", json.dumps(payload)]).collect()
        response = str(result[0][0]) if result else "No response from agent"
    except Exception as e:
        return "Agent execution error: " + str(e)
    text = response
    try:
        rj = json.loads(response)
        parts = [it.get("text", "") for it in rj.get("content", []) if isinstance(it, dict) and it.get("type") == "text"]
        if parts:
            text = "\\n".join(parts)
    except (json.JSONDecodeError, KeyError, TypeError):
        pass
    return text

def run(session):
    rows = session.sql(
        "SELECT ID, TITLE, CONTENT:hypothesis::VARCHAR AS HYPOTHESIS, "
        "CONTENT:instructions::VARCHAR AS INSTRUCTIONS, METADATA:priority::VARCHAR AS PRIORITY, "
        "METADATA:swarm::BOOLEAN AS SWARM, TO_JSON(METADATA:related_prior_art) AS PRIOR_ART "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = ''INITIATIVE'' AND STAGE = ''Initiate'' "
        "AND SUPERSEDED_BY IS NULL "
        "ORDER BY METADATA:priority NULLS LAST, CREATED_AT LIMIT 1"
    ).collect()
    if not rows:
        return "No queued initiatives."
    init = rows[0]
    init_id = init["ID"]
    title = init["TITLE"]
    hypothesis = init["HYPOTHESIS"] or "N/A"
    instructions = init["INSTRUCTIONS"] or ""
    priority = (init["PRIORITY"] or "").lower()
    swarm = bool(init["SWARM"]) or (priority == "high")
    prior_art = init["PRIOR_ART"]
    pa_block = ""
    if prior_art and str(prior_art).strip() not in ("", "null"):
        pa_block = ("\\n\\nPRIOR ART ALREADY IN THE WHEEL (research syntheses and Radar finds we already have). "
                    "Build on and CITE these by id; if this initiative substantially overlaps one, say so plainly and focus only on what is NEW. Do NOT re-research from scratch:\\n" + str(prior_art)[:2000])
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = ''Research'', UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?", params=[init_id]).collect()

    base = ("TITLE: " + title + "\\nHYPOTHESIS: " + hypothesis + "\\n\\nINSTRUCTIONS:\\n" + instructions + pa_block +
            "\\n\\nUse web search to find current, specific information. Cite named sources, dates, numbers. "
            "Do NOT call submit_initiative.")

    method = "single"
    conflicts = ""
    if not swarm:
        # --- SINGLE-PASS (Rocky default, unchanged behavior) ---
        prompt = ("Execute this research initiative autonomously.\\n\\n" + base +
                  "\\n\\nWhen complete provide: 1) VERDICT (supported / partially supported / refuted) "
                  "2) KEY FINDINGS (3-5 bullets with specifics) 3) RECOMMENDED NEXT STEPS. Text only.")
        synthesis = _agent_text(session, prompt)
    else:
        # --- SWARM (RULE-030, opt-in via metadata.swarm or priority=high; ArcticSwarm pattern) ---
        method = "swarm"
        run_id = init_id + "-" + str(int(time.time()))
        roles = ["retriever", "counterexample-seeker", "consistency-checker"]
        for role in roles:
            rprompt = "ROLE: " + role + "\\n\\nExecute this research initiative in your role only.\\n\\n" + base
            findings = _agent_text(session, rprompt)
            session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE (RUN_ID, INIT_ID, ROLE, FINDINGS) VALUES (?, ?, ?, ?)",
                        params=[run_id, init_id, role, (findings or "")[:12000]]).collect()
        ev = session.sql("SELECT ROLE, FINDINGS FROM GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE WHERE RUN_ID = ? ORDER BY ROLE", params=[run_id]).collect()
        board = "\\n\\n".join(["=== ROLE " + r["ROLE"] + " ===\\n" + (r["FINDINGS"] or "") for r in ev])
        rec_prompt = ("You are the RECONCILER for an isolated multi-agent research swarm (ArcticSwarm pattern). "
                      "The roles worked independently and could not see each other. Do NOT average or paper over disagreement. "
                      "Return ONLY raw JSON (no markdown) with two keys: synthesis and conflicts. "
                      "synthesis = the best-supported integrated answer as VERDICT / KEY FINDINGS (3-5 bullets with specifics) / RECOMMENDED NEXT STEPS. "
                      "conflicts = explicit bullets where the retriever supporting evidence and the counterexample-seeker disconfirming evidence disagree, plus any consistency-checker flags; empty string if none.\\n\\n"
                      "INITIATIVE: " + title + "\\n\\nISOLATED FINDINGS:\\n" + board)
        rec = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=["claude-sonnet-4-5", rec_prompt]).collect()
        rec_txt = str(rec[0][0]) if rec else ""
        synthesis = rec_txt
        m = re.search(r"\\{[\\s\\S]*\\}", rec_txt)
        if m:
            try:
                j = json.loads(m.group(0))
                synthesis = j.get("synthesis", rec_txt)
                conflicts = j.get("conflicts", "") or ""
            except Exception:
                pass

    base_id = "RES-" + init_id.replace("INIT-", "") + "-ROCKY"
    res_id = base_id
    v = 2
    while session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[res_id]).collect()[0]["C"] > 0:
        res_id = base_id + "-V" + str(v)
        v += 1
    fw_content = json.dumps({"synthesis": (synthesis or "")[:12000], "conflicts": (conflicts or "")[:6000], "method": method, "executor": "rocky-cortex-agent-v4"})
    fw_meta = json.dumps({"model": "auto", "has_web_search": True, "method": method, "pattern": "arcticswarm", "reconciler": ("claude-sonnet-4-5" if method == "swarm" else None)})
    try:
        # Single write chokepoint (RULE-029): delegate the RESEARCH INSERT to CREATE_ARTIFACT
        wres = session.sql(
            "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?, ?, NULL, ?, ?, ''Built'', NULL, ?, ?)",
            params=["RESEARCH", "Rocky Research: " + title[:200], fw_content, init_id, res_id, fw_meta]
        ).collect()
        wout = str(wres[0][0]) if wres else ""
        try:
            wj = json.loads(wout)
        except Exception:
            wj = {}
        if isinstance(wj, dict) and wj.get("error"):
            return "ERROR writing research: " + wout
    except Exception as e:
        return "ERROR writing research: " + str(e)
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE = ''Built'', UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?", params=[init_id]).collect()
    return "COMPLETE (" + method + "): " + init_id + " | " + title
';

-- =============================================================================
-- PUBLISH_ARTIFACT — register a launchable artifact (NARRATIVE/APP/MODEL/DASHBOARD)
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(
  P_TYPE VARCHAR,
  P_TITLE VARCHAR,
  P_DESCRIPTION VARCHAR,
  P_LAUNCH_SPEC VARCHAR,   -- JSON string (scalar surface for agent generic tools)
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
$$
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
    # Single write chokepoint (RULE-029): validate launch, then DELEGATE the INSERT to CREATE_ARTIFACT
    # (gap-free IDs, PRODUCT_ID, type/stage validation). No direct INSERT here.
    content = {"description": p_description or ""}
    meta = {"launch": launch, "sensitivity": p_sensitivity or "internal"}
    res = session.sql(
        "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?, ?, NULL, ?, ?, 'Built', NULL, NULL, ?)",
        params=[art_type, p_title, json.dumps(content), p_parent_id, json.dumps(meta)]
    ).collect()
    out = str(res[0][0]) if res else None
    try:
        r = json.loads(out) if out else {"error": "no response from CREATE_ARTIFACT"}
    except Exception:
        r = {"result": out}
    if isinstance(r, dict):
        r["launch"] = launch
    return r
$$;

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
           CONTENT = COALESCE(GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(:P_CONTENT, (SELECT TYPE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_ARTIFACT_ID)), CONTENT),
           TAGS = COALESCE(:P_TAGS, TAGS),
           UPDATED_AT = CURRENT_TIMESTAMP()
     WHERE ID = :P_ARTIFACT_ID;
    RETURN 'OK: updated ' || :P_ARTIFACT_ID;
END;

-- Read-back helper for long-form bodies. CONTENT.body_md (or full CONTENT JSON when absent) can
-- exceed a client's cell-render cap; this returns a SUBSTR slice so callers can page through it.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.GET_ARTIFACT_BODY(
  P_ARTIFACT_ID VARCHAR, P_OFFSET NUMBER DEFAULT 0, P_LEN NUMBER DEFAULT 4000
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
BEGIN
    LET full_body VARCHAR := (
        SELECT COALESCE(CONTENT:body_md::VARCHAR, TO_JSON(CONTENT))
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE ID = :P_ARTIFACT_ID AND SUPERSEDED_BY IS NULL
    );
    IF (:full_body IS NULL) THEN
        RETURN 'ERROR: artifact not found (or superseded): ' || :P_ARTIFACT_ID;
    END IF;
    RETURN SUBSTR(:full_body, :P_OFFSET + 1, :P_LEN);
END;

-- Grants
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ADVANCE_STAGE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
-- RULE-031: force overloads are ADMIN-only (contributors/agents cannot unilaterally override a dup HOLD).
-- The 3-arg wrapper (above) still lets contributors submit on the dup-gated path (delegates via EXECUTE AS OWNER).
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(VARCHAR,VARCHAR,VARCHAR,BOOLEAN) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(VARCHAR,VARCHAR,VARCHAR,BOOLEAN,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
-- PLAT-D008b: P_LAUNCH_SPEC (4th arg) is VARCHAR (scalar JSON surface), not VARIANT — grant sig must match the live proc or the GRANT no-ops silently.
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(VARCHAR,VARCHAR,VARIANT,ARRAY) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(VARCHAR,NUMBER) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.GET_ARTIFACT_BODY(VARCHAR,NUMBER,NUMBER) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE() TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- NORMALIZE_ARTIFACT_CONTENT — the ONE canonical content-shape normalizer (RULE-033).
-- Pure function (no session): guarantees renderable types carry CONTENT.body_md.
-- Called by BOTH write paths (CREATE_ARTIFACT + UPDATE_OWN_ARTIFACT) and the one-time
-- backfill, so the shape is enforced once, at the door, for every producer. NULL in -> NULL
-- out (so UPDATE's COALESCE no-ops). Lossless: single-body objects promote their alias;
-- multi-key structured objects compose EVERY key into a '## Section' (never drops content).
-- =============================================================================
CREATE OR REPLACE FUNCTION GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(P_CONTENT VARIANT, P_TYPE VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'norm'
AS
$$
import json
# Canonical renderable set. Extend here (or migrate to a TYPE_REGISTRY.RENDERABLE flag) to render more types.
RENDERABLE = {"NARRATIVE"}
_ALIASES = ["markdown", "body", "narrative", "synthesis", "description", "summary"]
_NON_BODY_META_KEYS = {"summary", "audience"}
def _repair_markdown(s):
    if not isinstance(s, str):
        return ""
    t = s.replace("\r\n", "\n").replace("\r", "\n")
    t = t.replace("\\|", "|")
    t = t.replace("  ## ", "\n\n## ")
    t = t.replace("  ---  ", "\n\n---\n\n")
    t = t.replace(" --- ", "\n\n---\n\n")
    t = t.replace("  - ", "\n- ")
    t = t.replace("|  ## ", "|\n\n## ")
    return t.strip()
def _validate_narrative_md(md):
    issues = []
    if not isinstance(md, str) or not md.strip():
        return ["body_md missing or empty"]
    body = md.strip()
    if len(body) > 600 and "\n" not in body:
        issues.append("body_md is a large single line")
    if "\\|" in body:
        issues.append("body_md still contains escaped table pipes")
    if body.count("|") >= 6 and "\n|" not in body:
        issues.append("table-like content appears collapsed onto one line")
    if "## " in body and "\n## " not in body and not body.startswith("## "):
        issues.append("heading markers appear inline instead of on separate lines")
    return issues
def _title(k):
    return k.replace("_", " ").strip().title()
def norm(content, p_type):
    if content is None:
        return None
    if not isinstance(content, dict):
        return content
    if (p_type or "").upper().strip() not in RENDERABLE:
        return content
    bm = content.get("body_md")
    if isinstance(bm, str) and bm.strip():
        out = dict(content)
        out["body_md"] = _repair_markdown(bm)
        issues = _validate_narrative_md(out["body_md"])
        if issues:
            raise ValueError("; ".join(issues))
        return out
    out = dict(content)
    # Promote the single body-alias (by _ALIASES priority) as the UNLABELED lead; append every
    # OTHER key as a '## Section'. So the prose leads clean and metadata/supplements trail; a
    # purely structured object (no alias) composes all keys as sections. Lossless either way.
    lead_key = None
    for a in _ALIASES:
        av = content.get(a)
        if isinstance(av, str) and av.strip():
            lead_key = a
            break
    parts = []
    if lead_key is not None:
        parts.append(content[lead_key].strip())
    for k, v in content.items():
        if k == lead_key or k == "body_md" or k in _NON_BODY_META_KEYS:
            continue
        if isinstance(v, str) and v.strip():
            seg = v
        elif isinstance(v, (dict, list)):
            seg = "```json\n" + json.dumps(v, indent=2, default=str) + "\n```"
        else:
            continue
        parts.append("## " + _title(k) + "\n\n" + seg)
    out["body_md"] = _repair_markdown("\n\n".join(parts))
    issues = _validate_narrative_md(out["body_md"])
    if issues:
        raise ValueError("; ".join(issues))
    return out
$$;
GRANT USAGE ON FUNCTION GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(VARIANT,VARCHAR) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON FUNCTION GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(VARIANT,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON FUNCTION GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(VARIANT,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- VALIDATE_NARRATIVE_CONTENT — the governed narrative-structure gate (E-014).
-- Reads NARRATIVE_TEMPLATE (governance-as-data), validates section-keyed content against
-- the declared template, and composes a canonical body_md in ORD order (headings from the
-- template). HARD-REJECTS a missing required section or an unknown section (no drift).
-- Pure UDFs cannot read tables, so this is a proc (session-backed). Returns
-- {ok, content, template, template_version} on success, or {error, ...} on violation.
-- Called by CREATE_ARTIFACT's NARRATIVE branch whenever content declares a template;
-- CREATE_NARRATIVE / BOB_EXECUTE always declare one, so the paved roads are always enforced.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(P_CONTENT VARCHAR, P_TEMPLATE VARCHAR DEFAULT NULL)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
# Non-section keys allowed alongside the template sections (never treated as drift).
RESERVED = {"template", "template_version", "audience", "title", "body_md"}
def run(session, p_content, p_template):
    try:
        content = json.loads(p_content) if isinstance(p_content, str) else (p_content or {})
    except Exception as e:
        return {"error": "narrative content is not valid JSON", "detail": str(e)}
    if not isinstance(content, dict):
        return {"error": "narrative content must be a JSON object of sections"}
    template = (p_template or content.get("template") or "default")
    template = str(template).strip() or "default"
    rows = session.sql(
        "SELECT SECTION_KEY, ORD, REQUIRED, HEADING, TEMPLATE_VERSION "
        "FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE WHERE TEMPLATE = ? ORDER BY ORD",
        params=[template]
    ).collect()
    if not rows:
        allowed = [r["TEMPLATE"] for r in session.sql("SELECT DISTINCT TEMPLATE FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE ORDER BY TEMPLATE").collect()]
        return {"error": "unknown narrative template", "template": template, "allowed": allowed}
    version = rows[0]["TEMPLATE_VERSION"]
    valid_keys = {r["SECTION_KEY"] for r in rows}
    unknown = [k for k in content.keys() if k not in valid_keys and k not in RESERVED]
    if unknown:
        return {"error": "unknown narrative sections (not in template)", "template": template,
                "unknown": sorted(unknown), "allowed": sorted(valid_keys)}
    missing = []
    for r in rows:
        if r["REQUIRED"]:
            v = content.get(r["SECTION_KEY"])
            if not (isinstance(v, str) and v.strip()):
                missing.append(r["SECTION_KEY"])
    if missing:
        return {"error": "missing required narrative sections", "template": template, "missing": missing,
                "hint": "provide non-empty markdown for every required section"}
    parts = []
    for r in rows:
        v = content.get(r["SECTION_KEY"])
        if isinstance(v, str) and v.strip():
            parts.append("## " + r["HEADING"] + "\n\n" + v.strip())
    out = dict(content)
    out["template"] = template
    out["template_version"] = version
    out["body_md"] = "\n\n".join(parts)
    return {"ok": True, "content": out, "template": template, "template_version": version}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- CREATE_ARTIFACT — the single gated write path (RULE-029): the ONLY proc that INSERTs into ARTIFACTS.
-- PUBLISH_ARTIFACT / SUBMIT_INITIATIVE / ROCKY_EXECUTE / STEWART_AUDIT / PROPOSE_CORRECTION / BOB_EXECUTE delegate here.
-- All-scalar surface (P_CONTENT/P_TAGS/P_METADATA are JSON strings) so Cortex agent generic tools over a warehouse can call it directly.
-- Registry-driven gap-free allocation from ID_CONVENTIONS; refuses existing IDs.
-- Dual mode: P_EXPLICIT_ID (descriptive, uniqueness-checked) or auto from (TYPE, PRODUCT).
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(
  P_TYPE VARCHAR,
  P_TITLE VARCHAR,
  P_PRODUCT VARCHAR DEFAULT NULL,
  P_CONTENT VARCHAR DEFAULT NULL,      -- JSON string (scalar surface: agent generic tools over warehouse cannot pass VARIANT/OBJECT/ARRAY)
  P_PARENT_ID VARCHAR DEFAULT NULL,
  P_STAGE VARCHAR DEFAULT NULL,
  P_TAGS VARCHAR DEFAULT NULL,          -- JSON array string, e.g. ["a","b"]
  P_EXPLICIT_ID VARCHAR DEFAULT NULL,
  P_METADATA VARCHAR DEFAULT NULL       -- JSON string
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

# Canonical TYPE + STAGE come from TYPE_REGISTRY (governance-as-data, single source).
# No hardcoded lists here -- adding a type = one INSERT into TYPE_REGISTRY.

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

def _canon(o):
    try:
        return json.dumps(o, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        return None

def _looks_json(s):
    return len(s) > 0 and s[0] in ("{", "[")

def _content_from(v):
    # Smart routing: a JSON object/array is stored structured as-is; plain text/markdown is
    # wrapped into CONTENT.body_md so prose is never silently lost; input that LOOKS like JSON
    # ({ or [) but fails to parse raises -> caller returns a loud error (no silent {} fallback).
    if v is None:
        return {}
    if isinstance(v, (dict, list)):
        return v
    if isinstance(v, str):
        s = v.strip()
        if s == "":
            return {}
        if _looks_json(s):
            return json.loads(s)
        return {"body_md": v}
    return {}

def _meta_from(v):
    # Metadata is structured-only: object as-is; blank -> {}; JSON-looking-but-invalid raises.
    if v is None:
        return {}
    if isinstance(v, (dict, list)):
        return v
    if isinstance(v, str):
        s = v.strip()
        if s == "":
            return {}
        if _looks_json(s):
            return json.loads(s)
        return {}
    return {}

def run(session, p_type, p_title, p_product, p_content, p_parent_id, p_stage, p_tags, p_explicit_id, p_metadata):
    t = (p_type or "").upper().strip()
    # TYPE must exist in the governed registry (RULE-029 single-write-path philosophy).
    if _count(session, "SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY WHERE TYPE = ?", [t]) == 0:
        allowed = [r["TYPE"] for r in session.sql("SELECT TYPE FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY ORDER BY TYPE").collect()]
        return {"error": "unknown artifact type", "got": p_type,
                "hint": "register it in TYPE_REGISTRY first (governance-as-data)", "allowed": allowed}
    if not p_title:
        return {"error": "TITLE required"}
    # Per-type stage lifecycle from TYPE_REGISTRY (governance-as-data). The FIRST stage in
    # the type's ordered STAGES is its birth default (OUTCOME->ASPIRATIONAL, DEFECT->Research,
    # standard types->Initiate). Validate against THIS type's stages only -- NOT the global
    # union across all types -- so an artifact cannot be born outside its own lifecycle (PLAT-D4).
    type_stages_csv = session.sql(
        "SELECT STAGES AS S FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY WHERE TYPE = ?", params=[t]
    ).collect()[0]["S"]
    type_stages = [s.strip() for s in (type_stages_csv or "").split(",") if s.strip()]
    stage = (p_stage.strip() if (isinstance(p_stage, str) and p_stage.strip()) else None) or (type_stages[0] if type_stages else "Initiate")
    if stage not in type_stages:
        return {"error": "invalid STAGE for type", "type": t, "got": stage, "allowed": type_stages}

    # --- DEDUP GUARD (idempotency; complements the single-write-path guarantee, RULE-029): reject byte-identical LIVE resubmits ---
    # Keyed on (TYPE, TITLE, PARENT, OWNER, canonical CONTENT+METADATA) among non-superseded rows.
    # No time window: identical live knowledge = one artifact. To re-create retired content,
    # supersede the original first (SUPERSEDED_BY) and this check will no longer match.
    # Runs BEFORE ID allocation so a deduped resubmit never burns a gap-free sequence number.
    owner = session.sql("SELECT CURRENT_USER() AS C").collect()[0]["C"]
    try:
        content = _content_from(p_content)
    except Exception as e:
        return {"error": "P_CONTENT is not valid JSON", "detail": str(e),
                "hint": "pass a JSON object for structured content, or plain text/markdown (stored as CONTENT.body_md)"}
    # Canonical shape (RULE-033 + E-014): NARRATIVE with a declared template (content.template)
    # is validated + composed against NARRATIVE_TEMPLATE -- missing/unknown section => HARD REJECT
    # (no drift). Templateless narratives (legacy prose, or launch-pointer NARRATIVEs from
    # PUBLISH_ARTIFACT) fall back to the body_md normalizer and are exempt from the conformance
    # tripwire (go-forward: only template-stamped narratives are checked).
    if t == "NARRATIVE" and isinstance(content, dict) and content.get("template"):
        try:
            vr = session.sql("CALL GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(?, ?)",
                             params=[json.dumps(content), str(content.get("template"))]).collect()
            v = json.loads(str(vr[0][0])) if vr and vr[0][0] is not None else {}
        except Exception as e:
            return {"error": "narrative template validation failed", "detail": str(e)}
        if isinstance(v, dict) and v.get("error"):
            return v
        if isinstance(v, dict) and isinstance(v.get("content"), dict):
            content = v["content"]
    else:
        try:
            _nr = session.sql("SELECT TO_JSON(GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(PARSE_JSON(?), ?)) AS J",
                              params=[json.dumps(content), t]).collect()
            if _nr and _nr[0]["J"]:
                content = json.loads(_nr[0]["J"])
        except Exception as e:
            return {"error": "invalid narrative content", "detail": str(e),
                    "hint": "NARRATIVE content must normalize to multiline body_md with renderable markdown structure"}
    try:
        meta = _meta_from(p_metadata)
    except Exception as e:
        return {"error": "P_METADATA is not valid JSON", "detail": str(e),
                "hint": "P_METADATA must be a JSON object"}
    norm_parent = p_parent_id.strip() if (isinstance(p_parent_id, str) and p_parent_id.strip() and p_parent_id.strip() != 'None') else None
    inc_c, inc_m = _canon(content), _canon(meta)
    dup_rows = session.sql(
        "SELECT ID, TO_JSON(CONTENT) AS C, TO_JSON(METADATA) AS M "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS "
        "WHERE TYPE = ? AND TITLE = ? AND OWNER = ? AND SUPERSEDED_BY IS NULL "
        "AND COALESCE(PARENT_ID, '~none~') = COALESCE(NULLIF(?, 'None'), '~none~')",
        params=[t, p_title, owner, norm_parent]
    ).collect()
    for row in dup_rows:
        if _canon(_asobj(row["C"], {})) == inc_c and _canon(_asobj(row["M"], {})) == inc_m:
            return {"artifact_id": row["ID"], "type": t, "stage": stage, "owner": owner,
                    "deduped": True,
                    "note": "idempotent: byte-identical live artifact already exists; returned existing ID (no new row, no ID burned)"}

    if isinstance(p_explicit_id, str) and p_explicit_id.strip():
        new_id = p_explicit_id.strip()
        if _count(session, "SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", [new_id]) > 0:
            return {"error": "DUPLICATE: id already exists", "id": new_id}
    else:
        prod = (p_product if isinstance(p_product, str) else "").upper().strip()
        # ID-series mapping is governance-as-data in TYPE_REGISTRY (no hardcoded type list):
        #   ID_PRODUCT_SCOPED -> entity is TYPE_<PRODUCT> (STORY/DEFECT); ID_SERIES_ENTITY -> that
        #   explicit entity (APP/MODEL/DASHBOARD -> 'APP'); else the entity is the TYPE itself.
        sr = session.sql(
            "SELECT ID_SERIES_ENTITY, ID_PRODUCT_SCOPED FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY WHERE TYPE = ?",
            params=[t]
        ).collect()
        if sr and sr[0]["ID_PRODUCT_SCOPED"]:
            ent = t + "_" + prod
        elif sr and sr[0]["ID_SERIES_ENTITY"]:
            ent = sr[0]["ID_SERIES_ENTITY"]
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

    tags = _asobj(p_tags, [])
    if not isinstance(tags, list):
        tags = []

    # STO-SUBSTRATE-8: stamp controlled PRODUCT_ID when P_PRODUCT is a registered product (the share boundary).
    prod = (p_product if isinstance(p_product, str) else "").lower().strip()
    prod_id = None
    if prod:
        chk = session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.PRODUCTS WHERE LOWER(PRODUCT_ID)=?", params=[prod]).collect()
        if chk and chk[0]["C"] > 0:
            prod_id = prod

    norm_parent_val = (p_parent_id if (isinstance(p_parent_id, str) and p_parent_id.strip() and p_parent_id.strip() != 'None') else None)

    # INIT-75 Thread A: birth-hash chain. Serialize on the CHAIN_HEAD row lock (bare INSERTs are NOT
    # mutually serialized in Snowflake), read prev, hash the birth bundle with the SAME _canon used by
    # the dedup guard, then insert + advance head atomically. Dedup guard above returns before here, so
    # a deduped resubmit never burns a link. ROW_HASH = SHA2_HEX(_canon({"rec": bundle, "prev": prev})).
    session.sql("BEGIN").collect()
    try:
        session.sql("UPDATE GUPPIWHEEL.PUBLIC.CHAIN_HEAD SET LAST_HASH = LAST_HASH WHERE CHAIN_ID = 'main'").collect()
        prev_hash = session.sql("SELECT LAST_HASH AS H FROM GUPPIWHEEL.PUBLIC.CHAIN_HEAD WHERE CHAIN_ID = 'main'").collect()[0]["H"]
        bundle = {"id": new_id, "type": t, "title": p_title, "owner": owner,
                  "parent_id": norm_parent_val, "content": content, "metadata": meta}
        row_hash = session.sql("SELECT SHA2_HEX(?) AS H", params=[_canon({"rec": bundle, "prev": prev_hash})]).collect()[0]["H"]
        session.sql(
            "INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS "
            "(ID, TYPE, STAGE, PARENT_ID, TITLE, OWNER, CONTENT, TAGS, METADATA, PRODUCT_ID, PREV_HASH, ROW_HASH, CREATED_AT, UPDATED_AT) "
            "SELECT ?, ?, ?, NULLIF(?, 'None'), ?, ?, PARSE_JSON(?), PARSE_JSON(?)::ARRAY, PARSE_JSON(?), NULLIF(?, 'None'), NULLIF(?, 'None'), ?, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()",
            params=[new_id, t, stage, norm_parent_val, p_title, owner,
                    json.dumps(content), json.dumps(tags), json.dumps(meta), prod_id, prev_hash, row_hash]
        ).collect()
        session.sql("UPDATE GUPPIWHEEL.PUBLIC.CHAIN_HEAD SET LAST_HASH = ? WHERE CHAIN_ID = 'main'", params=[row_hash]).collect()
        session.sql(
            "INSERT INTO GUPPIWHEEL.PUBLIC.STAGE_TRANSITIONS (ARTIFACT_ID, ARTIFACT_TYPE, FROM_STAGE, TO_STAGE, SOURCE) "
            "SELECT ?, ?, NULL, ?, 'birth'",
            params=[new_id, t, stage]
        ).collect()
        session.sql("COMMIT").collect()
    except Exception as e:
        session.sql("ROLLBACK").collect()
        return {"error": "chain-insert failed", "detail": str(e), "id": new_id}
    return {"artifact_id": new_id, "type": t, "stage": stage, "owner": owner, "product_id": prod_id, "row_hash": row_hash}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- =============================================================================
-- CREATE_NARRATIVE / UPDATE_NARRATIVE — the section-keyed paved road (E-014).
-- Authors (CoWork, Bob, humans) pass sections keyed by the template's section_key;
-- these delegate to the single write path (CREATE_ARTIFACT / UPDATE_OWN_ARTIFACT), which
-- enforces the template (hard-reject) via VALIDATE_NARRATIVE_CONTENT. Every narrative born
-- through here is template-conformant and stamped -- no drift.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_NARRATIVE(
  P_TEMPLATE VARCHAR, P_TITLE VARCHAR, P_SECTIONS VARCHAR,
  P_PARENT_ID VARCHAR DEFAULT NULL, P_PRODUCT VARCHAR DEFAULT NULL, P_METADATA VARCHAR DEFAULT NULL
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
def run(session, p_template, p_title, p_sections, p_parent_id, p_product, p_metadata):
    try:
        sections = json.loads(p_sections) if isinstance(p_sections, str) else (p_sections or {})
    except Exception as e:
        return {"error": "P_SECTIONS is not valid JSON", "detail": str(e)}
    if not isinstance(sections, dict):
        return {"error": "P_SECTIONS must be a JSON object of section_key -> markdown"}
    content = dict(sections)
    content["template"] = (p_template or content.get("template") or "default")
    # Single gate: CREATE_ARTIFACT validates against the template (hard-reject) + composes body_md.
    res = session.sql(
        "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('NARRATIVE', ?, ?, ?, ?, 'Built', NULL, NULL, ?)",
        params=[p_title, p_product, json.dumps(content), p_parent_id, p_metadata]
    ).collect()
    out = res[0][0] if res else None
    try:
        return json.loads(str(out)) if out is not None else {"error": "no response from CREATE_ARTIFACT"}
    except Exception:
        return {"result": str(out)}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_NARRATIVE(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CREATE_NARRATIVE(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_NARRATIVE(
  P_ARTIFACT_ID VARCHAR, P_SECTIONS VARCHAR, P_TEMPLATE VARCHAR DEFAULT NULL
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
def run(session, p_artifact_id, p_sections, p_template):
    row = session.sql(
        "SELECT TYPE, CONTENT:template::string AS TPL FROM GUPPIWHEEL.PUBLIC.ARTIFACTS "
        "WHERE ID = ? AND SUPERSEDED_BY IS NULL", params=[p_artifact_id]
    ).collect()
    if not row:
        return {"error": "artifact not found (or superseded)", "id": p_artifact_id}
    if row[0]["TYPE"] != "NARRATIVE":
        return {"error": "not a narrative", "id": p_artifact_id, "type": row[0]["TYPE"]}
    template = (p_template or row[0]["TPL"] or "default")
    try:
        sections = json.loads(p_sections) if isinstance(p_sections, str) else (p_sections or {})
    except Exception as e:
        return {"error": "P_SECTIONS is not valid JSON", "detail": str(e)}
    if not isinstance(sections, dict):
        return {"error": "P_SECTIONS must be a JSON object of section_key -> markdown"}
    content = dict(sections)
    content["template"] = template
    vr = session.sql("CALL GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(?, ?)",
                     params=[json.dumps(content), template]).collect()
    v = json.loads(str(vr[0][0])) if vr and vr[0][0] is not None else {}
    if v.get("error"):
        return v
    newc = v.get("content", content)
    ur = session.sql("CALL GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(?, NULL, PARSE_JSON(?), NULL)",
                     params=[p_artifact_id, json.dumps(newc)]).collect()
    return {"updated": p_artifact_id, "template": template, "result": (str(ur[0][0]) if ur else None)}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_NARRATIVE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_NARRATIVE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- VERIFY_CHAIN — INIT-75 Thread A tamper audit (v3: structural gate + informational content).
-- Walks the birth-hash chain by LINKAGE (prev_hash -> row_hash), NOT by any sequence/timestamp
-- column (Snowflake AUTOINCREMENT and CREATED_AT are not reliable chain order).
--
-- ATTESTATION MODEL (decided 2026-07-11): the wheel has GOVERNED in-place edits (MERGE_ARTIFACTS
-- re-parents children + breadcrumbs metadata; UPDATE_OWN_ARTIFACT edits title/content) that
-- legitimately change hashed bundle fields. So:
--   * STRUCTURAL = the hard pass/fail tamper-evidence gate: genesis==1, no fork, no cycle, all
--     rows reachable by hash-linkage (detects delete / reorder / insert). Flips ok:false.
--   * CONTENT = informational: for LIVE rows (SUPERSEDED_BY IS NULL) recompute the bundle hash;
--     rows that differ from birth are listed in `modified_since_birth` for review (governed
--     edits AND any real tamper surface here) — NEVER auto-fails. Superseded rows are retired
--     and skipped (they may carry governed MERGE annotations). Read-only.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.VERIFY_CHAIN()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

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

def _canon(o):
    try:
        return json.dumps(o, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        return None

def run(session):
    rows = session.sql(
        "SELECT ID, TYPE, TITLE, OWNER, PARENT_ID, TO_JSON(CONTENT) AS C, TO_JSON(METADATA) AS M, "
        "PREV_HASH, ROW_HASH, SUPERSEDED_BY FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NOT NULL"
    ).collect()
    total = len(rows)
    if total == 0:
        return {"ok": True, "total": 0, "note": "chain not initialized"}
    unhashed = session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NULL").collect()[0]["C"]

    by_prev = {}
    for r in rows:
        key = r["PREV_HASH"] if r["PREV_HASH"] else None
        by_prev.setdefault(key, []).append(r)

    genesis = by_prev.get(None, [])
    if len(genesis) != 1:
        return {"ok": False, "reason": "STRUCTURAL: genesis_count!=1", "genesis_found": len(genesis), "total": total, "unhashed_rows": unhashed}

    expected_prev = None
    count = 0
    modified = []
    while True:
        matches = by_prev.get(expected_prev, [])
        if len(matches) == 0:
            break
        if len(matches) > 1:
            return {"ok": False, "reason": "STRUCTURAL: fork", "at_prev_hash": expected_prev,
                    "fork_ids": [m["ID"] for m in matches], "checked": count}
        r = matches[0]
        # Informational content check on LIVE rows only (superseded rows are retired).
        if r["SUPERSEDED_BY"] is None:
            bundle = {"id": r["ID"], "type": r["TYPE"], "title": r["TITLE"], "owner": r["OWNER"],
                      "parent_id": r["PARENT_ID"], "content": _asobj(r["C"], {}), "metadata": _asobj(r["M"], {})}
            expected_row = session.sql("SELECT SHA2_HEX(?) AS H",
                                       params=[_canon({"rec": bundle, "prev": expected_prev})]).collect()[0]["H"]
            if expected_row != r["ROW_HASH"]:
                modified.append(r["ID"])
        count += 1
        expected_prev = r["ROW_HASH"]
        if count > total:
            return {"ok": False, "reason": "STRUCTURAL: cycle_detected", "checked": count}

    if count != total:
        return {"ok": False, "reason": "STRUCTURAL: unreachable_rows(orphan/deletion/reorder)",
                "reachable": count, "total": total}
    return {"ok": True, "structural": "intact", "total": total, "head": expected_prev,
            "unhashed_rows": unhashed,
            "modified_since_birth": modified,
            "modified_note": "live rows whose hashed fields changed after birth (governed edits like MERGE re-parent / UPDATE_OWN_ARTIFACT, or tamper) -- review, not a failure"}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.VERIFY_CHAIN() TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.VERIFY_CHAIN() TO ROLE GUPPIWHEEL_VIEWER;

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
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('AUDIT', ?, NULL, ?, NULL, 'Built', '[\"guppi\"]', ?, ?)",
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
    r = session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('STORY', ?, 'STEWART', ?, ?, 'Initiate', '[\"guppi\"]', NULL, ?)",
        params=[p_title, content, parent, meta]).collect()
    out = r[0][0] if r else None
    return {"proposed_story": out, "parent_audit": parent, "note": "Proposal only. Human/orchestrator reviews + applies. Stewart cannot change doctrine (RULE-027)."}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.PROPOSE_CORRECTION(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- BOB_EXECUTE — Bob, the Building-stage agent (INIT-36 / E-014). Takes a RESEARCH artifact,
-- gathers grounding (research + Guppi + Bond + BOB_AGENT web brief), authors a SECTION-KEYED
-- NARRATIVE to a governed NARRATIVE_TEMPLATE (rubric generated from the template, not hardcoded),
-- default single Sonnet-class writer (MODEL_CATALOG ROLE-based; opt-in P_BAKEOFF for the full
-- multi-model bake-off), cross-judges (independent models, RULE-023), conform-or-repair against
-- the template gate, and writes the winner via CREATE_NARRATIVE (template-enforced, no drift).
-- Two overloads: 5-arg (template + bakeoff knobs) + 3-arg stub (CoWork/legacy: auto-template,
-- single-writer). Distinct arities so they coexist (defaults collapse into one proc in Snowflake).
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(P_RESEARCH_ID VARCHAR, P_TARGET VARCHAR, P_ANGLE VARCHAR, P_TEMPLATE VARCHAR, P_BAKEOFF BOOLEAN)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

def _agent_text(resp):
    try:
        j = json.loads(resp)
        parts = [it.get("text", "") for it in j.get("content", []) if isinstance(it, dict) and it.get("type") == "text"]
        if parts:
            return "\n".join(parts)
    except Exception:
        pass
    return resp

def _parse_json(s):
    t = s
    for _ in range(3):
        if isinstance(t, dict):
            return t
        if not isinstance(t, str):
            return None
        ts = t.strip()
        if ts.startswith("```"):
            ts = ts.strip("`")
            if ts[:4].lower() == "json":
                ts = ts[4:]
            ts = ts.strip()
        v = None
        try:
            v = json.loads(ts, strict=False)
        except Exception:
            if "{" in ts and "}" in ts:
                try:
                    v = json.loads(ts[ts.find("{"):ts.rfind("}")+1], strict=False)
                except Exception:
                    v = None
        if isinstance(v, dict):
            return v
        if isinstance(v, str):
            t = v; continue
        return None
    return None

def _ai(session, model, prompt):
    r = session.sql("SELECT AI_COMPLETE('" + model + "', ?) AS R", params=[prompt]).collect()
    return str(r[0]["R"]) if r and r[0]["R"] is not None else None

def run(session, p_research_id, p_target, p_angle, p_template, p_bakeoff):
    p_bakeoff = bool(p_bakeoff)
    rows = session.sql(
        "SELECT TITLE, PARENT_ID, PRODUCT_ID, COALESCE(CONTENT:synthesis::string, TO_JSON(CONTENT)) AS SYN, CONTENT:conflicts::string AS CONFLICTS "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[p_research_id]).collect()
    if not rows:
        return {"error": "research not found", "id": p_research_id}
    init_id = rows[0]["PARENT_ID"]; synthesis = rows[0]["SYN"] or ""
    conflicts = rows[0]["CONFLICTS"] or ""; product_id = rows[0]["PRODUCT_ID"]
    target = p_target or rows[0]["TITLE"]; angle = p_angle or ""
    is_internal = (str(product_id or "").lower() == "guppi") or ("internal" in (angle or "").lower()) or ("for guppi" in (angle or "").lower())

    # Governed structure (E-014). Default by audience; overridable via P_TEMPLATE. Guard the
    # Snowpark None->'None' bind: treat blank/'none'/'null' as unset.
    if isinstance(p_template, str) and p_template.strip().lower() in ("", "none", "null"):
        p_template = None
    template = (p_template or ("internal_plan" if is_internal else "position"))
    template = str(template).strip() or ("internal_plan" if is_internal else "position")
    trows = session.sql("SELECT SECTION_KEY, HEADING, HINT FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE WHERE TEMPLATE = ? ORDER BY ORD", params=[template]).collect()
    if not trows:
        return {"error": "unknown narrative template for Bob", "template": template}
    section_keys = [r["SECTION_KEY"] for r in trows]
    spec_lines = "\n".join(["- " + r["SECTION_KEY"] + " (" + r["HEADING"] + "): " + (r["HINT"] or "") for r in trows])

    gup = ""
    if init_id:
        ir = session.sql("SELECT TITLE, COALESCE(CONTENT:hypothesis::string,'') AS H FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[init_id]).collect()
        if ir:
            gup = "INITIATIVE: " + (ir[0]["TITLE"] or "") + "\nHYPOTHESIS: " + (ir[0]["H"] or "")
    bond = ""
    try:
        br = session.sql("SELECT KEY, LEFT(TO_JSON(CONTENT),500) AS C FROM THE_BOND.PUBLIC.MEMORY_STORE WHERE ARRAY_CONTAINS(?::variant, TAGS) ORDER BY CREATED_AT DESC LIMIT 3",
            params=[(target.split()[0].lower() if target else "bob")]).collect()
        bond = "\n".join(["BOND[" + (x["KEY"] or "") + "]: " + (x["C"] or "") for x in br])
    except Exception:
        bond = ""
    brief = ""
    try:
        msg = json.dumps({"messages": [{"role": "user", "content": [{"type": "text", "text": "TARGET: " + target + "\n\nRESEARCH SUMMARY:\n" + synthesis[:6000]}]}]})
        ar = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)", params=["GUPPIWHEEL.PUBLIC.BOB_AGENT", msg]).collect()
        brief = _agent_text(str(ar[0][0]) if ar else "")
    except Exception as e:
        brief = "(grounding agent unavailable: " + str(e)[:200] + ")"

    guppi_rule = ("This is INTERNAL Guppi work: you MAY and SHOULD name Guppi and its components."
                  if is_internal else "Do NOT mention the word Guppi (internal tooling stays internal).")
    conflicts_block = ("\n\nOPEN DISAGREEMENTS (from isolated swarm research - address the honest tension, do NOT paper over):\n" + conflicts[:3000]) if conflicts.strip() else ""
    grounding = ("TARGET: " + target + "\nANGLE: " + angle + "\n\nRESEARCH SYNTHESIS:\n" + synthesis[:8000] + conflicts_block +
        "\n\nGUPPI CONTEXT:\n" + gup + "\n\nBOND:\n" + bond + "\n\nWEB GROUNDING BRIEF:\n" + brief[:4000])

    def author_prompt(extra=""):
        return ("You are Bob, an engineering-first narrative builder for a Snowflake healthcare team. "
            "Using ONLY the grounding below, author a narrative for the TARGET that fulfills the ANGLE. "
            + guppi_rule + " Ground every claim in the grounding; no invented facts; use no numbers not in the grounding; be honest about limits.\n\n"
            "Return ONLY a JSON object (no markdown fences) with EXACTLY these keys, each a markdown string:\n"
            + spec_lines + "\n\nEvery listed section is REQUIRED and must be non-empty markdown. Do not add other keys.\n"
            + extra + "\nGROUNDING:\n" + grounding)

    ts = session.sql("SELECT TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISS') AS T").collect()[0]["T"]
    run_id = "BOB-" + p_research_id.replace("RES-", "").replace("-ROCKY", "") + "-" + ts

    pool = [x["MODEL_NAME"] for x in session.sql("SELECT MODEL_NAME FROM GUPPIWHEEL.PUBLIC.MODEL_CATALOG WHERE ENABLED AND ROLE IN ('authoring','both') ORDER BY MODEL_NAME").collect()]
    judges = [x["MODEL_NAME"] for x in session.sql("SELECT MODEL_NAME FROM GUPPIWHEEL.PUBLIC.MODEL_CATALOG WHERE ENABLED AND ROLE IN ('judge','both') ORDER BY MODEL_NAME").collect()]
    if not pool:
        pool = [x["MODEL_NAME"] for x in session.sql("SELECT MODEL_NAME FROM GUPPIWHEEL.PUBLIC.MODEL_CATALOG WHERE ENABLED ORDER BY MODEL_NAME").collect()]
    # Default single writer = Sonnet-class (RULE-023 governed; not Opus). Opt-in bake-off = whole pool.
    primary = next((m for m in pool if "sonnet" in m.lower()), (pool[0] if pool else None))
    writers = pool if p_bakeoff else ([primary] if primary else pool[:1])

    def parse_sections(txt):
        obj = _parse_json(txt)
        if not isinstance(obj, dict):
            return None
        secs = {k: obj.get(k) for k in section_keys if isinstance(obj.get(k), str) and obj.get(k).strip()}
        return secs or None

    def preview(secs):
        return "\n\n".join(["## " + r["HEADING"] + "\n\n" + secs.get(r["SECTION_KEY"], "") for r in trows if secs.get(r["SECTION_KEY"])])

    candidates = {}
    for m in writers:
        try:
            txt = _ai(session, m, author_prompt())
        except Exception:
            txt = None
        secs = parse_sections(txt) if txt else None
        if secs:
            candidates[m] = secs
            session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.BOB_BAKEOFF_CANDIDATES (RUN_ID,RESEARCH_ID,MODEL_NAME,NARRATIVE) SELECT ?,?,?,?",
                        params=[run_id, p_research_id, m, json.dumps(secs)]).collect()
    if not candidates:
        return {"error": "no candidates produced", "run_id": run_id, "template": template}

    judge_rubric = ("You are TARS, an INDEPENDENT trust auditor. Score the NARRATIVE for the TARGET on trust using ONLY "
        "the GROUNDING as ground truth. Penalize claims beyond the grounding, a missing honest boundary, vagueness, or "
        "hallucination. Reward grounded specificity, honesty about weak fit, and clear structure. Return ONLY a JSON "
        "object: {\"trust\": <0..1 float>, \"c_signals\": <int>, \"d_signals\": <int>, \"notes\": \"<one sentence>\"}.\n\n")
    scores = {}
    for author, secs in candidates.items():
        scores[author] = []
        pv = preview(secs)
        for judge in judges:
            if judge == author:
                continue
            jp = judge_rubric + "GROUNDING:\n" + grounding[:8000] + "\n\nNARRATIVE (author hidden):\n" + pv[:6000]
            try:
                obj = _parse_json(_ai(session, judge, jp))
            except Exception:
                obj = None
            if isinstance(obj, dict) and obj.get("trust") is not None:
                try:
                    scores[author].append({"judge": judge, "trust": float(obj.get("trust")),
                        "c": int(float(obj.get("c_signals", 0) or 0)), "d": int(float(obj.get("d_signals", 0) or 0)),
                        "notes": str(obj.get("notes", ""))[:300]})
                except Exception:
                    pass

    results = []; audit_ids = []
    for author in candidates:
        js = scores.get(author, [])
        avg = round(sum(j["trust"] for j in js) / len(js), 4) if js else 0.0
        results.append({"model": author, "avg_trust": avg, "n_judges": len(js)})
        content = {"target": target, "score": avg, "c_signals": sum(j["c"] for j in js),
            "d_signals": sum(j["d"] for j in js), "total_checks": len(js), "status": "COMPLETE",
            "author_model": author, "run_id": run_id,
            "findings": [{"judge": j["judge"], "trust": j["trust"], "notes": j["notes"]} for j in js]}
        meta = {"audit_kind": "TARS", "author_model": author, "run_id": run_id, "source": "bob-bakeoff",
            "judges": [{"model": j["judge"], "trust": j["trust"]} for j in js]}
        aid = ("AUDIT-" + run_id + "-" + author.replace("-", "").replace(".", ""))[:60]
        try:
            session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('AUDIT', ?, NULL, ?, NULL, 'Built', '[\"tars\",\"bob\",\"bakeoff\"]', ?, ?)",
                params=["TARS bake-off: " + author + " on " + target[:50], json.dumps(content), aid, json.dumps(meta)]).collect()
            audit_ids.append(aid)
        except Exception:
            pass

    results.sort(key=lambda x: (-x["avg_trust"], x["model"]))
    winner = results[0]["model"]; win_secs = candidates[winner]

    # Conform-or-repair: winner must pass the template gate. One repair retry, else fail loud.
    def validate(secs):
        c = dict(secs); c["template"] = template
        vr = session.sql("CALL GUPPIWHEEL.PUBLIC.VALIDATE_NARRATIVE_CONTENT(?, ?)", params=[json.dumps(c), template]).collect()
        return json.loads(str(vr[0][0])) if vr and vr[0][0] is not None else {}
    v = validate(win_secs)
    if v.get("error"):
        try:
            fix = _ai(session, winner, author_prompt("PRIOR ATTEMPT FAILED VALIDATION: " + json.dumps(v) + ". Return corrected JSON with ALL required sections non-empty.\n"))
            fixed = parse_sections(fix)
            if fixed:
                win_secs = fixed; v = validate(win_secs)
        except Exception:
            pass
    if v.get("error"):
        return {"error": "winner failed template validation after repair", "detail": v, "run_id": run_id, "template": template, "results": results}

    loc_judge = next((m for m in judges if m != winner), (judges[0] if judges else winner))
    win_preview = preview(win_secs)
    loc_prompt = ("You are an INDEPENDENT claim auditor. Decompose the NARRATIVE into atomic factual claims. "
        "Judge EACH claim ONLY against the GROUNDING: 'grounded'/'unsupported'/'contradicted'. Return ONLY a raw JSON array, each "
        "{\"claim\":\"<short quote>\",\"verdict\":\"grounded|unsupported|contradicted\",\"evidence\":\"<grounding quote or none>\"}.\n\n"
        "GROUNDING:\n" + grounding[:8000] + "\n\nNARRATIVE:\n" + win_preview[:6000])
    claims = []
    try:
        lt = _ai(session, loc_judge, loc_prompt) or ""
        i = lt.find("["); k = lt.rfind("]")
        if i >= 0 and k > i:
            claims = json.loads(lt[i:k+1], strict=False)
    except Exception:
        claims = []
    claims = [c for c in claims if isinstance(c, dict)][:40]
    unsupported = sum(1 for c in claims if str(c.get("verdict", "")).lower() == "unsupported")
    contradicted = sum(1 for c in claims if str(c.get("verdict", "")).lower() == "contradicted")
    localization = {"judge_model": loc_judge, "n_claims": len(claims), "n_unsupported": unsupported, "n_contradicted": contradicted, "claims": claims}

    mode = "bakeoff" if p_bakeoff else "single-writer"
    nar_meta = {"winner_model": winner, "run_id": run_id, "bakeoff": results,
        "grounding": {"research_id": p_research_id, "agent": "BOB_AGENT", "bond": True},
        "no_guppi_mention": (not is_internal), "built_by": "BOB_EXECUTE", "template": template,
        "mode": mode, "claim_localization": localization}
    title = ("Bob: " + target[:70]) if is_internal else ("Bob: " + target[:70] + " on Snowflake (position)")
    try:
        cr = session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_NARRATIVE(?, ?, ?, ?, ?, ?)",
            params=[template, title, json.dumps(win_secs), init_id, product_id, json.dumps(nar_meta)]).collect()
        nar_res = str(cr[0][0]) if cr else None
        try:
            nar_id = json.loads(nar_res).get("artifact_id") if nar_res else None
        except Exception:
            nar_id = nar_res
    except Exception as e:
        return {"error": "winner write failed: " + str(e)[:300], "run_id": run_id, "results": results}

    return {"run_id": run_id, "winner_model": winner, "template": template, "mode": mode, "results": results,
        "narrative_id": nar_id, "audit_ids": audit_ids,
        "localization": {"judge": loc_judge, "n_claims": len(claims), "unsupported": unsupported, "contradicted": contradicted}}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(VARCHAR,VARCHAR,VARCHAR,VARCHAR,BOOLEAN) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(VARCHAR,VARCHAR,VARCHAR,VARCHAR,BOOLEAN) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- 3-arg stub (CoWork/legacy paved road): auto-template + single-writer. Passes '' (not None) for
-- template to dodge the Snowpark None->'None' bind; distinct arity from the 5-arg so both coexist.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(P_RESEARCH_ID VARCHAR, P_TARGET VARCHAR, P_ANGLE VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
def run(session, p_research_id, p_target, p_angle):
    r = session.sql("CALL GUPPIWHEEL.PUBLIC.BOB_EXECUTE(?, ?, ?, '', FALSE)", params=[p_research_id, p_target, p_angle]).collect()
    return r[0][0] if r else None
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.BOB_EXECUTE(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR; -- Bob is EXECUTE AS OWNER; contributors invoke the build step via the governed proc (RULE-028)

-- =============================================================================
-- MERGE_ARTIFACTS — reconcile a duplicate artifact into a survivor.
-- TIER: Default (works on clone; adjust to taste).
-- RULE-027: this proc sets SUPERSEDED_BY -> ORCHESTRATOR/ADMIN authority ONLY.
--   NEVER grant to sub-agent/contributor roles (that would let a sub-agent kill
--   doctrine/serving surfaces). Admin-only by grant + by intent.
-- Behavior: re-parents the duplicate's DIRECT children onto the survivor, points
--   the duplicate's SUPERSEDED_BY at the survivor (removing it from *_CURRENT_V
--   views), and writes provenance breadcrumbs on both. Supersede-don't-destroy:
--   nothing is deleted. Does NOT repoint metadata cross-refs (e.g. depends_on).
-- Idempotent: refuses if the duplicate is already superseded, or if the survivor
--   is itself superseded (merge only into a live artifact).
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.MERGE_ARTIFACTS(
  P_DUPLICATE_ID VARCHAR,
  P_SURVIVOR_ID  VARCHAR,
  P_REASON       VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
BEGIN
  IF (:P_DUPLICATE_ID = :P_SURVIVOR_ID) THEN
    RETURN 'ERROR: duplicate and survivor are the same id';
  END IF;

  LET dup_cnt INT := (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_DUPLICATE_ID);
  LET surv_cnt INT := (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_SURVIVOR_ID);
  IF (:dup_cnt = 0) THEN RETURN 'ERROR: duplicate not found: ' || :P_DUPLICATE_ID; END IF;
  IF (:surv_cnt = 0) THEN RETURN 'ERROR: survivor not found: ' || :P_SURVIVOR_ID; END IF;

  LET dup_sup VARCHAR := (SELECT SUPERSEDED_BY FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_DUPLICATE_ID);
  LET surv_sup VARCHAR := (SELECT SUPERSEDED_BY FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_SURVIVOR_ID);
  IF (:dup_sup IS NOT NULL) THEN RETURN 'ERROR: duplicate already superseded by ' || :dup_sup; END IF;
  IF (:surv_sup IS NOT NULL) THEN RETURN 'ERROR: survivor is itself superseded by ' || :surv_sup || ' - merge into a live artifact'; END IF;

  LET child_count INT := (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :P_DUPLICATE_ID);

  -- 1) re-parent the duplicate's direct children onto the survivor
  UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
     SET PARENT_ID = :P_SURVIVOR_ID, UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE PARENT_ID = :P_DUPLICATE_ID;

  -- 2) supersede the duplicate + breadcrumb
  UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
     SET SUPERSEDED_BY = :P_SURVIVOR_ID,
         METADATA = OBJECT_INSERT(
                      OBJECT_INSERT(
                        OBJECT_INSERT(COALESCE(METADATA, OBJECT_CONSTRUCT()),
                                      'reconciled_into', :P_SURVIVOR_ID, TRUE),
                        'reconciled_reason', COALESCE(:P_REASON, 'merged duplicate via MERGE_ARTIFACTS'), TRUE),
                      'reconciled_at', CURRENT_TIMESTAMP()::STRING, TRUE),
         UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE ID = :P_DUPLICATE_ID;

  -- 3) breadcrumb on the survivor (append to absorbed_duplicates array)
  UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
     SET METADATA = OBJECT_INSERT(COALESCE(METADATA, OBJECT_CONSTRUCT()),
                      'absorbed_duplicates',
                      ARRAY_APPEND(COALESCE(METADATA:absorbed_duplicates::ARRAY, ARRAY_CONSTRUCT()), :P_DUPLICATE_ID),
                      TRUE),
         UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE ID = :P_SURVIVOR_ID;

  RETURN 'OK: merged ' || :P_DUPLICATE_ID || ' -> ' || :P_SURVIVOR_ID
      || ' (' || :child_count || ' child(ren) re-parented; duplicate superseded)';
END;

GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.MERGE_ARTIFACTS(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- ENSURE_NARRATIVE_HTML — create-if-missing launchable HTML for a NARRATIVE.
-- Open-button robustness: if the narrative has no staged HTML (or a dangling
-- stage_path), render a clean styled doc from CONTENT, put_stream it to
-- @ARTIFACT_ASSETS/narrative/auto/<ID>.html, and set metadata.launch. Idempotent:
-- if the referenced file already exists on the stage, it is reused untouched.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.ENSURE_NARRATIVE_HTML(P_ARTIFACT_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, io, re

def _esc(s):
    return (str(s) if s is not None else "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")

def _inline(t):
    # t is already HTML-escaped
    t = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2" target="_blank">\1</a>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', t)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    return t

def _is_table_sep(line):
    s = line.strip()
    if not s.startswith("|"):
        return False
    cells = [c.strip() for c in s.strip("|").split("|")]
    return len(cells) > 0 and all(re.match(r'^:?-{3,}:?$', c or '') for c in cells)

def _table_html(lines):
    header = [c.strip() for c in lines[0].strip().strip("|").split("|")]
    rows = []
    for raw in lines[2:]:
        cells = [c.strip() for c in raw.strip().strip("|").split("|")]
        while len(cells) < len(header):
            cells.append("")
        rows.append(cells[:len(header)])
    out = ["<table><thead><tr>"]
    for h in header:
        out.append("<th>" + _inline(_esc(h)) + "</th>")
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>")
        for cell in row:
            out.append("<td>" + _inline(_esc(cell)) + "</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)

def _md(md):
    lines = (md or "").split("\n")
    out = []
    mode = None
    para = []
    i = 0
    def flush_para():
        if para:
            out.append("<p>" + _inline(" ".join(para)) + "</p>")
            para.clear()
    def close_list():
        nonlocal mode
        if mode == 'ul': out.append("</ul>")
        elif mode == 'ol': out.append("</ol>")
        mode = None
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        if line.strip().startswith("```"):
            flush_para(); close_list()
            if mode == 'pre':
                out.append("</code></pre>"); mode = None
            else:
                out.append("<pre><code>"); mode = 'pre'
            i += 1
            continue
        if mode == 'pre':
            out.append(_esc(raw)); i += 1; continue
        s = line.strip()
        if not s:
            flush_para(); close_list(); i += 1; continue
        if i + 1 < len(lines) and s.startswith("|") and _is_table_sep(lines[i+1]):
            flush_para(); close_list()
            tbl = [line, lines[i+1].rstrip()]
            j = i + 2
            while j < len(lines):
                nxt = lines[j].rstrip()
                if nxt.strip().startswith("|"):
                    tbl.append(nxt)
                    j += 1
                    continue
                break
            out.append(_table_html(tbl))
            i = j
            continue
        m = re.match(r'^(#{1,6})\s+(.*)$', s)
        if m:
            flush_para(); close_list()
            lvl = min(len(m.group(1)), 4)
            out.append("<h%d>%s</h%d>" % (lvl, _inline(_esc(m.group(2))), lvl)); i += 1; continue
        if re.match(r'^(---+|\*\*\*+)$', s):
            flush_para(); close_list(); out.append("<hr>"); i += 1; continue
        mb = re.match(r'^[-*]\s+(.*)$', s)
        if mb:
            flush_para()
            if mode != 'ul': close_list(); out.append("<ul>"); mode = 'ul'
            out.append("<li>" + _inline(_esc(mb.group(1))) + "</li>"); i += 1; continue
        mo = re.match(r'^\d+\.\s+(.*)$', s)
        if mo:
            flush_para()
            if mode != 'ol': close_list(); out.append("<ol>"); mode = 'ol'
            out.append("<li>" + _inline(_esc(mo.group(1))) + "</li>"); i += 1; continue
        if mode in ('ul','ol'): close_list()
        para.append(_esc(s))
        i += 1
    flush_para(); close_list()
    if mode == 'pre': out.append("</code></pre>")
    return "\n".join(out)

def _obj(v):
    if v is None: return {}
    if isinstance(v,(dict,list)): return v
    try: return json.loads(v)
    except Exception: return {}

def run(session, p_artifact_id):
    rows = session.sql("SELECT TYPE, TITLE, STAGE, OWNER, PARENT_ID, CONTENT, METADATA "
                       "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ? AND SUPERSEDED_BY IS NULL",
                       params=[p_artifact_id]).collect()
    if not rows: return {"error":"artifact not found","id":p_artifact_id}
    r = rows[0]
    if r["TYPE"] != "NARRATIVE": return {"error":"not a narrative","id":p_artifact_id,"type":r["TYPE"]}
    content = _obj(r["CONTENT"]); meta = _obj(r["METADATA"]) or {}
    launch = meta.get("launch") or {}
    existing = launch.get("stage_path") or ""

    def _exists(sp):
        if not sp or not sp.startswith("@"): return False
        try:
            return len(session.sql("LIST " + sp).collect()) > 0
        except Exception:
            return False

    if _exists(existing):
        return {"artifact_id":p_artifact_id,"stage_path":existing,"created":False,"note":"existing html reused"}

    # E-014: template-stamped narratives render section-by-section from NARRATIVE_TEMPLATE
    # (heading from the template, body from that section's markdown) so the look is single-sourced
    # from the same governed table as the structure. Legacy/templateless narratives fall back to body_md.
    body = None
    tmpl = content.get("template")
    if tmpl:
        try:
            trows = session.sql("SELECT SECTION_KEY, HEADING FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE WHERE TEMPLATE = ? ORDER BY ORD", params=[str(tmpl)]).collect()
        except Exception:
            trows = []
        if trows:
            segs = []
            for tr in trows:
                sv = content.get(tr["SECTION_KEY"])
                if isinstance(sv, str) and sv.strip():
                    segs.append("<h2>" + _esc(tr["HEADING"]) + "</h2>\n" + _md(sv))
            if segs:
                body = "\n".join(segs)
    if body is None:
        md = content.get("body_md") or ""
        if not md:
            # Defensive (post-normalization this should not fire): compose losslessly via the shared
            # normalizer instead of raw-dumping JSON. Handles pre-migration cached rows on the fly.
            try:
                _rr = session.sql("SELECT TO_JSON(GUPPIWHEEL.PUBLIC.NORMALIZE_ARTIFACT_CONTENT(PARSE_JSON(?), 'NARRATIVE')) AS J",
                                  params=[json.dumps(content)]).collect()
                if _rr and _rr[0]["J"]:
                    md = (json.loads(_rr[0]["J"]).get("body_md") or "")
            except Exception:
                md = ""
        if not md:
            md = "_(empty narrative)_"
        body = _md(md)
    title = r["TITLE"] or p_artifact_id
    bits = [_esc(r["STAGE"])]
    if r["OWNER"]: bits.append("owner " + _esc(r["OWNER"]))
    if r["PARENT_ID"]: bits.append("parent " + _esc(r["PARENT_ID"]))
    meta_line = " &middot; ".join([b for b in bits if b])
    html = ("<!DOCTYPE html><html><head><meta charset=utf-8>"
        "<meta name=viewport content=\"width=device-width,initial-scale=1\">"
        "<title>" + _esc(title) + "</title><style>"
        "*{box-sizing:border-box;margin:0;padding:0}"
        "body{font-family:'Segoe UI',Helvetica,Arial,sans-serif;background:#0a0a12;color:#e2e8f0;line-height:1.6}"
        ".wrap{max-width:860px;margin:0 auto;padding:0 0 80px}"
        ".cover{background:linear-gradient(135deg,#0B1F33,#12131e 70%);border-bottom:3px solid #29B5E8;padding:30px 44px}"
        ".cover .id{color:#29B5E8;font-size:.7rem;font-weight:800;letter-spacing:.08em;text-transform:uppercase}"
        ".cover h1{font-size:1.7rem;margin:6px 0 8px;color:#fff;line-height:1.25}"
        ".cover .meta{color:#8888a0;font-size:.75rem}"
        ".body{padding:30px 44px}"
        ".body h1{font-size:1.5rem;color:#fff;margin:26px 0 10px;border-bottom:1px solid #1e2030;padding-bottom:6px}"
        ".body h2{font-size:1.2rem;color:#29B5E8;margin:22px 0 8px}"
        ".body h3{font-size:1.02rem;color:#14B8A6;margin:18px 0 6px}"
        ".body h4{font-size:.92rem;color:#cbd5e1;margin:14px 0 4px}"
        ".body p{margin:10px 0;color:#cbd5e1}"
        ".body ul,.body ol{margin:10px 0 10px 26px;color:#cbd5e1}.body li{margin:4px 0}"
        ".body table{width:100%;border-collapse:collapse;margin:14px 0;background:#12131e;border:1px solid #1e2030;border-radius:8px;overflow:hidden;display:block;overflow-x:auto}"
        ".body thead{background:#171826}.body th,.body td{padding:10px 12px;border-bottom:1px solid #1e2030;text-align:left;vertical-align:top;min-width:160px}"
        ".body th{font-size:.72rem;letter-spacing:.05em;text-transform:uppercase;color:#8aa0c4}.body tbody tr:last-child td{border-bottom:none}"
        ".body a{color:#29B5E8;text-decoration:none}.body a:hover{text-decoration:underline}"
        ".body strong{color:#fff}"
        ".body code{background:#171826;border:1px solid #1e2030;border-radius:4px;padding:1px 5px;font-size:.88em}"
        ".body pre{background:#12131e;border:1px solid #1e2030;border-radius:8px;padding:14px;overflow:auto;margin:12px 0}"
        ".body pre code{background:none;border:none;padding:0;white-space:pre}"
        ".body hr{border:none;border-top:1px solid #1e2030;margin:20px 0}"
        ".foot{text-align:center;color:#5a5a72;font-size:.72rem;margin-top:30px;padding:0 44px}"
        "</style></head><body><div class=wrap>"
        "<div class=cover><div class=id>" + _esc(p_artifact_id) + " &middot; NARRATIVE</div>"
        "<h1>" + _esc(title) + "</h1><div class=meta>" + meta_line + "</div></div>"
        "<div class=body>" + body + "</div>"
        "<div class=foot>Generated by GuppiWheel &middot; bytes in @GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS &middot; source of truth is the wheel</div>"
        "</div></body></html>")
    target = "@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/narrative/auto/" + p_artifact_id + ".html"
    session.file.put_stream(io.BytesIO(html.encode("utf-8")), target, auto_compress=False, overwrite=True)
    meta["launch"] = {"app_type":"static_html","stage_path":target,"default_ttl_seconds":3600}
    session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET METADATA = PARSE_JSON(?), UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?",
                params=[json.dumps(meta), p_artifact_id]).collect()
    return {"artifact_id":p_artifact_id,"stage_path":target,"created":True}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ENSURE_NARRATIVE_HTML(VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ENSURE_NARRATIVE_HTML(VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- =============================================================================
-- RESOLVE_APP_METRIC — launch-time metric resolver for APP artifacts (PLAT-D008a).
-- Reads metadata:metric_exports off a published APP, applies default_filters +
-- caller overrides to the metric's query_template, runs it EXECUTE AS OWNER and
-- returns the scalar value (+ unit/is_simulated/resolved_query). The viewer calls
-- this to render live app KPIs. Was created live 2026-07-08 but never seeded — this
-- entry ends that drift so it survives a fresh install / re-seed.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RESOLVE_APP_METRIC(
  P_APP_ID VARCHAR, P_METRIC_NAME VARCHAR, P_FILTER_OVERRIDES VARIANT)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
def run(session, app_id, metric_name, overrides):
    r = session.sql("SELECT metadata:metric_exports AS me FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE id = ? AND superseded_by IS NULL", params=[app_id]).collect()
    if not r or r[0]["ME"] is None:
        return {"error": "app or metric_exports not found", "app_id": app_id}
    me = r[0]["ME"]
    me = json.loads(me) if isinstance(me, str) else me
    metric = next((x for x in me if x.get("name") == metric_name), None)
    if metric is None:
        return {"error": "metric not found", "app_id": app_id, "metric": metric_name,
                "available": [x.get("name") for x in me]}
    filters = dict(metric.get("default_filters") or {})
    ov = overrides
    if isinstance(ov, str):
        ov = json.loads(ov) if ov.strip() else {}
    if isinstance(ov, dict):
        filters.update(ov)
    q = metric.get("query_template", "")
    for k, v in filters.items():
        q = q.replace("{{" + str(k) + "}}", str(v))
    rows = session.sql(q).collect()
    value = rows[0][0] if rows and len(rows[0]) > 0 else None
    try:
        value = float(value)
    except (TypeError, ValueError):
        pass
    return {"app_id": app_id, "metric": metric_name, "value": value,
            "unit": metric.get("unit"), "is_simulated": metric.get("is_simulated"),
            "filters": filters, "resolved_query": q}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RESOLVE_APP_METRIC(VARCHAR,VARCHAR,VARIANT) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RESOLVE_APP_METRIC(VARCHAR,VARCHAR,VARIANT) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RESOLVE_APP_METRIC(VARCHAR,VARCHAR,VARIANT) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- PUBLISH_PLUGIN_VERSION — the governed, regression-proof stamp path for
-- PLUGIN_VERSION (the rule in 02_rules.sql describes this gate). Direct DML on
-- PLUGIN_VERSION stays revoked; this EXECUTE-AS-OWNER proc is the only writer.
-- v1 scope: semver validation + MONOTONICITY guard (refuses a lower version
-- unless P_FORCE) — this is what prevents a stale seed literal from regressing a
-- live install. The full manifest-compatibility gate the rule describes (dropped
-- columns/tables/procs, type narrowings, rename-without-view-shim) is a
-- documented FUTURE extension, not yet implemented here.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_PLUGIN_VERSION(
    P_VERSION VARCHAR, P_NOTES VARCHAR DEFAULT NULL, P_FORCE BOOLEAN DEFAULT FALSE)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import re

PLUGIN = 'guppi-platform'

def _key(v):
    return tuple(int(x) for x in v.split('.'))

def run(session, p_version, p_notes, p_force):
    v = (p_version or '').strip()
    if not re.match(r'^\d+\.\d+\.\d+$', v):
        return {"ok": False, "error": "invalid semver (expected N.N.N)", "given": p_version}
    cur = session.sql(
        "SELECT VERSION FROM GUPPIWHEEL.PUBLIC.PLUGIN_VERSION WHERE PLUGIN_NAME = ?",
        params=[PLUGIN]).collect()
    current = cur[0]["VERSION"] if cur else None
    if current and not p_force and _key(v) < _key(current):
        return {"ok": False, "error": "refusing version regression", "from": current, "to": v,
                "hint": "pass P_FORCE => TRUE for a deliberate rollback"}
    notes = p_notes if p_notes else 'published via PUBLISH_PLUGIN_VERSION'
    session.sql(
        "MERGE INTO GUPPIWHEEL.PUBLIC.PLUGIN_VERSION t "
        "USING (SELECT ? AS PLUGIN_NAME, ? AS VERSION) s ON t.PLUGIN_NAME = s.PLUGIN_NAME "
        "WHEN MATCHED THEN UPDATE SET VERSION = s.VERSION, INSTALLED_AT = CURRENT_TIMESTAMP(), "
        "INSTALLED_BY = CURRENT_USER(), NOTES = ? "
        "WHEN NOT MATCHED THEN INSERT (PLUGIN_NAME, VERSION, NOTES) VALUES (s.PLUGIN_NAME, s.VERSION, ?)",
        params=[PLUGIN, v, notes, notes]).collect()
    return {"ok": True, "plugin": PLUGIN, "from": current, "to": v, "forced": bool(p_force)}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.PUBLISH_PLUGIN_VERSION(VARCHAR, VARCHAR, BOOLEAN) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- ADMIN REPAIR DOORS — governed alternatives to hand-written DML.
--
-- Every one of these exists because a real incident proved that leaving the fix
-- to raw SQL is how the substrate drifts. They are ADMIN-gated BY GRANT rather
-- than by in-proc role checks: inside EXECUTE AS OWNER, CURRENT_USER() is the
-- caller but CURRENT_ROLE() is the OWNER's role, so role introspection inside the
-- body is unreliable. Grant-based authorization is deterministic — if you can
-- call it, you are authorized.
-- =============================================================================

-- RESYNC_ID_SERIES — forward-only repair of a desynced ID counter.
-- Incident: a hardcoded `UPDATE ID_CONVENTIONS SET NEXT_SEQ = 40` moved the NARRATIVE
-- counter BACKWARD by 55, so the allocator then re-issued live IDs and produced a
-- duplicate NAR-39. This proc recomputes the counter from the data and REFUSES to move
-- it backward, which is the property the manual UPDATE lacked.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RESYNC_ID_SERIES(P_ENTITY VARCHAR, P_REASON VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Forward-only repair of a desynced ID_CONVENTIONS counter. Recomputes NEXT_SEQ from the max sequential ID actually present and refuses to move the counter backward (the Aug-14 failure mode). Requires a reason; logs to VIOLATIONS under RULE-029. ADMIN-gated by grant.'
EXECUTE AS OWNER
AS
$$
def run(session, p_entity, p_reason):
    ent = (p_entity or "").strip().upper()
    if not ent:
        return {"error": "P_ENTITY required"}
    if not (p_reason or "").strip():
        return {"error": "P_REASON required (audit trail)"}

    reg = session.sql(
        "SELECT ID_PREFIX, NEXT_SEQ FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = ?",
        params=[ent]
    ).collect()
    if not reg:
        return {"error": "unknown entity (not in ID_CONVENTIONS)", "entity": ent}
    prefix = reg[0]["ID_PREFIX"]
    cur = reg[0]["NEXT_SEQ"]
    if prefix is None:
        return {"error": "entity has no ID_PREFIX (human-readable series)", "entity": ent}

    # ONLY the gap-free sequential series counts: strictly PREFIX + digits (e.g. NAR-96).
    # Must NOT match slug/date-suffixed IDs (NAR-RADAR-20260702, NAR-CHANGELOG-3.5.0)
    # or suffix-tagged IDs (RES-111-ROCKY). NOTE: REGEXP_LIKE is a FULL-STRING match in
    # Snowflake -- an earlier version used REGEXP_SUBSTR(ID,'[0-9]+$'), which matched the
    # date-suffixed IDs and set the counter to 20260703.
    mx = session.sql(
        "SELECT COALESCE(MAX(TO_NUMBER(SUBSTR(ID, LENGTH(?)+1))),0) AS M "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS "
        "WHERE ID LIKE ? AND REGEXP_LIKE(SUBSTR(ID, LENGTH(?)+1), '[0-9]+')",
        params=[prefix, prefix + '%', prefix]
    ).collect()[0]["M"]

    target = int(mx) + 1

    # Forward-only: refuse the Aug-14 failure mode (hardcoded backward SET).
    if cur is not None and target <= int(cur):
        return {"entity": ent, "prefix": prefix, "next_seq": int(cur),
                "actual_max": int(mx), "changed": False,
                "note": "already at or ahead of data; refusing to move counter backward"}

    session.sql(
        "UPDATE GUPPIWHEEL.PUBLIC.ID_CONVENTIONS SET NEXT_SEQ = ? WHERE ENTITY = ?",
        params=[target, ent]
    ).collect()

    session.sql(
        "INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS, OVERRIDE_REASON) "
        "SELECT 'RULE-029', ?, 'acknowledged', ?",
        params=['ID_SERIES:' + ent,
                'RESYNC_ID_SERIES ' + str(cur) + ' -> ' + str(target) + ' (max=' + str(mx) + '). ' + p_reason]
    ).collect()

    return {"entity": ent, "prefix": prefix, "from_next_seq": (int(cur) if cur is not None else None),
            "to_next_seq": target, "actual_max": int(mx), "changed": True, "reason": p_reason}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RESYNC_ID_SERIES(VARCHAR, VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- RETAG_PRODUCT — governed change of ARTIFACTS.PRODUCT_ID.
-- Closes the last gap that forced raw DML: UPDATE_OWN_ARTIFACT covers only TITLE/CONTENT/TAGS, so
-- correcting a mis-tagged product previously required a hand-written UPDATE — exactly the pattern
-- DIRECT_DML_TRIPWIRE_V flags. PRODUCT_ID drives the outbound share boundary (PRODUCT_SHARE_LEAK_V,
-- STO-SUBSTRATE-8), so a mis-tag is a confidentiality event, not cosmetic — hence ADMIN, not owner.
-- An ownership check alone would also be insufficient in practice: agent-authored artifacts (Rocky)
-- are owned by the agent, so the human curating them is never the owner.
-- PRODUCT_ID is NOT part of the birth-hash bundle, so re-tagging preserves ROW_HASH.
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RETAG_PRODUCT(P_ARTIFACT_ID VARCHAR, P_PRODUCT_ID VARCHAR, P_REASON VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Governed re-tag of ARTIFACTS.PRODUCT_ID (the outbound share boundary). Validates the target against PRODUCTS, allows explicit clearing to NULL, refuses no-ops and duplicate-ID rows, requires a reason, and logs before/after to VIOLATIONS under RULE-021. Touches PRODUCT_ID only - not part of the birth-hash bundle, so ROW_HASH stays valid. ADMIN-gated by grant.'
EXECUTE AS OWNER
AS
$$
def run(session, p_artifact_id, p_product_id, p_reason):
    aid = (p_artifact_id or "").strip()
    if not aid:
        return {"error": "P_ARTIFACT_ID required"}
    if not (p_reason or "").strip():
        return {"error": "P_REASON required (audit trail)"}

    rows = session.sql(
        "SELECT ID, TYPE, TITLE, OWNER, PRODUCT_ID, SUPERSEDED_BY "
        "FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", params=[aid]
    ).collect()
    if not rows:
        return {"error": "artifact not found", "id": aid}
    # Guard the same hazard BACKFILL_UNHASHED has: an UPDATE ... WHERE ID = ? would hit BOTH
    # rows of a duplicate pair and corrupt the legitimate one. Refuse until the dup is resolved.
    if len(rows) > 1:
        return {"error": "duplicate ID present; resolve the duplicate before retagging",
                "id": aid, "rows": len(rows)}

    cur = rows[0]["PRODUCT_ID"]

    # Empty / NULL / 'null' clears the tag -- a valid state (artifact belongs to no product).
    raw = (p_product_id or "").strip()
    if raw == "" or raw.lower() == "null":
        target = None
    else:
        chk = session.sql(
            "SELECT PRODUCT_ID FROM GUPPIWHEEL.PUBLIC.PRODUCTS WHERE LOWER(PRODUCT_ID) = ?",
            params=[raw.lower()]
        ).collect()
        if not chk:
            allowed = [r["PRODUCT_ID"] for r in session.sql(
                "SELECT PRODUCT_ID FROM GUPPIWHEEL.PUBLIC.PRODUCTS ORDER BY PRODUCT_ID").collect()]
            return {"error": "unknown product; register it in PRODUCTS first (governance-as-data)",
                    "got": p_product_id, "allowed": allowed}
        target = chk[0]["PRODUCT_ID"]   # normalize to the registered casing

    if (cur or None) == (target or None):
        return {"id": aid, "product_id": cur, "changed": False, "note": "no-op: already tagged this way"}

    session.sql(
        "UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET PRODUCT_ID = ?, UPDATED_AT = CURRENT_TIMESTAMP() WHERE ID = ?",
        params=[target, aid]
    ).collect()

    session.sql(
        "INSERT INTO GUPPIWHEEL.PUBLIC.VIOLATIONS (RULE_ID, ARTIFACT_ID, STATUS, OVERRIDE_REASON) "
        "SELECT 'RULE-021', ?, 'acknowledged', ?",
        params=[aid, "RETAG_PRODUCT " + str(cur) + " -> " + str(target) + ". " + p_reason]
    ).collect()

    return {"id": aid, "type": rows[0]["TYPE"], "owner": rows[0]["OWNER"],
            "from_product": cur, "to_product": target, "changed": True, "reason": p_reason}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RETAG_PRODUCT(VARCHAR, VARCHAR, VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- Self-heal stamp on every seed apply. This is the SINGLE go-forward version
-- stamp and MUST equal .cortex-plugin/plugin.json version (SDLC preflight Check
-- 13.1 asserts plugin.json == this literal == live PLUGIN_VERSION). Regression-
-- proof via the guard above; equal re-stamp is idempotent.
CALL GUPPIWHEEL.PUBLIC.PUBLISH_PLUGIN_VERSION('3.21.1', 'SDLC preflight sweep fixes: restore TMG-003 to the engine seed (was live-only, so fresh installs lacked it); RULE-018 launch repair via MERGE_ARTIFACTS; publish orphan plans; skill-registry sync grant + corrected script path; NARRATIVE_TEMPLATE_ADOPTION_V gains a narrow LAUNCH-POINTER cohort so launch-pointer narratives are not false-flagged', FALSE);
