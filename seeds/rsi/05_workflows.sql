-- =============================================================================
-- guppi-platform v3.24.0 -- RSI Engine Seed 05: Workflows
-- =============================================================================
-- The two stage-backed Snowflake Workflows that ARE the engine:
--   RSI_LOOP    -- RIGHT side: improve an artifact against its objective (gated).
--   RSI_ONBOARD -- LEFT side: initiative -> self-improving target (human-gated).
-- Both EXECUTE AS 'RSI_ENGINE', run on RSI_AUTO_POOL (02_prereqs.sql), and load
-- their Python entrypoint from AUTOMATION_STAGE.
--
-- Run LAST (needs the schema, procs, compute pool). The PUT statements upload the
-- vendored entrypoints; they use paths RELATIVE TO THE REPO ROOT, so run the
-- bootstrap from the plugin root (as the other seeds are). Safe to re-run.
-- =============================================================================

USE DATABASE GUPPI_RSI_ENGINE;
USE SCHEMA CORE;

-- Upload the workflow entrypoints to the stage (repo-root-relative paths).
PUT file://seeds/rsi/automations/rsi_loop/main.py    @GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE/rsi_loop/    OVERWRITE = TRUE AUTO_COMPRESS = FALSE;
PUT file://seeds/rsi/automations/rsi_onboard/main.py @GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE/rsi_onboard/ OVERWRITE = TRUE AUTO_COMPRESS = FALSE;

CREATE OR REPLACE WORKFLOW GUPPI_RSI_ENGINE.CORE.RSI_LOOP
  execute as 'RSI_ENGINE'
  runtime version '0.0.24'
  compute pool 'RSI_AUTO_POOL'
  warehouse 'SI_DEMO_WH'
  entrypoint 'main:run'
  comment 'Guppi RSI engine (platform, domain-agnostic + metric-agnostic). Steps bound per-run by FQN via input_data.steps.'
  as '@GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE/rsi_loop/';

CREATE OR REPLACE WORKFLOW GUPPI_RSI_ENGINE.CORE.RSI_ONBOARD
  execute as 'RSI_ENGINE'
  runtime version '0.0.24'
  compute pool 'RSI_AUTO_POOL'
  warehouse 'SI_DEMO_WH'
  entrypoint 'main:run'
  comment 'RSI LEFT automation (initiative -> self-improving target). Bob authors epic/stories + target_spec into the wheel; human gates provisioning (Tier-1); substrate materialized; UNCHANGED RSI_LOOP triggered from profile bindings; human merges (Tier-3); merged champion synced + card scored. Phases idempotent by observed state; mode auto-build|do-not.'
  as '@GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE/rsi_onboard/';
