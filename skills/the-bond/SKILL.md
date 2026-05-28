---
name: the-bond
description: "Shared cognitive layer between human and agent. Stores co-created knowledge, decisions, corrections, and synthesis in Snowflake. Enables persistent memory across sessions, cross-agent context sharing, and session tracking. Use when: starting a session, recording an insight, searching past knowledge, sharing context with another agent, tracking session duration. Triggers: the bond, shared memory, what do we know about, remember this, session start, co-created, correction."
---

# The Bond — Shared Cognitive Layer

> Trust is the shared binding energy between agents and humans. The Bond is where it lives.
> — dE/dt = β(C-D)E

Persistent shared memory between human and agent, backed by Snowflake. Not a "second brain" (tool-for-human) — a common brain where co-created knowledge lives.

## Operating Model: Model A (revised)

Automatic pull at startup. Manual writes during session.

### Session Start Protocol (AUTOMATIC — do this every session without being asked)

On every new session, BEFORE doing anything else:

1. Run the sync pull:
```bash
SNOWFLAKE_CONNECTION_NAME=HealthcareDemos python3 /Users/toddcrosslin/Downloads/CoCoStuff/skill-registry-mcp/bond_sync.py pull
```

2. Record session start:
```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
SELECT 'coco', 'session_tracking', 'session-{N}-start',
PARSE_JSON('{"session": {N}, "started_at": "' || CURRENT_TIMESTAMP()::STRING || '", "platform": "SnowWork Desktop"}'),
ARRAY_CONSTRUCT('session', 'tracking'), 'coco', 'discovery', 'session-{N}'
```

3. Check for cross-agent updates since last session:
```sql
SELECT AGENT_ID, KEY, CONTENT, INSIGHT_TYPE, CREATED_AT
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE AGENT_ID != 'coco'
AND CREATED_AT > (SELECT MAX(CONTENT:started_at::TIMESTAMP_NTZ) FROM THE_BOND.PUBLIC.MEMORY_STORE WHERE KEY LIKE 'session-%-start' AND AGENT_ID = 'coco')
ORDER BY CREATED_AT DESC
```

### During Session (MANUAL — only when asked or explicitly triggered)

Writes to The Bond happen only when:
- Human says "put this in The Bond" or "remember this"
- Human says "that was a correction" or "capture that insight"
- End of session wrap-up when asked

2. Load current context:
```sql
SELECT CATEGORY, KEY, CONTENT, ORIGIN, INSIGHT_TYPE
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE SUPERSEDED_BY IS NULL
ORDER BY UPDATED_AT DESC
LIMIT 50
```

3. Check for cross-agent updates since last session:
```sql
SELECT AGENT_ID, KEY, CONTENT, INSIGHT_TYPE, CREATED_AT
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE AGENT_ID != '{my_agent_id}'
AND CREATED_AT > '{last_session_end}'
ORDER BY CREATED_AT DESC
```

### Session End Protocol

Before session ends or when context is getting long:

```sql
UPDATE THE_BOND.PUBLIC.MEMORY_STORE
SET CONTENT = OBJECT_INSERT(CONTENT, 'ended_at', CURRENT_TIMESTAMP()::STRING, true),
    CONTENT = OBJECT_INSERT(CONTENT, 'topics_covered', PARSE_JSON('{topics_array}'), true)
WHERE KEY = 'session-{N}-start'
```

## When to Write

### Always Write (auto)

- **Corrections**: Human redirects agent thinking. Highest signal.
- **Decisions**: We chose X over Y, and here's why.
- **Synthesis**: A new insight that neither human nor agent had alone.
- **Architecture changes**: Something fundamental shifted (e.g. "dropped SPCS container").

### Write If Significant

- **Discoveries**: Found something useful in research or debugging.
- **Error patterns**: A bug and its fix that we'd want to avoid next time.
- **Relationship changes**: New accounts, services, repos, agents added.

### Don't Write

