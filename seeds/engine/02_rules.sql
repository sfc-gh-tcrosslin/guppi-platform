-- =============================================================================
-- guppi-platform v3.14.1 — Engine Seed 02: Rules
-- TIER 0 (INVARIANT): doctrine is data. Enabled RULES rows are authoritative; agents
--   read them, never paraphrase. You may ADD rows (that extends doctrine); do not gut
--   the core governance rules. See COCO.md, Tier 0 #5.
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
    -- DOCTRINE PRINCIPLES (added v3.5.0 — synced from live; audit-model-independent)
    -- ==========================================================================
    ('RULE-020', 'GUIDING_PRINCIPLE', 'INITIATIVE', NULL, NULL, '-- Enforced at SUBMIT_INITIATIVE time: warn (not block) when a new initiative title contains v2/refresh/refresh of/with X added/follow-up to INIT-N or otherwise references an existing initiative as its anchor. The submitter must either confirm it is genuinely a new goal or downgrade the work into RESEARCH/STORY children under the existing initiative.', 'warn', TRUE, 'Initiative-vs-Research Lineage: An initiative is one DISTINCT GOAL. Refinement passes, context updates, v2 pitches, and "with X added" iterations are RESEARCH children under the existing initiative — not sibling initiatives. Smell test: if the proposed title contains "v2", "refresh", "follow-up to INIT-N", "with X added", or otherwise references an existing initiative as its anchor, it is almost always a research artifact, not an initiative. The wheel doctrine: initiatives = goals; research = work toward a goal; stories = builds against research; defects = bugs against builds. Keeping these clean preserves lineage, prevents initiative-table sprawl, and makes the truth legible: one goal, many passes. Universally accepted exception: a refinement pass that genuinely changes the GOAL (different customer, different program, different problem statement) is a new initiative.'),
    ('RULE-021', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, '-- Enforced at share creation: SHARE_MANIFEST declares framework_included=true (default) and exemplar_refs (explicit curated list of INIT IDs). Customer-content artifacts are excluded unless their INIT is in exemplar_refs. Plugin bytes are NEVER in the share; only PLUGIN_REFERENCE rows with name/version/URL. Consumer side: incoming share lands in a distinct database from local wheel (default VERT.PUBLIC.*). Local artifacts are never modified by share contents.', 'warn', FALSE, 'Wheel Share Composition: Outbound shares contain FRAMEWORK by default (rules, plugin contract, skill registry, doctrine narratives) and EXEMPLAR REFERENCES by explicit curation (INITs + artifact subtrees + plugin pointers). The share carries CONCEPTS not bytes. Plugin bytes live in their canonical T1 channel (GitHub); the share references them by name, version, and URL. Consumers land the share in a distinct database (default VERT.PUBLIC.*) separate from their local wheel. Local content is operational truth; shared exemplars are reference; never auto-merge. Customer-private content is never shared; exemplars are curated and anonymized at curation time. Smell test: if the share contains a row the producer did not explicitly mark for inclusion, the share is wrong. Exception: framework rows propagate by default; they are the engine, not content.'),
    ('RULE-023', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     '-- Enforced by Bob bake-off + cross-judge panel; no wheel-SQL gate',
     'warn', FALSE,
     'Foundation-Model Agnosticism: no single model is privileged. Authoring models are interchangeable rows in MODEL_CATALOG; Bob authors a deliverable across all enabled models and selects by EVIDENCE — a cross-judge panel in which every candidate is scored by every OTHER enabled model (a model never judges its own work) and the highest average trust wins. Model choice is therefore an auditable decision (in-wheel AUDIT artifacts via TARS_AUDITS_V), not a default. Adding or removing a model is a MODEL_CATALOG row, never a code change. Smell test: if a build hardcodes one model name as the sole author or the judge, it violates this rule.'),

    ('RULE-024', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, '-- Enforcement via repo-level grep/precommit, not wheel SQL', 'warn', FALSE, 'Secrets Hygiene: Credentials (passwords, tokens, keys, connection strings) come from env vars with STRICT access — os.environ[''KEY''], NOT os.environ.get(''KEY'', ''<literal>''). Lenient fallbacks are banned: they hide literals in source. Connection strings embedding credentials (postgres://user:pass@host, sk-..., ghp_...) are equally banned; template with a placeholder (e.g. __SET_PASSWORD_BEFORE_DEPLOY__) that fails loudly at deploy. Files holding local secrets (deploy specs, .env) must be .gitignored AND hold only the placeholder at rest. Smell test: repo-wide grep for credential patterns returns ZERO hits in tracked files. Audit must include connection-string formats. Multi-consumer secrets: route via single helper or Snowflake SECRET (no copy-paste). Reason: a prior release leaked a literal credential across 9 files via lenient fallback; required filter-repo + force-push.'),
    ('RULE-025', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, 'SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE SUPERSEDED_BY IS NOT NULL  -- supersession is in use when > 0', 'warn', FALSE, 'Serving Surfaces Show Current Truth Only: consumer-facing grounding (Cortex Search, semantic views, the cowork agent, dashboards) indexes ONLY non-superseded artifacts (SUPERSEDED_BY IS NULL). On doctrine/rule/narrative change: INSERT new version, set old row''s SUPERSEDED_BY to the new ID — never delete. History stays queryable in the substrate; the pointer chain IS the audit trail (e.g. spark->Initiate). One answer to the world; full journey to anyone querying the substrate. COMPLEMENTS RULE-019 (immutable additive history), not a reversal. Scope: doctrine/rule/narrative artifacts where staleness causes wrong answers; most artifacts are historical facts, never superseded.'),
    ('RULE-026', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, '-- Checklist rule; enforced by author discipline + post-change smell test, not SQL', 'warn', FALSE, 'Doctrine Change Grounding Sweep: when any doctrine, rule, stage name, type name, or canonical narrative changes, the change is NOT complete until all grounding surfaces are swept. The substrate (ARTIFACTS/RULES rows) is only ONE surface. The 6 surfaces: (1) RULES.FROM_STAGE/TO_STAGE/MESSAGE; (2) semantic view dimension COMMENTS + AI_SQL_GENERATION text (Cortex Analyst grounding); (3) Cortex Search corpora (ARTIFACTS_SEARCH_V + Bond MEMORY_DOCUMENTS); (4) agent system prompt / instructions; (5) GitHub mirror (README, CHANGELOG, plugin docs) — cold-start grounding for new installs; (6) agent memory files (/memories). Smell test to confirm done: ask the LIVE agent the changed question, verify it answers with current truth. Root incident: 2026-06-12 stage migration updated the substrate but missed semantic view comments — "spark still lives" surfaced to users weeks later. Pairs with RULE-025 (serving shows current truth only).'),
    ('RULE-028', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, '-- Enforced by RBAC: no role below ADMIN has INSERT/UPDATE on ARTIFACTS or RULES; verified via SHOW GRANTS', 'block', FALSE, 'GuppiWheel Writes Are Procedure-Mediated; Doctrine Is Admin-Only. No role below GUPPIWHEEL_ADMIN holds direct INSERT/UPDATE on ARTIFACTS or RULES. Contributors write ONLY through procedures (CREATE_ARTIFACT, SUBMIT_INITIATIVE, PUBLISH_ARTIFACT, ADVANCE_STAGE, UPDATE_OWN_ARTIFACT), all EXECUTE AS OWNER; the submit/publish family delegates its INSERT to the single CREATE_ARTIFACT chokepoint (RULE-029). Consequences enforced structurally: STAGE changes only via ADVANCE_STAGE (STG rules cannot be bypassed); SUPERSEDED_BY untouchable by contributors (protects RULE-025 serving lens); self-edit only via UPDATE_OWN_ARTIFACT (OWNER=CURRENT_USER, refuses STAGE/SUPERSEDED_BY/TYPE). Doctrine (RULES) changes are an ADMIN/orchestrator act — the human mirror of STO-36-O. CRITICAL mechanic: write procs MUST be EXECUTE AS OWNER or they break when caller DML is revoked. The born-locked seed ships this by default; the guppiwheel-governance skill audits and remediates existing installs (suggest + per-step admin approval). Reference: STO-RBAC-LOCKDOWN, RULE-024/025/026, plugin v3.4.0.'),
    ('RULE-027', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL, 'TRUE', 'block', FALSE, 'Doctrine-Change Authority Is Orchestrator-Only. Sub-agents (Stewart, Rocky, etc.) operate WITHIN current doctrine: they READ everything and PROPOSE via artifacts, but never write RULES, never set SUPERSEDED_BY, and never alter serving surfaces. Only the orchestrator/admin applies doctrine/rule changes. Enforced by RBAC (no sub-agent role holds RULES DML) + toolset construction (a sub-agent''s procs only read and create proposal artifacts; none can write doctrine). The owner/orchestrator itself is bound by DISCIPLINE + the DUPLICATE_ID_SCREAM_V and GROUNDING_HEALTH_V tripwires, because RBAC cannot bind the table owner — Stewart monitors orchestrator/owner writes for exactly this reason. Realizes STO-36-O.'),

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
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.TARS_AUDITS_V ar JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.target_name = a.TITLE WHERE a.ID = :artifact_id AND ar.trust_score >= 0.85)',
     'block', TRUE,
     'App cannot advance to Built without a TARS audit scoring >= 0.85'),

    ('STG-004', 'stage_transition', 'ALL', NULL, 'Narrated',
     'EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.TARS_AUDITS_V ar JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.target_name = a.TITLE WHERE a.ID = :artifact_id AND ar.human_vote IS NOT NULL)',
     'block', TRUE,
     'Nothing advances to Narrated without a human affirmation vote on its TARS audit'),

    ('STG-005', 'stage_transition', 'OUTCOME', 'TRACKED', 'RESOLVED', '-- Enforcement deferred until INIT-37 OUTCOME type is Built; warn-level for now', 'warn', TRUE, 'OUTCOME artifacts use a distinct 4-stage lifecycle: ASPIRATIONAL (target stated before work) -> SELECTED (decision-maker commits) -> TRACKED (pointer wired to live data: snowflake_path / app_metric / external_url) -> RESOLVED (measured against the world). An OUTCOME should not reach RESOLVED without its pointer resolving to real data or an explicit human sign-off. This is the standalone lifecycle introduced in INIT-37; the standard artifact stages (Initiate->Research->Building->Built->Narrated) do NOT apply to OUTCOME.'),

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

    ('QAL-002', 'quality', 'ALL', NULL, NULL,
     'NOT EXISTS (SELECT 1 FROM GUPPIWHEEL.PUBLIC.TARS_FINDINGS_V af JOIN GUPPIWHEEL.PUBLIC.TARS_AUDITS_V ar ON af.audit_id = ar.audit_id JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a ON ar.target_name = a.TITLE WHERE a.ID = :artifact_id AND af.signal = ''D'' AND af.disposition IS NULL)',
     'block', FALSE,
     'Unresolved TARS D-signal (defection) blocks stage advancement until dispositioned'),

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
     'Initiative at Initiate >7 days without research started — going cold'),

    ('RULE-029', 'platform', 'ALL', NULL, NULL,
     'TRUE', 'block', FALSE,
     'Artifact IDs are globally unique. CREATE_ARTIFACT is the SINGLE write chokepoint: the only procedure that INSERTs into ARTIFACTS, allocating gap-free IDs atomically from ID_CONVENTIONS (or accepting a de-duped explicit ID) and refusing existing IDs. Every other write proc — SUBMIT_INITIATIVE, PUBLISH_ARTIFACT, ROCKY_EXECUTE, STEWART_AUDIT, PROPOSE_CORRECTION, BOB_EXECUTE — validates/shapes its payload then DELEGATES the INSERT by CALLing CREATE_ARTIFACT (no direct INSERT of their own). CREATE_ARTIFACT exposes an all-scalar surface (P_CONTENT/P_TAGS/P_METADATA are JSON strings) so Cortex agent generic tools over a warehouse can call it directly. Direct INSERT on ARTIFACTS is revoked from all roles except the table owner. Enforced by single write path + DUPLICATE_ID_SCREAM_V tripwire (Snowflake does not enforce PK/UNIQUE).'),

    ('RULE-030', 'GUIDING_PRINCIPLE', 'ALL', NULL, NULL,
     'TRUE', 'warn', FALSE,
     'Isolation-Then-Reconcile on Hard Research (credit: Snowflake ArcticSwarm). For high-stakes or flagged research (metadata.swarm=true OR priority=high), Rocky decomposes the question into PROFILED, ISOLATED sub-agents — a broad retriever, a counterexample-seeker (disconfirmation lives HERE, once), and a consistency-checker — each a separate DATA_AGENT_RUN with no shared context (write-only to GUPPIWHEEL.PUBLIC.ROCKY_EVIDENCE). A reconciler, which MUST be a different model than the sub-agents (per RULE-023 no-self-judging), synthesizes and PRESERVES conflicts rather than averaging them; the RESEARCH artifact stores {synthesis, conflicts, roles}. Downstream authoring (Bob) reads the conflicts, not just the flattened verdict; disconfirmation is NOT repeated at Bob. Default research stays single-pass; swarm is opt-in and A/B-validated (ROCKY_AB) before any widening. Pattern credited to Snowflake''s ArcticSwarm: isolation during discovery + broadcast-for-review / managed disagreement.')

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
