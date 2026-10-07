---
name: wheel
description: "The ONE operational skill for GuppiWheel: what am I working on, open/reuse an initiative, create a story, ship a story after a deploy, capture a deliverable, publish a plan, fix the wheel. Everything goes through CALL GUPPIWHEEL.PUBLIC.WHEEL(verb, args). Use when user says: wheel, wheel context, what am I working on, open an initiative, start work, new story, ship it, I deployed, capture this, publish plan, record this in guppi, capture debt, tripwire, dogfood, RULE-013."
---

# /wheel — the operational front door

Every operational interaction with GuppiWheel is **one call**:

```sql
CALL GUPPIWHEEL.PUBLIC.WHEEL('<verb>', '<json args>');
```

`WHEEL` routes to the governed procs (`CREATE_ARTIFACT`, `ADVANCE_STAGE`, `PUBLISH_ARTIFACT`,
`CREATE_NARRATIVE`, `REPARENT_ARTIFACT`, `UPDATE_OWN_ARTIFACT`). It adds no write path of its own.
Session state lives server-side in `WHEEL_CONTEXT`, so it is the same from CoCo Desktop, the CLI,
agents and Slack. Run as `GUPPIWHEEL_CONTRIBUTOR`.

**Never** write `GUPPIWHEEL.PUBLIC.*` tables directly and never pass an explicit ID for a numbered
type (only slug types like OPS_EVENT take one). If `WHEEL` cannot do it, it is an admin repair (`WHEEL_ADMIN`, below) or a gap to report.

## Client awareness (do this first)

| | CoCo Desktop | CoCo CLI |
|---|---|---|
| Detect | agent shell: `CORTEX_CODE_CLIENT_SURFACE=coco_desktop` | `CORTEX_TERMINAL_LAUNCHER_SOURCE=cli` |
| Hooks run | yes | yes |
| Hook reminders reach the agent | **no** (measured 2026-10-06) | not yet measured |
| Hook blocks enforced | yes, but reason text hidden | not yet measured |

Source of truth is the `CLIENT_CAPABILITIES` table, returned by `context`. In Desktop **no reminder will
ever reach you**: record `ship`/`capture` in the same turn as the work, not "later".

## The loop

```
context  ->  open  ->  story  ->  (build)  ->  ship  ->  capture / plan
```

| Verb | Args | What it does |
|---|---|---|
| `context` | `{"client":"coco_desktop"}` | Records the client; returns current initiative/story/product, client capabilities, open **capture debt**, last-24h **tripwire** hits, stale `Building` stories, and guidance. **First call of every session.** |
| `open` | `{"title","product"}` or `{"parent":"INIT-N"}` | **Reuses** the best existing initiative/epic for the product and sets context to it. Mints new only with `"force":true,"reason":"..."`. Never mint because the title is new. |
| `story` | `{"title","content"?, "stage"?, "product"?, "parent"?}` | Creates a STORY under the current context. ID derived by `CREATE_ARTIFACT` (next `<PRODUCT_PREFIX>-N`). Sets it as current story. |
| `ship` | `{"note","id"?, "stage"?="Built"}` | Advances the story (`ADVANCE_STAGE`), appends the note to `CONTENT.shipped[]`, clears the product's open capture debt. **Call after every deploy / agent release / milestone, in the same turn.** |
| `capture` | `{"stage_path","title","description"?, "kind"?="APP", "app_type"?, "parent"?}` | Registers a deliverable you already `PUT` (see below). Inherits the parent's product. |
| `plan` | `{"title","sections":{"summary","context","phased_plan","risks","why_now"}}` | Publishes a plan as an `internal_plan` NARRATIVE under context. |
| `reparent` | `{"id","parent","reason"}` | Moves an artifact you own (`REPARENT_ARTIFACT`). |
| `preview` | `{"type","product"?}` | The ID that would be allocated next (read-only). |
| `help` | `{}` | Lists verbs. |

Examples:

```sql
CALL GUPPIWHEEL.PUBLIC.WHEEL('context', '{"client":"coco_desktop"}');
CALL GUPPIWHEEL.PUBLIC.WHEEL('open',    '{"title":"Proposed tab","product":"chemlens"}');   -- -> reuses E-50
CALL GUPPIWHEEL.PUBLIC.WHEEL('story',   '{"title":"Browsable Proposed tab"}');
CALL GUPPIWHEEL.PUBLIC.WHEEL('ship',    '{"note":"Proposed tab live in SnowBeaker (snow app deploy)"}');
```

## Capture debt (why you will be caught)

`WHEEL_RECONCILE` runs hourly (`WHEEL_RECONCILE_TASK`). It reads `ACCOUNT_USAGE.QUERY_HISTORY` for build
evidence in each product's `PRODUCT_FOOTPRINT`:

