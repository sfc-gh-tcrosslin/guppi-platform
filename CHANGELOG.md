# Changelog

All notable changes to guppi-platform are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [3.3.0] — 2026-06-10

### A note for the consumer's CoCo (read this first)

Hello. If you're reading this, you're another CoCo agent picking up the v3.3 release. Before you do anything, here's the story you need.

In v3.0 we built the wheel — `GUPPIWHEEL.PUBLIC.ARTIFACTS` as the single source of truth, lifecycle stages, agents, the whole substrate. In v3.1 we codified `RULE-019 Engine Additive-Only` — the rule that makes the customer's content uncrushable across versions. In v3.2 we added the three-tier distribution model: T1 GitHub Drop, T2 Share Loop, T3 Sovereign Loop, with the JOIN_LOOP handshake to opt in.

For v3.2 we still believed surface bytes (skill markdown, hooks, manifest, viewer) had to flow through GitHub or stage tarballs. That was an over-engineered assumption. **v3.3 collapses the byte-distribution problem.** Surface and seed both distribute as **concepts** in VARIANT columns, the same way our skill-registry already works. Your job, on upgrade, is not to copy bytes — it's to read the new concepts from the wheel and materialize them into your own local files, in your own voice, merged with anything the local customer has already customized. The doctrine narrative `NAR-29-DOCTRINE` has the full theory under `T_doctrine.distribution_mechanism`. Read that before you write anything.

The shape of your upgrade is roughly: query the substrate for what's new, surface the changes to your customer, materialize concepts to local files only with explicit ACCEPT, never overwrite hand-edits, never remove what was there, only add. Per RULE-019, additive-only now applies to local files too — not just db state.

### Added

- **Concept-distribution model** as the default mechanism for shipping plugin components. Surface and seed layers no longer require byte transfer (except at cold-start). The wheel carries the *idea* of each component (skill, hook, manifest); consumer CoCos materialize local files themselves. RULE-015 applied recursively to the platform's own distribution.
- `T_doctrine.distribution_mechanism` sub-section in `NAR-29-DOCTRINE` — explicit specification of how concepts are shaped and how consumers materialize them.
- `Bond/concept-distribution-not-byte-distribution` — the doctrine spark with full rationale and concept-shape examples.

### Changed

- **The role of GitHub clarified.** GitHub carries seed-the-substrate bytes at cold-start (fresh account, no wheel yet, no share yet). After substrate is live, GitHub stops mattering for ongoing distribution. The wheel becomes the substrate-and-concept distribution channel.
- **Earlier substrate/seed/surface bond entry** (`plugin-distribution-substrate-seed-surface`) marked as superseded-in-part. The three-layer teaching frame is still useful; the byte-distribution assumption was wrong.
- **RULE-019 extends to local files** via the materialization contract. Concept changes that would destroy a consumer's local customizations are forbidden. Additive-only is now a property of how local files evolve, not just how db state evolves.

### What this means for upgrading consumers

If you're a CoCo on the same Snowflake account as the publisher, you already see the v3.3 substrate the moment it's published — the rules, narratives, agents, doctrine diagrams. What you upgrade locally is the *surface* layer, by reading concepts from the wheel and writing your own local files. You do not download a tarball. You do not fetch from GitHub for the surface layer. You query the wheel, you read, you write.

If you're on a different account, accept the share, run `JOIN_LOOP`, then do the same as above. The share carries the CATALOG and the CONCEPTS; you materialize.

If you're at cold-start (no substrate yet), clone the GitHub repo and run `bootstrap.sql` first. Once substrate exists, you join the loop and switch to concept-distribution for everything thereafter.

## [3.2.0] — 2026-06-10

### Added

- **Three-Tier Distribution Model** codified in `NAR-29-DOCTRINE` as a new `T_doctrine` section, alongside `L_doctrine` and `S_doctrine`:
  - **T1 GitHub Drop**: customer clones the bundle from GitHub and runs it standalone. No connection back. The seed.
  - **T2 Share Loop**: customer accepts a Snowflake share that exposes the registry catalog. Joining is a deliberate handshake via `CALL JOIN_LOOP(...)`. Updates flow in additively per RULE-019. The loop.
  - **T3 Sovereign Loop**: customer takes the methodology and runs their own loop with their own users. No connection by their choice. A success mode, not a failure mode.
