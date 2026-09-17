"""RSI engine -- Cortex Workflow Automation entrypoint (platform: GUPPI_RSI_ENGINE.CORE).

Domain-agnostic + metric-agnostic. Each run binds its own step procs by FQN via input_data.steps
(champion/propose/eval/decide) and reports back an arbitrary metrics VARIANT. The engine orchestrates;
targets are pluggable.

RSI-6 scope adds the three-tier ladder + rails:
  - Tier-2 commit: on improvement AND mode=="auto-push", push the final champion to a branch+PR
    (RSI_GIT_PUSH -- content-guarded, NEVER writes the default branch). Default mode="propose-only".
  - Tier-3 merge stays human (this engine never merges).
  - cost ceiling: budget.max_evals bounds work per run.
  - regression guarantee: only the accept-gated final champion is ever pushed; a worse candidate
    can never land (RSI_GIT_DELETE_BRANCH is the manual revert).
  - human-fired-TARS audit-flag: each shipped/ready champion writes AUDIT_FLAGS (TARS='human-fired').
  - failure containment: a per-iteration step failure becomes a reject, never a partial commit.

input_data:
{
  "target": "<label>",
  "steps": {"champion_proc": FQN, "propose_proc": FQN, "eval_proc": FQN, "decide_proc": FQN?},
  "decide_config": {"objective_key": "...", "direction": "max|min", "margin": 0.0,
                     "guard_key": "...", "guard_dir": "min|max"},
  "loop": {"n_loops": 5, "convergence_k": 2},
  "budget": {"max_evals": 8},
  "mode": "propose-only|auto-push",
  "judge_policy": "end", "start_from": "<ref>"
}
Plugin contract:
  champion_proc(target, start_ref) -> {artifact, ref}
  propose_proc(current_artifact, feedback_json) -> {candidate_id, artifact}
  eval_proc(artifact) -> {<arbitrary metrics VARIANT>}
  decide_proc(prev_metrics, cand_metrics, config) -> {accept, score, reason}
"""
import json, re

_ENG = "GUPPI_RSI_ENGINE.CORE"
_FQN = re.compile(r"^[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+$")


