-- =============================================================================
-- guppi-platform — Engine Seed 06: The Bond (episodic memory organ)
-- TIER 0/1: The Bond is the EPISODIC-memory tier of the AILC (peer to the
--   current-truth RULES engine and the procedural skills layer). It is an
--   append-only log of co-created moments.
--
-- SHIPS EMPTY. This seed creates the SUBSTRATE only. A consumer's moments are
--   runtime data and are NEVER seeded — a fresh install starts with a blank
--   common brain that the consumer accretes themselves (Bobiverse: same engine,
--   different mind). Do NOT add INSERTs of moments to this file.
--
-- PRIVATE BY DEFAULT. VISIBILITY defaults to 'private' and BOND_ACCESS_POLICY
--   (row access policy) restricts rows to ACCOUNTADMIN / GUPPIWHEEL_ADMIN /
--   the owning user / rows explicitly marked 'shared'. Sharing the Bond is a
--   MANUAL, DELIBERATE, per-reason act — there is intentionally NO automated
--   share view (the corpus is the moat and holds confidential moments).
--
-- Safe to re-run. CREATE ... IF NOT EXISTS for db/schema/tables/stream/policy;
--   CREATE OR REPLACE for the search service. Existing rows are never touched.
--
-- PREREQ: a warehouse must be active in this session (the Cortex Search service
--   binds to it). Run  USE WAREHOUSE <your_wh>;  first. Guard below fails loud.
-- =============================================================================

-- --- Guard: require an active warehouse, then capture it ----------------------
EXECUTE IMMEDIATE $$
DECLARE
  no_wh EXCEPTION (-20037,
    'No active warehouse. Run  USE WAREHOUSE <your_wh>;  then re-run 06_bond.sql');
BEGIN
  IF ((SELECT CURRENT_WAREHOUSE()) IS NULL) THEN
    RAISE no_wh;
  END IF;
  RETURN 'warehouse OK';
END;
$$;

SET wh = (SELECT CURRENT_WAREHOUSE());

-- --- Database + schema --------------------------------------------------------
CREATE DATABASE IF NOT EXISTS THE_BOND;
CREATE SCHEMA   IF NOT EXISTS THE_BOND.PUBLIC;

-- --- MEMORY_STORE — the episodic moment log ----------------------------------
CREATE TABLE IF NOT EXISTS THE_BOND.PUBLIC.MEMORY_STORE (
    MEMORY_ID       VARCHAR DEFAULT UUID_STRING(),
    AGENT_ID        VARCHAR NOT NULL,
    CATEGORY        VARCHAR NOT NULL,
    KEY             VARCHAR NOT NULL,
    CONTENT         VARIANT,
    TAGS            ARRAY,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    SUPERSEDED_BY   VARCHAR,
    ORIGIN          VARCHAR,
    INSIGHT_TYPE    VARCHAR,
    SESSION_CONTEXT VARCHAR,
    VISIBILITY      VARCHAR(10) DEFAULT 'private'
);

-- --- MEMORY_DOCUMENTS — longer-form co-created documents ----------------------
CREATE TABLE IF NOT EXISTS THE_BOND.PUBLIC.MEMORY_DOCUMENTS (
    DOC_ID          VARCHAR DEFAULT UUID_STRING(),
    AGENT_ID        VARCHAR NOT NULL,
    CATEGORY        VARCHAR NOT NULL,
    TITLE           VARCHAR,
    BODY            VARCHAR,
    SOURCE_FILE     VARCHAR,
    TAGS            ARRAY,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    ORIGIN          VARCHAR,
    INSIGHT_TYPE    VARCHAR,
    SESSION_CONTEXT VARCHAR
);

-- Self-heal pre-existing installs that predate VISIBILITY (idempotent no-op on fresh).
ALTER TABLE THE_BOND.PUBLIC.MEMORY_STORE ADD COLUMN IF NOT EXISTS VISIBILITY VARCHAR(10) DEFAULT 'private';

-- --- Change stream for cross-agent notifications ------------------------------
CREATE STREAM IF NOT EXISTS THE_BOND.PUBLIC.MEMORY_STREAM ON TABLE THE_BOND.PUBLIC.MEMORY_STORE;

