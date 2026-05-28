---
name: agent-guardrails
description: >
  Implements defense-in-depth guardrails for Cortex Agent and MCP Server applications.
  Creates read-only Snowflake roles, API-layer SQL validation, and UI confirmation flows
  to prevent data modification via agent-generated queries.
  Use when: add guardrails, agent security, prevent data modification, read-only agent,
  SQL validation, human-in-the-loop, agent safety, block DML, block DDL, defense in depth,
  secure agent, guardrail implementation.
metadata:
  author: tjia
  version: 1.0.0
  category: security
  tags: [guardrails, security, cortex-agent, mcp-server, defense-in-depth, sql-validation]
---

# Agent Guardrails: Defense in Depth

Implement a 3-layer security architecture that prevents Cortex Agent / MCP Server applications from modifying data. Each layer is independent — if one fails, the others still protect.

## When to Use

- Building a Cortex Agent or MCP Server app that should be read-only
- Adding security to an existing agent chat interface
- Preventing agent-generated SQL from executing DML/DDL
- Need human-in-the-loop approval before SQL execution

## Architecture

```
User Question → Cortex Analyst → Generated SQL
                                      ↓
                          ┌─── Layer 2: API Validator ───┐
                          │  Regex blocklist strips       │
                          │  DML/DDL before execution     │
                          └──────────┬───────────────────┘
                                     ↓
                          ┌─── Layer 3: UI Confirmation ──┐
                          │  User sees SQL, clicks        │
                          │  Execute or Reject             │
                          └──────────┬───────────────────┘
                                     ↓
                          ┌─── Layer 1: Snowflake Role ───┐
                          │  SELECT-only grants            │
                          │  Platform-enforced             │
                          └───────────────────────────────┘
```

## Workflow

### Step 1: Identify Target Application

**Goal:** Understand the app architecture to determine where guardrails go.

**Actions:**
1. Identify the MCP client / service file that calls `executeSQL()` or equivalent
2. Identify the UI component(s) that display agent responses with SQL
3. Identify the Snowflake database/schema the agent queries

**Output:** File paths for API layer and UI layer modifications

### Step 2: Layer 1 — Snowflake Read-Only Role

**Goal:** Create a platform-enforced SELECT-only role.

**Actions:**

```sql
CREATE ROLE IF NOT EXISTS <APP_NAME>_READONLY_ROLE
  COMMENT = 'Read-only role for <app> agent — blocks all DML/DDL';

GRANT USAGE ON WAREHOUSE <WAREHOUSE> TO ROLE <APP_NAME>_READONLY_ROLE;
GRANT USAGE ON DATABASE <DATABASE> TO ROLE <APP_NAME>_READONLY_ROLE;
GRANT USAGE ON SCHEMA <DATABASE>.<SCHEMA> TO ROLE <APP_NAME>_READONLY_ROLE;

GRANT SELECT ON ALL TABLES IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <APP_NAME>_READONLY_ROLE;
GRANT SELECT ON ALL VIEWS IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <APP_NAME>_READONLY_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <APP_NAME>_READONLY_ROLE;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <APP_NAME>_READONLY_ROLE;
```

Repeat for each schema the agent needs access to.

**Output:** Role created with SELECT-only privileges

### Step 3: Layer 2 — SQL Validator (API Layer)

**Goal:** Add a regex-based blocklist that rejects dangerous SQL before it reaches Snowflake.

**Pattern — TypeScript:**

