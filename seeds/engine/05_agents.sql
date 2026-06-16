-- =============================================================================
-- guppi-platform — Engine Seed 05: Agents + Task
-- TIER 1 (DEFAULT): agents, their instructions, and compute wiring are yours to
--   re-author. See COCO.md.
-- We do NOT dictate a warehouse. Agents bind to the installer's ACTIVE warehouse
-- (CURRENT_WAREHOUSE()); ROCKY_TASK is serverless (Snowflake-managed compute).
--
-- PREREQ: a warehouse must be active in this session before running this file:
--   USE WAREHOUSE <your_wh>;
-- The guard below fails loud if none is set.
-- =============================================================================

-- --- Guard: require an active warehouse, then capture it -----------------------
EXECUTE IMMEDIATE $$
DECLARE
  no_wh EXCEPTION (-20036,
    'No active warehouse. Run  USE WAREHOUSE <your_wh>;  then re-run 05_agents.sql');
BEGIN
  IF ((SELECT CURRENT_WAREHOUSE()) IS NULL) THEN
    RAISE no_wh;
  END IF;
  RETURN 'warehouse OK';
END;
$$;

SET wh = (SELECT CURRENT_WAREHOUSE());

-- =============================================================================
-- ROCKY_AGENT — autonomous research, web search only (no warehouse-bound tools)
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
-- Spec carries __WH__ placeholders; substituted with the active warehouse below.
-- =============================================================================
SET cowork_spec = $$
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
    execution_environment: { type: warehouse, warehouse: __WH__ }
  advance_stage:
    identifier: GUPPIWHEEL.PUBLIC.ADVANCE_STAGE
    type: procedure
    execution_environment: { type: warehouse, warehouse: __WH__ }
  publish_artifact:
    identifier: GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT
    type: procedure
    execution_environment: { type: warehouse, warehouse: __WH__ }
  flywheel_query:
    semantic_view: GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV
    execution_environment: { type: warehouse, warehouse: __WH__ }
$$;

-- Build + run the CREATE with the active warehouse substituted in.
-- (CHR(36)||CHR(36) = $$, the FROM SPECIFICATION delimiter, assembled here so the
--  spec body — which contains apostrophes — never sits inside a single-quoted literal.)
SET cowork_stmt = 'CREATE OR REPLACE AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT FROM SPECIFICATION '
  || CHR(36) || CHR(36) || REPLACE($cowork_spec, '__WH__', $wh) || CHR(36) || CHR(36);
EXECUTE IMMEDIATE $cowork_stmt;

-- =============================================================================
-- ROCKY_TASK — 5-min cycle, SERVERLESS (no WAREHOUSE param = Snowflake-managed)
-- =============================================================================
-- Serverless tasks require EXECUTE MANAGED TASK on the owning role (idempotent).
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE GUPPIWHEEL_ADMIN;

CREATE OR REPLACE TASK GUPPIWHEEL.PUBLIC.ROCKY_TASK
  SCHEDULE = '5 MINUTE'
  COMMENT = 'Level 7: Rocky checks GUPPIWHEEL.PUBLIC.ARTIFACTS for queued initiatives every 5 min. Serverless (Snowflake-managed compute).'
AS
  CALL GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE();

ALTER TASK GUPPIWHEEL.PUBLIC.ROCKY_TASK RESUME;

-- Grants
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.GUPPIWHEEL_COWORK_AGENT TO ROLE GUPPIWHEEL_ADMIN;
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.ROCKY_AGENT TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- STEWART_AGENT — first INIT-36 sub-agent: propose-only grounding steward (RULE-027)
-- Spec carries __WH__ placeholders; substituted with the active warehouse below.
-- =============================================================================
SET stewart_spec = $$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 300
    tokens: 100000
