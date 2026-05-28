# GUPPI AUDITS — TARS Integration

## Overview

The AUDITS schema stores results from TARS Trust Auditor runs. TARS is invoked separately (via the `tars-trust-auditor` skill) and writes results here.

## Tables

- **AUDIT_RUNS** — one row per audit (target, trust score, grade, votes)
- **AUDIT_FINDINGS** — one row per check (signal C/D, tier, weight, evidence)

## Querying Audit History

### Latest trust score per target
```sql
SELECT TARGET_NAME, AUDIT_DATE, TRUST_SCORE, GRADE, HUMAN_VOTE
FROM GUPPI.AUDITS.AUDIT_RUNS
QUALIFY ROW_NUMBER() OVER (PARTITION BY TARGET_NAME ORDER BY AUDIT_DATE DESC) = 1
ORDER BY TRUST_SCORE
```

### All defection signals
```sql
SELECT r.TARGET_NAME, f.CHECK_NAME, f.DESCRIPTION, f.EVIDENCE
FROM GUPPI.AUDITS.AUDIT_FINDINGS f
JOIN GUPPI.AUDITS.AUDIT_RUNS r ON r.AUDIT_ID = f.AUDIT_ID
WHERE f.SIGNAL = 'D'
ORDER BY r.AUDIT_DATE DESC
```

### Trust trend
```sql
SELECT TARGET_NAME, AUDIT_DATE, TRUST_SCORE
FROM GUPPI.AUDITS.AUDIT_RUNS
WHERE STATUS = 'COMPLETE'
ORDER BY TARGET_NAME, AUDIT_DATE
```

## Relationship to Stories

When TARS finds a D signal that requires code changes, it spawns a DEFECT story in PUBLIC.STORIES and links it via AUDIT_FINDING_ID on the incident or a reference in the story description.

## Invocation

TARS is invoked via the `tars-trust-auditor` skill, not directly through GUPPI. GUPPI's role is storage and queryability of results.
