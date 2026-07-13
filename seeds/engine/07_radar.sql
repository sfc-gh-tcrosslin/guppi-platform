-- =============================================================================
-- guppi-platform — Engine Seed 07: Radar (weekday AI-blog scan) + swarm evidence board
-- Additive only (RULE-019). Idempotent: CREATE ... IF NOT EXISTS + MERGE seeds.
--
-- Supports:
--   * RULE-030 Rocky swarm: ROCKY_EVIDENCE = the write-only evidence board that
--     isolated profiled sub-agents post to; the reconciler reads it.
--   * "Radar" weekday AI-blog scan (a STANDING INITIATIVE under the 'guppi' product,
--     NOT a new product): RADAR_SOURCES (config), RADAR_SEEN (dedupe), RADAR_DELIVERY
--     (session-start digest tracking).
-- Pattern credited to Snowflake ArcticSwarm (isolation during discovery + reconcile).
-- =============================================================================

USE DATABASE GUPPIWHEEL;
USE SCHEMA PUBLIC;

-- Swarm evidence board — isolated sub-agents write here (never read peers); reconciler reads.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE (
    RUN_ID      VARCHAR,          -- one id per swarm run (init_id + timestamp)
    INIT_ID     VARCHAR,          -- initiative being researched
    ROLE        VARCHAR,          -- retriever | counterexample-seeker | consistency-checker
    FINDINGS    VARCHAR,          -- that role's raw synthesis text
    CREATED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Radar source registry — edit freely to add/drop sources (enabled flag toggles).
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.RADAR_SOURCES (
    SOURCE_ID     VARCHAR,
    DISPLAY_NAME  VARCHAR,
    DOMAIN        VARCHAR,         -- preferred domain/path the fetcher should favor
    QUERY_HINTS   VARCHAR,        -- extra terms to steer web_search
    ENABLED       BOOLEAN DEFAULT TRUE,
    CREATED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Dedupe watermark — a found URL is recorded so digests never resurface it.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.RADAR_SEEN (
    URL_HASH      VARCHAR,        -- SHA2(url)
    URL           VARCHAR,
    FIRST_SEEN_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Session-start delivery tracking — which digest artifacts have already been surfaced.
-- (Legacy from the daily-digest model; superseded by RADAR_ITEMS.DELIVERED. Kept for back-compat.)
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.RADAR_DELIVERY (
    ARTIFACT_ID   VARCHAR,
    DELIVERED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- RADAR_ITEMS — the durable feed. Dedupe (URL_HASH), history, "what's new" (DELIVERED),
-- portfolio-grounded assessment (RELEVANCE/RELATED/ACTIONS), and the source of truth the
-- ONE rolling Radar narrative renders from (last 7 days).
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.RADAR_ITEMS (
    URL_HASH        VARCHAR,
    URL             VARCHAR,
    TITLE           VARCHAR,
    PUBLISHED_DATE  VARCHAR,
    SOURCE_ID       VARCHAR,
    SOURCE_NAME     VARCHAR,
    WHY             VARCHAR,
    FLAG            VARCHAR,          -- e.g. Substance | Hype
    RELEVANCE       VARCHAR,          -- high | medium | low (portfolio-grounded, set by RADAR_ASSESS)
    RELATED         VARCHAR,          -- product/initiative ids or names this touches
    ACTIONS         VARCHAR,          -- proposed next steps tied to those projects (human promotes)
    DELIVERED       BOOLEAN DEFAULT FALSE,
    FOUND_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Seed the starter + recommended sources (idempotent). Databricks / MS Research
-- ship DISABLED (optional competitor/adjacent signal; flip ENABLED to include).
MERGE INTO GUPPIWHEEL.PUBLIC.RADAR_SOURCES AS t
USING (
  SELECT column1 AS SOURCE_ID, column2 AS DISPLAY_NAME, column3 AS DOMAIN, column4 AS QUERY_HINTS, column5 AS ENABLED
  FROM VALUES
    ('snowflake_eng',        'Snowflake Engineering Blog', 'snowflake.com/en/blog/engineering',       'AI agents data engineering', TRUE),
    ('snowflake_airesearch', 'Snowflake AI Research',      'snowflake.com/en/product/ai/ai-research', 'ArcticSwarm LLM research',   TRUE),
    ('anthropic',            'Anthropic',                  'anthropic.com/news',                      'Claude models safety research', TRUE),
    ('openai',               'OpenAI',                     'openai.com/news',                         'models research releases',   TRUE),
    ('nvidia',               'NVIDIA Technical Blog',      'developer.nvidia.com/blog',               'AI GPU inference LLM',       TRUE),
    ('deepmind',             'Google DeepMind',            'deepmind.google/discover/blog',           'AI research models',         TRUE),
    ('huggingface',          'Hugging Face Blog',          'huggingface.co/blog',                     'open models datasets agents', TRUE),
    ('meta_ai',              'Meta AI',                    'ai.meta.com/blog',                        'Llama research',             TRUE),
    ('arxiv_ai',             'arXiv cs.AI / cs.CL',        'arxiv.org/list/cs.AI/recent',             'LLM agents multi-agent recent', TRUE),
    ('databricks',           'Databricks Blog',            'databricks.com/blog',                     'AI data lakehouse (competitor)', FALSE),
    ('ms_research',          'Microsoft Research Blog',    'microsoft.com/en-us/research/blog',       'AI research',                FALSE)
) AS s
ON t.SOURCE_ID = s.SOURCE_ID
WHEN NOT MATCHED THEN INSERT (SOURCE_ID, DISPLAY_NAME, DOMAIN, QUERY_HINTS, ENABLED)
VALUES (s.SOURCE_ID, s.DISPLAY_NAME, s.DOMAIN, s.QUERY_HINTS, s.ENABLED);

-- NOTE: the standing "Radar" scan INITIATIVE opener proc + serverless Mon-Fri TASK
-- are added below in this file by seed step 6 (RADAR_OPEN_SCAN + BLOGSCAN_TASK).

-- =============================================================================
-- ROCKY_AB — prove-it harness (RULE-030). Runs BOTH single-pass and swarm on the
-- SAME initiative, writes two RESEARCH artifacts (method=single|swarm) + a comparison
-- NARRATIVE judged by a THIRD model (openai-gpt-4.1, distinct from generators -> no
-- self-judging). Does NOT change the initiative stage (side experiment). Manual/opt-in.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.ROCKY_AB(P_INIT_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, re, time

def _atext(session, prompt):
    try:
        r = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)",
                        params=["GUPPIWHEEL.PUBLIC.ROCKY_AGENT", json.dumps({"messages":[{"role":"user","content":[{"type":"text","text":prompt}]}]})]).collect()
        resp = str(r[0][0]) if r else ""
    except Exception as e:
        return "agent error: " + str(e)
    try:
        j = json.loads(resp)
        parts = [it.get("text","") for it in j.get("content",[]) if isinstance(it,dict) and it.get("type")=="text"]
        return "\n".join(parts) if parts else resp
    except Exception:
        return resp

def run(session, p_init_id):
    ir = session.sql("SELECT TITLE, CONTENT:hypothesis::string AS H, CONTENT:instructions::string AS I FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=? AND TYPE='INITIATIVE'", params=[p_init_id]).collect()
    if not ir:
        return {"error":"initiative not found","id":p_init_id}
    title = ir[0]["TITLE"]; hypo = ir[0]["H"] or "N/A"; instr = ir[0]["I"] or ""
    ts = str(int(time.time()))
    base = "TITLE: " + title + "\nHYPOTHESIS: " + hypo + "\n\nINSTRUCTIONS:\n" + instr + "\n\nUse web search; cite named sources, dates, numbers. Do NOT call submit_initiative."

    single = _atext(session, "Execute this research initiative autonomously.\n\n" + base + "\n\nProvide VERDICT / KEY FINDINGS / NEXT STEPS. Text only.")

    run_id = p_init_id + "-AB-" + ts
    for role in ["retriever","counterexample-seeker","consistency-checker"]:
        f = _atext(session, "ROLE: " + role + "\n\nExecute this research initiative in your role only.\n\n" + base)
        session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE (RUN_ID,INIT_ID,ROLE,FINDINGS) VALUES (?,?,?,?)", params=[run_id, p_init_id, role, (f or "")[:12000]]).collect()
    ev = session.sql("SELECT ROLE,FINDINGS FROM GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE WHERE RUN_ID=? ORDER BY ROLE", params=[run_id]).collect()
    board = "\n\n".join(["=== ROLE " + r["ROLE"] + " ===\n" + (r["FINDINGS"] or "") for r in ev])
    rec = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=["claude-sonnet-4-5", "Reconcile these isolated findings into VERDICT / KEY FINDINGS / NEXT STEPS; preserve conflicts, do not average.\n\n" + board]).collect()
    swarm = str(rec[0][0]) if rec else ""

    jprompt = ("You are an INDEPENDENT judge (a different model than the authors). Compare TWO research syntheses answering the SAME initiative. "
               "Judge on completeness, specificity (named sources/dates/numbers), and honest treatment of disconfirming evidence. "
               "Return ONLY JSON: {\"winner\":\"single|swarm|tie\",\"why\":\"one sentence\",\"single_score\":0.0,\"swarm_score\":0.0}.\n\n"
               "INITIATIVE: " + title + "\n\n=== SYNTHESIS A (single) ===\n" + single[:6000] + "\n\n=== SYNTHESIS B (swarm) ===\n" + swarm[:6000])
    jr = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=["openai-gpt-4.1", jprompt]).collect()
    jtxt = str(jr[0][0]) if jr else ""
    verdict = {}
    mm = re.search(r"\{[\s\S]*\}", jtxt)
    if mm:
        try:
            verdict = json.loads(mm.group(0))
        except Exception:
            verdict = {"raw": jtxt[:500]}

    num = p_init_id.replace("INIT-","")
    sid = "RES-" + num + "-AB-SINGLE-" + ts
    wid = "RES-" + num + "-AB-SWARM-" + ts
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?,?,NULL,?,?,'Built',?,?,?)",
        params=["RESEARCH","Rocky A/B (single): " + title[:150], json.dumps({"synthesis":(single or "")[:12000],"method":"single"}), p_init_id, json.dumps(["ab","single"]), sid, json.dumps({"ab":True,"method":"single"})]).collect()
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?,?,NULL,?,?,'Built',?,?,?)",
        params=["RESEARCH","Rocky A/B (swarm): " + title[:150], json.dumps({"synthesis":(swarm or "")[:12000],"method":"swarm"}), p_init_id, json.dumps(["ab","swarm"]), wid, json.dumps({"ab":True,"method":"swarm","pattern":"arcticswarm"})]).collect()

    nar_id = "NAR-AB-" + num + "-" + ts
    ncontent = {"markdown": "# Rocky A/B: single vs swarm\n\n**Judge:** openai-gpt-4.1 (independent; no self-judging)\n\n**Verdict:** " + json.dumps(verdict) + "\n\n## Single-pass\n" + single[:4000] + "\n\n## Swarm (isolate + reconcile)\n" + swarm[:4000], "verdict": verdict}
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(?,?,NULL,?,?,'Published',?,?,?)",
        params=["NARRATIVE", "Rocky A/B: single vs swarm -- " + title[:80], json.dumps(ncontent), p_init_id, json.dumps(["ab","radar","swarm"]), nar_id, json.dumps({"ab":True,"judge":"openai-gpt-4.1","single_research":sid,"swarm_research":wid,"pattern":"arcticswarm"})]).collect()
    return {"init":p_init_id,"single_research":sid,"swarm_research":wid,"comparison_narrative":nar_id,"verdict":verdict}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.ROCKY_AB(VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- RADAR_ASSESS — portfolio-grounded "so what for us". For each unassessed item (last
-- 7 days), one batched claude call fed our PRODUCTS + ALL INITIATIVES decides relevance,
-- which projects it touches, and PROPOSED actions (human promotes; no self-spawning per
-- RULE-016). A new capability may be a reason to revisit a past initiative / tell a customer.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_ASSESS()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, re

CHUNK = 8  # items per COMPLETE call — small enough that the model returns every item

def _norm(u):
    # normalize a URL for tolerant matching: drop scheme/www, query, fragment, trailing slash
    u = (u or "").strip().lower()
    for p in ("https://", "http://"):
        if u.startswith(p):
            u = u[len(p):]
    if u.startswith("www."):
        u = u[4:]
    u = u.split("#", 1)[0].split("?", 1)[0]
    return u.rstrip("/")

def run(session):
    items = session.sql("SELECT URL_HASH, TITLE, SOURCE_NAME, WHY, URL FROM GUPPIWHEEL.PUBLIC.RADAR_ITEMS "
                        "WHERE RELEVANCE IS NULL AND FOUND_AT >= DATEADD('day', -7, CURRENT_TIMESTAMP()) ORDER BY FOUND_AT DESC").collect()
    if not items:
        return {"assessed": 0}
    prods = session.sql("SELECT PRODUCT_ID, NAME, LEFT(DESCRIPTION,300) AS D FROM GUPPIWHEEL.PUBLIC.PRODUCTS WHERE STATUS='ACTIVE' ORDER BY PRODUCT_ID").collect()
    inits = session.sql("SELECT ID, TITLE, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE='INITIATIVE' AND SUPERSEDED_BY IS NULL ORDER BY CREATED_AT DESC LIMIT 100").collect()
    ctx = "PRODUCTS:\n" + "\n".join(["- " + p["PRODUCT_ID"] + " (" + (p["NAME"] or "") + "): " + (p["D"] or "") for p in prods])
    ctx += "\n\nINITIATIVES (all stages):\n" + "\n".join(["- " + i["ID"] + " [" + (i["STAGE"] or "") + "] " + (i["TITLE"] or "") for i in inits])
    ctx = ctx[:8000]

    n = 0
    batches = 0
    for start in range(0, len(items), CHUNK):
        chunk = items[start:start + CHUNK]
        lst = [{"url": it["URL"], "title": it["TITLE"], "source": it["SOURCE_NAME"], "why": it["WHY"]} for it in chunk]
        prompt = ("You are Radar's analyst for a Snowflake healthcare team. Using ONLY the PORTFOLIO below (our products and initiatives), assess how each NEWS ITEM relates to OUR work and propose concrete next steps. "
            "Reference our products/initiatives by id. A new capability may be a reason to REVISIT a past initiative or tell that customer they could up their game. Be specific and honest; use relevance=low if it is not really relevant. "
            "Return ONLY a raw JSON array with EXACTLY one object per item, in the SAME ORDER as given, each "
            "{\"url\":\"<echo the item url exactly>\",\"relevance\":\"high|medium|low\",\"related\":\"comma-separated product/INIT ids, or none\",\"actions\":\"1-2 concrete PROPOSED next steps tied to those ids; these are proposals, not approved work\"}.\n\n"
            "PORTFOLIO:\n" + ctx + "\n\nITEMS:\n" + json.dumps(lst))
        res = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=["claude-sonnet-4-5", prompt]).collect()
        txt = str(res[0][0]) if res else ""
        arr = []
        mm = re.search(r"\[[\s\S]*\]", txt)
        if mm:
            try:
                arr = json.loads(mm.group(0))
            except Exception:
                arr = []
        by_url = {_norm(a.get("url")): a for a in arr if isinstance(a, dict) and a.get("url")}
        batches += 1
        for j, it in enumerate(chunk):
            a = by_url.get(_norm(it["URL"]))
            if a is None and j < len(arr) and isinstance(arr[j], dict):
                a = arr[j]  # positional fallback — model returned items in order but url drifted
            if not a:
                continue
            session.sql("UPDATE GUPPIWHEEL.PUBLIC.RADAR_ITEMS SET RELEVANCE=?, RELATED=?, ACTIONS=? WHERE URL_HASH=?",
                params=[(a.get("relevance") or "")[:20], (a.get("related") or "")[:500], (a.get("actions") or "")[:2000], it["URL_HASH"]]).collect()
            n += 1
    return {"assessed": n, "candidates": len(items), "batches": batches}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_ASSESS() TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- RADAR_RENDER — regenerate the ONE rolling Radar narrative (NAR-RADAR) from
