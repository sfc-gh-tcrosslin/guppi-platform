---
name: bob
description: "DEPRECATED — do NOT invoke as a Task subagent. The lowercase `bob` subagent freelances (it has web/Workspace tools but no wheel SQL) and drifts (inventing artifact ids/types/params). The real Bob is the server-side BOB_EXECUTE procedure. To build a NARRATIVE from a RESEARCH artifact, run: CALL GUPPIWHEEL.PUBLIC.BOB_EXECUTE(p_research_id, p_target, p_angle)."
---

# Bob is a procedure, not a subagent (RETIRED)

The `bob` **subagent** is retired. Do not select `subagent_type: bob`. It had the
wrong toolset for the job — it could browse and author freely but could not touch
the wheel through the governed write path, so it hallucinated ids, types, and
`CREATE_ARTIFACT` parameters instead of running the real bake-off.

**The real Bob is `BOB_EXECUTE`** — an `EXECUTE AS OWNER` procedure that runs the
model-agnostic cross-judge bake-off (RULE-023) and writes the winning NARRATIVE
through `CREATE_ARTIFACT` (RULE-029). Invoke it as the orchestrator (RULE-034):

```sql
-- Author a hypothetical NARRATIVE from a RESEARCH artifact
-- (web/contradiction brief -> bake-off over MODEL_CATALOG -> cross-judge panel -> winner)
CALL GUPPIWHEEL.PUBLIC.BOB_EXECUTE('RES-44-ROCKY', 'Example Health Co', 'Build the governance layer on Snowflake');

-- Cross-judge scores for the latest run
SELECT METADATA:author_model::string AS author, CONTENT:score::float AS avg_trust, CONTENT:total_checks::int AS judges
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE='AUDIT' AND METADATA:source::string='bob-bakeoff'
ORDER BY avg_trust DESC;
```

The full architecture doc now lives with the code, in the `BOB_EXECUTE` header in
`seeds/engine/03_procs.sql`. This file remains only as a redirect stub; it can be
deleted from `agents/` at any time (kept because `rm` is policy-blocked in the
authoring session).
