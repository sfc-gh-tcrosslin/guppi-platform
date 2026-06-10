-- =============================================================================
-- Upgrade: guppi-platform 2.0.0 → 3.0.0
-- For accounts that installed v2.0.0 and want to move to v3.0.0.
-- Run AFTER pulling v3.0.0 plugin and running engine/01..05.
-- Idempotent — safe to re-run; checks PLUGIN_VERSION before applying mutations.
-- =============================================================================

-- =============================================================================
-- 1. Rename FLYWHEEL → GUPPIWHEEL if customer is on FLYWHEEL
-- =============================================================================
DECLARE
  has_flywheel NUMBER;
  has_guppiwheel NUMBER;
BEGIN
  SELECT COUNT(*) INTO :has_flywheel FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES WHERE DATABASE_NAME = 'FLYWHEEL';
  SELECT COUNT(*) INTO :has_guppiwheel FROM SNOWFLAKE.INFORMATION_SCHEMA.DATABASES WHERE DATABASE_NAME = 'GUPPIWHEEL';
  IF (:has_flywheel = 1 AND :has_guppiwheel = 0) THEN
    EXECUTE IMMEDIATE 'ALTER DATABASE FLYWHEEL RENAME TO GUPPIWHEEL';
  END IF;
END;

-- =============================================================================
-- 2. Normalize TYPE values to UPPERCASE
-- =============================================================================
UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET TYPE = UPPER(TYPE) WHERE TYPE != UPPER(TYPE);

-- =============================================================================
-- 3. Rename stages: spark→Initiate, active→Research, built→Building, proven→Built, told→Narrated, archived→Narrated
-- =============================================================================
UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS SET STAGE =
  CASE UPPER(STAGE)
    WHEN 'SPARK' THEN 'Initiate'
    WHEN 'ACTIVE' THEN 'Research'
    WHEN 'BUILT' THEN 'Built'
    WHEN 'PROVEN' THEN 'Built'
    WHEN 'TOLD' THEN 'Narrated'
    WHEN 'NARRATED' THEN 'Narrated'
    WHEN 'ARCHIVED' THEN 'Narrated'
    WHEN 'INITIATE' THEN 'Initiate'
    WHEN 'RESEARCH' THEN 'Research'
    WHEN 'BUILDING' THEN 'Building'
    WHEN 'SYNTHESIZE' THEN 'Research'
    WHEN 'DRAFT' THEN 'Initiate'
    ELSE 'Initiate'
  END
WHERE STAGE NOT IN ('Initiate','Research','Building','Built','Narrated');

-- =============================================================================
-- 4. Update PLUGIN_VERSION
-- =============================================================================
MERGE INTO GUPPIWHEEL.PUBLIC.PLUGIN_VERSION t
USING (SELECT 'guppi-platform' AS PLUGIN_NAME, '3.0.0' AS VERSION) s
ON t.PLUGIN_NAME = s.PLUGIN_NAME
WHEN MATCHED THEN UPDATE SET VERSION = s.VERSION, INSTALLED_AT = CURRENT_TIMESTAMP(), NOTES = 'Upgraded from 2.0.0'
WHEN NOT MATCHED THEN INSERT (PLUGIN_NAME, VERSION, NOTES) VALUES (s.PLUGIN_NAME, s.VERSION, 'First install at 3.0.0 (upgrade run)');

-- =============================================================================
-- 5. Manual steps (cannot automate safely; reference only)
-- =============================================================================
-- For customers who had GUPPI.PLATFORM.* tables (legacy split):
--   Migrate those rows into GUPPIWHEEL.PUBLIC.ARTIFACTS by TYPE
--   See guppi-platform v3.0.0 CHANGELOG for the migration patterns we used internally
-- For customers with local file-path NARRATIVES:
--   Use PUBLISH_ARTIFACT to upload bytes and re-register with metadata.launch
-- For customers with old GUPPI.PLATFORM.ROCKY_TASK:
--   ALTER TASK GUPPI.PLATFORM.ROCKY_TASK SUSPEND
--   The new GUPPIWHEEL.PUBLIC.ROCKY_TASK is created and resumed by engine/05_agents.sql