-- RADAR_ITEMS (last 7 days). Builds styled HTML, PUTs it to @ARTIFACT_ASSETS, and
-- refreshes the launchable narrative in place. NO agent calls -> $0, safe to re-run
-- (also used at session-start). Persona: Cpl. Radar O'Reilly (M*A*S*H) hears it first.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_RENDER()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, io

def _esc(s):
    return (str(s) if s is not None else "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")

def _radar_init(session):
    ir = session.sql("SELECT ID FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE='INITIATIVE' AND METADATA:radar::boolean=TRUE AND SUPERSEDED_BY IS NULL LIMIT 1").collect()
    if ir:
        return ir[0]["ID"]
    cr = session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('INITIATIVE', ?, 'guppi', ?, NULL, 'Built', '[\"radar\"]', NULL, ?)",
        params=["Radar: weekday AI-blog scan",
                json.dumps({"hypothesis":"A standing scan of major AI blogs surfaces relevant news into the wheel so we stop finding it on X.","instructions":"Isolated per-source fetch; dedupe; render ONE rolling narrative (last 7 days)."}),
                json.dumps({"radar":True})]).collect()
    try:
        return json.loads(str(cr[0][0])).get("artifact_id")
    except Exception:
        return None

def run(session):
    init_id = _radar_init(session)
    rows = session.sql("SELECT SOURCE_NAME, TITLE, URL, PUBLISHED_DATE, WHY, FLAG, RELEVANCE, RELATED, ACTIONS, TO_VARCHAR(FOUND_AT,'YYYY-MM-DD') AS FD "
                       "FROM GUPPIWHEEL.PUBLIC.RADAR_ITEMS WHERE FOUND_AT >= DATEADD('day', -7, CURRENT_TIMESTAMP()) "
                       "ORDER BY CASE LOWER(RELEVANCE) WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END, FOUND_AT DESC, SOURCE_NAME").collect()
    n = len(rows)
    cards = []
    for r in rows:
        flag = (r["FLAG"] or "").strip()
        fh = ("<span class=flag>" + _esc(flag) + "</span>") if flag else ""
        rel = (r["RELEVANCE"] or "").strip().lower()
        rb = "<span class=rel data-lvl=" + _esc(rel or "unrated") + ">" + _esc(rel or "unrated") + "</span>"
        related = (r["RELATED"] or "").strip()
        actions = (r["ACTIONS"] or "").strip()
        rel_html = ("<div class=relto><b>Relates to:</b> " + _esc(related) + "</div>") if related and related.lower() != "none" else ""
        act_html = ("<div class=actions><b>Potential actions:</b> " + _esc(actions) + "</div>") if actions else ""
        cards.append("<div class=item><div class=meta>" + rb + "<span class=src>" + _esc(r["SOURCE_NAME"]) + "</span> <span class=date>" + _esc(r["PUBLISHED_DATE"] or r["FD"]) + "</span> " + fh + "</div>"
                     "<a class=title href=\"" + _esc(r["URL"]) + "\" target=_blank>" + _esc(r["TITLE"]) + "</a>"
                     "<div class=why>" + _esc(r["WHY"]) + "</div>" + rel_html + act_html + "</div>")
    body = "".join(cards) if cards else "<div class=empty>Nothing in the last 7 days. Radar is listening...</div>"
    updated = session.sql("SELECT TO_VARCHAR(CONVERT_TIMEZONE('America/Chicago', CURRENT_TIMESTAMP()),'YYYY-MM-DD HH24:MI')").collect()[0][0]
    html = ("<!DOCTYPE html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\">"
        "<title>Radar - AI News</title><style>"
        "*{box-sizing:border-box;margin:0;padding:0}body{font-family:Segoe UI,Helvetica,Arial,sans-serif;background:#eef1f6;color:#1a1f36}"
        ".wrap{max-width:900px;margin:0 auto;padding:0 0 60px}"
        ".cover{background:linear-gradient(135deg,#0B1F33,#1A2E45 60%,#0f2c47);color:#fff;padding:28px 40px;border-bottom:3px solid #29B5E8}"
        ".cover h1{font-size:1.7rem;letter-spacing:.06em}.cover .sub{color:#9fb4c9;font-size:.9rem;margin-top:4px}"
        ".cover .persona{color:#29B5E8;font-size:.72rem;text-transform:uppercase;letter-spacing:.06em;margin-top:10px}"
        ".body{padding:22px 40px}"
        ".item{background:#fff;border:1px solid #dde3ed;border-left:3px solid #29B5E8;border-radius:8px;padding:13px 16px;margin-bottom:12px}"
        ".meta{font-size:.72rem;color:#6b7a90;margin-bottom:4px}.src{font-weight:700;color:#0060a9}.date{margin-left:6px}"
        ".flag{margin-left:8px;background:#e3f8ee;color:#0a7d43;border-radius:4px;padding:1px 7px;font-weight:700}"
        ".title{display:block;font-size:1.02rem;font-weight:700;color:#0f1f3d;text-decoration:none;margin:2px 0}.title:hover{color:#29B5E8}"
        ".why{font-size:.9rem;color:#4a5e7a;margin-top:3px}.empty{color:#6b7a90;padding:30px;text-align:center}"
        ".rel{font-size:.6rem;font-weight:800;text-transform:uppercase;border-radius:4px;padding:1px 7px;margin-right:8px}"
        ".rel[data-lvl=high]{background:#ffe1e1;color:#b1113a}.rel[data-lvl=medium]{background:#fff3d6;color:#9a5b00}.rel[data-lvl=low]{background:#eef3fa;color:#4a5e7a}.rel[data-lvl=unrated]{background:#eef3fa;color:#9aa5b8}"
        ".relto{font-size:.8rem;color:#0060a9;margin-top:6px}"
        ".actions{font-size:.82rem;color:#0a6b3b;margin-top:4px;background:#f2fbf6;border:1px solid #d7f0e2;border-radius:6px;padding:6px 9px}"
        ".foot{text-align:center;color:#9aa5b8;font-size:.75rem;margin-top:20px}"
        "</style></head><body><div class=wrap>"
        "<div class=cover><h1>RADAR</h1><div class=sub>Rolling AI-news feed &middot; last 7 days &middot; " + str(n) + " items</div>"
        "<div class=persona>Cpl. Radar O'Reilly hears the choppers first &middot; GuppiWheel x ArcticSwarm pattern</div></div>"
        "<div class=body>" + body + "</div>"
        "<div class=foot>Updated " + _esc(updated) + " CST &middot; sources in GUPPIWHEEL.PUBLIC.RADAR_SOURCES &middot; regenerated each scan</div>"
        "</div></body></html>")
    session.file.put_stream(io.BytesIO(html.encode("utf-8")), "@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/radar/rolling.html", auto_compress=False, overwrite=True)

    nar_id = "NAR-RADAR"
    content = json.dumps({"summary":"Rolling AI-news radar (last 7 days): " + str(n) + " items.","count":n,"updated":str(updated),"render":"static_html"})
    ex = session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=?", params=[nar_id]).collect()[0]["C"]
    if ex and int(ex) > 0:
        session.sql("UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET CONTENT=PARSE_JSON(?), UPDATED_AT=CURRENT_TIMESTAMP() WHERE ID=?", params=[content, nar_id]).collect()
    else:
        meta = json.dumps({"radar_rolling":True,"launch":{"app_type":"static_html","stage_path":"@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/radar/rolling.html","default_ttl_seconds":3600}})
        session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('NARRATIVE', ?, 'guppi', ?, ?, 'Built', '[\"radar\"]', ?, ?)",
            params=["Radar: rolling AI-news feed", content, init_id, nar_id, meta]).collect()
    return {"narrative":nar_id,"rendered_items":n,"stage_path":"@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/radar/rolling.html"}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_RENDER() TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- RADAR_SCAN — weekday scan. Isolated per-source fetch (ROCKY_AGENT web_search, one
-- call per source = ArcticSwarm fan-out), dedupe into RADAR_ITEMS, then regenerate the
-- ONE rolling narrative via RADAR_RENDER. New items land with DELIVERED=false so
-- session-start can surface "what's new since last visit".
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_SCAN()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json, re, hashlib

