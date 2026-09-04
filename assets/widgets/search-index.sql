-- WIDGET W-6  class=search-index  home=@GUPPI_LIB.LIB.WIDGET_FILES/search-index.sql
-- Purpose: build a Cortex Search service over the catalog free-text so lookup complements
--          the semantic view.
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_SEARCH_INDEX recipe.
-- TOKENS: <PREFIX> proc prefix; <SEARCH_SVC> service name; <STUDY_TBL>/<SERIES_TBL> catalog tables;
--   ATTRIBUTES + the free-text concat below are the reference (DICOM) shape -- set your id,
--   attributes-to-return, free-text source columns, and grain. Warehouse resolves at build time.
-- EXIT GATE: a search for a known term returns the expected record.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_SEARCH_INDEX()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Build recipe: idempotently builds a Cortex Search service over the catalog free-text. Warehouse from CURRENT_WAREHOUSE(). Metadata only.'
EXECUTE AS OWNER
AS
$$
DECLARE
  ddl STRING;
BEGIN
  ddl := 'CREATE OR REPLACE CORTEX SEARCH SERVICE <SEARCH_SVC> ON SEARCH_TEXT ATTRIBUTES MODALITY, STUDY_DATE, PATIENT_ID, STUDY_UID WAREHOUSE = ' || CURRENT_WAREHOUSE() || ' TARGET_LAG = ''1 hour'' AS (SELECT s.STUDY_UID, s.MODALITY, s.STUDY_DATE, s.PATIENT_ID, TRIM(COALESCE(s.STUDY_DESC,'''') || '' '' || COALESCE(s.MODALITY,'''') || '' '' || COALESCE(LISTAGG(se.SERIES_DESC, '' '') WITHIN GROUP (ORDER BY se.SERIES_DESC), '''')) AS SEARCH_TEXT FROM <STUDY_TBL> s LEFT JOIN <SERIES_TBL> se ON se.STUDY_UID = s.STUDY_UID GROUP BY s.STUDY_UID, s.MODALITY, s.STUDY_DATE, s.PATIENT_ID, s.STUDY_DESC)';
  EXECUTE IMMEDIATE :ddl;
  RETURN OBJECT_CONSTRUCT(
    'ok', TRUE,
    'search_service', CURRENT_DATABASE()||'.'||CURRENT_SCHEMA()||'.<SEARCH_SVC>',
    'grain', 'one row per study',
    'built_by', CURRENT_ROLE()
  );
END
$$;
