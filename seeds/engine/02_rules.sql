-- =============================================================================
-- guppi-platform v3.0.0 — Engine Seed 02: Rules
-- Idempotent MERGE. Safe to re-run. Updates existing rules; adds new ones.
-- All conditions use UPPERCASE TYPE values and new stage names.
-- =============================================================================

MERGE INTO GUPPIWHEEL.PUBLIC.RULES AS target
USING (
  SELECT column1 AS RULE_ID, column2 AS RULE_TYPE, column3 AS APPLIES_TO_TYPE,
         column4 AS FROM_STAGE, column5 AS TO_STAGE, column6 AS CONDITION_SQL,
         column7 AS ENFORCEMENT, column8 AS OVERRIDABLE, column9 AS MESSAGE
  FROM VALUES
    -- ==========================================================================
    -- GUIDING PRINCIPLES (platform-wide, non-overridable)
    -- ==========================================================================
    ('RULE-013', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'block', FALSE,
     'Headless First: Every output is an artifact written to GUPPIWHEEL.PUBLIC.ARTIFACTS before any external render. Render FROM artifacts, never instead of them.'),

    ('RULE-014', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'warn', FALSE,
     'Status Ownership: Submitters set Initiate. Agents set Research/Built/Narrated. Humans review and sign off.'),

    ('RULE-015', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'warn', FALSE,
     'Collaboration Tags: Use metadata.tagged_users (array of usernames) to route artifacts to specific people. The viewer renders a My Tagged scope.'),

    ('RULE-016', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'block', FALSE,
     'No Self-Spawning: Agents must never call submit_initiative or otherwise enqueue work for themselves. Outputs are research findings only.'),

    ('RULE-017', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'warn', FALSE,
     'Separation of Execution: Cowork dispatches. Rocky researches. Cowork must not call web_search. Rocky must not call submit_initiative.'),

    ('RULE-018', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE',
     'warn', FALSE,
     'Launchables Live in the Wheel: NARRATIVE/APP/MODEL/DASHBOARD artifacts must have metadata.launch with valid app_type and matching identifier|url|stage_path field. Local file paths are forbidden. Bytes belong in @GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS.'),

    ('RULE-019', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     '-- Enforced at publish time: PUBLISH_PLUGIN_VERSION must reject any new version whose manifest declares dropped columns/tables/procs, renames without view-shim, type narrowings, or signature-incompatible procs vs the prior version. Customer-content objects (corrections, accreted memory, renderings) are never modified by an engine update.',
     'block', FALSE,
     'Engine Additive-Only: Engine changes are additive only. New columns, new tables, new procs, new metrics, new versions running in parallel. NO drops. NO renames (use view-shims). NO incompatible signature changes. Versions coexist - a customer with v1.0 instances keeps them when v1.1 ships. The ONLY universally accepted exception is a security vulnerability fix; otherwise we fix forward by adding new behavior, never removing old. This rule is the operational expression of the Subjective frame: customer corrections accrete forever; engine never destroys them; "we never break your stuff" is enforced by code, not promised by marketing.'),

    -- ==========================================================================
    -- STAGE TRANSITIONS
    -- ==========================================================================
    ('STG-001', 'stage_transition', 'INITIATIVE', 'Initiate', 'Research',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id AND TYPE = ''RESEARCH'')',
     'block', FALSE,
     'Initiative cannot advance to Research without at least one RESEARCH child artifact'),

    ('STG-002', 'stage_transition', 'STORY', 'Research', 'Building',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id AND TYPE IN (''APP'',''MODEL'',''DASHBOARD''))',
     'block', TRUE,
     'Story cannot advance to Building without at least one APP/MODEL/DASHBOARD artifact linked'),

    ('STG-003', 'stage_transition', 'APP', 'Building', 'Built',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = ''AUDIT'' AND CONTENT:target::VARCHAR = (SELECT TITLE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id) AND CONTENT:score::FLOAT >= 0.85)',
     'block', TRUE,
     'App cannot advance to Built without a TARS audit scoring >= 0.85'),

    ('STG-004', 'stage_transition', 'ALL', NULL, 'Narrated',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS n WHERE n.PARENT_ID = :artifact_id AND n.TYPE = ''NARRATIVE'')',
     'block', TRUE,
     'Nothing advances to Narrated without a NARRATIVE child artifact'),

    -- ==========================================================================
    -- COMPLETENESS
    -- ==========================================================================
    ('CMP-001', 'completeness', 'RESEARCH', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND CONTENT:verdict IS NOT NULL)',
     'warn', FALSE,
     'Research artifact should have a verdict (SUPPORTED/REFUTED/PARTIAL) in content'),

    ('CMP-002', 'completeness', 'APP', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND METADATA:launch:app_type IS NOT NULL)',
     'warn', FALSE,
     'App artifact should have metadata.launch.app_type identified'),

    ('CMP-003', 'completeness', 'NARRATIVE', NULL, NULL,
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id AND METADATA:launch:stage_path IS NOT NULL)',
     'warn', FALSE,
     'Narrative artifact should have metadata.launch.stage_path pointing into ARTIFACT_ASSETS stage'),

    -- ==========================================================================
    -- QUALITY (TARS via in-wheel AUDIT artifacts)
    -- ==========================================================================
    ('QAL-001', 'quality', 'ALL', NULL, NULL,
     'NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS au WHERE au.TYPE = ''AUDIT'' AND au.CONTENT:target::VARCHAR = (SELECT TITLE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id) AND au.CONTENT:score::FLOAT < 0.70)',
     'block', FALSE,
     'TARS score below 0.70 blocks all stage advancement'),

    -- ==========================================================================
    -- TIMING
    -- ==========================================================================
    ('TMG-001', 'timing', 'ALL', NULL, NULL,
     'DATEDIFF(''day'', (SELECT UPDATED_AT FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id), CURRENT_TIMESTAMP()) <= 30 OR EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :artifact_id)',
     'warn', FALSE,
     'Artifact at same stage >30 days with no children — consider stale'),

    ('TMG-002', 'timing', 'INITIATIVE', 'Initiate', 'Initiate',
     'DATEDIFF(''day'', (SELECT CREATED_AT FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :artifact_id), CURRENT_TIMESTAMP()) <= 7',
     'warn', FALSE,
     'Initiative at Initiate >7 days without research started — going cold')

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
    VERSION = COALESCE(target.VERSION, 1) + 1
WHEN NOT MATCHED THEN INSERT (RULE_ID, RULE_TYPE, APPLIES_TO_TYPE, FROM_STAGE, TO_STAGE, CONDITION_SQL, ENFORCEMENT, OVERRIDABLE, MESSAGE)
VALUES (source.RULE_ID, source.RULE_TYPE, source.APPLIES_TO_TYPE, source.FROM_STAGE, source.TO_STAGE, source.CONDITION_SQL, source.ENFORCEMENT, source.OVERRIDABLE, source.MESSAGE);