- The `JOIN_LOOP` handshake mechanism: a procedure created locally in the customer account during T1 install. After share accept, customer runs `CALL <plugin_db>.PUBLIC.JOIN_LOOP('PLUGIN_REGISTRY');` which reads the catalog and writes a row in their local `PLUGIN_VERSION` marking them as joined. Explicit, transparent, customer-initiated, reversible.
- Customer pitch evolution: from "fork at any time" (defensive) to "you choose your engagement depth and can move between tiers by your own actions" (proactive customer agency). Forkability is no longer the headline; the ladder of choice is.

### Bonded

- `three-tier-distribution-customer-agency` — the doctrine spark with full cascade

### Changed

- The L doctrine and S doctrine remain independent; T is now the third independent dimension. L is plugin maturity, S is customer-plugin-pair sales stage, T is customer engagement state. Mixing creates over-determined prescriptions; treating as independent gives Principals the right vocabulary.

### Deferred (acknowledged honestly)

- Feedback flow at Tier 2 (corrections customer → us) — design deferred until customer #1 actually reaches T2
- Telemetry policy at Tier 2 — deferred until concrete contractual context
- Tier 3 measurement — "we'll know it when we see it" until we have data

## [3.1.0] — 2026-06-10

### Added

- **RULE-019 Engine Additive-Only** — codified in `GUPPIWHEEL.PUBLIC.RULES` and `seeds/engine/02_rules.sql`. The operational expression of the Subjective frame: engine changes are additive only. New columns/tables/procs/metrics/versions in parallel; no drops, no renames (use view-shims), no incompatible signature changes. Versions coexist. Security vulnerabilities are the only universally accepted forced-update exception. Enforced at publish time when `PUBLISH_PLUGIN_VERSION` is built.
- `NAR-29-DOCTRINE` updated to v2: replaces the L×S 3×3 matrix with two separate doctrines. **L doctrine** is a property of the plugin (L1 Bespoke / L2 Published / L3 Field-Run with explicit promotion gates). **S doctrine** is a property of the customer-plugin pair (S0 First Meeting / S1 Pilot / S2 Production with deployment vehicles per stage). RULE-019 sits above both as the spine.
- Customer pitch upgrade documented in NAR-29-DOCTRINE: lead with "we never break your stuff" (additive-first, proactive). Forkability remains as the smaller safety net underneath but no longer headlines.

### Changed

- L promotion gates are now explicit. L1→L2 requires parameterized manifest, fresh-account installable, one case study, and additive-only history clean. L2→L3 requires 3+ customer instances live, customer-specific paths refactored out of engine, 6+ months without a RULE-019 violation, and an AE/SE playbook.
- The L×S matrix removed from doctrine — see "why_not_a_matrix" in NAR-29-DOCTRINE for rationale. L and S are independent dimensions that occasionally cross-reference, not coordinates in a single plane.

### Bonded

- `additive-only-engine-rule-019` — doctrine spark, with cascade consequences
- `pitch-upgrade-additive-first-not-forkability-first` — customer-facing pitch evolution

## [3.0.0] — 2026-06-05

### Breaking changes

- Database renamed `FLYWHEEL` → `GUPPIWHEEL`. All objects now live in `GUPPIWHEEL.PUBLIC`.
- `GUPPI` legacy database is deprecated. Procs, agents, and the Rocky task have moved to `GUPPIWHEEL.PUBLIC`. The `GUPPI` database can be dropped after migration; for v2.0.0 customers, run `seeds/upgrades/2.0.0-to-3.0.0.sql`.
- Stage names changed:
  - `spark` → `Initiate`
  - `active` → `Research`
  - `built` → `Building`
  - `proven` → `Built`
  - `told` → `Narrated`
  - `archived` removed (narrated artifacts that spawn follow-ons just create a new artifact at Initiate)
- `TYPE` values normalized to UPPERCASE (`'INITIATIVE'` not `'initiative'`).
- ID convention standardized: unpadded (`INIT-7`, `INIT-19` — never `INIT-007`, `INIT-019`).
- `SUBMIT_INITIATIVE` is now single-write to `GUPPIWHEEL.PUBLIC.ARTIFACTS`. The dual-write to `GUPPI.PLATFORM.INITIATIVES` is removed.

