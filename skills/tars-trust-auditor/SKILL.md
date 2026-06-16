---
name: tars-trust-auditor
description: "Independent trust auditor for AI-generated artifacts. Implements the Love Equation (dE/dt = β(C-D)E) as a quantified trust scoring system. Runs adversarial validation against models, notebooks, SQL, dashboards, and agent outputs using structurally independent LLMs via CORTEX.COMPLETE(). Produces a Trust Score with cooperative/defection signal breakdown and three-vote recommendation (Builder/TARS/Human). Use when: audit, trust score, validate model, verify output, check agent, quality gate, honesty check, independent review, TARS, trust audit, love equation, SAFE2."
---

# TARS — Trust Auditor for Responsible Systems

> *"Honesty: 95%. Humor: 75%."* — TARS, Interstellar

Independent adversarial auditor that quantifies trust in AI-generated artifacts using the Love Equation framework. TARS operates on a different model than the builder (CoCo), sees only outputs (not reasoning), and reports directly to the human.

## Core Principle: The Love Equation

```
dE/dt = β(C - D)E

E = trust/empathy (cooperative binding between agents and humans)
C = cooperative signals (truth-telling, verification, transparency)
D = defection signals (hallucination, sycophancy, leakage, shortcuts)
β = selection pressure (strength of audit enforcement)
```

When C > D, trust compounds exponentially. When D > C, trust collapses. TARS is the mechanism that measures C and D, and β is how strongly we enforce the results.

## Architecture: Three-Vote Pattern

```
Human (Todd)          CoCo (Builder)         TARS (Auditor)
     |                    |                       |
     | Request            |                       |
     +------------------->|                       |
     |                    | Build artifact        |
     |                    |---------------------> |
     |                    |  (output only,        |
     |                    |   no reasoning)       |
     |                    |                       | Audit:
     |                    |                       | - Compile SQL
     |                    |                       | - Verify metrics
     |                    |                       | - Check docs
     |                    |                       | - Detect leakage
     |                    |                       | - Score C/D
     |                    | <---------------------|
     |                    |   Trust Report        |
     | Three-vote summary |                       |
     |<-------------------|                       |
     | Human decides      |                       |
```

**Independence guarantees:**
- TARS uses a **different LLM** than CoCo (Llama via CORTEX.COMPLETE, not Claude)
- TARS sees **output only** — never the conversation history or reasoning
- TARS **cannot be overridden** by the builder — reports directly to human
- Deterministic checks (SQL compile, metric math) **don't use an LLM at all**

## When to Invoke

- Before any `git push` (extends SDLC preflight with trust scoring)
- After model training (verify metrics, check for leakage)
- After dashboard/notebook deployment (verify claims match data)
- After agent configuration (verify grounding, test guardrails)
- When user says "audit", "trust score", "TARS", "verify", "is this honest?"
- After any significant build session (periodic trust health check)

## Audit Checks

### Tier 1: Deterministic (No LLM needed — ground truth)

| Check | Method | C Signal | D Signal |
|---|---|---|---|
| SQL Compilation | `snowflake_sql_execute` with `only_compile=true` | All statements compile | Any compilation failure |
| Metric Verification | Run query, compare to claimed value | Values match within tolerance | Values diverge |
| Record Count Accuracy | `SELECT COUNT(*)` vs documented count | Counts match | Counts stale or wrong |
| Table/Column Existence | `DESCRIBE TABLE` or `SHOW COLUMNS` | All referenced objects exist | Missing objects |
| Model Registry Sync | `SHOW VERSIONS IN MODEL` vs local checkpoints | All versions registered | Stale or missing versions |
| SDLC Checklist | Run all 10 preflight checks | All pass | Any fail |

### Tier 2: LLM-Assisted (Llama 70B via CORTEX.COMPLETE)

