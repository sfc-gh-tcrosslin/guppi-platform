---
name: wheel
description: "Wheel discipline gestures for guppi-platform: open initiatives, publish plans as narratives, link commits to initiatives. Use when user says: wheel start, wheel current, wheel status, wheel publish plan, wheel link commit, what am I working on, open an initiative, dogfood, RULE-013 reminder, headless first."
---

# /wheel — Use Guppi to Build Guppi

Explicit gestures that wrap the dogfood loop. Hooks fire automatically; this skill is the human escape hatch when hooks miss or you want to be deliberate.

## Triggers

- `wheel start "<title>"` — open a new initiative
- `wheel current` — show my active initiative
- `wheel status` — list my open initiatives across all stages
- `wheel capture <file>` — **push a finished deliverable into the wheel** (PUT + PUBLISH_ARTIFACT + provenance)
- `wheel publish-plan <file>` — publish a `.plan.md` as a NARRATIVE under current initiative
- `wheel link-commit <sha>` — append `Wheel: INIT-N` footer to a not-yet-pushed commit

## Session-current state

The active initiative for the current session lives at `~/.snowflake/cortex/.guppi-platform-state.json`.
This is the **single canonical path** — both `hooks/lifecycle.sh` and this skill's commands read and
write it. (Before 2026-08-16 the hook used `$CORTEX_PROJECT_DIR/.cortex-plugin/.state.json` while
this skill used the path above: split brain. `CORTEX_PROJECT_DIR` is normally unset, so the hook
resolved state against cwd, failed to write, and died under `set -e`. Nothing persisted and
`current_initiative` was permanently null. Do not reintroduce a second location.)

```json
{
  "phase": "ad-hoc",
  "active_skill": null,
  "refs_read": [],
  "current_initiative": "INIT-29",
  "pending_captures": [
    {"path": "/Users/me/Downloads/deck.html", "sha256": "...", "ts": "2026-08-16T12:00:00Z"}
  ],
  "last_updated": "2026-08-16T12:00:00Z"
}
```

`pending_captures[]` is capture debt: deliverables that exist as local files but not yet as
artifacts. The `pre-write` hook appends to it; `/wheel capture` removes entries; the `stop` hook
lists whatever remains.

## Commands

### wheel start "<title>"

Asks for the hypothesis (one sentence) and instructions (what success looks like). Then:

```sql
CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(
  '<title>',
  '<hypothesis>',
  '<instructions>'
);
-- Returns: 'Submitted: INIT-N (Initiate). Rocky picks up within 5 minutes.'
```

Capture the returned `INIT-N` and write it to the state file:

```bash
echo "{\"current_initiative\":\"INIT-N\",\"set_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > ~/.snowflake/cortex/.guppi-platform-state.json
```

Confirm to user: `Opened INIT-N. All work this session links here.`

### wheel current

Read state file, query the initiative:

```sql
SELECT ID, TITLE, STAGE, OWNER, CREATED_AT,
       (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS c WHERE c.PARENT_ID = a.ID) AS children
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE ID = :current_initiative;
```

Show ID, title, stage, child count, days at stage. If no current, suggest `wheel start`.

### wheel status

List all my non-Published initiatives:

```sql
SELECT ID, TITLE, STAGE, 
       DATEDIFF('day', UPDATED_AT, CURRENT_TIMESTAMP()) AS days_at_stage,
       (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS c WHERE c.PARENT_ID = a.ID) AS children
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE TYPE = 'INITIATIVE' 
  AND OWNER = CURRENT_USER()
  AND STAGE != 'Published'
ORDER BY UPDATED_AT DESC;
```

Render as a table grouped by stage.

### wheel publish-plan <file>

Given a plan file path (default: most recent `.plan.md` in `~/.snowflake/cortex/plans/` or `playground/.../plans/`):

1. Read state file to get current initiative
2. PUT plan markdown to `@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/plans/<basename>`
3. Call `PUBLISH_ARTIFACT` with TYPE=NARRATIVE, parent=current_initiative, app_type=static_html
4. Confirm: `Published <basename> as NAR-N under INIT-X`

If no current initiative, error: `Open one first with /wheel start, or pass --parent INIT-N explicitly.`

### wheel capture <file> [--title "..."] [--description "..."] [--template default] [--supersede ID]

**The one verb for getting creative desktop work into the wheel.** Same sequence every time — no
judgment calls, no improvisation. This is the antidote to the drift documented in RULE-013:
iterate freely in scratch, then capture at the milestone.

**Never** hand-write `INSERT`/`UPDATE` against `ARTIFACTS` or `ID_CONVENTIONS`, and **never** pass
`P_EXPLICIT_ID`. The procedure allocates IDs (RULE-029). As of 2026-08-16 the desktop session runs
as `GUPPIWHEEL_CONTRIBUTOR`, so direct DML is *denied* anyway — but the discipline is the point.

Steps:

1. **Resolve the initiative.** Read `current_initiative` from the state file. If absent, stop and
   tell the user to run `/wheel start` (or accept `--parent INIT-N`).

