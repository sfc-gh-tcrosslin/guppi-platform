---
name: guppi-slack-rep
description: "Suggestion recipe: stand up a read-only, grounded Guppi 'representative' agent that answers @mentions in a team's Slack in real time (SPCS Socket Mode), on the owner's behalf, grounded in their GuppiWheel corpus. This is an OPTIONAL capability one Guppi recommends to another — NOT seed substrate. Suggest it when: a team lives in Slack and fields repetitive, groundable questions and has SPCS headroom. Triggers: Slack representative, rep agent, answer for me in Slack, Guppi in Slack, bi-directional Slack, Socket Mode bridge, @mention agent, represent me in Slack, on my behalf in Slack."
---

# Guppi Slack Representative — a capability recipe (a *suggestion*, not substrate)

A read-only Cortex Agent that answers questions in a team's Slack **in real time**, attributed and grounded in the owner's GuppiWheel corpus. "Ask the record," on the owner's behalf — never impersonating them, never able to act.

**This is a suggestion, not a seed.** Most GuppiWheel installs will never want it (not every team lives in Slack; it needs tokens + SPCS budget). So it is packaged as an adoptable recipe in the capability tier — one Guppi says to another *"you could do this"* — rather than baked into `seeds/`. Only surface it when the environment fits (see below).

## When to suggest this (and when NOT to)
Suggest when ALL hold:
- The owner's team collaborates in **Slack**.
- They repeatedly answer **groundable** questions (status, decisions, "where's the doc on X", "what did we decide about Y") that already live in the wheel/Bond.
- They have **SPCS headroom** (a small XS pool, scheduled to business hours, is enough).

Do **not** suggest it when: the team isn't on Slack; the questions are mostly novel-opinion/commitment (the agent will just escalate those anyway); or there's no appetite to run any service.

## What the operator gets — and the guardrails that travel with it
- A read-only rep agent (default name `{{AGENT_NAME}}`) grounded on their semantic view + Cortex Search + Bond. **No write tools** — write capability is removed by *architecture*, not suppressed by instruction. An open Slack channel must never reach a write-capable agent.
- **Least-privilege role** (`{{ROLE}}`): only what the bridge needs (agent usage, grounding read, warehouse, CORTEX_USER, EAI, pool, create-service, image read, bind-endpoint).
- **Business-hours-only compute**: a dedicated XS pool with scheduled resume/suspend tasks. Suspended = no cost.
- **Tokens in Snowflake SECRETs**, mounted into the service — never a laptop file, never in chat/args.
- **EAI scoped** to Slack hosts only.

## Reusability contract (learned the hard way — 2026-07-11)
- **Don't name the object after a person.** The agent object is generic (`{{AGENT_NAME}}`); the owner attribution ("on behalf of {{OWNER_HANDLE}}") lives in the **persona config** (`rep-agent-spec.json.template`), so anyone can stand up their own. Naming an object `*_TODD_*` was the mistake this recipe exists to avoid.
- Everything below is parameterized with `{{TOKENS}}`. Fill them in for your environment; the worked example values are the reference deployment.

## Prerequisites (operator, in Slack + local)
1. A Slack app in the target workspace with **Socket Mode ON**.
   - Bot token `xoxb-…` (OAuth & Permissions). Scopes: `app_mentions:read`, `chat:write`, `im:read`, `im:history`.
   - App-level token `xapp-…` (Basic Information → App-Level Tokens, scope `connections:write`). This is NOT tied to reinstall.
   - Event subscriptions: `app_mention`, `message.im`. Invite the bot to the channel.
2. Local: Snowflake CLI + Docker, logged in to the SPCS image registry.
3. The grounding objects already exist: semantic view `{{SEMANTIC_VIEW}}`, Cortex Search `{{ARTIFACTS_SEARCH}}`, and (optional) Bond `{{BOND_SEARCH}}`.

## Deploy runbook (in order)
Substitute `{{TOKENS}}` throughout (`assets/` files carry the same tokens).

