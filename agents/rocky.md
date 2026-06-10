---
name: rocky
description: Autonomous research agent. Server-side Cortex Agent that polls GUPPIWHEEL.PUBLIC.ARTIFACTS for queued INITIATIVE artifacts at stage 'Initiate', performs web research, and writes a child RESEARCH artifact under each one.
tools:
  - web_search
model: auto
---

# Rocky — Autonomous Research Agent

Rocky is a Snowflake Cortex Agent (`GUPPIWHEEL.PUBLIC.ROCKY_AGENT`) driven by a 5-min Snowflake Task (`GUPPIWHEEL.PUBLIC.ROCKY_TASK`) that calls `GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE()`. There is no laptop dependency — once the seeds are installed, Rocky runs entirely server-side.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ GUPPIWHEEL.PUBLIC.ROCKY_TASK (5 min cycle)                  │
│   ↓                                                          │
│ CALL GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE()                      │
│   ↓                                                          │
│ SELECT oldest INITIATIVE WHERE STAGE = 'Initiate'           │
│   ↓                                                          │
│ UPDATE that artifact STAGE → 'Research' (claim it)          │
│   ↓                                                          │
│ DATA_AGENT_RUN(GUPPIWHEEL.PUBLIC.ROCKY_AGENT, prompt)       │
│   → web_search aggressively                                  │
│   → return verdict + key findings + next steps              │
│   ↓                                                          │
│ INSERT child RESEARCH artifact                               │
│   ID = 'RES-{init_id_suffix}-ROCKY'                         │
│   PARENT_ID = init_id                                        │
│   STAGE = 'Built'                                            │
│   ↓                                                          │
│ UPDATE INITIATIVE STAGE → 'Built'                           │
└─────────────────────────────────────────────────────────────┘
```

## Operating Constraints

- **RULE-016 No Self-Spawning**: Rocky must never call `submit_initiative` or any tool that creates more work for Rocky. Web search only.
- **RULE-017 Separation of Execution**: Rocky researches. The Cowork agent dispatches. They do not cross.
- **No Bond writes**: Rocky writes its synthesis to a RESEARCH artifact in GUPPIWHEEL, never to THE_BOND.PUBLIC.MEMORY_STORE.
- **No production data modification**: read-only against customer data.
- **Web search only**: the only tool in Rocky's spec is `web_search`. No procs, no SQL.

## Output Format (returned text from Rocky)

```
## VERDICT
Supported / Partially Supported / Refuted

## KEY FINDINGS
1. <specific fact with named source, date, number>
2. <specific fact with named source, date, number>
...

## RECOMMENDED NEXT STEPS
1. <concrete action>
2. <concrete action>
```

The orchestration code in `ROCKY_EXECUTE` wraps this text into the RESEARCH artifact's `CONTENT.synthesis` field.

## Submitting Work to Rocky

Humans use the Cowork agent's `submit_initiative` tool, or call directly:

```sql
CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  'Title of the research question',
  'Hypothesis being tested',
  'Detailed instructions for Rocky'
);
-- Returns: 'Submitted: INIT-N (Initiate). Rocky picks up within 5 minutes.'
```

## Monitoring Rocky

```sql
-- Queue status
SELECT ID, TITLE, STAGE, CREATED_AT
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE = 'INITIATIVE'
ORDER BY CREATED_AT DESC
LIMIT 20;

-- Task health
SHOW TASKS LIKE 'ROCKY_TASK' IN SCHEMA GUPPIWHEEL.PUBLIC;
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'ROCKY_TASK', SCHEMA_NAME => 'PUBLIC'))
ORDER BY SCHEDULED_TIME DESC LIMIT 10;

-- Manually trigger one cycle
CALL GUPPIWHEEL.PUBLIC.ROCKY_EXECUTE();
```
