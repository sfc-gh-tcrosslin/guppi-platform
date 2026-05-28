---
name: app-testing
description: "Graduated testing pattern for Snowflake apps, pipelines, and transformations. Use when: testing new features, validating data pipelines, running transformation tests, smoke testing, scaling up test data, test strategy, test pattern, QA workflow, validation workflow. Triggers: test, testing, validate, QA, smoke test, graduated test, scale up testing, test pattern, harden tests."
---

# App Testing

Graduated testing framework: start small, validate, scale up. Applies to Native Apps, data pipelines, transformations, and any multi-stage build.

## Core Principle: Graduated Testing

Never test at full scale first. Follow this progression:

```
Level 1 (Smoke)  →  Level 2 (Validate)  →  ⚠️ PAUSE  →  Level 3 (Scale)
   1 record            10 records           Review         Full dataset
```

**The pause between Level 2 and Level 3 is mandatory.** Level 3 can be expensive (compute, time, side effects). Always stop, review Level 2 results, and get explicit approval before scaling.

## Workflow

### Step 1: Define Test Dimensions

Before writing any tests, identify:

| Dimension | Example |
|-----------|---------|
| **Input unit** | FHIR bundle, CSV file, API request, row batch |
| **Output tables/artifacts** | OMOP tables, analytics views, model outputs |
| **Vocabulary/lookup dependencies** | Terminology tables, mapping seeds, config |
| **Ground truth** | Known-good reference data for comparison at scale |
| **Referential integrity** | FK relationships between output tables |
| **Coverage metric** | % of source records successfully mapped/transformed |

**Ask user:**
1. What is the input unit? (e.g., "1 FHIR bundle", "1 CSV file", "1 API call")
2. What outputs should exist after transformation?
3. Is there ground truth data for full-scale comparison?
4. What Snowflake connection/warehouse/database to use?

### Step 2: Build Test Levels

#### Level 1 — Smoke Test (1 unit)

**Purpose:** Prove the pipeline runs end-to-end without errors.

**Checks (all must pass):**
- Pipeline completes without exceptions
- All expected output tables/artifacts are created
- At least 1 row in primary output table
- Multiple distinct entity types processed (if applicable)
- No SQL compilation errors

**Pattern:**
```python
def validate_level1(bundle_count, resource_count):
    assert bundle_count == 1, f"Expected 1 input unit, got {bundle_count}"
    assert resource_count > 0, "No resources parsed"
    for table in OUTPUT_TABLES:
        assert table_exists(table), f"Table {table} not created"
    assert primary_table_count >= 1, "Primary table empty"
```

**Cost:** Minimal — seconds to run.

#### Level 2 — Validation (10 units)

**Purpose:** Validate proportional output, mapping quality, and referential integrity.

**Checks (all must pass):**
- Proportional output (10x input ≈ proportional output growth)
- Non-zero concept/mapping IDs in key columns (coverage > 0%)
- Referential integrity between related tables (orphan rate < 50%)
- Print coverage report by domain/table

**Pattern:**
```python
def validate_level2(bundle_count):
    person_count = count("PERSON")
    assert person_count >= expected_min, f"Disproportionate: {person_count} from {bundle_count}"

    for table, concept_col in CONCEPT_COLUMNS:
        total, mapped = get_mapping_stats(table, concept_col)
        assert mapped > 0, f"{table} has zero mapped concepts"
        print(f"  {table}: {mapped}/{total} = {mapped/total*100:.1f}%")

    orphans = count_orphans("CHILD_TABLE", "PARENT_TABLE", "join_key")
    assert orphan_rate < 0.5, f"Too many orphans: {orphans}"
```

**Cost:** Low — typically under 1 minute.

#### ⚠️ MANDATORY PAUSE

**After Level 2 passes:**

Present results to user:
```
Level 2 Results (10 units):
- All tables created: ✓
- Coverage: [table-by-table breakdown]
- Referential integrity: [orphan counts]
- Elapsed: [time]

Ready to proceed to Level 3 (full dataset)?
This will process [N] records and may take [estimated time].
```

**Do NOT proceed to Level 3 without explicit user approval.**

Acceptable user responses to continue:
- "yes", "go", "proceed", "run it", "scale up"

