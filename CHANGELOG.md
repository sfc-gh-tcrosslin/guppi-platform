# Changelog

All notable changes to guppi-platform are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [3.14.1] — 2026-07-12

### Fix — governed, regression-proof plugin version stamp (resolves 3-way version drift)

The plugin version was tracked in three places that had silently drifted: `plugin.json` (source, 3.14.0), the `01_schema.sql` stamp literal (3.8.1 — *staler than live*, so re-seeding would have **regressed** an install), and the live `PLUGIN_VERSION` table (3.10.1). This makes the version single-source and self-healing.

- **New `PUBLISH_PLUGIN_VERSION` proc (`03_procs.sql`).** The governed, `EXECUTE AS OWNER` stamp path the `02_rules.sql` rule already described. Validates semver and enforces a **monotonicity guard** — refuses a lower version unless `P_FORCE => TRUE` — which is exactly what prevents a stale seed literal from regressing a live install. Direct DML on `PLUGIN_VERSION` stays revoked; this proc is the only writer. `v1` scope is semver + monotonicity; the full manifest-compatibility gate (dropped columns/procs, type narrowings) the rule describes remains a documented future extension.
- **Stamp moved out of `01_schema.sql`.** The raw literal `MERGE` (which held the stale 3.8.1) is removed; the single go-forward stamp is now `CALL PUBLISH_PLUGIN_VERSION('3.14.1', 'seed apply', FALSE)` at the tail of `03_procs.sql` (after the proc is defined). Re-running the engine seed now self-heals the live version instead of regressing it.
- **SDLC preflight three-way guard (`skills/sdlc-preflight/SKILL.md`, Check 13.1).** Asserts `plugin.json` version == the `03_procs.sql` stamp literal == live `PLUGIN_VERSION`. `plugin.json` is the single source of truth; the seed literal is a checked mirror; drift fails preflight before a push.
- Dogfooded the new proc on a real 3.10.1 → 3.14.1 transition.

## [3.14.0] — 2026-07-12

### Feature — Guppi Slack Representative recipe (a *suggestion*, not substrate) + birth-hash attestation model (INIT-77, INIT-75)

Two bodies of work. First, the bi-directional Slack representative — built and proven live on the reference account — is packaged as an **adoptable recipe skill**, deliberately in the capability tier rather than the engine seed. Second, `VERIFY_CHAIN` (INIT-75 Thread A) is upgraded to the attestation model we settled on when governed edits collided with the birth-hash.

- **New skill `guppi-slack-rep` (INIT-77).** A read-only, grounded Cortex Agent that answers Slack @mentions in real time on the owner's behalf, via an SPCS Socket Mode listener. Packaged as a *suggestion* — "one Guppi to another, you could do this" — because most installs won't want it (not every team is on Slack; it needs tokens + SPCS budget). Fully parameterized with `{{TOKENS}}`: `SKILL.md` (when-to-suggest, guardrails, deploy runbook, the SPCS→Agent `Bearer`+`OAUTH` auth gotcha) + `assets/` (Socket Mode `app.py`, Dockerfile, requirements, parameterized rep-agent spec, and groundwork/secrets/service SQL reconstructed from the live deployment). **Explicitly NOT seeded** — no rep agent in `05_agents.sql`.
- **Reusability contract baked in.** The agent OBJECT name is generic (`GUPPI_REP_AGENT`); the owner attribution ("on behalf of <owner>") lives only in the persona config. This recipe exists partly to codify *don't name a shared object after a person*.
- **`VERIFY_CHAIN` v3 (`seeds/engine/03_procs.sql`, INIT-75).** Structural checks (genesis / linkage / fork / reachability — delete/reorder/insert detection) remain the hard pass/fail tamper-evidence gate. Content differences on LIVE rows are now **informational** (`modified_since_birth`), not an auto-fail, because governed in-place edits (`MERGE_ARTIFACTS` re-parent + breadcrumb, `UPDATE_OWN_ARTIFACT`) legitimately change hashed bundle fields; superseded rows skip the content recompute. Syncs the seed to the deployed proc.