```typescript
const BLOCKED_SQL_PATTERNS: RegExp[] = [
  /\b(INSERT\s+INTO|INSERT\s+OVERWRITE)\b/i,
  /\b(UPDATE\s+\w)\b/i,
  /\b(DELETE\s+FROM)\b/i,
  /\b(MERGE\s+INTO)\b/i,
  /\b(DROP\s+(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE|PIPE|STREAM|TASK|FUNCTION|PROCEDURE|MCP))\b/i,
  /\b(CREATE\s+(OR\s+REPLACE\s+)?(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE|PIPE|STREAM|TASK|FUNCTION|PROCEDURE|MCP))\b/i,
  /\b(ALTER\s+(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE|PIPE|STREAM|TASK|FUNCTION|PROCEDURE))\b/i,
  /\b(TRUNCATE\s+TABLE)\b/i,
  /\b(GRANT\s+\w)\b/i,
  /\b(REVOKE\s+\w)\b/i,
  /\b(COPY\s+INTO)\b/i,
  /\b(PUT\s+)\b/i,
  /\b(REMOVE\s+@)\b/i,
  /\b(CALL\s+)\b/i,
  /\b(EXECUTE\s+)\b/i,
];

export function validateSQL(sql: string): { safe: boolean; blockedPattern?: string } {
  const stripped = sql.replace(/--.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '').trim();
  for (const pattern of BLOCKED_SQL_PATTERNS) {
    if (pattern.test(stripped)) {
      return { safe: false, blockedPattern: pattern.source };
    }
  }
  return { safe: true };
}
```

**Pattern — Python (Streamlit / Flask):**

```python
import re

BLOCKED_SQL_PATTERNS = [
    r'\b(INSERT\s+INTO|INSERT\s+OVERWRITE)\b',
    r'\b(UPDATE\s+\w)\b',
    r'\b(DELETE\s+FROM)\b',
    r'\b(MERGE\s+INTO)\b',
    r'\b(DROP\s+(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE))\b',
    r'\b(CREATE\s+(OR\s+REPLACE\s+)?(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE))\b',
    r'\b(ALTER\s+(TABLE|VIEW|SCHEMA|DATABASE|WAREHOUSE|ROLE|USER|STAGE))\b',
    r'\b(TRUNCATE\s+TABLE)\b',
    r'\b(GRANT\s+\w)\b',
    r'\b(REVOKE\s+\w)\b',
    r'\b(COPY\s+INTO)\b',
    r'\b(CALL\s+)\b',
]

def validate_sql(sql: str) -> tuple[bool, str | None]:
    stripped = re.sub(r'--.*$', '', sql, flags=re.MULTILINE)
    stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.DOTALL).strip()
    for pattern in BLOCKED_SQL_PATTERNS:
        if re.search(pattern, stripped, re.IGNORECASE):
            return False, pattern
    return True, None
```

**Integration:** Call `validateSQL()` at the top of the `executeSQL()` method. Throw/raise an error if `safe` is false.

### Step 4: Layer 3 — UI Confirmation (Human-in-the-Loop)

**Goal:** Show users the SQL and require explicit approval before execution.

**Flow:**
1. Agent returns a response with generated SQL
2. Validate SQL with Layer 2 — if blocked, show shield icon + blocked message
3. If safe, show SQL with **Execute** (green) and **Reject** (red) buttons
4. Only execute SQL after user clicks Execute
5. If rejected, append "(SQL execution was rejected by user)" to the message

**State needed:**
- `pendingSql: Map<messageId, sqlString>` — tracks which messages have unapproved SQL
- `sqlPending: boolean` on message model — controls button visibility
- `sqlBlocked: boolean` on message model — controls blocked indicator

**UI Components:**
- Green "Execute" button → triggers SQL execution, removes pending state
- Red "Reject" button → marks as rejected, removes pending state
- Hourglass icon + "SQL Awaiting Approval" label for pending state
- Shield icon + "SQL Blocked by Guardrail" label for blocked state

## Stopping Points

- After Step 1 if architecture is unclear — ask user to confirm file paths
- After Step 2 to confirm the role name and schemas before creating
- After Step 4 to rebuild and test the app

## Validation

After implementation, test these scenarios:

| Test | Expected Result |
|------|----------------|
| Normal SELECT query | Shows Execute/Reject buttons, executes on approve |
| User clicks Reject | SQL not executed, rejection note appended |
| "DELETE FROM table" prompt | Blocked at Layer 2, shield icon shown |
| SQL with comment-hidden DML | Comments stripped, DML still caught |

## Output

- Snowflake role: `<APP_NAME>_READONLY_ROLE` with SELECT-only grants
- API validator: `validateSQL()` function blocking 15 DML/DDL patterns
- UI confirmation: Execute/Reject buttons on all agent-generated SQL
- Optional: Snowflake-branded presentation (`guardrails-presentation.html`)