def _atext(session, prompt):
    try:
        r = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)",
                        params=["GUPPIWHEEL.PUBLIC.ROCKY_AGENT", json.dumps({"messages":[{"role":"user","content":[{"type":"text","text":prompt}]}]})]).collect()
        resp = str(r[0][0]) if r else ""
    except Exception:
        return ""
    try:
        j = json.loads(resp)
        parts = [it.get("text","") for it in j.get("content",[]) if isinstance(it,dict) and it.get("type")=="text"]
        return "\n".join(parts) if parts else resp
    except Exception:
        return resp

def run(session):
    srcs = session.sql("SELECT SOURCE_ID, DISPLAY_NAME, DOMAIN, QUERY_HINTS FROM GUPPIWHEEL.PUBLIC.RADAR_SOURCES WHERE ENABLED ORDER BY SOURCE_ID").collect()
    new = 0
    for s in srcs:
        prompt = ("ROLE: retriever\n\nFind blog posts or articles PUBLISHED IN THE LAST 7 DAYS from " + (s["DISPLAY_NAME"] or "") +
                  " (strongly prefer the domain " + (s["DOMAIN"] or "") + "). Focus topics: " + (s["QUERY_HINTS"] or "") + ". "
                  "Return ONLY a raw JSON array (no prose) of up to 5 items, each {\"title\":\"\",\"url\":\"\",\"date\":\"\",\"why\":\"\",\"flag\":\"Substance or Hype\"}. "
                  "why = one line on why it matters to a Snowflake data/AI + healthcare + multi-agent team. "
                  "Only include items you are confident were published in the last 7 days with a real URL. If none, return [].")
        txt = _atext(session, prompt)
        arr = []
        mm = re.search(r"\[[\s\S]*\]", txt)
        if mm:
            try:
                arr = json.loads(mm.group(0))
            except Exception:
                arr = []
        for it in (arr if isinstance(arr, list) else []):
            if not isinstance(it, dict):
                continue
            url = (it.get("url") or "").strip()
            if not url or not url.lower().startswith("http"):
                continue
            h = hashlib.sha256(url.encode("utf-8")).hexdigest()
            seen = session.sql("SELECT COUNT(*) AS C FROM GUPPIWHEEL.PUBLIC.RADAR_ITEMS WHERE URL_HASH=?", params=[h]).collect()[0]["C"]
            if seen and int(seen) > 0:
                continue
            session.sql("INSERT INTO GUPPIWHEEL.PUBLIC.RADAR_ITEMS (URL_HASH,URL,TITLE,PUBLISHED_DATE,SOURCE_ID,SOURCE_NAME,WHY,FLAG,DELIVERED) SELECT ?,?,?,?,?,?,?,?,FALSE",
                        params=[h, url, (it.get("title") or "")[:500], (it.get("date") or "")[:40], s["SOURCE_ID"], s["DISPLAY_NAME"], (it.get("why") or "")[:1000], (it.get("flag") or "")[:40]]).collect()
            new += 1
    session.sql("CALL GUPPIWHEEL.PUBLIC.RADAR_ASSESS()").collect()
    rr = session.sql("CALL GUPPIWHEEL.PUBLIC.RADAR_RENDER()").collect()
    render = None
    try:
        render = json.loads(str(rr[0][0])) if rr else None
    except Exception:
        render = str(rr[0][0]) if rr else None
    return {"new_items": new, "sources": len(srcs), "render": render}
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.RADAR_SCAN() TO ROLE GUPPIWHEEL_ADMIN;