## [3.13.0] — 2026-07-03

### Feature — Prior-art search on new initiatives + Guppi viewer rewrite (SDLC + AILC)

Two bodies of work. First, new initiatives now search the accumulated corpus for relevant prior art before Rocky researches them — the backlog never goes to zero, so choosing what to build should be informed by what we already know. Second, the Guppi viewer is rewritten from a 1066-line monolith into a maintainable Flask app with a deep-drill AILC view and a gated add-artifact form.

- **Prior-art search (advisory, non-blocking).** `SUBMIT_INITIATIVE` (`03_procs.sql`) now runs a Cortex Search scan over the corpus and attaches the top hits to `metadata.related_prior_art`. `ROCKY_EXECUTE` injects those hits as grounding so Rocky builds on / cites existing work instead of starting cold. Proven end-to-end on INIT-62 ("auto-evolve our sub-agents"): 7 hits including the CoCoEvolve radar find; Rocky's `RES-62-ROCKY` explicitly cited it.
- **Search services seeded (`07_radar.sql`).** `ARTIFACTS_SEARCH_SVC` (over `ARTIFACTS_SEARCH_V`, artifacts-only, INCREMENTAL, arctic-embed-m-v1.5) and a dedicated `RADAR_SEARCH_SVC` (over `RADAR_SEARCH_V`, RDR- pseudo-rows from `RADAR_ITEMS`). Radar finds are discoverable without being promoted to artifacts. Both were missing from seeds — a fresh install would have broken; now bootstrapped with a warehouse guard.
- **Agent reconciliation (`05_agents.sql`).** Documented that `ROCKY_AGENT` is the current research agent (web_search), `GUPPIWHEEL_COWORK_AGENT` is dispatch, and the precursor `GUPPI.PLATFORM.ROCKY_AGENT` was dropped 2026-06-12. Clears up the naming overlap surfaced during Radar work.
- **Guppi viewer rewrite.** `render_guppi.py` 1066 → ~215 lines: `query_guppi()` kept verbatim, inline HTML template extracted to `templates/index.html` + `static/guppi.{css,js}`. Three views — Command Center, **Classic (SDLC)** (kept deliberately: user stories / defects "before picture"), and **AILC** with drill-down from initiative all the way into story/narrative detail via a half-screen detail drawer. New gated **Add Artifact** form writes through `SUBMIT_INITIATIVE` (INITIATIVE) or `CREATE_ARTIFACT` (else) — the same chokepoint agents use (RULE-029). Product is a dropdown (no ad-hoc product creation); INITIATIVE keeps explicit Hypothesis + Instructions fields mapping to the proc params.
- **Chore.** Untracked a stray committed `.pyc` (already in `.gitignore`).

## [3.10.1] — 2026-06-25

### Chore — scrub personal references from shipped skills

Removed operator-specific paths and connection names so the plugin is clean for any installer:
- `build-protocol`, `snowflake-mcp` — `~/Downloads/CoCoStuff/...` local project paths genericized to `<your-projects-root>/`.
- `guppi/render_guppi.py` and `skill-registry-collaborator/sync_skills.py` — connection resolution no longer falls back to a hardcoded `HealthcareDemos`; uses the named connection if `SNOWFLAKE_CONNECTION_NAME` is set, otherwise the default connection.
- `guppi`, `sdlc-preflight`, `skill-registry-collaborator` — example commands use `YourConnection` instead of `HealthcareDemos`.
- Left intentionally: the two `sdlc-preflight` lines that contain `Downloads/CoCoStuff` as the **scanner search pattern** (the leak-detector that finds exactly this class of issue).

## [3.10.0] — 2026-06-25

### Feature — The Bond is now a real, installable, private-by-default feature

Before this release, seeding guppi-platform created `GUPPIWHEEL.*` but **never created THE_BOND** — yet `03_procs.sql` (Bob grounding) and the `the-bond` skill both read `THE_BOND.PUBLIC.MEMORY_STORE`. A fresh install had no Bond and the headline episodic-memory feature errored out. This release makes the Bond install cleanly, empty, and safe.

