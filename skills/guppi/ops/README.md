# GUPPI OPS — Incidents & Post-Mortems

## When to Create an Incident (vs a Defect)

| Situation | Track As |
|-----------|----------|
| Service down, data stale, sync broken | OPS INCIDENT |
| Code bug found during development | DEFECT (story) |
| User-reported error in production | OPS INCIDENT → may spawn DEFECT |
| Performance degradation detected | OPS INCIDENT |
| Scheduled maintenance | NOT an incident |

## Severity Levels

| Level | Criteria | Response |
|-------|----------|----------|
| SEV1 | Data loss, financial impact, service down | Immediate. Drop everything. |
| SEV2 | Degraded service, incorrect results, workaround exists | Same session. |
| SEV3 | Minor issue, cosmetic, no user impact | Next session. |

## Incident Lifecycle

```
DETECTED → MITIGATED → RESOLVED → CLOSED
```

- DETECTED: Problem identified (record DETECTED_AT)
- MITIGATED: Bleeding stopped, workaround in place (record MITIGATED_AT)
- RESOLVED: Root cause fixed, verified (record RESOLVED_AT)
- CLOSED: Post-mortem written, preventive action created

## Timeline Metrics

| Metric | Formula | Target |
|--------|---------|--------|
| TTD (Time to Detect) | DETECTED_AT - actual_start | < 5 min (SEV1) |
| TTM (Time to Mitigate) | MITIGATED_AT - DETECTED_AT | < 30 min (SEV1) |
| TTR (Time to Resolve) | RESOLVED_AT - DETECTED_AT | < 4 hrs (SEV1) |

## Post-Mortem Structure

Every SEV1/SEV2 incident gets a post-mortem (stored in OPS.POST_MORTEMS):
1. Timeline of events
2. Root cause (5 Whys)
3. Root cause category (CONFIG, CODE, DATA, INFRA, HUMAN)
4. What went well
5. What went wrong
6. Preventive actions (link to GUPPI stories)

## Creating an Incident

```sql
INSERT INTO GUPPI.OPS.INCIDENTS 
(INCIDENT_ID, PRODUCT_ID, SEVERITY, STATUS, TITLE, DESCRIPTION, DETECTED_AT, DETECTED_BY)
VALUES ('INC-XXX', '<product>', 'SEV2', 'DETECTED', '<title>', '<description>', CURRENT_TIMESTAMP(), 'CoCo')
```
