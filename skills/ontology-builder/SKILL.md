# Ontology Builder — Customer-Facing Discovery + Build Skill

## Purpose

Interactive wizard that helps customers discover which ontology pattern(s) they need and builds the lightest viable solution directly in their Snowflake account. Replaces abstract ontology theory with practical, use-case-driven recommendations.

## When to Invoke

- Customer asks about ontologies, knowledge graphs, semantic models, or "how to organize their data"
- Customer is confused about terminology (ontology vs. taxonomy vs. schema vs. graph)
- Customer wants to build a semantic view, graph, or knowledge structure
- Any conversation about data meaning, relationships, or metadata strategy

## Philosophy

1. **Lightest viable pattern first** — never recommend OWL when a semantic view will do
2. **Start from the problem, not the theory** — ask what they want to DO, not what they think they need
3. **Build in the meeting** — the customer leaves with working artifacts, not a strategy deck
4. **Graduate over time** — the first layer seeds the next; wiki → semantic → graph → formal

## Three Phases

### Phase 1 — Discovery

Ask these questions conversationally (not as a form). Each answer narrows the recommendation:

1. **"What does your organization do?"**
   - Industry context: pharma, banking, manufacturing, retail, government, healthcare provider
   - This seeds the examples and terminology you'll use

2. **"What questions do you wish you could ask your data right now?"**
   - Routes toward semantic layer if answers are analytical
   - Routes toward graph if answers are about relationships/connections

3. **"Do you need codes or terms that everyone in your industry agrees on?"**
   - YES → Reference Terminology is part of their stack (SNOMED, ICD, LOINC, NAICS, FIBO, etc.)
   - NO → They may still benefit from controlled vocabulary, but not industry standards

4. **"When data changes, do real-world actions need to happen?"**
   - YES → Operational ontology (object-link-action pattern)
   - NO → Descriptive/analytical ontology only

5. **"Do you need to trace how things connect — what leads to what?"**
   - YES → Domain graph / property graph pattern
   - NO → Flat/tabular patterns sufficient

6. **"Do you already have an ontology team, RDF/OWL tools, or a graph database?"**
   - YES → Formal ontology path (delegate to ontology-stack-builder skill)
   - NO → Stay in lighter patterns

7. **"Is this primarily for reporting, operations, compliance, or research?"**
   - Confirms routing and priority

### Phase 2 — Recommendation

Based on discovery answers, produce a recommendation with:

- **Which families they need** (typically 2-3 from the 7-family taxonomy)
- **Priority order** (lightest first, build up)
- **Snowflake feature mapping** for each
- **Estimated time** per layer
- **What "done" looks like** at each stage

Format the recommendation as a clear visual summary, not a wall of text.

### Phase 3 — Build

Route to the appropriate implementation based on recommendation:

| Pattern | Action | Delegated To |
|---|---|---|
| Semantic View | Discover tables, propose dimensions/metrics/joins, create YAML | `semantic-view` skill |
| Operational Ontology | Map workflow steps, create action tables + agent spec | Templates in this skill |
| Domain Graph | Discover entities, propose schema, create graph tables | Templates in this skill |
| Agent Wiki | Set up stage + Cortex Search service | `search-optimization` skill |
| Reference Terminology | Point to Marketplace, set up crosswalk tables | Guidance + Marketplace |
| Formal Ontology (rare) | Run 7-phase OWL pipeline | `ontology-stack-builder` skill |

## Routing Rules

See `decision_tree.md` for the complete routing logic.

### Quick Routing Heuristic

- **"I want to ask questions about my data"** → Semantic View (80% of customers)
- **"I want to automate workflows"** → Operational Ontology
- **"I want to see what connects to what"** → Domain Graph
- **"I need industry-standard codes"** → Reference Terminology + whatever else
- **"I want to capture institutional knowledge"** → Agent Wiki
- **"I already have OWL/RDF and need Snowflake integration"** → Formal Ontology (delegate)

### The 5% Gate (Formal Ontology)

Only route to the formal ontology path when ALL of these are true:
- Customer has existing RDF/OWL investments (Stardog, GraphDB, Protégé, Neptune)
- OR regulatory/contract requirement mandates formal ontology deliverable
- Customer answers YES to "Do you need machine reasoning / inference?"
- Customer has or is willing to build an ontology team to maintain it

If ANY of those are false, route to a lighter pattern.

## Industry-Specific Examples

### Healthcare / Pharma
- Reference: SNOMED CT, ICD-10, LOINC, RxNorm, NDC
- Semantic: Patient metrics, claim outcomes, drug utilization
- Operational: Claims adjudication engine (F6 pattern), prior auth workflows
- Graph: Patient→Provider→Outcome→Geography (FIMR pattern)
- Application: OMOP CDM, FHIR profiles

### Financial Services
- Reference: FIBO, NAICS, LEI, ISIN
- Semantic: Trade metrics, risk measures, P&L dimensions
- Operational: Trade execution, compliance triggers, alert workflows
- Graph: Entity→Counterparty→Exposure→Sector

### Manufacturing / Supply Chain
- Reference: ISA-95, GS1, UNSPSC
- Semantic: OEE metrics, yield dimensions, supplier performance
- Operational: Quality alerts, predictive maintenance triggers
- Graph: Part→Supplier→Plant→Route→Customer

### Retail / E-Commerce
- Reference: schema.org/Product, GPC, GTIN
- Semantic: Revenue metrics, customer segments, product dimensions
- Operational: Inventory triggers, pricing rules, recommendation actions
- Graph: Customer→Product→Category→Supplier

## Presentation Asset

The HTML presentation (`~/Downloads/Ontology_Builder_Presentation.html`) is designed to precede this skill in a customer meeting:

1. Show presentation (10 slides, ~15 minutes)
2. Transition at slide 9: "Let's build yours"
3. Invoke this skill in their CoCo instance
4. Walk through discovery + build live

## Connection to Existing Skills

- `semantic-view`: Primary backend for the most common recommendation
- `search-optimization`: Backend for Agent Wiki pattern
- `ontology-stack-builder`: Heavy backend for formal OWL (5% of cases)
- `cortex-agent`: Referenced when building operational ontology (agent as action layer)
- `sql-author`: Used when discovering their tables and relationships

## Phase 3 — Visualize (Knowledge Graph Renderer)

After building the ontology, generate an interactive visualization using the template at `renderer/ontology_graph.html`.

### Data Contract

The template expects three arrays injected as JSON:

```
nodes: [{id, label, layer, color, r, desc, metrics:[{n,v}]}]
links: [{source, target, label, layer, color}]
layers: [{id, label, color}]
```

### How to Generate

1. After the build phase completes, inventory all tables/views/models created
2. Map each to a node with:
   - `id`: snake_case identifier
   - `label`: human-friendly name
   - `layer`: one of the project's logical layers (clinical, sdoh, model, etc.)
   - `color`: hex from the layer palette
   - `r`: 8-14 based on importance (core entities larger)
   - `desc`: 1-2 sentence description with record counts
   - `metrics`: key facts [{n:"Records", v:"50,000"}]
3. Map relationships between entities to links
4. Define layers with distinct colors
5. Replace `{{NODES}}`, `{{LINKS}}`, `{{LAYERS}}`, `{{PROJECT_NAME}}` in the template
6. Write the resulting HTML to the project's output directory

### Engine Features (built-in, no modification needed)

- D3 force-directed layout with zoom + pan
- Lock/unlock button (freeze layout, still drag individual nodes)
- Layer filter buttons (isolate by logical layer)
- Click-to-highlight with detail panel
- Hover tooltips
- Connection counting
- Initial zoom-to-fit
