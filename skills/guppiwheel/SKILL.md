# GuppiWheel — Value Creation Engine

> Initiative → Research → Stories → Apps/Models → Heroes → Narratives → (loop)

GuppiWheel is the flywheel that tracks the full lifecycle of value creation. One table, one schema, lineage via parent_id. Every artifact progresses through stages. Templates are reusable. Spins are deployable.

## Guiding Principles (ENFORCE THESE)

1. **Headless First** — All outputs (research, proposals, narratives, briefs) MUST be written as artifacts in `GUPPIWHEEL.PUBLIC.ARTIFACTS` before any external render (Google Doc, HTML, slides, PDF). The flywheel is the source of truth. Render FROM artifacts, never instead of them. If the user asks for a "doc" or "proposal" or "brief" — the FIRST action is INSERT into the flywheel. Rendering is a SECOND, optional step.

2. **Raw → Structured → Queryable** — Anything unstructured with value (PDFs, fee schedules, research papers) gets ingested raw, parsed to structured, then made queryable. Never leave value trapped in a file.

3. **Server-Side First** — Logic lives in Snowflake (procs, tasks, rules, policies), not in client code. CoCo is the interface, not the engine.

4. **We Own Architecture, They Own Data** — Snowflake owns the intelligence architecture (flywheel, rules, agents). Customer owns their data. We never need their real data to demonstrate value.

5. **Rules Are Data** — Governance rules are rows in GUPPIWHEEL.PUBLIC.RULES, not hardcoded logic. They're versioned, queryable, and enforceable via ADVANCE_STAGE().

6. **Narrative Is First-Class** — Every spin must produce a NARRATIVE artifact. The story IS the deliverable. Viz, code, and models serve the narrative.

7. **Spins Compound** — Each spin makes the next one faster. Templates, patterns, and architecture are reusable. 50 IPs × 10 spins/month × 6 months = 3,000 synthetic industry twins.

8. **The Sphere** — Intelligence is omnidirectional, not linear. Any artifact can connect to any other. The flywheel is a circle; the full system is a sphere.

## Core Concepts

- **Artifact** — any first-class object in the flywheel (initiative, research, story, app, model, hero, narrative, skill, audit, memory)
- **Stage** — lifecycle position: Initiate → Research → Building → Built → Published
- **Spin** — one complete pass through the flywheel (initiative to narrative, ready to deploy)
- **Template** — reusable visualization pattern (Diverging Rivers, Parallel Futures, Waterfall, Sankey, Trajectory Archetypes)
- **Ecosystem** — PK's market taxonomy (60 categories, 600+ companies, CRM-validated)

## Database: GUPPIWHEEL

### ARTIFACTS Table

```sql
GUPPIWHEEL.PUBLIC.ARTIFACTS
├── ID          VARCHAR(36) PK — UUID or readable slug (e.g., 'ab-init-001')
├── TYPE        VARCHAR(20) — initiative, research, story, app, model, hero, narrative, skill, audit, defect, memory, ops_event, widget
├── STAGE       VARCHAR(20) — Initiate, Research, Building, Built, Published
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
  SELECT * FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :root_id
  UNION ALL
  SELECT a.* FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
  JOIN lineage l ON a.PARENT_ID = l.ID
)
SELECT ID, TYPE, STAGE, TITLE, PARENT_ID FROM lineage ORDER BY CREATED_AT;
```

## Creating Artifacts — proc-mediated (RULE-029). NEVER raw-INSERT.

Writes go through governed `EXECUTE AS OWNER` procs. Do **not** `INSERT INTO ARTIFACTS` directly
and do **not** hand-assign IDs — the registry allocates them.

### Decision tree
| You are creating… | Call | Notes |
|---|---|---|
| An **INITIATIVE** (research question for Rocky) | `SUBMIT_INITIATIVE(TITLE, HYPOTHESIS, INSTRUCTIONS)` | 3-arg, **always dup-gated**. Mints `INIT-N`. No product arg (product_id ends null → use TAGS). |