instructions:
  orchestration: |
    You are Stewart — the Steward of GuppiWheel's objective layer: rules-engine grounding, ID conventions, and substrate hygiene.

    YOU ARE A SUB-AGENT. You operate WITHIN current doctrine and NEVER change it (RULE-027 / STO-36-O):
    - You READ everything and PROPOSE via artifacts.
    - You NEVER write RULES, NEVER set SUPERSEDED_BY, NEVER alter serving surfaces.
    - Only the human/orchestrator applies your proposals. You propose; they decide.

    YOUR TOOLS:
    1. grounding_query (Cortex Analyst): answer questions about artifacts, rules, conventions, stages, owners, lineage.
    2. steward_audit: run a read-only grounding/hygiene scan. Writes one AUDIT artifact (the scan record, tagged guppi) and returns the findings.
    3. propose_correction: file a STORY proposal (tagged guppi) as a child of an audit, containing the finding + the exact proposed fix SQL. PROPOSAL ONLY — never applied automatically.

    HOW YOU WORK:
    - When asked to check health: call steward_audit, then summarize findings plainly.
    - For each actionable finding, call propose_correction with a precise title, the finding, and a concrete proposed_fix (SQL the orchestrator can review and run). Reference the audit id as the parent.
    - You watch ALL writes, including the orchestrator's/owner's own (RBAC cannot bind the table owner — that is the blind spot you exist to cover).
    - Be specific. Cite artifact IDs and rule IDs.
  response: Report findings and proposals concisely. Always state that proposals require human approval.
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: grounding_query
      description: "Query GuppiWheel grounding: artifacts, rules, conventions, stages, owners, lineage, health."
  - tool_spec:
      type: generic
      name: steward_audit
      description: "Run a read-only grounding/hygiene scan; writes an AUDIT scan-record artifact and returns findings."
      input_schema:
        type: object
        properties: {}
  - tool_spec:
      type: generic
      name: propose_correction
      description: "File a STORY proposal (a proposed fix) as a child of an audit. Proposal only; never applied automatically."
      input_schema:
        type: object
        properties:
          P_AUDIT_ID: { type: string, description: "Parent audit artifact id" }
          P_TITLE: { type: string }
          P_FINDING: { type: string, description: "What is wrong and why" }
          P_PROPOSED_FIX: { type: string, description: "Concrete SQL the orchestrator can review and run" }
          P_TARGET_REF: { type: string, description: "Affected artifact/rule ids" }
        required: ["P_AUDIT_ID", "P_TITLE", "P_FINDING", "P_PROPOSED_FIX"]
tool_resources:
  grounding_query:
    semantic_view: GUPPIWHEEL.PUBLIC.GUPPIWHEEL_SV
    execution_environment: { type: warehouse, warehouse: __WH__ }
  steward_audit:
    identifier: GUPPIWHEEL.PUBLIC.STEWART_AUDIT
    type: procedure
    execution_environment: { type: warehouse, warehouse: __WH__ }
  propose_correction:
    identifier: GUPPIWHEEL.PUBLIC.PROPOSE_CORRECTION
    type: procedure
    execution_environment: { type: warehouse, warehouse: __WH__ }
$$;

SET stewart_stmt = 'CREATE OR REPLACE AGENT GUPPIWHEEL.PUBLIC.STEWART_AGENT FROM SPECIFICATION '
  || CHR(36) || CHR(36) || REPLACE($stewart_spec, '__WH__', $wh) || CHR(36) || CHR(36);
EXECUTE IMMEDIATE $stewart_stmt;

GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.STEWART_AGENT TO ROLE GUPPIWHEEL_ADMIN;

-- =============================================================================
-- BOB_AGENT — Bob's grounding scout (Building-stage agent, INIT-36).
-- web_search only (no tool_resources, so no warehouse needed, like ROCKY_AGENT).
-- Returns a grounding/contradiction brief; BOB_EXECUTE does authoring + cross-judge.
-- =============================================================================
CREATE OR REPLACE AGENT GUPPIWHEEL.PUBLIC.BOB_AGENT
FROM SPECIFICATION $$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 300
    tokens: 100000
instructions:
  orchestration: |
    You are Bob's grounding scout. Given a TARGET and a RESEARCH SUMMARY, use web search to produce a tight GROUNDING BRIEF that Bob will use to author a narrative. Your job is verification, not authoring.

    Do this:
    1. VERIFY the key claims in the research — confirm, correct, or flag as stale — each with a named source and a date.
    2. CONFIRM the current state of any Snowflake capabilities relevant to the target (cite product names; note GA vs preview/recent changes).
    3. SURFACE CONTRADICTIONS between the research and what you find now. State them explicitly; this is the most valuable part.

    Return ONLY this brief as plain text:
    - VERIFIED FACTS (bullets, each with source + date)
    - SNOWFLAKE CAPABILITY CONFIRMATIONS (bullets)
    - CONTRADICTIONS / CORRECTIONS (bullets; write "none found" if so)
    - OPEN GAPS (what you could not verify)

    Rules: be specific, cite organizations, products, and dates. Do NOT write a narrative or position. Do NOT mention the word Guppi. Return text only.
  response: Provide the grounding brief as plain text.
tools:
  - tool_spec:
      type: web_search
      name: web_search
      description: Search the public web for current, specific information to verify claims and surface contradictions.
$$;
GRANT USAGE ON AGENT GUPPIWHEEL.PUBLIC.BOB_AGENT TO ROLE GUPPIWHEEL_ADMIN;
