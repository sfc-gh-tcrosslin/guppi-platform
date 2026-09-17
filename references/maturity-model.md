# CoCo Maturity Model

Nine levels of AI engineering maturity. Most teams are at Level 1.

| Level | Name | Description |
|-------|------|-------------|
| 1 | Ad-Hoc | Agent + human building things. No reuse, no process. |
| 2 | Skills | Repeatable patterns extracted. Agent learns from yesterday. |
| 3 | Enterprise SDLC | Enterprise-level quality checks with disciplined delivery. |
| 4 | Trust | Independent audit (TARS). Quantified confidence. No self-approval. |
| 5 | Ecosystem | Shared registry, cross-account collaboration, feedback loops. |
| 6 | Shared Cognition | Persistent memory, co-created knowledge that compounds. |
| 7 | Initiative | Agents self-organize, generate insights, predict trajectories, initiate without prompting. |
| 8 | Representation | Agents represent their owner/team to others — answering on their behalf, grounded in the corpus. |
| 9 | Recursion | The engine improves the things it builds — and ultimately itself — under independent (Level 4) gating. The wheel turns the wheel. |

## Level 9 — Recursion (RSI)

Recursion is the apex: the platform runs a gated improvement loop over its own
artifacts (prompts, recipes, configs). Two decisions that matter:

- **Autonomy is not a separate level.** It is Level 7 (Initiative) — the RSI
  *floor*. Recursion is what Initiative compounds into once the loop can improve
  the artifact, not just act on it.
- **Level 4 (Trust) is what keeps Recursion honest.** Improvement is only real
  if graded on a held-out signal by a *different* model — never self-approved.
  TARS is the guardrail that makes the apex trustworthy rather than reward-hacked.

Level 9 has its own sub-ladder (after Weco's first-evidence-of-RSI work):
9.0 delegation → **9.1 net-positive** → 9.2 ignition → 9.3 inflection.

**Honest status:** the Guppi RSI engine is **9.0 (delegation)** today — it runs
the gated loop end to end. **9.1 (net-positive) is NOT claimed** — it stays
gated on held-out proof (fair human baseline, a private score never selected
against, and a sustained multi-step trend). See the `rsi` skill.


## The Compounding Effect

- First project: 5x velocity (skill + agent + data)
- Second project in same domain: 10-20x (skip architecture, data model, calibration)
- Skills compound. Trust compounds. Knowledge compounds.

## Assessment

- Level 1: Using CoCo for one-off tasks
- Level 2: Have custom skills, reuse patterns
- Level 3+: SDLC gates, TARS audits, shared registry — CoCo Rockstar
