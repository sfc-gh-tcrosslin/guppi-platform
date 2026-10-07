-- =============================================================================
-- guppi-platform upgrade: 3.31.0 -> 3.32.0 — derive IDs from data (PLAT-61)
-- =============================================================================
-- Retires stored ID counters. After this upgrade:
--   * global types take their prefix from TYPE_REGISTRY.ID_PREFIX (via ID_SERIES_ENTITY
--     when set: MODEL/DASHBOARD mint in the APP- series); NULL = explicit ID required
--   * product-scoped types (STORY/DEFECT) take PRODUCTS.ID_PREFIX || '-' || PRODUCT_ID_SUFFIX
--     (STORY '' -> PLAT-61, DEFECT 'D' -> PLAT-D9)
--   * the number is MAX(existing)+1, computed by CREATE_ARTIFACT inside the CHAIN_HEAD lock
--   * ID_CONVENTIONS is DEPRECATED (read-only for one release; nothing allocates from it)
--
-- Apply as ACCOUNTADMIN (substrate owner), in order:
--   1. this file (schema + prefix data + register missing products)
--   2. seeds/engine/03_procs.sql   (CREATE_ARTIFACT / PREVIEW_NEXT_ID / CREATE_PRODUCT / RESYNC)
--   3. seeds/engine/09_wheel_front_door.sql, seeds/engine/10_reconcile.sql
-- Idempotent: safe to re-run.
-- =============================================================================

USE SCHEMA GUPPIWHEEL.PUBLIC;

-- 1. Columns -------------------------------------------------------------------
ALTER TABLE GUPPIWHEEL.PUBLIC.PRODUCTS ADD COLUMN IF NOT EXISTS ID_PREFIX VARCHAR(30)
  COMMENT 'Stem for product-scoped IDs (STORY -> <stem>-N, DEFECT -> <stem>-DN). Unique across products. Set by CREATE_PRODUCT.';
