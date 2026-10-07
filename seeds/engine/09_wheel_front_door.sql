-- =============================================================================
-- 09_wheel_front_door.sql — the single operational front door (PLAT-60, v3.31.0)
-- =============================================================================
-- WHY: 2026-10-06 a two-day build recorded nothing in the wheel. The agent had
-- 50 procs, 21 skills and a dead GUPPI.* schema in its docs, so it improvised
-- (duplicate initiative, raw UPDATE on ID_CONVENTIONS). Hooks could not save it:
-- measured in CoCo Desktop, hook systemMessages are invisible to the agent.
--
-- WHAT: one verb router, WHEEL(verb, args_json). It adds NO new write path:
-- every artifact write still flows through CREATE_ARTIFACT / ADVANCE_STAGE /
-- PUBLISH_ARTIFACT / CREATE_NARRATIVE / REPARENT_ARTIFACT / UPDATE_OWN_ARTIFACT
-- (RULE-028/029). CURRENT_USER() inside EXECUTE AS OWNER is the caller, so the
-- owner-gated procs still check the real user.
--
-- Contributor verbs : context, open, story, ship, capture, plan, reparent, preview, help
-- Admin verbs       : WHEEL_ADMIN(merge | retag)  (GUPPIWHEEL_ADMIN only;
--                     wrapping them in WHEEL would launder admin power to contributors)
-- IDs (3.32.0)      : derived by CREATE_ARTIFACT (MAX+1 via ID_SERIES_V under the CHAIN_HEAD lock).
--                     No counters, so no resync. PREVIEW_NEXT_ID shows the next ID read-only.
--
-- Ownership: ACCOUNTADMIN, like every other substrate object (see 03_procs.sql).
-- =============================================================================

USE SCHEMA GUPPIWHEEL.PUBLIC;

-- Server-side session context: replaces ~/.snowflake/cortex/.guppi-platform-state.json
-- as the source of truth. Works from Desktop, CLI, agents, Slack.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.WHEEL_CONTEXT (
  USER_NAME          VARCHAR NOT NULL,
  CURRENT_INITIATIVE VARCHAR,
  CURRENT_STORY      VARCHAR,
  PRODUCT_ID         VARCHAR,
  CLIENT_SURFACE     VARCHAR,
  SET_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT PK_WHEEL_CONTEXT PRIMARY KEY (USER_NAME)
) COMMENT = 'Per-user current initiative/story/product + client. Written only by WHEEL().';

-- What each CoCo client can actually do. Data, not folklore: one row update changes
-- the guidance everywhere when a client gains a capability.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.CLIENT_CAPABILITIES (
  CLIENT_SURFACE        VARCHAR NOT NULL,
  HOOKS_RUN             BOOLEAN,
  HOOK_MESSAGES_VISIBLE BOOLEAN,
  HOOK_BLOCK_ENFORCED   BOOLEAN,
  MEMORY_INJECTED       BOOLEAN,
  VERIFIED_AT           TIMESTAMP_NTZ,
  EVIDENCE              VARCHAR,
  CONSTRAINT PK_CLIENT_CAPABILITIES PRIMARY KEY (CLIENT_SURFACE)
) COMMENT = 'Measured per-client hook/memory behaviour. Read by WHEEL(context).';

MERGE INTO GUPPIWHEEL.PUBLIC.CLIENT_CAPABILITIES t
USING (
  SELECT 'coco_desktop' CLIENT_SURFACE, TRUE HOOKS_RUN, FALSE HOOK_MESSAGES_VISIBLE, TRUE HOOK_BLOCK_ENFORCED, TRUE MEMORY_INJECTED,
         '2026-10-06'::TIMESTAMP_NTZ VERIFIED_AT,
         'Probe 2026-10-06: global+plugin hooks fire and hot-reload; cwd=workspace (relative plugin commands fail); matchers case-sensitive lowercase; systemMessage not shown to agent; block enforced but reason text not shown; hook env has no CORTEX_* (VSCODE_PID present).' EVIDENCE
  UNION ALL
  SELECT 'cli', TRUE, NULL, NULL, TRUE, NULL,
         'coco.log shows "Loaded hooks from plugins" for terminal_launcher_source=cli. Message visibility/blocking not yet measured in CLI.'
) s ON t.CLIENT_SURFACE = s.CLIENT_SURFACE
WHEN NOT MATCHED THEN INSERT VALUES (s.CLIENT_SURFACE, s.HOOKS_RUN, s.HOOK_MESSAGES_VISIBLE, s.HOOK_BLOCK_ENFORCED, s.MEMORY_INJECTED, s.VERIFIED_AT, s.EVIDENCE);

