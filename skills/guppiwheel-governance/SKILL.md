---
name: guppiwheel-governance
description: "Audits and locks down GuppiWheel RBAC so contributors write only through procedures and doctrine (RULES) is admin-only. Runs audit -> explain -> propose -> apply-on-approval -> verify against the live account, adapting to local role names. Use when: securing a GuppiWheel install, locking down the wheel, RBAC review, governance audit, contributors can change Guppi in place, after bootstrap, verify lockdown, who can change doctrine. Triggers: guppiwheel governance, rbac lockdown, lock down the wheel, governance audit, secure guppiwheel, procedure-mediated writes, admin-only doctrine, RULE-028, verify lockdown."
metadata:
  author: CoCo + Todd Crosslin
  version: 1.0.0
  category: security
  tags: [guppiwheel, rbac, governance, security, defense-in-depth, procedure-mediated, STO-36-O]
---

# GuppiWheel Governance — Procedure-Mediated Writes, Admin-Only Doctrine

> Governance cannot be enforced if raw DML exists alongside the procedures.
> The procs are a front door; this skill closes the unlocked side door.

The companion to the born-locked seed (`seeds/engine/01_schema.sql`). The seed makes a **new** install born-locked; this skill **audits and remediates existing or drifted installs**, and verifies posture on an ongoing basis. It is the human/RBAC sibling of STO-36-O (only the orchestrator changes doctrine) and a sibling skill to `agent-guardrails` (agent-generated-SQL guardrails) and `coco-enterprise-pipeline` (dev/qa/prod separation).

## The model this skill enforces

Three-tier roles:
- **GUPPIWHEEL_ADMIN** — orchestrator/human. Full direct DML including `RULES` (doctrine). The ONLY role that changes doctrine.
- **GUPPIWHEEL_CONTRIBUTOR** — writes ONLY through procedures. No direct DML on `ARTIFACTS` or `RULES`. Keeps direct DML on `ECOSYSTEM.TAXONOMY` (reference data).
- **GUPPIWHEEL_VIEWER** — read-only.

Six rules:
1. Doctrine (`RULES`, `RULES_HISTORY`) is admin-only.
2. All `ARTIFACTS` writes go through procedures; no direct contributor DML.
3. `STAGE` changes only via `ADVANCE_STAGE` so the STG rules engine is enforced, not advisory.
4. `SUPERSEDED_BY` is untouchable by contributors (protects the RULE-025 current-truth serving lens).
5. Self-edit via `UPDATE_OWN_ARTIFACT` (`OWNER = CURRENT_USER()`; refuses STAGE/SUPERSEDED_BY/TYPE).
6. `ECOSYSTEM.TAXONOMY` direct DML retained.

### Critical mechanic (do not skip)
`ADVANCE_STAGE` is `EXECUTE AS OWNER` and survives a DML revoke. `PUBLISH_ARTIFACT` and `SUBMIT_INITIATIVE` ship as `EXECUTE AS CALLER` — they will **break** when caller DML is revoked unless flipped to `EXECUTE AS OWNER` first. Always flip the procs before revoking grants.

## Operating contract: propose + apply on per-step approval

This skill NEVER bulk-applies. For each hole found, it (a) explains why it matters, (b) shows the exact SQL, (c) waits for the admin to approve THAT step, (d) applies, (e) re-verifies. Suggest, understand, admin-executes — concept-distribution per RULE-021. Adapt all role names to the local install (the installer may not use the literal `GUPPIWHEEL_*` names).

## Phase 1 — AUDIT (read-only)

Run these and report findings in plain language.

```sql
-- Roles present
SHOW ROLES LIKE 'GUPPIWHEEL%';

-- What direct DML does CONTRIBUTOR hold? (the holes live here)
SHOW GRANTS TO ROLE GUPPIWHEEL_CONTRIBUTOR;
-- Flag: any INSERT/UPDATE on GUPPIWHEEL.PUBLIC.ARTIFACTS  -> HOLE (in-place edit + stage bypass)
-- Flag: any INSERT/UPDATE on GUPPIWHEEL.PUBLIC.RULES / RULES_HISTORY -> HOLE (doctrine rewrite)

-- Are the write procs CALLER (unsafe once DML revoked) or OWNER?
SELECT 'PUBLISH_ARTIFACT' AS proc,
  CASE WHEN GET_DDL('PROCEDURE','GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(VARCHAR,VARCHAR,VARCHAR,VARIANT,VARCHAR,VARCHAR,VARCHAR)') ILIKE '%EXECUTE AS OWNER%' THEN 'OWNER (ok)' ELSE 'CALLER (must flip)' END AS exec_as
UNION ALL
SELECT 'SUBMIT_INITIATIVE',
  CASE WHEN GET_DDL('PROCEDURE','GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(VARCHAR,VARCHAR,VARCHAR)') ILIKE '%EXECUTE AS OWNER%' THEN 'OWNER (ok)' ELSE 'CALLER (must flip)' END;

-- Does the owner-scoped edit proc exist?
SHOW PROCEDURES LIKE 'UPDATE_OWN_ARTIFACT' IN SCHEMA GUPPIWHEEL.PUBLIC;
```

