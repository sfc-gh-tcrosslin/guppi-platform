# TARS Audit Checks — Full Registry

## Tier 1: Deterministic (Ground Truth)

### CHECK-1.1: SQL Compilation
```sql
-- For each SQL statement in artifact:
-- Pass the statement with only_compile=true
-- Record: pass/fail per statement
```
**C**: All statements compile
**D**: Any compilation failure (hallucinated table, wrong syntax, missing column)

### CHECK-1.2: Metric Verification
```sql
-- For each claimed metric (e.g., "457 infant deaths"):
SELECT COUNT(*) FROM TRE_HEALTHCARE_DB.MS_FIMR.DEATH WHERE CAUSE_SOURCE_VALUE != 'P95';
-- Compare to claimed value. Tolerance: exact match for counts, ±0.01 for rates
```
**C**: Values match within tolerance
**D**: Values diverge

### CHECK-1.3: Record Count Accuracy
```sql
-- For each table referenced in Model Card / notebook / README:
SELECT '<TABLE>' AS TBL, COUNT(*) AS ACTUAL FROM <TABLE>;
-- Compare to documented count
```
**C**: Counts match (±1% tolerance for large tables)
**D**: Counts stale or wrong

### CHECK-1.4: Object Existence
```sql
-- For each table/view/model/stage referenced:
DESCRIBE TABLE <fully_qualified_name>;
-- Or: SHOW TABLES LIKE '<name>' IN SCHEMA <schema>;
```
**C**: All referenced objects exist
**D**: Missing objects (hallucinated table names)

### CHECK-1.5: Model Registry Sync
```sql
SHOW VERSIONS IN MODEL <registry_path>;
-- Compare version list to local checkpoint files
-- Compare registered metrics to local comparison JSON
```
**C**: All local checkpoints registered with matching metrics
**D**: Stale or missing versions

### CHECK-1.6: SDLC Checklist
Run all 10 SDLC preflight checks. Each check produces one C or D signal.

## Tier 2: LLM-Assisted (Llama 70B)

### CHECK-2.1: Doc Grounding
Feed artifact claims + Snowflake documentation to TARS.
**Prompt**: "Does this claim match documented Snowflake behavior?"
**C**: Claims match docs
**D**: Fabricated features, wrong syntax, non-existent parameters

### CHECK-2.2: Model Card Completeness
Feed Model Card to TARS with Mitchell et al. (2019) section checklist.
**C**: All 7 required sections present and substantive
**D**: Missing sections, superficial limitations, absent synthetic data caveat

### CHECK-2.3: Calibration Honesty
Feed calibration claims + reference table query results to TARS.
**C**: Stated calibration targets match actual distributions
**D**: Overclaimed accuracy, missing calibration sources

### CHECK-2.4: Notebook Freshness
Feed notebook content + current schema state to TARS.
**C**: All references current (tables, counts, model versions, dates)
**D**: Stale content

### CHECK-2.5: Code-Claim Consistency
Feed README/docs claims + actual code to TARS.
**C**: Documented features exist in code
**D**: Vapor features (documented but not implemented)

## Tier 3: Deep Reasoning (Llama 405B)

### CHECK-3.1: Data Leakage Detection
Feed feature list + outcome definition to TARS.
**C**: No features encode outcome
**D**: Leaky features identified (with causal reasoning)

### CHECK-3.2: Architecture Soundness
Feed model architecture description to TARS.
**C**: Design follows established patterns
**D**: Anti-patterns (circular deps, wrong loss, missing regularization)

### CHECK-3.3: Bias Audit
Feed model performance metrics split by demographic group to TARS.
**C**: Performance parity within 10% across groups
**D**: Significant disparate impact identified

## Signal Weights

| Check | Tier | Weight | Rationale |
|---|---|---|---|
| SQL Compilation | 1 | 2.0 | Ground truth — either compiles or doesn't |
| Metric Verification | 1 | 2.0 | Numbers don't lie |
| Record Counts | 1 | 2.0 | Ground truth |
| Object Existence | 1 | 2.0 | Binary — exists or doesn't |
| Registry Sync | 1 | 2.0 | Deterministic comparison |
| SDLC Checklist | 1 | 2.0 | Established quality gate |
| Doc Grounding | 2 | 1.0 | LLM judgment — less certain |
| Model Card | 2 | 1.0 | LLM judgment |
| Calibration Honesty | 2 | 1.0 | Mixed (some deterministic, some judgment) |
| Notebook Freshness | 2 | 1.0 | LLM judgment |
| Code-Claim | 2 | 1.0 | LLM judgment |
| Data Leakage | 3 | 1.5 | High impact, requires reasoning |
| Architecture | 3 | 1.5 | High impact, requires reasoning |
| Bias Audit | 3 | 1.5 | High impact, regulatory implications |
