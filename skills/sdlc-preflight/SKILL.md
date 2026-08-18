---
name: sdlc-preflight
description: "SDLC preflight checks for the CoCo healthcare portfolio. Validates README freshness, test coverage, skill-code sync, secret scanning, changelog, manifest integrity, portfolio manifest, hero page freshness, model registry sync, and notebook freshness before git push. Use when: preflight, pre-push, sdlc, code review, quality gate, readme check, test check, skill sync, changelog, portfolio health, before pushing, ready to push, hero page, docs html, showcase page, model registry, notebook."
---

# SDLC Preflight

Quality gate for the CoCo healthcare portfolio. Run before every git push to ensure repos meet standards.

## When to Invoke

- Before any `git push`
- When asked to review/audit a repo
- When a new version is deployed (Native Apps)
- When the user says "preflight", "ready to push", "check quality", or "sdlc"

## Preflight Checks

Run ALL checks in order. Report results as a pass/fail checklist.

### Check 1: README Freshness

**Load** `references/readme-template.md` for the required structure.

Verify the repo's README.md contains these required sections:
- Title (matches actual project name/purpose)
- Overview/description paragraph
- Architecture diagram or description
- Installation/deployment instructions
- Usage section with code examples
- Version history or link to CHANGELOG.md
- Credits & acknowledgments
- License

**How to check:**
1. Read README.md
2. Compare the title against what the app actually does (check manifest.yml, main.py, SKILL.md)
3. Verify the architecture section reflects current feature set (count mappers, tables, input/output formats)
4. Check that code examples use current API (proc names, param counts)
5. Verify project structure tree matches actual directory listing
6. **Check downstream READMEs**: scan for any additional README.md files in subdirectories (e.g. `skill/README.md`, `docs/README.md`, `streamlit/README.md`). Each downstream README must:
   - Reference the current project name (not an old name)
   - Reference current feature counts (mappers, tables, formats)
   - Reference current install paths (skill folder name, stage paths)
   - Not contradict the root README

**Pass criteria:** Root README has all required sections AND content matches current state AND all downstream READMEs are consistent.
**Fail criteria:** Missing sections, content describes an older version, OR any downstream README is stale/contradictory.

### Check 2: Test Coverage

Verify tests exist and are appropriate for the project type:

| Project Type | Required Tests |
|-------------|---------------|
| Native App | `tests/` dir with graduated Level 1/2/3 pattern (see `$app-testing` skill) |
| Streamlit App | At minimum, a manual test plan. Ideally `$app-testing` graduated tests |
| CoCo Skill | No code tests, but SKILL.md must have accurate trigger phrases and step counts |
| Data Pipeline | SQL compilation check (`only_compile=true`) or test script |
| React/SPCS App | `npm test` or equivalent |

**How to check:**
1. Look for `tests/` directory
2. If exists, verify test files reference current proc/table names
3. Check if `--level` flag pattern is used (graduated testing)
4. Report: "Tests exist: Y/N", "Test files current: Y/N", "Last known pass: [date or unknown]"

**Pass criteria:** Tests exist and reference current code.
**Fail criteria:** No tests, or tests reference outdated proc/table names.

### Check 3: Skill-Code Sync (if applicable)

Only applies to repos with a `skill/` directory or corresponding installed skill in `~/.snowflake/cortex/skills/`.

**How to check:**
1. Read SKILL.md `name:` and `description:` fields
2. Compare mapper/proc counts in SKILL.md against actual `setup_procs.sql` or equivalent
3. Compare trigger phrases against actual features
4. Check that `references/` files match current architecture
5. Verify the installed copy at `~/.snowflake/cortex/skills/<name>/` matches the repo copy

**Pass criteria:** Skill files accurately describe current code. Installed copy matches repo copy.
**Fail criteria:** Counts don't match, trigger phrases missing new features, installed copy outdated.

### Check 4: Secret Scanning

Scan all staged/modified files for potential secrets.

**Patterns to flag:**
- API keys: `[A-Za-z0-9]{32,}` in config files
- Passwords: `password\s*=\s*['"][^'"]+['"]` (case-insensitive)
- Connection strings with credentials
- `.env` files staged for commit
- Private key files (`.pem`, `.p8`, `.key`)
- Snowflake PATs or tokens
- AWS/Azure/GCP credentials