-- Which Snowflake objects belong to which product. Drives WHEEL_RECONCILE.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.PRODUCT_FOOTPRINT (
  PRODUCT_ID VARCHAR NOT NULL,
  PATTERN    VARCHAR NOT NULL,   -- ILIKE pattern matched against QUERY_TEXT
  NOTE       VARCHAR,
  CONSTRAINT PK_PRODUCT_FOOTPRINT PRIMARY KEY (PRODUCT_ID, PATTERN)
) COMMENT = 'Product -> object-name patterns for evidence-based capture (WHEEL_RECONCILE).';

-- Work that happened in Snowflake with no wheel record after it.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.CAPTURE_DEBT (
  DEBT_KEY          VARCHAR NOT NULL,   -- product|kind|user|hour bucket (dedupe)
  PRODUCT_ID        VARCHAR,
  KIND              VARCHAR,            -- DEPLOY | AGENT_RELEASE | SCHEMA
  USER_NAME         VARCHAR,
  EVENTS            NUMBER,
  FIRST_EVIDENCE_TS TIMESTAMP_LTZ,
  LAST_EVIDENCE_TS  TIMESTAMP_LTZ,
  SAMPLE_TEXT       VARCHAR,
  SAMPLE_QUERY_ID   VARCHAR,
  STATUS            VARCHAR DEFAULT 'open',   -- open | cleared
  CLEARED_BY        VARCHAR,
  CLEARED_AT        TIMESTAMP_LTZ,
  DETECTED_AT       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT PK_CAPTURE_DEBT PRIMARY KEY (DEBT_KEY)
) COMMENT = 'Evidence of build work (deploys, agent releases, schema) not yet reflected in the wheel.';

-- =============================================================================
-- WHEEL(verb, args) — the front door
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL(P_VERB VARCHAR, P_ARGS VARCHAR DEFAULT '{}')
COPY GRANTS
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Single operational front door for the wheel. Verbs: context, open, story, ship, capture, plan, reparent, help. Delegates every write to the governed procs.'
EXECUTE AS OWNER
AS
$$
import json, re

VERBS = {
  "context":  "{client} -> who/what am I working on, client capabilities, open capture debt, tripwire hits. Call first every session.",
  "open":     "{title, product, parent?, force?, reason?, hypothesis?, instructions?} -> reuse the best existing initiative (sets context); mints new only with force+reason.",
  "story":    "{title, product?, parent?, content?, stage?} -> create a STORY under context (ID allocated by CREATE_ARTIFACT).",
  "ship":     "{id?, stage?='Built', note} -> advance a story via ADVANCE_STAGE, record the note, clear matching debt.",
  "capture":  "{stage_path, title, description?, kind?='APP'|'NARRATIVE', app_type?} -> register a PUT deliverable via PUBLISH_ARTIFACT.",
  "plan":     "{title, sections{summary,context,phased_plan,risks,why_now}, parent?} -> internal_plan NARRATIVE via CREATE_NARRATIVE.",
  "reparent": "{id, parent, reason} -> REPARENT_ARTIFACT (owner-gated).",
  "preview":  "{type, product?} -> the ID CREATE_ARTIFACT would allocate next (read-only).",
  "help":     "{} -> this list.",
}
TERMINAL = ("Built", "Published", "Resolved", "RESOLVED", "Narrated", "TRACKED")

def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()

# Snowpark binds Python None as the STRING 'None' (same bug class CHANGELOG 3.9.1 fixed in
# CREATE_ARTIFACT). Bind a sentinel and NULLIF it back to a real SQL NULL.
NUL = "__WHEEL_NULL__"
def b(v):
    return NUL if v is None else v

def clean(v):
    return None if v in (None, "None", "null", "") else v

def call(session, sql, params):
    r = q(session, sql, params)
    v = r[0][0] if r else None
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return v
    return v

def me(session):
    return q(session, "SELECT CURRENT_USER()")[0][0]

