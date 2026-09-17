"""RSI_ONBOARD -- the LEFT workflow automation (initiative -> self-improving target).

Extends the RSI workflow to the LEFT of RSI_LOOP. Bob authors the epic+stories and the
target_spec INTO the wheel; a human gates provisioning (Tier-1); the substrate is materialized;
the UNCHANGED RSI_LOOP is triggered (per-run FQN bindings assembled from the profile); a human
merges the PR (Tier-3); then the merged champion is synced back and an experience card is scored.

Phases are idempotent by OBSERVED STATE (no state table): each phase checks whether its effect
already exists and skips if so, so a human-gated re-run resumes from the top cleanly.

The automation is PLUMBING. It authors nothing itself -- Bob's cognition lives inside
BOB_WRITE_EPIC_STORIES and BUILD_SUBSTRATE; the impartial grader lives in the engine; this
entrypoint only orchestrates + gates + hands off to the unchanged loop.

input_data:
{
  "research_id":"RES-...", "initiative":"INIT-...", "product":"<slug>",
  "target":"<slug>",              # RSI target label (defaults to product)
  "title":"<human title>",
  "mode":"auto-build"|"do-not",   # autonomy: do-not stops for human review before building
  "approve_provision": false,      # Tier-1 human gate; set true to allow provisioning
  "loop_mode":"auto-push"|"propose-only",
  "loop":{...}, "budget":{...}     # forwarded to RSI_LOOP
}
"""
import json

