---
name: guppi-dist
description: "RETIRED distribution bundle (pre-GuppiWheel). Do not use. For operations use the `wheel` skill; for the viewer and concepts use the `guppi` skill."
---

# guppi-dist — RETIRED (v3.31.0)

This bundle described a standalone `GUPPI` database (`GUPPI.PLATFORM.STORIES`, `INCIDENTS`, `DEFECTS`,
`AUDIT_RUNS`, `QA_RUNS`) that has been retired (`DONOTUSEGUPPI`). Its bundled files (`tars/`,
`render_guppi.py`, `setup.sql`) are no longer shipped here, and its raw-`INSERT` instructions contradict
RULE-028/029.

- Operations (initiatives, stories, ship, capture, plans): **`wheel`** skill -> `CALL GUPPIWHEEL.PUBLIC.WHEEL(verb, args)`
- Viewer and concepts: **`guppi`** skill
- New-account install: **`guppiwheel-bootstrap`** skill

The previous content is in git history (`git log -- skills/guppi-dist/SKILL.md`).
