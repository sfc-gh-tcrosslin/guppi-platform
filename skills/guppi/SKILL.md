# GUPPI — Unified Enterprise Platform

> Plan work. Do work. Track work. Verify work. Remember everything.

GUPPI is an AI-native SDLC + Ops + QA platform running entirely in Snowflake. One queryable database replaces Jira, ServiceNow, PagerDuty, and manual QA.

## Running the viewer

```bash
pip install -r skills/guppi/requirements.txt
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 skills/guppi/render_guppi.py --serve
```

Open http://localhost:8888. Two tabs:
- **Command Center** — SDLC view (epics, stories, defects, incidents, audits, initiatives)
- **Flywheel** — single-list initiative view; click to expand for child counts and the Open button on launchable artifacts

Without `--serve`, the script writes a static HTML to `~/Downloads/GUPPI.html` and exits.

## Setup (First Use)

Before creating any work items, configure your naming conventions:

1. Query `GUPPIWHEEL.PUBLIC.ID_CONVENTIONS` to see current rules
2. Each entity type has a PREFIX_PATTERN and NEXT_SEQ
3. When generating a new ID, read the pattern + increment NEXT_SEQ

**ID_CONVENTIONS table:**
| ENTITY | PREFIX_PATTERN | NEXT_SEQ | Notes |
|---|---|---|---|
| EPIC | E-{NNN} | auto | Global sequential |
| STORY_{PRODUCT} | {prefix}-{NNN} | auto | Product-specific prefix |
| DEFECT | {PRODUCT}-D{NNN} | auto | Product prefix + D |
| INCIDENT | INC-{NNN} | auto | Global |
| INITIATIVE | INIT-{NNN} | auto | Level 7 autonomous |
| AUDIT | {target_slug}-{YYYYMMDD} | N/A | Descriptive |

**When creating a new ID:** Always read NEXT_SEQ from ID_CONVENTIONS, use it, then UPDATE NEXT_SEQ = NEXT_SEQ + 1. Never guess or hardcode IDs.

**For new GUPPI adopters:** INSERT your own rows into ID_CONVENTIONS with your team's naming patterns before creating any entities.

## Headless Architecture

GUPPI has no webapp. No login screen. No UI server to deploy.

- **The database IS the application.** Snowflake tables are the system of record.
- **CoCo IS the interface.** You interact with GUPPI through conversation — "create a story", "show me P0 backlog", "log an incident". This skill translates intent to SQL.
- **HTML artifacts are read-only viewers.** The GUPPI.html file renders the DB state for visual review (meetings, standups, sharing). It's a report, not an input mechanism.
- **Any SQL client works.** Snowsight, dbt, Tableau, or raw SQL can query GUPPI directly. The skill just makes it conversational.

This means:
- Zero infrastructure to maintain (no app server, no auth layer, no session management)
- Instantly queryable by any tool that speaks SQL
- AI-native from day one — the agent reads/writes the same tables
- Scales to any team size without UI bottlenecks
- Auditable by default (Snowflake access history tracks every read/write)

## Architecture

```
GUPPI Database (Snowflake)
├── PUBLIC schema  — SDLC (epics, stories, sprints, templates)
├── OPS schema     — Operational incidents, post-mortems, runbooks
├── AUDITS schema  — TARS trust scores, findings, audit runs
└── QA schema      — Test suites, runs, model cards, coverage
```

## Intent Router

| User Says | Route To | Action |
|-----------|----------|--------|
| "show guppi", "refresh guppi", "open guppi" | viewer | Regenerate and open HTML viewer |
| "create story", "add to backlog", "log work" | `sdlc/` | Create/update stories |
| "what's the status", "show backlog", "priorities" | `sdlc/` | Query stories |
| "check templates", "what template", "before writing a US" | `sdlc/` | Template lookup |
| "log incident", "outage", "SEV1", "operational issue" | `ops/` | Create incident |
| "post-mortem", "root cause", "what happened" | `ops/` | Create/query post-mortems |
| "run audit", "trust score", "TARS" | `audits/` | Invoke TARS, store results |
| "test results", "QA run", "model card" | `qa/` | Record test outcomes |
| "submit initiative", "research this", "Rocky" | `platform/` | Submit/query initiatives |
| "add schema", "migrate", "new table" | `admin/` | Schema changes |

## Database: GUPPI

### PUBLIC Schema (SDLC)

**PRODUCTS** — top-level product registry
| Column | Type | Description |
|--------|------|-------------|
| PRODUCT_ID | TEXT PK | e.g., "F6-ENGINE", "HEALTHCARE-FORGE" |
| NAME | TEXT | Display name |
| DESCRIPTION | TEXT | What it does |
| STATUS | TEXT | ACTIVE, SUNSET |

