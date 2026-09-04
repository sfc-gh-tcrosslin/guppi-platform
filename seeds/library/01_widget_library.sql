-- =============================================================================
-- guppi-platform : seeds/library/01_widget_library.sql
-- GUPPI_LIB -- the canonical WIDGET library home (least-privilege convention).
-- =============================================================================
-- GRANT-ONCE / ACCOUNT PHASE. Run as ACCOUNTADMIN (needs CREATE ROLE + CREATE
-- DATABASE + MANAGE GRANTS). Idempotent: safe to re-apply -- equal re-apply is a
-- no-op. On an account where GUPPI_LIB already exists (built live) this reconciles
-- to the same state and clears any residual PUBLIC (current + future).
--
-- Convention (Todd, 2026-09-03): GUPPI_* platform DBs use a dedicated least-priv
-- steward that OWNS the schema/objects, and the named Guppi family consumes
-- (VIEWER read / CONTRIBUTOR+ADMIN run). NOT broad PUBLIC.  The DATABASE stays
-- ACCOUNTADMIN-owned, and the steward owns schema + objects + stage.
--
-- Widget FILES (build templates) are shipped in assets/widgets/ and PUT to
-- @GUPPI_LIB.LIB.WIDGET_FILES by the install step (see assets/widgets/README.md).
-- =============================================================================

-- 1. steward role -------------------------------------------------------------
CREATE ROLE IF NOT EXISTS GUPPI_LIB_STEWARD;
GRANT ROLE GUPPI_LIB_STEWARD TO ROLE ACCOUNTADMIN;

-- 2. database (owner = ACCOUNTADMIN) ------------------------------------------
CREATE DATABASE IF NOT EXISTS GUPPI_LIB;
GRANT USAGE ON DATABASE GUPPI_LIB TO ROLE GUPPI_LIB_STEWARD;
GRANT USAGE ON DATABASE GUPPI_LIB TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON DATABASE GUPPI_LIB TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON DATABASE GUPPI_LIB TO ROLE GUPPIWHEEL_ADMIN;
REVOKE USAGE ON DATABASE GUPPI_LIB FROM ROLE PUBLIC;

-- 3. LIB schema (owner = steward) ---------------------------------------------
CREATE SCHEMA IF NOT EXISTS GUPPI_LIB.LIB;
GRANT OWNERSHIP ON SCHEMA GUPPI_LIB.LIB TO ROLE GUPPI_LIB_STEWARD COPY CURRENT GRANTS;
GRANT USAGE ON SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_ADMIN;

-- 4. WIDGET_FILES stage (owner = steward, file-widget home) -------------------
CREATE STAGE IF NOT EXISTS GUPPI_LIB.LIB.WIDGET_FILES
  COMMENT = 'Home for file-type widgets (build-template SQL, etc.). Impls PUT from assets/widgets/.';
GRANT OWNERSHIP ON STAGE GUPPI_LIB.LIB.WIDGET_FILES TO ROLE GUPPI_LIB_STEWARD COPY CURRENT GRANTS;
GRANT READ ON STAGE GUPPI_LIB.LIB.WIDGET_FILES TO ROLE GUPPIWHEEL_VIEWER;
GRANT READ ON STAGE GUPPI_LIB.LIB.WIDGET_FILES TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT READ ON STAGE GUPPI_LIB.LIB.WIDGET_FILES TO ROLE GUPPIWHEEL_ADMIN;

-- 5. W-1 PARSE_DICOM (object-widget: a runnable header-parse UDF) --------------
CREATE OR REPLACE FUNCTION GUPPI_LIB.LIB.PARSE_DICOM("URL" VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','pydicom','numpy')
HANDLER = 'run'
COMMENT = 'WIDGET W-1: DICOM header parse (metadata only, stop_before_pixels). Reads a staged file via SnowflakeFile scoped URL.'
AS $$
from snowflake.snowpark.files import SnowflakeFile
import pydicom, io
def run(url):
    with SnowflakeFile.open(url, 'rb') as f:
        ds = pydicom.dcmread(io.BytesIO(f.read()), stop_before_pixels=True)
    def g(t):
        v = ds.get(t, None)
        return str(v) if v is not None else None
    return {
      "patient_id": g("PatientID"), "study_uid": g("StudyInstanceUID"),
      "series_uid": g("SeriesInstanceUID"), "sop_uid": g("SOPInstanceUID"),
      "modality": g("Modality"), "study_date": g("StudyDate"),
      "study_desc": g("StudyDescription"), "series_desc": g("SeriesDescription"),
      "instance_number": g("InstanceNumber"),
      "px_rows": int(ds.get("Rows",0) or 0), "px_cols": int(ds.get("Columns",0) or 0)
    }
$$;
GRANT OWNERSHIP ON FUNCTION GUPPI_LIB.LIB.PARSE_DICOM(VARCHAR) TO ROLE GUPPI_LIB_STEWARD COPY CURRENT GRANTS;
GRANT USAGE ON FUNCTION GUPPI_LIB.LIB.PARSE_DICOM(VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON FUNCTION GUPPI_LIB.LIB.PARSE_DICOM(VARCHAR) TO ROLE GUPPIWHEEL_ADMIN;

-- 6. FUTURE grants: new lib impls inherit the family (run tier), never PUBLIC --
--    (defensive REVOKE clears a residual PUBLIC future grant on accounts that
--     pre-dated the standardization -- harmless on a fresh install.)
REVOKE USAGE ON FUTURE FUNCTIONS  IN SCHEMA GUPPI_LIB.LIB FROM ROLE PUBLIC;
REVOKE USAGE ON FUTURE PROCEDURES IN SCHEMA GUPPI_LIB.LIB FROM ROLE PUBLIC;
GRANT USAGE ON FUTURE FUNCTIONS  IN SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON FUTURE FUNCTIONS  IN SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_ADMIN;

GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GUPPI_LIB.LIB TO ROLE GUPPIWHEEL_ADMIN;