_ENG = "GUPPI_RSI_ENGINE.CORE"


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
    research = p.get("research_id")
    init = p.get("initiative")
    product = p.get("product")
    target = p.get("target") or product
    title = p.get("title") or (product or target)
    mode = str(p.get("mode", "auto-build")).lower()
    approve = bool(p.get("approve_provision", False))
    loop_mode = str(p.get("loop_mode", "auto-push")).lower()
    run_id = ctx.run_id
    phases = []

    def rec(name, status, **kw):
        phases.append(dict(phase=name, status=status, **kw))

    def done(next_action=None, **extra):
        out = dict(run_id=run_id, target=target, phases=phases, complete=(next_action is None))
        if next_action:
            out["human_action"] = next_action
        out.update(extra)
        ctx.output(out)
        return out

    if not (research and init and product):
        return done(error="missing research_id/initiative/product")

    # ---- Phase 1: write_epic_stories (Bob authors; idempotent in-proc) ----
    ws = _cell(ctx.query("CALL GUPPIWHEEL.PUBLIC.BOB_WRITE_EPIC_STORIES(:1,:2,:3)",
                         [research, init, product])) or {}
    epic = ws.get("epic_id") or p.get("epic")
    rec("write_epic_stories", "ok" if epic else "error",
        epic=epic, idempotent=ws.get("idempotent"), stories=ws.get("story_ids"))
    if not epic:
        return done(error="no epic from write_epic_stories", detail=ws)

    spec_present = bool(_cell(ctx.query(
        "SELECT CONTENT:target_spec IS NOT NULL FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=:1", [epic])))

    # ---- do-not autonomy gate: stop before building unless auto-build ----
    if mode == "do-not" and not spec_present:
        rec("stories_gate", "await_human")
        return done(next_action=("Review stories for %s (target '%s'), then re-run with "
                                 "mode='auto-build' to let Bob build the substrate." % (epic, target)))

    # ---- Phase 2: build_substrate (Bob authors target_spec into the epic) ----
    if not spec_present:
        bs = _cell(ctx.query("CALL GUPPIWHEEL.PUBLIC.BUILD_SUBSTRATE(:1,:2,:3)",
                             [init, epic, False])) or {}
        spec_present = bool(_cell(ctx.query(
            "SELECT CONTENT:target_spec IS NOT NULL FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=:1", [epic])))
        rec("build_substrate", "ok" if spec_present else "error", detail=bs)
        if not spec_present:
            return done(error="build_substrate did not persist target_spec", detail=bs)
    else:
        rec("build_substrate", "skip_present")

    # ---- substrate lint gate (defense in depth): the contract must pass before we provision ----
    spec_v = _cell(ctx.query("SELECT CONTENT:target_spec FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=:1", [epic]))
    lint = _cell(ctx.query("CALL GUPPIWHEEL.PUBLIC.SUBSTRATE_LINT(PARSE_JSON(:1))", [json.dumps(spec_v)])) or {}
    rec("substrate_lint", "ok" if lint.get("ok") else "fail", failures=lint.get("failures"))
    if not lint.get("ok"):
        return done(next_action=("Substrate failed the contract lint: " + "; ".join(lint.get("failures", [])) +
                                 ". Re-run build_substrate (it now self-corrects and self-lints)."))

    prof_status = _cell(ctx.query(
        "SELECT PROFILE:status::string FROM " + _ENG + ".RSI_TARGET_PROFILE WHERE TARGET=:1", [target]))
    provisioned = prof_status in ("substrate_ready", "provisioned")

    # ---- Phase 3: provision gate (Tier-1 HITL) ----
    if not provisioned and not approve:
        rec("provision_gate", "await_human")
        return done(next_action=("Approve Tier-1 provisioning of '%s' (creates a private GitHub repo "
                                 "+ domain DB). Re-run with approve_provision=true." % target))

    # ---- Phase 4: provision (materialize substrate from the epic spec) ----
    if not provisioned:
        spec = _cell(ctx.query("SELECT CONTENT:target_spec FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID=:1", [epic]))
        pr = _cell(ctx.query("CALL " + _ENG + ".RSI_PROVISION_TARGET(:1,:2,:3,PARSE_JSON(:4))",
                             [target, title, "PROVISION " + target, json.dumps(spec)])) or {}
        provisioned = bool(pr.get("ok"))
        rec("provision", "ok" if provisioned else "error", detail=pr.get("steps") or pr)
        if not provisioned:
            return done(error="provision failed", detail=pr)
    else:
        rec("provision", "skip_present")

    prof = _cell(ctx.query("SELECT PROFILE FROM " + _ENG + ".RSI_TARGET_PROFILE WHERE TARGET=:1", [target])) or {}
    steps = prof.get("steps", {}) or {}
    dcfg = prof.get("decide_config", {}) or {}
    default_branch = (prof.get("repo", {}) or {}).get("default_branch", "main")

    loop_ran = bool(_cell(ctx.query(
        "SELECT COUNT(*)>0 FROM " + _ENG + ".AUDIT_FLAGS WHERE TARGET=:1", [target])))

    # ---- Phase 5: trigger the UNCHANGED RSI_LOOP ----
    if not loop_ran:
        loop_input = json.dumps({
            "target": target, "steps": steps, "decide_config": dcfg,
            "loop": p.get("loop", {"n_loops": 5, "convergence_k": 2}),
            "budget": p.get("budget", {"max_evals": 8}),
            "mode": loop_mode, "judge_policy": "end", "start_from": default_branch,
        })
        ra = _cell(ctx.query("SELECT SYSTEM$RUN_AUTOMATION('" + _ENG + ".RSI_LOOP', :1)", [loop_input]))
        loop_out = ra.get("output") if isinstance(ra, dict) else ra
        if isinstance(loop_out, str):
            try:
                loop_out = json.loads(loop_out)
            except Exception:
                pass
        rec("run_loop", "ok", loop=loop_out)
    else:
        rec("run_loop", "skip_present")

    pend = _cell(ctx.query(
        "SELECT OBJECT_CONSTRUCT('pr_url',PR_URL,'commit_sha',COMMIT_SHA,'status',STATUS,'branch',BRANCH) "
        "FROM " + _ENG + ".AUDIT_FLAGS WHERE TARGET=:1 AND PR_URL IS NOT NULL "
        "ORDER BY CREATED_AT DESC LIMIT 1", [target])) or {}
    pr_url = pend.get("pr_url")
    pushed_sha = pend.get("commit_sha")

    # ---- Phase 6: merge gate (Tier-3 HITL) + merge detection via main head ----
    synced = False
    if pr_url:
        sync = _cell(ctx.query("CALL " + _ENG + ".RSI_SYNC_TARGET(:1,:2)", [target, default_branch])) or {}
        main_head = sync.get("head")
        if main_head and pushed_sha and str(main_head) == str(pushed_sha):
            synced = True
            rec("merge_gate", "merged", pr_url=pr_url, main_head=main_head)
            rec("sync", "ok", detail=sync)
        else:
            rec("merge_gate", "await_human", pr_url=pr_url, main_head=main_head, pushed_sha=pushed_sha)
            return done(next_action=("Review + merge the PR (Tier-3): %s . Then re-run to sync the "
                                     "merged champion." % pr_url))
    else:
        rec("merge_gate", "no_pr", note="loop did not push (propose-only or no improvement)")

    # ---- Phase 7: experience card ----
    try:
        card = _cell(ctx.query("CALL " + _ENG + ".RSI_SCORE_CARDS(:1)", [target]))
        rec("card", "ok", detail=card)
    except Exception as e:
        rec("card", "warn", error=str(e)[:150])

    return done(provisioned=True, synced=synced, pr_url=pr_url)