**How to check:**
1. Run `git diff --cached --name-only` (or `git diff --name-only` for unstaged)
2. Grep modified files for secret patterns
3. Check `.gitignore` exists and covers common secret files

**Pass criteria:** No secrets detected in staged files. `.gitignore` exists.
**Fail criteria:** Potential secret found. Report file + line number (but NOT the secret value).

### Check 5: CHANGELOG

**Load** `references/changelog-template.md` for the required format.

**How to check:**
1. Check if `CHANGELOG.md` exists in repo root
2. If exists, verify latest entry matches the current version being pushed
3. If not exists, generate one from git log

**Pass criteria:** CHANGELOG.md exists with current version entry.
**Fail criteria:** Missing or outdated. Offer to generate from git log.

### Check 6: Manifest Validation (Native Apps only)

Only applies to repos with `manifest.yml`.

**How to check:**
1. Read `manifest.yml`
2. Verify `manifest_version` is set (should be 2)
3. Verify `artifacts.setup_script` points to an existing file
4. Verify all referenced files in manifest exist on disk
5. Check that privilege definitions match what the app actually uses

**Pass criteria:** All referenced files exist, version set correctly.
**Fail criteria:** Missing files, bad references.

### Check 7: Portfolio Manifest Sync

**Load** `references/portfolio-manifest.md` for the master tracking list.

**How to check:**
1. Read the portfolio manifest from memory (`/memories/portfolio-manifest.md`)
2. Verify current repo's entry is up-to-date (version, last push date, test status)
3. If entry missing, add it

**Pass criteria:** Portfolio manifest has current entry for this repo.
**Fail criteria:** Entry missing or outdated. Update it.

### Check 8: Hero Page Freshness

Authored HTML pages in `docs/` directories and the `coco-playbook/` site serve as showcase/demo documentation. They contain version numbers, feature counts, architecture descriptions, and app names that can go stale when code changes.

