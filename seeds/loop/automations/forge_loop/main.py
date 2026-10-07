"""Demo Forge -- ReAct build-runner over the neutral loop kernel (GUPPI_LOOP_ENGINE.CORE).

This is NOT a second RSI. It is the ReAct / plan-execute loop pattern (loop
engineering, 2026): reason -> act -> observe -> repeat until a VERIFIABLE goal
(each step's exit_gate) is met. There is:
  * NO grader, NO score, NO champion/candidate, NO selection among variants.
  * "recover" = fix-and-retry a FAILING step (error recovery), never "pick the
    better of two builds".
Quality/selection is the Reflection config's (RSI) job -- reachable ONLY via the
optional handoff at the very end. That is why one runtime hosts two patterns
without becoming two RSIs.

Runs as FORGE_BUILDER (write authority ONLY inside DEMO_FORGE_SANDBOX). Every
build statement goes through DEMO_FORGE_SANDBOX.CONTROL.FORGE_EXEC (sandbox cage
+ qualification guard). The kernel enforces budget / idempotency-replay /
no-progress / gate; this driver only decides succeed / recover / fail.

input_data:
{
  "run_id": "<stable resume key>",            # launcher-assigned; resume-safe
  "target": "<build_plan_id>",
  "sandbox_schema": "DEMO_FORGE_SANDBOX.RUN_<id>",
  "plan": [ {"step_id","kind","sql","gate_sql"?,"gate_min_rows"?}, ... ],  # sql may use {{SANDBOX}}
  "budget": {"max_steps","max_attempts","max_retries","max_retries_per_step"},
  "gate": {"policy":"pre-run","state":"approved|awaiting","token"?},
  "handoff": {"enabled":bool,"execute":bool,"payload":{...}}   # optional RSI turn (dry-run by default)
}
"""
import json, hashlib

_ENG = "GUPPI_LOOP_ENGINE.CORE"
_EXEC = "DEMO_FORGE_SANDBOX.CONTROL.FORGE_EXEC"
_MODEL = "claude-sonnet-4-5"
_SANDBOX_DB = "DEMO_FORGE_SANDBOX"


def _cell(rows):
    if not rows:
        return None
    r0 = rows[0]
    try:
        v = list(r0.values())[0]
    except Exception:
        try:
            v = r0[0]
        except Exception:
            v = r0
    if isinstance(v, str):
        try:
            return json.loads(v)
        except Exception:
            return v
    return v


