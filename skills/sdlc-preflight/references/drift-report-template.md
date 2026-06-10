# Plugin / Live Account Drift Report

Template for reporting drift between guppi-platform seeds and the live GUPPIWHEEL account state. Used by SDLC preflight Check 13.

---

## Summary

- **Plugin version (manifest):** `<from .cortex-plugin/plugin.json>`
- **Plugin version (live):** `<from GUPPIWHEEL.PUBLIC.PLUGIN_VERSION>`
- **Drift items found:** `<count>`
- **Status:** PASS | DRIFT_DETECTED

## Sub-check results

| # | Check | Status | Details |
|---|-------|--------|---------|
| 13.1 | Plugin version match | ✓/✗ | manifest=X.Y.Z, live=A.B.C |
| 13.2 | Schema match | ✓/✗ | <missing columns / extra columns> |
| 13.3 | Rules match | ✓/✗ | <missing rule_ids / orphan rule_ids> |
| 13.4 | Procs/agents/task/SV present | ✓/✗ | <missing objects> |
| 13.5 | Stage hygiene | ✓/✗ | <orphaned static_html/pdf artifacts> |
| 13.6 | Identifier hygiene | ✓/✗ | <orphaned cortex_agent/streamlit/native_app refs> |
| 13.7 | Local-path scan | ✓/✗ | <files / artifacts referencing local paths> |
| 15 | Plan-to-wheel sync | ✓/✗ | <orphan .plan.md files with no NARRATIVE in wheel> |
| 16 | Commit-to-wheel reference | ✓/✗ | <orphan commits with no Wheel: footer> |

## Drift items

### Item 1: <one-line description>

- **Type:** version_mismatch | schema_drift | missing_rule | orphan_rule | missing_object | stage_orphan | identifier_orphan | local_path
- **Location:** <table.column / artifact_id / file:line>
- **Source of truth:** seeds/<file>
- **Live state:** <what's actually there>
- **Fix command:**
  ```bash
  # or SQL
  ```

### Item 2: ...

## Recommended remediation order

1. Run `seeds/upgrades/<from>-to-<to>.sql` if version mismatched
2. Re-run `seeds/engine/01_schema.sql` if schema drifted
3. Re-run `seeds/engine/02_rules.sql` if rules drifted (MERGE handles updates)
4. Re-run `seeds/engine/03_procs.sql` / `04_semantic_view.sql` / `05_agents.sql` if objects missing
5. For stage orphans: re-publish via PUBLISH_ARTIFACT, or remove the artifact row
6. For identifier orphans: recreate the missing object, or remove the artifact row
7. For local-path scans: migrate using PUBLISH_ARTIFACT to upload bytes into ARTIFACT_ASSETS stage

## Override

If drift is intentional (e.g., customer-specific local rule), promote the change back into seeds before push. **Drift cannot persist** — either lift live state into the plugin, or reset live to match the plugin.