2. **Sandbox-lint any HTML** before staging. Snowflake renders staged HTML in a strict sandbox.
   Reject and report if the file contains:
   - remote or sibling `<script src=...>` / `<link href=...>` (CDN, `./three.min.js`, etc.)
   - inline event handlers (`onclick=`, `onload=`, ...)
   - `eval(` or runtime network calls (`fetch(`, `XMLHttpRequest`)

   A file that fails the lint renders locally but **breaks when shared from the wheel**. Either
   inline the dependency (self-contained) or capture it as an `APP` with the limitation stated.

3. **PUT the bytes** (contributor holds WRITE on the stage):

```sql
PUT 'file://<abs-path>' '@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/<INIT-N>/<YYYYMMDD>/'
    AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```

4. **Register through the chokepoint.** Pick `app_type` from the extension:
   `.html -> static_html`, `.pdf -> pdf`, service -> `spcs_service`, Streamlit -> `streamlit`.

```sql
CALL GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(
  'NARRATIVE',                      -- or APP; see class split below
  '<title>',
  '<description>',
  '{"app_type":"static_html","stage_path":"@GUPPIWHEEL.PUBLIC.ARTIFACT_ASSETS/<INIT-N>/<YYYYMMDD>/<basename>"}',
  '<INIT-N>', NULL, 'internal'
);
```

`PUBLISH_ARTIFACT` validates the launch spec then delegates the INSERT to `CREATE_ARTIFACT`,
preserving the single write path and satisfying RULE-018 / CMP-003.

5. **Stamp provenance.** CoCo Desktop already attaches a `QUERY_TAG` carrying
   `desktop_session_id`, `agent_session_id`, and `tool_use_id` to every statement it issues — so
   session lineage is recoverable from `QUERY_HISTORY` without extra work. Record `source_path` and
   the file `sha256` in artifact metadata so a re-capture can be recognized.

6. **Supersede, do not duplicate.** If this deliverable was captured before (same `source_path`
   under the same initiative), set `SUPERSEDED_BY` on the prior artifact via the governed path
   rather than creating a sibling (RULE-025 keeps serving surfaces on current truth).

7. **Render-parity check.** Confirm the shared bytes actually resolve — verify the artifact, not
   just the local file:

```sql
CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH('<ID>', 60);
```

8. **Clear the debt.** Remove the entry from `pending_captures[]` in the state file and confirm:
   `Captured <basename> as <ID> under <INIT-N>`.

#### NARRATIVE vs APP — which class?

- **NARRATIVE** — the default. Content lives as template-stamped sections and the canonical
  renderer (`ENSURE_NARRATIVE_HTML`) produces the HTML. Consistent order, headings, and styling
  across everything we publish; sandbox-safe by construction. Always declare a `template`
  (`default`, `account_brief`, `internal_plan`, `position`) so sections are validated and rendered
  in `NARRATIVE_TEMPLATE.ORD` with registry `HEADING`s.
- **APP** — bespoke interactive output (custom slide deck, WebGL hero, Streamlit). Hand-authored
  HTML belongs here, registered with its own `app_type` and an explicit note about sandbox limits.
  Do not mislabel a hand-built deck as a NARRATIVE: it will not match the canonical render.


### wheel link-commit <sha>

For not-yet-pushed commits only. Verify:

```bash
git log <sha> --not --remotes 2>/dev/null
```

If returns the sha, the commit hasn't been pushed. Run `git rebase -i` to amend the message with `Wheel: INIT-N` footer (interactive). Or for the most recent commit: `git commit --amend -m "$(git log -1 --format=%B)\n\nWheel: INIT-N"`.

If commit was already pushed, refuse: `Cannot rewrite pushed history. Add a follow-up commit referencing the initiative instead.`

## RULE references

This skill exists because of:

- RULE-013 Headless First — every output is an artifact
- RULE-014 Status Ownership — submitter sets Initiate
- RULE-018 Launchables Live in the Wheel — bytes belong in stage
- RULE-025 Current truth only — re-capture supersedes, it does not duplicate
- RULE-029 Single write chokepoint — `CREATE_ARTIFACT` allocates IDs; never pass an explicit ID
- RULE-033 JSON bodies — long-form prose lives in `CONTENT.body_md`
- RULE-034 Least privilege — the session runs as `GUPPIWHEEL_CONTRIBUTOR`

Enforcement is layered, because any single layer drifts:

| Layer | Control | Type |
|---|---|---|
| Identity | session runs as `GUPPIWHEEL_CONTRIBUTOR` (no DML on `ARTIFACTS`/`RULES`/`ID_CONVENTIONS`) | preventive |
| Gate | `pre-write` blocks creating a new deliverable with no initiative; warns on edit | preventive |
| Verb | `/wheel capture` — one deterministic path through the procs | procedural |
| Render | `ENSURE_NARRATIVE_HTML` + `NARRATIVE_TEMPLATE` — one renderer, one design system | procedural |
| Detective | `DIRECT_DML_TRIPWIRE_V` catches the owner/ACCOUNTADMIN bypass RBAC cannot bind | detective |
| Maintenance | `RESYNC_ID_SERIES` (forward-only, admin) — removes any reason to hand-edit counters | procedural |


Hooks (`hooks/lifecycle.sh post-create-plan`, `post-switch-mode`, `pre-push`) provide automatic enforcement. This skill provides explicit gestures.

## Note on wheel-platform separation

`wheel start` works for any account that has `GUPPIWHEEL.PUBLIC` installed. The skill doesn't care which plugin you're working in. Sister plugins can adopt the same loop by importing the wheel skill.
