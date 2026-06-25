# GuppiWheel Bootstrap — Self-Generating Plugin from DB State

> Connect → Discover → Generate → You're in the system.

This skill bootstraps a new CoCo into the GuppiWheel platform by reading the shared Snowflake database and generating a local plugin with full context.

## When to Use

- First time connecting to the GuppiWheel Snowflake account
- After significant platform changes (new templates, new spins)
- When another IP says "just bootstrap from the DB"

## Bootstrap Flow

### Step 0: Run Seeds (First-Time Only)

If the GUPPIWHEEL database does not exist on this account, run the seed scripts in order:

```bash
# From the plugin root (run by the account ADMIN):
snowsql -f seeds/engine/01_schema.sql   # Creates GUPPIWHEEL DB, ARTIFACTS, RULES, VIOLATIONS, views, RBAC (born-locked per RULE-028)
snowsql -f seeds/engine/02_rules.sql    # Seeds platform rules (MERGE — safe to re-run)
snowsql -f seeds/engine/03_procs.sql    # Creates the procedures (ADVANCE_STAGE gate, SUBMIT_INITIATIVE, PUBLISH_ARTIFACT, UPDATE_OWN_ARTIFACT — all EXECUTE AS OWNER)
snowsql -f seeds/engine/04_semantic_view.sql
snowsql -f seeds/engine/05_agents.sql
```

These are idempotent (CREATE IF NOT EXISTS, MERGE). Safe to re-run on an existing account to pick up new rules.

**After seeding, verify the lockdown.** The seed ships born-locked (contributors write only through procedures; doctrine RULES is admin-only). Invoke the `guppiwheel-governance` skill to AUDIT the install and confirm — or to remediate an older account that pre-dates the born-locked seed.

### Step 1: Verify Connection

```sql
SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE();
-- Expect: role = GUPPIWHEEL_CONTRIBUTOR or GUPPIWHEEL_ADMIN
-- Note: CONTRIBUTOR writes only through procedures (no direct ARTIFACTS/RULES DML) per RULE-028.
```

### Step 2: Discover Platform State

```sql
-- What's in the wheel?
SELECT TYPE, STAGE, COUNT(*) as cnt
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
GROUP BY TYPE, STAGE ORDER BY TYPE, STAGE;

-- What initiatives exist?
SELECT ID, TITLE, OWNER, CREATED_AT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE = 'INITIATIVE' ORDER BY CREATED_AT DESC;

-- What templates are registered?
SELECT ID, TITLE, METADATA:app_type::VARCHAR as viz_type
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE IN ('APP','MODEL') AND ARRAY_CONTAINS('reusable-template'::VARIANT, TAGS);

-- What skills are in the registry?
SELECT SKILL_NAME, DOMAIN, DESCRIPTION
FROM SKILL_REGISTRY.PUBLIC.SKILLS ORDER BY DOMAIN;

-- What's in the ecosystem?
SELECT COUNT(*) FROM GUPPIWHEEL.ECOSYSTEM.TAXONOMY; -- (when table exists)
```

### Step 3: Generate Local Plugin

Use the `plugin-creator` skill to scaffold:

**Plugin Name:** `guppiwheel-{username}`
**Skills to include:**
- `guppiwheel` (copy SKILL.md from DB or from this plugin's skill)
- `guppi` (command center operations)
- `tars-trust-auditor` (audit any artifact)
- `the-bond` (shared memory)

**Agents to include:**
- `rocky.md` (autonomous research executor)
- `tars.md` (trust auditor)

**References to include:**
- `maturity-model.md` (7 levels)
- `trust-equation.md` (Love Equation)

### Step 4: Confirm Bootstrap

After generation, verify:

```sql
-- Log bootstrap event
INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS (ID, TYPE, STAGE, TITLE, TAGS, OWNER, METADATA)
SELECT
  CONCAT(LOWER(CURRENT_USER()), '-bootstrap-', TO_VARCHAR(CURRENT_DATE(), 'YYYYMMDD')),
  'OPS_EVENT', 'Narrated',
  CONCAT('Bootstrap: ', CURRENT_USER(), ' joined GuppiWheel'),
  ARRAY_CONSTRUCT('bootstrap', 'onboarding', 'platform'),
  CURRENT_USER(),
  OBJECT_CONSTRUCT('event', 'bootstrap', 'role', CURRENT_ROLE(), 'timestamp', CURRENT_TIMESTAMP());
```

## What the IP Gets After Bootstrap

1. Local plugin with all skill context (schema knowledge, operating model)
2. Awareness of existing spins they can fork
3. Ability to create new artifacts, run Rocky, invoke TARS
4. Connection to the shared ecosystem taxonomy
5. Their CoCo "speaks GuppiWheel" — understands types, stages, lineage, templates

## Self-Updating

The plugin generated from DB state is a **snapshot**. To refresh:
- Re-run bootstrap (overwrites local skill docs with latest from DB)
- Or: pull from GitHub (sfc-gh-tcrosslin/guppi-platform) for the canonical version

The DB is the source of truth. GitHub is the distribution cache. Local plugin is the working copy.
