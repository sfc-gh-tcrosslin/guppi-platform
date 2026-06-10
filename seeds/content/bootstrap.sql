-- =============================================================================
-- guppi-platform v3.0.0 — Content Seed: Bootstrap
-- ONE-TIME ONLY for fresh accounts. Do NOT re-run on existing accounts.
-- Inserts seed rows into ID_CONVENTIONS so SUBMIT_INITIATIVE / PUBLISH_ARTIFACT work.
-- Customer's own ARTIFACTS rows are NEVER touched by engine seeds.
-- =============================================================================

INSERT INTO GUPPIWHEEL.PUBLIC.ID_CONVENTIONS (ENTITY, NEXT_SEQ, NOTES)
SELECT * FROM VALUES
    ('INITIATIVE', 1, 'Sequence for INIT-N artifact IDs'),
    ('RESEARCH',   1, 'Sequence (not generally used; Rocky uses RES-INIT-N-ROCKY)'),
    ('STORY',      1, 'Sequence for STORY-N artifact IDs'),
    ('EPIC',       1, 'Sequence for E-N artifact IDs'),
    ('NARRATIVE',  1, 'Sequence for NAR-N artifact IDs'),
    ('APP',        1, 'Sequence for APP-N / MOD-N / DASH-N artifact IDs'),
    ('AUDIT',      1, 'Sequence for AUDIT-N artifact IDs'),
    ('DEFECT',     1, 'Sequence for DEFECT-N artifact IDs'),
    ('INCIDENT',   1, 'Sequence for INC-N artifact IDs')
AS s(ENTITY, NEXT_SEQ, NOTES)
WHERE NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS WHERE ENTITY = s.ENTITY);