def get_ctx(session, user):
    r = q(session, "SELECT CURRENT_INITIATIVE, CURRENT_STORY, PRODUCT_ID, CLIENT_SURFACE, SET_AT FROM GUPPIWHEEL.PUBLIC.WHEEL_CONTEXT WHERE USER_NAME = ?", [user])
    if not r:
        return {}
    x = r[0]
    return {"initiative": clean(x[0]), "story": clean(x[1]), "product": clean(x[2]), "client": clean(x[3]), "set_at": str(x[4])}

def set_ctx(session, user, clear=(), **kw):
    cur = get_ctx(session, user)
    cur.update({k: v for k, v in kw.items() if v is not None})
    for k in clear:
        cur[k] = None
    q(session, """
      MERGE INTO GUPPIWHEEL.PUBLIC.WHEEL_CONTEXT t
      USING (SELECT ? U, NULLIF(?, '__WHEEL_NULL__') I, NULLIF(?, '__WHEEL_NULL__') S,
                    NULLIF(?, '__WHEEL_NULL__') P, NULLIF(?, '__WHEEL_NULL__') C) s ON t.USER_NAME = s.U
      WHEN MATCHED THEN UPDATE SET CURRENT_INITIATIVE = s.I, CURRENT_STORY = s.S, PRODUCT_ID = s.P,
                                   CLIENT_SURFACE = s.C, SET_AT = CURRENT_TIMESTAMP()
      WHEN NOT MATCHED THEN INSERT (USER_NAME, CURRENT_INITIATIVE, CURRENT_STORY, PRODUCT_ID, CLIENT_SURFACE)
                            VALUES (s.U, s.I, s.S, s.P, s.C)""",
      [user, b(cur.get("initiative")), b(cur.get("story")), b(cur.get("product")), b(cur.get("client"))])
    return get_ctx(session, user)

def live(session, aid):
    r = q(session, "SELECT TYPE, STAGE, PRODUCT_ID, TITLE, OWNER FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ? AND SUPERSEDED_BY IS NULL", [aid])
    return None if not r else {"type": r[0][0], "stage": r[0][1], "product": r[0][2], "title": r[0][3], "owner": r[0][4]}

def create_artifact(session, typ, title, product, content, parent, stage, tags):
    args = [typ, title, product, json.dumps(content or {}), b(parent), stage, json.dumps(tags or []), NUL, NUL]
    sql = "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?, ?, ?, ?, NULLIF(?, '__WHEEL_NULL__'), ?, ?, NULLIF(?, '__WHEEL_NULL__'), NULLIF(?, '__WHEEL_NULL__'))"
    return call(session, sql, args)

# ---------------------------------------------------------------- verbs
def v_context(session, user, a):
    ctx = set_ctx(session, user, client=a.get("client")) if a.get("client") else get_ctx(session, user)
    caps = None
    if ctx.get("client"):
        r = q(session, "SELECT HOOKS_RUN, HOOK_MESSAGES_VISIBLE, HOOK_BLOCK_ENFORCED, MEMORY_INJECTED, EVIDENCE FROM GUPPIWHEEL.PUBLIC.CLIENT_CAPABILITIES WHERE CLIENT_SURFACE = ?", [ctx["client"]])
        if r:
            caps = {"hooks_run": r[0][0], "hook_messages_visible": r[0][1], "hook_block_enforced": r[0][2],
                    "memory_injected": r[0][3], "evidence": r[0][4]}
    debt = [dict(product=x[0], kind=x[1], events=int(x[2]), last=str(x[3]), sample=x[4]) for x in q(session, """
        SELECT PRODUCT_ID, KIND, SUM(EVENTS), MAX(LAST_EVIDENCE_TS), ANY_VALUE(SAMPLE_TEXT)
        FROM GUPPIWHEEL.PUBLIC.CAPTURE_DEBT WHERE STATUS = 'open' AND USER_NAME = ?
        GROUP BY 1, 2 ORDER BY 4 DESC LIMIT 20""", [user])]
    trip = []
    try:
        trip = [dict(ts=str(x[0]), table=x[1], text=x[2]) for x in q(session, """
            SELECT START_TIME, TARGET_TABLE, LEFT(QUERY_TEXT, 160) FROM GUPPIWHEEL.PUBLIC.DIRECT_DML_TRIPWIRE_V
            WHERE USER_NAME = ? AND START_TIME > DATEADD(hour, -24, CURRENT_TIMESTAMP()) ORDER BY 1 DESC LIMIT 10""", [user])]
    except Exception as e:
        trip = [{"error": str(e)[:200]}]
    stale = [dict(id=x[0], title=x[1], days=int(x[2])) for x in q(session, """
        SELECT ID, TITLE, DATEDIFF('day', UPDATED_AT, CURRENT_TIMESTAMP()) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE OWNER = ? AND TYPE = 'STORY' AND STAGE = 'Building' AND SUPERSEDED_BY IS NULL
          AND UPDATED_AT < DATEADD(day, -7, CURRENT_TIMESTAMP()) ORDER BY 3 DESC LIMIT 10""", [user])]
    if ctx.get("initiative"):
        i = live(session, ctx["initiative"])
        ctx["initiative_title"] = i["title"] if i else "(superseded or missing — run WHEEL open)"
    guidance = []
    if caps is not None and caps.get("hook_messages_visible") is False:
        guidance.append("Hook reminders are not visible in this client: record ship/capture in the same turn as the work.")
    if not ctx.get("initiative"):
        guidance.append("No current initiative: call WHEEL('open', {title, product}) before producing work.")
    if debt:
        guidance.append("Open capture debt: ship the matching stories (WHEEL ship) or open/story then ship.")
    return {"user": user, "context": ctx, "client_capabilities": caps, "capture_debt": debt,
            "tripwire_24h": trip, "stale_building_stories": stale, "guidance": guidance}

