# Semantic View Recommendation

## What It Is

A semantic layer that gives business meaning to your physical data. Maps columns to dimensions and metrics, defines relationships between tables, and enables natural-language queries via Cortex Analyst.

## When This Was Recommended

You want to ask questions about your data in plain language and get consistent answers across teams.

## What Gets Built

1. **Semantic View YAML** — dimensions, metrics, time dimensions, relationships
2. **Cortex Analyst access** — natural-language queries against your data
3. **Verified queries** — pre-tested questions that validate the model

## Snowflake Features Used

- Semantic Views (`CREATE SEMANTIC VIEW`)
- Cortex Analyst (NL-to-SQL)
- Verified Query Representations (VQRs)

## Estimated Time

- Discovery: 10-15 minutes (identify tables, key columns, common questions)
- Build: 15-20 minutes (create YAML, test with sample questions)
- Validate: 10 minutes (run verified queries, confirm accuracy)
- **Total: ~30-45 minutes for a working first version**

## What "Done" Looks Like

- Users can ask "What was our revenue last quarter by region?" and get SQL + results
- Metrics are consistent regardless of who asks
- New team members can explore data without knowing table structures

## Next Steps After This Layer

- Add more tables/relationships as needs expand
- Graduate to Domain Graph if relationship traversal becomes important
- Add Operational Ontology if actions need to trigger from metric thresholds

## Delegation

This routes to the `semantic-view` skill for implementation.
