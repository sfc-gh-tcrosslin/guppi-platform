-- =============================================================================
-- guppi-platform v3.24.0 — RSI Engine Seed 01: Schema
-- =============================================================================
-- The RSI (Recursive Self-Improvement) engine — Level 9 of the CoCo Maturity
-- Model. This is CORE platform capability, generic and DOMAIN/METRIC-AGNOSTIC:
-- it improves any artifact (prompt, recipe, config) against any objective, on a
-- second, separate database from the value/governance wheel (GUPPIWHEEL.PUBLIC).
--
-- What ships here is the ENGINE (the loop machinery). It does NOT ship any
-- initiative instance — no target profiles, runs, cards, or satellite data.
-- Targets like nextgen/dental/faers/HYPERBOLIC_LAB are ordinary initiatives that
-- USE this engine and are provisioned per-account, never seeded.
--
-- Maturity honesty: this engine is delegation-grade (L9.0) — it runs a gated
-- improvement loop end to end. "Net-positive self-improvement" (L9.1) is NOT
-- claimed; it stays gated on held-out proof (TARS). See the rsi skill.
--
-- Safe to re-run. CREATE ... IF NOT EXISTS for the database/schema/stage/tables
-- so a consuming account's runs/profiles/cards are NEVER overwritten by re-apply.
-- Requires the prerequisites in 00_prereqs.sql (compute pool, Cortex, optional
-- git commit-loop integration + secret).
-- =============================================================================

-- ROLE — the engine's owner/executor. Workflows and procs run as RSI_ENGINE.
CREATE ROLE IF NOT EXISTS RSI_ENGINE
  COMMENT = 'Owner/executor of the Guppi RSI engine (GUPPI_RSI_ENGINE.CORE). Runs the improvement + onboarding workflows.';
-- Platform admin manages the engine role.
GRANT ROLE RSI_ENGINE TO ROLE GUPPIWHEEL_ADMIN;

-- DATABASE + SCHEMA — separate from the wheel by design.
CREATE DATABASE IF NOT EXISTS GUPPI_RSI_ENGINE
  COMMENT = 'Guppi RSI engine — the platform capability that improves the things the wheel builds. Level 9 (Recursion) of the CoCo Maturity Model.';
CREATE SCHEMA IF NOT EXISTS GUPPI_RSI_ENGINE.CORE;
GRANT OWNERSHIP ON DATABASE GUPPI_RSI_ENGINE TO ROLE RSI_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA GUPPI_RSI_ENGINE.CORE TO ROLE RSI_ENGINE COPY CURRENT GRANTS;

USE DATABASE GUPPI_RSI_ENGINE;
USE SCHEMA CORE;

-- Warehouse the engine runs its SQL/Cortex steps on (matches the workflow spec).
GRANT USAGE ON WAREHOUSE SI_DEMO_WH TO ROLE RSI_ENGINE;

-- STAGE — holds the workflow entrypoint code (rsi_loop/main.py, rsi_onboard/main.py).
CREATE STAGE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Python entrypoints for the RSI workflows (RSI_LOOP, RSI_ONBOARD).';

-- =============================================================================
-- ENGINE TABLES — schemas only; NEVER seed rows. IF NOT EXISTS protects data on
-- re-apply. All owned by RSI_ENGINE.
-- =============================================================================

-- RSI_RUNS — the append-only ledger of every iteration (baseline + candidates),
-- the accept/reject decision, score, metrics, and reason. The climb chart reads this.
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.RSI_RUNS (
    RUN_ID       VARCHAR,
    TARGET       VARCHAR,
    ITER         NUMBER(38,0),
    CANDIDATE_ID VARCHAR,
    ACCEPTED     BOOLEAN,
    SCORE        FLOAT,
    METRICS      VARIANT,
    REASON       VARCHAR,
    CREATED_AT   TIMESTAMP_NTZ(6)
);