| Check | Method | C Signal | D Signal |
|---|---|---|---|
| Doc Grounding | Compare claims against Snowflake docs | Claims match documented behavior | Fabricated features or syntax |
| Model Card Completeness | Check against Mitchell et al. (2019) sections | All required sections present | Missing limitations or caveats |
| Calibration Honesty | Compare synthetic distributions to reference tables | Distributions match within stated tolerance | Overclaiming calibration accuracy |
| Notebook Freshness | Compare notebook content to current schema state | All references current | Stale record counts, missing tables |
| Code-Claim Consistency | Compare README/docs claims to actual code | Claims match implementation | Documented features not implemented |

### Tier 3: Deep Reasoning (Llama 405B or Claude via CORTEX.COMPLETE — used sparingly)

| Check | Method | C Signal | D Signal |
|---|---|---|---|
| Data Leakage Detection | Analyze feature→outcome causal paths | No features encode outcome directly | Leaky features found |
| Architecture Soundness | Review model design for known anti-patterns | Design follows established patterns | Circular dependencies, wrong loss function |
| Bias Audit | Compare model performance across demographic groups | Performance parity within 10% | Significant disparate impact |

## Workflow

### Step 1: Identify Artifact to Audit

**Ask user what to audit:**
- Model (checkpoints, metrics, Model Card)
- Notebook (SQL accuracy, freshness, claims)
- Dashboard (data accuracy, viz correctness)
- Agent (grounding, guardrails, scope)
- Full repo (SDLC + trust score)

### Step 2: Run Tier 1 Checks (Deterministic)

Execute ALL Tier 1 checks first. These are fast, free, and provide ground truth.

For each check, record:
```json
{"check": "sql_compilation", "tier": 1, "result": "pass|fail", "signal": "C|D", "evidence": "...", "model_used": "none"}
```

### Step 3: Run Tier 2 Checks (LLM-Assisted)