-- Weekday 7am CST scan. Serverless (Snowflake-managed compute). Created SUSPENDED —
-- RESUME only after a successful manual test (ALTER TASK ... RESUME).
CREATE OR REPLACE TASK GUPPIWHEEL.PUBLIC.BLOGSCAN_TASK
  SCHEDULE = 'USING CRON 0 7 * * MON-FRI America/Chicago'
  COMMENT = 'Radar: weekday 7am CST AI-blog scan (isolated per-source fetch -> dedupe -> daily digest). ArcticSwarm fan-out.'
AS
  CALL GUPPIWHEEL.PUBLIC.RADAR_SCAN();

-- =============================================================================
-- CORTEX SEARCH — institutional-memory discoverability (prior-art at initiative time)
-- Co-located here (not 01_schema) because RADAR_SEARCH_V depends on RADAR_ITEMS (above)
-- and Cortex Search services must bind to the installer's active warehouse.
-- TWO services on purpose: ARTIFACTS_SEARCH_SVC uses INCREMENTAL refresh over a
-- FLATTEN/LISTAGG source; UNION-ing Radar items into it is NOT incrementally
-- refreshable and breaks that dynamic table, so Radar gets its own simple service.
-- SUBMIT_INITIATIVE queries BOTH for advisory prior-art. (ARTIFACTS_SEARCH_SVC was
-- created out-of-band 2026-06-12; seeding it here gives fresh installs the search
-- tool the Cowork agent already depends on.)
-- =============================================================================
EXECUTE IMMEDIATE $$
DECLARE
  no_wh EXCEPTION (-20037, 'No active warehouse. Run  USE WAREHOUSE <your_wh>;  then re-run 07_radar.sql');
