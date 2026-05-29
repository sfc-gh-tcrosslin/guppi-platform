# GuppiWheel — Value Creation Engine

> Initiative → Research → Stories → Apps/Models → Heroes → Narratives → (loop)

GuppiWheel is the flywheel that tracks the full lifecycle of value creation. One table, one schema, lineage via parent_id. Every artifact progresses through stages. Templates are reusable. Spins are deployable.

## Core Concepts

- **Artifact** — any first-class object in the flywheel (initiative, research, story, app, model, hero, narrative, skill, audit, memory)
- **Stage** — lifecycle position: spark → active → built → proven → told → archived
- **Spin** — one complete pass through the flywheel (initiative to narrative, ready to deploy)
- **Template** — reusable visualization pattern (Diverging Rivers, Parallel Futures, Waterfall, Sankey, Trajectory Archetypes)
- **Ecosystem** — PK's market taxonomy (60 categories, 600+ companies, CRM-validated)

## Database: FLYWHEEL

### ARTIFACTS Table

```sql
FLYWHEEL.PUBLIC.ARTIFACTS
├── ID          VARCHAR(36) PK — UUID or readable slug (e.g., 'ab-init-001')
├── TYPE        VARCHAR(20) — initiative, research, story, app, model, hero, narrative, skill, audit, defect, memory, ops_event
├── STAGE       VARCHAR(20) — spark, active, built, proven, told, archived
├── PARENT_ID   VARCHAR(36) — lineage: what produced this artifact
├── TITLE       VARCHAR(500)
├── CONTENT     VARIANT — flexible payload per type
├── TAGS        ARRAY
├── OWNER       VARCHAR(200)
├── CREATED_AT  TIMESTAMP_NTZ
├── UPDATED_AT  TIMESTAMP_NTZ
└── METADATA    VARIANT — type-specific fields (priority, score, app_type, etc.)
```

### Semantic Views

Each view filters ARTIFACTS by TYPE and extracts relevant METADATA fields:

- `INITIATIVES_V` — TYPE='initiative', extracts status, priority
- `RESEARCH_V` — TYPE='research', extracts source, verdict
- `STORIES_V` — TYPE='story', extracts priority, points
- `APPS_V` — TYPE IN ('app','model'), extracts app_type, url
- `HEROES_V` — TYPE='hero', extracts outcome, metrics
- `NARRATIVES_V` — TYPE='narrative', extracts narrative_type, audience
- `SKILLS_V` — TYPE='skill', extracts skill_status
- `MEMORIES_V` — TYPE='memory', extracts context
- `AUDITS_V` — TYPE='audit', extracts trust_score, verdict

## Lineage

Parent_id creates a DAG. Query any artifact's full chain:

```sql
-- Get full lineage from an initiative
WITH RECURSIVE lineage AS (
  SELECT * FROM FLYWHEEL.PUBLIC.ARTIFACTS WHERE ID = :root_id
  UNION ALL
  SELECT a.* FROM FLYWHEEL.PUBLIC.ARTIFACTS a
  JOIN lineage l ON a.PARENT_ID = l.ID
)
SELECT ID, TYPE, STAGE, TITLE, PARENT_ID FROM lineage ORDER BY CREATED_AT;
```

## Creating Artifacts

Always use readable IDs with a prefix pattern:

- Initiatives: `{region}-init-{NNN}` (e.g., ab-init-001)
- Research: `{region}-research-{NNN}`
- Stories: `{region}-story-{NNN}`
- Apps: `{region}-app-{NNN}`
- Heroes: `{region}-hero-{NNN}`
- Narratives: `{region}-narr-{NNN}`

```sql
INSERT INTO FLYWHEEL.PUBLIC.ARTIFACTS (ID, TYPE, STAGE, PARENT_ID, TITLE, CONTENT, TAGS, OWNER, METADATA)
SELECT '{id}', '{type}', '{stage}', '{parent_id}', '{title}',
  OBJECT_CONSTRUCT('key1','val1','key2','val2'),
  ARRAY_CONSTRUCT('tag1','tag2'),
  '{owner}',
  OBJECT_CONSTRUCT('priority','P0','points',3);
```

## Visualization Template Library

Reusable viz patterns — same engine, different data, different story:

| Template | Best For | Example |
|---|---|---|
| Diverging Rivers | Before/after policy scenarios | Alberta fee reform trajectories |
| Parallel Futures | Same entities, different interventions | Physicians under baseline vs reform |
| Waterfall Impact | Cumulative executive summary | Total spend → levers → net savings |
| Sankey Flow | Flow redistribution | Billing archetype → reformed outcome |
| Trajectory Archetypes | Behavioral patterns over time | AC population health life-course |

Templates stored in: `/alberta-specialist-cost/` (and future per-region dirs)

## Spins (Deployable Packages)

A spin = one complete flywheel pass, ready to package for a customer:

1. **Identify the spin** — all artifacts sharing a root initiative
2. **Package** — SQL script (schema + seed data) + viz HTML + agent config
3. **Deploy** — to customer's Snowflake account or GitHub repo
4. **Fork** — copy a spin for a new region/customer, swap the data

```sql
-- Find all artifacts in a spin
SELECT * FROM FLYWHEEL.PUBLIC.ARTIFACTS
WHERE ID = :root_id
   OR PARENT_ID = :root_id
   OR PARENT_ID IN (SELECT ID FROM FLYWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :root_id)
ORDER BY CREATED_AT;
```

## RBAC

| Role | Access | Who |
|---|---|---|
| GUPPIWHEEL_ADMIN | Full CRUD, schema changes | Todd |
| GUPPIWHEEL_CONTRIBUTOR | Insert/update artifacts, read all | IPs (PK, etc.) |
| GUPPIWHEEL_VIEWER | Read only | Customers, stakeholders |

## Ecosystem Layer (PK's Taxonomy)

60 healthcare categories, 600+ companies. Cross-references spins to market segments.

```sql
-- "Which customers in Category 20 (Population Health) could use the Alberta spin?"
SELECT company, crm_status FROM FLYWHEEL.PUBLIC.ECOSYSTEM
WHERE category_id = 20 AND crm_status = 'customer';
```

## Relationship to GUPPI

- **GUPPI** = the Command Center (backlog, defects, ops, audits, QA, initiatives)
- **GuppiWheel** = the Value Creation Engine (flywheel lifecycle, templates, spins, ecosystem)
- They coexist: GUPPI is operational, GuppiWheel is strategic
- GUPPI HTML viewer has a "Flywheel" global tab showing GuppiWheel data
- Champion/challenger: GUPPI is the champion, GuppiWheel is the challenger for unified architecture

## Bootstrap (For New IPs)

When a new IP connects their CoCo to this Snowflake account:

1. CoCo queries FLYWHEEL.PUBLIC.ARTIFACTS to discover existing spins
2. CoCo reads this skill doc to understand the schema and operating model
3. CoCo uses `plugin-creator` to scaffold a local plugin from the DB state
4. IP is now "in the system" — can create artifacts, fork spins, contribute templates
