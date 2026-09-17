---
name: rsi
description: "The Guppi RSI (Recursive Self-Improvement) engine — Level 9 of the CoCo Maturity Model. Use when: running or explaining the RSI loop, onboarding a target, reading RSI runs, setting an accept margin, or understanding how Guppi improves what it builds. Triggers: RSI, recursive self-improvement, RSI_LOOP, RSI_ONBOARD, improve a prompt/recipe, target profile, accept margin, eval noise, RSI_MEASURE_NOISE, commit loop, level 9, recursion, self-improvement."
---

# RSI — the engine that improves what the wheel builds

RSI is **Level 9 (Recursion)** of the CoCo Maturity Model: the platform runs a
gated improvement loop over its own artifacts. It lives in a **separate database
from the wheel** — `GUPPI_RSI_ENGINE.CORE` — and is domain- and metric-agnostic:
it improves any text artifact (prompt, recipe, config) against any objective.

> **RSI is core but additive.** The wheel (`GUPPIWHEEL`) runs fine without the
> engine; RSI amplifies it. Initiatives that *use* RSI (a coding model, a signal
> pipeline, etc.) are ordinary initiatives — they are NOT part of this engine.

## Topology

- **`GUPPI_RSI_ENGINE.CORE`** — the engine. Tables: `RSI_RUNS` (iteration ledger),
  `RSI_TARGET_PROFILE` (per-target config + FQN step bindings), `EXPERIENCE_CARDS`
  + `CARD_USAGE` (endogenous memory), `AUDIT_FLAGS` (what shipped / pending),
  `RSI_NOISE_MEASUREMENTS` (measured eval noise). Procs: `RSI_DECIDE`, `RSI_LOG`,
  `RSI_NARRATE`, `RSI_MEASURE_NOISE`, `RSI_PROVISION/DEPROVISION/SYNC_TARGET`,
  card procs, generic `RSI_EVAL/PROPOSE/CHAMPION_CLASSIFY`. Workflows: `RSI_LOOP`
  (RIGHT — improve), `RSI_ONBOARD` (LEFT — initiative → self-improving target).
- **Wheel bridge (`GUPPIWHEEL.PUBLIC`)** — `RUN_TARGET_LIFECYCLE` (triggers
  `RSI_ONBOARD`) and `BUILD_SUBSTRATE` (Bob authors the eval substrate into the
  Epic). These are the entry points `BOB_AGENT` calls.

## The durable contracts (why this generalizes)

- **Metric/domain-agnostic loop.** `RSI_LOOP` binds its propose/eval/champion
  steps per-run by FQN from `RSI_TARGET_PROFILE.PROFILE.steps` — the engine
  ships no domain logic; a target supplies its own steps + objective + guard.
- **Three-tier human gate.** Tier-1 provision (human approves), Tier-2 commit
  (mode-gated: `do-not` vs `auto-build`), Tier-3 merge (always human). The loop
  can OPEN a PR; a human merges it.
- **The artifact is a recipe.** The thing being improved is text (a prompt or a
  JSON recipe) — so it is git-diffable, guardable, and auditable.
- **Measure eval noise; never guess the margin.** Run `RSI_MEASURE_NOISE` on a
  FROZEN champion before trusting a target's accept margin; set margin ≥ 2·SD.
  For a **deterministic** scorer, bootstrap over evaluation UNITS (repeat-runs
  give SD 0 and lie). Standing rule.
- **Preregister.** Record the objective/guard and any amendment BEFORE seeing the
  affected result.

## Honest maturity (say this, don't oversell)

Level 9 has a sub-ladder: 9.0 delegation → **9.1 net-positive** → 9.2 ignition →
9.3 inflection. The engine is **9.0 today** — it runs the gated loop end to end.
**9.1 is NOT established.** Do not claim "net-positive self-improvement" until
three gaps close: a fair human baseline, a **private** held-out score never
selected against, and a sustained multi-step trend (not a single iter-1 jump).
**Level 4 Trust (TARS, a different model on a held-out signal) is what keeps the
apex honest** — improvement is never self-approved.

## Running Bob — IMPORTANT surface caveat

`BOB_AGENT` carries the `code_toolset_all` tool (its coding sandbox). That tool
is supported on the **Agents REST API / `DATA_AGENT_RUN`** surfaces, **not** the
first-party Cowork chat UI — in Cowork the run starts then stops. Run Bob via the
See-the-Loop app / `DATA_AGENT_RUN` / REST, not Cowork.

## Install

Applied by `guppiwheel-bootstrap` after the wheel seeds:
`seeds/rsi/01_schema.sql` → `02_prereqs.sql` (ACCOUNTADMIN: compute pool +
`SNOWFLAKE.CORTEX_USER`, required) → `03_procs.sql` → `05_workflows.sql`
(run from repo root — the `PUT` paths are repo-root-relative). The optional
`04_commit_loop.sql` adds the git PR loop: edit the GitHub org and set the real
token out-of-band first — the seed ships a **tokenless placeholder** and never a
real secret.
