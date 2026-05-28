---
name: coco-enterprise-pipeline
description: "Dev/QA/Prod pipeline agent with RBAC-enforced separation of duties for enterprise CoCo deployments. Engineers cannot self-promote to production. Use when: enterprise governance, CI/CD pipeline, dev qa prod, promotion gates, separation of duties, deployment pipeline, production access control, SOX compliance, HIPAA deployment, cowboy deploy prevention, gated promotion."
---

# CoCo Enterprise Pipeline: Dev/QA/Prod with Separation of Duties

An AI-native CI/CD governance pattern for enterprises deploying with Cortex Code. Engineers build fast in dev. Production requires human approval from a separate role. No single person can both write code and promote it.

## The Problem

CoCo gives engineers god-like power — write SQL, deploy SPCS services, alter tables, push to production. In a startup, that's velocity. In an enterprise with SOX/HIPAA/regulatory requirements, that's a compliance violation.

**An engineer who can both write code AND promote to production breaks separation of duties.**

## Architecture

### Role Hierarchy

```
ACCOUNTADMIN
├── SECURITYADMIN
├── SYSADMIN
│   ├── PROD_DEPLOYER (service role — no human uses directly)
│   ├── QA_APPROVER (separate human — cannot write code)
│   ├── ENGINEER_DEV (builds in dev, reads QA/prod)
│   └── TARS_AUDITOR (read-only, scores artifacts)
```

Key constraint: **No single user holds ENGINEER_DEV + QA_APPROVER + PROD_DEPLOYER.**

### Environment Isolation

| Environment | Database Pattern | Who Writes | Who Reads |
|---|---|---|---|
| Dev | `DEV_*` databases | ENGINEER_DEV | Everyone |
| QA | `QA_*` databases | Promotion task only | ENGINEER_DEV (read), QA_APPROVER (read+approve) |
| Prod | `PROD_*` databases | PROD_DEPLOYER (task) | Everyone (via views) |

### CoCo Connection Binding

The connection name determines the role. CoCo inherits the role of its connection — this is the enforcement boundary.

```toml
# ~/.snowflake/connections.toml

[MyProject_Dev]
account = "org-account"
role = "ENGINEER_DEV"
warehouse = "DEV_WH"
database = "DEV_HEALTHCARE"

[MyProject_QA]
account = "org-account"
role = "QA_REVIEWER"
warehouse = "QA_WH"
database = "QA_HEALTHCARE"

[MyProject_Prod]
account = "org-account"
role = "PROD_READER"
warehouse = "ANALYTICS_WH"
database = "PROD_HEALTHCARE"
```

CoCo running on `MyProject_Dev` literally cannot execute DDL against production — Snowflake RBAC denies it at the engine level.

## Promotion Flow

```
Engineer (CoCo) → Dev → [TARS Audit] → QA → [Human Approval] → Prod
                   │         │                      │
                   │    Must pass              QA_APPROVER role
                   │    (automated)            (different person)
                   │
              ENGINEER_DEV role
              (full write access)
```

### Step 1: Engineer Builds in Dev

CoCo creates, tests, iterates — full freedom in DEV_* databases.

```sql
-- CoCo executes as ENGINEER_DEV
CREATE OR REPLACE TABLE DEV_HEALTHCARE.ANALYTICS.NEW_MODEL AS ...;
CREATE OR REPLACE VIEW DEV_HEALTHCARE.ANALYTICS.V_DASHBOARD AS ...;
```

### Step 2: Request Promotion

Engineer creates a promotion request (GUPPI story or dedicated table):

```sql
INSERT INTO GUPPI.PLATFORM.PROMOTION_REQUESTS
(REQUEST_ID, STORY_ID, SOURCE_ENV, TARGET_ENV, ARTIFACT_TYPE, ARTIFACT_NAME, REQUESTED_BY, REQUESTED_AT)
VALUES (UUID_STRING(), 'F6-042', 'DEV', 'QA', 'TABLE', 'DEV_HEALTHCARE.ANALYTICS.NEW_MODEL', CURRENT_USER(), CURRENT_TIMESTAMP());
```

### Step 3: TARS Audit (Automated Gate)

A Snowflake Task monitors the promotion stream. On new request:

1. TARS audits the artifact (schema validation, test coverage, security scan)
2. Trust score recorded in GUPPI.PLATFORM.AUDIT_RUNS
3. If score < threshold → request auto-rejected with feedback
4. If score >= threshold → request advances to QA_REVIEW status

```sql
CREATE OR REPLACE TASK TARS_PROMOTION_GATE
  WAREHOUSE = QA_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('PROMOTION_REQUESTS_STREAM')
AS
CALL RUN_TARS_AUDIT_ON_PENDING_REQUESTS();
```

