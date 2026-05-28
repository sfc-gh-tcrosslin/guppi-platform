# CORTEX.COMPLETE() Audit Patterns for TARS

## Model Selection by Audit Tier

| Tier | Model | Cost | Use Case |
|---|---|---|---|
| 1 | None (deterministic) | Free | SQL compile, COUNT(*), DESCRIBE |
| 2 | `llama3.1-70b` | ~0.001 credits/call | Doc grounding, completeness checks |
| 3 | `llama3.1-405b` | ~0.01 credits/call | Leakage detection, bias audit |

## Base Audit Prompt Template

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    CONCAT(
        'You are TARS, an independent trust auditor. Honesty setting: ', :honesty, '%.\n',
        'Your job is to find defects and verify claims. You are NOT the builder.\n',
        'You must provide EVIDENCE for every finding.\n',
        'Classify each finding as:\n',
        '  C (Cooperative) = truthful, verified, transparent\n',
        '  D (Defection) = inaccurate, missing, misleading, fabricated\n\n',
        'AUDIT TYPE: ', :audit_type, '\n',
        'ARTIFACT:\n', :artifact, '\n\n',
        'CRITERIA:\n', :criteria, '\n\n',
        'Respond ONLY in this JSON format:\n',
        '{"findings": [{"signal": "C|D", "check": "name", "description": "...", "evidence": "..."}], ',
        '"summary": "one sentence overall assessment"}'
    )
) AS tars_result;
```

## Specific Audit Prompts

### Model Card Completeness Audit

```sql
-- criteria parameter:
'Check for these required sections (Mitchell et al. 2019):
1. Model Details (name, version, type, framework, license)
2. Intended Use (primary use, intended users, out-of-scope)
3. Training Data (source, population, splits, calibration if synthetic)
4. Evaluation Results (metrics per window, base vs graph if dual-model)
5. Limitations (synthetic data caveat MUST be prominent if applicable)
6. Ethical Considerations (bias, fairness, consent)
7. Reproducibility (seeds, commands, versions)
For each section: C if present and substantive, D if missing or superficial.'
```

### Data Leakage Detection (Tier 3)

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-405b',
    CONCAT(
        'You are TARS auditing a clinical prediction model for data leakage.\n',
        'DATA LEAKAGE means a feature directly or indirectly encodes the outcome label.\n\n',
        'MODEL OUTCOME: ', :outcome_description, '\n',
        'FEATURES:\n', :feature_list, '\n\n',
        'For each feature, assess:\n',
        '1. Could this feature be computed FROM the outcome? (reverse causality)\n',
        '2. Is this feature available BEFORE the prediction time? (temporal leakage)\n',
        '3. Does this feature aggregate outcomes of similar patients? (leakage via aggregation)\n\n',
        'Known leakage examples from this project:\n',
        '- COUNTY_IMR: directly encoded county-level mortality rate → removed\n',
        '- DELIVERY_SITE_MORTALITY_RATE: site-level outcome rate → removed\n\n',
        'Classify each feature as C (safe) or D (potential leakage) with reasoning.'
    )
) AS leakage_audit;
```

### Calibration Honesty Audit

```sql
-- Run deterministic comparison first
WITH claims AS (
    SELECT 'Overall IMR' AS metric, 9.0 AS claimed_value
    UNION ALL SELECT 'Black IMR', 13.5
    UNION ALL SELECT 'White IMR', 5.5
),
actuals AS (
    SELECT 'Overall IMR' AS metric,
        ROUND(COUNT(CASE WHEN d.PERSON_ID IS NOT NULL THEN 1 END) * 1000.0 / COUNT(*), 1) AS actual_value
    FROM infants i LEFT JOIN deaths d ON i.PERSON_ID = d.PERSON_ID
    -- ... repeat for race-specific
)
SELECT c.metric, c.claimed_value, a.actual_value,
    ABS(c.claimed_value - a.actual_value) AS delta,
    CASE WHEN ABS(c.claimed_value - a.actual_value) <= 1.0 THEN 'C' ELSE 'D' END AS signal
FROM claims c JOIN actuals a ON c.metric = a.metric;
```

## Trust Score Computation

```python
def compute_trust_score(findings):
    tier_weights = {1: 2.0, 2: 1.0, 3: 1.5}
    c_weighted = sum(tier_weights[f['tier']] for f in findings if f['signal'] == 'C')
    d_weighted = sum(tier_weights[f['tier']] for f in findings if f['signal'] == 'D')
    total = c_weighted + d_weighted
    if total == 0:
        return 1.0
    return round(c_weighted / total, 4)

def grade(score):
    if score >= 0.95: return 'EXCELLENT'
    if score >= 0.85: return 'GOOD'
    if score >= 0.70: return 'FAIR'
    return 'FAIL'
```
