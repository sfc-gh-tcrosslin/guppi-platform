---
name: spcs-react-agent
description: "Build and deploy React SPA dashboards on Snowpark Container Services (SPCS) with Cortex Agent integration. Use when: creating SPCS React apps, building dashboards with Flask backend, deploying SPAs to SPCS, wiring Cortex Agents from SPCS, DATA_AGENT_RUN pattern. Triggers: SPCS React, SPA dashboard, deploy React to SPCS, Cortex Agent from SPCS, Flask SPCS backend, DATA_AGENT_RUN."
---

# SPCS React SPA + Cortex Agent Scaffold

Generates a complete React SPA dashboard deployed on Snowpark Container Services with a Python Flask backend that queries Snowflake via connector and calls Cortex Agents via `DATA_AGENT_RUN`.

## Architecture

```
┌─────────────────────────────────────────────┐
│  SPCS Container                             │
│  ┌────────────────────────────────────────┐ │
│  │ nginx (port 8080)                      │ │
│  │   / → static SPA (React build)         │ │
│  │   /api/ → proxy to Flask               │ │
│  │   /health → proxy to Flask             │ │
│  └────────────────┬───────────────────────┘ │
│                   │                          │
│  ┌────────────────▼───────────────────────┐ │
│  │ Flask backend (port 8085)              │ │
│  │   /api/v2/statements → SQL execution   │ │
│  │   /api/v2/cortex/agent:run → Agent     │ │
│  │   /health → connection check           │ │
│  │                                        │ │
│  │ snowflake-connector-python             │ │
│  │   auth: oauth via /snowflake/session/  │ │
│  │         token (SPCS service token)     │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Critical Pitfalls

1. **SPCS service token does NOT work with REST API** — Always use `snowflake-connector-python` with `authenticator='oauth'`
2. **Do NOT set SNOWFLAKE_HOST/SNOWFLAKE_ACCOUNT in spec** — SPCS injects internal values automatically
3. **DATA_AGENT_RUN response format** — Returns `{content: [...]}` at top level (NOT `{message: {content: [...]}}`). Tool results at `block.tool_result.content[]`
4. **Docker must use `--platform linux/amd64`** — SPCS runs on x86_64
5. **Use ALTER SERVICE** (not DROP+CREATE) to preserve stable endpoint URL
6. **`python:3.12-slim`** as base — not alpine (snowflake-connector-python needs glibc)

## Workflow

### Step 1: Gather Requirements

**Ask** the user:
1. App name (kebab-case, e.g. `my-dashboard`)
2. Target database/schema for queries
3. Cortex Agent FQN (if agent integration needed, e.g. `DB.SCHEMA.MY_AGENT`)
4. SPCS compute pool name
5. SPCS image repository path
6. Warehouse name

### Step 2: Scaffold React Project

**Actions:**
1. Run `npm create vite@latest {app-name} -- --template react-ts`
2. Install dependencies:
   ```bash
   cd {app-name}
   npm install tailwindcss @tailwindcss/vite recharts lucide-react
   ```
3. Generate project files from assets:

| File | Purpose |
|------|---------|
| `src/services/snowflake.ts` | Snowflake connector: SQL exec + Agent queries |
| `src/types/index.ts` | Shared TypeScript types |
| `src/index.css` | Tailwind + light theme CSS variables |
| `backend.py` | Flask backend with SQL + Agent endpoints |
| `Dockerfile` | Multi-stage: node build → python:3.12-slim + nginx |
| `nginx.conf.template` | nginx config: static files + API proxy |
| `entrypoint.sh` | Wait for token, start Flask, start nginx |

4. Write asset files using templates from `assets/` directory

### Step 3: Configure Snowflake Service

**Generate** SPCS service SQL:

```sql
CREATE SERVICE IF NOT EXISTS {db}.{schema}.{service_name}
  IN COMPUTE POOL {compute_pool}
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: app
      image: {registry}/{repo}/{image}:latest
      resources:
        requests: { memory: 1G, cpu: 0.5 }
        limits: { memory: 2G, cpu: 1 }
    endpoints:
    - name: app
      port: 8080
      public: true
    capabilities:
      securityContext:
        executeAsCaller: true
  $$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1;
