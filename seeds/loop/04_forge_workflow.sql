-- =============================================================================
-- guppi-platform -- Forge Config Seed 04: ReAct build-runner workflow
-- =============================================================================
-- The Demo Forge driver = a Cortex Workflow Automation whose entrypoint runs the
-- ReAct loop (forge_loop/main.py) over the neutral loop kernel. It executes as
-- FORGE_BUILDER (write authority ONLY in DEMO_FORGE_SANDBOX) and reuses the RSI
-- compute pool. Mirrors the RSI_LOOP workflow mechanism -- same durable runtime,
-- DIFFERENT loop pattern (succeed/recover/fail, no grader).
--
-- Run the bootstrap from the plugin root (PUT path is repo-root-relative).
-- Safe to re-run.
-- =============================================================================

-- Workflow-create privilege for the scoped builder (ownership alone doesn't imply it).
USE ROLE ACCOUNTADMIN;
GRANT CREATE WORKFLOW ON SCHEMA DEMO_FORGE_SANDBOX.CONTROL TO ROLE FORGE_BUILDER;

-- Register the forge config in the kernel's self-describing registry (owned by
-- LOOP_ENGINE). Makes the "one runtime, two patterns" claim inspectable: the
-- DECISION_FN is the ONLY thing that differs from RSI.
USE ROLE LOOP_ENGINE;
MERGE INTO GUPPI_LOOP_ENGINE.CORE.LOOP_CONFIG t
USING (SELECT 'forge' AS CONFIG) s ON t.CONFIG = s.CONFIG
WHEN MATCHED THEN UPDATE SET
    PATTERN = 'react',
    DRIVER = 'DEMO_FORGE_SANDBOX.CONTROL.DEMO_FORGE',
    DECISION_FN = 'succeed / recover-retry / fail (verifiable exit_gate) -- NO grader, NO champion/candidate, NO selection',
    DEFAULTS = PARSE_JSON('{"budget":{"max_steps":12,"max_attempts":24,"max_retries":8,"max_retries_per_step":2},"gate":{"policy":"pre-run"},"ttl_days":7}'),
    NOTE = 'ReAct / plan-execute build-runner. Completion loop only; improvement is RSI''s job via optional handoff.',
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (CONFIG, PATTERN, DRIVER, DECISION_FN, DEFAULTS, NOTE, UPDATED_AT)
VALUES ('forge', 'react', 'DEMO_FORGE_SANDBOX.CONTROL.DEMO_FORGE',
    'succeed / recover-retry / fail (verifiable exit_gate) -- NO grader, NO champion/candidate, NO selection',
    PARSE_JSON('{"budget":{"max_steps":12,"max_attempts":24,"max_retries":8,"max_retries_per_step":2},"gate":{"policy":"pre-run"},"ttl_days":7}'),
    'ReAct / plan-execute build-runner. Completion loop only; improvement is RSI''s job via optional handoff.',
    CURRENT_TIMESTAMP());

-- Upload the entrypoint + create the workflow as the scoped builder.
USE ROLE FORGE_BUILDER;
USE WAREHOUSE SI_DEMO_WH;
PUT file://seeds/loop/automations/forge_loop/main.py @DEMO_FORGE_SANDBOX.CONTROL.FORGE_STAGE/forge_loop/ OVERWRITE = TRUE AUTO_COMPRESS = FALSE;

CREATE OR REPLACE WORKFLOW DEMO_FORGE_SANDBOX.CONTROL.DEMO_FORGE
  execute as 'FORGE_BUILDER'
  runtime version '0.0.24'
  compute pool 'RSI_AUTO_POOL'
  warehouse 'SI_DEMO_WH'
  entrypoint 'main:run'
  comment 'Demo Forge ReAct build-runner (loop kernel forge config). Executes a Bob-composed build-plan into a per-run sandbox: execute step -> verify exit_gate -> bounded error-recovery -> advance. NO grader/champion/selection (that is RSI). Optional final handoff INTO RSI via RUN_TARGET_LIFECYCLE.'
  as '@DEMO_FORGE_SANDBOX.CONTROL.FORGE_STAGE/forge_loop/';
