-- =============================================================================
-- guppi-platform upgrade: 3.21.1 -> 3.22.0
-- "WIDGET artifact type — governed pointers to reusable building blocks"
--
-- Additive only (RULE-019). Safe to re-run. Nothing here rewrites existing artifacts.
--
-- WHAT THIS ADDS
-- --------------
-- A new first-class artifact TYPE, WIDGET: a governed catalog entry that POINTS to a
-- reusable building block (proc/UDF/HTML pattern/python/…) living anywhere in the account.
-- The artifact holds metadata only; the implementation lives at content.pointer.ref
-- (default library home GUPPI_LIB.LIB) and is REFERENCED, never copied. This is
-- TYPE-ONLY: no widget implementations ship in this plugin.
--
-- Single-source rule: one physical impl + one WIDGET artifact; multi-surfacing is done
-- with tags + the pointer, never duplication (e.g. W-1 tagged imaging-dicom AND
-- guppi-showcase over one impl GUPPI_LIB.LIB.PARSE_DICOM).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Type registry row. Lives in seeds/engine/01_schema.sql (idempotent MERGE);
--    re-applying the engine seed is the preferred path.
-- -----------------------------------------------------------------------------
--   ==> Apply seeds/engine/01_schema.sql to MERGE the WIDGET row into TYPE_REGISTRY
--       (Draft,Published,Deprecated stages; global W- series; ID_SERIES_ENTITY=WIDGET).
--       Re-applying also updates the semantic view's type enumeration (14 -> 15).

-- -----------------------------------------------------------------------------
-- 2. ID allocator entity. seeds/content/bootstrap.sql is fresh-account ONLY and is
--    NOT re-run on existing installs, so the WIDGET allocator row is provided here
--    as an insert-if-missing (will NOT reset an already-advanced NEXT_SEQ).
-- -----------------------------------------------------------------------------
INSERT INTO GUPPIWHEEL.PUBLIC.ID_CONVENTIONS (ENTITY, NEXT_SEQ, ID_PREFIX, NOTES)
SELECT * FROM VALUES
    ('WIDGET', 1, 'W-', 'Reusable building-block widgets. Global sequential W-N; implementation lives at content.pointer.ref (default GUPPI_LIB.LIB).')
AS s(ENTITY, NEXT_SEQ, ID_PREFIX, NOTES)
WHERE NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = s.ENTITY);

-- -----------------------------------------------------------------------------
-- 3. Post-upgrade verify (read-only).
-- -----------------------------------------------------------------------------

-- 3a. The WIDGET type is registered with the right stages/series.
SELECT TYPE, ID_PREFIX, STAGES, ID_SERIES_ENTITY, ID_PRODUCT_SCOPED
FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY WHERE TYPE = 'WIDGET';

-- 3b. The allocator entity exists (NEXT_SEQ preserved if already advanced).
SELECT ENTITY, NEXT_SEQ, ID_PREFIX
FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = 'WIDGET';

-- 3c. A widget can be minted: this should return the type as valid (do not run in prod
-- unless you want a test row). Illustrative only.
--   CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('WIDGET','<title>','<product>','<content json>','<parent>',NULL,'<tags json>',NULL,NULL);
