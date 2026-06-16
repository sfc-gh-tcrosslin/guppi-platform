-- =============================================================================
-- guppi-platform v3.0.0 — Content Seed: Bootstrap
-- ONE-TIME ONLY for fresh accounts. Do NOT re-run on existing accounts.
-- Inserts seed rows into ID_CONVENTIONS so SUBMIT_INITIATIVE / PUBLISH_ARTIFACT work.
-- Customer's own ARTIFACTS rows are NEVER touched by engine seeds.
-- =============================================================================

INSERT INTO GUPPIWHEEL.PUBLIC.ID_CONVENTIONS (ENTITY, NEXT_SEQ, ID_PREFIX, NOTES)
SELECT * FROM VALUES
    ('INITIATIVE', 1, 'INIT-', 'Global INIT-N artifact IDs'),
    ('RESEARCH',   1, NULL,    'Rocky uses RES-<init>-ROCKY (collision-guarded); not auto-allocated'),
    ('STORY',      1, NULL,    'Stories are product-scoped: STORY_<PRODUCT> rows registered per product'),
    ('EPIC',       1, 'E-',    'Global E-N artifact IDs'),
    ('NARRATIVE',  1, 'NAR-',  'Global NAR-N artifact IDs'),
    ('APP',        1, 'APP-',  'APP-N / MOD-N / DASH-N artifact IDs'),
    ('AUDIT',      1, NULL,    'Descriptive slug-date IDs; not auto-allocated'),
    ('DEFECT',     1, NULL,    'Defects are product-scoped: DEFECT_<PRODUCT> rows registered per product'),
    ('INCIDENT',   1, 'INC-',  'Global INC-N artifact IDs'),
    ('STORY_STEWART', 1, 'STO-STEWART-', 'Stewart-authored hygiene/correction stories (product-tagged guppi)')
AS s(ENTITY, NEXT_SEQ, ID_PREFIX, NOTES)
WHERE NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = s.ENTITY);
