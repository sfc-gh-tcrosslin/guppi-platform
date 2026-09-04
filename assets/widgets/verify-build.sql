-- WIDGET W-10  class=verify-build  home=@GUPPI_LIB.LIB.WIDGET_FILES/verify-build.sql
-- Purpose: run deterministic acceptance gates over a build and return structured pass/fail per gate
--          + overall. This is the builder SELF-CHECK (feeds an independent audit); it is NOT the audit.
-- Source: generalized from the proven dicom-vna-companion DICOM_VERIFY_BUILD recipe.
-- TOKENS: <PREFIX> proc prefix; <STUDY_TBL>/<SERIES_TBL>/<INSTANCE_TBL> catalog tables; <RAW_STAGE> source stage;
--   <SV>/<SEARCH_SVC>/<AGENT> object names. Gates below are the reference (DICOM) set -- express your
--   acceptance criteria (from the stories) as boolean gates over COUNT/SHOW/SEMANTIC_VIEW.
-- EXIT GATE: overall_pass = true across all gates on representative state.
CREATE OR REPLACE PROCEDURE <PREFIX>_VERIFY_BUILD()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Build recipe: runs deterministic acceptance gates over the build and returns structured pass/fail per gate + overall. Read-only self-check.'
EXECUTE AS OWNER
AS '
DECLARE
  obj_cnt INT; dir_files INT; inst_cnt INT; orphan_series INT; orphan_inst INT;
  bin_cols INT; sv_studies INT; search_cnt INT; agent_cnt INT;
  g_objs BOOLEAN; g_index BOOLEAN; g_nopix BOOLEAN; g_refint BOOLEAN;
  g_sv BOOLEAN; g_search BOOLEAN; g_agent BOOLEAN; overall BOOLEAN;
BEGIN
  obj_cnt := (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES
              WHERE TABLE_SCHEMA=CURRENT_SCHEMA() AND TABLE_NAME IN (''<STUDY_TBL>'',''<SERIES_TBL>'',''<INSTANCE_TBL>''));
  dir_files := (SELECT COUNT(*) FROM DIRECTORY(@<RAW_STAGE>));
  inst_cnt  := (SELECT COUNT(*) FROM <INSTANCE_TBL>);
  bin_cols  := (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_SCHEMA=CURRENT_SCHEMA() AND TABLE_NAME=''<INSTANCE_TBL>'' AND DATA_TYPE IN (''BINARY'',''VARBINARY''));
  orphan_series := (SELECT COUNT(*) FROM <SERIES_TBL> se
                    LEFT JOIN <STUDY_TBL> s ON se.STUDY_UID=s.STUDY_UID WHERE s.STUDY_UID IS NULL);
  orphan_inst := (SELECT COUNT(*) FROM <INSTANCE_TBL> i
                  LEFT JOIN <SERIES_TBL> se ON i.SERIES_UID=se.SERIES_UID WHERE se.SERIES_UID IS NULL);
  BEGIN
    sv_studies := (SELECT study_count FROM SEMANTIC_VIEW(<SV> METRICS study.study_count));
  EXCEPTION WHEN OTHER THEN sv_studies := -1;
  END;
  SHOW CORTEX SEARCH SERVICES LIKE ''<SEARCH_SVC>'';
  search_cnt := (SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
  SHOW AGENTS LIKE ''<AGENT>'';
  agent_cnt := (SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  g_objs   := (obj_cnt = 3);
  g_index  := (dir_files > 0 AND inst_cnt = dir_files);
  g_nopix  := (bin_cols = 0);
  g_refint := (orphan_series = 0 AND orphan_inst = 0);
  g_sv     := (sv_studies >= 1);
  g_search := (search_cnt >= 1);
  g_agent  := (agent_cnt >= 1);
  overall  := (g_objs AND g_index AND g_nopix AND g_refint AND g_sv AND g_search AND g_agent);

  RETURN OBJECT_CONSTRUCT(
    ''ok'', TRUE,
    ''overall_pass'', :overall,
    ''gates'', ARRAY_CONSTRUCT(
      OBJECT_CONSTRUCT(''name'',''catalog_objects_exist'',''pass'',:g_objs,''detail'',''catalog tables present (''||:obj_cnt||''/3)''),
      OBJECT_CONSTRUCT(''name'',''index_complete'',''pass'',:g_index,''detail'',''instances=''||:inst_cnt||'' vs directory files=''||:dir_files),
      OBJECT_CONSTRUCT(''name'',''no_pixel_columns'',''pass'',:g_nopix,''detail'',''binary columns=''||:bin_cols||'' (metadata-only)''),
      OBJECT_CONSTRUCT(''name'',''referential_integrity'',''pass'',:g_refint,''detail'',''orphan series=''||:orphan_series||'', orphan instances=''||:orphan_inst),
      OBJECT_CONSTRUCT(''name'',''semantic_view_answers'',''pass'',:g_sv,''detail'',''study_count=''||:sv_studies),
      OBJECT_CONSTRUCT(''name'',''search_service_exists'',''pass'',:g_search,''detail'',''matches=''||:search_cnt),
      OBJECT_CONSTRUCT(''name'',''agent_exists'',''pass'',:g_agent,''detail'',''matches=''||:agent_cnt)
    ),
    ''verified_by'', CURRENT_ROLE()
  );
END;
';