**EPICS** — large user stories that have child stories underneath (NOT a product grouping)
| Column | Type | Description |
|--------|------|-------------|
| EPIC_ID | TEXT PK | e.g., "E-001" |
| PRODUCT_ID | TEXT FK | Links to product |
| NAME | TEXT | Epic title |
| DESCRIPTION | TEXT | Scope and goals |
| STATUS | TEXT | ACTIVE, DONE, DEFERRED |
| SORT_ORDER | NUMBER | Display order |

**What an Epic IS:** A large user story too big to complete in one sprint. It decomposes into child stories (in STORIES table via EPIC_ID FK). Think of it as a feature-level objective, not a product boundary.

**What an Epic is NOT:** A product. A team. A release. Those are separate concepts. An Epic belongs to a product and contains stories.

**STORIES** — work items (stories, defects, tech debt)
| Column | Type | Description |
|--------|------|-------------|
| STORY_ID | TEXT PK | Format: `{PREFIX}-{NNN}` (F6-020, AI-003, PLAT-005) |
| EPIC_ID | TEXT FK | Parent epic |
| TITLE | TEXT | One-line description |
| DESCRIPTION | TEXT | Full requirements, acceptance criteria |
| PRIORITY | TEXT | P0, P1, P2, HIGH, MED, LOW |
| STATUS | TEXT | BACKLOG, PLANNED, IN_PROGRESS, DONE |
| ASSIGNEE | TEXT | Who owns it |
| SPRINT | TEXT | Sprint identifier |
| STORY_POINTS | NUMBER | Effort estimate |
| STORY_TYPE | TEXT | STORY, DEFECT, TECH_DEBT |
| CREATED_AT | TIMESTAMP | Auto |
| UPDATED_AT | TIMESTAMP | Auto |

**Story ID Prefixes:**
- `F6-` = F6 Claims Engine
- `AI-` = ML Models
- `UI-` = Frontend/UX
- `DP-` = Data Pipeline
- `OPS-` = Operations
- `EL-` = Enrollment
- `PLAT-` = Platform tooling
- `CE-` = Claims Edits
- `DEF-` = Defects (legacy, prefer STORY_TYPE=DEFECT now)

### OPS Schema (Operational Incidents)

**INCIDENTS** — operational events (NOT defects — those are stories)
| Column | Type | Description |
|--------|------|-------------|
| INCIDENT_ID | TEXT PK | e.g., "INC-001" |
| PRODUCT_ID | TEXT | Affected product |
| SEVERITY | TEXT | SEV1, SEV2, SEV3 |
| STATUS | TEXT | DETECTED, MITIGATED, RESOLVED, CLOSED |
| TITLE | TEXT | What happened |
| DESCRIPTION | TEXT | Full details |
| DETECTED_AT | TIMESTAMP | When noticed |
| MITIGATED_AT | TIMESTAMP | When bleeding stopped |
| RESOLVED_AT | TIMESTAMP | When fully fixed |
| TIME_TO_DETECT_MIN | NUMBER | TTD metric |
| TIME_TO_MITIGATE_MIN | NUMBER | TTM metric |
| TIME_TO_RESOLVE_MIN | NUMBER | TTR metric |
| ROOT_CAUSE | TEXT | Why it happened |
| PREVENTIVE_ACTION | TEXT | How to prevent recurrence |
| PREVENTIVE_STORY_ID | TEXT | Story created to prevent |

**Key distinction:** Incidents are operational events with their own lifecycle. A defect is a code bug tracked as a story. An incident might PRODUCE a defect story but is not itself one.

### AUDITS Schema (TARS Trust)

**AUDIT_RUNS** — one per audit invocation
**AUDIT_FINDINGS** — one per check (C or D signal)

See `audits/README.md` for full schema. Managed by the `tars-trust-auditor` skill.

### PLATFORM Schema (Initiatives & Infrastructure)

**INITIATIVES** — Level 7 autonomous research tasks
| Column | Type | Description |
|--------|------|-------------|
| INITIATIVE_ID | TEXT PK | e.g., "INIT-001" |
| TITLE | TEXT | Short descriptive title |
| HYPOTHESIS | TEXT | Testable statement |
| INSTRUCTIONS | TEXT | Step-by-step for Rocky to execute |
| STATUS | TEXT | QUEUED, RUNNING, COMPLETE, FAILED |
| PRIORITY | TEXT | P1, P2 |
| SUBMITTED_BY | TEXT | HUMAN or agent name |
| SUBMITTED_AT | TIMESTAMP | Auto |
| STARTED_AT | TIMESTAMP | When Rocky picks it up |
| COMPLETED_AT | TIMESTAMP | When finished |
| RESULT | TEXT | Synthesis of findings |
| METRICS | VARIANT | Quantitative results |
| BOND_KEY | TEXT | Link to Bond entry |
| MAX_CALLS | NUMBER | LLM call ceiling (default 50) |
| CALLS_USED | NUMBER | Actual calls made |
| PARENT_INITIATIVE_ID | TEXT | For Level 7.1 recursive initiatives |
| STORIES_SPAWNED | TEXT | Story IDs created from findings |

