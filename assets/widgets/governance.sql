-- WIDGET W-8  class=governance  home=@GUPPI_LIB.LIB.WIDGET_FILES/governance.sql
-- Purpose: apply column masking + a row-access policy driven by a SCOPED entitlements table;
--          keep an independent auditor able to READ (rows visible, sensitive column still masked).
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_GOVERNANCE recipe.
-- TOKENS: <PREFIX> proc prefix; <TBL> governed table; <MASK_COL> masked column; <RAP_COL> row-access column;
--   <ENT> entitlements table; <MP>/<RAP> policy names; <PRIVILEGED_ROLES> comma list of full-access roles;
--   <AUDITOR_ROLE> independent auditor (reads rows, masked column stays masked). Scoped rows only (no '*').
-- EXIT GATE: policy_applied != isolation_proven -- prove a scoped role sees only its scope, a
--   non-entitled role sees ZERO, auditor sees rows but the masked column stays masked.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_GOVERNANCE()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Governance day-one (idempotent, detach-before-replace): masking + row-access over a scoped entitlements table; auditor reads rows, sensitive column stays masked.'
EXECUTE AS OWNER
AS '
DECLARE
  applied VARIANT;
BEGIN
  CREATE TABLE IF NOT EXISTS <ENT> (ROLE_NAME STRING, ALLOWED_VALUE STRING);
  BEGIN ALTER TABLE <TBL> MODIFY COLUMN <MASK_COL> UNSET MASKING POLICY; EXCEPTION WHEN OTHER THEN NULL; END;
  CREATE OR REPLACE MASKING POLICY <MP> AS (v STRING) RETURNS STRING ->
    CASE WHEN CURRENT_ROLE() IN (<PRIVILEGED_ROLES>) THEN v ELSE ''***MASKED***'' END;
  ALTER TABLE <TBL> MODIFY COLUMN <MASK_COL> SET MASKING POLICY <MP> FORCE;
  BEGIN ALTER TABLE <TBL> DROP ROW ACCESS POLICY <RAP>; EXCEPTION WHEN OTHER THEN NULL; END;
  CREATE OR REPLACE ROW ACCESS POLICY <RAP> AS (val STRING) RETURNS BOOLEAN ->
    CURRENT_ROLE() IN (<PRIVILEGED_ROLES>,''<AUDITOR_ROLE>'')
    OR EXISTS (SELECT 1 FROM <ENT> e
               WHERE e.ROLE_NAME = CURRENT_ROLE() AND (e.ALLOWED_VALUE = val OR e.ALLOWED_VALUE = ''*''));
  ALTER TABLE <TBL> ADD ROW ACCESS POLICY <RAP> ON (<RAP_COL>);
  applied := (SELECT ARRAY_AGG(OBJECT_CONSTRUCT(''policy'', POLICY_NAME, ''kind'', POLICY_KIND, ''column'', REF_COLUMN_NAME))
                FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
                  REF_ENTITY_NAME => CURRENT_DATABASE()||''.''||CURRENT_SCHEMA()||''.<TBL>'', REF_ENTITY_DOMAIN => ''TABLE'')));
  RETURN OBJECT_CONSTRUCT(''ok'', TRUE,
    ''masking_policy'',''<MP> on <TBL>.<MASK_COL>'',
    ''row_access_policy'',''<RAP> on <TBL>(<RAP_COL>)'',
    ''entitlements_table'',''<ENT>'',
    ''applied_policies'', :applied,
    ''auditor_read'',''<AUDITOR_ROLE> via explicit allow-list (rows visible, <MASK_COL> stays masked)'',
    ''idempotent'',''detach-before-replace'',
    ''built_by'', CURRENT_ROLE());
END;
';