def v_open(session, user, a):
    title = (a.get("title") or "").strip()
    product = (a.get("product") or "").strip().lower() or None
    if a.get("parent"):
        p = live(session, a["parent"])
        if not p or p["type"] not in ("INITIATIVE", "EPIC"):
            return {"error": "parent must be a live INITIATIVE or EPIC", "parent": a["parent"]}
        return {"chosen": a["parent"], "title": p["title"],
                "context": set_ctx(session, user, clear=("story",), initiative=a["parent"], product=product or p["product"])}
    if not title or not product:
        return {"error": "open needs {title, product} (or {parent})"}
    # Homes for a product: initiatives/epics tagged with it, or that already parent its work
    # (INIT-70 is product 'guppi' but parents the PLAT stories of product 'platform').
    cands = [dict(id=x[0], type=x[1], stage=x[2], title=x[3], product=x[4], product_children=int(x[5]), score=float(x[6])) for x in q(session, """
        WITH homes AS (
          SELECT a.ID, a.TYPE, a.STAGE, a.TITLE, a.PRODUCT_ID,
                 (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS c
                   WHERE c.PARENT_ID = a.ID AND c.SUPERSEDED_BY IS NULL AND LOWER(c.PRODUCT_ID) = ?) AS KIDS
          FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
          WHERE a.TYPE IN ('INITIATIVE', 'EPIC') AND a.SUPERSEDED_BY IS NULL
            AND a.TITLE NOT ILIKE '[RETIRED%')
        SELECT ID, TYPE, STAGE, TITLE, PRODUCT_ID, KIDS,
               JAROWINKLER_SIMILARITY(LOWER(?), LOWER(TITLE)) / 100.0 + LEAST(KIDS, 10) * 0.05
                 + IFF(LOWER(PRODUCT_ID) = ?, 0.3, 0) AS SCORE
        FROM homes WHERE KIDS > 0 OR LOWER(PRODUCT_ID) = ?
        ORDER BY SCORE DESC LIMIT 5""", [product, title, product, product])]
    if cands and not a.get("force"):
        best = cands[0]
        ctx = set_ctx(session, user, clear=("story",), initiative=best["id"], product=product)
        return {"reused": best["id"], "why": "existing home for product '%s' (pass parent= to choose another, or force+reason to mint new)" % product,
                "candidates": cands, "context": ctx}
    if not a.get("force") or not (a.get("reason") or "").strip():
        return {"error": "no existing home for product '%s'; mint a new initiative with force:true and a reason" % product,
                "candidates": cands}
    out = call(session, "CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(?, ?, ?, ?, ?)",
               [title, a.get("hypothesis") or title, a.get("instructions") or ("Opened via WHEEL open for product " + product),
                True, a["reason"]])
    m = re.search(r"\bINIT-\d+\b", str(out))
    ctx = set_ctx(session, user, clear=("story",), initiative=m.group(0), product=product) if m else get_ctx(session, user)
    return {"minted": m.group(0) if m else None, "submit_result": out, "candidates": cands, "context": ctx}

