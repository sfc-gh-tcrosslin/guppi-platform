-- WIDGET W-4  class=storage-index  home=@GUPPI_LIB.LIB.WIDGET_FILES/storage-index.sql
-- Purpose: external-stage a single open-format copy and parse HEADERS ONLY into a
--          metadata catalog (study/series/instance). Metadata only, zero pixel/blob columns.
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_STORAGE_INDEX recipe.
-- TOKENS (substitute for your domain, then run in a builder-owned sandbox schema):
--   <PREFIX>        proc-name prefix           e.g. DICOM
--   <PARSE_FN>      header-only parse UDF       e.g. PARSE_DICOM  (widget W-1)
--   <STUDY_TBL>/<SERIES_TBL>/<INSTANCE_TBL>     catalog grain tables
--   the m:<field>::<type> -> column mapping below is the reference (DICOM) shape; adjust per domain.
-- EXIT GATE: row counts load; parsed-instances == directory files; ZERO binary/blob columns; no orphans.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_STORAGE_INDEX("P_STAGE" VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS 'DECLARE
  n_inst INT; n_ser INT; n_std INT;
BEGIN
  EXECUTE IMMEDIATE ''ALTER STAGE '' || :P_STAGE || '' REFRESH'';
  EXECUTE IMMEDIATE ''CREATE OR REPLACE TEMP TABLE _P AS SELECT RELATIVE_PATH op, <PARSE_FN>(BUILD_SCOPED_FILE_URL(@'' || :P_STAGE || '', RELATIVE_PATH)) m FROM DIRECTORY(@'' || :P_STAGE || '')'';
  MERGE INTO <INSTANCE_TBL> t USING (
     SELECT m:sop_uid::string sop, m:series_uid::string ser, m:study_uid::string std,
            m:instance_number::string inum, m:px_rows::int r, m:px_cols::int c, op FROM _P) s ON t.sop_uid=s.sop
   WHEN NOT MATCHED THEN INSERT (sop_uid,series_uid,study_uid,instance_number,px_rows,px_cols,object_path,ingested_at)
     VALUES (s.sop,s.ser,s.std,s.inum,s.r,s.c,s.op,CURRENT_TIMESTAMP());
  MERGE INTO <SERIES_TBL> t USING (SELECT DISTINCT m:series_uid::string ser, m:study_uid::string std, m:series_desc::string sd, m:modality::string mo FROM _P) s
    ON t.series_uid=s.ser WHEN NOT MATCHED THEN INSERT (series_uid,study_uid,series_desc,modality) VALUES (s.ser,s.std,s.sd,s.mo);
  MERGE INTO <STUDY_TBL> t USING (SELECT DISTINCT m:study_uid::string std, m:patient_id::string pid, m:study_date::string dt, m:study_desc::string sd, m:modality::string mo FROM _P) s
    ON t.study_uid=s.std WHEN NOT MATCHED THEN INSERT (study_uid,patient_id,study_date,study_desc,modality) VALUES (s.std,s.pid,s.dt,s.sd,s.mo);
  SELECT COUNT(*) INTO :n_inst FROM <INSTANCE_TBL>;
  SELECT COUNT(*) INTO :n_ser FROM <SERIES_TBL>;
  SELECT COUNT(*) INTO :n_std FROM <STUDY_TBL>;
  RETURN OBJECT_CONSTRUCT(''ok'',TRUE,''stage'',:P_STAGE,''parse_fn'',''<PARSE_FN>'',''instances'',:n_inst,''series'',:n_ser,''studies'',:n_std);
END';
