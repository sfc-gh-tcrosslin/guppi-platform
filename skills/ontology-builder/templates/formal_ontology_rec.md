# Formal Ontology Recommendation

## What It Is

A machine-readable model with classes, properties, relationships, and axioms (rules) that enables automated reasoning and inference. The heaviest pattern — only appropriate when you genuinely need provable consistency or have existing formal investments.

## When This Was Recommended

You answered YES to ALL of these:
- You have existing RDF/OWL tools (Stardog, GraphDB, Protégé, Neptune)
- OR a regulatory/contract requirement mandates formal ontology deliverables
- You need machine reasoning / inference (not just search or analytics)
- You have or will build a team to maintain it

## What Gets Built

1. **OWL ontology** — classes, object properties, data properties, axioms
2. **SHACL shapes** — validation constraints
3. **Triples table** — RDF storage in Snowflake for the data layer
4. **Abstract views** — Snowflake views that present ontology concepts over relational data
5. **Semantic view** — NL-to-SQL layer on top of abstract views
6. **Agent** — Cortex Agent that queries the ontology-grounded data

## Snowflake Pattern

```sql
-- Triples stored relationally
CREATE TABLE ontology_triples (
  SUBJECT VARCHAR,
  PREDICATE VARCHAR,
  OBJECT VARCHAR,
  OBJECT_TYPE VARCHAR,  -- 'uri', 'literal', 'typed_literal'
  GRAPH VARCHAR DEFAULT 'default'
);

-- Hierarchy traversal via recursive CTE
-- Reasoning delegated to external engine (Stardog, HermiT, Pellet)
-- Or approximated with materialized inference views
```

## Snowflake Features Used

- Tables (triple storage, materialized inferences)
- Views (abstract views presenting ontology concepts)
- Semantic Views (NL-to-SQL over abstract views)
- Cortex Agents (query interface)
- External Access Integration (connect to external reasoner if needed)

## Estimated Time

- Ontology design: 1-2 weeks (requires domain expert + ontology engineer)
- Implementation on Snowflake: 2-3 days (7-phase pipeline via ontology-stack-builder)
- Integration with existing tools: 1-2 weeks
- **Total: 3-6 weeks for a production deployment**

## What "Done" Looks Like

- Classes and relationships are formally defined and machine-checkable
- New data is validated against SHACL shapes before acceptance
- Inference produces new facts from existing data (e.g., "if Patient hasDiagnosis Diabetes_Type_2 then Patient hasCondition MetabolicDisorder")
- Interoperable with external ontology tools and standards bodies

## When NOT to Use This

- You just want BI metrics → use Semantic View
- You just want to see relationships → use Domain Graph
- You don't have an ontology team → you won't maintain it
- Nobody else needs your ontology to be in OWL → lighter patterns work

## Delegation

This routes to the `ontology-stack-builder` skill for the full 7-phase implementation:
1. Schema discovery
2. Ontology generation (OWL/RDF)
3. Abstract view creation
4. Concrete view creation
5. Semantic model generation
6. Agent configuration
7. Graph analytics scaffolding

## Critical Success Factors

- Executive sponsor who understands the multi-week investment
- Dedicated ontology engineer (or team) for ongoing maintenance
- Clear use case that REQUIRES reasoning (not just search or analytics)
- Integration plan with existing tools and workflows