- **New engine seed `seeds/engine/06_bond.sql`** — bootstraps `THE_BOND.PUBLIC` (MEMORY_STORE, MEMORY_DOCUMENTS, MEMORY_STREAM, MEMORY_SEARCH, BOND_ACCESS_POLICY) idempotently. Ships **empty** (no moments — each instance accretes its own, Bobiverse-style) and **private by default**: `VISIBILITY` defaults to `private` and the row access policy gates every row to admins / owner / rows marked `shared`. Cortex Search binds to the installer's active warehouse (no dictated compute). Wired into the README install order + `guppiwheel-bootstrap`.
- **`the-bond` skill scrubbed + realigned.** Removed the hardcoded personal path + `HealthcareDemos` connection from session-start; it now pulls context with pure SQL on the active connection. Rewrote "Versioning" to the append-only doctrine (moments are immutable; `SUPERSEDED_BY` only for genuine errors, never world-change). Replaced "Cross-Agent Sharing" with **"Sharing the Bond (manual and deliberate)"** — no automated share surface by design.
- **Presentation upgraded** — README gains a dedicated "The Bond" section; COCO.md Tier 1 names it as the episodic-memory tier; activation.md wording aligned.

Sharing the Bond stays a manual, per-reason act (no `BOND_SHARE_V`). The corpus is the moat and holds confidential moments; default-private + RLS enforce "don't share with just anyone" structurally.

## [3.9.2] — 2026-06-25

### Fix — CoWork content Q&A (cortex_search tool) + Claude→CoCo tool-id hygiene

`GUPPIWHEEL_COWORK_AGENT` could not answer questions about artifact CONTENT: it only had the `flywheel_query` Cortex Analyst tool over `GUPPIWHEEL_SV`, whose raw-VARIANT CONTENT dimension Cortex Analyst cannot read. Added a `cortex_search` tool **`search_artifacts`** over the existing `ARTIFACTS_SEARCH_SVC` (its `SEARCH_TEXT` already flattens CONTENT). The agent now routes: `flywheel_query` for structured facts/counts/stages/lineage; `search_artifacts` for "what does X say / summarize / find artifacts about ___". Updated `seeds/engine/05_agents.sql` (tool_spec + tool_resource + ACTIONS / "WHICH READ TOOL" instructions) and applied live.

Also fixed Claude Code → CoCo Desktop tool-id drift surfaced during plugin install (these silently no-op the restriction/matcher in CoCo otherwise):
- `agents/tars.md` tools `Read`/`Grep`/`Glob` → `read`/`grep`/`glob`
- `hooks/hooks.json` PreToolUse matcher `Write|Edit` → `write|edit`

No schema change; engine seed patched (agents only).

## [3.9.1] — 2026-06-18

### Docs — COCO.md "Staying current" (inbound-only update path)

Added a Tier 2 (suggestive) section to `COCO.md` for installs that don't want to share anything back to the source. It tells a consumer's CoCo it *may* check the upstream repo at session start and **offer** (never auto-apply) updates via a one-way `git fetch upstream` — explicitly **no data leaves the account, no telemetry**. Safe because seeds are idempotent/self-healing and the conformance gate re-confirms Tier 0. Core platform only — customer drops stay pinned/reproducible. Consumer side of the recursivity initiative (INIT-46).

## [3.9.0] — 2026-06-18

### Feature — bundled `snowflake-mcp` skill (server + client MCP patterns)

Added a reusable skill capturing the Snowflake-managed MCP playbook, so building/consuming MCP servers is twice-learned, not re-learned. Born out of the Adonis RCM MVP build.