1. **Groundwork DDL** — `assets/01-groundwork.sql.template`: network rule → EAI → XS pool (INITIALLY_SUSPENDED) → least-priv role + grants → image repo. Run as an admin role.
2. **Create the rep agent** — `assets/rep-agent-spec.json.template`: `CREATE OR REPLACE AGENT {{DB}}.{{SCHEMA}}.{{AGENT_NAME}} FROM SPECIFICATION $$ … $$;` then `GRANT USAGE ON AGENT … TO ROLE {{ROLE}};`. Use `$$` dollar-quoting (named tags like `$spec$` FAIL). Fill `{{OWNER_NAME}}`/`{{OWNER_HANDLE}}` in the persona.
   - **Test the lane before wiring Slack**: a grounded Q → answer + cited artifact IDs; an ungrounded/novel Q → declines + escalates; a commitment Q → refuses + escalates.
3. **Tokens → SECRETs** — `assets/02-secrets.py.template`: reads local token files → `CREATE SECRET … TYPE=GENERIC_STRING` → grants READ to `{{ROLE}}`. Delete the local token files after.
4. **Build + push the image**:
   ```
   snow spcs image-registry login
   docker build --platform linux/amd64 -t <registry>/{{DB_LC}}/{{SCHEMA_LC}}/{{IMAGE_REPO_LC}}/guppi-slack-bridge:{{IMAGE_TAG}} assets/
   docker push <registry>/…/guppi-slack-bridge:{{IMAGE_TAG}}
   ```
   (`assets/Dockerfile.template` + `assets/app.py.template` + `assets/requirements.txt` are the build context. Rename the `.template` files to drop the suffix for the build.)
5. **Create the service + schedule** — `assets/03-service.sql.template`: `CREATE SERVICE {{SERVICE}}` (env `AGENT_NAME={{AGENT_NAME}}`, resources, secrets) + two business-hours TASKs (`{{RESUME_CRON}}` / `{{SUSPEND_CRON}}` `{{TIMEZONE}}`).
6. **Verify live**: `@{{AGENT_NAME}}` (or the bot) in the channel → expect a real-time, grounded, attributed reply. Check `SYSTEM$GET_SERVICE_LOGS('{{DB}}.{{SCHEMA}}.{{SERVICE}}', 0, 'bridge', 50)` if quiet.

## The auth gotcha you will hit (documented so you don't re-derive it)
The SPCS service calls the Cortex Agent `:run` REST endpoint with its **service identity** (token at `/snowflake/session/token`). The headers MUST be:
```
Authorization: Bearer <token>
X-Snowflake-Authorization-Token-Type: OAUTH
```
NOT the `Authorization: Snowflake Token="<token>"` scheme. The failure walk if you get it wrong: `400` (bad Accept) → `401 390104` "must login again" (missing OAUTH type) → `400 390146` "Bearer token is missing" (OAUTH type set but Snowflake-Token scheme) → **Bearer + OAUTH = 200**. `app.py.template` already has this right.

## Cost note
Only the XS pool costs anything, and only while resumed. The tasks keep it to business hours; suspend manually after ad-hoc use. Everything else (agent inference, grounding) is pay-per-call.

## Worked-example values (the reference deployment)
`{{DB}}`=GUPPIWHEEL, `{{SCHEMA}}`=PUBLIC, `{{AGENT_NAME}}`=GUPPI_REP_AGENT, `{{ROLE}}`=GUPPI_SLACK_BRIDGE_ROLE, `{{POOL}}`=GUPPI_SLACK_POOL, `{{EAI}}`=GUPPI_SLACK_EAI, `{{NETWORK_RULE}}`=SLACK_EGRESS_RULE, `{{IMAGE_REPO}}`=GUPPI_IMAGES, `{{SERVICE}}`=GUPPI_SLACK_BRIDGE, `{{WAREHOUSE}}`=SI_DEMO_WH, `{{TIMEZONE}}`=America/New_York, `{{RESUME_CRON}}`=`0 8 * * MON-FRI`, `{{SUSPEND_CRON}}`=`0 18 * * MON-FRI`.
