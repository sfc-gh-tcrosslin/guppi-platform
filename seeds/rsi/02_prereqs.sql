-- =============================================================================
-- guppi-platform v3.24.0 — RSI Engine Seed 02: Prerequisites (required)
-- =============================================================================
-- Account-level infrastructure the RSI engine needs to run its loop. Runs AFTER
-- 01_schema.sql (the RSI_ENGINE role must already exist). RUN AS ACCOUNTADMIN
-- (compute pools + the Cortex database-role grant are admin-gated).
--
-- This is the REQUIRED baseline. The engine runs PROPOSE-ONLY with just this.
-- The optional git commit-loop (open a PR for human merge) is 04_commit_loop.sql.
--
-- Safe to re-run (IF NOT EXISTS + idempotent grants).
-- =============================================================================

-- Compute pool the RSI workflows run on (RSI_LOOP / RSI_ONBOARD). Small, single
-- node, auto-suspends after 5 min idle.
CREATE COMPUTE POOL IF NOT EXISTS RSI_AUTO_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_S
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 300
  COMMENT = 'Compute pool for the Guppi RSI workflows (RSI_LOOP, RSI_ONBOARD).';

-- Cortex — the loop's propose/eval/champion/narrate steps call Cortex models.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE RSI_ENGINE;

-- Compute pool access for the engine role.
GRANT USAGE, MONITOR ON COMPUTE POOL RSI_AUTO_POOL TO ROLE RSI_ENGINE;