## Phase 2 — EXPLAIN

For each hole, state the risk: raw `ARTIFACTS` UPDATE = edit anyone's work + set STAGE directly (bypassing every STG rule) + corrupt the RULE-025 serving lens via SUPERSEDED_BY. Raw `RULES` DML = rewrite doctrine. CALLER procs = will break the moment the lockdown lands.

## Phase 3 — PROPOSE + APPLY (one step at a time, admin approves each)

```sql
-- Step A: flip write procs to OWNER (preserve all logic; only execution context changes)
--   CREATE OR REPLACE PROCEDURE ... EXECUTE AS OWNER ...  (re-emit existing body)

-- Step B: owner-scoped self-edit proc
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(
  P_ARTIFACT_ID VARCHAR, P_TITLE VARCHAR DEFAULT NULL, P_CONTENT VARIANT DEFAULT NULL, P_TAGS ARRAY DEFAULT NULL)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER AS
$$
DECLARE owner_check VARCHAR;
BEGIN
  SELECT OWNER INTO :owner_check FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = :P_ARTIFACT_ID;
  IF (:owner_check IS NULL) THEN RETURN 'ERROR: artifact not found'; END IF;
  IF (:owner_check <> CURRENT_USER()) THEN RETURN 'DENIED: not your artifact (owner=' || :owner_check || ')'; END IF;
  UPDATE GUPPIWHEEL.PUBLIC.ARTIFACTS
     SET TITLE = COALESCE(:P_TITLE, TITLE),
         CONTENT = COALESCE(:P_CONTENT, CONTENT),
         TAGS = COALESCE(:P_TAGS, TAGS),
         UPDATED_AT = CURRENT_TIMESTAMP()
   WHERE ID = :P_ARTIFACT_ID;
  -- deliberately CANNOT change STAGE, SUPERSEDED_BY, TYPE, OWNER
  RETURN 'OK: updated ' || :P_ARTIFACT_ID;
END;
$$;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.UPDATE_OWN_ARTIFACT(VARCHAR,VARCHAR,VARIANT,ARRAY) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- Step C: revoke the holes (only AFTER procs are OWNER)
REVOKE INSERT, UPDATE ON TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS FROM ROLE GUPPIWHEEL_CONTRIBUTOR;
REVOKE INSERT, UPDATE ON TABLE GUPPIWHEEL.PUBLIC.RULES FROM ROLE GUPPIWHEEL_CONTRIBUTOR;
REVOKE INSERT, UPDATE ON TABLE GUPPIWHEEL.PUBLIC.RULES_HISTORY FROM ROLE GUPPIWHEEL_CONTRIBUTOR;
-- KEEP: ECOSYSTEM.TAXONOMY direct DML; VIOLATIONS/ARTIFACT_LAUNCHES inserts (proc-written); stage R/W; proc USAGE
```

## Phase 4 — VERIFY

```sql
-- 1. No direct DML on ARTIFACTS/RULES for CONTRIBUTOR (re-run SHOW GRANTS, expect absent)
-- 2. Procs report OWNER (re-run Phase 1 exec_as check)
-- 3. As a contributor session: SUBMIT_INITIATIVE + PUBLISH_ARTIFACT succeed
-- 4. As a contributor session: UPDATE ARTIFACTS SET STAGE=... is DENIED
-- 5. UPDATE_OWN_ARTIFACT edits own row; refuses others; cannot change STAGE
-- 6. ECOSYSTEM.TAXONOMY direct DML still works
```

## Where this fits
- New installs: the seed (`engine/01_schema.sql` + `03_procs.sql`) ships born-locked; `guppiwheel-bootstrap` hands off here to verify.
- Existing/drifted installs: run this skill end-to-end.
- Ongoing: re-run Phase 1 periodically (a Seymour task could do this — flag drift like RULE-026 does for grounding surfaces).
- Doctrine: RULE-028 (candidate) codifies the invariant — no role below ADMIN holds direct DML on ARTIFACTS or RULES.
