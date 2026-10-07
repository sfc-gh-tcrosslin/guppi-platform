-- =============================================================================
-- guppi-platform -- Loop Kernel Seed 01: Roles + Schema
-- =============================================================================
-- The NEUTRAL loop kernel: a bounded, durable, resumable step-loop runtime.
-- It is the shared substrate underneath TWO loop patterns (loop engineering,
-- 2026 consensus):
--   * REFLECTION (generate -> evaluate-against-criteria -> revise, grader-driven)
--     -- this is RSI (GUPPI_RSI_ENGINE.CORE). Quality/selection.
--   * ReAct / plan-execute (reason -> act -> observe -> repeat until a VERIFIABLE
--     goal is met, NO grader) -- this is the Demo Forge. Completion/execution.
--
-- One runtime, two configs. The kernel owns the primitives every durable agent
-- loop needs -- named-step boundaries + replay, idempotency keys, an explicit
-- termination contract (iteration/cost/time budget + verifiable done-predicate +
-- no-progress detection), circuit breakers, a durable human gate, and a
-- trajectory ledger. The CONFIG's decision function is the only thing that
-- differs between patterns; the kernel is deliberately unaware of "better/worse".
--
-- This is why we do NOT get two RSIs: the forge cannot select build variants
-- against a score -- that is the Reflection config's job, and it lives elsewhere.
--
-- Safe to re-run: CREATE ... IF NOT EXISTS for role/db/schema/stage so a
-- consuming account's runs are NEVER overwritten by re-apply.
-- =============================================================================

-- ROLE -- the neutral kernel's owner/executor. The kernel is NOT RSI-owned.
CREATE ROLE IF NOT EXISTS LOOP_ENGINE
  COMMENT = 'Owner of the neutral Guppi loop kernel (GUPPI_LOOP_ENGINE.CORE): the bounded/durable/resumable step-loop runtime shared by RSI (Reflection config) and the Demo Forge (ReAct config).';

-- ROLE -- the Demo Forge's scoped executor. Writes ONLY in DEMO_FORGE_SANDBOX;
-- appends to the kernel ledger; has NO other write authority. Modeled on the
-- CODING_BOB scoped-builder precedent (own schema + CREATE WORKFLOW + SI_DEMO_WH
-- + compute pool + Cortex), but caged to the sandbox.
CREATE ROLE IF NOT EXISTS FORGE_BUILDER
  COMMENT = 'Scoped executor for the Demo Forge ReAct build-runner. Writes ONLY in DEMO_FORGE_SANDBOX; appends to the loop kernel ledger; no other write authority. Bob (read-only) never holds this role -- he only triggers a governed launcher.';

-- Platform admin manages both engine roles (mirrors RSI_ENGINE -> GUPPIWHEEL_ADMIN).
GRANT ROLE LOOP_ENGINE  TO ROLE GUPPIWHEEL_ADMIN;
GRANT ROLE FORGE_BUILDER TO ROLE GUPPIWHEEL_ADMIN;
-- Grant to ACCOUNTADMIN so the installing admin can administer/validate now.
GRANT ROLE LOOP_ENGINE  TO ROLE ACCOUNTADMIN;
GRANT ROLE FORGE_BUILDER TO ROLE ACCOUNTADMIN;

-- KERNEL DATABASE + SCHEMA -- neutral, separate from both the wheel and RSI.
CREATE DATABASE IF NOT EXISTS GUPPI_LOOP_ENGINE
  COMMENT = 'Neutral loop kernel -- the bounded/durable/resumable step-loop runtime shared by RSI (Reflection) and the Demo Forge (ReAct). Not RSI-owned; RSI and the forge are two configs over this substrate.';
CREATE SCHEMA IF NOT EXISTS GUPPI_LOOP_ENGINE.CORE;
GRANT OWNERSHIP ON DATABASE GUPPI_LOOP_ENGINE TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA GUPPI_LOOP_ENGINE.CORE TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;

-- SANDBOX DATABASE -- the ONLY place the forge may write. FORGE_BUILDER owns it,
-- so it can mint per-run schemas here; a reaper task drops them past TTL. Nothing
-- here is durable infra -- dropping a run schema is the forge's compensation step.
CREATE DATABASE IF NOT EXISTS DEMO_FORGE_SANDBOX
  COMMENT = 'Ephemeral build sandbox for the Demo Forge. FORGE_BUILDER owns it; per-run schemas are created here and reaped by TTL. Cage boundary: the forge has write authority NOWHERE else.';
GRANT OWNERSHIP ON DATABASE DEMO_FORGE_SANDBOX TO ROLE FORGE_BUILDER COPY CURRENT GRANTS;

-- STAGE -- holds the workflow entrypoint code for the kernel's pattern drivers
-- (e.g. the forge ReAct driver: forge_loop/main.py).
USE DATABASE GUPPI_LOOP_ENGINE;
USE SCHEMA CORE;
CREATE STAGE IF NOT EXISTS GUPPI_LOOP_ENGINE.CORE.AUTOMATION_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Python entrypoints for the loop kernel pattern drivers (forge ReAct driver, etc.).';
GRANT OWNERSHIP ON STAGE GUPPI_LOOP_ENGINE.CORE.AUTOMATION_STAGE TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;

-- SHARED COMPUTE + CORTEX for both engine roles.
GRANT USAGE ON WAREHOUSE SI_DEMO_WH TO ROLE LOOP_ENGINE;
GRANT USAGE ON WAREHOUSE SI_DEMO_WH TO ROLE FORGE_BUILDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE LOOP_ENGINE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE FORGE_BUILDER;