### Step 4: Human Approval (QA_APPROVER)

A different person — with QA_APPROVER role — reviews and approves:

```sql
-- Only QA_APPROVER role can execute this
UPDATE GUPPI.PLATFORM.PROMOTION_REQUESTS
SET STATUS = 'APPROVED_FOR_PROD', APPROVED_BY = CURRENT_USER(), APPROVED_AT = CURRENT_TIMESTAMP()
WHERE REQUEST_ID = 'xxx' AND STATUS = 'QA_PASSED';
```

### Step 5: Production Deployment (Service Role)

A Snowflake Task running as PROD_DEPLOYER executes the actual promotion:

```sql
CREATE OR REPLACE TASK PROMOTE_TO_PROD
  WAREHOUSE = PROD_DEPLOY_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('APPROVED_PROMOTIONS_STREAM')
AS
CALL EXECUTE_PRODUCTION_PROMOTION();
-- Clones from QA, applies to prod, logs result
```

No human ever runs DDL against production directly.

## Enforcement Mechanisms

### 1. Snowflake RBAC (Primary)

The database engine itself denies unauthorized access. This is not application-level — it's infrastructure-level.

```sql
-- ENGINEER_DEV can write to dev
GRANT ALL ON DATABASE DEV_HEALTHCARE TO ROLE ENGINEER_DEV;

-- ENGINEER_DEV can READ qa and prod (for debugging, not writing)
GRANT USAGE ON DATABASE QA_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT SELECT ON ALL TABLES IN DATABASE QA_HEALTHCARE TO ROLE ENGINEER_DEV;

-- ENGINEER_DEV CANNOT write to prod
-- (no grant = no access, this is Snowflake's default-deny model)
```

### 2. Managed Access Schemas

Production schemas use `WITH MANAGED ACCESS` — even object owners can't grant privileges. Only the schema owner (PROD_DEPLOYER service role) controls access.

```sql
CREATE SCHEMA PROD_HEALTHCARE.ANALYTICS WITH MANAGED ACCESS;
```

### 3. CoCo Hooks (Defense in Depth)

Pre-execution hooks catch accidental cross-environment commands:

```json
{
  "hooks": {
    "pre-sql-execute": [{
      "matcher": "PROD_|production",
      "action": "warn",
      "message": "This SQL references production objects. Use the promotion workflow."
    }]
  }
}
```

### 4. GUPPI Audit Trail

Every promotion is a story with:
- WHO requested (CURRENT_USER from ENGINEER_DEV session)
- WHO approved (CURRENT_USER from QA_APPROVER session)
- WHAT was promoted (artifact name, source/target)
- WHEN (timestamps at every stage)
- WHY (linked story with business context)

### 5. Snowflake Access History

`SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` captures every object access. Combined with GUPPI, provides full lineage: code change → story → audit → approval → deployment.

## Setup SQL (Franchise Kit)

