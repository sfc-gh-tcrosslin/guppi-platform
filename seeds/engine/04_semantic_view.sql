-- =============================================================================
-- guppi-platform v3.0.0 — Engine Seed 04: Semantic View
-- For Cortex Analyst natural-language querying via the Cowork agent.
-- CREATE OR REPLACE. Safe to re-run.
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV

  TABLES (
    artifacts AS GUPPIWHEEL.PUBLIC.ARTIFACTS
      PRIMARY KEY (ID)
      COMMENT = 'All GuppiWheel artifacts'
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
      COMMENT = 'INITIATIVE, RESEARCH, STORY, EPIC, APP, MODEL, NARRATIVE, DASHBOARD, DEFECT, INCIDENT, AUDIT',
    artifacts.stage AS STAGE
      WITH SYNONYMS = ('status', 'lifecycle stage')
      COMMENT = 'Initiate, Research, Building, Built, Narrated',
    artifacts.owner AS OWNER
      WITH SYNONYMS = ('created by', 'author')
      COMMENT = 'Who owns this artifact',
    artifacts.parent_id AS PARENT_ID
      COMMENT = 'Parent artifact for lineage',
    artifacts.title AS TITLE
      WITH SYNONYMS = ('name', 'subject')
      COMMENT = 'Human-readable title'
  )

  METRICS (
    artifacts.artifact_count AS COUNT(*)
      COMMENT = 'Total artifacts',
    artifacts.initiative_count AS COUNT(CASE WHEN TYPE = 'INITIATIVE' THEN 1 END)
      COMMENT = 'Initiatives',
    artifacts.story_count AS COUNT(CASE WHEN TYPE = 'STORY' THEN 1 END)
      COMMENT = 'Stories',
    artifacts.app_count AS COUNT(CASE WHEN TYPE IN ('APP','MODEL','DASHBOARD') THEN 1 END)
      COMMENT = 'Apps, models, and dashboards',
    artifacts.narrative_count AS COUNT(CASE WHEN TYPE = 'NARRATIVE' THEN 1 END)
      COMMENT = 'Narratives'
  )

  COMMENT = 'GuppiWheel — unified value creation engine'

  AI_SQL_GENERATION 'ARTIFACTS is one table with all items. Filter TYPE for kinds (INITIATIVE, RESEARCH, STORY, EPIC, APP, MODEL, NARRATIVE, DASHBOARD, DEFECT, INCIDENT, AUDIT). PARENT_ID traces lineage. CONTENT is VARIANT. METADATA is VARIANT with priority, tagged_users, product, launch. TAGS is ARRAY. Use UPPER(TYPE) for filters. Stages: Initiate, Research, Building, Built, Narrated.';

GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_VIEWER;
GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT REFERENCES, SELECT ON SEMANTIC VIEW GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV TO ROLE GUPPIWHEEL_ADMIN;
