# GUPPI Admin — Schema Migrations

## When to Use

Invoke when you need to:
- Add a new table to any GUPPI schema
- Modify an existing table (add column, change type)
- Create a new schema
- Backfill data into a new structure

## Migration Pattern

1. Write the DDL
2. Execute in Snowflake
3. Verify with DESCRIBE TABLE
4. Update the SKILL.md schema reference
5. Log the change (no formal migration table yet — tracked via git history)

## Existing Schemas

| Schema | Purpose | Owner |
|--------|---------|-------|
| PUBLIC | SDLC — stories, epics, products | All products |
| OPS | Incidents, post-mortems | Operations |
| AUDITS | TARS trust scores | TARS skill |
| QA | Test results, coverage | QA Automation |

## Adding a Schema

```sql
CREATE SCHEMA IF NOT EXISTS GUPPI.<NEW_SCHEMA>;
```

Then update the SKILL.md Architecture section and add a sub-directory with README.md.
