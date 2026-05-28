---
name: spcs-spa-auth
description: "Build SPAs (React, Vue, etc.) on Snowpark Container Services (SPCS) that query Snowflake data. Use for: SPCS authentication, SPCS SPA, containerized web app querying Snowflake, SPCS service token, SPCS SQL API, SPCS React app, SPCS dashboard, connect to Snowflake from container. Triggers: SPCS app, SPA on SPCS, container auth Snowflake, SPCS token, SPCS web app, deploy React to SPCS, SPCS query data."
---

# SPCS SPA Authentication Pattern

Build and deploy Single Page Applications on SPCS that securely query Snowflake.

## Critical Knowledge

### The SPCS Service Token Does NOT Work with the SQL REST API

The token at `/snowflake/session/token` inside SPCS containers is a service-user OAuth token. It CANNOT be used with:
- Snowflake SQL REST API (`/api/v2/statements`) — returns error 395092 "unauthorized to use Snowpark Container Services OAuth token"
- `Authorization: Bearer <token>` header — same 395092 error
- `Authorization: Snowflake Token="<token>"` header — returns 390146 "Bearer token is missing"
- Python connector pointed at the PUBLIC account hostname — same 395092 error

### The Working Pattern: Python Backend + Internal Host

The service token ONLY works with `snowflake-connector-python` when connected via SPCS-injected internal environment variables:
- `SNOWFLAKE_HOST` — internal host (e.g., `sob92100.prod3.us-west-2.aws.snowflakecomputing.com`), NOT the public account locator
- `SNOWFLAKE_ACCOUNT` — internal account (e.g., `SOB92100`), NOT the org-account format

### Do NOT Override SNOWFLAKE_HOST or SNOWFLAKE_ACCOUNT

SPCS auto-injects these env vars with correct internal values. Setting them manually in the service spec (even with `{{host}}`/`{{account}}` which are NOT resolved template variables) breaks connectivity. Remove any env var overrides for these.

## Architecture

```
Browser → SPCS Ingress → nginx:8080 → SPA static files
                                    → /api/* proxy → Flask:8085 → snowflake-connector-python → Snowflake
```

- **nginx** (port 8080): Serves SPA static files + reverse-proxies `/api/` to Flask
- **Flask** (port 8085): Reads `/snowflake/session/token`, connects via Python connector with `authenticator='oauth'`
- **Frontend**: Sends POST to `/api/v2/statements` (same-origin, no CORS issues, no auth headers needed)

## Workflow

### Step 1: Gather Requirements

Ask user for:
1. **Frontend framework** (React, Vue, plain HTML)
2. **Snowflake database/schema/warehouse** for queries
3. **Compute pool** for SPCS deployment
4. **Image repository** path (e.g., `DB.SCHEMA.REPO`)

### Step 2: Create Backend (backend.py)

Create a Flask app that proxies SQL execution:

```python
import os, json, logging
from flask import Flask, request, jsonify
import snowflake.connector

app = Flask(__name__)
SF_HOST = os.getenv('SNOWFLAKE_HOST', '')
SF_ACCOUNT = os.getenv('SNOWFLAKE_ACCOUNT', '')

def get_token():
    with open('/snowflake/session/token', 'r') as f:
        return f.read().strip()

def get_connection():
    params = {
        'token': get_token(),
        'authenticator': 'oauth',
        'database': '<DATABASE>',
        'schema': '<SCHEMA>',
        'warehouse': '<WAREHOUSE>',
    }
    if SF_HOST:
        params['host'] = SF_HOST
    if SF_ACCOUNT:
        params['account'] = SF_ACCOUNT
    return snowflake.connector.connect(**params)

@app.route('/api/v2/statements', methods=['POST'])
def execute_sql():
    body = request.json
    sql = body.get('statement', '')
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [desc[0] for desc in cur.description] if cur.description else []
        rows = cur.fetchall()
        data = [[str(v) if v is not None else None for v in row] for row in rows]
        return jsonify({
            'resultSetMetaData': {'rowType': [{'name': c} for c in cols]},
            'data': data,
            'code': '090001',
            'message': 'Statement executed successfully.',
        })
    finally:
        conn.close()

@app.route('/health', methods=['GET'])
def health():
    try:
        conn = get_connection()
        cur = conn.cursor()
        cur.execute('SELECT CURRENT_USER(), CURRENT_ROLE()')
        row = cur.fetchone()
        conn.close()
        return jsonify({'status': 'ok', 'user': row[0], 'role': row[1]})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8085)
```

Replace `<DATABASE>`, `<SCHEMA>`, `<WAREHOUSE>` with user's values.

### Step 3: Create nginx Config (nginx.conf.template)

```nginx
server {
    listen 8080;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8085/api/;
        proxy_set_header Content-Type "application/json";
        proxy_set_header Accept "application/json";
        proxy_pass_request_body on;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
    }

    location /health {
        proxy_pass http://127.0.0.1:8085/health;
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 256;
}
```

### Step 4: Create Entrypoint (entrypoint.sh)

