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
- `wheel publish-plan <file>` — publish a `.plan.md` as a NARRATIVE under current initiative
- `wheel link-commit <sha>` — append `Wheel: INIT-N` footer to a not-yet-pushed commit

## Session-current state

The active initiative for the current session lives at `~/.snowflake/cortex/.guppi-platform-state.json`. Hooks read/write this file. The skill's commands manipulate it.

```json
{
  "current_initiative": "INIT-29",
  "set_at": "2026-06-05T17:30:00Z",
  "session": "<session_id>"
}
```

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

List all my non-Narrated initiatives:

```sql
SELECT ID, TITLE, STAGE, 
       DATEDIFF('day', UPDATED_AT, CURRENT_TIMESTAMP()) AS days_at_stage,
       (SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS c WHERE c.PARENT_ID = a.ID) AS children
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE TYPE = 'INITIATIVE' 
  AND OWNER = CURRENT_USER()
  AND STAGE != 'Narrated'
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

Hooks (`hooks/lifecycle.sh post-create-plan`, `post-switch-mode`, `pre-push`) provide automatic enforcement. This skill provides explicit gestures.

## Note on wheel-platform separation

`wheel start` works for any account that has `GUPPIWHEEL.PUBLIC` installed. The skill doesn't care which plugin you're working in. Sister plugins can adopt the same loop by importing the wheel skill.