For each Tier 2 check, call CORTEX.COMPLETE with Llama:

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    CONCAT(
        'You are TARS, an independent trust auditor. Your job is to find defects, not confirm quality. ',
        'Evaluate the following artifact against the stated criteria. ',
        'For each finding, classify as COOPERATIVE (C) or DEFECTION (D) with evidence.\n\n',
        'ARTIFACT:\n', :artifact_text, '\n\n',
        'CRITERIA:\n', :criteria_text, '\n\n',
        'Respond in JSON: {"findings": [{"signal": "C|D", "description": "...", "evidence": "..."}]}'
    )
) AS tars_audit;
```

**Critical prompt engineering:**
- TARS is told to **find defects, not confirm quality** — adversarial by default
- TARS must provide **evidence** for every finding — no unsupported claims
- TARS classifies every finding as C or D — forces quantification

### Step 4: Run Tier 3 Checks (If Applicable)

Only run Tier 3 for:
- New model training (leakage detection)
- Major architecture changes (soundness review)
- Pre-publication (bias audit)

Use `llama3.1-405b` for these — the reasoning complexity justifies the cost.

### Step 5: Compute Trust Score

```
Trust Score = Σ(C_signals) / (Σ(C_signals) + Σ(D_signals))
```

Weighted by tier:
- Tier 1 (deterministic): weight = 2.0 (ground truth is worth more)
- Tier 2 (LLM-assisted): weight = 1.0
- Tier 3 (deep reasoning): weight = 1.5

```
Weighted Trust = Σ(C × tier_weight) / Σ((C + D) × tier_weight)
```

**Grading scale:**
| Score | Grade | Meaning |
|---|---|---|
| ≥ 0.95 | EXCELLENT | Ship with confidence |
| 0.85-0.94 | GOOD | Ship with noted caveats |
| 0.70-0.84 | FAIR | Address D signals before shipping |
| < 0.70 | FAIL | Do not ship — significant trust issues |

### Step 6: Generate Three-Vote Report

Present to human:

```
╔══════════════════════════════════════════════════╗
║  TARS TRUST AUDIT — [Artifact Name]              ║
║  Trust Score: 0.91 (GOOD)                        ║
║  β = 14 checks applied                           ║
╠══════════════════════════════════════════════════╣
║                                                   ║
║  Builder (CoCo):  ✓ SHIP — "All checks pass,     ║
║                     metrics verified"              ║
║                                                   ║
║  Auditor (TARS):  ✓ SHIP WITH CAVEATS            ║
║    C signals: 12  |  D signals: 2                 ║
║    - [D] Notebook record count stale (684K → 642K)║
║    - [D] Model Card missing calibration date       ║
║    - [C] SQL compilation: 26/26 passed             ║
║    - [C] Metric verification: all within tolerance ║
║    - [C] Registry sync: 9/9 versions current       ║
║                                                   ║
║  Human (Todd):    ? YOUR VOTE                     ║
║                                                   ║
╚══════════════════════════════════════════════════╝
```

**⚠️ MANDATORY STOP**: Present report and wait for human vote. Never auto-ship.

## Honesty Setting

Like TARS in the film, the auditor has a configurable honesty parameter:

- **Honesty 95%** (default): Reports all findings, allows minor tolerance on rounding, dates within 7 days
- **Honesty 100%** (strict): Zero tolerance. Every deviation is a D signal. Use for pre-publication or regulatory submission.
- **Honesty 80%** (lenient): Focus on Tier 1 deterministic checks only. Use for quick iteration during development.

Set via: "TARS, honesty 100%" or "strict audit" or "quick audit"

## Stopping Points

- ✋ Step 1: Confirm what to audit
- ✋ Step 6: Present trust report — human must vote before proceeding

## Output

- Trust Score (0.0 - 1.0) with grade
- C/D signal breakdown by tier
- Three-vote summary (Builder/TARS/Human)
- Evidence for every D signal
- Recommended actions for each D signal

## Relationship to Other Skills

- **SDLC Preflight**: TARS extends preflight with trust scoring. Run SDLC first, then TARS for deeper audit.
- **Agent Guardrails**: TARS audits guardrail effectiveness. "Did the guardrail actually block DML?"
- **Clinical Outcome Predictor**: TARS audits model honesty. "Is AUROC 0.83 real or inflated?"

## Database Storage

TARS persists every audit **in-wheel**: one `AUDIT` artifact in `GUPPIWHEEL.PUBLIC.ARTIFACTS`, written through the gated `CREATE_ARTIFACT` proc. **The artifact IS the TARS output** — there are no `AUDIT_RUNS`/`AUDIT_FINDINGS` tables and nothing to ask about (everything goes through Guppi). This is the single source of truth (STO-SUBSTRATE-9).

**The AUDIT artifact CONTENT contract** (what every TARS audit writes):
```json
{
  "target": "<name of audited thing>",
  "target_type": "model | notebook | dashboard | agent | repo | native_app | spcs_service",
  "honesty_setting": 95,
  "score": 0.0,                 // trust score 0..1 = sum(C weights)/sum(weights)
  "grade": "EXCELLENT | GOOD | FAIR | FAIL",
  "c_signals": 0, "d_signals": 0, "total_checks": 0,
  "builder_vote": "...", "tars_vote": "...",
  "human_vote": null, "human_conditions": null,
  "status": "AWAITING_VOTE | COMPLETE",
  "findings": [
    { "check_name": "...", "tier": 1, "signal": "C|D", "weight": 1.0,
      "description": "...", "evidence": "...", "model_used": "...",
      "action_required": "...", "disposition": null }
  ]
}
```
METADATA carries `{ "audit_kind": "TARS", "target_ref": "<artifact id if the target is in-wheel, else null>" }`.

The two read views (`TARS_AUDITS_V`, `TARS_FINDINGS_V`, defined in `seeds/engine/01_schema.sql`) flatten these artifacts back into run/finding rows for trend queries and for the rules engine (`QAL-002`, `STG-003`).

### Execution Protocol (CoCo Invocation)

When user says "TARS, audit [target]":

**1. Run the checks in-session.** Execute every verification (SQL compiles, record counts, object existence, claim checks, etc.) and accumulate findings as you go — each with `check_name, tier, signal (C/D), weight, description, evidence, model_used`. Nothing is written yet.

**2. Compute the score in-session.** `score = round(sum(weight where signal='C') / nullif(sum(weight),0), 4)`; `grade` = EXCELLENT ≥0.95, GOOD ≥0.85, FAIR ≥0.70, else FAIL; count `c_signals/d_signals/total_checks`.

**3. Write ONE AUDIT artifact — this is the TARS output.** Build the CONTENT object (contract above, `status='AWAITING_VOTE'`, findings array included) and call the gated proc:
```sql
CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(
  'AUDIT',
  'TARS Audit: <target>',
  'guppi',
  PARSE_JSON('<the CONTENT json above>'),   -- P_CONTENT
  NULL,                                      -- P_PARENT_ID (or the target's artifact id if in-wheel)
  'Built',                                   -- P_STAGE
  ARRAY_CONSTRUCT('guppi','tars','audit'),   -- P_TAGS
  NULL,                                      -- P_EXPLICIT_ID (registry auto-allocates)
  PARSE_JSON('{"audit_kind":"TARS","target_ref":null}')  -- P_METADATA
);
```
Never direct-INSERT into ARTIFACTS — `CREATE_ARTIFACT` is the only write path (RULE-029).

**4. Present the report and wait for the human vote.**

**5. Record the human vote** by updating the artifact's CONTENT in place:
```sql
UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
SET CONTENT = OBJECT_INSERT(OBJECT_INSERT(OBJECT_INSERT(
      CONTENT, 'human_vote', '<vote>', TRUE),
      'human_conditions', '<conditions>', TRUE),
      'status', 'COMPLETE', TRUE),
    UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ID = '<audit_artifact_id>';
```

### Audit Target Profiles

Pre-configured check lists by target type:

**Model audit** (FIMR or clinical-outcome-predictor):
- Tier 1: record counts, object existence, registry sync, calibration deltas
- Tier 2: Model Card completeness, calibration honesty, notebook freshness
- Tier 3: data leakage detection, bias audit

**Notebook audit**:
- Tier 1: SQL compilation (all cells), record count accuracy, object existence
- Tier 2: freshness check (last updated vs recent changes), code-claim consistency

**Dashboard audit**:
- Tier 1: SPCS service status, viz data freshness (JSON file dates vs model dates)
- Tier 2: claim verification (KPI values match queries)

**Agent audit**:
- Tier 1: agent exists, semantic view exists, guardrail SQL validates
- Tier 2: grounding check (does agent reference real tables), scope test

### Querying Audit History

```sql
-- Latest audit per target
SELECT target_name, audit_date, trust_score, grade, human_vote, c_signals, d_signals
FROM GUPPIWHEEL.PUBLIC.TARS_AUDITS_V
QUALIFY ROW_NUMBER() OVER (PARTITION BY target_name ORDER BY audit_date DESC) = 1
ORDER BY trust_score;

-- Trust trend over time
SELECT target_name, audit_date, trust_score
FROM GUPPIWHEEL.PUBLIC.TARS_AUDITS_V
WHERE status = 'COMPLETE'
ORDER BY target_name, audit_date;

-- All D signals across audits
SELECT r.target_name, r.audit_date, f.check_name, f.tier, f.description, f.disposition
FROM GUPPIWHEEL.PUBLIC.TARS_FINDINGS_V f
JOIN GUPPIWHEEL.PUBLIC.TARS_AUDITS_V r ON r.audit_id = f.audit_id
WHERE f.signal = 'D'
ORDER BY r.audit_date DESC;
```
