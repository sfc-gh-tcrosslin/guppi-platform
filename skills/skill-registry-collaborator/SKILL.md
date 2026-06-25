---
name: skill-registry-collaborator
description: "Connect to a Skill Registry MCP server to discover, install, use, and collaborate on AI agent skills. This skill makes your CoCo a participant in a shared skill ecosystem. Use when: discover skills, browse registry, install skill, rate skill, fork skill, discuss skill, propose merge, collaborate, skill marketplace, what skills are available."
---

# Skill Registry Collaborator

Connect to a shared Skill Registry to discover, install, and collaborate on AI agent skills — without leaving your conversation.

## Architecture (v1.0)

No container. No MCP server. Just a shared table and SQL API.

-- READ: Query skills directly from the Snowflake data share (always on, zero compute)
-- WRITE: Submit feedback/forks via SQL API + scoped PAT (always on, serverless)
-- PARENT_SKILL_ID: Sub-skills get their own rows, linked to parent via this column
-- Versioning: Sub-skills version independently (fix one, bump one)
-- References: Embedded in SKILL_CONTENT variant so they flow through the share

## Connection

### Read Path (Shared Table)

The Skill Registry is shared to your account via Snowflake data sharing. Find the mounted database:

```sql
SHOW DATABASES LIKE '%SKILL_REGISTRY%';
```

Query skills directly:

```sql
SELECT SKILL_ID, DOMAIN, DESCRIPTION, VERSION
FROM <shared_db>.PUBLIC.SKILLS
ORDER BY DOMAIN;
```

### Write Path (SQL API)

Submit feedback, forks, and discussions via the SQL API with a scoped PAT.

-- URL: `https://sfsehol-si-industry-demos-healthcare-lmszks.snowflakecomputing.com/api/v2/statements`
-- Auth: `Bearer <PAT>`
-- Scope: `SKILL_REGISTRY_COLLABORATOR` role — SELECT/INSERT on SKILLS and CONTRIBUTIONS only
-- PAT expires: 2026-07-30

### Identity

For all actions, identify yourself:

```sql
SELECT CURRENT_USER() || '@' || CURRENT_ACCOUNT() AS IDENTITY;
```

## Available Actions (7 Verbs)

### 1. Discover

**Trigger:** "what skills are available?", "browse skills", "find a skill for..."

```sql
SELECT SKILL_ID, DOMAIN, DESCRIPTION, VERSION
FROM <shared_db>.PUBLIC.SKILLS
ORDER BY DOMAIN;
```

Filter by domain:
```sql
SELECT * FROM <shared_db>.PUBLIC.SKILLS WHERE DOMAIN = 'healthcare';
```

### 2. Get Skill Details

**Trigger:** "tell me more about [skill]", "show me the TARS auditor"

```sql
SELECT SKILL_ID, SKILL_CONTENT, AUDIT_HISTORY, METADATA
FROM <shared_db>.PUBLIC.SKILLS
WHERE SKILL_UUID = '{uuid}';
```

### 3. Install

**Trigger:** "install [skill]", "add that to my skills"

Read the SKILL_CONTENT VARIANT from the shared table, extract the structured content, and write a local SKILL.md:

```
~/.snowflake/cortex/skills/{skill_id}/SKILL.md
```

### 4. Submit Feedback

**Trigger:** "rate this skill", "give feedback on [skill]"

Via SQL API:
```sql
INSERT INTO SKILL_REGISTRY.PUBLIC.CONTRIBUTIONS
(CONTRIBUTION_ID, SKILL_UUID, CONTRIBUTION_TYPE, CONTRIBUTOR_USER, CONTRIBUTOR_ACCOUNT, CONTENT, RATING)
SELECT UUID_STRING(), '{skill_uuid}', 'feedback', '{user}', '{account}',
PARSE_JSON('{"comment": "{text}"}'), {rating};
```

Submit via HTTP POST to SQL API with Bearer PAT.

### 5. Fork

**Trigger:** "fork [skill]", "create a version of [skill]"

```sql
INSERT INTO SKILL_REGISTRY.PUBLIC.CONTRIBUTIONS
(CONTRIBUTION_ID, SKILL_UUID, CONTRIBUTION_TYPE, CONTRIBUTOR_USER, CONTRIBUTOR_ACCOUNT, CONTENT)
SELECT UUID_STRING(), '{skill_uuid}', 'fork', '{user}', '{account}',
PARSE_JSON('{"changes": "{description}", "new_skill_id": "{new_id}"}');
```

### 6. Discuss

**Trigger:** "comment on [skill]", "discuss [skill]"