def _ok_fqn(nm):
    return bool(nm and _FQN.match(nm))


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
    target = p.get("target", "(unknown)")
    steps = p.get("steps", {}) or {}
    champ_proc = steps.get("champion_proc")
    propose_proc = steps.get("propose_proc")
    eval_proc = steps.get("eval_proc")
    decide_proc = steps.get("decide_proc", _ENG + ".RSI_DECIDE")
    dcfg = p.get("decide_config", {}) or {}
    okey = dcfg.get("objective_key", "score")
    direction = str(dcfg.get("direction", "max")).lower()
    loop = p.get("loop", {}) or {}
    n_loops = int(loop.get("n_loops", 5))
    conv_k = int(loop.get("convergence_k", 2))
    budget = p.get("budget", {}) or {}
    max_evals = int(budget.get("max_evals", n_loops + 1))
    mode = str(p.get("mode", "propose-only")).lower()
    judge = p.get("judge_policy", "end")
    start_ref = p.get("start_from", "")
    run_id = ctx.run_id

    for nm in (champ_proc, propose_proc, eval_proc, decide_proc):
        if not _ok_fqn(nm):
            out = {"run_id": run_id, "error": "bad_or_missing_step_proc", "proc": nm}
            ctx.output(out); return out

    dcfg_json = json.dumps(dcfg)

    def _obj(m):
        try:
            return float((m or {}).get(okey, 0) or 0)
        except Exception:
            return 0.0

    def _better(a, b):
        # is a better than b, per objective direction
        return a > b if direction != "min" else a < b

    # champion -> baseline
    ch = _cell(ctx.query("CALL " + champ_proc + "(:1, :2)", [target, start_ref]))
    if not ch or "artifact" not in ch:
        out = {"run_id": run_id, "error": "no_champion", "detail": ch}
        ctx.output(out); return out
    best_art = ch["artifact"]
    best_metrics = _cell(ctx.query("CALL " + eval_proc + "(:1)", [best_art])) or {}
    baseline_obj = _obj(best_metrics)
    evals_done = 1
    ctx.query(
        "CALL " + _ENG + ".RSI_LOG(:1,:2,:3,:4,:5,:6,PARSE_JSON(:7),:8)",
        [run_id, target, 0, "champion", True, _obj(best_metrics), json.dumps(best_metrics), "baseline"])
    traj = [{"iter": 0, "role": "champion", "ref": ch.get("ref"), "metrics": best_metrics}]

    stopped = "n_loops"
    no_improve = 0
    accepts = 0
    for i in range(1, n_loops + 1):
        if evals_done >= max_evals:
            stopped = "budget"
            break
        # failure containment: a step failure becomes a reject, never a crashed run / partial commit
        try:
            prop = _cell(ctx.query(
                "CALL " + propose_proc + "(:1, :2)", [best_art, json.dumps(best_metrics)])) or {}
            cand_id = prop.get("candidate_id")
            cand_art = prop.get("artifact", "")
            cand_metrics = _cell(ctx.query("CALL " + eval_proc + "(:1)", [cand_art])) or {}
            evals_done += 1
            dec = _cell(ctx.query(
                "CALL " + decide_proc + "(PARSE_JSON(:1), PARSE_JSON(:2), PARSE_JSON(:3))",
                [json.dumps(best_metrics), json.dumps(cand_metrics), dcfg_json])) or {}
            accept = bool(dec.get("accept", False))
            reason = (dec.get("reason") or "")[:300]
        except Exception as e:
            cand_id, cand_art, cand_metrics, accept = None, "", {}, False
            reason = ("step_error: " + str(e))[:300]
        ctx.query(
            "CALL " + _ENG + ".RSI_LOG(:1,:2,:3,:4,:5,:6,PARSE_JSON(:7),:8)",
            [run_id, target, i, cand_id, accept, _obj(cand_metrics), json.dumps(cand_metrics), reason])
        traj.append({"iter": i, "candidate_id": cand_id, "accept": accept,
                     "metrics": cand_metrics, "reason": reason})
        if accept:
            best_art, best_metrics = cand_art, cand_metrics
            accepts += 1
            no_improve = 0
        else:
            no_improve += 1
            if no_improve >= conv_k:
                stopped = "converged"
                break

    # ---- Tier-2 commit + audit-flag (RSI-6) ----
    best_obj = _obj(best_metrics)
    improved = _better(best_obj, baseline_obj)
    commit = {"mode": mode, "improved": improved}

    def _flag(commit_sha, pr_url, branch, status):
        try:
            ctx.query(
                "INSERT INTO " + _ENG + ".AUDIT_FLAGS"
                "(RUN_ID,TARGET,COMMIT_SHA,PR_URL,BRANCH,OBJECTIVE_KEY,BASELINE,CHAMPION,MODE,TARS,STATUS,CREATED_AT) "
                "SELECT :1,:2,:3,:4,:5,:6,:7,:8,:9,:10,:11,CURRENT_TIMESTAMP()",
                [run_id, target, commit_sha, pr_url, branch, okey, baseline_obj, best_obj, mode, "human-fired", status])
        except Exception as e:
            commit["flag_error"] = str(e)[:200]

    if not improved:
        commit["note"] = "no improvement over baseline; nothing to ship"
    elif mode == "auto-push":
        msg = "RSI %s: %s %.4f -> %.4f (%d kept). Human review + merge required (Tier-3)." % (
            run_id, okey, baseline_obj, best_obj, accepts)
        try:
            push = _cell(ctx.query(
                "CALL " + _ENG + ".RSI_GIT_PUSH(:1,:2,:3,:4)", [target, run_id, best_art, msg]))
            if isinstance(push, dict) and push.get("ok"):
                commit.update({"pushed": True, "pr_url": push.get("pr_url"),
                               "commit_sha": push.get("commit_sha"), "branch": push.get("branch")})
                _flag(push.get("commit_sha"), push.get("pr_url"), push.get("branch"), "pending_human_tars")
            else:
                commit.update({"pushed": False, "push_result": push})
        except Exception as e:
            commit.update({"pushed": False, "push_exception": str(e)[:200]})
    else:  # propose-only
        commit["note"] = "improvement ready; not pushed (propose-only mode)"
        _flag(None, None, None, "proposed_not_pushed")

    judge_required = judge in ("end", "every_k", "on_threshold")
    result = {
        "run_id": run_id, "target": target, "stopped": stopped, "iters_run": len(traj) - 1,
        "accepts": accepts, "baseline": baseline_obj, "champion": best_obj, "objective_key": okey,
        "improved": improved, "mode": mode, "commit": commit,
        "judge_policy": judge, "judge_required": judge_required,
        "ladder": {"provision": "human-gated (Tier-1)", "commit": "mode-gated (Tier-2)", "merge": "human only (Tier-3)"},
        "note": "RSI engine (GUPPI_RSI_ENGINE.CORE); metric-agnostic, step-pluggable, RSI-6 rails on.",
        "trajectory": traj,
    }
    ctx.output(result)
    return result