```sql
-- Roles
CREATE ROLE ENGINEER_DEV;
CREATE ROLE QA_APPROVER;
CREATE ROLE PROD_DEPLOYER;
CREATE ROLE TARS_AUDITOR;

-- Hierarchy
GRANT ROLE ENGINEER_DEV TO ROLE SYSADMIN;
GRANT ROLE QA_APPROVER TO ROLE SYSADMIN;
GRANT ROLE PROD_DEPLOYER TO ROLE SYSADMIN;
GRANT ROLE TARS_AUDITOR TO ROLE SYSADMIN;

-- Databases
CREATE DATABASE DEV_HEALTHCARE;
CREATE DATABASE QA_HEALTHCARE;
CREATE DATABASE PROD_HEALTHCARE;

-- Dev: full access for engineers
GRANT ALL ON DATABASE DEV_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT ALL ON ALL SCHEMAS IN DATABASE DEV_HEALTHCARE TO ROLE ENGINEER_DEV;

-- QA: read for engineers, write only via promotion task
GRANT USAGE ON DATABASE QA_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT SELECT ON FUTURE TABLES IN DATABASE QA_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT ALL ON DATABASE QA_HEALTHCARE TO ROLE PROD_DEPLOYER;

-- Prod: read for everyone, write only via PROD_DEPLOYER
GRANT USAGE ON DATABASE PROD_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT USAGE ON DATABASE PROD_HEALTHCARE TO ROLE QA_APPROVER;
GRANT SELECT ON FUTURE TABLES IN DATABASE PROD_HEALTHCARE TO ROLE ENGINEER_DEV;
GRANT SELECT ON FUTURE TABLES IN DATABASE PROD_HEALTHCARE TO ROLE QA_APPROVER;
GRANT ALL ON DATABASE PROD_HEALTHCARE TO ROLE PROD_DEPLOYER;

-- Managed access on prod schemas
CREATE SCHEMA PROD_HEALTHCARE.ANALYTICS WITH MANAGED ACCESS;
CREATE SCHEMA PROD_HEALTHCARE.MODELS WITH MANAGED ACCESS;

-- TARS: read everything, write nothing
GRANT USAGE ON DATABASE DEV_HEALTHCARE TO ROLE TARS_AUDITOR;
GRANT USAGE ON DATABASE QA_HEALTHCARE TO ROLE TARS_AUDITOR;
GRANT USAGE ON DATABASE PROD_HEALTHCARE TO ROLE TARS_AUDITOR;
GRANT SELECT ON ALL TABLES IN DATABASE DEV_HEALTHCARE TO ROLE TARS_AUDITOR;
GRANT SELECT ON ALL TABLES IN DATABASE QA_HEALTHCARE TO ROLE TARS_AUDITOR;
GRANT SELECT ON ALL TABLES IN DATABASE PROD_HEALTHCARE TO ROLE TARS_AUDITOR;

-- Assign to users (CRITICAL: no overlap between engineer and approver)
GRANT ROLE ENGINEER_DEV TO USER engineer_alice;
GRANT ROLE ENGINEER_DEV TO USER engineer_bob;
GRANT ROLE QA_APPROVER TO USER qa_charlie;  -- Charlie CANNOT also have ENGINEER_DEV
GRANT ROLE PROD_DEPLOYER TO USER svc_deployer;  -- Service account only
```

## SPCS-Specific Patterns

For container deployments (like FIMR dashboard):

| Environment | Compute Pool | Image Tag | Service Name |
|---|---|---|---|
| Dev | DEV_COMPUTE_POOL | `:dev` | `DEV_DB.SCHEMA.MY_SERVICE` |
| QA | QA_COMPUTE_POOL | `:qa` | `QA_DB.SCHEMA.MY_SERVICE` |
| Prod | PROD_COMPUTE_POOL | `:latest` | `PROD_DB.SCHEMA.MY_SERVICE` |

Promotion = retag `:qa` → `:latest`, ALTER SERVICE in prod (executed by PROD_DEPLOYER task, not engineer).

## Anti-Patterns to Prevent

| Anti-Pattern | Why It's Bad | How This Prevents It |
|---|---|---|
| Engineer pushes `:latest` directly to prod | No review, no audit | RBAC: engineer role can't ALTER prod services |
| Same person approves their own code | No separation of duties | Role constraint: ENGINEER_DEV ≠ QA_APPROVER |
| Hotfix bypasses QA | Technical debt, risk | Emergency path exists but requires SECURITYADMIN override + incident logged |
| Service account credentials shared | Accountability lost | PROD_DEPLOYER is a service user with no interactive login |
| CoCo runs as ACCOUNTADMIN | Unlimited blast radius | Connection binding: CoCo uses environment-specific roles |

## Emergency Path

For genuine emergencies (production down, data corruption):

1. SECURITYADMIN temporarily grants ENGINEER_DEV → PROD_DEPLOYER
2. Fix is applied
3. Grant is immediately revoked
4. Incident logged in GUPPI.OPS.INCIDENTS
5. Post-mortem documents why normal path wasn't viable
6. Preventive story created to avoid recurrence

This path exists but is auditable and exceptional.

## Integration with PLAT-010 (QA Automation)

PLAT-010 defines WHAT gets tested (TARS-driven verification).
PLAT-011 defines WHEN testing gates promotion (this pipeline).

Together:
- TARS scores every artifact before it can leave dev
- Score threshold is configurable per product/risk-level
- Results feed into GUPPI stories for traceability
- Failed audits block promotion with actionable feedback

## Maturity Levels

| Level | Description | CoCo Setup |
|---|---|---|
| 1 - Basic | Separate dev/prod databases, manual promotion | 2 connections, copy scripts |
| 2 - Gated | TARS audit required, human approval logged | Add QA_APPROVER role, GUPPI integration |
| 3 - Automated | Tasks handle promotion, full audit trail | Streams + Tasks, zero manual DDL in prod |
| 4 - Enterprise | SOX-compliant, MFA on approvals, time-bound access | Add MFA policy, session policies, access review |

## Stopping Points

- Before creating roles: Confirm org structure and who maps to which role
- Before managed access: Understand that object owners lose grant ability
- Before emergency path: Document who holds SECURITYADMIN
