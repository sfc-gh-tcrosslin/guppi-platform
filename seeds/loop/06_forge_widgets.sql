-- =============================================================================
-- guppi-platform -- Forge Config Seed 06: build-plan step-contract WIDGET
-- =============================================================================
-- Mints ONE governed WIDGET artifact that documents the Demo Forge's build-plan
-- step-contract so Bob (the read-only PLANNER) knows how to compose plans that
-- the ReAct build-runner can execute. It ties the forge to the EXISTING
-- build-template widget classes (transform / semantic-index / search-index /
-- agent / governance / verify-build) and pins the VERIFIABLE exit_gate per class
-- -- the "done" check that replaces any grader.
--
-- Idempotent: skips if a WIDGET with this title already exists (re-apply no-op).
-- =============================================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SEED_FORGE_STEP_CONTRACT()
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import json
TITLE = "Forge build-plan step-contract (ReAct build-runner)"
CONTENT = {
  "kind": "step-contract",
  "class": "forge",
  "purpose": ("How to compose a Demo Forge build-plan. The forge is a ReAct build-runner over the "
              "loop kernel: it EXECUTES each step and verifies a VERIFIABLE exit_gate, with bounded "
              "error-recovery. It does NOT grade, rank, or select among build variants -- that is RSI's "
              "job, reachable only via the optional handoff. Keep steps deterministic and idempotent."),
  "step_schema": {
    "step_id": "short stable id, unique within the plan (e.g. 't_cohort')",
    "kind": "one of the widget classes below (drives the default exit_gate)",
    "sql": "ONE fully-qualified statement; use the literal {{SANDBOX}} placeholder for the run schema. "
           "Writes MUST be qualified into {{SANDBOX}} (FORGE_EXEC refuses unqualified writes).",
    "gate_sql": "optional verification query (may use {{SANDBOX}}); passes if it returns >= gate_min_rows rows",
    "gate_min_rows": "optional int, default 1"
  },
  "exit_gate_by_class": {
    "transform": "SELECT COUNT(*) FROM {{SANDBOX}}.<table>  -- table built and non-empty",
    "semantic-index": "DESCRIBE SEMANTIC VIEW {{SANDBOX}}.<view>  (or SHOW SEMANTIC VIEWS LIKE) -- view exists",
    "search-index": "SHOW CORTEX SEARCH SERVICES LIKE '<name>' IN SCHEMA {{SANDBOX}} -- service exists",
    "agent": "DESCRIBE AGENT {{SANDBOX}}.<agent>  (or SHOW AGENTS) -- agent exists",
    "governance": "SELECT COUNT(*) FROM TABLE(...POLICY_REFERENCES...) -- policy attached",
    "verify-build": "the self-check returns overall=pass"
  },
  "budget_defaults": {"max_steps": 12, "max_attempts": 24, "max_retries": 8, "max_retries_per_step": 2},
  "idempotency": ("run_id is deterministic from (target + plan); the kernel journals every step and "
                  "REPLAYS/skips already-succeeded steps on resume, so a re-launch of the same plan is safe."),
  "gates": {"launch": "human GO via FORGE_APPROVE (Tier-1)",
            "improve": "optional handoff into RSI (RUN_TARGET_LIFECYCLE); grading/selection live there only"},
  "how_bob_uses_it": ("Compose an ordered plan[] of steps, each producing one build object from the matching "
                      "build-template class, with an exit_gate. Call FORGE_LAUNCH(plan, target) to STAGE it; a "
                      "human reviews and calls FORGE_APPROVE. Bob never runs the build himself."),
  "origin": "packaged: guppi-platform seeds/loop/06_forge_widgets.sql"
}
TAGS = ["widget", "step-contract", "forge", "react", "bob", "platform", "loop-kernel"]
def run(session):
    ex = session.sql("SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS_CURRENT_V WHERE TYPE='WIDGET' AND TITLE=?",
                     params=[TITLE]).collect()[0][0]
    if int(ex) > 0:
        return {"minted": [], "skipped": [TITLE]}
    session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('WIDGET', ?, 'guppi', ?, NULL, 'Published', ?, NULL, ?)",
                params=[TITLE, json.dumps(CONTENT), json.dumps(TAGS),
                        json.dumps({"packaged": True, "source": "guppi-platform", "epic": "E-46"})]).collect()
    return {"minted": [TITLE], "skipped": []}
$$;
CALL GUPPIWHEEL.PUBLIC.SEED_FORGE_STEP_CONTRACT();
