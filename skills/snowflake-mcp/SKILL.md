---
name: snowflake-mcp
description: "Build and consume Snowflake-managed MCP servers. SERVER side: CREATE MCP SERVER over Cortex Analyst (semantic views), Cortex Search, Cortex Agents, UDFs/procedures; grants; RLS via DEFAULT_ROLE. CLIENT side: JSON-RPC tools/list & tools/call with PAT/OAuth, and the EXACT response-parsing shapes for the analyst/search tools (the part everyone gets wrong). Use when: create MCP server, managed MCP, expose semantic view as API, embeddable agent API, MCP client, call MCP from a web app, parse Cortex Analyst MCP response, MCP tools/call. Triggers: MCP server, managed MCP, CREATE MCP SERVER, mcp-servers endpoint, CORTEX_ANALYST_MESSAGE, CORTEX_SEARCH_SERVICE_QUERY, tools/call, embed Cortex agent, MCP client."
---

# Snowflake-managed MCP — server + client

A Snowflake-managed MCP server exposes Snowflake objects (Cortex Analyst semantic views, Cortex Search services, Cortex Agents, UDFs/procedures) as standard MCP tools over JSON-RPC. It's the cleanest **embeddable API** for letting any MCP client (Claude, ChatGPT, Cursor, your own app) query governed Snowflake data — data never leaves the account.

Docs: `https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-mcp` and `.../sql/create-mcp-server`.

---

## SERVER SIDE — create & govern

### Create
```sql
CREATE OR REPLACE MCP SERVER <db>.<schema>.<NAME>
  FROM SPECIFICATION $$
    tools:
      - name: "rcm-analyst"                      -- use hyphens, not underscores
        type: "CORTEX_ANALYST_MESSAGE"
        identifier: "<db>.<schema>.<SEMANTIC_VIEW>"
        title: "RCM Analytics"
        description: "Natural-language analytics over ... (be specific; the model picks tools by description)."
      - name: "rcm-denial-search"
        type: "CORTEX_SEARCH_SERVICE_QUERY"
        identifier: "<db>.<schema>.<SEARCH_SERVICE>"
        title: "Denial Search"
        description: "Unstructured search over ..."
  $$;
```

Tool types: `CORTEX_ANALYST_MESSAGE`, `CORTEX_SEARCH_SERVICE_QUERY`, `CORTEX_AGENT_RUN`, `SYSTEM_EXECUTE_SQL`, `GENERIC` (UDF/proc, needs `config:` with type/warehouse/input_schema).

### Grants — access to the server is NOT access to the tools (grant both)
```sql
GRANT USAGE ON MCP SERVER <db>.<schema>.<NAME> TO ROLE <r>;            -- connect + discover
GRANT SELECT ON SEMANTIC VIEW <db>.<schema>.<SEMANTIC_VIEW> TO ROLE <r>;       -- analyst tool
GRANT USAGE  ON CORTEX SEARCH SERVICE <db>.<schema>.<SEARCH_SERVICE> TO ROLE <r>; -- search tool
GRANT USAGE  ON CORTEX AGENT <db>.<schema>.<AGENT> TO ROLE <r>;        -- agent tool
```

### Inspect
`SHOW MCP SERVERS IN SCHEMA <db>.<schema>;`  ·  `DESCRIBE MCP SERVER <name>;`  ·  `DROP MCP SERVER <name>;`

### Endpoint
```
https://<account_url>/api/v2/databases/<db>/schemas/<schema>/mcp-servers/<NAME>
```

### Critical server facts
- **Cortex Analyst requires a SEMANTIC VIEW**, not a semantic model file (managed MCP only).
- **Sessions use the connecting user's `DEFAULT_ROLE`. Secondary roles are NOT supported.** So row-level security keyed on the role flows through cleanly — and each user must have `DEFAULT_ROLE` + `DEFAULT_WAREHOUSE` set or the session fails to init: `ALTER USER <u> SET DEFAULT_ROLE='<r>' DEFAULT_WAREHOUSE='<wh>';`
- **Read-only posture:** expose Analyst/Search/Agent tools (no mutation). Avoid `SYSTEM_EXECUTE_SQL` with `read_only:false`. (Defense-in-depth: also validate SQL client-side — see below.)
- Use **hyphens, not underscores**, in tool names and in the account hostname (underscores cause connection issues with some clients).
- Limits: max 50 tools/server; tool responses truncated (~250 KB) — keep queries narrow.
- Auth: prefer **OAuth** (security integration, shared client id/secret). **PAT** works (`Authorization: Bearer <PAT>`); scope it to a **least-privilege role**.

---