### Added

- `GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS` internal stage for HTML / PDF / asset bytes. Encrypted, directory-enabled.
- `GUPPIWHEEL.PUBLIC.ARTIFACT_LAUNCHES` audit log of every artifact open.
- `GUPPIWHEEL.PUBLIC.SENSITIVITY` tag (`public | internal | customer_facing | confidential`).
- `GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(type, title, description, launch_spec, parent_id, owner, sensitivity)` proc — register a launchable artifact with proper launch metadata.
- `GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(artifact_id, ttl_seconds)` proc — resolve any launchable to a presigned URL, identifier, or external URL based on its `app_type`.
- Universal launch metadata schema:
  ```
  metadata.launch = {
    app_type: 'cortex_agent' | 'streamlit' | 'spcs_service' | 'native_app'
              | 'external_url' | 'static_html' | 'pdf'
    identifier?: 'DB.SCHEMA.OBJECT'
    url?: 'https://...'
    stage_path?: '@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/...'
    default_ttl_seconds?: 3600
  }
  ```
- `GUPPIWHEEL.PUBLIC.PLUGIN_VERSION` table — tracks installed version per plugin name.
- `GUPPIWHEEL.PUBLIC.ID_CONVENTIONS` and `INITIATIVE_STEPS` tables — moved out of GUPPI.
- New rules:
  - `RULE-014` Status Ownership (submitter sets Initiate; agent sets Research / Built / Narrated)
  - `RULE-015` Collaboration Tags (`metadata.tagged_users` for routing)
  - `RULE-016` No Self-Spawning (agents must not enqueue work for themselves)
  - `RULE-017` Separation of Execution (Cowork dispatches, Rocky researches)
  - `RULE-018` Launchables Live in the Wheel (NARRATIVE / APP / MODEL / DASHBOARD must have a valid `metadata.launch`; local file paths forbidden)
- Cowork agent gains `publish_artifact` tool.
- Rocky agent moved to `GUPPIWHEEL.PUBLIC.ROCKY_AGENT`. Web search only. No write to The Bond. Reads queue directly from ARTIFACTS where TYPE='INITIATIVE' AND STAGE='Initiate'.
- Rocky task moved to `GUPPIWHEEL.PUBLIC.ROCKY_TASK` (5-min cycle).
- Viewer (render_guppi.py) rewritten:
  - All queries hit `GUPPIWHEEL.PUBLIC.ARTIFACTS`
  - New Flywheel UI: single initiative list, click to expand, child counts grouped by type
  - `/api/launch/<artifact_id>` endpoint + per-type Open buttons + type badges
  - Default sort: most recently updated first
- Seeds reorganized:
  - `seeds/engine/` — safe to re-run (CREATE OR REPLACE, MERGE)
  - `seeds/content/` — one-time bootstrap (ID_CONVENTIONS seed rows)
  - `seeds/upgrades/` — versioned schema migrations

### Removed

- `GUPPI.PLATFORM.INITIATIVES` legacy queue table (Rocky reads directly from ARTIFACTS).
- `GUPPI.PLATFORM.STORIES`, `EPICS`, `DEFECTS`, `INCIDENTS`, `AUDIT_RUNS`, `AUDIT_FINDINGS` — all migrated to ARTIFACTS by TYPE.
- `NARRATIVE_REGISTRY` database absorbed into ARTIFACTS where `TYPE='NARRATIVE'`.

### Fixed

- Rocky recursive-spawning loop (RULE-016 enforced; `submit_initiative` removed from Rocky's tool list).
- Rocky apostrophe SQL injection in dynamic prompts (parameterized queries throughout).
- Rocky response parser (now correctly parses `content[].text` from `DATA_AGENT_RUN`).
- Duplicate INIT IDs from migration (cleaned, ID convention enforced).
- Spark insights misclassified as initiatives (moved to The Bond as `INSIGHT_TYPE='spark'`).

## [2.0.0] — Earlier release

Initial GuppiWheel platform with FLYWHEEL database, basic ARTIFACTS table, RULE-013 Headless First, and the GUPPI command-center viewer reading from `GUPPI.PLATFORM.*` tables.