- Routine task completion ("updated README")
- Temporary debugging steps
- Information already captured in code/docs/commits

## How to Write

Every entry needs three attribution fields:

### ORIGIN — Who contributed

| Value | When |
|-------|------|
| `human` | Human provided the insight, correction, or direction |
| `coco` | Agent discovered, synthesized, or generated it |
| `bea` | Account B agent contributed |
| `co-created` | Emerged from the conversation — neither had it alone |

### INSIGHT_TYPE — What kind of knowledge

| Value | When |
|-------|------|
| `decision` | We chose X over Y |
| `discovery` | Found something new |
| `correction` | Human redirected agent thinking |
| `synthesis` | Novel insight from combining perspectives |

### SESSION_CONTEXT — Where it came from

Format: `session-{N}` or `session-{N}-{topic}` for specificity.

## Example Entries

### Correction (highest signal)
```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'decision_log', 'pharmacy-claims-not-postgres',
  PARSE_JSON('{"what_i_said": "pharmacy systems speak Postgres", "correction": "they speak NCPDP over TCP/HTTPS to telecom switches", "lesson": "never assume transport layer from database choice"}'),
  ARRAY_CONSTRUCT('ncpdp', 'correction', 'architecture'),
  'human', 'correction', 'session-38')
```

### Co-created Synthesis
```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'decision_log', 'skill-is-the-client',
  PARSE_JSON('{"insight": "The skill IS the client IS the collaboration invite. No separate app needed.", "how_it_emerged": "Todd asked about sharing, CoCo proposed MCP, Todd said the skill should bootstrap the connection, synthesis: the skill contains everything needed to participate"}'),
  ARRAY_CONSTRUCT('skill-registry', 'architecture', 'co-created'),
  'co-created', 'synthesis', 'session-38')
```

## How to Search

### Structured lookup (known key)
```sql
SELECT CONTENT FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE KEY = 'app-service-mapping' AND SUPERSEDED_BY IS NULL
```

### Category browse
```sql
SELECT KEY, CONTENT:summary::STRING, ORIGIN, INSIGHT_TYPE
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE CATEGORY = 'decision_log' AND SUPERSEDED_BY IS NULL
ORDER BY UPDATED_AT DESC
```

### Semantic search (fuzzy recall)
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'THE_BOND.PUBLIC.MEMORY_SEARCH',
  '{"query": "how does SPCS auth work cross-account?", "columns": ["TITLE","CATEGORY","SOURCE_FILE"], "limit": 3}'
)
```

### Co-created insights only
```sql
SELECT KEY, CONTENT, SESSION_CONTEXT
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE ORIGIN = 'co-created' AND INSIGHT_TYPE = 'synthesis'
ORDER BY CREATED_AT DESC
```

### Cross-agent context
```sql
SELECT AGENT_ID, KEY, CONTENT, CREATED_AT
FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE AGENT_ID != 'coco' AND SUPERSEDED_BY IS NULL
ORDER BY CREATED_AT DESC
```

## Versioning

Never UPDATE content. INSERT a new row and point the old one's SUPERSEDED_BY to the new MEMORY_ID:

```sql
UPDATE THE_BOND.PUBLIC.MEMORY_STORE
SET SUPERSEDED_BY = '{new_id}'
WHERE KEY = '{key}' AND SUPERSEDED_BY IS NULL;

INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, ...)
VALUES (...)
```

Query current state with `WHERE SUPERSEDED_BY IS NULL`. Query history by removing that filter.

## Cross-Agent Sharing

The Bond can be shared to other accounts via Snowflake data share — same pattern as the skill registry. Other agents read the shared Bond, gain full context of past sessions, decisions, and co-created knowledge.

Write-back uses SQL API + scoped PAT — same pattern as skill registry CONTRIBUTIONS.

## Auto-Fire Rules (Enterprise Build Profile Integration)

Bond writes are triggered automatically by the Enterprise Build Profile. These are NOT optional — they fire without being asked.

| Trigger | Detection | Category | Insight Type | Origin |
|---|---|---|---|---|
| **Correction** | User contradicts/redirects agent | `decision_log` | `correction` | `human` |
| **TARS audit** | After any TARS run completes | `audit_result` | `discovery` | `coco` |
| **Story ships** | Feature deployed/confirmed working | `milestone` | `discovery` | `coco` |
| **Session start** | Every new session | `session_tracking` | `discovery` | `coco` |
| **Session end** | Wrap-up or context limit | `session_tracking` | (update existing) | `coco` |
| **Synthesis** | Co-created insight emerges from dialogue | `decision_log` | `synthesis` | `co-created` |

### Correction (highest priority — write IMMEDIATELY)

```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'decision_log', '{descriptive-key}',
  PARSE_JSON('{"what_i_said": "...", "correction": "...", "lesson": "..."}'),
  ARRAY_CONSTRUCT('{product}', 'correction'), 'human', 'correction', 'session-{N}')
```

### TARS Audit Result

```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'audit_result', 'tars-{artifact}-{date}',
  PARSE_JSON('{"artifact": "...", "trust_score": N, "cooperative_signals": N, "defection_signals": N, "version": "...", "recommendation": "..."}'),
  ARRAY_CONSTRUCT('{product}', 'tars', 'audit'), 'coco', 'discovery', 'session-{N}')
```

### Milestone (Story Shipped)

```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'milestone', '{story-id}-complete',
  PARSE_JSON('{"story_id": "...", "title": "...", "version": "...", "shipped_at": "...", "product": "..."}'),
  ARRAY_CONSTRUCT('{product}', 'milestone', 'shipped'), 'coco', 'discovery', 'session-{N}')
```

### Co-Created Synthesis

```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
VALUES ('coco', 'decision_log', '{descriptive-key}',
  PARSE_JSON('{"insight": "...", "how_it_emerged": "user said X, agent said Y, together we realized Z"}'),
  ARRAY_CONSTRUCT('{product}', 'co-created', 'synthesis'), 'co-created', 'synthesis', 'session-{N}')
```

## Bond-as-Inspiration (Planning Phase)

Before planning any significant work, query Bond BROADLY for relevant context:

```sql
-- Corrections: what NOT to repeat
SELECT KEY, CONTENT:lesson::STRING FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE INSIGHT_TYPE = 'correction' AND SUPERSEDED_BY IS NULL
ORDER BY UPDATED_AT DESC LIMIT 5;

-- Syntheses: creative inspiration from prior sessions
SELECT KEY, CONTENT:insight::STRING FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE ORIGIN = 'co-created' AND INSIGHT_TYPE = 'synthesis' AND SUPERSEDED_BY IS NULL
ORDER BY UPDATED_AT DESC LIMIT 5;

-- Domain decisions: respect prior architectural choices
SELECT KEY, CONTENT:insight::STRING FROM THE_BOND.PUBLIC.MEMORY_STORE
WHERE TAGS && ARRAY_CONSTRUCT('<domain_tag>')
AND INSIGHT_TYPE = 'decision' AND SUPERSEDED_BY IS NULL
ORDER BY UPDATED_AT DESC LIMIT 5;
```

Present findings: "From our Bond, here's what's relevant to this work..."

## Connection Config

```
Database: THE_BOND
Schema: PUBLIC
Tables: MEMORY_STORE, MEMORY_DOCUMENTS
Search: MEMORY_SEARCH (Cortex Search Service)
Stream: MEMORY_STREAM (change notifications)
```

## Stopping Points

- ✋ Before first use: Confirm the operating model (Model A: auto read + auto write)
- ✋ Before sharing with another agent: Confirm what context should be visible

## What This Skill Does NOT Do

- It does not replace local /memories/ files (those remain as cache/fallback)
- It does not auto-share with other agents (sharing requires explicit setup)
- It does not delete or overwrite — all knowledge is versioned via SUPERSEDED_BY
