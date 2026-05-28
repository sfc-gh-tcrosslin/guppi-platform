# GUPPI QA — Test Suites, Runs, Model Cards

## Status: PLACEHOLDER

The QA schema exists (`GUPPI.QA`) but tables are not yet created. This documents the intended design.

## Planned Tables

### TEST_SUITES
| Column | Type | Description |
|--------|------|-------------|
| SUITE_ID | TEXT PK | e.g., "F6-CONFORMANCE" |
| PRODUCT_ID | TEXT | Which product |
| NAME | TEXT | Display name |
| DESCRIPTION | TEXT | What it tests |
| TEST_COUNT | NUMBER | Total tests in suite |

### TEST_RUNS
| Column | Type | Description |
|--------|------|-------------|
| RUN_ID | TEXT PK | UUID |
| SUITE_ID | TEXT FK | Which suite |
| RUN_DATE | TIMESTAMP | When executed |
| PASSED | NUMBER | Pass count |
| FAILED | NUMBER | Fail count |
| SKIPPED | NUMBER | Skip count |
| DURATION_MS | NUMBER | Total execution time |
| TRIGGER | TEXT | MANUAL, PRE_DEPLOY, SCHEDULED |

### TEST_RESULTS
| Column | Type | Description |
|--------|------|-------------|
| RESULT_ID | TEXT PK | UUID |
| RUN_ID | TEXT FK | Parent run |
| TEST_NAME | TEXT | Individual test |
| STATUS | TEXT | PASS, FAIL, SKIP, ERROR |
| MESSAGE | TEXT | Error details if failed |
| DURATION_MS | NUMBER | Individual test time |

## Model Cards

Model cards are **NOT stored in GUPPI** — they live in the product database (e.g., `NCPDP_F6.PUBLIC.MODEL_CARDS`). GUPPI QA tracks test results against models but does not own the model card content.

The GUPPI story for a model LINKS to the model card location:
- Story description includes: "Model Card: NCPDP_F6.PUBLIC.MODEL_CARDS WHERE model_name = 'PBM_SPEND_FORECAST'"

## QA Automation Suite

The QA Automation Suite (load_test.py, conformance_test.py, etc.) writes results here. Each run produces a TEST_RUNS row with summary metrics, and TEST_RESULTS rows for individual assertions.

Future: TARS-driven continuous verification runs the suite on a schedule and logs results automatically.
