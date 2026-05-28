# Portfolio Manifest

Master tracking for all CoCo healthcare portfolio repos. Updated by `$sdlc-preflight` skill.

**Last updated**: 2026-04-21

## Public Repos (GitHub: JacinthLaval)

| Repo | Type | Version | Last Push | README | Tests | Skill | CHANGELOG | Status |
|------|------|---------|-----------|--------|-------|-------|-----------|--------|
| tuva-fhir-to-omop-app | Native App | V1_6 | 2026-04-21 | ✅ | ✅ | ✅ snowflake-health-data-forge | ✅ | Active |
| ontology-stack-builder | Repo Bundle | v1.0 | 2026-04-21 | ✅ | N/A | ✅ ontology-stack-builder | ❌ MISSING | Active |
| precision_advisor | Streamlit | v1.0 | 2026-04-10 | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |

## Private/Internal Repos

| Repo | Type | Version | Last Push | README | Tests | Skill | CHANGELOG | Status |
|------|------|---------|-----------|--------|-------|-------|-----------|--------|
| coco-playbook | Static Site | — | 2026-04-21 | ❓ UNCHECKED | N/A | N/A | N/A | Active |
| ms-fimr | Streamlit | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| fimr-dashboard | Streamlit | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| oncolook-digital-pathology | SPCS | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| fhir-ingestion-manager | Streamlit | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| healthcare-mcp-app | MCP | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| cugraph-variant-similarity | SPCS | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| tre_streamlit_app | Streamlit | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| snowflake-cart-pathology-intelligence | Streamlit | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| evo2-container | SPCS | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |
| fda-510k-rag | RAG | — | — | ❓ UNCHECKED | ❓ UNCHECKED | N/A | ❓ UNCHECKED | Active |

## CoCo Skills (installed at ~/.snowflake/cortex/skills/)

| Skill Name | Source Repo | Synced | Last Updated | Triggers Current |
|-----------|-------------|--------|-------------|-----------------|
| snowflake-health-data-forge | tuva-fhir-to-omop-app/skill | ✅ | 2026-04-21 | ✅ |
| ontology-stack-builder | ontology-stack-builder/skill | ✅ | 2026-04-21 | ✅ |
| agent-guardrails | standalone | — | ❓ UNCHECKED | ❓ UNCHECKED |
| app-testing | standalone | — | ❓ UNCHECKED | ✅ |
| spcs-react-agent | standalone | — | ❓ UNCHECKED | ❓ UNCHECKED |
| spcs-spa-auth | standalone | — | ❓ UNCHECKED | ❓ UNCHECKED |
| synthetic-data-generator | standalone | — | ❓ UNCHECKED | ❓ UNCHECKED |
| sdlc-preflight | standalone | — | 2026-04-21 | ✅ |

## Legend

- ✅ = Current / Passing
- ⚠️ = Exists but outdated
- ❌ = Missing / Stale
- ❓ = Not yet checked by preflight
- N/A = Not applicable for this project type