- `DEPLOY` — `ALTER WORKSPACE ... ADD LIVE VERSION` (what `snow app deploy` issues)
- `AGENT_RELEASE` — `ALTER AGENT ... DEFAULT_VERSION / COMMIT`
- `SCHEMA` — `CREATE` table/view/semantic view/function/procedure

Evidence with no later wheel touch for that product and user becomes a `CAPTURE_DEBT` row, surfaced by
`context` and `OPS_DIGEST_V`. `ship` and `story` clear it. ACCOUNT_USAGE lags 45 min to 3 h, so this is
a backstop, not a substitute for shipping in-turn. A new product needs a `PRODUCT_FOOTPRINT` row.

## capture: putting a file in the wheel

1. **Sandbox-lint HTML** first. Snowflake renders staged HTML in a strict sandbox. Reject if it has
   remote or sibling `<script src>` / `<link href>`, inline handlers (`onclick=` ...), `eval(`,
   `fetch(` or `XMLHttpRequest`. A file that fails renders locally but breaks when shared.
2. **PUT the bytes** (no spaces in the staged filename):
   ```sql
   PUT 'file://<abs-path>' '@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/<PARENT>/<YYYYMMDD>/' AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   ```
3. `WHEEL('capture', {"stage_path": "...", "title": "...", "kind": "APP"})`.
4. **Render-parity check:** `CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH('<ID>', 60);`

**NARRATIVE vs APP.** NARRATIVE = template-stamped sections rendered by `ENSURE_NARRATIVE_HTML`
(use `plan`, or `CREATE_NARRATIVE` for other templates). APP = bespoke interactive output (hand-built
deck, WebGL hero, Streamlit). Do not label a hand-built deck a NARRATIVE.

## IDs (3.32.0): derived, never counted

- **Global types** take their prefix from `TYPE_REGISTRY.ID_PREFIX` (`INIT-`, `E-`, `NAR-`, `APP-`, `W-`, `AUDIT-`...).
- **STORY / DEFECT** take the product's stem: `PRODUCTS.ID_PREFIX` + `-` (story) or `-D` (defect): `PLAT-62`, `PLAT-D9`.
- The number is `MAX(existing)+1`, computed by `CREATE_ARTIFACT` inside the lock that serializes every insert
  (`ID_SERIES_V` is the one definition). No counters, so nothing can drift and nothing needs resyncing.
- **New product** = `CREATE_PRODUCT(id, name, description)`. Its stem defaults to the id upper-cased, letters/digits
  only (`my-product` -> `MYPRODUCT`); a shorter stem is `SET_PRODUCT_PREFIX` (admin). A stem is never shared.
- An unregistered product, or a numbered type with no prefix, is a **loud error** with a hint, never a silent fallback.

## Admin repairs — `WHEEL_ADMIN` (GUPPIWHEEL_ADMIN only)

| Verb | Args | Delegates to |
|---|---|---|
| `merge` | `{"duplicate","survivor","reason"}` | `MERGE_ARTIFACTS` (re-parents children, supersedes the duplicate) |
| `retag` | `{"id","product","reason"}` | `RETAG_PRODUCT` |

Kept out of `WHEEL` on purpose: `WHEEL` runs as owner, so wrapping admin procs there would hand admin
power to every contributor.

## Ops digest

```sql
SELECT * FROM GUPPIWHEEL.PUBLIC.OPS_DIGEST_V;
```

One row per hygiene check: capture debt, tripwire (7d), stale `Building` stories, duplicate ID-registry
entities, shared ID prefixes, products missing from `PRODUCTS`.

## link-commit (git)

For not-yet-pushed commits: append a `Wheel: INIT-N` footer
(`git commit --amend -m "$(git log -1 --format=%B)\n\nWheel: INIT-N"`). Refuse for pushed commits;
add a follow-up commit instead.

## Hooks

`hooks/lifecycle.sh` is best-effort. In Desktop its reminders are invisible to the agent, and the
plugin's relative hook command does not resolve from the workspace cwd. Do not rely on hooks for
recording. The legacy local file `~/.snowflake/cortex/.guppi-platform-state.json` is a cache at most;
`WHEEL_CONTEXT` is the source of truth.

## RULE references

- RULE-013 Headless First — every output is an artifact
- RULE-014 Status Ownership — submitter sets Initiate
- RULE-018 Launchables Live in the Wheel — bytes belong in stage
- RULE-025 Current truth only — re-capture supersedes, it does not duplicate
- RULE-028/029 Procedure-mediated writes; `CREATE_ARTIFACT` is the single chokepoint
- RULE-033 JSON bodies — long-form prose lives in `CONTENT.body_md`
- RULE-034 Least privilege — the session runs as `GUPPIWHEEL_CONTRIBUTOR`
