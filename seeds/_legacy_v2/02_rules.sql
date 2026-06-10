-- GuppiWheel Platform Rules
-- These are the universal rules that every GuppiWheel account gets.
-- Project-specific rules are added locally per spin.
-- Run AFTER 01_schema.sql

MERGE INTO GUPPIWHEEL.PUBLIC.RULES AS target
USING (
  SELECT column1 AS RULE_ID, column2 AS RULE_TYPE, column3 AS APPLIES_TO_TYPE,
         column4 AS FROM_STAGE, column5 AS TO_STAGE, column6 AS CONDITION_SQL,
         column7 AS ENFORCEMENT, column8 AS OVERRIDABLE, column9 AS MESSAGE
  FROM VALUES
    -- ==========================================================================
    -- GUIDING PRINCIPLES (platform-wide, non-negotiable)
    -- ==========================================================================
    ('RULE-013', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'SELECT COUNT(*) = 0 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id',
     'block', FALSE,
     'Headless First: All outputs MUST be written as artifacts in GUPPIWHEEL.PUBLIC.ARTIFACTS before any external render (doc, HTML, slides). The flywheel is the source of truth. Render FROM artifacts, never instead of them.'),

    -- ==========================================================================
    -- STAGE TRANSITIONS (when can an artifact advance?)
    -- ==========================================================================
    ('STG-001', 'stage_transition', 'initiative', 'spark', 'active',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id AND TYPE = ''research'')',
     'block', FALSE,
     'Initiative cannot advance to active without at least one research artifact as a child'),

    ('STG-002', 'stage_transition', 'story', 'active', 'built',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id AND TYPE IN (''app'',''model''))',
     'block', TRUE,
     'Story cannot advance to built without at least one app/model artifact linked'),

    ('STG-003', 'stage_transition', 'app', 'built', 'proven',
     'EXISTS (SELECT 1 FROM GUPPI.PLATFORM.AUDIT_RUNS ar JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.TARGET_NAME = a.TITLE WHERE a.ID = :artifact_id AND ar.TRUST_SCORE >= 0.85)',
     'block', TRUE,
     'App cannot advance to proven without a TARS audit scoring >= 0.85'),

    ('STG-004', 'stage_transition', 'ALL', NULL, 'told',
     'EXISTS (SELECT 1 FROM GUPPI.PLATFORM.AUDIT_RUNS ar JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.TARGET_NAME = a.TITLE WHERE a.ID = :artifact_id AND ar.HUMAN_VOTE IS NOT NULL)',
     'block', FALSE,
     'Nothing advances to told (narrative) without a human vote on the TARS audit'),

    -- ==========================================================================
    -- COMPLETENESS (does the artifact have required fields?)
    -- ==========================================================================
    ('CMP-001', 'completeness', 'research', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND METADATA:verdict IS NOT NULL)',
     'warn', FALSE,
     'Research artifact should have a verdict (SUPPORTED/REFUTED/PARTIAL) in metadata'),

    ('CMP-002', 'completeness', 'app', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND (METADATA:app_type IS NOT NULL OR METADATA:viz_template IS NOT NULL))',
     'warn', FALSE,
     'App artifact should have app_type or viz_template identified in metadata'),

    ('CMP-003', 'completeness', 'hero', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND METADATA:outcome IS NOT NULL)',
     'warn', FALSE,
     'Hero artifact must have quantified outcomes in metadata'),

    -- ==========================================================================
    -- QUALITY (TARS integration)
    -- ==========================================================================
    ('QAL-001', 'quality', 'ALL', NULL, NULL,
     'NOT EXISTS (SELECT 1 FROM GUPPI.PLATFORM.AUDIT_RUNS ar JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.TARGET_NAME = a.TITLE WHERE a.ID = :artifact_id AND ar.TRUST_SCORE < 0.70)',
     'block', FALSE,
     'TARS score below 0.70 blocks all stage advancement'),

    ('QAL-002', 'quality', 'ALL', NULL, NULL,
     'NOT EXISTS (SELECT 1 FROM GUPPI.PLATFORM.AUDIT_FINDINGS af JOIN GUPPI.PLATFORM.AUDIT_RUNS ar ON af.AUDIT_ID = ar.AUDIT_ID JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.TARGET_NAME = a.TITLE WHERE a.ID = :artifact_id AND af.SIGNAL = ''D'' AND af.HUMAN_DISPOSITION IS NULL)',
     'warn', FALSE,
     'D signals without human dispositions should be addressed before advancing'),

    -- ==========================================================================
    -- TIMING (staleness detection)
    -- ==========================================================================
    ('TMG-001', 'timing', 'ALL', NULL, NULL,
     'DATEDIFF(''day'', (SELECT CREATED_AT FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id), CURRENT_TIMESTAMP()) <= 30 OR EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id)',
     'flag', FALSE,
     'Artifact at same stage >30 days with no children — consider stale'),

    ('TMG-002', 'timing', 'initiative', 'spark', 'spark',
     'DATEDIFF(''day'', (SELECT CREATED_AT FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND STAGE = ''spark''), CURRENT_TIMESTAMP()) <= 7',
     'flag', FALSE,
     'Initiative at spark >7 days without research started — going cold'),

    ('TMG-003', 'timing', 'ALL', NULL, NULL,
     'NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.VIOLATIONS WHERE ARTIFACT_ID = :artifact_id AND STATUS = ''open'' AND DATEDIFF(''day'', DETECTED_AT, CURRENT_TIMESTAMP()) > 14)',
     'warn', FALSE,
     'Violation open >14 days without acknowledgment — needs attention')

) AS source (RULE_ID, RULE_TYPE, APPLIES_TO_TYPE, FROM_STAGE, TO_STAGE, CONDITION_SQL, ENFORCEMENT, OVERRIDABLE, MESSAGE)
ON target.RULE_ID = source.RULE_ID
WHEN MATCHED THEN UPDATE SET
    RULE_TYPE = source.RULE_TYPE,
    APPLIES_TO_TYPE = source.APPLIES_TO_TYPE,
    FROM_STAGE = source.FROM_STAGE,
    TO_STAGE = source.TO_STAGE,
    CONDITION_SQL = source.CONDITION_SQL,
    ENFORCEMENT = source.ENFORCEMENT,
    OVERRIDABLE = source.OVERRIDABLE,
    MESSAGE = source.MESSAGE,
    UPDATED_AT = CURRENT_TIMESTAMP(),
    VERSION = target.VERSION + 1
WHEN NOT MATCHED THEN INSERT (RULE_ID, RULE_TYPE, APPLIES_TO_TYPE, FROM_STAGE, TO_STAGE, CONDITION_SQL, ENFORCEMENT, OVERRIDABLE, MESSAGE)
VALUES (source.RULE_ID, source.RULE_TYPE, source.APPLIES_TO_TYPE, source.FROM_STAGE, source.TO_STAGE, source.CONDITION_SQL, source.ENFORCEMENT, source.OVERRIDABLE, source.MESSAGE);