def v_story(session, user, a):
    ctx = get_ctx(session, user)
    parent = a.get("parent") or ctx.get("initiative")
    product = (a.get("product") or ctx.get("product") or "").lower() or None
    if not parent or not product or not a.get("title"):
        return {"error": "story needs title + (parent or current initiative) + (product or context product)", "context": ctx}
    res = create_artifact(session, "STORY", a["title"], product, a.get("content") or {}, parent,
                          a.get("stage") or "Initiate", a.get("tags") or [product])
    if isinstance(res, dict) and res.get("artifact_id"):
        res["context"] = set_ctx(session, user, story=res["artifact_id"])
    return res

def v_ship(session, user, a):
    ctx = get_ctx(session, user)
    aid = a.get("id") or ctx.get("story")
    stage = a.get("stage") or "Built"
    note = (a.get("note") or "").strip()
    if not aid or not note:
        return {"error": "ship needs a note (what shipped) and an id or a current story", "context": ctx}
    art = live(session, aid)
    if not art:
        return {"error": "artifact not found or superseded", "id": aid}
    adv = None
    if art["stage"] != stage:
        # Third arg is an OVERRIDE for blocking rules, never a note: pass NULL.
        adv = call(session, "CALL GUPPIWHEEL.PUBLIC.ADVANCE_STAGE(?, ?, NULL)", [aid, stage])
        if isinstance(adv, dict) and adv.get("blocked"):
            return {"blocked": True, "id": aid, "advance": adv}
    noted = None
    if art["owner"] == user:
        r = q(session, "SELECT CONTENT FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = ?", [aid])
        content = r[0][0] if r and r[0][0] is not None else "{}"
        try:
            c = json.loads(content) if isinstance(content, str) else dict(content)
        except Exception:
            c = {"body": str(content)}
        if not isinstance(c, dict):
            c = {"body": c}
        c.setdefault("shipped", []).append({"note": note, "stage": stage, "client": ctx.get("client")})
        noted = call(session, "CALL GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(?, NULL, PARSE_JSON(?), NULL)", [aid, json.dumps(c)])
    cleared = q(session, """
        UPDATE GUPPIWHEEL.PUBLIC.CAPTURE_DEBT SET STATUS = 'cleared', CLEARED_BY = ?, CLEARED_AT = CURRENT_TIMESTAMP()
        WHERE STATUS = 'open' AND USER_NAME = ? AND LOWER(PRODUCT_ID) = LOWER(?) AND LAST_EVIDENCE_TS <= CURRENT_TIMESTAMP()""",
        [aid, user, art["product"] or ctx.get("product") or ""])
    return {"shipped": aid, "stage": stage, "advance": adv, "note_recorded": noted,
            "note_skipped_reason": None if art["owner"] == user else "not owner; note kept only in this response",
            "debt_cleared": cleared[0][0] if cleared else 0}

def v_capture(session, user, a):
    ctx = get_ctx(session, user)
    parent = a.get("parent") or ctx.get("initiative")
    if not parent or not a.get("stage_path") or not a.get("title"):
        return {"error": "capture needs stage_path (PUT the file first) + title + (parent or current initiative)"}
    kind = (a.get("kind") or "APP").upper()
    spec = {"app_type": a.get("app_type") or "static_html", "stage_path": a["stage_path"]}
    res = call(session, "CALL GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(?, ?, ?, ?, ?, NULL, 'internal')",
               [kind, a["title"], a.get("description") or a["title"], json.dumps(spec), parent])
    # PUBLISH_ARTIFACT has no product parameter, so captures were born untagged and invisible
    # to reconcile. Inherit the product from the parent. ASSIGN_PRODUCT cascades to descendants,
    # so it is only ever called on the artifact just created (a leaf).
    if isinstance(res, dict) and res.get("artifact_id") and not res.get("product_id"):
        p = live(session, parent)
        product = (a.get("product") or (p or {}).get("product") or ctx.get("product"))
        if product:
            res["product_assigned"] = call(session, "CALL GUPPIWHEEL.PUBLIC.ASSIGN_PRODUCT(?, ?)", [res["artifact_id"], product])
    return res

