-- =============================================================================
-- guppi-platform -- Loop Kernel Seed 02: Primitive Procs
-- =============================================================================
-- The pattern-AGNOSTIC operations every durable agent loop needs (loop
-- engineering, 2026 consensus). Both configs -- Reflection (RSI) and ReAct
-- (forge) -- call these; neither writes the kernel tables directly. Owner's
-- rights, owned by LOOP_ENGINE (the kernel's tables), so a caller (FORGE_BUILDER)
-- can only append through the narrow, parameterized contract below -- it cannot
-- rewrite the ledger.
--
-- The kernel is deliberately unaware of "better/worse". It records steps,
-- enforces budget/idempotency/stall, and holds the gate. The CONFIG's decision
-- function (accept-if-better for RSI; succeed/recover/fail for the forge) lives
-- in each pattern's driver -- NOT here. That is why there is only one runtime,
-- not two RSIs.
--
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

USE DATABASE GUPPI_LOOP_ENGINE;
USE SCHEMA CORE;

-- LOOP_BEGIN -- register/resume a run. Idempotent on RUN_ID: a re-launch of the
-- same work RESUMES the existing run (preserves cursor/spend) rather than
-- restarting. Initial status honors a pre-run gate policy.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BEGIN(
    P_RUN_ID VARCHAR, P_CONFIG VARCHAR, P_PATTERN VARCHAR, P_TARGET VARCHAR,
    P_BUDGET VARIANT, P_SCOPE VARCHAR, P_INPUT VARIANT, P_GATE VARIANT)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_T = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def _v(x):  # SQL NULL VARIANT arrives as sqlNullWrapper, not None
    return None if (x is None or x.__class__.__name__ == "sqlNullWrapper") else x
def run(session, run_id, config, pattern, target, budget, scope, inp, gate):
    gate = _v(gate) or {}; budget = _v(budget) or {}; inp = _v(inp) or {}
    ex = session.sql("SELECT STATUS,STEP_CURSOR,SPENT,BUDGET FROM " + _T + " WHERE RUN_ID=?", params=[run_id]).collect()
    if ex:
        session.sql("UPDATE " + _T + " SET UPDATED_AT=CURRENT_TIMESTAMP() WHERE RUN_ID=?", params=[run_id]).collect()
        r = ex[0]
        return {"run_id": run_id, "resumed": True, "status": r[0], "step_cursor": r[1],
                "spent": json.loads(r[2]) if r[2] else {}, "budget": json.loads(r[3]) if r[3] else {}}
    status = "awaiting_gate" if (gate.get("policy") == "pre-run" and gate.get("state") != "approved") else "running"
    session.sql(
        "INSERT INTO " + _T + "(RUN_ID,CONFIG,PATTERN,TARGET,STATUS,STEP_CURSOR,BUDGET,SPENT,SCOPE,GATE,INPUT,RESULT,STARTED_AT,UPDATED_AT) "
        "SELECT ?,?,?,?,?,0,PARSE_JSON(?),PARSE_JSON(?),?,PARSE_JSON(?),PARSE_JSON(?),NULL,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()",
        params=[run_id, config, pattern, target, status, json.dumps(budget),
                json.dumps({"steps": 0, "attempts": 0, "retries": 0, "seconds": 0, "cost": 0}),
                scope, json.dumps(gate), json.dumps(inp)]).collect()
    return {"run_id": run_id, "resumed": False, "status": status, "step_cursor": 0,
            "spent": {"steps": 0, "attempts": 0, "retries": 0, "seconds": 0, "cost": 0}, "budget": budget}
$$;

-- LOOP_RECORD_STEP -- append one step ATTEMPT to the journal (the trajectory log),
-- advance the run cursor on progress, and increment the spend tally (steps +
-- retries). The idempotency key = md5(run_id::step_id::attempt).
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECORD_STEP(
    P_RUN_ID VARCHAR, P_STEP_ID VARCHAR, P_STEP_IDX NUMBER, P_ATTEMPT NUMBER,
    P_KIND VARCHAR, P_INPUT_HASH VARCHAR, P_STATUS VARCHAR, P_RESULT VARIANT, P_ERROR VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json, hashlib
_S = "GUPPI_LOOP_ENGINE.CORE.LOOP_STEP"
_R = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def _v(x):  # SQL NULL VARIANT arrives as sqlNullWrapper, not None
    return None if (x is None or x.__class__.__name__ == "sqlNullWrapper") else x
def run(session, run_id, step_id, step_idx, attempt, kind, input_hash, status, result, error):
    result = _v(result); attempt = int(attempt or 0); step_idx = int(step_idx or 0)
    idem = hashlib.md5(("%s::%s::%s" % (run_id, step_id, attempt)).encode()).hexdigest()
    session.sql(
        "INSERT INTO " + _S + "(RUN_ID,STEP_ID,STEP_IDX,ATTEMPT,IDEMPOTENCY_KEY,KIND,STATUS,INPUT_HASH,RESULT,ERROR,STARTED_AT,ENDED_AT) "
        "SELECT ?,?,?,?,?,?,?,?,PARSE_JSON(?),?,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP()",
        params=[run_id, step_id, step_idx, attempt, idem, kind, status, input_hash,
                json.dumps(result if result is not None else {}), (error or "")[:1000]]).collect()
    advance = status in ("succeeded", "recovered", "skipped_recorded")
    inc_attempts = 0 if status == "skipped_recorded" else 1   # real executions (runaway cap)
    inc_steps = 1 if advance else 0                            # cursor progress (plan-length guard)
    inc_retries = 1 if (attempt > 0 and status != "skipped_recorded") else 0
    session.sql(
        "UPDATE " + _R + " SET "
        "STEP_CURSOR = CASE WHEN ? AND ? > STEP_CURSOR THEN ? ELSE STEP_CURSOR END, "
        "SPENT = OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(SPENT,'steps',COALESCE(GET(SPENT,'steps')::int,0)+?,TRUE),"
        "'attempts',COALESCE(GET(SPENT,'attempts')::int,0)+?,TRUE),"
        "'retries',COALESCE(GET(SPENT,'retries')::int,0)+?,TRUE), "
        "UPDATED_AT = CURRENT_TIMESTAMP() WHERE RUN_ID=?",
        params=[advance, step_idx, step_idx, inc_steps, inc_attempts, inc_retries, run_id]).collect()
    return {"ok": True, "idempotency_key": idem, "advanced": advance}
$$;

-- LOOP_RECALL_STEP -- replay/skip read: if this step already SUCCEEDED, return
-- its memoized result so the driver skips re-execution (no duplicate side
-- effects on resume). This is the whole point of durable execution.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECALL_STEP(P_RUN_ID VARCHAR, P_STEP_ID VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_S = "GUPPI_LOOP_ENGINE.CORE.LOOP_STEP"
def run(session, run_id, step_id):
    rows = session.sql("SELECT RESULT FROM " + _S + " WHERE RUN_ID=? AND STEP_ID=? "
                       "AND STATUS IN ('succeeded','recovered') ORDER BY ENDED_AT DESC LIMIT 1",
                       params=[run_id, step_id]).collect()
    if rows and rows[0][0] is not None:
        return {"found": True, "result": json.loads(rows[0][0])}
    return {"found": False, "result": None}
$$;

-- LOOP_BUDGET_LEFT -- circuit-breaker read, enforced in the RUNTIME (not the
-- prompt): remaining steps/retries + an exhausted flag the driver checks each
-- iteration before doing more work.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BUDGET_LEFT(P_RUN_ID VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_R = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def run(session, run_id):
    rows = session.sql("SELECT BUDGET,SPENT FROM " + _R + " WHERE RUN_ID=?", params=[run_id]).collect()
    if not rows:
        return {"found": False}
    budget = json.loads(rows[0][0]) if rows[0][0] else {}
    spent = json.loads(rows[0][1]) if rows[0][1] else {}
    ms, ma, mr = budget.get("max_steps"), budget.get("max_attempts"), budget.get("max_retries")
    steps_left = None if ms is None else max(0, int(ms) - int(spent.get("steps", 0)))
    attempts_left = None if ma is None else max(0, int(ma) - int(spent.get("attempts", 0)))
    retries_left = None if mr is None else max(0, int(mr) - int(spent.get("retries", 0)))
    exhausted = ((steps_left is not None and steps_left <= 0)
                 or (attempts_left is not None and attempts_left <= 0)
                 or (retries_left is not None and retries_left <= 0))
    return {"found": True, "steps_left": steps_left, "attempts_left": attempts_left,
            "retries_left": retries_left, "budget": budget, "spent": spent, "exhausted": exhausted}
$$;

-- LOOP_STALL_CHECK -- no-progress detection: true if the most recent K attempts
-- all failed (the "insistent failure" guard -- stop repeating a broken step).
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_STALL_CHECK(P_RUN_ID VARCHAR, P_K NUMBER)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
_S = "GUPPI_LOOP_ENGINE.CORE.LOOP_STEP"
def run(session, run_id, k):
    k = int(k or 3)
    rows = session.sql("SELECT STATUS FROM " + _S + " WHERE RUN_ID=? ORDER BY ENDED_AT DESC LIMIT ?",
                       params=[run_id, k]).collect()
    recent = [r[0] for r in rows]
    stalled = len(recent) >= k and all(s == "failed" for s in recent)
    return {"stalled": stalled, "recent": recent}
$$;

-- LOOP_SET_STATUS -- terminal/transition status + optional terminal result.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_SET_STATUS(P_RUN_ID VARCHAR, P_STATUS VARCHAR, P_RESULT VARIANT)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_R = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def _v(x):  # SQL NULL VARIANT arrives as sqlNullWrapper, not None
    return None if (x is None or x.__class__.__name__ == "sqlNullWrapper") else x
def run(session, run_id, status, result):
    result = _v(result)
    session.sql("UPDATE " + _R + " SET STATUS=?, RESULT=COALESCE(PARSE_JSON(?),RESULT), UPDATED_AT=CURRENT_TIMESTAMP() WHERE RUN_ID=?",
                params=[status, (json.dumps(result) if result is not None else None), run_id]).collect()
    return {"ok": True, "run_id": run_id, "status": status}
$$;

-- LOOP_GATE_STATE -- inspect the durable human gate.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_STATE(P_RUN_ID VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_R = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def run(session, run_id):
    rows = session.sql("SELECT STATUS,GATE FROM " + _R + " WHERE RUN_ID=?", params=[run_id]).collect()
    if not rows:
        return {"found": False}
    return {"found": True, "status": rows[0][0], "gate": json.loads(rows[0][1]) if rows[0][1] else {}}
$$;

-- LOOP_GATE_DECIDE -- resolve the durable gate (approve/deny). Token-checked.
-- Approve -> running; deny -> cancelled. The human GO/NO-GO signal.
CREATE OR REPLACE PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_DECIDE(P_RUN_ID VARCHAR, P_DECISION VARCHAR, P_TOKEN VARCHAR, P_DECIDED_BY VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
_R = "GUPPI_LOOP_ENGINE.CORE.LOOP_RUN"
def run(session, run_id, decision, token, decided_by):
    rows = session.sql("SELECT GATE FROM " + _R + " WHERE RUN_ID=?", params=[run_id]).collect()
    if not rows:
        return {"ok": False, "error": "no_such_run"}
    gate = json.loads(rows[0][0]) if rows[0][0] else {}
    want = gate.get("token")
    if want and token != want:
        return {"ok": False, "error": "bad_token"}
    decision = (decision or "").lower()
    if decision not in ("approved", "denied"):
        return {"ok": False, "error": "bad_decision"}
    gate["state"] = decision; gate["decided_by"] = decided_by
    new_status = "running" if decision == "approved" else "cancelled"
    session.sql("UPDATE " + _R + " SET GATE=PARSE_JSON(?), STATUS=?, UPDATED_AT=CURRENT_TIMESTAMP() WHERE RUN_ID=?",
                params=[json.dumps(gate), new_status, run_id]).collect()
    return {"ok": True, "run_id": run_id, "decision": decision, "status": new_status}
$$;

-- =============================================================================
-- OWNERSHIP + GRANTS -- kernel role owns the procs (so they write the ledger as
-- LOOP_ENGINE, which owns exactly the kernel tables). Consumers get USAGE only.
-- =============================================================================
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BEGIN(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARIANT,VARIANT) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECORD_STEP(VARCHAR,VARCHAR,NUMBER,NUMBER,VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECALL_STEP(VARCHAR,VARCHAR) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BUDGET_LEFT(VARCHAR) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_STALL_CHECK(VARCHAR,NUMBER) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_SET_STATUS(VARCHAR,VARCHAR,VARIANT) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_STATE(VARCHAR) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_DECIDE(VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;

GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BEGIN(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARIANT,VARIANT) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECORD_STEP(VARCHAR,VARCHAR,NUMBER,NUMBER,VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_RECALL_STEP(VARCHAR,VARCHAR) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_BUDGET_LEFT(VARCHAR) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_STALL_CHECK(VARCHAR,NUMBER) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_SET_STATUS(VARCHAR,VARCHAR,VARIANT) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_STATE(VARCHAR) TO ROLE FORGE_BUILDER;
GRANT USAGE ON PROCEDURE GUPPI_LOOP_ENGINE.CORE.LOOP_GATE_DECIDE(VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE FORGE_BUILDER;