If user says "pause", "stop", "let me review", "not yet" — STOP and wait.

#### Level 3 — Full Scale (complete dataset)

**Purpose:** Validate against ground truth and measure production-ready quality.

**Checks:**
- Row counts within ±10% of ground truth (if available)
- Full coverage report across all domains
- Quality summary (row counts per output table)
- Performance benchmarks (elapsed time, rows/second)

**Pattern:**
```python
def validate_level3():
    for table, (gt_table, gt_expected) in GROUND_TRUTH.items():
        actual = count(table)
        lo, hi = gt_expected * 0.9, gt_expected * 1.1
        assert lo <= actual <= hi, f"{table}: {actual} outside [{lo}, {hi}]"

    print_full_coverage_report()
    print_quality_summary()
```

**Cost:** High — minutes to hours depending on dataset size. Always estimate before running.

### Step 3: Test Infrastructure

**Standard test infrastructure pattern:**

```
tests/
├── test_<domain>.py          # Graduated Level 1/2/3 test
├── test_vocabulary.py        # Vocabulary/seed validation (if applicable)
└── conftest.py               # Shared fixtures (optional)
```

**CLI pattern (argparse):**
```
python tests/test_<domain>.py                  # Level 1 (default)
python tests/test_<domain>.py --level 2        # Level 2
python tests/test_<domain>.py --level 3        # Level 3
python tests/test_<domain>.py --level 2 --keep # Keep test artifacts
```

**Required flags:**
- `--level {1,2,3}` — test level (default: 1)
- `--keep` — retain test schema/artifacts after run (default: cleanup)

**Test schema pattern:**
- Create a dedicated test schema (e.g., `DB.TEST_<APP>_<DOMAIN>`)
- Copy/subset source data into test schema
- Run pipeline against test schema
- Clean up unless `--keep` is set

**Connection pattern:**
```python
conn = snowflake.connector.connect(
    connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "<default>"
)
```

### Step 4: Execute Graduated Tests

**Execution order — always sequential:**

1. Run Level 1. If any check fails → fix before proceeding.
2. Run Level 2 with `--keep`. Review coverage report.
3. **PAUSE.** Present Level 2 results. Wait for user approval.
4. Run Level 3 only after explicit approval.

**Reporting pattern:**
```
============================================================
FHIR-to-OMOP Transformation Test — Level 2
============================================================

--- Setup ---
  Setup: created test table with 10 bundles [0.8s]

--- Pipeline Execution ---
  Parsed 247 FHIR resources [1.2s]
  Mapped 20 persons [0.3s]
  ...

--- Level 2 Checks ---
  [PASS] Proportional person output  (20 persons from 10 bundles)
  [PASS] CONDITION has non-zero concept_ids  (45/52 = 86.5%)
  [FAIL] MEASUREMENT coverage below threshold  (12/89 = 13.5%)

============================================================
Results: 8 passed, 1 failed [4.2s]
============================================================
```

### Step 5: Vocabulary/Seed Validation (if applicable)

When the pipeline depends on terminology/lookup tables, validate them separately:

**Checks:**
- All seed tables have > 0 rows
- No duplicate primary keys
- Known mappings resolve correctly (spot-check 2-3 known codes)

Run seed validation BEFORE pipeline tests — bad seeds cause cascading failures.

## Stopping Points

- ✋ After Step 1: Confirm test dimensions with user
- ✋ After Level 2 passes: **Mandatory pause** before Level 3
- ✋ After Level 3: Review results before declaring success

## Extending This Skill

This skill is designed to grow. Future additions:

| Pattern | When to Add |
|---------|-------------|
| **Regression testing** | When pipeline changes need before/after comparison |
| **Performance benchmarks** | When SLAs or latency targets exist |
| **Data drift detection** | When source data schema may change over time |
| **Canary testing** | When deploying to production with rollback needs |
| **A/B comparison** | When comparing two pipeline implementations |
| **Native App install testing** | When testing consumer-side app installation |

## Output

- Test script(s) in `tests/` directory with `--level` and `--keep` flags
- Coverage reports printed to stdout
- PASS/FAIL summary with elapsed times
- Test schema created (and cleaned up unless `--keep`)
