# GUPPI — AI-Native SDLC Platform

> Plan work. Do work. Track work. Verify work. Remember everything.

GUPPI is a headless SDLC + Ops + QA platform running entirely in Snowflake. The database is the application. Conversation is the interface.

## Headless Architecture

GUPPI has no webapp. No login screen. No UI server to deploy.

- **The database IS the application.** Snowflake tables are the system of record.
- **CoCo IS the interface.** You interact through conversation — "create a story", "show me P0 backlog", "log an incident". This skill translates intent to SQL.
- **HTML artifacts are read-only viewers.** The GUPPI.html file renders the DB state for visual review (meetings, standups, sharing). It's a report, not an input mechanism.
- **Any SQL client works.** Snowsight, dbt, Tableau, or raw SQL can query GUPPI directly.

This means:
- Zero infrastructure to maintain
- Instantly queryable by any tool that speaks SQL
- AI-native from day one
- Scales to any team size without UI bottlenecks
- Auditable by default (Snowflake access history tracks every read/write)

## Database Schema

```
GUPPI Database (Snowflake)
└── PLATFORM schema
    ├── PRODUCTS        — Product registry
    ├── EPICS           — Feature groupings
    ├── STORIES         — Work items (backlog, in progress, done)
    ├── DEFECTS         — Bugs with severity, repro steps, related stories
    ├── INCIDENTS       — Operational events (SEV1/2/3, TTD/TTM/TTR)
    ├── AUDIT_RUNS      — TARS trust scores per audit
    ├── AUDIT_FINDINGS  — Individual check results (C/D signals)
    ├── QA_RUNS         — Test suite execution history
    └── QA_DASHBOARD    — Real-time gate status view
```

## Intent Router

| User Says | Action |
|-----------|--------|
| "show guppi", "refresh guppi", "open guppi" | Regenerate and open HTML viewer |
| "create story", "add to backlog", "log work" | Create/update stories |
| "what's the status", "show backlog", "priorities" | Query stories |
| "log incident", "outage", "SEV1" | Create incident |
| "run audit", "trust score", "TARS" | Invoke TARS, store results |
| "test results", "QA run" | Record test outcomes |

## Story Management

### Create a Story
```sql
INSERT INTO GUPPI.PLATFORM.STORIES 
(STORY_ID, EPIC_ID, TITLE, DESCRIPTION, PRIORITY, STATUS, CREATED_AT, UPDATED_AT)
VALUES (:id, :epic, :title, :desc, :priority, 'BACKLOG', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())
```

Story IDs follow the pattern: `{PRODUCT_PREFIX}-{NUMBER}` (e.g., `PLAT-001`, `F6-042`)

### Update Status
```sql
UPDATE GUPPI.PLATFORM.STORIES 
SET STATUS = :new_status, UPDATED_AT = CURRENT_TIMESTAMP()
WHERE STORY_ID = :id
```

Valid statuses: `BACKLOG` → `PLANNED` → `IN_PROGRESS` → `DONE`

### Query Backlog
```sql
SELECT STORY_ID, TITLE, PRIORITY, STATUS, ASSIGNEE
FROM GUPPI.PLATFORM.STORIES
WHERE STATUS NOT IN ('DONE')
ORDER BY PRIORITY, CREATED_AT
```

## Incident Management

### Log an Incident
```sql
INSERT INTO GUPPI.PLATFORM.INCIDENTS
(INCIDENT_ID, PRODUCT_ID, SEVERITY, STATUS, TITLE, DESCRIPTION, DETECTED_AT, DETECTED_BY)
VALUES (:id, :product, :severity, 'DETECTED', :title, :desc, CURRENT_TIMESTAMP(), :detected_by)
```

Severity: `SEV1` (critical), `SEV2` (degraded), `SEV3` (minor), `INFO`

### Resolve with Metrics
```sql
UPDATE GUPPI.PLATFORM.INCIDENTS
SET STATUS = 'RESOLVED',
    RESOLVED_AT = CURRENT_TIMESTAMP(),
    ROOT_CAUSE = :root_cause,
    PREVENTIVE_ACTION = :preventive,
    TIME_TO_DETECT_MIN = DATEDIFF('minute', DETECTED_AT, MITIGATED_AT),
    TIME_TO_MITIGATE_MIN = DATEDIFF('minute', DETECTED_AT, MITIGATED_AT),
    TIME_TO_RESOLVE_MIN = DATEDIFF('minute', DETECTED_AT, CURRENT_TIMESTAMP())
WHERE INCIDENT_ID = :id
```

## Defect Management

### Log a Defect
```sql
INSERT INTO GUPPI.PLATFORM.DEFECTS
(DEFECT_ID, EPIC_ID, TITLE, DESCRIPTION, SEVERITY, PRIORITY, STATUS, 
 FOUND_IN_VERSION, REPRODUCTION_STEPS, REPORTED_BY, RELATED_STORY_ID, CREATED_AT, UPDATED_AT)
VALUES (:id, :epic, :title, :desc, :severity, :priority, 'OPEN',
 :version, :repro, :reporter, :related_story, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())
```

## QA Integration

### Run Golden Tests
```sql
CALL SEYMOUR_RUN_GOLDEN_TESTS('MANUAL')
-- Returns: total_tests, passed, failed, gate_status (OPEN/BLOCKED)
-- Auto-logs to GUPPI.PLATFORM.QA_RUNS
```

### Check Gate Status
```sql
SELECT * FROM GUPPI.PLATFORM.QA_DASHBOARD
-- Returns: gate_status, golden_passed/failed, canary checks, run history
```

## TARS Integration

TARS (bundled separately) stores audit results directly into GUPPI:

```sql
-- TARS writes here after each audit
INSERT INTO GUPPI.PLATFORM.AUDIT_RUNS (TARGET_NAME, TARGET_TYPE, TRUST_SCORE, GRADE, C_SIGNALS, D_SIGNALS, ...)
-- Individual findings
INSERT INTO GUPPI.PLATFORM.AUDIT_FINDINGS (AUDIT_ID, CHECK_NAME, SIGNAL, TIER, WEIGHT, EVIDENCE, ...)
```

When TARS completes an audit, results appear in the GUPPI viewer's Audits tab automatically.

## HTML Viewer

The viewer is a rendered report — not a live app. Generate it with:

```bash
python render_guppi.py          # Render to ~/Downloads/GUPPI.html
python render_guppi.py --open   # Render and open in browser
```

Tabs: Backlog | Defects | Ops | Audits | QA

The viewer:
- Remembers your last tab (localStorage)
- Filters by product, status, search
- Shows expandable detail for every item
- Renders QA gate status with golden test results

## Templates

Before creating stories, check if a template exists:

| Template | Fields |
|---|---|
| Feature | title, acceptance criteria, dependencies |
| Bug | title, severity, repro steps, expected vs actual |
| Ops Task | title, schedule, autonomy level, verification method |
| Research | title, hypothesis, method, success criteria |

## Viewer Regeneration

After any mutation (create, update, close), offer to regenerate the viewer:
"Want me to refresh the GUPPI viewer?"

This keeps the HTML current without auto-refresh overhead.
