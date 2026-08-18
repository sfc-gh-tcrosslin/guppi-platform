-- =============================================================================
-- guppi-platform v3.20.0 — Engine Seed 01: Schema
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

-- INIT-75 Thread A: birth-hash provenance chain (tamper-evidence; NOT blockchain -- single write
-- authority via CREATE_ARTIFACT). PREV_HASH links to the prior birth's ROW_HASH; each new birth's
-- ROW_HASH = SHA2_HEX(_canon({"rec": birth-bundle, "prev": PREV_HASH})). Set ONCE at birth and never
-- rewritten (supersede stays a logical pointer). Idempotent ADD COLUMN on re-run.
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ADD COLUMN IF NOT EXISTS PREV_HASH VARCHAR(64);
ALTER TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS ADD COLUMN IF NOT EXISTS ROW_HASH  VARCHAR(64);

-- CHAIN_HEAD — single-row serialization point for the birth-hash chain (INIT-75). CREATE_ARTIFACT
-- locks this row (UPDATE) before it reads prev + inserts the new birth, forcing concurrent births to
-- serialize: bare INSERTs are NOT mutually serialized in Snowflake, so ordering must be enforced here.
-- One logical chain: CHAIN_ID = 'main'. Proven under 8-way concurrency in the CHAIN_LAB prototype.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.CHAIN_HEAD (
    CHAIN_ID   VARCHAR(20) NOT NULL PRIMARY KEY,
    LAST_HASH  VARCHAR(64)
);
MERGE INTO GUPPIWHEEL.PUBLIC.CHAIN_HEAD t
USING (SELECT 'main' AS CHAIN_ID) s ON t.CHAIN_ID = s.CHAIN_ID
WHEN NOT MATCHED THEN INSERT (CHAIN_ID, LAST_HASH) VALUES ('main', NULL);

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

-- E-014: narrative writer vs judge roles (RULE-023 stays model-agnostic; the DEFAULT single
-- narrative writer is a Sonnet-class model, not Opus -- BOB_EXECUTE picks it by name from the
-- authoring pool). 'both' = eligible writer AND judge; 'judge' = judge-only. Idempotent.
UPDATE GUPPIWHEEL.PUBLIC.MODEL_CATALOG SET ROLE = 'both'  WHERE MODEL_NAME IN ('claude-sonnet-4-5','openai-gpt-4.1');
UPDATE GUPPIWHEEL.PUBLIC.MODEL_CATALOG SET ROLE = 'judge' WHERE MODEL_NAME IN ('llama3.3-70b','mistral-large2');

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

-- Version stamp: NOT set here. The single go-forward stamp is a governed call to
-- PUBLISH_PLUGIN_VERSION at the end of 03_procs.sql (regression-proof; must equal
-- .cortex-plugin/plugin.json — SDLC preflight Check 13.1). A raw literal MERGE used
-- to live here and drifted stale (3.8.1) behind live installs; removed deliberately.

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

-- APPS_V (app-family launchables) is defined BELOW, after TYPE_REGISTRY, because it derives from IS_APP.

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

-- CHAIN_INTEGRITY_V — structural tripwire for the birth-hash chain (INIT-75 Thread A). Pure-SQL checks
-- that need no hash recompute; deep content re-hash lives in the VERIFY_CHAIN proc (canon is Python).
-- Once baselined, healthy = genesis_count is exactly 1 and every other signal is n=0.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.CHAIN_INTEGRITY_V AS
WITH hashed AS (SELECT ID, PREV_HASH, ROW_HASH FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NOT NULL)
SELECT 'unhashed_rows' AS signal, COUNT(*) AS n,
       LISTAGG(ID, ', ') WITHIN GROUP (ORDER BY ID) AS detail
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NULL
UNION ALL
SELECT 'genesis_count', (SELECT COUNT(*) FROM hashed WHERE PREV_HASH IS NULL), ''
UNION ALL
SELECT 'forked_prev', COUNT(*), LISTAGG(PREV_HASH, ', ')
FROM (SELECT PREV_HASH FROM hashed WHERE PREV_HASH IS NOT NULL GROUP BY PREV_HASH HAVING COUNT(*) > 1)
UNION ALL
SELECT 'dangling_prev', COUNT(*), LISTAGG(h.ID, ', ') WITHIN GROUP (ORDER BY h.ID)
FROM hashed h WHERE h.PREV_HASH IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM hashed p WHERE p.ROW_HASH = h.PREV_HASH)
UNION ALL
SELECT 'dup_row_hash', COUNT(*), LISTAGG(ROW_HASH, ', ')
FROM (SELECT ROW_HASH FROM hashed GROUP BY ROW_HASH HAVING COUNT(*) > 1);