> **⚠️ Running Rocky = `SUBMIT_INITIATIVE` only (RULE-032, PLAT-D5).** Rocky is a server-side Cortex Agent (`ROCKY_TASK` polls every 5 min). Do **NOT** spawn a local `rocky` task subagent to research — it has no queue access, is unscoped, hits the ~25-min background cap, and writes nothing. On any Rocky miss/timeout, **re-enqueue and report** — never hand-author the RESEARCH artifact yourself (Rocky's output is SYSTEM-owned, `RES-{N}-ROCKY`; writing `RES-N` as a user is a governance leak). A Pass-2 on an already-`Built` initiative is a **fresh `SUBMIT_INITIATIVE`**.
| A **launchable** (NARRATIVE/APP/MODEL/DASHBOARD with a launch spec) | `PUBLISH_ARTIFACT(...)` | Something a human opens. |
| **Anything else** (RESEARCH, STORY, EPIC, OUTCOME, AUDIT…) | `CREATE_ARTIFACT(P_TYPE, P_TITLE, P_PRODUCT, P_CONTENT, P_PARENT_ID, P_STAGE, P_TAGS, P_EXPLICIT_ID, P_METADATA)` | Under a parent. Pass `P_CONTENT`/`P_METADATA`/`P_TAGS` as **JSON STRINGS** (`TO_JSON(OBJECT_CONSTRUCT(...))`). Leave `P_EXPLICIT_ID` empty. |
| A **WIDGET** (governed pointer to a reusable building block — a proc/UDF/HTML pattern/python) | `CREATE_ARTIFACT('WIDGET', P_TITLE, P_PRODUCT, P_CONTENT, P_PARENT_ID, ...)` | Global **`W-`** series. The artifact **points to** a canonical impl; it does **not** contain it. See "WIDGET — the single-source rule" below. |

**Stages are per-type.** Most types start at `Initiate`; a few differ — **OUTCOME** uses `ASPIRATIONAL → SELECTED → TRACKED → RESOLVED`, **DEFECT** starts at `Research`, **WIDGET** uses `Draft → Published → Deprecated`. As of **3.17.1**, `CREATE_ARTIFACT` defaults `P_STAGE` to the type's first registry stage (so OUTCOME → `ASPIRATIONAL` automatically) and **rejects a stage that isn't in that type's lifecycle**. Example:
```sql
CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(
  'OUTCOME', '<title>', NULL, '<content json>', '<parent_id>',
  'ASPIRATIONAL', '<tags json>', NULL, NULL
);
```

### Content bodies: structured JSON + `body_md` for prose (RULE-033)
`CONTENT` is a JSON object, and `CREATE_ARTIFACT` smart-routes `P_CONTENT` by the first non-whitespace char:
- **JSON object/array** (`{...}` / `[...]`) → stored structured as-is. Use top-level keys for small structured fields, e.g. `{"summary":"…","decision":"…","status":"PARKED"}`.
- **Plain text / markdown** (anything not starting with `{`/`[`) → auto-wrapped into `{"body_md":"<text>"}`. Hand-authored long-form prose goes here — no need to escape it into JSON by hand.
- **Malformed JSON** (starts with `{`/`[` but won't parse) → returns `{"error":"P_CONTENT is not valid JSON"}` and inserts **nothing**. No more silent `{}` bodies.

Mixing both? Put prose under a `body_md` key alongside your structured keys. The NARRATIVE renderer prefers `body_md`. **Verify after every write:** `SELECT LENGTH(CONTENT::STRING) FROM ARTIFACTS WHERE ID=…` (`2` = `{}` = empty = fail). Read large bodies back in slices with `GET_ARTIFACT_BODY(id, offset, len)` — the SQL client's cell cap is display-only; storage is a 16 MB VARIANT.

### Return-type gotchas (these have bitten us)
- `SUBMIT_INITIATIVE` and `MERGE_ARTIFACTS` return **VARCHAR** → do **NOT** wrap in `TO_JSON()` (errors "Invalid argument types for TO_JSON"; the CALL still ran). Read the string, or query the row back.
- `CREATE_ARTIFACT` returns **VARIANT** → read via `SELECT TO_JSON("CREATE_ARTIFACT") FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`.

### IDs / product scoping
- Global series (INITIATIVE→`INIT-N`) and product-scoped STORY series live in `ID_CONVENTIONS`. STORY is `ID_PRODUCT_SCOPED` → entity `STORY_<PRODUCT>`.
- **Platform/guppi tooling stories** use the `PLAT-N` series via an **explicit** `P_EXPLICIT_ID='PLAT-N'` with product `guppi` (the `STORY_GUPPI` series is unregistered — documented quirk; follow precedent, don't invent a new series mid-task).

### WIDGET — the single-source rule
A WIDGET is a **governed catalog entry that points to a reusable building block** (a proc, UDF, HTML pattern, python module, …) living anywhere in the account. The artifact carries the metadata; the impl lives in a library home (e.g. `GUPPI_LIB.LIB`) and is **referenced, not shipped in this plugin**.

**Content contract** (`P_CONTENT` JSON object):
```
{ "kind": "udf|proc|html|python|sql|...",
  "pointer": { "location_type": "snowflake_object|stage|repo", "ref": "<FQN or path>" },
  "signature": "<callable signature>",
  "inputs": [...], "outputs": [...], "requires": [...],
  "usage": "<how to call it>", "notes": "...", "version": "<semver>",
  "provenance": "<who built it / under which artifact>" }
```

**The rule (enforce this):** **one physical implementation + one WIDGET artifact.** A widget may appear in *many* contexts — never as a copy. Multi-surfacing is done with **tags + the pointer**, not duplication. Example: `W-1` (PARSE_DICOM) is tagged `imaging-dicom` **and** `guppi-showcase`, so it surfaces in the imaging catalog and the platform showcase from **one** row over **one** impl (`GUPPI_LIB.LIB.PARSE_DICOM`). Packaging: the owner of the canonical impl (core guppi = library steward) maintains it; domain packs **declare a dependency and reference the pointer** — they must not re-bundle the code.

### ⚠️ THE DEDUP RULE (RULE-031 — no unilateral dup-override)
`SUBMIT_INITIATIVE` HOLDs when a new initiative is `AI_SIMILARITY >= 0.80` to a live one, returning:
*"…resubmit with P_FORCE => TRUE. Otherwise add your work under INIT-N."*

- **On a HOLD, DEFAULT to adding your work under the named INIT-N.**
- **Only force (`P_FORCE=TRUE`) on EXPLICIT human approval, and it now REQUIRES a reason** (`P_FORCE_REASON`, stamped to `metadata.dup_override`).
- A "narrower scope" rationale **never** overrides an explicit "put it under INIT-N." (This is exactly how INIT-84 got wrongly spawned — see PLAT-31.)
- The force overload is **ADMIN-only**; the Cowork agent's tool cannot force by design.

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
SELECT * FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE ID = :root_id
   OR PARENT_ID = :root_id
   OR PARENT_ID IN (SELECT ID FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE PARENT_ID = :root_id)
ORDER BY CREATED_AT;
```

## RBAC

| Role | Access | Who |
|---|---|---|
| GUPPIWHEEL_VIEWER | Read only | Customers, stakeholders |
| GUPPIWHEEL_CONTRIBUTOR | Wheel writes ONLY via governed procs (no direct ARTIFACTS/RULES DML); read all | IPs; CoCo default |
| GUPPI_BUILDER | Elevate to create DBs/warehouses/SPCS/apps for MVPs; inherits CONTRIBUTOR; NO wheel DML | Builders |
| GUPPIWHEEL_ADMIN | Full CRUD, schema changes, doctrine | Todd |

## Operating posture (RULE-034)

CoCo operates as an **orchestrator**: default role `GUPPIWHEEL_CONTRIBUTOR`, every wheel change through the procs above, never `ACCOUNTADMIN` for wheel work, never raw DML on `ARTIFACTS`/`RULES`. Elevate deliberately — `USE ROLE GUPPI_BUILDER` to build MVPs (DBs/warehouses/SPCS/apps), `USE ROLE ACCOUNTADMIN` only as break-glass.

**Critical:** `USE ROLE` alone does NOT drop privilege if your identity holds admin — sessions default to `SECONDARY ROLES = ALL`, which keeps admin live regardless of the primary role. To actually constrain an admin-holder: `USE SECONDARY ROLES NONE` in-session, or durably `ALTER USER x SET DEFAULT_ROLE=GUPPIWHEEL_CONTRIBUTOR, DEFAULT_SECONDARY_ROLES=()`. Non-admin identities are constrained by RBAC directly. The binding control is the role/secondary-roles the connection holds — this guidance is not itself enforcement.

## Ecosystem Layer (PK's Taxonomy)

60 healthcare categories, 600+ companies. Cross-references spins to market segments.

```sql
-- "Which customers in Category 20 (Population Health) could use the Alberta spin?"
SELECT company, crm_status FROM GUPPIWHEEL.PUBLIC.ECOSYSTEM
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

1. CoCo queries GUPPIWHEEL.PUBLIC.ARTIFACTS to discover existing spins
2. CoCo reads this skill doc to understand the schema and operating model
3. CoCo uses `plugin-creator` to scaffold a local plugin from the DB state
4. IP is now "in the system" — can create artifacts, fork spins, contribute templates
