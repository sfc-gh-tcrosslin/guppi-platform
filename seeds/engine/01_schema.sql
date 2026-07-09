-- =============================================================================
-- guppi-platform v3.8.1 — Engine Seed 01: Schema
-- TIER 0 (INVARIANT): ARTIFACTS source-of-truth, gap-free ID_CONVENTIONS registry,
--   revoked direct INSERT, DUPLICATE_ID_SCREAM_V + GROUNDING_HEALTH_V tripwires.
--   Re-author SQL if you must, but these guarantees must survive (see COCO.md, Tier 0).
-- Safe to re-run. CREATE OR REPLACE for views, CREATE IF NOT EXISTS for tables.
-- Customer DATA in ARTIFACTS, RULES, VIOLATIONS, ID_CONVENTIONS, INITIATIVE_STEPS,
-- ARTIFACT_LAUNCHES, PLUGIN_VERSION, PRODUCTS — never overwritten by this seed.
-- =============================================================================

-- DATABASE + SCHEMA
CREATE DATABASE IF NOT EXISTS GUPPIWHEEL;
CREATE SCHEMA IF NOT EXISTS GUPPIWHEEL.PUBLIC;
USE DATABASE GUPPIWHEEL;
USE SCHEMA PUBLIC;

-- =============================================================================
-- ARTIFACTS — single source of truth
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.ARTIFACTS (
    ID          VARCHAR(64)     NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    TYPE        VARCHAR(20)     NOT NULL,
    STAGE       VARCHAR(20)     DEFAULT 'Initiate',
    PARENT_ID   VARCHAR(64),
    SUPERSEDED_BY VARCHAR(64),
    TITLE       VARCHAR(500),
    CONTENT     VARIANT,
    TAGS        ARRAY,
    OWNER       VARCHAR(200),
    CREATED_AT  TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT  TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    METADATA    VARIANT,
    PRODUCT_ID  VARCHAR(50)     -- STO-SUBSTRATE-8: controlled product membership (FK to PRODUCTS); the share/no-share boundary
);

-- Self-heal existing installs: CREATE TABLE IF NOT EXISTS won't add SUPERSEDED_BY/PRODUCT_ID or widen
-- ID/PARENT_ID on a pre-existing ARTIFACTS. These ALTERs are idempotent (no-ops on fresh installs).
-- SUPERSEDED_BY (RULE-025) + 64-char IDs are required by the serving/TARS views below.
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ADD COLUMN IF NOT EXISTS SUPERSEDED_BY VARCHAR(64);
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ADD COLUMN IF NOT EXISTS PRODUCT_ID VARCHAR(50);
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ALTER COLUMN ID SET DATA TYPE VARCHAR(64);
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ALTER COLUMN PARENT_ID SET DATA TYPE VARCHAR(64);
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ALTER COLUMN SUPERSEDED_BY SET DATA TYPE VARCHAR(64);