def run(ctx, input_data: dict) -> dict:
    p = input_data or {}
    target = p.get("target", "(unknown-plan)")
    ss = (p.get("sandbox_schema") or "").strip()
    plan = p.get("plan") or []
    budget = p.get("budget") or {}
    gate = p.get("gate") or {}
    handoff = p.get("handoff") or {}
    run_id = p.get("run_id") or ctx.run_id
    max_rps = int(budget.get("max_retries_per_step", 2))

    def q1(sql, params=None):
        return _cell(ctx.query(sql, params or []))

    # ---- guard: the driver may only ever create/write inside the sandbox DB ----
    if not ss.upper().startswith(_SANDBOX_DB + ".") or ".CONTROL" in ss.upper():
        out = {"run_id": run_id, "error": "bad_sandbox_schema", "sandbox_schema": ss}
        ctx.output(out); return out
    if not plan:
        out = {"run_id": run_id, "error": "empty_plan"}
        ctx.output(out); return out

    # ---- register / resume the run in the kernel (idempotent on run_id) ----
    q1("CALL " + _ENG + ".LOOP_BEGIN(:1,:2,:3,:4,PARSE_JSON(:5),:6,PARSE_JSON(:7),PARSE_JSON(:8))",
       [run_id, "forge", "react", target, json.dumps(budget), ss, json.dumps(p), json.dumps(gate)])

    # ---- durable human gate: do not proceed until approved ----
    gs = q1("CALL " + _ENG + ".LOOP_GATE_STATE(:1)", [run_id])
    if isinstance(gs, dict) and gs.get("status") == "awaiting_gate":
        out = {"run_id": run_id, "status": "awaiting_gate",
               "note": "human GO required (FORGE_LAUNCH gate) before the forge runs"}
        ctx.output(out); return out

    # ---- ensure the per-run sandbox schema exists (driver-owned; not via FORGE_EXEC) ----
    ctx.query("CREATE SCHEMA IF NOT EXISTS " + ss)

    def record(step_id, idx, attempt, kind, status, result, error):
        q1("CALL " + _ENG + ".LOOP_RECORD_STEP(:1,:2,:3,:4,:5,:6,:7,PARSE_JSON(:8),:9)",
           [run_id, step_id, idx, attempt, kind,
            hashlib.md5((step_id + "|" + str(idx)).encode()).hexdigest(),
            status, json.dumps(result or {}), (error or None)])

    def gate_ok(gate_sql, min_rows):
        if not gate_sql:
            return True, "no explicit gate; exec success is the gate"
        ex = q1("CALL " + _EXEC + "(:1,:2,:3)", [run_id, ss, gate_sql])
        if not (isinstance(ex, dict) and ex.get("ok")):
            return False, "gate query failed: " + (ex.get("error", "?") if isinstance(ex, dict) else str(ex))
        rc = int(ex.get("rowcount") or 0)
        if rc < min_rows:
            return False, "gate rowcount %d < min_rows %d" % (rc, min_rows)
        return True, "gate ok (rowcount=%d)" % rc

    def repair(cur_sql, err):
        prompt = ("You are fixing ONE Snowflake SQL statement that failed. Return ONLY the "
                  "corrected statement -- no prose, no markdown fences. It MUST be fully "
                  "qualified into schema " + ss + ". Statement:\n" + cur_sql + "\n\nError:\n" + (err or ""))
        out = q1("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", [_MODEL, prompt])
        if not isinstance(out, str):
            return None
        fixed = out.strip()
        if fixed.startswith("```"):
            fixed = fixed.strip("`")
            if fixed[:3].lower() == "sql":
                fixed = fixed[3:]
            fixed = fixed.strip()
        return fixed or None

    traj = []
    halt = None            # 'budget' | 'stalled'
    final_status = "done"  # optimistic; flips on terminal step failure / halt

    for idx, step in enumerate(plan, start=1):
        step_id = step.get("step_id") or ("s%d" % idx)
        kind = step.get("kind", "build")

        # replay/skip: a prior (crashed) run already completed this step -> reuse, no re-exec
        rec = q1("CALL " + _ENG + ".LOOP_RECALL_STEP(:1,:2)", [run_id, step_id])
        if isinstance(rec, dict) and rec.get("found"):
            record(step_id, idx, 0, kind, "skipped_recorded", rec.get("result") or {}, None)
            traj.append({"step": step_id, "status": "skipped_recorded"})
            continue

        cur_sql = (step.get("sql") or "").replace("{{SANDBOX}}", ss)
        gate_sql = (step.get("gate_sql") or "").replace("{{SANDBOX}}", ss)
        min_rows = int(step.get("gate_min_rows", 1))
        step_done = False
        attempt = 0
        while attempt <= max_rps:
            bl = q1("CALL " + _ENG + ".LOOP_BUDGET_LEFT(:1)", [run_id])
            if isinstance(bl, dict) and bl.get("exhausted"):
                halt = "budget"; break
            ex = q1("CALL " + _EXEC + "(:1,:2,:3)", [run_id, ss, cur_sql])
            ok = isinstance(ex, dict) and ex.get("ok")
            gpass, gnote = (gate_ok(gate_sql, min_rows) if ok else (False, "exec failed"))
            if ok and gpass:
                status = "recovered" if attempt > 0 else "succeeded"
                record(step_id, idx, attempt, kind, status, {"exec": ex, "gate": gnote}, None)
                traj.append({"step": step_id, "status": status, "attempt": attempt})
                step_done = True; break
            err = (ex.get("error") if isinstance(ex, dict) else str(ex)) if not ok else ("gate_failed: " + gnote)
            record(step_id, idx, attempt, kind, "failed", {"exec": ex}, err)
            traj.append({"step": step_id, "status": "failed", "attempt": attempt, "error": (err or "")[:200]})
            st = q1("CALL " + _ENG + ".LOOP_STALL_CHECK(:1,:2)", [run_id, 3])
            if isinstance(st, dict) and st.get("stalled"):
                halt = "stalled"; break
            if attempt >= max_rps:
                break
            fixed = repair(cur_sql, err)          # ReAct recover: fix-and-retry, NOT variant selection
            if not fixed or fixed.strip() == cur_sql.strip():
                break
            cur_sql = fixed
            attempt += 1

        if halt:
            final_status = "budget_exhausted" if halt == "budget" else "stalled"
            break
        if not step_done:
            final_status = "failed"   # a required build step could not be made to succeed
            break

    result = {
        "run_id": run_id, "target": target, "sandbox_schema": ss,
        "status": final_status, "steps_total": len(plan), "trajectory": traj,
        "pattern": "react", "config": "forge",
        "note": ("ReAct build-runner (GUPPI_LOOP_ENGINE.CORE forge config). No grader / no "
                 "champion / no selection -- completion loop only."),
        "ladder": {"launch": "human-gated (Tier-1)", "improve": "optional RSI handoff (Tier-2/3 live in RSI)"},
    }

    # ---- optional handoff INTO RSI (the Doctrine B dashed 'optional turn') ----
    if final_status == "done" and handoff.get("enabled"):
        if handoff.get("execute"):
            try:
                ho = q1("CALL GUPPIWHEEL.PUBLIC.RUN_TARGET_LIFECYCLE(PARSE_JSON(:1))",
                        [json.dumps(handoff.get("payload") or {})])
                result["handoff"] = {"invoked": True, "result": ho}
            except Exception as e:
                result["handoff"] = {"invoked": False, "error": str(e)[:300]}
        else:
            result["handoff"] = {"invoked": False, "mode": "dry-run",
                                 "would_call": "GUPPIWHEEL.PUBLIC.RUN_TARGET_LIFECYCLE",
                                 "payload": handoff.get("payload") or {},
                                 "note": "improvement is RSI's job; set handoff.execute=true to actually start it"}

    q1("CALL " + _ENG + ".LOOP_SET_STATUS(:1,:2,PARSE_JSON(:3))",
       [run_id, final_status, json.dumps(result)])
    ctx.output(result)
    return result