-- RSI_TARGET_PROFILE — per-target config (objective/guard/direction/metaphor/
-- glossary + the FQN step bindings that make the loop domain-agnostic). One row
-- per target. SHIPS EMPTY — profiles are per-account initiative data.
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.RSI_TARGET_PROFILE (
    TARGET     VARCHAR,
    PROFILE    VARIANT,
    UPDATED_AT TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP()
);

-- EXPERIENCE_CARDS — the loop's endogenous memory (lessons from prior iterations),
-- scored + corroborated, retrieved to ground the next proposal.
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.EXPERIENCE_CARDS (
    CARD_ID        VARCHAR,
    TARGET         VARCHAR,
    RUN_ID         VARCHAR,
    ITER           NUMBER(38,0),
    CARD_TYPE      VARCHAR,
    TRIGGER_KIND   VARCHAR,
    ARTIFACT_REF   VARCHAR,
    LESSON         VARCHAR,
    METRICS_BEFORE VARIANT,
    METRICS_AFTER  VARIANT,
    SCORE          FLOAT DEFAULT 0,
    CORROBORATIONS NUMBER(38,0) DEFAULT 0,
    STATUS         VARCHAR DEFAULT 'proposed',
    CREATED_AT     TIMESTAMP_NTZ(6),
    LAST_SCORED_AT TIMESTAMP_NTZ(6)
);

-- CARD_USAGE — which cards grounded which candidate (for corroboration scoring).
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.CARD_USAGE (
    TARGET       VARCHAR,
    CANDIDATE_ID VARCHAR,
    CARD_ID      VARCHAR,
    USED_AT      TIMESTAMP_NTZ(6)
);

-- AUDIT_FLAGS — provenance of what shipped / awaits human review (commit sha, PR
-- url, TARS verdict, baseline->champion). Drives the "shipped & pending" panel.
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.AUDIT_FLAGS (
    RUN_ID        VARCHAR,
    TARGET        VARCHAR,
    COMMIT_SHA    VARCHAR,
    PR_URL        VARCHAR,
    BRANCH        VARCHAR,
    OBJECTIVE_KEY VARCHAR,
    BASELINE      FLOAT,
    CHAMPION      FLOAT,
    MODE          VARCHAR,
    TARS          VARCHAR,
    STATUS        VARCHAR,
    CREATED_AT    TIMESTAMP_NTZ(9)
);

-- RSI_NOISE_MEASUREMENTS — append-only record of RSI_MEASURE_NOISE runs. Each row
-- = N repeat evals of ONE frozen champion, used to set the accept margin from
-- MEASURED eval noise instead of a guessed constant (standing methodology rule).
CREATE TABLE IF NOT EXISTS GUPPI_RSI_ENGINE.CORE.RSI_NOISE_MEASUREMENTS (
    MEASURE_ID         VARCHAR,
    TARGET             VARCHAR,
    OBJECTIVE_KEY      VARCHAR,
    N_EVALS            NUMBER(38,0),
    ARTIFACT_MD5       VARCHAR,
    SCORES             VARIANT,
    MEAN               FLOAT,
    SD                 FLOAT,
    MIN_SCORE          FLOAT,
    MAX_SCORE          FLOAT,
    SPREAD             FLOAT,
    CI95_HALFWIDTH     FLOAT,
    CURRENT_MARGIN     FLOAT,
    RECOMMENDED_MARGIN FLOAT,
    VERDICT            VARCHAR,
    DETAIL             VARIANT,
    CREATED_AT         TIMESTAMP_NTZ(9)
);

-- Engine owns its tables + stage (COPY CURRENT GRANTS keeps any consumer grants).
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA GUPPI_RSI_ENGINE.CORE TO ROLE RSI_ENGINE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON STAGE GUPPI_RSI_ENGINE.CORE.AUTOMATION_STAGE TO ROLE RSI_ENGINE COPY CURRENT GRANTS;