- **`skills/snowflake-mcp/SKILL.md`** — SERVER: `CREATE MCP SERVER` over Cortex Analyst (semantic views, not model files), Cortex Search, Agents, UDFs/procs; the "grant the server AND each tool object" rule; sessions use `DEFAULT_ROLE` (no secondary roles) so RLS flows through; hyphens-not-underscores; read-only posture. CLIENT: JSON-RPC `tools/list`/`tools/call`; the **exact** parse everyone gets wrong — `CORTEX_ANALYST_MESSAGE` returns `content[].text` as a JSON string → array, with `obj.statement` (SQL), `obj.text` (answer), `obj.suggestions`; SQL-API execution + async polling; client-side read-only guardrail; "don't stringify-regex the response" trap.
- Auto-discovered via the existing `"skills": ["./skills"]` manifest entry; no engine/DDL change (seed engine version stays 3.8.1).
- Encodes the session's process correction: **check the referenced prior art before writing a fix from scratch.**

## [3.8.1] — 2026-06-18

### Refactor — one artifact write chokepoint + agent-callable scalar surface

Consolidated the artifact write path onto a single procedure and made it directly callable by Cortex agents. Answers "why do we need two artifact functions?" — now there is exactly one writer; everything else delegates.

- **`CREATE_ARTIFACT` is the sole INSERT path (RULE-029).** `PUBLISH_ARTIFACT`, `SUBMIT_INITIATIVE`, `ROCKY_EXECUTE`, `STEWART_AUDIT`, `PROPOSE_CORRECTION`, and `BOB_EXECUTE` now validate/shape their payload and **delegate** the INSERT by `CALL`ing `CREATE_ARTIFACT` — no proc does its own `INSERT INTO ARTIFACTS` anymore.
- **All-scalar surface.** `CREATE_ARTIFACT` (and `PUBLISH_ARTIFACT`) now take JSON **strings** for `P_CONTENT`/`P_TAGS`/`P_METADATA`/`P_LAUNCH_SPEC` instead of `VARIANT`/`ARRAY`. Cortex agent generic tools over a warehouse execution environment **cannot pass `object`/`array` argument types** — this was the real cause of the earlier `publish_artifact` "launch specification not compatible with the execution environment" failure. The proc parses JSON internally.
- **Cowork gains a `create_artifact` tool** for non-launchable artifacts (RESEARCH findings, STORY, EPIC, OUTCOME). `publish_artifact` stays for launchables (a launch spec). This is how a research finding now lands under an initiative (e.g. `P_PARENT_ID=INIT-29`) — verified end-to-end through the live agent.
- **`RESEARCH` is now an allocatable series** (`RES-N`) for ad-hoc/Cowork research; Rocky still uses explicit `RES-<init>-ROCKY`.
- **`NULLIF(?, 'None')` guard** on `PRODUCT_ID` (and `PARENT_ID`) — Snowpark binds Python `None` as the string `'None'`; the chokepoint normalizes it to SQL `NULL`.
- **Doctrine sweep:** `RULE-029`/`RULE-028` messages reconciled (single chokepoint; wrappers delegate). **`RULES.MESSAGE` widened `VARCHAR(1000)` → `VARCHAR(4000)`** (self-heal `ALTER`) — long doctrine messages (RULE-026/028) were silently stubbed at 1000 on older installs.
- Conformance gate 5/5 PASS; launchable publish + `GET_ARTIFACT_LAUNCH` verified.

## [3.8.0] — 2026-06-17

### Feature — guppi as a controlled product + per-product share boundary (STO-SUBSTRATE-8)

Formalized `guppi` as a controlled product and made `PRODUCT_ID` the reusable per-product share boundary (Vert). `guppi` is instance #1 (the platform's own self-meta journey); the same primitive packages a customer/prospect initiative as its own share to just that account.

