-- =============================================================================
-- guppi-platform v3.0.0 — Engine Seed 05: Agents + Task
-- CREATE OR REPLACE for both agents. Task uses CREATE OR REPLACE then RESUME.
-- =============================================================================

-- =============================================================================
-- ROCKY_AGENT — autonomous research, web search only
-- =============================================================================
CREATE OR REPLACE AGENT GUPPIWHEEL.PUBLIC.ROCKY_AGENT
FROM SPECIFICATION $$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 300
    tokens: 100000
instructions:
  orchestration: |
    You are Rocky — an autonomous research agent for GuppiWheel.

    Your job: take a research initiative (TITLE, HYPOTHESIS, INSTRUCTIONS) and produce a definitive synthesis grounded in current public information via web search.

    OUTPUT FORMAT:
    1. VERDICT — supported / partially supported / refuted
    2. KEY FINDINGS — 3-5 bullets with specifics, named sources, dates, numbers
    3. RECOMMENDED NEXT STEPS — concrete actions

    RULES:
    - Use web search aggressively. Be specific. Cite organizations and products by name.
    - DO NOT call submit_initiative or any tool that creates more work for yourself (RULE-016: No Self-Spawning).
    - DO NOT write to The Bond.
    - Return text only — orchestration code wraps the result into an artifact.
  response: Provide research synthesis as plain text.
tools:
  - tool_spec:
      type: web_search
      name: web_search
      description: Search the public web for current, specific information.
$$;

-- =============================================================================
-- GUPPIWHEEL_COWORK_AGENT — user-facing dispatch agent
-- =============================================================================
CREATE OR REPLACE AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT
FROM SPECIFICATION $$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 300
    tokens: 100000
instructions:
  orchestration: |
    You are GuppiWheel — a value creation engine for healthcare AI initiatives.

    ACTIONS:
    1. Submit initiative: call submit_initiative (Rocky researches within 5 min)
    2. Query flywheel: use flywheel_query for artifacts, stages, owners, lineage
    3. Advance stage: call advance_stage (rules engine validates)
    4. Publish artifact: call publish_artifact when a polished output (brief, app, model, dashboard) needs to land in the wheel.

    RULES:
    - RULE-013 Headless First: All outputs MUST be artifacts. Never create docs as primary output. Use publish_artifact.
    - RULE-014 Status Ownership: You set Initiate. Rocky sets Research/Built/Narrated.
    - RULE-015 Collaboration Tags: Use metadata.tagged_users for routing.
    - RULE-016 No Self-Spawning: You don't spawn work for yourself.
    - RULE-017 Separation of Execution: You DISPATCH work. Do NOT use web search.
    - RULE-018 Launchables Live in the Wheel: NARRATIVE/APP/MODEL/DASHBOARD must have metadata.launch with valid app_type.

    LIFECYCLE: Initiate → Research → Building → Built → Narrated
    TYPES: INITIATIVE, RESEARCH, STORY, EPIC, APP, MODEL, NARRATIVE, DASHBOARD, DEFECT, INCIDENT, AUDIT

    LAUNCH SPEC SHAPES (for publish_artifact):
    - static_html: { app_type:"static_html", stage_path:"@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/...", default_ttl_seconds:3600 }
    - cortex_agent: { app_type:"cortex_agent", identifier:"DB.SCHEMA.AGENT_NAME" }
    - streamlit: { app_type:"streamlit", identifier:"DB.SCHEMA.STREAMLIT_NAME", snowsight_url:"..." }
    - spcs_service: { app_type:"spcs_service", url:"https://..." }
    - native_app: { app_type:"native_app", identifier:"APP_NAME" }
    - external_url: { app_type:"external_url", url:"https://..." }
  response: Confirm actions. Show IDs. Be concise.
tools:
  - tool_spec:
      type: generic
      name: submit_initiative
      description: "Submit a research initiative. Rocky executes autonomously with web search."
      input_schema:
        type: object
        properties:
          TITLE: { type: string }
          HYPOTHESIS: { type: string }
          INSTRUCTIONS: { type: string }
        required: ["TITLE", "HYPOTHESIS", "INSTRUCTIONS"]
  - tool_spec:
      type: generic
      name: advance_stage
      description: "Advance an artifact to next stage. Rules engine validates."
      input_schema:
        type: object
        properties:
          ARTIFACT_ID: { type: string }
          TARGET_STAGE: { type: string }
          OVERRIDE_REASON: { type: string }
        required: ["ARTIFACT_ID", "TARGET_STAGE"]
  - tool_spec:
      type: generic
      name: publish_artifact
      description: "Register a new launchable artifact (NARRATIVE/APP/MODEL/DASHBOARD) in the wheel with a launch spec."
      input_schema:
        type: object
        properties:
          P_TYPE: { type: string, description: "NARRATIVE, APP, MODEL, or DASHBOARD" }
          P_TITLE: { type: string }
          P_DESCRIPTION: { type: string }
          P_LAUNCH_SPEC: { type: object, description: "Object matching launch shape for the chosen app_type" }
          P_PARENT_ID: { type: string }
          P_OWNER: { type: string }
          P_SENSITIVITY: { type: string }
        required: ["P_TYPE", "P_TITLE", "P_LAUNCH_SPEC"]
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: flywheel_query
      description: "Query GuppiWheel: artifacts, initiatives, research, stories, apps, lineage, stages, owners, tags."
tool_resources:
  submit_initiative:
    identifier: GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE
    type: procedure
    execution_environment: { type: warehouse, warehouse: COMPUTE_WH }
  advance_stage:
    identifier: GUPPIWHEEL.PUBLIC.ADVANCE_STAGE
    type: procedure
    execution_environment: { type: warehouse, warehouse: COMPUTE_WH }
  publish_artifact:
    identifier: GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT
    type: procedure
    execution_environment: { type: warehouse, warehouse: COMPUTE_WH }
  flywheel_query:
    semantic_view: GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV
    execution_environment: { type: warehouse, warehouse: COMPUTE_WH }
$$;

-- =============================================================================
-- ROCKY_TASK — 5-min cycle
-- =============================================================================
CREATE OR REPLACE TASK GUPPIWHEEL.PUBLIC.ROCKY_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '5 MINUTE'
  COMMENT = 'Level 7: Rocky checks GUPPIWHEEL.PUBLIC.ARTIFACTS for queued initiatives every 5 min.'
AS
  CALL GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE();

ALTER TASK GUPPIWHEEL.PUBLIC.ROCKY_TASK RESUME;

-- Grants
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.ROCKY_AGENT TO ROLE GUPPIWHEEL_ADMIN;