**INITIATIVE_STEPS** — execution log per initiative
| Column | Type | Description |
|--------|------|-------------|
| STEP_ID | NUMBER PK | Auto-increment |
| INITIATIVE_ID | TEXT FK | Parent initiative |
| STEP_NUMBER | NUMBER | Sequential order |
| PROMPT | TEXT | What was asked |
| RESPONSE | TEXT | What LLM returned |
| MODEL_USED | TEXT | Default llama3.1-70b |
| TOKENS_USED | NUMBER | Token consumption |
| DURATION_MS | NUMBER | Step execution time |
| STATUS | TEXT | PENDING, COMPLETE, FAILED |
| CREATED_AT | TIMESTAMP | Auto |

**INITIATIVE_ARTIFACTS** — outputs from initiatives
| Column | Type | Description |
|--------|------|-------------|
| ARTIFACT_ID | NUMBER PK | Auto-increment |
| INITIATIVE_ID | TEXT FK | Parent initiative |
| ARTIFACT_TYPE | TEXT | TABLE, FUNCTION, DOCUMENT, METRIC |
| NAME | TEXT | What was created |
| LOCATION | TEXT | FQN or path |
| CREATED_AT | TIMESTAMP | Auto |

**ID_CONVENTIONS** — configurable naming patterns
| Column | Type | Description |
|--------|------|-------------|
| ENTITY | TEXT PK | e.g., INITIATIVE, EPIC, STORY_F6 |
| PREFIX_PATTERN | TEXT | Pattern with {NNN} placeholder |
| NEXT_SEQ | NUMBER | Auto-incremented on use |

**CODE_STAGE** — stage for procedure source files (e.g., execute_initiative.py)

**Rocky Infrastructure:**
- `ROCKY_EXECUTE()` — Python stored procedure that picks up QUEUED initiatives and executes via Cortex Complete
- `ROCKY_TASK` — Hourly scheduled task calling ROCKY_EXECUTE
- `SUBMIT_INITIATIVE(TITLE, HYPOTHESIS, INSTRUCTIONS)` — SQL procedure that inserts + triggers immediate execution via EXECUTE TASK
- `ROCKY_AGENT` — SI agent for mobile submission (generic tool calling SUBMIT_INITIATIVE)

**Level 7 Flow:**
Phone (SI) → Rocky Agent → SUBMIT_INITIATIVE → EXECUTE TASK → ROCKY_EXECUTE → Steps in DB → Results in GUPPI

### QA Schema (Test & Quality)

**Placeholder — tables TBD:**
- TEST_SUITES — named test collections
- TEST_RUNS — execution records with pass/fail counts
- TEST_RESULTS — individual test outcomes
- MODEL_CARDS — stored in product DBs, referenced from here

## Rules

### Rule 0: ALWAYS Write to the Database
Every user story, epic, defect, incident, or audit result discussed in conversation MUST be written to the GUPPI database via SQL INSERT/UPDATE. Never just discuss work items verbally — if it's worth mentioning, it's worth tracking. The database is the system of record, not the conversation.

### Rule 1: Check Templates Before Writing a US
Before creating any story, check if a template exists for that type of work. Templates define required fields and acceptance criteria patterns.

### Rule 2: Defects Block Features
If a conformance defect is found (STORY_TYPE=DEFECT, PRIORITY=P1), it must be resolved before feature work continues on the same component.

### Rule 3: Incidents Are Not Defects
Operational events (outage, data sync issue, stale cache) go in OPS.INCIDENTS. Code bugs go in PUBLIC.STORIES with STORY_TYPE=DEFECT.

### Rule 4: Model Cards in Product DBs
Model cards are product-specific artifacts stored in the product's database (e.g., NCPDP_F6.PUBLIC.MODEL_CARDS). GUPPI stories LINK to them, don't store them.

### Rule 5: Every Deploy Gets a Story Update
When a deploy happens, the corresponding story status updates to DONE and UPDATED_AT refreshes.

## Viewer (Pull-Based)

When user says "show guppi", "refresh guppi", or "open guppi":

1. Run `render_guppi.py` (queries GUPPI DB, generates HTML with embedded JSON)
2. Open the resulting file in IDE browser via `open_browser`

The viewer is READ-ONLY. All mutations happen via CoCo (headless). The HTML is a rendered report.

```bash
SNOWFLAKE_CONNECTION_NAME=HealthcareDemos python render_guppi.py
```

Output: `~/Downloads/GUPPI.html`