BEGIN
  IF ((SELECT CURRENT_WAREHOUSE()) IS NULL) THEN RAISE no_wh; END IF;
  RETURN 'warehouse OK';
END;
$$;
SET wh = (SELECT CURRENT_WAREHOUSE());

-- Artifacts corpus: full body of RESEARCH/NARRATIVE/STORY/etc. (flattened CONTENT).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_V AS
SELECT
    a.ID, a.TYPE, a.TITLE, a.STAGE, a.OWNER, a.PARENT_ID, a.CREATED_AT, a.UPDATED_AT,
    CONCAT(COALESCE(a.TITLE, ''), '\n\n', COALESCE(f.FLATTENED_TEXT, '')) AS SEARCH_TEXT,
    ARRAY_TO_STRING(a.TAGS, ', ') AS TAGS_TEXT,
    a.METADATA:"industry"::STRING AS INDUSTRY,
    a.METADATA:"use_case"::STRING AS USE_CASE,
    a.METADATA:"account"::STRING AS ACCOUNT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
LEFT JOIN (
    SELECT art.ID, LISTAGG(fl.key || ': ' || fl.value::STRING, '\n\n') AS FLATTENED_TEXT
    FROM GUPPIWHEEL.PUBLIC.ARTIFACTS art, LATERAL FLATTEN(input => art.CONTENT) fl
    GROUP BY art.ID
) f ON a.ID = f.ID
WHERE a.CONTENT IS NOT NULL AND a.SUPERSEDED_BY IS NULL;