-- =============================================================================
-- RULES — governance as data
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.RULES (
    RULE_ID         VARCHAR(30)     NOT NULL PRIMARY KEY,
    RULE_TYPE       VARCHAR(30)     NOT NULL,
    APPLIES_TO_TYPE VARCHAR(30)     DEFAULT 'ALL',
    FROM_STAGE      VARCHAR(20),
    TO_STAGE        VARCHAR(20),
    CONDITION_SQL   VARCHAR(4000)   NOT NULL,
    ENFORCEMENT     VARCHAR(10)     NOT NULL DEFAULT 'warn',
    OVERRIDABLE     BOOLEAN         DEFAULT FALSE,
    MESSAGE         VARCHAR(4000)   NOT NULL,
    ENABLED         BOOLEAN         DEFAULT TRUE,
    VERSION         NUMBER          DEFAULT 1,
    CREATED_AT      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    CREATED_BY      VARCHAR(200)    DEFAULT CURRENT_USER()
);
-- Self-heal: widen MESSAGE on pre-existing installs (CREATE TABLE IF NOT EXISTS won't). Several doctrine
-- messages (RULE-026/028) exceed 1000 chars; 1000 silently stubbed them on older installs. Idempotent.
ALTER TABLE GUPPIWHEEL.PUBLIC.RULES ALTER COLUMN MESSAGE SET DATA TYPE VARCHAR(4000);


-- =============================================================================
-- VIOLATIONS — where broken rules land
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.VIOLATIONS (
    VIOLATION_ID    VARCHAR(36)     NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    RULE_ID         VARCHAR(30)     NOT NULL,
    ARTIFACT_ID     VARCHAR(64)     NOT NULL,
    STATUS          VARCHAR(20)     DEFAULT 'open',
    OVERRIDE_REASON VARCHAR(1000),
    DETECTED_AT     TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    RESOLVED_AT     TIMESTAMP_NTZ,
    RESOLVED_BY     VARCHAR(200)
);

-- =============================================================================
-- ID_CONVENTIONS — sequence tracker
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.ID_CONVENTIONS (
    ENTITY    VARCHAR(50) NOT NULL PRIMARY KEY,
    NEXT_SEQ  NUMBER      NOT NULL DEFAULT 1,
    ID_PREFIX VARCHAR(20),   -- RULE-029: literal prefix CREATE_ARTIFACT prepends (e.g. 'INIT-'); NULL = descriptive / product-registered, no auto-alloc
    NOTES     VARCHAR(500)
);

-- =============================================================================
-- INITIATIVE_STEPS — Rocky step logs
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.INITIATIVE_STEPS (
    STEP_ID         VARCHAR(36)     NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    INITIATIVE_ID   VARCHAR(64)     NOT NULL,
    STEP_NUMBER     NUMBER,
    AGENT_ID        VARCHAR(100),
    ACTION_TYPE     VARCHAR(50),
    PROMPT          VARCHAR,
    RESPONSE        VARCHAR,
    STARTED_AT      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    COMPLETED_AT    TIMESTAMP_NTZ,
    METADATA        VARIANT
);

-- =============================================================================
-- MODEL_CATALOG — INIT-36 foundation-model agnosticism (RULE-023). The set of
-- models Bob authors with and cross-judges across. ROLE allows future judge-only
-- models. Adding/removing a model = a row here, never a code change.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.MODEL_CATALOG (
    MODEL_NAME    VARCHAR(100) NOT NULL PRIMARY KEY,
    PROVIDER      VARCHAR(50),
    ROLE          VARCHAR(50)  DEFAULT 'authoring',  -- authoring | judge | both
    ENABLED       BOOLEAN      DEFAULT TRUE,
    LAST_VERIFIED TIMESTAMP_NTZ,
    NOTES         VARCHAR(500)
);
-- Seed the verified-callable models (insert-if-missing so re-runs don't clobber toggles).
MERGE INTO GUPPIWHEEL.PUBLIC.MODEL_CATALOG t
USING (
  SELECT 'claude-sonnet-4-5' AS MODEL_NAME, 'Anthropic' AS PROVIDER UNION ALL
  SELECT 'openai-gpt-4.1', 'OpenAI' UNION ALL
  SELECT 'llama3.3-70b', 'Meta' UNION ALL
  SELECT 'mistral-large2', 'Mistral'
) s ON t.MODEL_NAME = s.MODEL_NAME
WHEN NOT MATCHED THEN INSERT (MODEL_NAME, PROVIDER, ROLE, ENABLED, LAST_VERIFIED, NOTES)
  VALUES (s.MODEL_NAME, s.PROVIDER, 'authoring', TRUE, CURRENT_TIMESTAMP(), 'Cortex AI_COMPLETE verified callable');

-- BOB_BAKEOFF_CANDIDATES — working set for Bob's model bake-off (scratch; winners become artifacts).
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.BOB_BAKEOFF_CANDIDATES (
    RUN_ID      VARCHAR(64),
    RESEARCH_ID VARCHAR(64),
    MODEL_NAME  VARCHAR(100),
    NARRATIVE   VARCHAR,
    CREATED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- PRODUCTS — for Command Center grouping
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.PRODUCTS (
    PRODUCT_ID      VARCHAR(50)     NOT NULL PRIMARY KEY,
    NAME            VARCHAR(200),
    DESCRIPTION     VARCHAR,
    STATUS          VARCHAR(20)     DEFAULT 'active',
    CREATED_AT      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- ARTIFACT_LAUNCHES — audit log of artifact opens
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.ARTIFACT_LAUNCHES (
    LAUNCH_ID     VARCHAR(36)   NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    ARTIFACT_ID   VARCHAR(64)   NOT NULL,
    CALLER        VARCHAR(200)  DEFAULT CURRENT_USER(),
    APP_TYPE      VARCHAR(50),
    RESULT_TYPE   VARCHAR(50),
    RESULT_VALUE  VARCHAR(2000),
    TTL_SECONDS   NUMBER,
    EXPIRES_AT    TIMESTAMP_NTZ,
    LAUNCHED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- STAGE_TRANSITIONS — timestamped log of every stage change (proc-written).
-- Enables REAL cycle-time/speed metrics. Written by ADVANCE_STAGE ('advance')
-- and CREATE_ARTIFACT ('birth'). Historical transitions are unrecoverable;
-- speed accrues forward from install of this table.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.STAGE_TRANSITIONS (
    TRANSITION_ID   VARCHAR(36)   NOT NULL DEFAULT UUID_STRING() PRIMARY KEY,
    ARTIFACT_ID     VARCHAR(64)   NOT NULL,
    ARTIFACT_TYPE   VARCHAR(20),
    FROM_STAGE      VARCHAR(20),
    TO_STAGE        VARCHAR(20),
    TRANSITIONED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    ACTOR           VARCHAR(200)  DEFAULT CURRENT_USER(),
    OVERRIDE_REASON VARCHAR(4000),
    SOURCE          VARCHAR(20)
);

-- =============================================================================
-- PLUGIN_VERSION — what's installed
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.PLUGIN_VERSION (
    PLUGIN_NAME     VARCHAR(100)    NOT NULL PRIMARY KEY,
    VERSION         VARCHAR(20)     NOT NULL,
    INSTALLED_AT    TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    INSTALLED_BY    VARCHAR(200)    DEFAULT CURRENT_USER(),
    NOTES           VARCHAR(500)
);

MERGE INTO GUPPIWHEEL.PUBLIC.PLUGIN_VERSION t
USING (SELECT 'guppi-platform' AS PLUGIN_NAME, '3.8.1' AS VERSION) s
ON t.PLUGIN_NAME = s.PLUGIN_NAME
WHEN MATCHED THEN UPDATE SET VERSION = s.VERSION, INSTALLED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (PLUGIN_NAME, VERSION) VALUES (s.PLUGIN_NAME, s.VERSION);

-- =============================================================================
-- ARTIFACT_ASSETS — internal stage for HTML/PDF bytes
-- =============================================================================
CREATE STAGE IF NOT EXISTS GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Internal stage for artifact bytes (HTML, PDF, static visualizations). Referenced via metadata.launch.stage_path on ARTIFACTS rows.';

-- =============================================================================
-- SENSITIVITY tag
-- =============================================================================
CREATE TAG IF NOT EXISTS GUPPIWHEEL.PUBLIC.SENSITIVITY
  ALLOWED_VALUES 'public', 'internal', 'customer_facing', 'confidential'
  COMMENT = 'Classification of artifact bytes. Drives access policies and audit posture.';

-- =============================================================================
-- TYPE-SPECIFIC VIEWS (optional convenience over the unified ARTIFACTS table)
-- =============================================================================
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.INITIATIVES_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       METADATA:priority::VARCHAR AS PRIORITY,
       METADATA:account::VARCHAR AS ACCOUNT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'INITIATIVE';

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.RESEARCH_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       CONTENT:verdict::VARCHAR AS VERDICT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'RESEARCH';

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.STORIES_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       METADATA:priority::VARCHAR AS PRIORITY,
       METADATA:story_points::NUMBER AS POINTS
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'STORY';

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.APPS_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       METADATA:launch:app_type::VARCHAR AS APP_TYPE,
       METADATA:launch:url::VARCHAR AS URL,
       METADATA:launch:identifier::VARCHAR AS IDENTIFIER
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE IN ('APP','MODEL','DASHBOARD');

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.NARRATIVES_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       METADATA:launch:stage_path::VARCHAR AS STAGE_PATH
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'NARRATIVE';

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.AUDITS_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       CONTENT:score::FLOAT AS TRUST_SCORE,
       CONTENT:grade::VARCHAR AS GRADE
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'AUDIT';

-- TARS_AUDITS_V / TARS_FINDINGS_V — TARS trust audits live IN-WHEEL as AUDIT artifacts
-- (STO-SUBSTRATE-9: one place; the artifact IS the TARS output). No AUDIT_RUNS/AUDIT_FINDINGS tables.
-- A TARS AUDIT artifact's CONTENT carries: target, target_type, score, grade, c_signals, d_signals,
-- total_checks, builder_vote, tars_vote, human_vote, human_conditions, status, findings[] (array of
-- {check_name,tier,signal,weight,description,evidence,model_used,action_required,disposition}).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.TARS_AUDITS_V AS
SELECT
  a.ID                               AS audit_id,
  a.CONTENT:target::STRING           AS target_name,
  a.CONTENT:target_type::STRING      AS target_type,
  a.CONTENT:score::FLOAT             AS trust_score,
  a.CONTENT:grade::STRING            AS grade,
  a.CONTENT:c_signals::INT           AS c_signals,
  a.CONTENT:d_signals::INT           AS d_signals,
  a.CONTENT:total_checks::INT        AS total_checks,
  a.CONTENT:builder_vote::STRING     AS builder_vote,
  a.CONTENT:tars_vote::STRING        AS tars_vote,
  a.CONTENT:human_vote::STRING       AS human_vote,
  a.CONTENT:human_conditions::STRING AS human_conditions,
  COALESCE(a.CONTENT:status::STRING, 'COMPLETE') AS status,
  a.CREATED_AT                       AS audit_date
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.TYPE = 'AUDIT' AND a.CONTENT:score IS NOT NULL AND a.SUPERSEDED_BY IS NULL;

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.TARS_FINDINGS_V AS
SELECT
  a.ID                               AS audit_id,
  f.value:check_name::STRING         AS check_name,
  f.value:tier::INT                  AS tier,
  f.value:signal::STRING             AS signal,
  f.value:weight::FLOAT              AS weight,
  f.value:description::STRING        AS description,
  f.value:evidence::STRING           AS evidence,
  f.value:model_used::STRING         AS model_used,
  f.value:action_required::STRING    AS action_required,
  f.value:disposition::STRING        AS disposition
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a,
     LATERAL FLATTEN(input => a.CONTENT:findings, outer => FALSE) f
WHERE a.TYPE = 'AUDIT' AND a.CONTENT:score IS NOT NULL AND a.SUPERSEDED_BY IS NULL;

-- DUPLICATE_ID_SCREAM_V — RULE-029 tripwire. Should ALWAYS be empty. Watched by the data-hygiene agent.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.DUPLICATE_ID_SCREAM_V AS
SELECT ID, COUNT(*) AS row_count, LISTAGG(DISTINCT TYPE, ',') AS types,
       LISTAGG(DISTINCT LEFT(TITLE,40), ' | ') AS titles, MAX(UPDATED_AT) AS last_touch
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
GROUP BY ID HAVING COUNT(*) > 1;

-- GROUNDING_HEALTH_V — Stewart's senses (RULE-027). Deterministic grounding/hygiene drift signals; healthy = all N=0.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.GROUNDING_HEALTH_V AS
WITH canon_type AS (
  SELECT column1 AS t FROM VALUES ('INITIATIVE'),('RESEARCH'),('STORY'),('EPIC'),('APP'),('MODEL'),('DASHBOARD'),('NARRATIVE'),('DEFECT'),('INCIDENT'),('AUDIT'),('OPS_EVENT'),('OUTCOME'),('SKILL')
),
canon_stage AS (
  SELECT column1 AS s FROM VALUES ('Initiate'),('Research'),('Building'),('Built'),('Narrated'),('Resolved'),('ASPIRATIONAL'),('SELECTED'),('TRACKED'),('RESOLVED')
)
SELECT 'duplicate_id' AS signal, 'HIGH' AS severity, COUNT(*) AS n, LISTAGG(ID, ', ') WITHIN GROUP (ORDER BY ID) AS detail
FROM (SELECT ID FROM GUPPIWHEEL.PUBLIC.ARTIFACTS GROUP BY ID HAVING COUNT(*)>1)
UNION ALL
SELECT 'orphan_parent_id', 'HIGH', COUNT(*), LISTAGG(a.ID, ', ') WITHIN GROUP (ORDER BY a.ID)
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.PARENT_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS p WHERE p.ID = a.PARENT_ID)
UNION ALL
SELECT 'noncanonical_artifact_type', 'MED', COUNT(*), LISTAGG(DISTINCT TYPE, ', ')
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE NOT IN (SELECT t FROM canon_type)
UNION ALL
SELECT 'noncanonical_artifact_stage', 'MED', COUNT(*), LISTAGG(DISTINCT STAGE, ', ')
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE STAGE NOT IN (SELECT s FROM canon_stage)
UNION ALL
SELECT 'rule_dead_db_ref', 'HIGH', COUNT(*), LISTAGG(RULE_ID, ', ') WITHIN GROUP (ORDER BY RULE_ID)
FROM GUPPIWHEEL.PUBLIC.RULES
WHERE CONDITION_SQL LIKE '%FLYWHEEL.PUBLIC%' OR CONDITION_SQL LIKE '%GUPPI.PLATFORM%' OR MESSAGE LIKE '%FLYWHEEL.PUBLIC%'
UNION ALL
SELECT 'rule_noncanonical_applies_to', 'MED', COUNT(*), LISTAGG(RULE_ID, ', ') WITHIN GROUP (ORDER BY RULE_ID)
FROM GUPPIWHEEL.PUBLIC.RULES
WHERE ENABLED=TRUE AND APPLIES_TO_TYPE <> 'ALL' AND APPLIES_TO_TYPE NOT IN (SELECT t FROM canon_type);

-- GUPPI_SHARE_V — the shareable surface (STO-SUBSTRATE-8). Simple surface, controlled foundation:
-- row boundary = PRODUCT_ID (not the folksonomy tag); field boundary = internal namespace stripped,
-- raw METADATA omitted (it holds METADATA:internal.*). This is the per-product share template:
-- a customer share is the same shape with PRODUCT_ID swapped + SHARE pointed at that account.
CREATE OR REPLACE SECURE VIEW GUPPIWHEEL.PUBLIC.GUPPI_SHARE_V AS
SELECT
  ID, TYPE, STAGE, TITLE,
  OBJECT_DELETE(CONTENT, 'internal', 'strategic_note') AS CONTENT,  -- defensively strip internal namespace
  TAGS, PARENT_ID, PRODUCT_ID, CREATED_AT, UPDATED_AT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE PRODUCT_ID = 'guppi' AND SUPERSEDED_BY IS NULL;

-- PRODUCT_SHARE_LEAK_V — confidentiality tripwire (STO-SUBSTRATE-8). Two dimensions; must be 0:
--   row: a guppi-product artifact whose SUBJECT is a customer/prospect (CONTENT:target or title).
--        Keys on SUBJECT, not topical tags, so platform roadmap stories that merely mention a
--        customer (e.g. "onboard FIMR") are NOT flagged.
--   field: a guppi artifact still carrying an internal key in CONTENT (would ride into the share).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.PRODUCT_SHARE_LEAK_V AS
SELECT ID, PRODUCT_ID, 'customer-subject in guppi product' AS leak, LEFT(TITLE,60) AS detail
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE PRODUCT_ID='guppi'
  AND UPPER(TITLE || ' ' || COALESCE(CONTENT:target::string,'')) RLIKE '.*(FERRUM|ADONIS|MEDUIT|MISSISSIPPI|MCKESSON|DEEPHEALTH|ABARCA).*'
UNION ALL
SELECT ID, PRODUCT_ID, 'internal key in shared CONTENT', LEFT(TITLE,60)
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE PRODUCT_ID='guppi' AND (CONTENT:strategic_note IS NOT NULL OR CONTENT:internal IS NOT NULL);

-- GUPPI_CONFORMANCE_V — the conformance gate (COCO.md "you got Guppi when this passes").
-- Definition of done after any build or re-author: every row must read PASS. These are the
-- Tier 0 invariants that drift silently because Snowflake does not enforce PK/UNIQUE/FK.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.GUPPI_CONFORMANCE_V AS
SELECT 'no-duplicate-ids' AS check_name, 'Tier0 #2 (no dup IDs)' AS tier_ref,
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.DUPLICATE_ID_SCREAM_V) = 0, 'PASS', 'FAIL') AS status
UNION ALL
SELECT 'ids-distinct', 'Tier0 #2 (distinct = total)',
       IFF((SELECT COUNT(DISTINCT ID) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS)
            = (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS), 'PASS', 'FAIL')
UNION ALL
SELECT 'grounding-health', 'Tier0 #1/#8 (no orphans/noncanonical, no dead refs)',
       IFF((SELECT COALESCE(SUM(n), 0) FROM GUPPIWHEEL.PUBLIC.GROUNDING_HEALTH_V) = 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'rules-present', 'Tier0 #5 (doctrine is data)',
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.RULES WHERE ENABLED = TRUE) > 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'no-share-leak', 'Tier0 confidentiality (product share boundary, STO-SUBSTRATE-8)',
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.PRODUCT_SHARE_LEAK_V) = 0, 'PASS', 'FAIL');

