# guppi-platform v3.0.0

GuppiWheel — value creation engine on Snowflake. One ARTIFACTS table is the source of truth; every initiative, research synthesis, app, model, narrative, defect, incident, and audit lives in the wheel.

Includes:
- **Rocky** — autonomous research Cortex Agent (server-side, 5-min Task)
- **Cowork** — user-facing dispatch agent (submit, advance, query, publish)
- **TARS** — independent trust auditor (writes AUDIT artifacts)
- **The Bond** — shared cognition layer (separate database)
- **GUPPI viewer** — Flask app rendering Command Center + Flywheel from `localhost:8888`

## Lifecycle

```
Initiate → Research → Building → Built → Narrated
```

A Narrated artifact that spawns a follow-on creates a NEW artifact at Initiate. There is no "archived."

## Install (fresh account)

```bash
# 1. Clone or pull this plugin
git clone <this-repo> guppi-platform
cd guppi-platform

# 2. Run engine seeds — safe to re-run
snow sql -f seeds/engine/01_schema.sql
snow sql -f seeds/engine/02_rules.sql
snow sql -f seeds/engine/03_procs.sql
snow sql -f seeds/engine/04_semantic_view.sql
snow sql -f seeds/engine/05_agents.sql

# 3. Bootstrap content — ONE TIME only on fresh accounts
snow sql -f seeds/content/bootstrap.sql

# 4. Install viewer dependencies and launch
pip install -r skills/guppi/requirements.txt
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 skills/guppi/render_guppi.py --serve
# Open http://localhost:8888
```

## Upgrade from 2.0.0

```bash
git pull
# Engine seeds are CREATE OR REPLACE / MERGE — safe to re-run
snow sql -f seeds/engine/01_schema.sql
snow sql -f seeds/engine/02_rules.sql
snow sql -f seeds/engine/03_procs.sql
snow sql -f seeds/engine/04_semantic_view.sql
snow sql -f seeds/engine/05_agents.sql

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
├── RULES                  -- governance as data (RULE-013..018 + STG/CMP/QAL/TMG)
├── VIOLATIONS             -- where broken rules land
├── ID_CONVENTIONS         -- sequence tracker for INIT-N etc.
├── INITIATIVE_STEPS       -- Rocky step logs
├── PRODUCTS               -- product groupings (used by viewer)
├── ARTIFACT_LAUNCHES      -- audit log of every artifact open
├── PLUGIN_VERSION         -- what's installed
├── @ARTIFACT_ASSETS       -- internal stage for HTML/PDF bytes
├── ADVANCE_STAGE proc     -- universal stage gate
├── SUBMIT_INITIATIVE proc -- queue work for Rocky
├── ROCKY_EXECUTE proc     -- Rocky's per-cycle handler
├── PUBLISH_ARTIFACT proc  -- register a launchable
├── GET_ARTIFACT_LAUNCH    -- resolve to URL/identifier (presigned + audited)
├── GUPPIWHEEL_SV          -- semantic view for Cortex Analyst
├── ROCKY_AGENT            -- web-search-only research agent
├── GUPPIWHEEL_COWORK_AGENT -- user-facing dispatch agent
└── ROCKY_TASK             -- 5-min cycle running ROCKY_EXECUTE

Roles: GUPPIWHEEL_ADMIN > GUPPIWHEEL_CONTRIBUTOR > GUPPIWHEEL_VIEWER
```

## Architecture principles

- **RULE-013 Headless First** — every output is an artifact. Render FROM artifacts.
- **RULE-014 Status Ownership** — submitter sets Initiate; agent sets Research/Built/Narrated.
- **RULE-015 Collaboration Tags** — `metadata.tagged_users` for routing.
- **RULE-016 No Self-Spawning** — agents never enqueue work for themselves.
- **RULE-017 Separation of Execution** — Cowork dispatches, Rocky researches.
- **RULE-018 Launchables Live in the Wheel** — bytes belong in `@ARTIFACT_ASSETS`, never in local file paths.

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

## Documentation

- See `CHANGELOG.md` for version history and breaking changes
- See `skills/guppiwheel/SKILL.md` for the full GuppiWheel concept
- See `skills/guppi/SKILL.md` for the viewer architecture
- See `agents/rocky.md` and `agents/tars.md` for agent behavior contracts
- See `references/maturity-model.md` and `references/trust-equation.md` for theoretical foundations

## Versioning

- Plugin version is in `.cortex-plugin/plugin.json` (`version` field)
- Live install version is in `GUPPIWHEEL.PUBLIC.PLUGIN_VERSION`
- The two are kept in sync via `seeds/engine/01_schema.sql` (which inserts/updates the row on every engine run) and the SDLC preflight Check 11 drift detection
