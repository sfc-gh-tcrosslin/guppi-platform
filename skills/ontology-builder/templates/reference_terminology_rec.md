# Reference Terminology Recommendation

## What It Is

Industry-standard codes and vocabularies that enable interoperability — ensuring your data means the same thing to partners, regulators, and systems as it does to you.

## When This Was Recommended

You need codes that everyone in your industry agrees on — for billing, compliance, data exchange, or regulatory submission.

## What Gets Built

1. **Marketplace listing subscription** — access to curated terminology datasets
2. **Dimension tables** — standard codes joined to your fact tables
3. **Crosswalk tables** — mappings between your internal codes and standards
4. **Validation rules** — ensure data conforms to allowed values

## Common Terminologies by Industry

### Healthcare
| Standard | Purpose | Source |
|---|---|---|
| SNOMED CT | Clinical concepts | Snowflake Marketplace |
| ICD-10-CM | Diagnosis billing codes | CMS / Marketplace |
| LOINC | Lab/observation codes | Regenstrief |
| RxNorm | Drug names (normalized) | NLM |
| NDC | Drug package SKU | FDA |
| CPT/HCPCS | Procedure codes | AMA/CMS |

### Financial Services
| Standard | Purpose | Source |
|---|---|---|
| FIBO | Financial concepts | EDM Council |
| LEI | Legal Entity Identifier | GLEIF |
| NAICS | Industry classification | Census Bureau |
| ISIN/CUSIP | Security identifiers | Standard bodies |

### Manufacturing / Retail
| Standard | Purpose | Source |
|---|---|---|
| GS1/GTIN | Product identification | GS1 |
| UNSPSC | Product classification | GS1/UNDP |
| schema.org | Product metadata | W3C community |

## Snowflake Features Used

- Snowflake Marketplace (subscribe to curated datasets)
- Shared databases (reference data available as dimension tables)
- Views + joins (connect standards to your fact tables)
- Object Tags (tag columns with their terminology source)

## Estimated Time

- Identify needed standards: 10 minutes
- Subscribe on Marketplace: 5 minutes per listing
- Join to existing tables: 15-30 minutes
- Crosswalk for internal codes: 1-2 hours (depends on mapping complexity)
- **Total: 30 minutes to 2 hours depending on crosswalk needs**

## What "Done" Looks Like

- Your diagnosis codes resolve to SNOMED/ICD definitions
- Reports use standardized labels instead of internal codes
- Data exchange with partners uses agreed identifiers
- Regulatory submissions pass validation

## The Crosswalk Problem

Your internal codes rarely match standards 1:1. Crosswalk patterns:

```sql
CREATE TABLE crosswalk_internal_to_icd (
  INTERNAL_CODE VARCHAR,
  ICD10_CODE VARCHAR,
  CONFIDENCE NUMBER(3,2),
  MAPPING_TYPE VARCHAR,  -- 'exact', 'broader', 'narrower', 'related'
  REVIEWED_BY VARCHAR,
  REVIEWED_AT TIMESTAMP_NTZ
);
```

Key facts about crosswalks:
- SNOMED ↔ ICD: many-to-one, precision lost
- RxNorm ↔ NDC: one-to-many (one ingredient, many packages)
- Expect 70-90% automated mapping, remainder needs human review
- OMOP vocabulary tables solve most healthcare crosswalks

## Next Steps After This Layer

- Add Semantic View to query standardized data with natural language
- Use OMOP CDM if you need a unified clinical research schema
- Feed standardized codes into your Domain Graph for richer traversal
