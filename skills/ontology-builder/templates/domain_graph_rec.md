# Domain Graph Recommendation

## What It Is

A network of entities and their relationships that you can traverse. Answers "what connects to what?" — enabling impact analysis, root cause tracing, recommendation engines, and network-effect discovery.

## When This Was Recommended

You need to trace relationships — who connects to whom, what impacts what, how things are related beyond simple joins.

## What Gets Built

1. **Node table** — entities (patients, providers, facilities, products, accounts)
2. **Edge table** — typed relationships with properties (TREATS, PRESCRIBES, REFERS_TO, SUPPLIES)
3. **Traversal queries** — recursive CTEs or graph-table queries for pathfinding
4. **Visualization** — interactive graph rendering for exploration

## Schema Pattern

```sql
CREATE TABLE nodes (
  NODE_ID VARCHAR PRIMARY KEY,
  NODE_TYPE VARCHAR,       -- Patient, Provider, Facility, Drug, etc.
  PROPERTIES VARIANT,      -- flexible attributes
  LABEL VARCHAR
);

CREATE TABLE edges (
  EDGE_ID VARCHAR PRIMARY KEY,
  SOURCE_ID VARCHAR REFERENCES nodes(NODE_ID),
  TARGET_ID VARCHAR REFERENCES nodes(NODE_ID),
  EDGE_TYPE VARCHAR,       -- TREATS, PRESCRIBES, LOCATED_AT, etc.
  PROPERTIES VARIANT,      -- weight, date, confidence, etc.
  CREATED_AT TIMESTAMP_NTZ
);
```

## Snowflake Features Used

- Tables (node + edge storage)
- Recursive CTEs (path traversal)
- VARIANT columns (flexible properties)
- Cortex Search (semantic search over node labels)
- SPCS + visualization library (for interactive graph rendering)

## Estimated Time

- Discovery: 15-20 minutes (identify entities and relationship types)
- Build schema: 15 minutes (node + edge tables)
- Load data: 30-60 minutes (transform from source tables)
- Traversal queries: 30 minutes (common patterns)
- **Total: 2-3 hours for a queryable graph**

## What "Done" Looks Like

- "Show me all providers connected to this patient within 2 hops"
- "What facilities share the most patients?" (network analysis)
- "Trace the referral chain from primary care to specialist"
- Impact analysis: "If this drug is recalled, which patients and providers are affected?"

## Example (Healthcare)

```
Nodes: Patient, Provider, Facility, Diagnosis, Drug, Geography
Edges: 
  Patient -[HAS_DIAGNOSIS]-> Diagnosis
  Patient -[TREATED_BY]-> Provider
  Provider -[WORKS_AT]-> Facility
  Provider -[PRESCRIBES]-> Drug
  Facility -[LOCATED_IN]-> Geography
```

## Next Steps After This Layer

- Add Semantic View to ask analytical questions about graph metrics
- Add cuGraph / graph algorithms for PageRank, community detection, centrality
- Consider Cortex Agent that monitors graph for anomalies (unusual connections)