-- =============================================================================
-- RBAC (3-tier)
-- =============================================================================
CREATE ROLE IF NOT EXISTS GUPPIWHEEL_ADMIN;
CREATE ROLE IF NOT EXISTS GUPPIWHEEL_CONTRIBUTOR;
CREATE ROLE IF NOT EXISTS GUPPIWHEEL_VIEWER;

GRANT ROLE GUPPIWHEEL_VIEWER TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT ROLE GUPPIWHEEL_CONTRIBUTOR TO ROLE GUPPIWHEEL_ADMIN;
GRANT ROLE GUPPIWHEEL_ADMIN TO ROLE SYSADMIN;

GRANT USAGE ON DATABASE GUPPIWHEEL TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_VIEWER;
GRANT SELECT ON ALL VIEWS IN SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_VIEWER;
GRANT READ ON STAGE GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS TO ROLE GUPPIWHEEL_VIEWER;

-- CONTRIBUTOR is procedure-mediated: NO direct INSERT/UPDATE on ARTIFACTS (born-locked per RULE-028).
-- Writes flow only through SUBMIT_INITIATIVE / PUBLISH_ARTIFACT / ADVANCE_STAGE / UPDATE_OWN_ARTIFACT
-- (granted in 03_procs.sql, all EXECUTE AS OWNER). Doctrine (RULES, RULES_HISTORY) is ADMIN-ONLY:
-- contributors are intentionally granted NOTHING on those tables. See skill: guppiwheel-governance.
GRANT INSERT ON TABLE GUPPIWHEEL.PUBLIC.VIOLATIONS TO ROLE GUPPIWHEEL_CONTRIBUTOR;       -- proc-written audit trail
GRANT INSERT ON TABLE GUPPIWHEEL.PUBLIC.ARTIFACT_LAUNCHES TO ROLE GUPPIWHEEL_CONTRIBUTOR; -- proc-written
GRANT INSERT ON TABLE GUPPIWHEEL.PUBLIC.STAGE_TRANSITIONS TO ROLE GUPPIWHEEL_CONTRIBUTOR; -- proc-written stage-change log
GRANT INSERT, UPDATE ON TABLE GUPPIWHEEL.PUBLIC.PRODUCTS TO ROLE GUPPIWHEEL_CONTRIBUTOR;  -- product registry: contributors curate (reference data, not doctrine)
GRANT READ, WRITE ON STAGE GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS TO ROLE GUPPIWHEEL_CONTRIBUTOR;
-- NOTE: contributors are intentionally NOT granted direct DML on ID_CONVENTIONS, PLUGIN_VERSION,
-- INITIATIVE_STEPS (Rocky/agent log, OWNER-written), or GUPPI_TOUCH_WATCH. Sequence/version/log
-- tables are system- or procedure-owned. PRODUCTS and ECOSYSTEM.TAXONOMY are the only contributor-
-- curatable reference tables.

GRANT ALL PRIVILEGES ON DATABASE GUPPIWHEEL TO ROLE GUPPIWHEEL_ADMIN;
GRANT ALL PRIVILEGES ON SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_ADMIN;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_ADMIN;
GRANT ALL PRIVILEGES ON ALL VIEWS IN SCHEMA GUPPIWHEEL.PUBLIC TO ROLE GUPPIWHEEL_ADMIN;
GRANT READ, WRITE ON STAGE GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS TO ROLE GUPPIWHEEL_ADMIN;

-- RULE-029: ARTIFACTS creation is procedure-mediated even for ADMIN. GRANT ALL above confers INSERT;
-- carve it back out so the ONLY insert path is CREATE_ARTIFACT (EXECUTE AS OWNER). Admin keeps
-- UPDATE/DELETE for data surgery/corrections. This is what makes "no duplicate IDs" a real invariant
-- (Snowflake does not enforce PK/UNIQUE). A future GRANT INSERT here re-opens the hole -- see guppiwheel-governance.
REVOKE INSERT ON TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS FROM ROLE GUPPIWHEEL_ADMIN;