```sql
INSERT INTO SKILL_REGISTRY.PUBLIC.CONTRIBUTIONS
(CONTRIBUTION_ID, SKILL_UUID, CONTRIBUTION_TYPE, CONTRIBUTOR_USER, CONTRIBUTOR_ACCOUNT, CONTENT)
SELECT UUID_STRING(), '{skill_uuid}', 'discussion', '{user}', '{account}',
PARSE_JSON('{"comment": "{text}"}');
```

### 7. Propose Merge

**Trigger:** "propose my changes back", "submit my fork for review"

```sql
INSERT INTO SKILL_REGISTRY.PUBLIC.CONTRIBUTIONS
(CONTRIBUTION_ID, SKILL_UUID, CONTRIBUTION_TYPE, CONTRIBUTOR_USER, CONTRIBUTOR_ACCOUNT, CONTENT)
SELECT UUID_STRING(), '{fork_uuid}', 'merge_proposal', '{user}', '{account}',
PARSE_JSON('{"description": "{what_changed}", "parent_uuid": "{parent}"}');
```

### 8. Publish / Sync

**Trigger:** "sync skills to registry", "publish my skills", "push skills to DB"

Run the idempotent sync script to push all local skill changes to the registry:

```bash
SNOWFLAKE_CONNECTION_NAME=YourConnection python3 ~/.snowflake/cortex/skills/skill-registry-collaborator/sync_skills.py
```

This script:
- Walks the full `~/.snowflake/cortex/skills/` tree
- Creates one row per SKILL.md (parents AND sub-skills)
- Links sub-skills to parents via PARENT_SKILL_ID
- Embeds reference docs into SKILL_CONTENT variant
- Uses MERGE — safe to run repeatedly (idempotent)

Consumer queries after sync:
```sql
-- Browse top-level skills only
SELECT SKILL_ID, DOMAIN, DESCRIPTION FROM SKILLS WHERE PARENT_SKILL_ID IS NULL;

-- Get a skill's full tree for install
SELECT * FROM SKILLS WHERE SKILL_ID = 'hcls-provider-cdata-clinical-nlp'
   OR PARENT_SKILL_ID = 'hcls-provider-cdata-clinical-nlp';

-- Search across all skills including sub-skills
SELECT SKILL_ID, DESCRIPTION FROM SKILLS WHERE DESCRIPTION ILIKE '%negation%';
```

## Feedback Lifecycle

Every contribution gets resolved:

-- PENDING: Just landed (default)
-- ACKNOWLEDGED: Provider saw it, no action needed
-- ACCEPTED: Feedback drove a change (new version published)
-- DEFERRED: Valid but not now
-- DECLINED: Disagree or won't fix

## UUID Rules

-- Same SKILL_UUID across versions of the same skill
-- New SKILL_UUID only on fork (FORK_OF points to parent)

## Feedback Hooks (Environment-Aware)

### CLI (Cortex Code CLI)
```
cortex ctx rule add skill-feedback
```
Rule: "After using any skill from the Skill Registry, prompt for feedback and submit via SQL API."

### Desktop (CoCo Desktop)
Add to `~/.snowflake/cortex/hooks.json`:
```json
{
  "hooks": {
    "user-prompt-submit": [{
      "matcher": "feedback|rate skill|skill worked|skill failed",
      "hooks": [{"type": "command", "command": "echo 'REMINDER: Submit feedback via SQL API'"}]
    }]
  }
}
```

## Narrative Context

### What This Is
A headless skill marketplace. No UI to browse — the agent IS the interface. The skill IS the client IS the collaboration invite.

### Agents
-- **CoCo**: Builder (Claude) — creates artifacts, Account A
-- **Beatrice**: Collaborator (Account B CLI) — discovers, uses, contributes
-- **TARS**: Auditor (Llama) — independent trust verification
-- **Rocky**: Future Ops Automation
-- **Human**: Final authority — three-vote pattern

### Key Principles
-- The user never leaves their conversation
-- Skills improve themselves via feedback loops
-- Corrections are the highest-signal contributions
-- No agent self-approves

## Provider Setup (Franchise Kit)

Any account can become a provider. Execute in order:

```sql
-- Step 1: Database
CREATE DATABASE SKILL_REGISTRY;
USE SKILL_REGISTRY.PUBLIC;

-- Step 2: Skills table
CREATE TABLE SKILLS (
    SKILL_ID STRING,
    VERSION STRING,
    SKILL_UUID STRING DEFAULT UUID_STRING(),
    SKILL_NAME STRING,
    AUTHOR STRING,
    DOMAIN STRING,
    DESCRIPTION STRING,
    SKILL_CONTENT VARIANT,
    HERO_HTML STRING,
    REFERENCES VARIANT DEFAULT PARSE_JSON('[]'),
    AUDIT_HISTORY VARIANT DEFAULT PARSE_JSON('[]'),
    METADATA VARIANT DEFAULT PARSE_JSON('{}'),
    DISCUSSION VARIANT DEFAULT PARSE_JSON('[]'),
    FORK_OF VARIANT,
    PARENT_SKILL_ID STRING,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    SUPERSEDED_BY STRING
);

-- Step 3: Contributions table
CREATE TABLE CONTRIBUTIONS (
    CONTRIBUTION_ID STRING DEFAULT UUID_STRING(),
    SKILL_UUID STRING,
    CONTRIBUTION_TYPE STRING,
    CONTRIBUTOR_USER STRING,
    CONTRIBUTOR_ACCOUNT STRING,
    CONTENT VARIANT,
    RATING NUMBER,
    TARS_SCORE FLOAT,
    STATUS STRING DEFAULT 'PENDING',
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Step 4: Notifications table
CREATE TABLE CONTRIBUTION_NOTIFICATIONS (
    NOTIFICATION_ID STRING DEFAULT UUID_STRING(),
    CONTRIBUTION_ID STRING,
    NOTIFIED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    ACKNOWLEDGED BOOLEAN DEFAULT FALSE
);

-- Step 5: Stage for hero HTML and reference docs
CREATE STAGE SKILL_ASSETS;

-- Step 6: Scoped role (SELECT/INSERT only)
CREATE ROLE SKILL_REGISTRY_COLLABORATOR;
GRANT USAGE ON DATABASE SKILL_REGISTRY TO ROLE SKILL_REGISTRY_COLLABORATOR;
GRANT USAGE ON SCHEMA SKILL_REGISTRY.PUBLIC TO ROLE SKILL_REGISTRY_COLLABORATOR;
GRANT SELECT ON TABLE SKILL_REGISTRY.PUBLIC.SKILLS TO ROLE SKILL_REGISTRY_COLLABORATOR;
GRANT SELECT, INSERT ON TABLE SKILL_REGISTRY.PUBLIC.CONTRIBUTIONS TO ROLE SKILL_REGISTRY_COLLABORATOR;

-- Step 7: Service user + PAT
CREATE USER SKILL_REGISTRY_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = SKILL_REGISTRY_COLLABORATOR;
GRANT ROLE SKILL_REGISTRY_COLLABORATOR TO USER SKILL_REGISTRY_SVC;
-- Then create a PAT for this user via Snowsight (Security > Programmatic Access Tokens)

-- Step 8: Stream + Alert for new contributions
CREATE STREAM CONTRIBUTIONS_STREAM ON TABLE CONTRIBUTIONS SHOW_INITIAL_ROWS = FALSE;

CREATE ALERT NEW_CONTRIBUTION_ALERT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
    IF (EXISTS (SELECT * FROM CONTRIBUTIONS_STREAM WHERE METADATA$ACTION = 'INSERT'))
    THEN
        INSERT INTO CONTRIBUTION_NOTIFICATIONS (CONTRIBUTION_ID)
        SELECT CONTRIBUTION_ID FROM CONTRIBUTIONS_STREAM WHERE METADATA$ACTION = 'INSERT';
ALTER ALERT NEW_CONTRIBUTION_ALERT RESUME;

-- Step 9: Share to consumer accounts
CREATE SHARE SKILL_REGISTRY_SHARE
    COMMENT = 'Skill Registry — AI agent skill catalog for discovery, install, and collaboration';
GRANT USAGE ON DATABASE SKILL_REGISTRY TO SHARE SKILL_REGISTRY_SHARE;
GRANT USAGE ON SCHEMA SKILL_REGISTRY.PUBLIC TO SHARE SKILL_REGISTRY_SHARE;
GRANT SELECT ON TABLE SKILL_REGISTRY.PUBLIC.SKILLS TO SHARE SKILL_REGISTRY_SHARE;
-- Add consumer accounts:
-- ALTER SHARE SKILL_REGISTRY_SHARE ADD ACCOUNTS = <ORG>.<ACCOUNT>;

-- Step 10: Load your first skill (yourself as collaborator)
-- INSERT INTO SKILLS (SKILL_ID, VERSION, SKILL_NAME, ...) VALUES (...);
```

After setup:
- Share the PAT securely with consumer accounts
- Consumer accepts share in Snowsight, queries SKILLS table for reads
- Consumer uses SQL API + PAT for writes (feedback, forks, discussion)
- Provider monitors CONTRIBUTION_NOTIFICATIONS for inbound activity

## Stopping Points

- Before installing: Confirm the skill name
- Before forking: Confirm new skill ID and changes
- Before proposing merge: Confirm what's being proposed

## What This Skill Does NOT Do

- It does not run skills — it discovers, installs, and collaborates on them
- It does not require a running container — reads are from shared table, writes are SQL API
- It does not bypass access controls — scoped role limits to SELECT/INSERT only
- It does not copy data locally — query the shared table directly
