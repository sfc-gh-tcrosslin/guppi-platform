# GuppiWheel Bootstrap — Self-Generating Plugin from DB State

> Connect → Discover → Generate → You're in the system.

This skill bootstraps a new CoCo into the GuppiWheel platform by reading the shared Snowflake database and generating a local plugin with full context.

## When to Use

- First time connecting to the GuppiWheel Snowflake account
- After significant platform changes (new templates, new spins)
- When another IP says "just bootstrap from the DB"

## Bootstrap Flow

### Step 0: Run Seeds (First-Time Only)

If the FLYWHEEL database does not exist on this account, run the seed scripts in order:

```bash
# From the plugin root:
snowsql -f seeds/01_schema.sql    # Creates FLYWHEEL DB, ARTIFACTS, RULES, VIOLATIONS, views, RBAC
snowsql -f seeds/02_rules.sql     # Seeds all 13 platform rules (MERGE — safe to re-run)
snowsql -f seeds/03_advance_stage.sql  # Creates the universal gate procedure
```

These are idempotent (CREATE IF NOT EXISTS, MERGE). Safe to re-run on an existing account to pick up new rules.

### Step 1: Verify Connection

```sql
SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE();
-- Expect: role = GUPPIWHEEL_CONTRIBUTOR or GUPPIWHEEL_ADMIN
```

### Step 2: Discover Platform State

```sql
-- What's in the flywheel?
SELECT TYPE, STAGE, COUNT(*) as cnt
FROM FLYWHEEL.PUBLIC.ARTIFACTS
GROUP BY TYPE, STAGE ORDER BY TYPE, STAGE;

-- What spins exist?
SELECT ID, TITLE, OWNER, CREATED_AT
FROM FLYWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE = 'initiative' ORDER BY CREATED_AT DESC;

-- What templates are registered?
SELECT ID, TITLE, METADATA:app_type::VARCHAR as viz_type
FROM FLYWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE = 'app' AND TAGS @> ARRAY_CONSTRUCT('reusable-template');

-- What skills are in the registry?
SELECT SKILL_NAME, DOMAIN, DESCRIPTION
FROM SKILL_REGISTRY.PUBLIC.SKILLS ORDER BY DOMAIN;

-- What's in the ecosystem?
SELECT COUNT(*) FROM FLYWHEEL.PUBLIC.ECOSYSTEM; -- (when table exists)
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
- Or: pull from GitHub (JacinthLaval/guppi-platform) for the canonical version

The DB is the source of truth. GitHub is the distribution cache. Local plugin is the working copy.
