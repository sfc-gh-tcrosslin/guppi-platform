---
name: guppi
description: "GUPPI command-center VIEWER and concepts for GuppiWheel (read-only). Use for: show guppi, open guppi, refresh guppi, guppi viewer, command center, flywheel view, what is guppi, external tracker (Jira/ServiceNow) mapping. For ANY operational action (open initiative, create/ship a story, capture a deliverable, publish a plan, fix the wheel) use the `wheel` skill instead."
---

# GUPPI — command-center viewer + concepts

> Plan work. Do work. Track work. Verify work. Remember everything.

GUPPI is the AI-native SDLC + Ops + QA platform that runs entirely in Snowflake. Its system of record
is **one table, `GUPPIWHEEL.PUBLIC.ARTIFACTS`**, and every operational write goes through
`CALL GUPPIWHEEL.PUBLIC.WHEEL(verb, args)` — see the **`wheel` skill**. This skill covers the viewer
and the concepts.

> The older `GUPPI` database (`GUPPI.PUBLIC.STORIES`, `GUPPI.OPS.INCIDENTS`, `GUPPI.AUDITS.*`,
> `GUPPI.PLATFORM.*`, `GUPPI.QA`) is **retired** (renamed `DONOTUSEGUPPI`). Never read or write it.
> Never compute or increment IDs yourself: `CREATE_ARTIFACT` allocates them (RULE-029).

## Running the viewer

```bash
pip install -r skills/guppi/requirements.txt
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 skills/guppi/render_guppi.py --serve
```

Open http://localhost:8888. Two tabs:
- **Command Center** — SDLC view (epics, stories, defects, incidents, audits, initiatives)
- **Flywheel** — single-list initiative view; click to expand for child counts and the Open button on launchable artifacts

Without `--serve`, the script writes a static HTML to `~/Downloads/GUPPI.html` and exits. The viewer
reads `GUPPIWHEEL.PUBLIC.ARTIFACTS` (+ `PRODUCTS`) and is **read-only**; all mutations happen through
`WHEEL`. Embedded JSON + client-side filtering handles 10K+ artifacts without a server.

When the user says "show guppi" / "refresh guppi" / "open guppi": run `render_guppi.py`, then open the
result with `open_browser`.

## Headless architecture

- **The database IS the application.** `GUPPIWHEEL` tables are the system of record.
- **CoCo IS the interface.** "Create a story", "ship it", "what am I working on" are `WHEEL` verbs.
- **HTML is a read-only report** (the viewer, staged APPs/NARRATIVEs), never an input mechanism.
- **Any SQL client works** for reading: Snowsight, dbt, Tableau. Writes stay procedure-mediated (RULE-028).

## The model (one table, typed rows)

| TYPE | ID series | Notes |
|---|---|---|
| INITIATIVE | `INIT-N` | Hypothesis-level work; Rocky researches new ones |
| EPIC | `E-N` | A large story that decomposes into stories (not a product, team, or release) |
| STORY | `<PRODUCT_PREFIX>-N` (e.g. `PLAT-60`, `CHEMLENS-22`) | Stem from `PRODUCTS.ID_PREFIX`; number derived |
| DEFECT | `<PRODUCT_PREFIX>-DN` (e.g. `PLAT-D9`) | A code bug is a DEFECT, not an incident |
| INCIDENT | `INC-N` | An operational event with its own lifecycle; may produce a DEFECT |
| NARRATIVE / APP | `NAR-N` / `APP-N` | Rendered deliverables (template-stamped vs bespoke) |
| AUDIT | `AUDIT-N` | TARS trust audits (see `tars-trust-auditor`) |
| WIDGET | `W-N` | Reusable building blocks (`GUPPI_LIB`) |

Products live in `GUPPIWHEEL.PUBLIC.PRODUCTS`. A product that is not registered there will not be stamped
on artifacts (and reconcile cannot see its work): register it with `CREATE_PRODUCT` first.

## Domain rules

1. **Record in the wheel, not the conversation.** Anything worth mentioning is worth an artifact (`WHEEL`).
2. **Check templates before writing a story** (`NARRATIVE_TEMPLATE` for narratives; prior stories in the epic).
3. **Defects block features.** A P1 conformance DEFECT is resolved before feature work continues on that component.
4. **Incidents are not defects.** Operational events are INCIDENTs; code bugs are DEFECTs.
5. **Model cards live in product DBs** (e.g. `NCPDP_F6.PUBLIC.MODEL_CARDS`); wheel artifacts link to them.
6. **Every deploy gets a story update** — `WHEEL('ship', ...)` in the same turn. `WHEEL_RECONCILE` flags deploys that were not.

## External trackers (Jira / ServiceNow)

GuppiWheel is the default backend. Teams on another tracker map the same abstract verbs:

| Verb | GuppiWheel (default) | Jira MCP | Manual (Bond only) |
|---|---|---|---|
| open / create work | `WHEEL('open')`, `WHEEL('story')` | `jira_create_issue` | Bond `CATEGORY='task_backlog'` |
| update / complete | `WHEEL('ship')` | `jira_transition_issue` | Bond milestone |
| query backlog | `SELECT ... FROM GUPPIWHEEL.PUBLIC.STORIES_V` | `jira_search` | Bond query |
| log audit result | TARS writes an `AUDIT` via `CREATE_ARTIFACT` | `jira_add_comment` | Bond `CATEGORY='audit_result'` |

MCP connection patterns:
```
Jira:        jira-mcp (community or Atlassian official); API token as a Cortex secret
ServiceNow:  servicenow-mcp; OAuth2 as a Cortex secret
```

## Sub-skill files

`sdlc/`, `ops/`, `audits/`, `qa/`, `admin/` READMEs are **legacy design notes** for the retired GUPPI
database. Their concepts (incident lifecycle, TTD/TTM/TTR, post-mortems) still apply; their SQL does not.