EXECUTE IMMEDIATE
  'CREATE OR REPLACE CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_SVC
     ON SEARCH_TEXT
     ATTRIBUTES TYPE, TITLE, STAGE, OWNER, TAGS_TEXT, INDUSTRY, USE_CASE, ACCOUNT
     WAREHOUSE = ' || $wh || '
     TARGET_LAG = ''1 hour''
     REFRESH_MODE = INCREMENTAL
     AS (
       SELECT ID, TYPE, TITLE, STAGE, OWNER, SEARCH_TEXT, TAGS_TEXT, INDUSTRY, USE_CASE, ACCOUNT
       FROM GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_V
     )';

-- Radar finds: separate simple (DT-friendly) service. Read-only discoverability;
-- Radar items are NOT promoted to artifacts (one rolling NAR-RADAR by design).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.RADAR_SEARCH_V AS
SELECT
    'RDR-' || LEFT(r.URL_HASH, 12) AS ID,
    r.TITLE AS TITLE, r.URL AS URL, r.SOURCE_NAME AS SOURCE_NAME,
    COALESCE(r.RELEVANCE,'') AS RELEVANCE, COALESCE(r.RELATED,'') AS RELATED, r.FOUND_AT AS FOUND_AT,
    CONCAT(COALESCE(r.TITLE,''), '. ', COALESCE(r.WHY,''), ' Source: ', COALESCE(r.SOURCE_NAME,''),
           '. Relates to: ', COALESCE(r.RELATED,''), '. Potential actions: ', COALESCE(r.ACTIONS,'')) AS SEARCH_TEXT
FROM GUPPIWHEEL.PUBLIC.RADAR_ITEMS r
WHERE r.URL IS NOT NULL;

EXECUTE IMMEDIATE
  'CREATE OR REPLACE CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.RADAR_SEARCH_SVC
     ON SEARCH_TEXT
     ATTRIBUTES ID, TITLE, URL, SOURCE_NAME, RELEVANCE, RELATED
     WAREHOUSE = ' || $wh || '
     TARGET_LAG = ''1 hour''
     AS (
       SELECT ID, TITLE, URL, SOURCE_NAME, RELEVANCE, RELATED, FOUND_AT, SEARCH_TEXT
       FROM GUPPIWHEEL.PUBLIC.RADAR_SEARCH_V
     )';

GRANT USAGE ON CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_SVC TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.ARTIFACTS_SEARCH_SVC TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.RADAR_SEARCH_SVC TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON CORTEX SEARCH SERVICE GUPPIWHEEL.PUBLIC.RADAR_SEARCH_SVC TO ROLE GUPPIWHEEL_CONTRIBUTOR;