```

For updates (preserves URL):
```sql
ALTER SERVICE {db}.{schema}.{service_name}
FROM SPECIFICATION $$ ... $$;
```

### Step 4: Build and Deploy

**Execute** sequentially:

```bash
npm run build
docker build --platform linux/amd64 -t {app-name}:latest .
docker tag {app-name}:latest '{registry_path}/{app-name}:latest'
snow spcs image-registry login --connection {connection}
docker push '{registry_path}/{app-name}:latest'
```

Then ALTER SERVICE to pick up the new image.

### Step 5: Verify

1. Check service status: `SHOW SERVICES LIKE '{service_name}' IN SCHEMA {db}.{schema}`
2. Check logs: `SELECT SYSTEM$GET_SERVICE_LOGS('{db}.{schema}.{service_name}', 0, 'app', 100)`
3. Hit `/health` endpoint to verify backend connectivity
4. Test SQL queries and Agent calls from the UI

## Stopping Points

1. **After Step 1** — Confirm requirements before scaffolding
2. **After Step 2** — User reviews generated code, adds custom components
3. **After Step 4** — Verify deployment succeeded before testing

## Key Code Patterns

### Flask Backend — Agent Call via DATA_AGENT_RUN

```python
def get_connection():
    with open('/snowflake/session/token', 'r') as f:
        token = f.read().strip()
    params = {
        'token': token,
        'authenticator': 'oauth',
        'database': AGENT_DB,
        'schema': AGENT_SCHEMA,
        'warehouse': WAREHOUSE,
    }
    host = os.getenv('SNOWFLAKE_HOST', '')
    account = os.getenv('SNOWFLAKE_ACCOUNT', '')
    if host: params['host'] = host
    if account: params['account'] = account
    return snowflake.connector.connect(**params)

@app.route('/api/v2/cortex/agent:run', methods=['POST'])
def agent_run():
    body = request.json
    request_json = json.dumps({'messages': body.get('messages', [])})
    conn = get_connection()
    cur = conn.cursor()
    cur.execute(
        "SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(%s, %s) AS response",
        (AGENT_FQN, request_json)
    )
    row = cur.fetchone()
    agent_resp = json.loads(row[0]) if row else {}
    conn.close()
    return jsonify(agent_resp)
```

### Frontend — Parsing DATA_AGENT_RUN Response

```typescript
const content = json.content || json.message?.content || [];
for (const block of content) {
  if (block.type === 'text') {
    text += block.text || '';
  } else if (block.type === 'tool_result') {
    const items = block.tool_result?.content || block.content || [];
    for (const item of items) {
      if (item.type === 'json' && item.json) {
        const jsonData = typeof item.json === 'string' ? JSON.parse(item.json) : item.json;
        if (jsonData?.sql) sql = jsonData.sql;
        if (jsonData?.result_set?.data) {
          // Parse result_set.resultSetMetaData.rowType + result_set.data
        }
      }
    }
  }
}
```

### Design System — Light Theme

```css
:root {
  --bg-primary: #f5f7fa;
  --bg-card: #ffffff;
  --accent: #29B5E8;       /* Snowflake blue */
  --accent-hover: #1a9bc7;
  --text-primary: #1e293b;
  --text-secondary: #64748b;
  --border: #e2e8f0;
  --shadow: 0 1px 3px rgba(0,0,0,0.1);
}
```

## Output

The skill produces a deployable SPCS React SPA with:
- Vite + React 19 + TypeScript + Tailwind CSS frontend
- Flask + snowflake-connector-python backend
- nginx reverse proxy (static files + API)
- Docker multi-stage build (node → python:3.12-slim)
- Cortex Agent integration via DATA_AGENT_RUN
- Light theme design system with Snowflake branding
- SPCS service spec with caller's rights