-- Compute pool for the forge workflow (reuse the RSI pool -- lighter default).
GRANT USAGE   ON COMPUTE POOL RSI_AUTO_POOL TO ROLE FORGE_BUILDER;
GRANT MONITOR ON COMPUTE POOL RSI_AUTO_POOL TO ROLE FORGE_BUILDER;

-- FORGE_BUILDER needs its own automation stage for the forge driver code; it
-- lives in the kernel DB and is owned by the kernel role, but FORGE_BUILDER reads
-- it at run time.

-- =============================================================================
-- KERNEL TABLES -- schemas only; the durable-execution backbone. Owned by
-- LOOP_ENGINE. IF NOT EXISTS protects live runs on re-apply. Both loop patterns
-- (Reflection = RSI, ReAct = forge) write here through the kernel procs; neither
-- writes these tables directly (cage: consumers get proc USAGE, not table DML).
-- =============================================================================

-- LOOP_RUN -- one durable row per run: the resumable header (cursor, budget,
-- spend tally, scope, gate state, terminal result). The launcher assigns a STABLE
-- RUN_ID so a re-launch of the same work resumes the same run (idempotent).
CREATE TABLE IF NOT EXISTS GUPPI_LOOP_ENGINE.CORE.LOOP_RUN (
    RUN_ID       VARCHAR,                 -- stable, launcher-assigned resume key
    CONFIG       VARCHAR,                 -- 'forge' | 'rsi' | ...
    PATTERN      VARCHAR,                 -- 'react' | 'reflection'
    TARGET       VARCHAR,                 -- build_plan_id (forge) / target label (rsi)
    STATUS       VARCHAR,                 -- running|awaiting_gate|done|failed|budget_exhausted|stalled|cancelled
    STEP_CURSOR  NUMBER(38,0) DEFAULT 0,  -- last completed step ordinal (resume from cursor+1)
    BUDGET       VARIANT,                 -- {max_steps,max_retries,max_seconds,max_cost}
    SPENT        VARIANT,                 -- {steps,retries,seconds,cost}
    SCOPE        VARCHAR,                 -- sandbox schema FQN (forge) / target schema (rsi)
    GATE         VARIANT,                 -- {policy,state,token,decided_by,decided_at}
    INPUT        VARIANT,                 -- full input_data (plan/config)
    RESULT       VARIANT,                 -- terminal result
    STARTED_AT   TIMESTAMP_NTZ(6),
    UPDATED_AT   TIMESTAMP_NTZ(6)
);

-- LOOP_STEP -- append-only journal, one row per step ATTEMPT. This is the
-- idempotency + replay backbone: before running a step the driver checks for a
-- SUCCEEDED row with the same (RUN_ID, STEP_ID) and REUSES its RESULT instead of
-- re-executing (durable-execution memoization -> no duplicate side effects on
-- resume). Also the trajectory log every loop-engineering guide calls for.
CREATE TABLE IF NOT EXISTS GUPPI_LOOP_ENGINE.CORE.LOOP_STEP (
    RUN_ID          VARCHAR,
    STEP_ID         VARCHAR,                 -- logical step identity within the run
    STEP_IDX        NUMBER(38,0),            -- ordinal in the plan
    ATTEMPT         NUMBER(38,0) DEFAULT 0,  -- 0-based retry counter (circuit breaker)
    IDEMPOTENCY_KEY VARCHAR,                 -- md5(run_id||step_id||attempt[||input_hash])
    KIND            VARCHAR,                 -- widget class (forge) / role: champion|propose|eval|decide (rsi)
    STATUS          VARCHAR,                 -- succeeded|failed|recovered|skipped_recorded
    INPUT_HASH      VARCHAR,                 -- detect same-input replays
    RESULT          VARIANT,                 -- memoized result (returned on replay)
    ERROR           VARCHAR,
    STARTED_AT      TIMESTAMP_NTZ(6),
    ENDED_AT        TIMESTAMP_NTZ(6)
);

-- LOOP_CONFIG -- self-describing registry of the named loop configs over this
-- kernel. Ships EMPTY; 'forge' is registered when its driver is created, 'rsi'
-- when RSI adopts the kernel. Makes the "one runtime, two patterns" claim
-- inspectable: exactly which decision function each config uses.
CREATE TABLE IF NOT EXISTS GUPPI_LOOP_ENGINE.CORE.LOOP_CONFIG (
    CONFIG      VARCHAR,     -- 'forge' | 'rsi'
    PATTERN     VARCHAR,     -- 'react' | 'reflection'
    DRIVER      VARCHAR,     -- workflow FQN / entrypoint ref
    DECISION_FN VARCHAR,     -- human-readable decision contract (the ONLY per-pattern difference)
    DEFAULTS    VARIANT,     -- default budget / gate_policy
    NOTE        VARCHAR,
    UPDATED_AT  TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP()
);

-- Kernel owns its tables (COPY CURRENT GRANTS keeps any consumer grants).
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA GUPPI_LOOP_ENGINE.CORE TO ROLE LOOP_ENGINE COPY CURRENT GRANTS;

-- Consumers (forge now, RSI later) resolve + call the kernel; they get proc USAGE
-- (added in 02_procs.sql), never direct table DML. Grant the resolution path +
-- stage read here.
GRANT USAGE ON DATABASE GUPPI_LOOP_ENGINE           TO ROLE FORGE_BUILDER;
GRANT USAGE ON SCHEMA   GUPPI_LOOP_ENGINE.CORE       TO ROLE FORGE_BUILDER;
GRANT READ  ON STAGE    GUPPI_LOOP_ENGINE.CORE.AUTOMATION_STAGE TO ROLE FORGE_BUILDER;
