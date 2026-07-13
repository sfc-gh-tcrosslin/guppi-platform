# guppi-platform v3.15.0

**Guppi** — value creation engine on Snowflake. One ARTIFACTS table is the source of truth; every initiative, research synthesis, app, model, narrative, defect, incident, and audit lives in the wheel.

> **New here? Read [`COCO.md`](COCO.md) first.** It is the contract: what is invariant (don't alter the guarantee), what is a default (yours to change), what is suggestive (author to taste), and the conformance gate that defines "you got Guppi."

Brand hierarchy: **Guppi** (product) → **GuppiWheel** (engine / `GUPPIWHEEL` db) → **Rocky / Cowork / TARS / Stewart** (agents) → **CoCo** (interface).

Includes:
- **Rocky** — autonomous research Cortex Agent (server-side, serverless 5-min Task). Opt-in *swarm* on hard research (`metadata.swarm` or `priority=high`): profiled, isolated roles reconciled by a different model, preserving conflicts — the ArcticSwarm isolate-then-reconcile pattern (RULE-030)
- **Radar** — standing weekday scan of major AI blogs. Isolated per-source fetch (ArcticSwarm fan-out) → portfolio-grounded assessment (relevance + related initiatives + *proposed* actions) → one rolling narrative
- **Cowork** — user-facing dispatch agent (submit, advance, query, publish)
- **Stewart** — propose-only grounding steward (read-only audit; files fix proposals, never applies them) — RULE-027 / STO-36-O
- **Bob** — Building-stage agent: authors hypothetical narratives from research, choosing the model by a cross-judge bake-off where no model judges its own work (RULE-023). Advisory *error-localization* on the winner: an independent model decomposes it into atomic claims and flags each grounded/unsupported/contradicted (ArcticSwarm "Agent GPA" pattern)
- **TARS** — independent trust auditor (writes AUDIT artifacts)
- **The Bond** — the episodic-memory organ of the AILC: an append-only, co-created log of moments (`THE_BOND` database). Empty on install, private by default.
- **GUPPI viewer** — Flask app rendering Command Center + Flywheel from `localhost:8888`

## Lifecycle

```
Initiate → Research → Building → Built → Narrated
```

A Narrated artifact that spawns a follow-on creates a NEW artifact at Initiate. There is no "archived."

## The Bond

The Bond (`THE_BOND` database) is GuppiWheel's **episodic memory** — the third tier alongside the current-truth RULES engine and the procedural skills layer. It is an append-only log of co-created moments (decisions, corrections, synthesis) that preserves the *why* forever. See the `the-bond` skill for the operating model.

- **Empty on install.** `06_bond.sql` ships the substrate only — no moments. Your instance accretes its own lived experience (Bobiverse: same engine, different mind).
- **Private by default.** `VISIBILITY` defaults to `private` and a row access policy (`BOND_ACCESS_POLICY`) gates every row to admins, the owner, or rows explicitly marked `shared`. You do not share your Bond with just anyone — sharing is manual and deliberate, and there is **no automated share view by design** (the corpus is the moat and holds confidential moments).
- **Append-only.** Moments are immutable; when understanding evolves you add a new linked entry rather than overwrite. `SUPERSEDED_BY` is reserved for genuine errors, not for "the world changed."

## Install (fresh account)

**Prerequisites:**
- Install as a role with account privileges (ACCOUNTADMIN, or a role with `CREATE DATABASE`, `CREATE ROLE`, and `EXECUTE MANAGED TASK` for the serverless Rocky task).
- A warehouse must be **active in your session** — we do not dictate one. `05_agents.sql` binds agents to your `CURRENT_WAREHOUSE()` and fails loud if none is set:
  ```sql
  USE WAREHOUSE <your_wh>;
  ```

```bash
# 1. Clone or pull this plugin
git clone <this-repo> guppi-platform
cd guppi-platform

# 2. Run engine seeds in order — safe to re-run
snow sql -f seeds/engine/01_schema.sql
snow sql -f seeds/engine/02_rules.sql
snow sql -f seeds/engine/03_procs.sql
snow sql -f seeds/engine/04_semantic_view.sql
snow sql -f seeds/engine/05_agents.sql      # requires an active warehouse (see prereqs)
snow sql -f seeds/engine/06_bond.sql        # The Bond (episodic memory); ships EMPTY, private by default; requires an active warehouse

# 3. Bootstrap content — ONE TIME only on fresh accounts (seeds the ID registry; no artifacts)
snow sql -f seeds/content/bootstrap.sql

# 4. Verify: the conformance gate must report PASS on every row
snow sql -q "SELECT * FROM GUPPIWHEEL.PUBLIC.GUPPI_CONFORMANCE_V ORDER BY check_name;"

# 5. Install viewer dependencies and launch
pip install -r skills/guppi/requirements.txt
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 skills/guppi/render_guppi.py --serve
# Open http://localhost:8888
```

A fresh install starts with a clean wheel (no seeded artifacts), so the gate passes immediately. Re-run the gate any time after you build or re-author — it is the definition of done (see `COCO.md`).

## Upgrade from 2.0.0

```bash
git pull
# Engine seeds are CREATE OR REPLACE / MERGE — safe to re-run
snow sql -f seeds/engine/01_schema.sql
snow sql -f seeds/engine/02_rules.sql
snow sql -f seeds/engine/03_procs.sql
snow sql -f seeds/engine/04_semantic_view.sql
snow sql -f seeds/engine/05_agents.sql
snow sql -f seeds/engine/06_bond.sql

# One-time upgrade migration
snow sql -f seeds/upgrades/2.0.0-to-3.0.0.sql
```

The upgrade script:
- Renames FLYWHEEL → GUPPIWHEEL if needed
- Normalizes TYPE values to UPPERCASE
- Renames stages (spark → Initiate, active → Research, told → Narrated, etc.)
- Updates PLUGIN_VERSION to 3.0.0

It does **NOT** touch your ARTIFACTS rows beyond TYPE/STAGE normalization. Your initiatives, briefs, and audits remain.

## What you get

```
GUPPIWHEEL.PUBLIC
├── ARTIFACTS              -- single source of truth (every type)
├── RULES                  -- governance as data (RULE-013..029 + STG/CMP/QAL/TMG)
├── VIOLATIONS             -- where broken rules land
├── ID_CONVENTIONS         -- gap-free ID registry (ENTITY, NEXT_SEQ, ID_PREFIX) — atomic, no SEQUENCE objects
├── INITIATIVE_STEPS       -- Rocky step logs
├── PRODUCTS               -- product groupings (used by viewer)
├── ARTIFACT_LAUNCHES      -- audit log of every artifact open
├── PLUGIN_VERSION         -- what's installed
├── @ARTIFACT_ASSETS       -- internal stage for HTML/PDF bytes
├── DUPLICATE_ID_SCREAM_V  -- RULE-029 tripwire (always 0 rows)
├── GROUNDING_HEALTH_V     -- Stewart's senses: orphans, noncanonical types/stages, dead refs
├── GUPPI_CONFORMANCE_V    -- the conformance gate (every row PASS = you got Guppi)
├── CREATE_ARTIFACT proc   -- the SINGLE gated write path (gap-free IDs; direct INSERT revoked)
├── ADVANCE_STAGE proc     -- universal stage gate
├── SUBMIT_INITIATIVE proc -- queue work for Rocky
├── ROCKY_EXECUTE proc     -- Rocky's per-cycle handler
├── PUBLISH_ARTIFACT proc  -- register a launchable
├── STEWART_AUDIT proc     -- read-only grounding/hygiene scan (writes one AUDIT artifact)
├── PROPOSE_CORRECTION proc -- file a fix proposal as a STORY (never auto-applied)
├── GET_ARTIFACT_LAUNCH    -- resolve to URL/identifier (presigned + audited)
├── GUPPIWHEEL_SV          -- semantic view for Cortex Analyst
├── ROCKY_AGENT            -- web-search-only research agent
├── GUPPIWHEEL_COWORK_AGENT -- user-facing dispatch agent
├── STEWART_AGENT          -- propose-only grounding steward (sub-agent)
├── BOB_AGENT              -- Bob's web_search grounding scout (Building-stage)
├── BOB_EXECUTE proc        -- Bob: model bake-off + cross-judge → winner NARRATIVE
├── MODEL_CATALOG          -- enabled models for the bake-off (RULE-023, foundation-model agnosticism)
└── ROCKY_TASK             -- serverless 5-min cycle running ROCKY_EXECUTE

Roles: GUPPIWHEEL_ADMIN > GUPPIWHEEL_CONTRIBUTOR > GUPPIWHEEL_VIEWER
(direct INSERT on ARTIFACTS is revoked even from ADMIN — writes flow only through procs)
```

## Architecture principles

- **RULE-013 Headless First** — every output is an artifact. Render FROM artifacts.
- **RULE-014 Status Ownership** — submitter sets Initiate; agent sets Research/Built/Narrated.
- **RULE-015 Collaboration Tags** — `metadata.tagged_users` for routing.
- **RULE-016 No Self-Spawning** — agents never enqueue work for themselves.
- **RULE-017 Separation of Execution** — Cowork dispatches, Rocky researches.
- **RULE-018 Launchables Live in the Wheel** — bytes belong in `@ARTIFACT_ASSETS`, never in local file paths.
- **RULE-027 Doctrine Authority** — sub-agents (e.g. Stewart) PROPOSE via artifacts; only the human/orchestrator changes doctrine (RULES, SUPERSEDED_BY, serving surfaces).
- **RULE-029 Uniqueness** — no duplicate IDs, ever. Enforced procedurally (Snowflake does not enforce PK/UNIQUE); watched by `DUPLICATE_ID_SCREAM_V`.

## Universal launch model

NARRATIVE / APP / MODEL / DASHBOARD artifacts all carry one shape:

```
metadata.launch = {
  app_type: 'cortex_agent' | 'streamlit' | 'spcs_service' | 'native_app'
            | 'external_url' | 'static_html' | 'pdf'
  identifier?: 'DB.SCHEMA.OBJECT_NAME'
  url?: 'https://...'
  stage_path?: '@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/...'
  default_ttl_seconds?: 3600
}
```

`GET_ARTIFACT_LAUNCH(artifact_id)` resolves any of these to the right thing — presigned URL, identifier, external URL — and logs every call to `ARTIFACT_LAUNCHES` for audit.

## Per-product sharing (Vert)

The wheel packages any product's artifacts as a Secure Data Share to specific accounts. The boundary is the controlled `ARTIFACTS.PRODUCT_ID` (FK to `PRODUCTS`), **not** the folksonomy tag. `guppi` is the platform's own self-meta product; customers/prospects are their own products.

**Confidentiality is enforced at three levels:**
- **Row** — `PRODUCT_ID` decides which artifacts are in a product's share.
- **Field** — share views select an explicit safe field set and strip the `internal` namespace (`CONTENT:internal.*`, `METADATA:internal.*`); raw `METADATA` is never shared. Internal commentary belongs in `METADATA:internal`.
- **Persistence** — the same line governs Bond/memory: record principles, never customer payloads.

`PRODUCT_SHARE_LEAK_V` (in `GUPPI_CONFORMANCE_V`) is the tripwire — it flags any guppi artifact whose *subject* is a customer (`CONTENT:target`/title) or that still carries an `internal` key. Must be 0. It keys on subject, not topical tags, so a roadmap story that merely mentions a customer is not flagged.

**The recipe** (guppi is the template; a customer share is fill-in-the-blank):
```sql
-- 1) artifacts carry PRODUCT_ID='<product>' (CREATE_ARTIFACT stamps it from P_PRODUCT)
-- 2) a product-scoped secure view: row filter + safe field projection
CREATE OR REPLACE SECURE VIEW <PRODUCT>_SHARE_V AS
  SELECT ID, TYPE, STAGE, TITLE, OBJECT_DELETE(CONTENT,'internal','strategic_note') AS CONTENT,
         TAGS, PARENT_ID, PRODUCT_ID, CREATED_AT, UPDATED_AT
  FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
  WHERE PRODUCT_ID='<product>' AND SUPERSEDED_BY IS NULL;
-- 3) the share + grants
CREATE SHARE <PRODUCT>_SHARE;
GRANT USAGE ON DATABASE GUPPIWHEEL TO SHARE <PRODUCT>_SHARE;
GRANT USAGE ON SCHEMA GUPPIWHEEL.PUBLIC TO SHARE <PRODUCT>_SHARE;
GRANT SELECT ON VIEW GUPPIWHEEL.PUBLIC.<PRODUCT>_SHARE_V TO SHARE <PRODUCT>_SHARE;
-- 4) add only that product's consumer account(s)
ALTER SHARE <PRODUCT>_SHARE ADD ACCOUNTS=<account_locator>;
```

**`PRODUCT_ID='<customer>'` means the artifact belongs to that product — not that it is customer-facing.** A customer share must additionally curate for customer-facing content (never ship internal strategy). The consumer lands the share in a distinct database (default `VERT.PUBLIC.*`, RULE-021), never auto-merged into their local wheel.

## Documentation

- See `COCO.md` for the tier contract and the conformance gate (read this first)
- See `CHANGELOG.md` for version history and breaking changes
- See `skills/guppiwheel/SKILL.md` for the full GuppiWheel concept
- See `skills/guppi/SKILL.md` for the viewer architecture
- See `skills/guppi-slack-rep/SKILL.md` for the optional Slack representative recipe (a *suggestion* one Guppi makes to another — capability tier, not seed substrate)
- See `agents/rocky.md`, `agents/tars.md`, `agents/steward.md`, and `agents/bob.md` for agent behavior contracts
- See `references/maturity-model.md` and `references/trust-equation.md` for theoretical foundations

## Versioning

- Plugin version is in `.cortex-plugin/plugin.json` (`version` field)
- Live install version is in `GUPPIWHEEL.PUBLIC.PLUGIN_VERSION`
- The two are kept in sync via `seeds/engine/01_schema.sql` (which inserts/updates the row on every engine run) and the SDLC preflight Check 11 drift detection