## CLIENT SIDE — call it & parse it

### JSON-RPC
`POST <endpoint>` with `Authorization: Bearer <PAT>`, `Content-Type: application/json`.
```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rcm-analyst","arguments":{"message":"denial rate by payer"}}}
```
`tools/list` (no params) discovers tools. Response: `{ "result": { ... } }` (check `data.error`).

### ⚠️ Response parsing — the part everyone gets wrong
The proven shapes (verified; ref `healthcare-mcp-app/app/(tabs)/omop.tsx`, `services/mcp-client.ts`):

**`CORTEX_ANALYST_MESSAGE`** → `result.content[]`. For an item with `type:"text"`, **`item.text` is itself a JSON STRING** that parses to an **array** of objects:
- `obj.statement` = the generated **SQL** ← execute this
- `obj.text` = the analyst's natural-language interpretation
- `obj.suggestions` = follow-up questions

```js
function extractSQL(result){
  for(const it of (result?.content||[])){
    if(it.type==="sql" && it.sql) return it.sql;
    if(it.type==="text" && it.text){ try{ const p=JSON.parse(it.text);
      if(Array.isArray(p)) for(const o of p){ if(o.statement) return o.statement; }
      else if(p.statement) return p.statement; }catch(e){} }
  }
  return null;
}
```
The analyst returns SQL, **not rows** — execute it yourself via the SQL API (next section).

**`CORTEX_SEARCH_SERVICE_QUERY`** → results live under `result.results`, or `result.content[].json.search_results`, or a JSON-string in `content[].text`. Walk those shapes; each hit has `text`/`BODY` + your attribute columns.

**DO NOT** regex over `JSON.stringify(result)` to find SQL — stringify re-introduces `\n`/`\"` escapes and you'll execute corrupt SQL (`syntax error ... unexpected '\'`). Always parse the structured fields.

### Execute the analyst SQL (SQL API)
`POST https://<account_url>/api/v2/statements` with Bearer PAT:
```json
{"statement":"<sql>","timeout":60,"database":"<db>","schema":"<schema>","warehouse":"<wh>"}
```
- Read `data.resultSetMetaData.rowType` (cols: `name`, `type`, `scale`) + `data.data` (array-of-arrays).
- **Async/large:** `408`/`202` or `code 333334` → poll `GET /api/v2/statements/<handle>`; multi-partition → fetch `?partition=N`.
- **Format by column type:** `real` or `fixed` w/ `scale>0` → money/decimals (2 places); `fixed` scale 0 → integer; `text` → leave (don't comma-format CPT/codes).

### Read-only guardrail (client-side, before executing any SQL)
```js
const BLOCK=[/\b(INSERT|UPDATE|DELETE|MERGE)\b/i,/\b(DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE)\b/i,/\b(COPY\s+INTO|PUT\s|REMOVE\s|CALL\s|EXECUTE\s)\b/i];
function validateSQL(s){ const t=s.replace(/--.*$/gm,"").trim();
  if(!/^(SELECT|WITH)\b/i.test(t)) return {safe:false}; for(const p of BLOCK) if(p.test(t)) return {safe:false,p:p.source}; return {safe:true}; }
```

### Embeddable web-client pattern (no infra)
- Single static page (HTML/JS or React/Expo), served locally or via a presigned URL — **runtime PAT entry**, nothing baked in (optionally persist in `sessionStorage`).
- Browser `fetch` to `*.snowflakecomputing.com` works cross-origin with the PAT (proven). If a client hits CORS, proxy via a tiny local backend.
- Reference implementations: `~/Downloads/CoCoStuff/healthcare-mcp-app` (Expo + serve.py) and `~/Downloads/CoCoStuff/adonis-rcm-mvp/app/index.html` (lean single-file).

---

## Verify
- `SHOW MCP SERVERS` lists it; `DESCRIBE` shows the tools.
- `tools/list` returns the expected tools with a PAT.
- `tools/call` on the analyst tool returns content whose `text` parses to an array with a `statement`; that SQL executes read-only via `/api/v2/statements` and returns rows.
- If RLS is in play, a facility/tenant-scoped `DEFAULT_ROLE` returns only its rows.

## Gotchas (hard-won)
- Analyst `item.text` is double-encoded JSON (string → array). Parse it; don't stringify-regex.
- Access to the MCP server ≠ access to its tools — grant each tool object.
- Secondary roles are ignored; set `DEFAULT_ROLE`/`DEFAULT_WAREHOUSE` per user.
- Analyst returns SQL, not data — you run it.
- Underscores in hostnames/tool names break some clients — use hyphens.
- Always check the referenced reference implementation before writing parsing from scratch.