```bash
#!/bin/sh
TOKEN_FILE="/snowflake/session/token"
echo "[entrypoint] Waiting for token file..."
for i in $(seq 1 30); do
    if [ -f "$TOKEN_FILE" ]; then
        echo "[entrypoint] Token file found after ${i}s"
        break
    fi
    sleep 1
done

echo "[entrypoint] Starting Python backend on port 8085..."
python3 /app/backend.py &
BACKEND_PID=$!
sleep 2
if kill -0 $BACKEND_PID 2>/dev/null; then
    echo "[entrypoint] Backend started (PID=$BACKEND_PID)"
else
    echo "[entrypoint] ERROR: Backend failed to start"
fi

echo "[entrypoint] Starting nginx on port 8080"
exec nginx -g "daemon off;"
```

### Step 5: Create Dockerfile

Use `python:3.12-slim` (NOT alpine — `snowflake-connector-python` needs C compilation that fails on alpine without extra packages).

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM python:3.12-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir flask snowflake-connector-python
COPY --from=build /app/dist /var/www/html
COPY nginx.conf.template /etc/nginx/conf.d/default.conf
COPY backend.py /app/backend.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN rm -f /etc/nginx/sites-enabled/default
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
```

For non-Node frontends, replace the build stage accordingly.

### Step 6: Frontend SQL Client

The frontend calls `/api/v2/statements` with NO auth headers (nginx proxies to Flask):

```typescript
async function executeSQL(sql: string): Promise<any> {
    const response = await fetch('/api/v2/statements', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            statement: sql,
            database: '<DATABASE>',
            schema: '<SCHEMA>',
            warehouse: '<WAREHOUSE>',
        }),
    });
    if (!response.ok) throw new Error(`SQL API error: ${response.status}`);
    return response.json();
}
```

### Step 7: Build and Push Image

```bash
docker build --platform linux/amd64 -t <APP_NAME>:latest .
docker tag <APP_NAME>:latest <REGISTRY>/<DB>/<SCHEMA>/<REPO>/<APP_NAME>:latest
snow spcs image-registry login --connection <CONNECTION>
docker push <REGISTRY>/<DB>/<SCHEMA>/<REPO>/<APP_NAME>:latest
```

Always use `--platform linux/amd64` (SPCS runs Linux amd64, local Mac is arm64).

### Step 8: Deploy SPCS Service

```sql
CREATE SERVICE <DB>.<SCHEMA>.<SERVICE_NAME>
  IN COMPUTE POOL <COMPUTE_POOL>
  FROM SPECIFICATION
  $$
  spec:
    containers:
    - name: web
      image: /<DB>/<SCHEMA>/<REPO>/<APP_NAME>:latest
      resources:
        requests:
          cpu: 0.5
          memory: 512M
        limits:
          cpu: 1
          memory: 1G
    endpoints:
    - name: ui
      port: 8080
      public: true
  $$;
```

For updates, use ALTER SERVICE (preserves endpoint URL):
```sql
ALTER SERVICE <DB>.<SCHEMA>.<SERVICE_NAME>
  FROM SPECIFICATION $$...same spec...$$;
```

### Step 9: Verify

```sql
SELECT SYSTEM$GET_SERVICE_STATUS('<SERVICE_NAME>');
SHOW ENDPOINTS IN SERVICE <SERVICE_NAME>;
```

Check logs if issues:
```sql
SELECT SYSTEM$GET_SERVICE_LOGS('<SERVICE_NAME>', 0, 'web', 100);
```

Visit the endpoint URL. Check `/health` to confirm Snowflake connectivity.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| 395092 "unauthorized to use SPCS OAuth token" | Using service token with SQL REST API or public hostname | Use Python connector with SPCS-injected internal host |
| 390146 "Bearer token is missing" | Wrong auth header format with REST API | Don't use REST API — use Python connector backend |
| `c++: not found` during Docker build | Alpine base lacks C compiler for snowflake-connector-python | Use `python:3.12-slim` instead of alpine |
| Token file not found | Container started before SPCS mounted token | entrypoint.sh waits up to 30s for token |
| Connection refused on /api/ | Flask backend not running | Check entrypoint logs, verify port 8085 |
| No data returned | SQL query error | Check service logs: `SYSTEM$GET_SERVICE_LOGS` |

## Caller's Rights (Multi-Tenant)

For apps where queries should run as the logged-in user (not the service user):

1. Add to spec: `capabilities: { securityContext: { executeAsCaller: true } }`
2. Read `Sf-Context-Current-User-Token` header from each request
3. Concatenate: `service_token + "." + caller_token`
4. Use concatenated token with `authenticator='oauth'`
5. Requires `GRANT CALLER` privileges on the service

## Stopping Points

- After Step 1 (confirm requirements)
- After Step 6 (review frontend integration)
- After Step 9 (verify deployment)

## Output

A working SPCS-hosted SPA with:
- Static frontend served by nginx
- Python Flask backend handling Snowflake auth
- Same-origin API proxy (no CORS issues)
- Stable endpoint URL preserved across updates
