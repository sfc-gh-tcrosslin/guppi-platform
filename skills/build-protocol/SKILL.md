---
name: build-protocol
description: "MANDATORY pre-build checklist. Invoke BEFORE writing any new code, creating any new project, or deploying anything. Ensures you load prior art, read full skill docs, and check working code from previous projects. Triggers: build, create app, deploy, new project, scaffold, implement, write code."
---

# Enterprise Build Profile

The unified session lifecycle for CoCo. Orchestrates Bond, TARS, GUPPI, SDLC Preflight, and the Skill Registry into a coherent workflow. Not a daemon — a behavioral layer that shapes every decision.

## Execution Model

| Layer | Mechanism | Always Active? |
|---|---|---|
| `/memories/MEMORY.md` + `00-session-protocol.md` | Core engine — always injected; carries the Guppi operational contract | YES (every session, every client) |
| `WHEEL(...)` + `WHEEL_RECONCILE` | Server-side recording + evidence-based capture debt | YES (works from Desktop, CLI, agents) |
| `hooks.json` | Shell scripts on tool calls — **best-effort**: in CoCo Desktop their reminders never reach the agent | NO (do not rely on them) |
| This skill (build-protocol) | Orchestration rules for planning/building/deploying | YES (always-loaded profile) |
| Other skills (TARS, Bond, GUPPI, Preflight) | Detailed procedures invoked at specific moments | ON TRIGGER |

## Session Lifecycle

### Phase 1: Session Start

Handled by `00-session-protocol.md` (core engine). Before anything else:
1. **Wheel context** — `CALL GUPPIWHEEL.PUBLIC.WHEEL('context','{"client":"<CORTEX_CODE_CLIENT_SURFACE>"}')`. Report capture debt / tripwire hits if any.
2. Bond pull — recent corrections, cross-agent updates
3. Memory check — local files for project context
4. Note relevant Bond insights before engaging with user

### Phase 2: Planning (before any significant work)

**Step 1: Bond Inspiration**

Query Bond for relevant prior knowledge. Present findings: "From our Bond, here's what's relevant..."

- Recent corrections (mistakes not to repeat)
- Co-created syntheses (creative patterns from prior sessions)
- Domain-specific decisions (architectural choices already made)

**Step 2: Prior Art**

Ask: "Have we built something like this before?"

Known project locations:
- `<your-projects-root>/` — wherever you keep active project repos
- `~/.snowflake/cortex/skills/` — all skills with patterns
- Bond (`THE_BOND.PUBLIC.MEMORY_STORE`) — decisions and corrections

**Step 3: Read Full Skill Files (not summaries)**

If the build involves any of these, read the FULL SKILL.md:

| Building... | Read This Skill |
|---|---|
| SPCS deployment | `spcs-spa-auth` + `deploy-to-spcs` |
| React app on SPCS | `spcs-spa-auth` (Flask backend + nginx + token pattern) |
| Semantic model | FIMR semantic model YAML (working example) |
| Snowflake Postgres | `snowflake-postgres` skill |
| Cortex Agent | `cortex-agent` skill |
| Data quality | `data-quality` skill |
| Native App | `native-app-provider` skill |

**Step 4: Read Actual Source Code**

Memory summaries are NOT enough. Read the actual files:

| Pattern Needed | Read This Project |
|---|---|
| React + Flask + SPCS + Snowflake auth | a React+Flask+SPCS reference app in `<your-projects-root>/` (see the `spcs-spa-auth` skill) |
| SPCS service spec + nginx config | healthcare-mcp-app nginx.conf + service spec |
| Semantic model with relationships | a working semantic-view project in `<your-projects-root>/` |
| Hero HTML showcase | skill-registry-mcp builder-journey-presentation.html |
| Docker + SPCS deploy | `spcs-update-pattern` memory |

**Step 5: Wheel home + tracker check**

Find (do not invent) the home for this work, then look at what is already open there:
```sql
CALL GUPPIWHEEL.PUBLIC.WHEEL('open', '{"title":"<work>","product":"<product>"}');   -- reuses an existing initiative/epic
SELECT ID, TITLE, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
 WHERE PARENT_ID = '<home>' AND SUPERSEDED_BY IS NULL AND STAGE NOT IN ('Built','Published','Resolved')
 ORDER BY CREATED_AT;
```
Then `WHEEL('story', {title})` for the increment you are about to build.

