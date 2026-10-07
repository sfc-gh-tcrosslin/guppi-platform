-- =============================================================================
-- guppi-platform -- Forge Config Seed 05: Governed launcher (Bob proposes, human GOes)
-- =============================================================================
-- Split into two procs so the human gate is STRUCTURAL, not advisory:
--   FORGE_LAUNCH  -- Bob-callable (read-only role). Validates a Bob-composed
--                    build-plan, stages an AWAITING-GATE run in the kernel, and
--                    returns a preview + a confirm token. It NEVER triggers.
--   FORGE_APPROVE -- human-only (admins, NOT Bob). Verifies the token, resolves
--                    the durable gate, and triggers the DEMO_FORGE workflow.
-- Bob can propose a build; only a human can make it run. Mirrors the
-- RUN_TARGET_LIFECYCLE trigger mechanism (SYSTEM$RUN_AUTOMATION), EXECUTE AS OWNER.
-- Safe to re-run.
-- =============================================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.FORGE_LAUNCH(
    P_PLAN VARIANT, P_TARGET VARCHAR, P_BUDGET VARIANT DEFAULT NULL, P_HANDOFF VARIANT DEFAULT NULL)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run'
COMMENT='Bob''s trigger-only tool: stage a Demo Forge build (awaiting human gate). Validates the build-plan, registers an awaiting_gate run in the loop kernel, returns a preview + confirm token. Does NOT run anything -- a human must call FORGE_APPROVE.'
EXECUTE AS OWNER AS
$$
import json, hashlib
def _v(x):
    return None if (x is None or x.__class__.__name__ == "sqlNullWrapper") else x
def run(session, plan, target, budget, handoff):
    plan = _v(plan); handoff = _v(handoff) or {}; budget = _v(budget)
    if not isinstance(plan, list) or not plan:
        return {"ok": False, "error": "plan must be a non-empty array of steps"}
    for i, s in enumerate(plan, 1):
        if not isinstance(s, dict) or not str(s.get("sql", "")).strip():
            return {"ok": False, "error": "step %d missing sql" % i}
    target = target or "adhoc-plan"
    plan_json = json.dumps(plan, sort_keys=True)
    rid = "FORGE-" + hashlib.md5((str(target) + "|" + plan_json).encode()).hexdigest()[:12]
    sandbox = "DEMO_FORGE_SANDBOX.RUN_" + rid.replace("-", "_")
    if not budget:
        d = session.sql("SELECT DEFAULTS FROM GUPPI_LOOP_ENGINE.CORE.LOOP_CONFIG WHERE CONFIG='forge'").collect()
        budget = (json.loads(d[0][0]).get("budget") if d and d[0][0] else {}) or {}
    ts = session.sql("SELECT CURRENT_TIMESTAMP()").collect()[0][0]
    token = hashlib.md5((rid + "|" + str(ts)).encode()).hexdigest()[:10]
    gate = {"policy": "pre-run", "state": "awaiting", "token": token}
    inp = {"run_id": rid, "target": target, "sandbox_schema": sandbox,
           "plan": plan, "budget": budget, "gate": gate, "handoff": handoff}
    session.sql("CALL GUPPI_LOOP_ENGINE.CORE.LOOP_BEGIN(?,?,?,?,PARSE_JSON(?),?,PARSE_JSON(?),PARSE_JSON(?))",
                params=[rid, "forge", "react", target, json.dumps(budget), sandbox,
                        json.dumps(inp), json.dumps(gate)]).collect()
    # authoritative gate/token (handles resume: a re-launch returns the original token)
    gs = session.sql("CALL GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_STATE(?)", params=[rid]).collect()
    st = json.loads(gs[0][0]) if gs and gs[0][0] else {}
    tok = (st.get("gate") or {}).get("token", token)
    return {"ok": True, "status": st.get("status", "awaiting_gate"), "run_id": rid,
            "sandbox_schema": sandbox, "steps": len(plan), "budget": budget,
            "plan_preview": [{"step_id": s.get("step_id") or ("s%d" % i), "kind": s.get("kind", "build")}
                             for i, s in enumerate(plan, 1)],
            "confirm_token": tok,
            "approve_with": "CALL GUPPIWHEEL.PUBLIC.FORGE_APPROVE('%s','%s')" % (rid, tok),
            "note": "Bob staged this build. A human must review the plan and call FORGE_APPROVE with the token. Nothing runs until then (Tier-1 gate)."}
