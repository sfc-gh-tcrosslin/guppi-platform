-- WIDGET W-5  class=semantic-index  home=@GUPPI_LIB.LIB.WIDGET_FILES/semantic-index.sql
-- Purpose: build a semantic view over the metadata catalog so Cortex Analyst answers
--          natural-language questions (counts/dimensions).
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_SEMANTIC_INDEX recipe.
-- TOKENS: <PREFIX> proc prefix; <SV> semantic view name; <STUDY_TBL>/<SERIES_TBL>/<INSTANCE_TBL>
--   catalog tables + their PKs/FKs; the DIMENSIONS/METRICS below are the reference (DICOM) shape --
--   replace with the dimensions you slice by and the metrics you ask for.
-- EXIT GATE: SEMANTIC_VIEW(<SV> METRICS ...) returns the same counts as the base tables.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_SEMANTIC_INDEX()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Build recipe: idempotently builds a semantic view over the metadata catalog for Cortex Analyst. Metadata only.'
EXECUTE AS OWNER
AS '
BEGIN
  CREATE OR REPLACE SEMANTIC VIEW <SV>
    TABLES (
      study    AS <STUDY_TBL>    PRIMARY KEY (STUDY_UID)  WITH SYNONYMS=(''studies'') COMMENT=''One row per study'',
      series   AS <SERIES_TBL>   PRIMARY KEY (SERIES_UID) WITH SYNONYMS=(''series'') COMMENT=''One row per series'',
      instance AS <INSTANCE_TBL> PRIMARY KEY (SOP_UID)    WITH SYNONYMS=(''instances'',''images'') COMMENT=''One row per instance, metadata only''
    )
    RELATIONSHIPS (
      series_belongs_to_study    AS series   (STUDY_UID)  REFERENCES study  (STUDY_UID),
      instance_belongs_to_series AS instance (SERIES_UID) REFERENCES series (SERIES_UID)
    )
    DIMENSIONS (
      study.modality           AS study.MODALITY          WITH SYNONYMS=(''scan type'') COMMENT=''Modality code'',
      study.study_date         AS study.STUDY_DATE        COMMENT=''Study date'',
      study.study_desc         AS study.STUDY_DESC        COMMENT=''Study description'',
      study.patient_id         AS study.PATIENT_ID        COMMENT=''De-identified patient identifier'',
      series.series_desc       AS series.SERIES_DESC      COMMENT=''Series description'',
      instance.instance_number AS instance.INSTANCE_NUMBER COMMENT=''Instance number within series''
    )
    METRICS (
      study.study_count       AS COUNT(study.STUDY_UID)   COMMENT=''Number of studies'',
      series.series_count     AS COUNT(series.SERIES_UID) COMMENT=''Number of series'',
      instance.instance_count AS COUNT(instance.SOP_UID)  COMMENT=''Number of instances''
    )
    COMMENT=''builder-built semantic view over the metadata catalog. Metadata only.'';
  RETURN OBJECT_CONSTRUCT(''ok'', TRUE, ''semantic_view'', ''<SV>'', ''built_by'', CURRENT_ROLE());
END;
';