ALTER TABLE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY ADD COLUMN IF NOT EXISTS PRODUCT_ID_SUFFIX VARCHAR(10)
  COMMENT 'Product-scoped types only: appended after <PRODUCTS.ID_PREFIX>- (STORY '''', DEFECT ''D'').';

-- 2. TYPE_REGISTRY: ID_PREFIX is now the real allocation prefix (prose moves to NOTES) --
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = NULL, PRODUCT_ID_SUFFIX = '',
       NOTES = 'Product-scoped: <PRODUCTS.ID_PREFIX>-N (PLAT-, CHEMLENS-, F6-, ...). Product must be registered with an ID_PREFIX (CREATE_PRODUCT).',
       UPDATED_AT = CURRENT_TIMESTAMP()
 WHERE TYPE = 'STORY';
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = NULL, PRODUCT_ID_SUFFIX = 'D',
       NOTES = 'Product-scoped: <PRODUCTS.ID_PREFIX>-DN (PLAT-D, F6-D, SC-D, GUPPI-D).',
       UPDATED_AT = CURRENT_TIMESTAMP()
 WHERE TYPE = 'DEFECT';
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = 'AUDIT-', NOTES = 'Global AUDIT-N series (was mis-registered under 4 ID_CONVENTIONS rows / 3 prefixes).', UPDATED_AT = CURRENT_TIMESTAMP() WHERE TYPE = 'AUDIT';
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = 'APP-', UPDATED_AT = CURRENT_TIMESTAMP() WHERE TYPE IN ('MODEL', 'DASHBOARD');
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = NULL, NOTES = 'Descriptive slug ID (OPS-<slug>); pass P_EXPLICIT_ID.', UPDATED_AT = CURRENT_TIMESTAMP() WHERE TYPE = 'OPS_EVENT';
UPDATE GUPPIWHEEL.PUBLIC.TYPE_REGISTRY SET ID_PREFIX = NULL, NOTES = 'Freeform slug ID; pass P_EXPLICIT_ID.', UPDATED_AT = CURRENT_TIMESTAMP() WHERE TYPE = 'SKILL';

-- 3. Register products that own an ID_CONVENTIONS story series but have no PRODUCTS row.
--    (Before 3.32.0 such products minted IDs but were never stamped: their stories were born
--    untagged.) Derived from THIS account's registry; no product names live in this file.
INSERT INTO GUPPIWHEEL.PUBLIC.PRODUCTS (PRODUCT_ID, NAME, DESCRIPTION, STATUS, CREATED_AT)
SELECT DISTINCT LOWER(SUBSTR(c.ENTITY, 7)), INITCAP(LOWER(SUBSTR(c.ENTITY, 7))),
       'Registered by the 3.32.0 upgrade: owned a story ID series but had no PRODUCTS row.', 'ACTIVE', CURRENT_TIMESTAMP()
FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS c
WHERE c.ENTITY LIKE 'STORY\\_%' ESCAPE '\\'
  AND LENGTH(c.ENTITY) > 6
  AND EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
               WHERE a.TYPE = 'STORY' AND a.PRODUCT_ID IS NULL AND STARTSWITH(a.ID, c.ID_PREFIX))
  AND NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.PRODUCTS p WHERE LOWER(p.PRODUCT_ID) = LOWER(SUBSTR(c.ENTITY, 7)));

-- 4. Stems (future allocation only; existing IDs never change). Account-local, derived:
--    (a) keep the stem the account already used for that product's STORY series in ID_CONVENTIONS
--        (e.g. 'PLAT-' -> PLAT), so new IDs continue the series people know;
--    (b) otherwise the CREATE_PRODUCT default: id upper-cased, alphanumerics only.
--    Shorter/renamed stems afterwards: SET_PRODUCT_PREFIX (admin). Never shared (asserted below).
UPDATE GUPPIWHEEL.PUBLIC.PRODUCTS p
   SET ID_PREFIX = COALESCE(
         (SELECT ANY_VALUE(RTRIM(c.ID_PREFIX, '-')) FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS c
           WHERE c.ENTITY = 'STORY_' || UPPER(p.PRODUCT_ID) AND REGEXP_LIKE(c.ID_PREFIX, '[A-Z][A-Z0-9]*-')),
         UPPER(REGEXP_REPLACE(p.PRODUCT_ID, '[^A-Za-z0-9]', '')))
 WHERE p.ID_PREFIX IS NULL;

-- 5. Deprecate the old registry (kept read-only for one release) ----------------
ALTER TABLE GUPPIWHEEL.PUBLIC.ID_CONVENTIONS SET COMMENT =
  'DEPRECATED in 3.32.0: IDs are derived (MAX+1 inside CREATE_ARTIFACT). Prefixes live in TYPE_REGISTRY.ID_PREFIX and PRODUCTS.ID_PREFIX. Nothing reads NEXT_SEQ. Scheduled for removal next release.';

-- 6. Assertions: every active product has a unique stem ----------------------------
SELECT IFF(COUNT(*) = 0, 'OK: no shared prefix stems',
           'FAIL: shared stems: ' || LISTAGG(ID_PREFIX, ',')) AS CHECK_SHARED_STEMS
FROM (SELECT ID_PREFIX FROM GUPPIWHEEL.PUBLIC.PRODUCTS WHERE ID_PREFIX IS NOT NULL GROUP BY 1 HAVING COUNT(*) > 1);
SELECT IFF(COUNT(*) = 0, 'OK: every product has a stem',
           'WARN: products without stem: ' || LISTAGG(PRODUCT_ID, ',')) AS CHECK_MISSING_STEMS
FROM GUPPIWHEEL.PUBLIC.PRODUCTS WHERE ID_PREFIX IS NULL;

-- 7. ID_SERIES_V — the ONE place the next ID is computed (CREATE_ARTIFACT reads it under the
--    CHAIN_HEAD lock; PREVIEW_NEXT_ID reads it without writing). Counts ALL rows incl.
--    superseded so an ID is never reused. Only strictly <PREFIX><digits> IDs count, so slug
--    IDs (RES-153-ROCKY, OPS-...) and longer prefixes (PLAT-D9 vs PLAT-) never interfere.
CREATE OR REPLACE VIEW GUPPIWHEEL.PUBLIC.ID_SERIES_V COPY GRANTS
COMMENT = '3.32.0: derived ID series. One row per (TYPE, PRODUCT_ID) with PREFIX, MAX_N in data, NEXT_ID. Global types: TYPE_REGISTRY.ID_PREFIX. Product-scoped: PRODUCTS.ID_PREFIX || ''-'' || TYPE_REGISTRY.PRODUCT_ID_SUFFIX.'
AS
WITH series AS (
  SELECT r.TYPE, NULL::VARCHAR AS PRODUCT_ID, r.ID_PREFIX AS PREFIX
  FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY r
  WHERE NOT r.ID_PRODUCT_SCOPED AND r.ID_PREFIX IS NOT NULL
  UNION ALL
  SELECT r.TYPE, LOWER(p.PRODUCT_ID), p.ID_PREFIX || '-' || COALESCE(r.PRODUCT_ID_SUFFIX, '')
  FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY r
  CROSS JOIN GUPPIWHEEL.PUBLIC.PRODUCTS p
  WHERE r.ID_PRODUCT_SCOPED AND p.ID_PREFIX IS NOT NULL
),
mx AS (
  SELECT u.PREFIX, MAX(TRY_TO_NUMBER(SUBSTR(a.ID, LENGTH(u.PREFIX) + 1))) AS MAX_N
  FROM (SELECT DISTINCT PREFIX FROM series) u
  LEFT JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a
    ON STARTSWITH(a.ID, u.PREFIX) AND REGEXP_LIKE(SUBSTR(a.ID, LENGTH(u.PREFIX) + 1), '[0-9]+')
  GROUP BY 1
)
SELECT s.TYPE, s.PRODUCT_ID, s.PREFIX, COALESCE(m.MAX_N, 0) AS MAX_N,
       s.PREFIX || TO_VARCHAR(COALESCE(m.MAX_N, 0) + 1) AS NEXT_ID
FROM series s JOIN mx m ON m.PREFIX = s.PREFIX;

GRANT SELECT ON VIEW GUPPIWHEEL.PUBLIC.ID_SERIES_V TO ROLE GUPPIWHEEL_CONTRIBUTOR;