$$;

CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.FORGE_APPROVE(P_RUN_ID VARCHAR, P_TOKEN VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run'
COMMENT='Human GO for a staged Demo Forge run. Verifies the confirm token, resolves the durable gate, and triggers the DEMO_FORGE ReAct workflow (which runs caged as FORGE_BUILDER). Human-only -- NOT granted to Bob''s read-only role.'
EXECUTE AS OWNER AS
$$
import json
def run(session, run_id, token):
    gs = session.sql("CALL GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_STATE(?)", params=[run_id]).collect()
    st = json.loads(gs[0][0]) if gs and gs[0][0] else {}
    if not st.get("found"):
        return {"ok": False, "error": "no_such_run", "run_id": run_id}
    if st.get("status") not in ("awaiting_gate", "running"):
        return {"ok": False, "error": "run is not awaiting a gate", "status": st.get("status")}
    dec = session.sql("CALL GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_DECIDE(?,?,?,?)",
                      params=[run_id, "approved", token, "human"]).collect()
    d = json.loads(dec[0][0]) if dec and dec[0][0] else {}
    if not d.get("ok"):
        return {"ok": False, "error": d.get("error", "gate_declined"), "run_id": run_id}
    row = session.sql("SELECT INPUT FROM GUPPI_LOOP_ENGINE.CORE.LOOP_RUN WHERE RUN_ID=?", params=[run_id]).collect()
    inp = json.loads(row[0][0]) if row and row[0][0] else {}
    inp["gate"] = {"policy": "pre-run", "state": "approved"}
    raw = session.sql("SELECT SYSTEM$RUN_AUTOMATION(?, ?)",
                      params=["DEMO_FORGE_SANDBOX.CONTROL.DEMO_FORGE", json.dumps(inp)]).collect()
    rawv = raw[0][0] if raw else None
    out = rawv
    try:
        parsed = json.loads(rawv) if rawv else {}
        out = json.loads(parsed["output"]) if isinstance(parsed.get("output"), str) else parsed.get("output", parsed)
    except Exception:
        pass
    # governed audit artifact per run (provenance). Records the run REGARDLESS of
    # outcome. No metric/champion/candidate is recorded -- proof the forge is a
    # completion loop, not a 2nd RSI.
    audit = None
    try:
        status = (out.get("status") if isinstance(out, dict) else None) or "unknown"
        title = "Forge run %s (%s)" % (run_id, status)
        aid = "forge-audit-" + run_id.replace("FORGE-", "").lower()   # explicit slug id (AUDIT has no auto-allocator)
        content = json.dumps({
            "run_id": run_id, "status": status,
            "target": (out.get("target") if isinstance(out, dict) else None),
            "sandbox_schema": (out.get("sandbox_schema") if isinstance(out, dict) else None),
            "steps_total": (out.get("steps_total") if isinstance(out, dict) else None),
            "trajectory": (out.get("trajectory") if isinstance(out, dict) else None),
            "handoff": (out.get("handoff") if isinstance(out, dict) else None),
            "pattern": "react",
            "note": "Demo Forge run audit (governed). No grader / champion / selection -- completion loop."})
        ex = session.sql("SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=?",
                         params=[aid]).collect()[0][0]
        if int(ex) == 0:
            session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('AUDIT', ?, 'guppi', ?, 'E-46', 'Published', ?, ?, ?)",
                        params=[title, content, json.dumps(["forge", "audit", "run", "react"]), aid,
                                json.dumps({"run_id": run_id, "source": "FORGE_APPROVE"})]).collect()
        audit = aid
    except Exception as e:
        audit = "audit_error: " + str(e)[:200]
    return {"ok": True, "run_id": run_id, "triggered": True, "audit": audit, "result": out}
$$;

-- Grants: Bob (read-only caller role) can PROPOSE; only humans can APPROVE.
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.FORGE_LAUNCH(VARIANT,VARCHAR,VARIANT,VARIANT) TO ROLE RSI_APP_READER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.FORGE_LAUNCH(VARIANT,VARCHAR,VARIANT,VARIANT) TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.FORGE_APPROVE(VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;
