# GUPPI SDLC — Stories, Epics, Templates

## Creating Stories

### Required Fields
- STORY_ID: Use next available in prefix sequence (query MAX + 1)
- EPIC_ID: Must reference existing epic
- TITLE: One line, action-oriented
- PRIORITY: P0 (blocker), P1 (must-have), P2 (nice-to-have)
- STATUS: BACKLOG (default), PLANNED, IN_PROGRESS, DONE
- STORY_TYPE: STORY (default), DEFECT, TECH_DEBT

### Templates

Before writing a User Story, check if a template applies:

| Work Type | Template | Required Sections |
|-----------|----------|-------------------|
| ML Model | ML_MODEL_TEMPLATE | Target variable, features, data source, metrics, model card location, surface location |
| New API Endpoint | API_TEMPLATE | Method, path, request/response schema, auth, error codes |
| Schema Change | SCHEMA_TEMPLATE | Table DDL, migration path, FK relationships, indexes |
| UI Feature | UI_TEMPLATE | Wireframe reference, data source, interactions, responsive behavior |
| Defect | DEFECT_TEMPLATE | Reproduction steps, expected vs actual, impact, root cause hypothesis |

### ML Model Template (first example)

Every ML model story MUST include:
1. **Target variable** — what are we predicting?
2. **Feature set** — what inputs drive the prediction?
3. **Training data source** — which layer (1/2/3)? How much?
4. **Success metrics** — what R²/MAE/F1 makes this shippable?
5. **Model card location** — where in the product DB?
6. **Surface location** — where does the user SEE this? (app tab, API, Streamlit)
7. **Limitations** — what CAN'T it do? What biases exist?

### Status Transitions
```
BACKLOG → PLANNED → IN_PROGRESS → DONE
                 ↘ BLOCKED (needs dependency)
```

### Priority Rules
- P0: Blocks other work or is a live production issue
- P1: Required for next milestone/demo
- P2: Valuable but not blocking
