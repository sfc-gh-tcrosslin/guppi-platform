# COCO.md — Read this first

You are a CoCo (Cortex Code agent) looking at a cloned **guppi-platform** repo. This file is the
**contract** for working with it. Read it before you change anything.

**Guppi** is a value-creation engine on Snowflake. Brand hierarchy:

> **Guppi** (the product) → **GuppiWheel** (the engine / `GUPPIWHEEL` database) → **Rocky / Cowork / TARS / Stewart** (the agents) → **CoCo** (you, the interface)

The wheel is one idea: a single `GUPPIWHEEL.PUBLIC.ARTIFACTS` table is the source of truth, and every
initiative, research synthesis, app, model, narrative, defect, incident, and audit lives in it. Doctrine
lives as data in `RULES`. This is **our journey, not objective truth** — and that applies to *your* wheel
too. The invariants below are the soul; everything else is yours to shape.

---

## The contract: three tiers

This repo is tiered on purpose. Before you rewrite something, know which tier it is in.

### Tier 0 — INVARIANTS (enforced; do **not** alter the guarantee)
These *are* Guppi. Re-author the SQL if you like, but the **guarantee must survive** — if you break one,
you no longer have Guppi, you have something else. The conformance gate (below) checks every one.

1. **Single source of truth.** Every artifact type lives in `GUPPIWHEEL.PUBLIC.ARTIFACTS`. No parallel tables of record.
2. **No duplicate IDs, ever.** `DUPLICATE_ID_SCREAM_V` must read 0 rows; `COUNT(DISTINCT ID) = COUNT(*)`.
3. **Gap-free sequential IDs.** Allocated atomically from the `ID_CONVENTIONS` registry (UPDATE-then-read inside the one write proc). **Do not** use Snowflake `SEQUENCE` objects for IDs — they leave large gaps.
4. **One gated write path.** `CREATE_ARTIFACT` is the only way artifacts are written; direct `INSERT` on `ARTIFACTS` is revoked. Add new write behavior *through* the proc, not around it.
5. **Doctrine is data.** Enabled rows in `RULES` are authoritative. Agents read doctrine; they do not paraphrase or hardcode it.
6. **Sub-agents propose, never change doctrine** (RULE-027 / STO-36-O). A sub-agent (e.g. Stewart) emits proposal artifacts. It never writes `RULES`, never sets `SUPERSEDED_BY`, never edits serving surfaces. This is structural, not just RBAC — and Stewart also watches the owner's own writes, because the table owner bypasses RBAC.
7. **Headless-first** (RULE-013). Outputs are artifacts; rendering reads *from* artifacts. Never make a local file the primary output.
8. **Lifecycle.** `Initiate → Research → Building → Built → Narrated` (OUTCOME runs its own `ASPIRATIONAL → SELECTED → TRACKED → RESOLVED` track). There is no "archived" — a follow-on is a new artifact at Initiate.

### Tier 1 — DEFAULTS (works on clone; yours to change)
Ships fully-specified so it runs on first pull. Nothing here says "keep it." Re-author to your style as
long as Tier 0 still holds.
- The **procedures** (`CREATE_ARTIFACT`, `ADVANCE_STAGE`, `SUBMIT_INITIATIVE`, `ROCKY_EXECUTE`, `STEWART_AUDIT`, `PROPOSE_CORRECTION`, …) — shapes are ours; the chokepoint guarantee (Tier 0 #4) is not.
- The **agents** (`ROCKY_AGENT`, `GUPPIWHEEL_COWORK_AGENT`, `STEWART_AGENT`) and their instructions.
- **Compute wiring.** We do **not** dictate a warehouse. `05_agents.sql` binds agents to your *active* warehouse (`CURRENT_WAREHOUSE()`) and runs `ROCKY_TASK` serverless. Change the binding however you want.
- The **viewer** (`skills/guppi`) and the semantic view shape.

### Tier 2 — SUGGESTIVE (please author to taste)
We deliberately did not specify these. Make them yours.
- Task cadence, budgets, scheduling.
- Cosmetics, naming flavor, viewer UI.
- Extra agents, extra tooling, extra rules (add `RULES` rows — that *extends* doctrine, it does not alter Tier 0).

---

## You got Guppi when the conformance gate passes

"Got Guppi" does **not** mean "ran our exact files." It means the install satisfies Tier 0. Run the gate
after any build or re-author:

```sql
-- Definition of done. Every row should report PASS.
SELECT * FROM GUPPIWHEEL.PUBLIC.GUPPI_CONFORMANCE_V;
```

If `GUPPI_CONFORMANCE_V` is absent (older install), the underlying checks are:

```sql
SELECT 'no-duplicate-ids' AS check, IFF(COUNT(*)=0,'PASS','FAIL') AS status FROM GUPPIWHEEL.PUBLIC.DUPLICATE_ID_SCREAM_V
UNION ALL SELECT 'grounding-health', IFF(COUNT(*)=0,'PASS','FAIL') FROM GUPPIWHEEL.PUBLIC.GROUNDING_HEALTH_V
UNION ALL SELECT 'ids-distinct', IFF(COUNT(DISTINCT ID)=COUNT(*),'PASS','FAIL') FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
UNION ALL SELECT 'rules-present', IFF(COUNT(*)>0,'PASS','FAIL') FROM GUPPIWHEEL.PUBLIC.RULES WHERE ENABLED;
```

Or just ask **Stewart**: he runs a read-only grounding/hygiene scan and proposes fixes (he never applies them).

---

## Install

See `README.md`. Short version: a warehouse must be active (`USE WAREHOUSE <your_wh>;`), then run the five
engine seeds in order, then `bootstrap.sql` once on a fresh account, then the viewer. Each `seeds/engine/*.sql`
file carries a `TIER:` header so you can see, inline, what you may freely re-author.