**Scope:**
- The **master playbook** at `coco-playbook/` (index.html, snowwork_portfolio.html, apps.html, skills-showcase.html, and child pages)
- **Per-repo docs/** HTML pages (install guides, showcases, summaries, project overviews)
- Exclude build artifacts in `dist/`, `public/`, `static/`

**How to check:**
1. Scan repo for `docs/*.html` files (exclude dist/public/static)
2. For each HTML file, extract key factual claims: version numbers, feature counts (mapper counts, table counts, skill counts), app/project names, architecture descriptions
3. Compare against current code truth:
   - App name matches (e.g. "Snowflake Health Data Forge" not "Tuva FHIR-to-OMOP")
   - Version matches latest deployed version
   - Counts match (mappers, tables, OMOP vs Tuva, input formats)
   - Architecture diagram reflects current capabilities
4. Cross-check consistency between playbook pages and per-repo docs (e.g. Tuva mapper count should be same everywhere)
5. Flag any customer/employee PII in pages intended for external distribution

**Pass criteria:** All hero pages reflect current code state. Counts and names are consistent across all pages.
**Fail criteria:** Any page references an old app name, old version, wrong counts, or outdated architecture.
**Warn criteria:** Minor inconsistencies or PII in shareable docs.

### Check 9: Model Registry Sync (if applicable)

Only applies to repos with ML models registered in Snowflake Model Registry.

**How to check:**
1. Look for `model/` directory with training scripts and checkpoints
2. Check if `register_models.py` or `register_graph_models.py` exists
3. Run `SHOW VERSIONS IN MODEL <model_name>` to list registered versions
4. Compare registered version dates against local checkpoint dates
5. Compare registered metrics against local `comparison_*.json` or `results_*.json` files
6. Check that both base AND graph-enhanced versions are registered (if graph model exists)

**Pass criteria:** All local model checkpoints have corresponding registry versions with matching metrics.
**Fail criteria:** Local checkpoints are newer than registry versions, or graph-enhanced versions missing from registry. Offer to run the registration script.

### Check 10: Notebook Freshness (if applicable)

Applies to repos with `notebooks/*.ipynb` files.

1. Check that notebooks exist in the `notebooks/` directory
2. Compare the notebook's "Last updated" date (in first markdown cell) against recent code changes
3. Verify the notebook references current table names, record counts, and model versions
4. Check that data lineage section matches current schema (e.g., new tables like REF_* calibration tables should be listed)
5. Verify SQL cell references match current MEASUREMENT_SOURCE_VALUE, CONDITION_SOURCE_VALUE patterns (these change when data is regenerated)

**Pass criteria:** Notebook "Last updated" date is within 7 days of most recent model training or data regeneration. Data lineage and record counts match current state. Snowsight notebook matches local file.
**Fail criteria:** Notebook references stale record counts, missing tables, or outdated model versions. Snowsight notebook is out of sync with local. Offer to rewrite and redeploy.

**Deployment:** After updating a local notebook, deploy to Snowsight Workspace:
```
cortex artifact create notebook "<Display Name>" "<local_path>.ipynb" -c <connection>
```
URL pattern: `https://app.snowflake.com/<org>/<account>/#/workspaces/ws/USER%24/PUBLIC/DEFAULT%24/<filename>.ipynb`

**Known notebook locations:**
| Repo | Local Path | Workspace URL |
|---|---|---|
| fimr-dashboard | `notebooks/fimr_workspace_explorer.ipynb` | `https://app.snowflake.com/sfsehol/si_industry_demos_healthcare_lmszks/#/workspaces/ws/USER%24/PUBLIC/DEFAULT%24/fimr_workspace_explorer.ipynb` |

### Check 11: Skill Registry Completeness

Every local skill (including sub-skills) must have a corresponding row in `SKILL_REGISTRY.PUBLIC.SKILLS`.

**How to check:**
1. Count local SKILL.md files: `find ~/.snowflake/cortex/skills -name "SKILL.md" | wc -l`
2. Count DB rows: `SELECT COUNT(*) FROM SKILL_REGISTRY.PUBLIC.SKILLS`
3. If local > DB, skills are missing from registry

**Fix:** Run the sync script:
```bash
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 \
  ~/.snowflake/cortex/plugins/guppi-platform/skills/skill-registry-collaborator/sync_skills.py
```

**Path note:** the script lives under the *plugin* tree
(`~/.snowflake/cortex/plugins/guppi-platform/skills/...`), NOT
`~/.snowflake/cortex/skills/...`. It *reads* `~/.snowflake/cortex/skills` (its `SKILLS_DIR`)
but is not installed there.

**Privilege prerequisite (added 2026-08-18):** the script writes with the connection's
DEFAULT role. Since the orchestrator posture sets that to `GUPPIWHEEL_CONTRIBUTOR`
(RULE-034, no standing DML), the sync fails with
`Insufficient privileges to operate on table 'SKILLS'` unless the role can write the
registry. `SKILL_REGISTRY` is a separate database from the wheel substrate, and publishing
skills is contributor work (analogous to `PRODUCTS`), so grant it there — this does NOT
reopen any wheel write path:
```sql
GRANT USAGE ON DATABASE SKILL_REGISTRY TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON SCHEMA SKILL_REGISTRY.PUBLIC TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT SELECT, INSERT, UPDATE ON TABLE SKILL_REGISTRY.PUBLIC.SKILLS TO ROLE GUPPIWHEEL_CONTRIBUTOR;
```

**Pass criteria:** Local SKILL.md count equals DB row count (excluding the duplicate synthetic-data-generator version row).
**Fail criteria:** Any local skill is not in the registry. Run sync.

### Check 12: Bond Sync

Every significant push should capture co-created knowledge in The Bond. This ensures persistent memory across sessions and makes insights discoverable by future agents.

**How to check:**
1. Review what was accomplished in this session (new features, architecture decisions, corrections, key learnings)
2. Query `THE_BOND.PUBLIC.MEMORY_STORE` for existing entries related to this repo/product
3. Determine if there are new insights worth persisting:
   - Architecture decisions (why we chose X over Y)
   - Corrections (user caught an error, how it was fixed)
   - Performance findings (benchmarks, thresholds discovered)
   - Integration patterns (how systems connect, auth flows, data flows)
   - Customer requirements (hard requirements stated by user)
   - Co-created designs (schemas, APIs, workflows designed together)

**What to write:**
- Category: `decision_log`, `correction`, `co-created`, `performance`, `integration_pattern`
- Tags: product name + relevant technical tags
- Content: concise JSON with the insight, context, and any numeric data
- Origin: `co-created` (always — Bond entries are collaborative by definition)

**Pass criteria:** If the session produced significant work (new features, architecture changes, key decisions), at least one Bond entry was written capturing the most important insight.
**Skip criteria:** Trivial changes (typo fixes, minor formatting) don't need Bond entries.
**Fail criteria:** Major architecture decision or customer requirement was discussed but not persisted to Bond.

**Example entry:**
```sql
INSERT INTO THE_BOND.PUBLIC.MEMORY_STORE
(AGENT_ID, CATEGORY, KEY, CONTENT, TAGS, ORIGIN, INSIGHT_TYPE, SESSION_CONTEXT)
SELECT 'coco', 'decision_log', 'f6-dur-medi-span-integration',
PARSE_JSON('{"insight": "Customer uses Wolters Kluwer Medi-Span for DUR. Licensed commercial API, not open source. Mock interface built with 75ms simulated latency. Real integration via MCP server when customer provides API key.", "performance_impact": "adds ~44ms to adjudication pipeline"}'),
ARRAY_CONSTRUCT('f6', 'dur', 'medi-span', 'architecture'), 'co-created', 'decision', 'session-44'
```

### Check 13: Plugin / Live Account Sync (guppi-platform only)

For plugins that ship Snowflake objects (guppi-platform), the live account state must match what the plugin's seeds describe. This catches drift introduced by direct edits in Snowsight, hotfixes that didn't make it back into seeds, and version mismatches.

**Source of truth:** the plugin's seed files. Live state should always match.

#### 13.1 Plugin version match (four-way)

The version is single-sourced in `.cortex-plugin/plugin.json`. Three mirrors must agree with it:

```bash
# a) source of truth
grep '"version"' .cortex-plugin/plugin.json
# b) the go-forward seed stamp literal (the CALL at the tail of 03_procs.sql)
grep "CALL GUPPIWHEEL.PUBLIC.PUBLISH_PLUGIN_VERSION(" seeds/engine/03_procs.sql
# d) the README title header (line 1)
grep -m1 '^# guppi-platform v' README.md
```
```sql
-- c) live installed version
SELECT VERSION FROM GUPPIWHEEL.PUBLIC.PLUGIN_VERSION WHERE PLUGIN_NAME = 'guppi-platform';
```

**Assert all four equal:** `plugin.json version` == the `PUBLISH_PLUGIN_VERSION('X', …)` literal in `03_procs.sql` == live `PLUGIN_VERSION` == the `# guppi-platform vX.Y.Z` header on line 1 of `README.md`.

- **plugin.json ≠ seed literal** → someone bumped the release but not the stamp (or vice-versa). Fix: set the `03_procs.sql` `CALL` literal to match `plugin.json` (plugin.json wins).
- **seed literal ≠ live** → live is stale. Fix: run the engine seed (the tail `CALL PUBLISH_PLUGIN_VERSION` self-heals live), or `CALL GUPPIWHEEL.PUBLIC.PUBLISH_PLUGIN_VERSION('<plugin.json version>', 'preflight reconcile', FALSE)`. The proc's monotonicity guard refuses a regression (pass `P_FORCE => TRUE` only for a deliberate rollback).
- **README header ≠ plugin.json** → the README title drifted (it is NOT auto-stamped; it silently sat at 3.16.2 through several releases until caught 2026-07-16). Fix: edit `README.md` line 1 to `# guppi-platform v<plugin.json version>`.

**Pass:** all four identical. **Fail:** report which pair diverged + the fix above. (The stamp is written only via `PUBLISH_PLUGIN_VERSION` — never a raw `MERGE`; direct DML on `PLUGIN_VERSION` is revoked.)

#### 13.2 Schema match

For each table seeds/engine/01_schema.sql declares (ARTIFACTS, RULES, VIOLATIONS, ID_CONVENTIONS, INITIATIVE_STEPS, ARTIFACT_LAUNCHES, PLUGIN_VERSION, PRODUCTS), compare:

```sql
DESC TABLE GUPPIWHEEL.PUBLIC.<TABLE_NAME>;
```

against the DDL in the seed. **Extra columns or missing columns = drift.**

#### 13.3 Rules match

```sql
SELECT RULE_ID FROM GUPPIWHEEL.PUBLIC.RULES ORDER BY RULE_ID;
```

Every RULE_ID in the seed must exist live, and vice versa. Any rule that exists live but not in `seeds/engine/02_rules.sql` is drift — either promote the live rule into seeds or remove it from live.

#### 13.4 Procs / agents / task / semantic view present

```sql
SHOW PROCEDURES IN SCHEMA GUPPIWHEEL.PUBLIC;
SHOW AGENTS IN SCHEMA GUPPIWHEEL.PUBLIC;
SHOW TASKS IN SCHEMA GUPPIWHEEL.PUBLIC;
SHOW SEMANTIC VIEWS IN SCHEMA GUPPIWHEEL.PUBLIC;
```

Required objects:
- Procs: ADVANCE_STAGE, SUBMIT_INITIATIVE, ROCKY_EXECUTE, PUBLISH_ARTIFACT, GET_ARTIFACT_LAUNCH
- Agents: ROCKY_AGENT, GUPPIWHEEL_COWORK_AGENT
- Tasks: ROCKY_TASK (state=`started`)
- Semantic views: GUPPIWHEEL_SV

**Missing object = drift; re-run `seeds/engine/03_procs.sql` / `04_semantic_view.sql` / `05_agents.sql`.**

#### 13.5 Stage hygiene (RULE-018 enforcement)

For every NARRATIVE / APP / MODEL / DASHBOARD artifact with `metadata.launch.app_type IN ('static_html', 'pdf')`:

```sql
SELECT a.ID, a.METADATA:launch:stage_path::VARCHAR AS stage_path
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.TYPE IN ('NARRATIVE','APP','MODEL','DASHBOARD')
  AND a.METADATA:launch:app_type::VARCHAR IN ('static_html', 'pdf');
```

For each row's `stage_path`, run `LIST` on the stage and confirm the file exists. Orphaned artifacts (pointing at missing files) get flagged.

#### 13.6 Identifier hygiene

For every artifact with `app_type IN ('cortex_agent', 'streamlit', 'native_app')`, verify the identifier resolves:

```sql
SHOW AGENTS;
SHOW STREAMLITS;
SHOW APPLICATIONS;
```

Orphaned identifiers (artifact references an agent/streamlit/app that doesn't exist) get flagged.

#### 13.7 Local-path scan

```bash
grep -r "Downloads/CoCoStuff" guppi-platform/seeds/ guppi-platform/skills/guppi/render_guppi.py
```

Zero matches required. Local file paths in production seeds violate RULE-018.

```sql
SELECT ID FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
WHERE TYPE IN ('NARRATIVE','APP','MODEL','DASHBOARD')
  AND METADATA::VARCHAR LIKE '%Downloads/CoCoStuff%';
```

Zero rows required.

#### 13.8 Type taxonomy sync

`TYPE_REGISTRY` is the single source of truth for the artifact-type taxonomy. `GROUNDING_HEALTH_V`, `CREATE_ARTIFACT`, and the semantic view all derive from / enforce against it. This check catches the drift that hid OUTCOME from the semantic model.

```sql
-- a) every live TYPE is registered (also surfaced by GROUNDING_HEALTH_V.noncanonical_artifact_type)
SELECT DISTINCT a.TYPE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
LEFT JOIN GUPPIWHEEL.PUBLIC.TYPE_REGISTRY r ON a.TYPE = r.TYPE
WHERE r.TYPE IS NULL;   -- expect 0 rows

-- b) registry row count (for the enumeration check below)
SELECT LISTAGG(TYPE, ', ') WITHIN GROUP (ORDER BY TYPE) AS types,
       LISTAGG(DISTINCT s.VALUE, ', ') AS stages
FROM GUPPIWHEEL.PUBLIC.TYPE_REGISTRY r, LATERAL SPLIT_TO_TABLE(r.STAGES, ',') s;
```

Then assert the semantic view enumerates the taxonomy (whether it joins `TYPE_REGISTRY` or uses the guarded fallback):
- Every `TYPE_REGISTRY.TYPE` name appears in `seeds/engine/04_semantic_view.sql` (the `TYPE` dimension `COMMENT` + the `AI_SQL_GENERATION` hint).
- Every distinct stage (union of `STAGES`) appears in the `STAGE` dimension `COMMENT` + AI hint.

```bash
# each registry TYPE must be present in the semantic view text
grep -o "OUTCOME\|OPS_EVENT\|SKILL\|INITIATIVE\|EPIC\|RESEARCH\|STORY\|NARRATIVE\|APP\|MODEL\|DASHBOARD\|DEFECT\|INCIDENT\|AUDIT" seeds/engine/04_semantic_view.sql | sort -u
```

Definitions are NOT restated in the semantic view (they live only in `TYPE_REGISTRY`), so only the name/stage enumeration can drift and this check covers it.

**Pass criteria:** (a) returns 0 rows; every registry type name + every stage appears in the semantic view text.
**Fail criteria:** an unregistered live type, OR a registry type/stage missing from the semantic view. Fix: register the type in `TYPE_REGISTRY`, or update the `04_semantic_view.sql` TYPE/STAGE comments + AI hint to enumerate it.

**Pass criteria:** All 13.1-13.8 sub-checks pass. Drift items get a fix command in the report.
**Fail criteria:** Any sub-check shows drift. Push blocks until either the seed catches up to live, or live is reset from seeds.

Applies to all repos with skills that are also registered in SKILL_REGISTRY.PUBLIC.SKILLS.

**The source of truth is the Snowflake table, not the local file.** If they drift, the local file is wrong.

**How to check:**
1. List local skills: `ls ~/.snowflake/cortex/skills/`
2. Query the registry: `SELECT SKILL_ID, VERSION, SKILL_CONTENT FROM SKILL_REGISTRY.PUBLIC.SKILLS`
3. For each local skill that exists in the registry, compare:
   - Does the local SKILL.md describe the same architecture as the VARIANT?
   - Does it reference the same endpoints, auth methods, and verbs?
   - Does the version match?
   - Are there stale references to deprecated approaches (e.g., MCP server endpoints when architecture moved to shared table)?
4. Check the connection config in SKILL_CONTENT:connection against what the local SKILL.md describes

**Key drift patterns to catch:**
- Local file references SPCS/MCP server but SKILL_CONTENT:connection:protocol = "SQL API + Snowflake Data Share"
- Local file has old endpoint URLs that no longer exist
- Local file describes fewer verbs/actions than SKILL_CONTENT:actions array
- Local file version doesn't match registry VERSION column
- Local file missing narrative/agents/provider setup that exists in VARIANT

**Pass criteria:** All local skill files match their SKILL_REGISTRY VARIANT counterparts in architecture, endpoints, and capabilities.
**Fail criteria:** Any local skill describes a different architecture or outdated approach vs what's in the registry table. Rewrite from the VARIANT.

## Report Format

After all checks, present a summary:

```
=== SDLC Preflight Report: <repo-name> ===

[PASS] README Freshness — all sections present, matches current V1.6
[FAIL] Test Coverage — tests/test_transformation.py references 9 mappers, code has 23
[PASS] Skill-Code Sync — snowflake-health-data-forge matches repo
[PASS] Secret Scanning — no secrets detected
[WARN] CHANGELOG — missing, recommend creating
[PASS] Manifest Validation — manifest.yml valid
[PASS] Portfolio Manifest — entry updated
[PASS] Hero Page Freshness — all docs/*.html pages match current state
[PASS] Model Registry — 9 versions registered (3 original + 3 base + 3 graph)
[PASS] Notebook Freshness — fimr_workspace_explorer.ipynb updated April 28, 2026
[PASS] Skill Registry Sync — all local skills match SKILL_REGISTRY table
[PASS] Bond Sync — 2 entries written (architecture decision + performance findings)

Result: 9 passed, 1 failed, 1 warning
Action items:
  1. Update tests/test_transformation.py to cover V1.2+ mappers
  2. Create CHANGELOG.md (offer to generate from git log)
```

## Fixing Failures

For each failure, offer to fix it immediately:
- **README outdated** → Rewrite with current info using the README template
- **Tests outdated** → Update test files to reference current procs/tables
- **Skill drift** → Update skill files and copy to installed location
- **Secret detected** → Add to .gitignore, remove from staging
- **CHANGELOG missing** → Generate from git log
- **Manifest broken** → Fix references
- **Portfolio entry missing** → Add/update entry
- **Hero page stale** → Update version, counts, names, architecture in the HTML. Cross-check consistency with all other hero pages in the portfolio. For the playbook site, update all referencing pages.
- **Model Registry stale** → Run the registration script (`register_graph_models.py` or `register_models.py`) to update registry with latest checkpoints.
- **Skill Registry drift** → Rewrite local SKILL.md from the VARIANT in SKILL_REGISTRY.PUBLIC.SKILLS (the table is source of truth).
- **Bond not synced** → Write Bond entry capturing the session's key insight (architecture decision, performance finding, customer requirement, or correction).

## Hook Integration

This skill is designed to work with CoCo hooks. Add to `~/.snowflake/cortex/hooks.json`:

```json
{
  "hooks": {
    "user-prompt-submit": [
      {
        "matcher": "git push",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'REMINDER: Run $sdlc-preflight before pushing'"
          }
        ]
      }
    ]
  }
}
```

This reminds you to run preflight checks before any push. The actual checks run via the skill, not the hook — the hook is just the trigger/reminder.

## Dual-Remote Push

Some repos are published to both a personal GitHub (&lt;personal-github&gt;) and a Snowflake org GitHub (sfc-gh-tcrosslin). When pushing these repos, push to **both** remotes.

### Setup (one-time per repo)

```bash
# Add the Snowflake remote
git remote add snowflake https://github.com/sfc-gh-tcrosslin/<repo-name>.git

# Verify both remotes
git remote -v
# origin     https://github.com/<personal-github>/<repo-name>.git (push)
# snowflake  https://github.com/sfc-gh-tcrosslin/<repo-name>.git (push)
```

### Push Pattern

After all preflight checks pass, push to both:

```bash
git push origin main && git push snowflake main
```

### Which Repos Have Dual Remotes

| Repo | origin (<personal-github>) | snowflake (sfc-gh-tcrosslin) |
|------|----------------------|------------------------------|
| ncpdp-f6-claims-engine | ✅ | ✅ |
| coco-playbook | ✅ | ✅ |
| MS_FIMR (fimr-dashboard) | ✅ | ✅ |
| tre-healthcare-snowflake (healthcare-mcp-app) | ✅ | ✅ |
| tuva-fhir-to-omop-app | ✅ | ✅ |
| oncolook-digital-pathology | ✅ | ✅ |
| coco-skills | ✅ | ✅ |
| building-with-coco | N/A | ✅ (webinar repo, snowflake-only) |
| guppi-platform | ✅ (remote name: `jacinthlaval`) | ✅ (remote name: `origin`) |

Add more repos to this table as they get dual remotes.

**Remote names are NOT consistent across repos.** In `guppi-platform` the mapping is
*inverted* from the pattern above: `origin` = sfc-gh-tcrosslin and `jacinthlaval` = the
personal account. Always read `git remote -v` before pushing; do not assume `origin` is
the personal remote.

**A private repo you are not authenticated for reports `Repository not found`, not
`Forbidden`.** GitHub deliberately masks private repos over HTTPS, so a stale/incorrect
active `gh` account looks exactly like a deleted repo. Before concluding a remote is gone,
run `gh auth status` — if the owning account is listed but `Active account: false`, it is
an auth problem, not a missing repo.

**NOTE:** `gh auth switch --user <personal-github>` is required before pushing to origin if the active account is sfc-gh-tcrosslin. Switch back after.

## Snowflake-Solutions Sync (Separate from Dual-Remote Push)

Some skills/repos are **synced** to the Snowflake-Solutions org team incubator. This is **NOT** a dual-remote push — it's a one-way mirror from the sfc-gh-tcrosslin repo into the team's shared repo via GitHub Actions.

### Key Distinction

| Concept | Dual-Remote Push | Snowflake-Solutions Sync |
|---------|-----------------|--------------------------|
| **What** | Same code pushed to 2 personal/org repos | Subset of code mirrored into team shared repo |
| **Direction** | Bidirectional (both are your repos) | One-way (your repo → team repo) |
| **Trigger** | Manual push after preflight | Automated via GitHub Action on push to main |
| **Accounts** | <personal-github> + sfc-gh-tcrosslin | sfc-gh-tcrosslin → Snowflake-Solutions org |
| **Auth** | gh auth switch between accounts | INCUBATOR_PAT secret on source repo |
| **When to use** | Every repo you own | Only skills/assets shared with the broader team |

### Active Syncs

| Source Repo (sfc-gh-tcrosslin) | Target Repo (Snowflake-Solutions) | Branch | Path | Trigger |
|-------------------------------|----------------------------------|--------|------|---------|
| coco-skills | health-sciences-coco-skills-incubator | tcrosslin-dev | skills/hcls-cross-tars-trust-auditor/ | Push to main touching tars-trust-auditor/** |

### Setup Pattern (for new syncs)

1. Create GitHub Action in source repo (`.github/workflows/sync-<name>.yml`)
2. Set `INCUBATOR_PAT` secret on source repo (PAT with SSO auth for Snowflake-Solutions)
3. Action clones target repo, copies files, commits with `[automated]` tag
4. The personal account is NOT involved in these syncs — this is sfc org-to-org only

### Preflight Integration

When running preflight, note any active syncs in the report:

```
Push targets:
  → origin: https://github.com/<personal-github>/coco-skills.git
  → snowflake: https://github.com/sfc-gh-tcrosslin/coco-skills.git
Syncs:
  → Snowflake-Solutions/health-sciences-coco-skills-incubator (tars-trust-auditor, automated)
```

### Preflight Integration

When running preflight, Check 7 (Portfolio Manifest) should note which remotes the repo has. The push reminder in the report should list both remotes if configured:

```
Push targets:
  → origin: https://github.com/<personal-github>/coco-playbook.git
  → snowflake: https://github.com/sfc-gh-tcrosslin/coco-playbook.git
```

### Check 15: Plan-to-wheel sync (guppi-platform only)

Every `.plan.md` file in `~/.snowflake/cortex/plans/` (or the playground equivalent) modified in the last 7 days should have a corresponding NARRATIVE artifact in the wheel. Plans on disk without wheel narratives are dogfood violations of RULE-013.

**How to check:**

```bash
# 1. List recent plan files
RECENT_PLANS=$(find ~/.snowflake/cortex/plans ~/.snowflake/cortex/playground/workspace/.snowflake/cortex/plans -name "*.plan.md" -mtime -7 2>/dev/null)
```

For each plan file basename, query:

```sql
SELECT a.ID, a.TITLE, a.METADATA:launch:stage_path::VARCHAR AS stage_path
FROM GUPPIWHEEL.PUBLIC.ARTIFACTS a
WHERE a.TYPE = 'NARRATIVE'
  AND a.METADATA:launch:stage_path::VARCHAR LIKE '%' || :plan_basename || '%';
```

**Pass criteria:** every recent plan file has at least one matching NARRATIVE artifact.
**Fail criteria:** orphan plans (file on disk, no wheel artifact). The drift report lists each orphan with a fix command:

```
Orphan plan: <plan-name>.plan.md
Fix: /wheel publish-plan <plan-name>.plan.md
   (or call PUBLISH_ARTIFACT manually if no /wheel skill available)
```

**Skip criteria:** plan files older than 7 days (covered by historical backfill, separate exercise) or explicitly tagged with `[archive]` in their title.

### Check 16: Commit-to-wheel reference (guppi-platform only)

Every git commit in `guppi-platform/` from the last 7 days should contain a `Wheel: INIT-N` (or `Wheel: NONE; reason: <text>`) footer in the commit message. The pre-push git hook enforces this on push, but Check 16 catches commits that were authored without the footer and haven't been pushed yet — letting you fix them before the push fails.

**How to check:**

```bash
git log --since="7 days ago" --pretty=format:"%H|%s|%b" -- . | while IFS='|' read -r sha subject body; do
  if ! echo "$body" | grep -qE '^Wheel: (INIT-[0-9]+|NONE)'; then
    echo "ORPHAN: $sha $subject"
  fi
done
```

For each orphan commit:
- If not yet pushed: suggest `/wheel link-commit <sha>` to amend
- If already pushed: suggest a follow-up commit referencing the relevant initiative
- If the commit was an emergency hotfix: confirm a `Wheel: NONE; reason: <text>` was acceptable (logged in drift report)

**Pass criteria:** every commit in the window has a Wheel footer (INIT-N or explicit NONE).
**Fail criteria:** orphan commits exist. Drift report counts and lists them.

**Override accounting:** if any commit uses `Wheel: NONE; reason: <text>`, sum these by month and surface as a "wheel discipline rate" metric. Trends downward over time as the loop becomes habitual.

### Check 17 (placeholder): future plan-to-initiative sync

Once Phase 5 of the dogfood plan ships (advance INIT-27 to Built), add a check that every recent plan narrative is parented to an INITIATIVE in the wheel (not just floating). For now Check 15 implicitly covers this since the publish-plan command always sets PARENT_ID.