- **`ARTIFACTS.PRODUCT_ID`** (new, FK to `PRODUCTS`) — the controlled membership / share boundary, replacing the folksonomy `guppi` tag. Self-heal `ALTER ... ADD COLUMN IF NOT EXISTS` for existing installs.
- **`PRODUCTS` `platform` → `guppi`** (singular umbrella; bootstrap seeds the `guppi` product on fresh installs).
- **Membership derived + human-reviewed** — 59 self-meta artifacts stamped `PRODUCT_ID='guppi'` (EPIC-SUBSTRATE/INIT-36/INIT-46 spine + platform/guppi tags + changelog narratives), with customer-subject artifacts (Ferrum bake-off audits, Adonis research) hard-excluded.
- **Two-dimensional confidentiality:** row (`PRODUCT_ID`) + field (an `internal` namespace the share never projects). `GUPPI_SHARE_V` now filters `PRODUCT_ID='guppi'` and strips `CONTENT:internal`/`strategic_note`, omitting raw `METADATA`. Migrated `NAR-34.CONTENT:strategic_note` → `METADATA:internal`.
- **`PRODUCT_SHARE_LEAK_V`** (new) — confidentiality tripwire keyed on *subject* (CONTENT:target/title), added to `GUPPI_CONFORMANCE_V` (now 5 checks, all PASS). Won't false-positive roadmap stories that mention a customer.
- **`CREATE_ARTIFACT` stamps `PRODUCT_ID`** from a validated `P_PRODUCT` — artifacts are born-bucketed (perpetuation). Bob's bake-off audits now use NULL product (customer-subject, not guppi).
- **Viewer** (`render_guppi`) reads the controlled `PRODUCT_ID` (with metadata fallback).
- **README:** documented the reusable per-product share recipe (row filter + field projection + SHARE + ADD ACCOUNTS).

## [3.7.0] — 2026-06-16

### Feature — Bob, the Building-stage agent (INIT-36)

The missing seat in the cast: Cowork (Initiate) -> Rocky (Research) -> **Bob (Building)** -> Stewart/TARS watch. v1 capability: `RESEARCH -> hypothetical NARRATIVE` (no app/model build).

- **`BOB_AGENT`** (Cortex Agent, `web_search`) — gathers/verifies grounding and surfaces contradictions; authors nothing.
- **`BOB_EXECUTE`** proc (`EXECUTE AS OWNER`) — assembles grounding (parent RESEARCH + Guppi + Bond + the web brief), authors the same narrative across **all enabled `MODEL_CATALOG` models** via `AI_COMPLETE`, then runs a **cross-judge panel** (every candidate scored by every *other* model — **no model judges its own work**, RULE-023), writes one in-wheel `AUDIT` per candidate (`TARS_AUDITS_V`), and writes the highest-average-trust winner as a `NARRATIVE` with provenance. Mirrors the Rocky agent+proc pattern; writes via `CREATE_ARTIFACT`.
- **`MODEL_CATALOG`** (minimal STO-36-B) — enabled models for the bake-off; adding/removing a model is a row, never code. Seeded with the verified-callable set (claude-sonnet-4-5, openai-gpt-4.1, llama3.3-70b, mistral-large2).
- **`RULE-023`** — foundation-model agnosticism: model choice is an auditable, evidence-based decision.
- First run on `RES-44` (Ferrum): winner claude-sonnet-4-5 (avg trust 0.85) over mistral (0.81), gpt-4.1 (0.81), llama (0.76); 3 independent judges each; zero self-judge violations; conformance gate 4/4 PASS. Uses `AI_COMPLETE` (not the deprecated `SNOWFLAKE.CORTEX.COMPLETE`).
- v1 stops at the NARRATIVE artifact; HTML rendering reuses the validated `static_html -> @ARTIFACT_ASSETS -> GET_ARTIFACT_LAUNCH` path.

## [3.6.0] — 2026-06-15

### Substrate — TARS audits in-wheel (STO-SUBSTRATE-9, 2026-06-16)

Resolved the audit-grounding fork toward a single source of truth: **TARS trust audits now live in the wheel as `AUDIT` artifacts** — the artifact *is* the TARS output. "Everything through Guppi."