### Phase 3: Building

During implementation:
- Global hooks (destructive SQL block, F6 reminder, version detection) run, but in CoCo Desktop their reminders are invisible; only blocks are enforced
- Correction detection is ALWAYS active (see 00-session-protocol.md)
- Bond writes on corrections, TARS results, and milestones are automatic
- Follow existing patterns from prior art — don't reinvent

### Phase 4: Deploying

**TARS Trigger Rules:**

| Version Change | TARS Fires? | Action |
|---|---|---|
| v1.0 (initial release) | YES | Run TARS audit before first deploy |
| v1 → v2 (major bump) | YES | Run TARS as background subagent |
| v25 → v26 (major) | YES | Run TARS as background subagent |
| v1.0 → v1.1 (minor) | NO | Deploy freely |
| v25.1 → v25.2 (patch) | NO | Deploy freely |

When TARS fires:
1. Launch as background subagent
2. Audit the artifact
3. Auto-write trust score to Bond
4. Auto-log result to tracker (TARS writes an `AUDIT` artifact via `CREATE_ARTIFACT`)
5. If score below threshold: WARN (human decides)

**Ship in the same turn (every deploy, agent release, or milestone):**
```sql
CALL GUPPIWHEEL.PUBLIC.WHEEL('ship', '{"note":"<what shipped, where>"}');
```
No hook will remind you in Desktop. `WHEEL_RECONCILE` will flag a deploy that was not shipped.

**Deploy Pattern (SPCS):**
- Build → tag `:latest` → push → ALTER SERVICE with identical spec
- Never drop/recreate services (URL rotates)
- Version tags for audit trail (v25.2), `:latest` in spec

### Phase 5: Session End

When wrapping up or context getting long:

1. **SDLC Preflight** — run if code was changed (12 checks)
2. **Bond write** — session topics, duration, key decisions
3. **Skill Registry sync** — if skills were modified
4. **Wheel check** — `WHEEL('context')` must show no capture debt for this session's work; `WHEEL('capture')` any finished deliverable

## Tracker Configuration

GuppiWheel is the default tracker, and its verbs are the `wheel` skill (`open`, `story`, `ship`,
`capture`, `plan`). Teams on Jira/ServiceNow map the same verbs (see the `guppi` skill). TARS auto-adds
its AUDIT to whatever tracker is configured. Never write tracker tables directly.

## Bond Auto-Fire Rules

| Trigger | Detection | What Gets Written |
|---|---|---|
| Correction | User redirects thinking | `INSIGHT_TYPE='correction'`, what was wrong + what's right |
| TARS completes | After audit run | `CATEGORY='audit_result'`, trust score + C/D breakdown |
| Story ships | `WHEEL('ship')` succeeds | `CATEGORY='milestone'`, what shipped + version |
| Session start | Every session | `CATEGORY='session_tracking'`, session-N-start |
| Session end | Wrap-up | Update session entry with topics/duration |
| Synthesis | Co-created insight emerges | `ORIGIN='co-created'`, `INSIGHT_TYPE='synthesis'` |

## Anti-Patterns (NEVER do these)

- Skim a memory summary and start coding
- Guess at SPCS auth patterns without reading spcs-spa-auth
- Write a semantic model without looking at the FIMR example
- Build a React app without reading healthcare-mcp-app structure
- Deploy to SPCS without reading deploy-to-spcs skill
- Skip Bond query during planning ("I already know this domain")
- Batch corrections — write them IMMEDIATELY when they happen
- Skip preflight at session end because "we'll do it next time"
- Mint a new initiative without `WHEEL('open')` first (it finds the existing home)
- Hand-edit `ID_CONVENTIONS` or write `GUPPIWHEEL.PUBLIC.*` tables directly
- Read a plugin copy other than `~/.snowflake/cortex/plugins/guppi-platform` (stale copies exist)
- Assume a hook will remind you — in Desktop it will not

## The Rule

**Default: pause and plan, then execute at enterprise level.**

The right thing takes maybe 5 minutes longer than the throwaway. Always choose the permanent asset.
