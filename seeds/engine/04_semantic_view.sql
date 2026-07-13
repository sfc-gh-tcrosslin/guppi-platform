-- =============================================================================
-- guppi-platform v3.15.0 — Engine Seed 04: Semantic View
-- TIER 1 (DEFAULT): the semantic view shape is yours to re-author. It binds Cortex
--   Analyst to ARTIFACTS for natural-language querying. See COCO.md.
-- For Cortex Analyst natural-language querying via the Cowork agent.
-- CREATE OR REPLACE. Safe to re-run.
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV

  TABLES (
    artifacts AS GUPPIWHEEL.PUBLIC.ARTIFACTS
      PRIMARY KEY (ID)
      COMMENT = 'All GuppiWheel artifacts',
    type_registry AS GUPPIWHEEL.PUBLIC.TYPE_REGISTRY
      PRIMARY KEY (TYPE)
      COMMENT = 'Canonical artifact-type taxonomy (governance-as-data). One row per type with its definition, lifecycle, and valid stages.'
  )

  RELATIONSHIPS (
    artifact_to_type AS artifacts (TYPE) REFERENCES type_registry (TYPE)
  )

  FACTS (
    artifacts.created_at AS CREATED_AT,
    artifacts.updated_at AS UPDATED_AT
  )

  DIMENSIONS (
    artifacts.artifact_id AS ID
      COMMENT = 'Unique artifact identifier',
    artifacts.artifact_type AS TYPE
      WITH SYNONYMS = ('type', 'kind', 'category')
      COMMENT = 'One of the 14 canonical types: INITIATIVE, EPIC, RESEARCH, STORY, NARRATIVE, APP, MODEL, DASHBOARD, DEFECT, INCIDENT, AUDIT, OPS_EVENT, OUTCOME, SKILL. Definitions/lifecycles are authoritative in TYPE_REGISTRY (joined) - see the PURPOSE/LIFECYCLE/TYPE_STAGES dimensions.',
    artifacts.stage AS STAGE
      WITH SYNONYMS = ('status', 'lifecycle stage')
      COMMENT = 'Standard lifecycle: Initiate, Research, Building, Built, Narrated. STORY/DEFECT also use SELECTED/RESOLVED/Resolved. OUTCOME uses its own 4-stage lifecycle: ASPIRATIONAL, SELECTED, TRACKED, RESOLVED.',
    artifacts.owner AS OWNER
      WITH SYNONYMS = ('created by', 'author')
      COMMENT = 'Who owns this artifact',
    artifacts.parent_id AS PARENT_ID
      COMMENT = 'Parent artifact for lineage',
    artifacts.title AS TITLE
      WITH SYNONYMS = ('name', 'subject')
      COMMENT = 'Human-readable title',
    type_registry.type_purpose AS PURPOSE
      WITH SYNONYMS = ('definition', 'what is this type', 'meaning', 'what does this type mean')
      COMMENT = 'Authoritative definition of an artifact type: what it is and when to use it. Use to answer "what is an OUTCOME / STORY / ..." questions.',
    type_registry.type_lifecycle AS LIFECYCLE
      WITH SYNONYMS = ('lifecycle family')
      COMMENT = 'Lifecycle family for the type: standard | workitem | outcome',
    type_registry.type_stages AS STAGES
      WITH SYNONYMS = ('valid stages', 'allowed stages')
      COMMENT = 'CSV of valid stages for this artifact type',
    type_registry.type_is_launchable AS IS_LAUNCHABLE
      WITH SYNONYMS = ('launchable')
      COMMENT = 'Whether this type is a launchable (APP/MODEL/DASHBOARD/NARRATIVE)'
  )

  METRICS (
    artifacts.artifact_count AS COUNT(*)
      COMMENT = 'Total artifacts',
    artifacts.initiative_count AS COUNT(CASE WHEN artifacts.TYPE = 'INITIATIVE' THEN 1 END)
      COMMENT = 'Initiatives',
    artifacts.story_count AS COUNT(CASE WHEN artifacts.TYPE = 'STORY' THEN 1 END)
      COMMENT = 'Stories',
    artifacts.app_count AS COUNT(CASE WHEN artifacts.TYPE IN ('APP','MODEL','DASHBOARD') THEN 1 END)
      COMMENT = 'Apps, models, and dashboards',
    artifacts.narrative_count AS COUNT(CASE WHEN artifacts.TYPE = 'NARRATIVE' THEN 1 END)
      COMMENT = 'Narratives'
  )

  COMMENT = 'GuppiWheel — unified value creation engine'

  AI_SQL_GENERATION 'ARTIFACTS is one table with all items; TYPE_REGISTRY (joined on TYPE) holds the canonical type taxonomy. The 14 types: INITIATIVE, EPIC, RESEARCH, STORY, NARRATIVE, APP, MODEL, DASHBOARD, DEFECT, INCIDENT, AUDIT, OPS_EVENT, OUTCOME, SKILL. For "what is an <TYPE>" or type-definition questions, read TYPE_REGISTRY.PURPOSE / LIFECYCLE / STAGES (do not guess). PARENT_ID traces lineage. CONTENT is VARIANT. METADATA is VARIANT with priority, tagged_users, product, launch. TAGS is ARRAY. Use UPPER(TYPE) for filters. Standard stages: Initiate, Research, Building, Built, Narrated; OUTCOME uses ASPIRATIONAL, SELECTED, TRACKED, RESOLVED.';

GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_VIEWER;
GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_ADMIN;
