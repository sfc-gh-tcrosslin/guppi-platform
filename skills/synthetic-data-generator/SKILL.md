---
name: synthetic-data-generator
description: "Generate synthetic data at scale in Snowflake. Defaults to Snowflake-native generation (SQL GENERATOR/Snowpark) for performance and security — data never leaves Snowflake. Falls back to local Python + write_pandas only when complex statistical distributions require it. Use when: creating test datasets, generating synthetic healthcare data, populating tables with realistic fake data, bulk loading generated data, synthetic data generation, mock data, test data at scale. Triggers: synthetic data, generate data, fake data, test dataset, populate tables, bulk load generated data, scale up data, create sample data."
---

# Synthetic Data Generator

Generate synthetic datasets at scale. Defaults to Snowflake-native generation — data stays in Snowflake.

## Approach Selection

Always prefer Snowflake-native. Only fall back to local Python when the statistical complexity demands it.

| Approach | When to Use | Data Leaves Snowflake? |
|----------|------------|----------------------|
| **SQL GENERATOR** (default) | Uniform distributions, simple schemas, high volume | No |
| **Snowpark Python SP** | Complex distributions, multi-table with referential integrity | No |
| **Local Python + write_pandas** | Calibration against external registries, iterative tuning | Yes (temporarily) |

## Prerequisites

- Active Snowflake connection
- Target database/schema exists
- For Snowpark: Python runtime enabled on warehouse
- For local fallback: Python 3.11+ with `snowflake-connector-python` and `pandas`

## Workflow

### Step 1: Gather Requirements

**Ask user for:**
1. **Target tables**: Schema, column definitions, relationships
2. **Volume**: Total row counts per table
3. **Distributions**: Any real-world statistical targets (rates, percentages, trends over time)
4. **Constraints**: Foreign keys, referential integrity, temporal ordering
5. **Calibration source**: Is there a real-world registry to calibrate against? (e.g. MSTAHRS, SEER, CDC WONDER)

### Step 2: Choose Generation Approach

**Decision tree:**
- Simple schema, uniform/normal distributions, no calibration → **SQL GENERATOR**
- Complex relationships, weighted distributions, referential integrity → **Snowpark SP**
- External registry calibration, iterative rate tuning → **Local Python** (fallback)

### Step 3a: Snowflake-Native — SQL GENERATOR (Default)

Use `GENERATOR(ROWCOUNT => N)` with Snowflake's built-in random functions:

```sql
CREATE OR REPLACE TABLE SYNTHETIC_PATIENTS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS PATIENT_ID,
    DATEADD('day', -UNIFORM(0, 36500, RANDOM()), CURRENT_DATE()) AS BIRTH_DATE,
    CASE UNIFORM(1, 4, RANDOM())
        WHEN 1 THEN 'White' WHEN 2 THEN 'Black'
        WHEN 3 THEN 'Hispanic' ELSE 'Other'
    END AS RACE,
    CASE UNIFORM(1, 2, RANDOM())
        WHEN 1 THEN 'Male' ELSE 'Female'
    END AS GENDER,
    ROUND(NORMAL(3200, 600, RANDOM()), 0) AS BIRTH_WEIGHT_G,
    ROUND(NORMAL(38.5, 2.5, RANDOM()), 1) AS GESTATIONAL_AGE_WEEKS
FROM TABLE(GENERATOR(ROWCOUNT => 50000));
```

**Weighted categorical distributions** — use cumulative probability:

```sql
CASE
    WHEN UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.55 THEN 'White'
    WHEN UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.92 THEN 'Black'
    WHEN UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.97 THEN 'Hispanic'
    ELSE 'Other'
END AS RACE
```

**Year-specific volumes** — use UNION ALL with per-year generators:

```sql
SELECT * FROM (
    SELECT 2020 AS YEAR, * FROM TABLE(GENERATOR(ROWCOUNT => 8590))
    UNION ALL
    SELECT 2021 AS YEAR, * FROM TABLE(GENERATOR(ROWCOUNT => 8488))
    UNION ALL
    SELECT 2022 AS YEAR, * FROM TABLE(GENERATOR(ROWCOUNT => 8385))
);
```

**Referential integrity** — generate parent first, sample from parent IDs:

```sql
CREATE TABLE CHILD AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS CHILD_ID,
    (SELECT PATIENT_ID FROM PARENT SAMPLE (1 ROWS)) AS PARENT_ID,
    ...
FROM TABLE(GENERATOR(ROWCOUNT => 100000));
```

Or for guaranteed FK coverage, use a JOIN pattern:

```sql
CREATE TABLE VISITS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS VISIT_ID,
    p.PATIENT_ID,
    DATEADD('day', UNIFORM(0, 365, RANDOM()), p.BIRTH_DATE) AS VISIT_DATE
FROM SYNTHETIC_PATIENTS p,
     TABLE(GENERATOR(ROWCOUNT => 5)) g;
```

### Step 3b: Snowflake-Native — Snowpark Stored Procedure

For complex multi-table generation with statistical controls:

```sql
CREATE OR REPLACE PROCEDURE GENERATE_SYNTHETIC_DATA(RECORD_COUNT INT)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
def run(session, record_count):
    import random
    random.seed(42)

    rows = []
    for i in range(record_count):
        race = random.choices(['White','Black','Hispanic','Other'], weights=[0.55,0.37,0.05,0.03])[0]
        rows.append({
            'PATIENT_ID': i + 1,
            'RACE': race,
            'BIRTH_WEIGHT': max(500, int(random.gauss(3200, 600))),
        })

    df = session.create_dataframe(rows)
    df.write.mode('overwrite').save_as_table('SYNTHETIC_PATIENTS')
    return f'Generated {record_count} patients'
$$;

CALL GENERATE_SYNTHETIC_DATA(50000);
```

**Advantages over local Python:**
- Data never leaves Snowflake
- Runs on warehouse compute (scalable)
- No local dependencies
- No write_pandas date conversion issues
- Can be scheduled via TASK

### Step 3c: Local Python Fallback

Use only when calibrating against external registry data that requires iterative tuning:

```
CONFIG (constants, distributions, rates from registry)
  ↓
HELPERS (weighted random picks, date generation, ID sequences)
  ↓
GENERATOR CLASS (stateful, accumulates rows in memory as dicts)
  ↓
BULK LOADER (write_pandas for each table)
  ↓
VERIFICATION (count queries per table)
```

**CRITICAL: Never use multi-value INSERT for >10K rows.** Use `write_pandas` which does PUT + COPY INTO.

| Method | Speed at 100K rows | Speed at 1M rows |
|--------|-------------------|-------------------|
| Multi-value INSERT (batch 2000) | ~30 min | 3+ hours |
| `write_pandas` (PUT + COPY INTO) | ~30 sec | ~3 min |

**Date handling gotcha:** `write_pandas` converts Python `date` objects to nanosecond timestamps that fail Snowflake's DATE cast. Always convert to `.isoformat()` strings first.

### Step 4: Implement Statistical Controls

**These apply to ALL approaches:**

**Rate scaling over time** — Use a base rate + year multiplier:

```python
BASE_RATE = 8.0
RATE_BY_YEAR = {2020: 8.0, 2021: 8.34, 2022: 8.68}

def get_scaled_rate(category, year):
    scale = RATE_BY_YEAR[year] / BASE_RATE
    return CATEGORY_RATES[category]["base_rate"] * scale
```

**Risk multiplier stacking** — Always cap compound multipliers:

```
risk = min(risk, 1.8)  -- CRITICAL: cap to prevent rate overshoot
```

**Weighted population average verification:**

```
overall_target = sum(group_rate * group_pct for each group)
```

### Step 5: TRUNCATE Before Reload

When regenerating, truncate in reverse dependency order (child tables first).

### Step 6: Validate Output

**Always verify both generation stats AND loaded data:**

```sql
-- Post-generation verification
SELECT 'PATIENTS' AS TBL, COUNT(*) AS ROWS FROM SYNTHETIC_PATIENTS
UNION ALL SELECT 'VISITS', COUNT(*) FROM SYNTHETIC_VISITS
UNION ALL SELECT 'CONDITIONS', COUNT(*) FROM SYNTHETIC_CONDITIONS;
```

**Report computed rates vs targets** to confirm statistical calibration.

## Stopping Points

- After Step 2: Approve approach selection (SQL vs Snowpark vs local)
- After Step 4: Verify rate calculations match targets
- After Step 6: Review validation output

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Failed to cast variant value ... to DATE` | Raw Python `date` in `write_pandas` | Convert to `.isoformat()` or use Snowpark SP |
| IMR/rates overshoot target by 30%+ | Uncapped risk multiplier stacking | Add cap: `min(risk, 1.8)` |
| Load takes hours for <1M rows | Using multi-value INSERT | Switch to `write_pandas` or SQL GENERATOR |
| Year distribution is uniform | Using `random.randint` | Use explicit year allocation |
| Data leaves Snowflake unnecessarily | Using local Python for simple generation | Switch to SQL GENERATOR or Snowpark SP |

## Output

- Synthetic data generated in Snowflake target schema (preferred) or loaded via write_pandas (fallback)
- Validation report showing row counts and statistical targets vs actuals