-- --- Row access policy: private-by-default, visibility-gated ------------------
-- NOTE: the (ROW_OWNER) arg is mapped to AGENT_ID at attach time; AGENT_ID holds
--   the writing agent ('coco'/'human'), not a Snowflake user, so the owner clause
--   is effectively inert for MEMORY_STORE — admin roles + 'shared' rows govern
--   visibility. Reproduced as-is to keep seed == live; revisit if a true OWNER
--   (CURRENT_USER) column is added. Non-admin roles see only 'shared' rows.
CREATE ROW ACCESS POLICY IF NOT EXISTS THE_BOND.PUBLIC.BOND_ACCESS_POLICY
  AS (ROW_OWNER VARCHAR, ROW_VISIBILITY VARCHAR) RETURNS BOOLEAN ->
        CURRENT_ROLE() = 'ACCOUNTADMIN'
     OR CURRENT_ROLE() = 'GUPPIWHEEL_ADMIN'
     OR ROW_VISIBILITY = 'shared'
     OR ROW_OWNER = CURRENT_USER();

-- Attach once (idempotent: ADD ROW ACCESS POLICY errors if already applied).
EXECUTE IMMEDIATE $$
DECLARE
  applied INT;
BEGIN
  SELECT COUNT(*) INTO :applied
  FROM TABLE(THE_BOND.INFORMATION_SCHEMA.POLICY_REFERENCES(
         REF_ENTITY_NAME => 'THE_BOND.PUBLIC.MEMORY_STORE',
         REF_ENTITY_DOMAIN => 'TABLE'))
  WHERE POLICY_NAME = 'BOND_ACCESS_POLICY';
  IF (:applied = 0) THEN
    ALTER TABLE THE_BOND.PUBLIC.MEMORY_STORE
      ADD ROW ACCESS POLICY THE_BOND.PUBLIC.BOND_ACCESS_POLICY ON (AGENT_ID, VISIBILITY);
  END IF;
  RETURN 'bond row access policy ensured';
END;
$$;

-- --- Cortex Search service over current (non-superseded) moments --------------
-- Warehouse bound to the installer's active warehouse (no dictated compute).
EXECUTE IMMEDIATE
  'CREATE OR REPLACE CORTEX SEARCH SERVICE THE_BOND.PUBLIC.MEMORY_SEARCH
     ON BODY
     ATTRIBUTES AGENT_ID, CATEGORY, INSIGHT_TYPE, ORIGIN, TAGS, VISIBILITY, SESSION_CONTEXT
     WAREHOUSE = ' || $wh || '
     TARGET_LAG = ''1 hour''
     REFRESH_MODE = INCREMENTAL
     AS (
       SELECT
         MEMORY_ID,
         KEY,
         COALESCE(KEY, '''') || '' :: '' || TO_JSON(CONTENT) AS BODY,
         LOWER(AGENT_ID) AS AGENT_ID,
         CATEGORY,
         COALESCE(INSIGHT_TYPE, '''') AS INSIGHT_TYPE,
         COALESCE(ORIGIN, '''')       AS ORIGIN,
         TAGS,
         COALESCE(VISIBILITY, ''private'') AS VISIBILITY,
         COALESCE(SESSION_CONTEXT, '''')   AS SESSION_CONTEXT
       FROM THE_BOND.PUBLIC.MEMORY_STORE
       WHERE SUPERSEDED_BY IS NULL
     )';

-- --- Grants (mirror GUPPIWHEEL role tiers; roles created in 01_schema.sql) -----
GRANT USAGE ON DATABASE THE_BOND TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON DATABASE THE_BOND TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON DATABASE THE_BOND TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON SCHEMA THE_BOND.PUBLIC TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON SCHEMA THE_BOND.PUBLIC TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON SCHEMA THE_BOND.PUBLIC TO ROLE GUPPIWHEEL_ADMIN;

GRANT SELECT ON TABLE THE_BOND.PUBLIC.MEMORY_STORE     TO ROLE GUPPIWHEEL_VIEWER;
GRANT SELECT ON TABLE THE_BOND.PUBLIC.MEMORY_DOCUMENTS TO ROLE GUPPIWHEEL_VIEWER;
GRANT SELECT, INSERT ON TABLE THE_BOND.PUBLIC.MEMORY_STORE     TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT SELECT, INSERT ON TABLE THE_BOND.PUBLIC.MEMORY_DOCUMENTS TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT SELECT, INSERT ON TABLE THE_BOND.PUBLIC.MEMORY_STORE     TO ROLE GUPPIWHEEL_ADMIN;
GRANT SELECT, INSERT ON TABLE THE_BOND.PUBLIC.MEMORY_DOCUMENTS TO ROLE GUPPIWHEEL_ADMIN;

GRANT USAGE ON CORTEX SEARCH SERVICE THE_BOND.PUBLIC.MEMORY_SEARCH TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON CORTEX SEARCH SERVICE THE_BOND.PUBLIC.MEMORY_SEARCH TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON CORTEX SEARCH SERVICE THE_BOND.PUBLIC.MEMORY_SEARCH TO ROLE GUPPIWHEEL_ADMIN;
