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

### Prerequisites

- **SnowCLI** (`snow`) installed and a named connection in `~/.snowflake/connections.toml`
- The connection must use a role with **CREATE DATABASE** privilege (typically `SYSADMIN`)
- **ACCOUNTADMIN** (or `SECURITYADMIN`) is required for the RBAC step (role creation)
- A warehouse named **`COMPUTE_WH`** must exist (used by agents and ROCKY_TASK). Create one if needed:
  ```sql
  CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
  ```
- If your `~/.snowflake/config.toml` sets a different `default_connection_name` than the one you intend, pass `--connection <name>` explicitly on every `snow sql` call

### Known issues with `snow sql -f`

`snow sql -f` splits on semicolons, which breaks SQL stored procedures that use `BEGIN...END` blocks (affects `SUBMIT_INITIATIVE` and `UPDATE_OWN_ARTIFACT` in `03_procs.sql`). Workarounds:
- Pipe individual procedures via `snow sql -i` (stdin), or
- Execute them through Snowsight or any connector that supports multi-statement execution

The Python-based procedures (string-delimited with `'...'`) execute correctly via `snow sql -f`.

### Steps

```bash
# 1. Clone or pull this plugin
git clone <this-repo> guppi-platform
cd guppi-platform

# 2. Run engine seeds — safe to re-run
#    Replace YOUR_CONNECTION with your connections.toml entry name.
#    The connection role needs CREATE DATABASE (e.g. SYSADMIN).
snow sql -f seeds/engine/01_schema.sql --connection YOUR_CONNECTION
snow sql -f seeds/engine/02_rules.sql  --connection YOUR_CONNECTION
snow sql -f seeds/engine/03_procs.sql  --connection YOUR_CONNECTION
snow sql -f seeds/engine/04_semantic_view.sql --connection YOUR_CONNECTION
snow sql -f seeds/engine/05_agents.sql --connection YOUR_CONNECTION

# 2a. RBAC — requires ACCOUNTADMIN (SYSADMIN cannot CREATE ROLE).
#     The RBAC block at the end of 01_schema.sql will fail unless you
#     pass --role ACCOUNTADMIN. Re-running is safe (IF NOT EXISTS).
snow sql -f seeds/engine/01_schema.sql --connection YOUR_CONNECTION --role ACCOUNTADMIN

# 2b. If 03_procs.sql fails on BEGIN...END procedures, see
#     "Known issues with snow sql -f" above.

# 3. Create auxiliary databases required by the viewer
#    (No seed file exists for these yet — create manually.)
snow sql --connection YOUR_CONNECTION -q "
CREATE DATABASE IF NOT EXISTS SKILL_REGISTRY;
CREATE TABLE IF NOT EXISTS SKILL_REGISTRY.PUBLIC.SKILLS (
    SKILL_ID VARCHAR(64) PRIMARY KEY, SKILL_NAME VARCHAR(200),
    AUTHOR VARCHAR(200), DOMAIN VARCHAR(100), VERSION VARCHAR(20),
    DESCRIPTION VARCHAR, CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE DATABASE IF NOT EXISTS THE_BOND;
CREATE TABLE IF NOT EXISTS THE_BOND.PUBLIC.MEMORY_STORE (
    MEMORY_ID VARCHAR(64) PRIMARY KEY, AGENT_ID VARCHAR(100),
    CATEGORY VARCHAR(100), KEY VARCHAR(500), TAGS ARRAY,
    ORIGIN VARCHAR(200), INSIGHT_TYPE VARCHAR(100),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
"

# 4. Bootstrap content — ONE TIME only on fresh accounts
snow sql -f seeds/content/bootstrap.sql --connection YOUR_CONNECTION

# 5. Install viewer dependencies and launch
pip install -r skills/guppi/requirements.txt
SNOWFLAKE_CONNECTION_NAME=YOUR_CONNECTION python3 skills/guppi/render_guppi.py --serve
# Open http://localhost:8888
```

## Upgrade from 2.0.0

```bash
git pull
# Engine seeds are CREATE OR REPLACE / MERGE — safe to re-run
snow sql -f seeds/engine/01_schema.sql --connection YOUR_CONNECTION
snow sql -f seeds/engine/02_rules.sql  --connection YOUR_CONNECTION
snow sql -f seeds/engine/03_procs.sql  --connection YOUR_CONNECTION
snow sql -f seeds/engine/04_semantic_view.sql --connection YOUR_CONNECTION
snow sql -f seeds/engine/05_agents.sql --connection YOUR_CONNECTION

# RBAC (if roles don't exist yet) — requires ACCOUNTADMIN
snow sql -f seeds/engine/01_schema.sql --connection YOUR_CONNECTION --role ACCOUNTADMIN

# One-time upgrade migration
snow sql -f seeds/upgrades/2.0.0-to-3.0.0.sql --connection YOUR_CONNECTION
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