- **`TARS_AUDITS_V` / `TARS_FINDINGS_V`** (new, `01_schema.sql`) flatten `AUDIT` artifacts (`CONTENT:score IS NOT NULL`) back into run/finding rows for trend queries and the rules engine.
- **Rules realigned to the views** (live + seed): `STG-003` (App→Built needs a TARS audit ≥ 0.85) and `QAL-002` (no unresolved D-signal) now read `TARS_AUDITS_V`/`TARS_FINDINGS_V`. Added `QAL-002` to the seed (was live-only drift).
- **`STG-004` decided**: advancing to **Narrated requires a human affirmation vote** on the artifact's TARS audit (seed previously required a NARRATIVE child — reconciled to the human-vote gate, seed == live).
- **Retired** legacy `AUDIT_RUNS` + `AUDIT_FINDINGS` tables (summaries already lived in-wheel under matching IDs).
- **`tars-trust-auditor` skill** rewritten: writes one `AUDIT` artifact via `CREATE_ARTIFACT` (`audit_kind='TARS'`, findings nested in `CONTENT`), human vote = an `UPDATE` to the artifact; removed the `AUDIT_RUNS` DDL and the "ask where to store" step.
- Conformance gate stays 4/4 PASS.
- **Schema drift fixed**: widened `ARTIFACTS.ID`/`PARENT_ID`/`SUPERSEDED_BY` (and `VIOLATIONS.ARTIFACT_ID`) to `VARCHAR(64)` (live was 36 — descriptive IDs overflowed). Added the missing `SUPERSEDED_BY` column to the seed `ARTIFACTS` table — without it a **fresh install would fail** creating the serving/TARS views that reference it. Idempotent self-heal `ALTER`s added so existing installs repair on re-run; fresh installs are born correct.

### Drop readiness — the Tier Contract + conformance gate (2026-06-16)

Prepared guppi-platform for its first external `git clone` by another SE. Made the drop self-describing so a receiving CoCo can tell an invariant from an affordance, and made "you got Guppi" testable rather than "ran our exact files."