def v_plan(session, user, a):
    ctx = get_ctx(session, user)
    parent = a.get("parent") or ctx.get("initiative")
    if not parent or not a.get("title") or not isinstance(a.get("sections"), dict):
        return {"error": "plan needs title + sections{summary,context,phased_plan,risks,why_now} + (parent or current initiative)"}
    return call(session, "CALL GUPPIWHEEL.PUBLIC.CREATE_NARRATIVE('internal_plan', ?, ?, ?, NULLIF(?, '__WHEEL_NULL__'), NULL)",
                [a["title"], json.dumps(a["sections"]), parent, b(a.get("product") or ctx.get("product"))])

def v_reparent(session, user, a):
    if not a.get("id") or not a.get("reason"):
        return {"error": "reparent needs id + parent + reason"}
    return call(session, "CALL GUPPIWHEEL.PUBLIC.REPARENT_ARTIFACT(?, NULLIF(?, '__WHEEL_NULL__'), ?)", [a["id"], b(a.get("parent")), a["reason"]])

def v_preview(session, user, a):
    t = (a.get("type") or "STORY").upper()
    product = (a.get("product") or get_ctx(session, user).get("product") or "").lower() or None
    r = q(session, "SELECT GUPPIWHEEL.PUBLIC.PREVIEW_NEXT_ID(?, NULLIF(?, '__WHEEL_NULL__'))", [t, b(product)])
    nid = r[0][0] if r else None
    out = {"type": t, "product": product, "next_id": nid}
    if nid is None:
        out["why"] = "descriptive-ID type (pass an explicit id) or unregistered product (CREATE_PRODUCT)"
    return out

def run(session, p_verb, p_args):
    verb = (p_verb or "help").strip().lower()
    try:
        a = json.loads(p_args) if p_args else {}
    except Exception as e:
        return {"error": "P_ARGS must be a JSON object string", "detail": str(e)}
    user = me(session)
    fn = {"context": v_context, "open": v_open, "story": v_story, "ship": v_ship, "capture": v_capture,
          "plan": v_plan, "reparent": v_reparent, "preview": v_preview}.get(verb)
    if fn is None:
        return {"verbs": VERBS} if verb == "help" else {"error": "unknown verb '%s'" % verb, "verbs": VERBS}
    try:
        return fn(session, user, a)
    except Exception as e:
        return {"error": str(e)[:1000], "verb": verb}
$$;

GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL(VARCHAR, VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL(VARCHAR, VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- WHEEL_ADMIN(verb, args) — admin-only repairs (MERGE/RESYNC/RETAG are RULE-027 admin)
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL_ADMIN(P_VERB VARCHAR, P_ARGS VARCHAR DEFAULT '{}')
COPY GRANTS
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Admin repairs: merge {duplicate,survivor,reason} | retag {id,product,reason}. GUPPIWHEEL_ADMIN only.'
EXECUTE AS OWNER
AS
$$
import json
def run(session, p_verb, p_args):
    a = json.loads(p_args or "{}")
    v = (p_verb or "").lower()
    if not (a.get("reason") or "").strip():
        return {"error": "reason required (audit trail)"}
    if v == "merge":
        sql, p = "CALL GUPPIWHEEL.PUBLIC.MERGE_ARTIFACTS(?, ?, ?)", [a["duplicate"], a["survivor"], a["reason"]]
    elif v == "retag":
        sql, p = "CALL GUPPIWHEEL.PUBLIC.RETAG_PRODUCT(?, ?, ?)", [a["id"], a["product"], a["reason"]]
    else:
        return {"error": "verbs: merge, retag (IDs are derived in 3.32.0; there is no resync)"}
    r = session.sql(sql, params=p).collect()
    v0 = r[0][0] if r else None
    try:
        return json.loads(v0) if isinstance(v0, str) else v0
    except Exception:
        return v0
$$;

GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL_ADMIN(VARCHAR, VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
GRANT SELECT ON TABLE GUPPIWHEEL.PUBLIC.CLIENT_CAPABILITIES TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT SELECT ON TABLE GUPPIWHEEL.PUBLIC.PRODUCT_FOOTPRINT  TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- Least privilege despite the schema FUTURE GRANT (USAGE on every new procedure -> RSI_APP_READER,
-- RSI_ENGINE; see PLAT-D9). That grant re-fires on every CREATE OR REPLACE, so an admin proc must
-- revoke it right after creation, every deploy.
REVOKE USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL_ADMIN(VARCHAR, VARCHAR) FROM ROLE RSI_APP_READER;
REVOKE USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.WHEEL_ADMIN(VARCHAR, VARCHAR) FROM ROLE RSI_ENGINE;