Scale design: embedded JSON + client-side filtering/pagination. Handles 10K+ stories without a server.

## Common Operations

### Create a Story
```sql
INSERT INTO GUPPI.PUBLIC.STORIES (STORY_ID, EPIC_ID, TITLE, DESCRIPTION, PRIORITY, STATUS, STORY_TYPE)
VALUES ('F6-021', 'E-001', 'Title here', 'Description...', 'P1', 'BACKLOG', 'STORY')
```

### Query Backlog by Product
```sql
SELECT s.STORY_ID, s.TITLE, s.PRIORITY, s.STATUS, e.NAME as EPIC
FROM GUPPI.PUBLIC.STORIES s
JOIN GUPPI.PUBLIC.EPICS e ON s.EPIC_ID = e.EPIC_ID
WHERE e.PRODUCT_ID = 'F6-ENGINE' AND s.STATUS != 'DONE'
ORDER BY s.PRIORITY, s.STORY_ID
```

### Log an Incident
```sql
INSERT INTO GUPPI.OPS.INCIDENTS (INCIDENT_ID, PRODUCT_ID, SEVERITY, STATUS, TITLE, DESCRIPTION, DETECTED_AT)
VALUES ('INC-003', 'F6-ENGINE', 'SEV2', 'DETECTED', 'Title', 'What happened...', CURRENT_TIMESTAMP())
```

### Get Next Story ID
```sql
SELECT MAX(CAST(SPLIT_PART(STORY_ID, '-', 2) AS INT)) + 1 
FROM GUPPI.PUBLIC.STORIES 
WHERE STORY_ID LIKE 'F6-%'
```

## Sub-Skill Files

| File | Purpose |
|------|---------|
| `sdlc/README.md` | Story creation, templates, sprint management |
| `ops/README.md` | Incident lifecycle, post-mortems, TTD/TTM/TTR |
| `audits/README.md` | TARS integration reference |
| `qa/README.md` | Test suites, model card storage, coverage |
| `admin/README.md` | Schema migrations, new table patterns |

## Tracker Backend Abstraction

GUPPI supports configurable tracker backends. Not everyone uses native GUPPI tables — enterprise teams may use Jira, ServiceNow, or Azure DevOps. The skill abstracts the backend so the Enterprise Build Profile works regardless.

### Configuration

On first use (or when no config is detected), determine the backend:

| Backend | Setup | Storage |
|---|---|---|
| **GUPPIWHEEL Native** (default) | Zero setup — direct SQL | GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE='STORY' |
| **Jira (MCP)** | Requires Jira MCP server connection | Jira project via API |
| **ServiceNow (MCP)** | Requires ServiceNow MCP connection | ServiceNow incidents/stories |
| **Manual** | No tracker — log to Bond only | THE_BOND.PUBLIC.MEMORY_STORE |

### Abstracted Verbs

All Enterprise Build Profile operations use these abstract verbs. The backend maps them to the correct API:

| Verb | GUPPI Native | Jira MCP | Manual (Bond only) |
|---|---|---|---|
| `create_story(title, desc, priority)` | `INSERT INTO STORIES` | `jira_create_issue(project, title, desc, priority)` | Bond entry with `CATEGORY='task_backlog'` |
| `update_story(id, status)` | `UPDATE STORIES SET STATUS` | `jira_transition_issue(id, status)` | Bond entry with milestone |
| `query_backlog(product)` | `SELECT FROM STORIES WHERE product AND STATUS != DONE` | `jira_search("project=X AND status!=Done")` | `SELECT FROM BOND WHERE CATEGORY='task_backlog'` |
| `log_audit_result(story, score)` | `INSERT INTO AUDIT_RUNS` | `jira_add_comment(story, "TARS Score: {score}")` | Bond entry with `CATEGORY='audit_result'` |
| `mark_complete(id)` | `UPDATE STORIES SET STATUS='DONE'` | `jira_transition_issue(id, 'Done')` | Bond milestone entry |

### TARS Auto-Integration

When TARS completes an audit, results are automatically logged to the configured tracker:

- **GUPPIWHEEL**: INSERT INTO GUPPIWHEEL.PUBLIC.ARTIFACTS with TYPE='AUDIT', trust score in CONTENT
- **Jira**: Add comment to the linked story with trust score breakdown
- **Manual**: Bond entry only (always written regardless of backend)

The engineer never manually logs audit results. The system handles it.

### MCP Connection Patterns

For Jira MCP:
```
MCP Server: jira-mcp (community or Atlassian official)
Auth: API token stored as Cortex secret
Capabilities: create_issue, search_issues, transition_issue, add_comment
```

For ServiceNow MCP:
```
MCP Server: servicenow-mcp
Auth: OAuth2 stored as Cortex secret
Capabilities: create_incident, update_record, query_table
```