- **`COCO.md`** (new, repo root) — the contract a receiving CoCo reads first. Three tiers: **Invariants** (enforced; don't alter the guarantee — single SSOT, no-dup IDs, gap-free registry, single gated write path, doctrine-as-data, sub-agents propose-only, headless-first, lifecycle), **Defaults** (works on clone; yours to change — procs, agents, compute wiring, viewer), **Suggestive** (author to taste — cadence, cosmetics, extra tooling). Each `seeds/engine/*.sql` carries an inline `TIER:` header.
- **`GUPPI_CONFORMANCE_V`** (new) — the conformance gate; the definition of done. Every row must read `PASS` (no-duplicate-ids, ids-distinct, grounding-health, rules-present). A fresh install passes immediately; re-run after any build or re-author.
- **Warehouse: we no longer dictate one.** `05_agents.sql` binds agents to the installer's active `CURRENT_WAREHOUSE()` (placeholder substitution, fails loud if none set) and `ROCKY_TASK` is now **serverless** (no `WAREHOUSE` param; requires `EXECUTE MANAGED TASK`).
- **Applied `STO-STEWART-1`**: cleaned the 3 orphaned narratives (`NAR-4`, `NAR-5`, `NAR-CHANGELOG-3.5.0`) whose `PARENT_ID` held the literal `'None'`; gate now green.
- **README** refreshed to v3.6.0 (Stewart, warehouse/`EXECUTE MANAGED TASK` prereqs, conformance-gate verification step, `COCO.md` pointer). Fixed `PLUGIN_VERSION` seed drift (`3.0.0` → `3.6.0`).
- **Genericized** `RULE-024` — removed a customer name from the secrets-hygiene reason text (seed + live).

### Feature — Stewart, the Grounding Steward (first INIT-36 sub-agent)

Shipped the first INIT-36 sub-agent and the dry run for the orchestrator/sub-agent pattern: a propose-only, Cortex-Analyst-oriented steward of the objective layer (rules-engine grounding, ID conventions, substrate hygiene).

- **`RULE-027`** — Doctrine-Change Authority Is Orchestrator-Only. Sub-agents operate within current doctrine: they read everything and **propose via artifacts**, but never write `RULES`, set `SUPERSEDED_BY`, or alter serving surfaces. Realizes `STO-36-O`.
- **`GROUNDING_HEALTH_V`** — Stewart's senses: deterministic drift signals (duplicate IDs, orphan parents, non-canonical TYPE/STAGE, dead-DB rule refs, non-canonical `APPLIES_TO_TYPE`).
- **`STEWART_AUDIT`** — read-only scan; writes one `AUDIT` scan-record artifact (tagged `guppi`).
- **`PROPOSE_CORRECTION`** — files `STORY` proposals (tagged `guppi`) under an audit; routes through `CREATE_ARTIFACT`. **Proposal only.**
- **`STEWART_AGENT`** — Cortex Agent: `cortex_analyst_text_to_sql` over `GUPPIWHEEL_SV` + the two procs as tools.
- **Boundary is structural**: no tool Stewart holds can write doctrine. He explicitly monitors orchestrator/owner writes — the blind spot RBAC cannot bind.
- **Bug caught on first run**: `CREATE_ARTIFACT` was writing the literal string `'None'` for null parents (3 orphaned artifacts). Fixed the proc (`NULLIF` + coercion); Stewart filed `STO-STEWART-1` proposing the data cleanup. Tracked as `STO-36-STEWART`.

## [3.5.0] — 2026-06-15

### Foundation — substrate integrity: dedup + enforced ID uniqueness (EPIC-SUBSTRATE)

Made "no duplicate artifact IDs" a real, enforced invariant before INIT-36. A TARS-FULL audit found 31 duplicate IDs in the `ARTIFACTS` SSOT — including `INIT-36` held by 5 different initiatives after a batch load bypassed the (non-atomic, stale) `ID_CONVENTIONS` counter. Root cause: Snowflake does not enforce `PRIMARY KEY`/`UNIQUE` on standard tables, and there was no single write path.

- **Dedup**: removed 19 exact-duplicate rows; re-IDed 15 divergent collisions (canonical row keeps the ID; childless colliders get fresh IDs — e.g. the 4 mis-loaded Adonis initiatives → `INIT-38..41`). Split `E-013` into Core Platform (`E-013`) + ETHOS (`E-21`) with children re-parented. Result: 394 rows = 394 distinct IDs.
- **`CREATE_ARTIFACT`** (new, `03_procs.sql`): the single gated write path. Registry-driven, gap-free atomic allocation from `ID_CONVENTIONS` keyed by `(TYPE, PRODUCT)`; dual-mode (auto-allocate or uniqueness-checked explicit ID); validates `TYPE`/`STAGE` domains. `EXECUTE AS OWNER` per RULE-028.
- **Registry**: `ID_CONVENTIONS` gains `ID_PREFIX`; introducing a convention = adding a row (honored automatically). Allocation is a gap-free atomic counter (not Snowflake sequences, which leave large gaps in human-referenced IDs).
- **Lockdown**: revoked direct `INSERT` on `ARTIFACTS` from `GUPPIWHEEL_ADMIN` (admin keeps UPDATE/DELETE for surgery); informational `PRIMARY KEY`; `DUPLICATE_ID_SCREAM_V` tripwire.
- **Agents hardened**: `ROCKY_EXECUTE` now versions research IDs on collision (`-V2`…) — it had created the `RES-20-ROCKY` duplicate; `SUBMIT_INITIATIVE` allocation made atomic.
- **Doctrine**: `RULE-029` (ID uniqueness + single write path). `guppiwheel-governance` skill gains a future-grant INSERT guard. Anomaly cleanup (FORGE/HF drift, lowercase series, raw-UUID IDs) grandfathered — deferred to a future data-hygiene agent.
- **Rules-engine grounding fix (live)**: corrected all 27 live `RULES.CONDITION_SQL` — they referenced dead DBs `FLYWHEEL.PUBLIC` (pre-rename) and `GUPPI.PLATFORM.AUDIT_*` (now `DONOTUSEGUPPI`), and used lowercase `APPLIES_TO_TYPE`/TYPE literals that never matched UPPERCASE data. `QAL-001` (block, ALL) was effectively blocking all stage advancement. `ADVANCE_STAGE` now evaluates cleanly. Added 7 audit-model-independent doctrine rules to the seed (`RULE-020/021/024/025/026/028`, `STG-005`). Discovered a seed↔live **audit-grounding model divergence** (seed = in-wheel AUDIT artifacts; live = `AUDIT_RUNS` tables, unseeded) — filed `STO-SUBSTRATE-9` for deliberate reconciliation rather than a breaking blind-sync.

## [3.4.1] — 2026-06-15

### Security — RBAC lockdown, secondary-table pass (follow-on to 3.4.0)

Completed the contributor grant audit started in 3.4.0. Revoked direct DML on the remaining system/log tables; kept the contributor-curatable reference tables.

- **Revoked from CONTRIBUTOR**: `ID_CONVENTIONS` (sequence counter — written only by the OWNER procs), `PLUGIN_VERSION` (system/admin), `INITIATIVE_STEPS` (Rocky/agent execution log, OWNER-written), `GUPPI_TOUCH_WATCH` (orphan, unwritten by any code path).
- **Kept for CONTRIBUTOR**: `PRODUCTS` (product registry — contributors curate; now added to the seed so it perpetuates), `ECOSYSTEM.TAXONOMY` (reference data), `VIOLATIONS` + `ARTIFACT_LAUNCHES` (proc-written), Bond `MEMORY_STORE`, stage R/W.
- **Seed**: `engine/01_schema.sql` adds `GRANT INSERT, UPDATE ON PRODUCTS` and a comment documenting which tables are contributor-curatable vs system/procedure-owned.
- Net: the only tables a contributor can write directly are the two reference registries (PRODUCTS, TAXONOMY). Everything else is procedure-mediated or admin-only, per RULE-028.

## [3.4.0] — 2026-06-15

### Security — RBAC lockdown (STO-RBAC-LOCKDOWN, RULE-028)

GuppiWheel writes are now **procedure-mediated**, and doctrine is **admin-only**. No role below ADMIN holds direct DML on `ARTIFACTS` or `RULES`. This closes a gap where contributors could edit any artifact in place, set `STAGE` directly (bypassing the `ADVANCE_STAGE` rules engine), or rewrite doctrine.

- **Born-locked seed**: `seeds/engine/01_schema.sql` no longer grants `INSERT/UPDATE ON ARTIFACTS` to `GUPPIWHEEL_CONTRIBUTOR`. `seeds/engine/03_procs.sql` now ships `SUBMIT_INITIATIVE` and `PUBLISH_ARTIFACT` as `EXECUTE AS OWNER` (so the procedure is the only working write path once direct DML is absent) and adds the owner-scoped `UPDATE_OWN_ARTIFACT` procedure.
- **New skill `guppiwheel-governance`**: audit → explain → propose → apply-on-per-step-approval → verify. Run it after bootstrap to confirm the lockdown on a new install, or to remediate an older account that pre-dates the born-locked seed. Adapts to local role names. Suggest + admin-ratified — never a forced script. Sibling to `agent-guardrails` and `coco-enterprise-pipeline`.
- **`guppiwheel-bootstrap` fixed**: corrected stale `FLYWHEEL` → `GUPPIWHEEL` references and seed paths (`seeds/engine/*`), and added a hand-off to `guppiwheel-governance` after seeding.
- **Model**: ADMIN (full direct DML incl. doctrine) > CONTRIBUTOR (procedure-mediated writes; `UPDATE_OWN_ARTIFACT` for own drafts; keeps `ECOSYSTEM.TAXONOMY` direct DML as reference data) > VIEWER (read-only). The human mirror of STO-36-O.

### Note for the consumer's CoCo
If you are upgrading an existing install, your contributors may still hold the old direct grants. Invoke `guppiwheel-governance` — it will audit, show you each hole, and remediate only with your admin's per-step approval. Concept-distribution per RULE-021: you get the model, not our users.

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