-- =============================================================================
-- TYPE_REGISTRY — the canonical artifact-type taxonomy as governance-as-data
-- (like RULES). ONE source of truth: GROUNDING_HEALTH_V derives its canonical
-- type + stage lists from here, CREATE_ARTIFACT enforces TYPE against it, and the
-- semantic view exposes it so agents can authoritatively define any type. Adding
-- a type = one governed INSERT here (then it is usable everywhere). Introduced to
-- resolve type-list drift (OUTCOME was missing from the semantic model). STAGES is
-- a CSV; the union of all STAGES defines the canonical stage set.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.TYPE_REGISTRY (
    TYPE           VARCHAR(40)   NOT NULL PRIMARY KEY,
    PURPOSE        VARCHAR(1000) NOT NULL,
    ID_PREFIX      VARCHAR(120),
    LIFECYCLE      VARCHAR(20)   NOT NULL,   -- standard | workitem | outcome
    STAGES         VARCHAR(300)  NOT NULL,   -- CSV of valid stages for this type
    IS_LAUNCHABLE  BOOLEAN       NOT NULL DEFAULT FALSE,   -- has metadata.launch (APP/MODEL/DASHBOARD/NARRATIVE)
    IS_APP            BOOLEAN    NOT NULL DEFAULT FALSE,    -- app-family (APP/MODEL/DASHBOARD): drives APPS_V, app_count, STG-002
    ID_SERIES_ENTITY  VARCHAR(40),                          -- ID_CONVENTIONS entity to mint under (NULL = use TYPE)
    ID_PRODUCT_SCOPED BOOLEAN    NOT NULL DEFAULT FALSE,    -- TRUE => entity is TYPE_<UPPER(product)> (STORY/DEFECT)
    INTRODUCED_IN  VARCHAR(40),
    NOTES          VARCHAR(500),
    UPDATED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
-- Self-heal for existing installs (CREATE TABLE IF NOT EXISTS won't add new columns):
ALTER TABLE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY ADD COLUMN IF NOT EXISTS IS_APP BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY ADD COLUMN IF NOT EXISTS ID_SERIES_ENTITY VARCHAR(40);
ALTER TABLE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY ADD COLUMN IF NOT EXISTS ID_PRODUCT_SCOPED BOOLEAN NOT NULL DEFAULT FALSE;

MERGE INTO GUPPIWHEEL.PUBLIC.TYPE_REGISTRY t
USING (
  SELECT column1 AS TYPE, column2 AS PURPOSE, column3 AS ID_PREFIX, column4 AS LIFECYCLE,
         column5 AS STAGES, column6 AS IS_LAUNCHABLE, column7 AS INTRODUCED_IN, column8 AS NOTES,
         column9 AS IS_APP, column10 AS ID_SERIES_ENTITY, column11 AS ID_PRODUCT_SCOPED
  FROM VALUES
    ('INITIATIVE','A unit of intended value: a hypothesis to pursue. Root of a work tree; Rocky researches it and epics/stories hang under it.','INIT-','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('EPIC','A large body of work grouping related stories under an initiative.','E-','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('RESEARCH','Synthesis/findings (often produced by Rocky) that ground an initiative before building.','RES-','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('STORY','A concrete unit of work (feature/change) under an initiative or epic. Product-scoped IDs.','product-scoped: ENTITY=STORY_<PRODUCT> (PLAT-, F6-, S-, ...)','workitem','Initiate,Research,Building,Built,SELECTED,RESOLVED,Published',FALSE,'','',FALSE,NULL,TRUE),
    ('NARRATIVE','A published, launchable write-up (plan, story, briefing) rendered to HTML in the wheel.','NAR-','standard','Initiate,Research,Building,Built,Published',TRUE,'','',FALSE,NULL,FALSE),
    ('APP','A launchable application registered in the wheel (identifier/url/stage_path in metadata.launch).','APP-','standard','Initiate,Research,Building,Built,Published',TRUE,'','',TRUE,'APP',FALSE),
    ('MODEL','A launchable ML model registered in the wheel.','APP- (minted in the APP series)','standard','Initiate,Research,Building,Built,Published',TRUE,'','',TRUE,'APP',FALSE),
    ('DASHBOARD','A launchable dashboard/visualization registered in the wheel.','DASH-','standard','Initiate,Research,Building,Built,Published',TRUE,'','',TRUE,'APP',FALSE),
    ('DEFECT','A tracked defect/bug against product work. Product-scoped IDs.','product-scoped: ENTITY=DEFECT_<PRODUCT> (PLAT-D, F6-D, SC-D)','workitem','Research,Building,Built,Published,Resolved',FALSE,'','',FALSE,NULL,TRUE),
    ('INCIDENT','An operational incident record.','INC-','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('AUDIT','A read-only grounding/hygiene scan record (e.g., Stewart). System-generated; UUID IDs.','(UUID)','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('OPS_EVENT','An operational event / status marker (e.g., a product status snapshot).','OPS-<slug>','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE),
    ('OUTCOME','A measurable target tracked against the real world. A pointer (snowflake_path / app_metric / external_url) must resolve to live data or an explicit human sign-off before RESOLVED.','OUT-','outcome','ASPIRATIONAL,SELECTED,TRACKED,RESOLVED',FALSE,'INIT-37','Distinct 4-stage lifecycle (STG-005); the standard Initiate->Published stages do NOT apply.',FALSE,NULL,FALSE),
    ('SKILL','A registered capability/recipe skill in the plugin.','<freeform slug>','standard','Initiate,Research,Building,Built,Published',FALSE,'','',FALSE,NULL,FALSE)
) s
ON t.TYPE = s.TYPE
WHEN MATCHED THEN UPDATE SET PURPOSE=s.PURPOSE, ID_PREFIX=s.ID_PREFIX, LIFECYCLE=s.LIFECYCLE,
  STAGES=s.STAGES, IS_LAUNCHABLE=s.IS_LAUNCHABLE, INTRODUCED_IN=s.INTRODUCED_IN, NOTES=s.NOTES,
  IS_APP=s.IS_APP, ID_SERIES_ENTITY=s.ID_SERIES_ENTITY, ID_PRODUCT_SCOPED=s.ID_PRODUCT_SCOPED, UPDATED_AT=CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (TYPE,PURPOSE,ID_PREFIX,LIFECYCLE,STAGES,IS_LAUNCHABLE,INTRODUCED_IN,NOTES,IS_APP,ID_SERIES_ENTITY,ID_PRODUCT_SCOPED)
  VALUES (s.TYPE,s.PURPOSE,s.ID_PREFIX,s.LIFECYCLE,s.STAGES,s.IS_LAUNCHABLE,s.INTRODUCED_IN,s.NOTES,s.IS_APP,s.ID_SERIES_ENTITY,s.ID_PRODUCT_SCOPED);

-- =============================================================================
-- NARRATIVE_TEMPLATE — the canonical narrative CONTENT structure as governance-as-data
-- (like TYPE_REGISTRY / RULES). One row per (template, section). The write-path
-- normalizer validates NARRATIVE content against the declared template and HARD-REJECTS
-- a missing required section; the renderer iterates these rows in ORD order. Changing the
-- structure = editing rows here, never code/prompt. Each narrative stamps the
-- TEMPLATE_VERSION it conformed to (go-forward: legacy narratives carry no stamp and are
-- exempt from the conformance tripwire). INIT-70 / E-014 (narrative write-path hardening).
-- =============================================================================
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE (
    TEMPLATE         VARCHAR(40)   NOT NULL,
    SECTION_KEY      VARCHAR(40)   NOT NULL,
    ORD              NUMBER        NOT NULL,
    REQUIRED         BOOLEAN       NOT NULL DEFAULT TRUE,
    HEADING          VARCHAR(120)  NOT NULL,
    KIND             VARCHAR(20)   NOT NULL DEFAULT 'prose',  -- prose | list | table | prose_or_table
    HINT             VARCHAR(500),
    TEMPLATE_VERSION VARCHAR(20)   NOT NULL DEFAULT '1',
    UPDATED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (TEMPLATE, SECTION_KEY)
);

MERGE INTO GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE t
USING (
  SELECT column1 AS TEMPLATE, column2 AS SECTION_KEY, column3 AS ORD, column4 AS REQUIRED,
         column5 AS HEADING, column6 AS KIND, column7 AS HINT, column8 AS TEMPLATE_VERSION
  FROM VALUES
    -- default: general-purpose narrative
    ('default','summary',1,TRUE,'Summary','prose','1-3 sentences: what this is and the punchline','1'),
    ('default','context',2,TRUE,'Context','prose','Background the reader needs','1'),
    ('default','findings',3,TRUE,'Findings','prose_or_table','The substance; tables welcome','1'),
    ('default','recommendation',4,TRUE,'Recommendation','prose','What to do','1'),
    ('default','next_steps',5,TRUE,'Next Steps','list','Concrete ordered actions','1'),
    ('default','honesty',6,TRUE,'Honesty / Caveats','prose','Real vs art-of-possible; limits','1'),
    -- position: customer-facing positioning narrative (no Guppi mention)
    ('position','thesis',1,TRUE,'Thesis','prose','1-2 sentences','1'),
    ('position','moves',2,TRUE,'Moves','list','Exactly 4 moves, each a bold headline + 1-2 sentences','1'),
    ('position','honest_boundary',3,TRUE,'Honest Boundary','prose','What Snowflake is NOT right for','1'),
    ('position','why_now',4,TRUE,'Why Now','prose','The timing close','1'),
    -- internal_plan: internal engineering-first deliverable / plan
    ('internal_plan','summary',1,TRUE,'Summary','prose','What and why, 1-3 sentences','1'),
    ('internal_plan','context',2,TRUE,'Context','prose','Grounding + current state','1'),
    ('internal_plan','phased_plan',3,TRUE,'Phased Plan','list','Ordered steps with a de-risk gate','1'),
    ('internal_plan','risks',4,TRUE,'Risks / Open Questions','prose','Honest unknowns','1'),
    ('internal_plan','why_now',5,TRUE,'Why Now','prose','The timing close','1'),
    -- account_brief: account/demo proposal (NAR-91 shape)
    ('account_brief','summary',1,TRUE,'Summary','prose','The punchline for the reader','1'),
    ('account_brief','account_context',2,TRUE,'Account Context','prose','Who they are, footprint, timing','1'),
    ('account_brief','proposed_demos',3,TRUE,'Proposed Demos / Apps','table','Demo -> lever -> reuse -> peer proof -> status','1'),
    ('account_brief','peer_proof',4,TRUE,'Peer Proof','prose_or_table','Real comparable wins','1'),
    ('account_brief','why_now',5,TRUE,'Renewal / Why Now','prose','The commercial hook','1'),
    ('account_brief','honesty',6,TRUE,'Honesty','prose','Real vs art-of-possible; do not over-promise','1')
) s
ON t.TEMPLATE = s.TEMPLATE AND t.SECTION_KEY = s.SECTION_KEY
WHEN MATCHED THEN UPDATE SET ORD=s.ORD, REQUIRED=s.REQUIRED, HEADING=s.HEADING, KIND=s.KIND,
  HINT=s.HINT, TEMPLATE_VERSION=s.TEMPLATE_VERSION, UPDATED_AT=CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (TEMPLATE, SECTION_KEY, ORD, REQUIRED, HEADING, KIND, HINT, TEMPLATE_VERSION)
  VALUES (s.TEMPLATE, s.SECTION_KEY, s.ORD, s.REQUIRED, s.HEADING, s.KIND, s.HINT, s.TEMPLATE_VERSION);

-- APPS_V — app-family launchables. Derives from TYPE_REGISTRY.IS_APP (single source; defined after the registry).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.APPS_V AS
SELECT ID, STAGE, TITLE, OWNER, CONTENT, TAGS, METADATA, PARENT_ID, CREATED_AT, UPDATED_AT,
       METADATA:launch:app_type::VARCHAR AS APP_TYPE,
       METADATA:launch:url::VARCHAR AS URL,
       METADATA:launch:identifier::VARCHAR AS IDENTIFIER
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE IN (SELECT TYPE FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY WHERE IS_APP);

-- GROUNDING_HEALTH_V — Stewart's senses (RULE-027). Deterministic grounding/hygiene drift signals; healthy = all N=0.
-- canon_type + canon_stage DERIVE from TYPE_REGISTRY (single source; no hardcoded lists to drift).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.GROUNDING_HEALTH_V AS
WITH canon_type AS (
  SELECT TYPE AS t FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY
),
canon_stage AS (
  SELECT DISTINCT TRIM(s.VALUE) AS s
  FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY r, LATERAL SPLIT_TO_TABLE(r.STAGES, ',') s
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
-- CUSTOMER_SUBJECT_TERMS — the customer/prospect name terms PRODUCT_SHARE_LEAK_V matches on.
--
-- These were previously a hardcoded RLIKE literal inside the view. That meant the share-leak
-- tripwire PUBLISHED the very customer list it existed to protect — fine while the plugin repo was
-- private, a confidentiality problem the moment it is public. Moving them to data fixes that and
-- removes the code change previously needed to onboard each new customer.
--
-- SEEDED EMPTY ON PURPOSE. Each install populates its own terms; no names live in this repo.
-- A term need not have a PRODUCTS row (a prospect may have no product yet), so PRODUCT_ID is
-- nullable. Contributor-curatable reference data, like PRODUCTS.
--
--   INSERT INTO GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS (TERM, PRODUCT_ID, NOTES)
--   VALUES ('<CUSTOMER>', '<product_id or NULL>', 'why this term is tracked');
--
-- NOTE: with an empty table the row-level half of PRODUCT_SHARE_LEAK_V matches nothing, so the
-- no-share-leak conformance check passes trivially. That is intentional for a fresh install with no
-- customer work in it — but populate this table before relying on the check.
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS (
  TERM        VARCHAR(120) NOT NULL PRIMARY KEY,
  PRODUCT_ID  VARCHAR(60),
  NOTES       VARCHAR(500),
  ACTIVE      BOOLEAN DEFAULT TRUE,
  CREATED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Customer/prospect name terms used by PRODUCT_SHARE_LEAK_V to detect a customer-subject artifact on the SHARED guppi product boundary (STO-SUBSTRATE-8). Governance-as-data; previously a hardcoded RLIKE literal in the view, which published the customer list the tripwire existed to protect. Seeded EMPTY - each install populates its own terms. PRODUCT_ID nullable (a prospect may have no product yet).';

CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.PRODUCT_SHARE_LEAK_V
COMMENT = 'Share-boundary tripwire (STO-SUBSTRATE-8). Flags (a) an artifact on the SHARED guppi product whose SUBJECT is a customer/prospect, and (b) a guppi artifact still carrying an internal-only key that would ride into the share. Customer terms come from CUSTOMER_SUBJECT_TERMS (governance-as-data). Keys on SUBJECT (title / CONTENT:target), not topical mentions. Must be 0 rows.'
AS
SELECT a.ID, a.PRODUCT_ID, 'customer-subject in guppi product' AS leak, LEFT(a.TITLE,60) AS detail
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.PRODUCT_ID = 'guppi'
  AND EXISTS (
        SELECT 1 FROM GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS t
        WHERE t.ACTIVE
          AND UPPER(a.TITLE || ' ' || COALESCE(a.CONTENT:target::string,'')) LIKE '%' || UPPER(t.TERM) || '%'
      )
UNION ALL
SELECT a.ID, a.PRODUCT_ID, 'internal key in shared CONTENT', LEFT(a.TITLE,60)
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.PRODUCT_ID = 'guppi'
  AND (a.CONTENT:strategic_note IS NOT NULL OR a.CONTENT:internal IS NOT NULL);

-- NARRATIVE_CONFORMANCE_V — E-014 go-forward tripwire. Lists template-STAMPED narratives that
-- violate their declared template (missing/empty required section, or an unknown template).
-- Legacy narratives (no CONTENT:template stamp) are grandfathered = never listed. Healthy = empty.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.NARRATIVE_CONFORMANCE_V AS
SELECT a.ID,
       a.CONTENT:template::string AS template,
       LISTAGG(t.SECTION_KEY, ', ') WITHIN GROUP (ORDER BY t.ORD) AS missing_sections
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
JOIN GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE t
  ON t.TEMPLATE = a.CONTENT:template::string AND t.REQUIRED = TRUE
WHERE a.TYPE = 'NARRATIVE' AND a.SUPERSEDED_BY IS NULL AND a.CONTENT:template IS NOT NULL
  AND (GET(a.CONTENT, t.SECTION_KEY) IS NULL OR TRIM(GET(a.CONTENT, t.SECTION_KEY)::string) = '')
GROUP BY a.ID, a.CONTENT:template::string
UNION ALL
SELECT a.ID, a.CONTENT:template::string AS template, 'UNKNOWN TEMPLATE' AS missing_sections
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.TYPE = 'NARRATIVE' AND a.SUPERSEDED_BY IS NULL AND a.CONTENT:template IS NOT NULL
  AND a.CONTENT:template::string NOT IN (SELECT DISTINCT TEMPLATE FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE);

-- NARRATIVE_TEMPLATE_ADOPTION_V — render-contract visibility (E-014 follow-on).
-- NARRATIVE_CONFORMANCE_V above only inspects narratives where CONTENT:template IS NOT NULL, so
-- UNTEMPLATED narratives were invisible to it: the gate could read PASS while most live narratives
-- had no template and therefore no guaranteed sections, order, or headings. That is the structural
-- inconsistency people hit when they go to SHARE a narrative. This view exposes that population.
-- Cohorts: LEGACY (pre-cutoff, grandfathered), MIGRATED (metadata.migrated_from set — legacy content
-- re-created through the chokepoint; forcing it into a template would rewrite the original author's
-- work, so it is grandfathered too), LAUNCH-POINTER (renders from a staged asset — a .plan.md, PDF, or
-- hand-built deck — so template sections do not apply; this is CREATE_ARTIFACT's documented behavior
-- for launch-pointer narratives), NEW (must fix). Only NEW gates conformance.
--
-- NEW is the genuinely broken case: no template AND no staged render, i.e. no defined structure and
-- nothing shareable. The LAUNCH-POINTER carve-out is deliberately narrow — it requires
-- metadata.launch.stage_path, which means the bytes were actually captured into the wheel (RULE-018).
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE_ADOPTION_V
COMMENT = 'Render-contract visibility (E-014 follow-on). Exposes narratives with NO CONTENT:template, which NARRATIVE_CONFORMANCE_V cannot see. Cohorts: LEGACY (grandfathered), MIGRATED (metadata.migrated_from — legacy content re-created through the chokepoint, grandfathered), LAUNCH-POINTER (renders from a staged asset such as a .plan.md/.pdf/hand-built deck, so template sections do not apply — CREATE_ARTIFACT documented behavior), NEW (must fix: no template AND no staged render = no defined structure and unshareable). Only NEW gates conformance.'
AS
SELECT
  a.ID,
  a.TITLE,
  a.OWNER,
  a.CREATED_AT,
  CASE
    WHEN a.METADATA:migrated_from IS NOT NULL       THEN 'MIGRATED (legacy content)'
    WHEN a.CREATED_AT < '2026-08-16'::timestamp_ntz THEN 'LEGACY (grandfathered)'
    WHEN a.METADATA:launch:stage_path IS NOT NULL   THEN 'LAUNCH-POINTER (renders from staged asset)'
    ELSE 'NEW (must fix)'
  END AS cohort,
  IFF(a.CONTENT:body_md IS NOT NULL, 'body_md fallback', 'no body_md - normalizer fallback') AS render_path,
  IFF(a.METADATA:launch IS NOT NULL, 'has launch', 'NO launch (unshareable per RULE-018/CMP-003)') AS launch_status
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.TYPE = 'NARRATIVE'
  AND a.SUPERSEDED_BY IS NULL
  AND a.CONTENT:template IS NULL;

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
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.PRODUCT_SHARE_LEAK_V) = 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'narrative-conformance', 'E-014 (template-stamped narratives match their template; legacy grandfathered)',
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.NARRATIVE_CONFORMANCE_V) = 0, 'PASS', 'FAIL')
UNION ALL
-- INIT-75 Thread A: structural chain health. Tolerant of a not-yet-baselined chain (zero hashed rows
-- = feature inactive = PASS). Once baselined: exactly 1 genesis, no fork/dangling/dup, no unhashed rows.
SELECT 'chain-structural-intact', 'INIT-75 Thread A (birth-hash chain: 1 genesis, no fork/dangling/dup/unhashed)',
       IFF(
         (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NOT NULL) = 0
         OR (
              (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NULL) = 0
          AND (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NOT NULL AND PREV_HASH IS NULL) = 1
          AND (SELECT COUNT(*) FROM (SELECT PREV_HASH FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PREV_HASH IS NOT NULL GROUP BY PREV_HASH HAVING COUNT(*) > 1)) = 0
          AND (SELECT COUNT(*) FROM (SELECT ROW_HASH FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ROW_HASH IS NOT NULL GROUP BY ROW_HASH HAVING COUNT(*) > 1)) = 0
         ), 'PASS', 'FAIL')
UNION ALL
-- Render contract: a NEW narrative must declare a template, else its shared structure is undefined.
-- LEGACY + MIGRATED cohorts are grandfathered (see NARRATIVE_TEMPLATE_ADOPTION_V).
SELECT 'narrative-template-adoption', 'Render contract (new narratives must declare a template; legacy grandfathered)',
       IFF((SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE_ADOPTION_V
            WHERE cohort = 'NEW (must fix)') = 0, 'PASS', 'FAIL');

-- DIRECT_DML_TRIPWIRE_V — RULE-028/029 DETECTIVE control (prevention is running as CONTRIBUTOR).
-- Flags ungoverned direct DML on protected substrate tables.
--
-- The discriminator that makes this work: procedures run EXECUTE AS OWNER, so their internal SQL is
-- indistinguishable from hand-written DML by role alone — a naive version of this view flags every
-- governed write. But client-issued statements carry a QUERY_TAG (app=cortex_code_desktop,
-- query_source=agent_tool) while proc-internal statements carry NO tag. Tagged = a human or agent
-- typed it (flag it). Untagged + parameterized = proc-internal (ignore). Untagged + literal is
-- surfaced as REVIEW for non-CoCo clients (worksheets, drivers).
--
-- Owner-rights view so contributors can read it without their own ACCOUNT_USAGE grants; the view
-- OWNER needs access to SNOWFLAKE.ACCOUNT_USAGE (ACCOUNTADMIN does by default).
-- LIMITATION: ACCOUNT_USAGE latency is 45min-3h, so this is forensics, not enforcement.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.DIRECT_DML_TRIPWIRE_V
COMMENT = 'RULE-028/029 detective control. Flags UNGOVERNED direct DML on protected substrate tables. Discriminator: client-issued statements carry a QUERY_TAG (cortex_code_desktop, query_source=agent_tool); statements inside governed stored procedures carry NO tag. Tagged = someone typed it (flag). Untagged + parameterized = proc-internal (ignored). Untagged + literal surfaces as REVIEW for non-CoCo clients. Owner-rights view so contributors read it without ACCOUNT_USAGE grants. LIMITATION: ACCOUNT_USAGE latency 45min-3h; prevention is running as GUPPIWHEEL_CONTRIBUTOR.'
AS
WITH base AS (
  SELECT
    q.START_TIME, q.USER_NAME, q.ROLE_NAME, q.QUERY_TYPE, q.QUERY_ID, q.QUERY_TEXT,
    TRY_PARSE_JSON(q.QUERY_TAG) AS tag
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.QUERY_TYPE IN ('INSERT','UPDATE','DELETE','MERGE','TRUNCATE_TABLE','MULTI_STATEMENT')
    AND q.EXECUTION_STATUS = 'SUCCESS'
    AND (q.QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.ARTIFACTS%'
      OR q.QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.RULES%'
      OR q.QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.ID_CONVENTIONS%'
      OR q.QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.TYPE_REGISTRY%')
    AND q.QUERY_TEXT NOT ILIKE '%CREATE OR REPLACE PROCEDURE%'
    AND q.QUERY_TEXT NOT ILIKE '%CREATE OR REPLACE VIEW%'
)
SELECT
  START_TIME, USER_NAME, ROLE_NAME, QUERY_TYPE,
  CASE
    WHEN QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.RULES%'          THEN 'RULES (doctrine)'
    WHEN QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.ID_CONVENTIONS%' THEN 'ID_CONVENTIONS (allocator)'
    WHEN QUERY_TEXT ILIKE '%GUPPIWHEEL.PUBLIC.TYPE_REGISTRY%'  THEN 'TYPE_REGISTRY'
    ELSE 'ARTIFACTS'
  END AS target_table,
  CASE
    WHEN tag:query_source::string = 'agent_tool' THEN 'DIRECT-AGENT (bypassed the procs)'
    ELSE 'REVIEW-UNTAGGED-LITERAL (non-CoCo client?)'
  END AS severity,
  tag:app::string                AS client_app,
  tag:desktop_session_id::string AS desktop_session_id,
  tag:agent_session_id::string   AS agent_session_id,
  QUERY_ID,
  LEFT(QUERY_TEXT, 400) AS query_text
FROM base
WHERE tag:query_source::string = 'agent_tool'
   OR (tag IS NULL AND QUERY_TEXT NOT LIKE '%?%');

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
GRANT INSERT, UPDATE, DELETE ON TABLE GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS TO ROLE GUPPIWHEEL_CONTRIBUTOR;  -- share-leak terms: reference data, not doctrine
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

-- =============================================================================
-- BUILDER tier (GUPPI_BUILDER) — sits between CONTRIBUTOR and ADMIN (RULE-034).
-- Lets a CoCo operator elevate from CONTRIBUTOR to create DBs / warehouses / SPCS
-- / apps for MVPs WITHOUT ACCOUNTADMIN. It inherits CONTRIBUTOR (wheel work stays
-- procedure-mediated) and is granted NO direct ARTIFACTS/RULES DML, so elevating
-- to build an MVP never reopens the wheel-write hole (governance preserved).
-- Orchestrator posture: default role = CONTRIBUTOR; `USE ROLE GUPPI_BUILDER` to build.
-- NOTE: per-user DEFAULT_ROLE / DEFAULT_SECONDARY_ROLES posture and granting this
-- role to specific humans are ACCOUNT operations (not seeded) — see RULE-034.
-- =============================================================================
CREATE ROLE IF NOT EXISTS GUPPI_BUILDER
  COMMENT = 'Guppi builder tier: elevate from GUPPIWHEEL_CONTRIBUTOR to create DBs/warehouses/SPCS/apps for MVPs. NOT ACCOUNTADMIN; no ARTIFACTS/RULES DML (wheel governance preserved).';
GRANT ROLE GUPPIWHEEL_CONTRIBUTOR TO ROLE GUPPI_BUILDER;   -- inherit wheel orchestration (procs) + SELECT; NO wheel DML
GRANT ROLE GUPPI_BUILDER TO ROLE SYSADMIN;                 -- role hierarchy hygiene
GRANT CREATE DATABASE ON ACCOUNT TO ROLE GUPPI_BUILDER;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE GUPPI_BUILDER;
GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE GUPPI_BUILDER;       -- SPCS
GRANT CREATE APPLICATION ON ACCOUNT TO ROLE GUPPI_BUILDER;
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE GUPPI_BUILDER;
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE GUPPI_BUILDER;    -- SPCS ingress
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE GUPPI_BUILDER;
