# Ontology Builder — Decision Tree Routing Rules

## The 7-Family Taxonomy

| # | Family | Key Signal | Snowflake Pattern |
|---|---|---|---|
| 1 | Reference Terminology | "Industry-agreed codes" | Marketplace + dimension joins |
| 2 | Semantic / Metric Layer | "Ask questions of data" | Semantic Views + Cortex Analyst |
| 3 | Operational | "Actions triggered by data" | Cortex Agents + procedures + tasks |
| 4 | Application Schema | "Specific workflow structure" | VARIANT + dbt + quickstarts |
| 5 | Domain Graph | "What connects to what" | Graph tables + recursive CTEs |
| 6 | Agent Wiki | "Team knowledge compounds" | Stage + Cortex Search + Agents |
| 7 | Formal / Upper | "Machine reasoning needed" | Triples table + external reasoner |

## Routing Decision Logic

### Question 1: Industry-Standard Codes?

```
IF customer needs codes recognized across organizations:
  ADD "Reference Terminology" to recommendation
  NOTE: This is additive — they almost always need something ELSE too
```

Healthcare → SNOMED, ICD, LOINC, RxNorm, NDC, CPT
Finance → FIBO, LEI, ISIN, NAICS
Manufacturing → ISA-95, GS1
Retail → schema.org, GPC, GTIN
Government → NAICS, SOC, OMB

### Question 2: Analytical / BI Questions?

```
IF customer wants to ask natural-language questions about their data:
  OR wants consistent metrics across teams:
  OR uses BI tools and needs a shared truth layer:
    ADD "Semantic Layer" to recommendation (HIGHEST PRIORITY)
    NOTE: This is the most common need — 80% of customers land here
```

### Question 3: Actions from Data?

```
IF updating an entity should trigger a real-world effect:
  (send alert, approve request, dispatch resource, block transaction)
    ADD "Operational Ontology" to recommendation
    NOTE: This requires stored procedures + agent or task pattern
```

### Question 4: Relationship Discovery?

```
IF customer needs to traverse connections:
  (impact analysis, root cause, network effects, recommendations)
    ADD "Domain Graph" to recommendation
    NOTE: Can be simple (recursive CTEs) or rich (graph tables)
```

### Question 5: Existing Formal Tools?

```
IF customer has Stardog, GraphDB, Protégé, Neptune, existing OWL:
  AND needs machine reasoning / inference:
  AND has or will build an ontology team:
    ADD "Formal Ontology" to recommendation
    DELEGATE to ontology-stack-builder skill
ELSE:
    DO NOT recommend formal ontology
    Route to lighter patterns that solve the same problem
```

### Question 6: Institutional Knowledge?

```
IF customer wants to capture team knowledge that compounds:
  (decisions, corrections, research, onboarding material)
    ADD "Agent Wiki" to recommendation
    NOTE: Lightest pattern — can start in 10 minutes
```

### Question 7: Application Schema?

```
IF customer has a specific workflow standard they must conform to:
  (OMOP for clinical research, FHIR for interop, CDISC for trials)
    ADD "Application Schema" to recommendation
    NOTE: This is usually an existing standard, not something we invent
```

## Priority Ordering

When multiple families are recommended, present in this order:

1. Semantic Layer (immediate value, minutes to build)
2. Reference Terminology (if needed, usually Marketplace + join)
3. Agent Wiki (if team knowledge capture needed)
4. Domain Graph (if relationship traversal needed)
5. Operational Ontology (if action automation needed)
6. Application Schema (if workflow conformance needed)
7. Formal Ontology (only if gate conditions met)

## Typical Customer Profiles

### "I just want to ask questions about my data"
→ Semantic View only. Done in 30 minutes.

### "We need consistent coding across our hospitals"
→ Reference Terminology (Marketplace) + Semantic View (metrics on top)

### "Claims need to auto-adjudicate based on rules"
→ Operational Ontology + Reference Terminology + Semantic View for reporting

### "We want to find which patients connect to which outcomes"
→ Domain Graph + Semantic View

### "We have a Stardog deployment and need Snowflake as the data backbone"
→ Formal Ontology (delegate to ontology-stack-builder)

### "We're drowning in institutional knowledge and decisions"
→ Agent Wiki + Semantic View (for the structured questions)

### "We need all of it — we're a large pharma"
→ Start with Semantic View (week 1), add Reference Terminology (week 2), add Graph (month 1), add Operational (month 2). Formal only if reasoning team exists.

## Anti-Patterns (Things to Avoid)

- DO NOT recommend formal OWL to a customer who just wants BI metrics
- DO NOT skip semantic view — it's almost always part of the answer
- DO NOT build a graph when a flat table with a join handles the relationship
- DO NOT recommend Agent Wiki as a replacement for proper governance
- DO NOT use ontology jargon (say "relationship map" not "property graph schema")
