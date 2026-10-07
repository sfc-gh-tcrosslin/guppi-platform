-- =============================================================================
-- guppi-platform -- Forge Config Seed 03: CONTROL home + FORGE_EXEC
-- =============================================================================
-- The Demo Forge is the ReAct CONFIG over the neutral loop kernel. This file
-- creates its DURABLE home and the single sandbox-guarded execution primitive
-- every build step runs through.
--
-- Homes:
--   DEMO_FORGE_SANDBOX.CONTROL  -- durable, FORGE_BUILDER-owned control plane
--                                  (driver code stage, FORGE_EXEC). NEVER reaped.
--   DEMO_FORGE_SANDBOX.RUN_<id> -- ephemeral per-run build schemas. Reaped by TTL.
--
-- Cage: FORGE_BUILDER can write NOWHERE except DEMO_FORGE_SANDBOX (RBAC is the
-- hard boundary). FORGE_EXEC adds defense-in-depth: it pins context to the run's
-- sandbox schema and refuses account-shape statements. Cross-DB READS are allowed
-- (a build often reads source data to build a view); WRITES outside the sandbox
-- simply cannot succeed as FORGE_BUILDER.
--
-- Owned by FORGE_BUILDER (created under its role) so all forge-owned objects live
-- in the one database it controls. Safe to re-run.
-- =============================================================================

USE ROLE FORGE_BUILDER;
USE WAREHOUSE SI_DEMO_WH;

-- Durable control-plane schema (never reaped -- reaper only drops RUN_* schemas).
CREATE SCHEMA IF NOT EXISTS DEMO_FORGE_SANDBOX.CONTROL
  COMMENT = 'Durable Demo Forge control plane (driver code + FORGE_EXEC). Not a run schema; the reaper never touches it.';

-- Stage for the forge ReAct driver entrypoint (forge_loop/main.py).
CREATE STAGE IF NOT EXISTS DEMO_FORGE_SANDBOX.CONTROL.FORGE_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Python entrypoint for the Demo Forge ReAct build-runner workflow.';

-- FORGE_EXEC -- the ONLY way a build step touches the database. Runs one
-- statement as FORGE_BUILDER, pinned to the run's sandbox schema, with a
-- defense-in-depth guard on top of the RBAC cage. Returns a structured result
-- so the driver can decide succeed / recover / fail WITHOUT any grader.
CREATE OR REPLACE PROCEDURE DEMO_FORGE_SANDBOX.CONTROL.FORGE_EXEC(
    P_RUN_ID VARCHAR, P_SANDBOX_SCHEMA VARCHAR, P_SQL VARCHAR)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
import re
_SANDBOX_DB = "DEMO_FORGE_SANDBOX"
# Account-shape / escape statements the forge must never issue, even though RBAC
# would already block most. Belt and suspenders + clear error messages.
_BANNED = re.compile(
    r"\b(CREATE|DROP|ALTER|UNDROP)\s+DATABASE\b"
    r"|\b(CREATE|DROP)\s+ROLE\b"
    r"|\bGRANT\b|\bREVOKE\b"
    r"|\bCREATE\s+(OR\s+REPLACE\s+)?(WORKFLOW|COMPUTE\s+POOL|WAREHOUSE|SECURITY\s+INTEGRATION|EXTERNAL\s+ACCESS\s+INTEGRATION)\b"
    r"|\bEXECUTE\s+TASK\b|\bEXECUTE\s+IMMEDIATE\b|\bCALL\b",
    re.IGNORECASE)
# Writes into the durable CONTROL schema are off-limits (only RUN_* schemas).
_CONTROL = re.compile(r"DEMO_FORGE_SANDBOX\.CONTROL\b", re.IGNORECASE)

# Write-ish statements must be FULLY QUALIFIED into the run sandbox schema
# (owner's-rights procs cannot issue USE, so there is no ambient schema to lean
# on -- qualification is what keeps every created object inside the run schema).
_WRITE = re.compile(r"^\s*(CREATE|INSERT|UPDATE|DELETE|MERGE|TRUNCATE|COPY)\b", re.IGNORECASE)

def run(session, run_id, sandbox_schema, sql):
    sql = (sql or "").strip().rstrip(";")
    if not sql:
        return {"ok": False, "error": "empty_sql", "run_id": run_id}
    ss = (sandbox_schema or "").upper()
    if not ss.startswith(_SANDBOX_DB + ".") or ".CONTROL" in ss:
        return {"ok": False, "error": "cage: sandbox_schema must be DEMO_FORGE_SANDBOX.RUN_*", "sandbox_schema": sandbox_schema}
    if _BANNED.search(sql):
        return {"ok": False, "error": "guard: account-shape / escape statement refused", "sql_head": sql[:120]}
    if _CONTROL.search(sql):
        return {"ok": False, "error": "guard: writes to the durable CONTROL schema are refused", "sql_head": sql[:120]}
    if _WRITE.match(sql) and ss not in sql.upper():
        # Reads may reference any DB (a build often reads source data); writes must
        # name the run schema so they land inside the cage.
        return {"ok": False, "error": "guard: a write must be fully-qualified into the run sandbox schema",
                "expect_schema": sandbox_schema, "sql_head": sql[:160]}
    try:
        rows = session.sql(sql).collect()
        sample = []
        for r in rows[:5]:
            try:
                sample.append({k: (str(v)[:200] if v is not None else None) for k, v in r.as_dict().items()})
            except Exception:
                sample.append(str(r)[:200])
        return {"ok": True, "rowcount": len(rows), "sample": sample}
    except Exception as e:
        return {"ok": False, "error": str(e)[:800]}
$$;

-- FORGE_BUILDER owns everything here (created under its role). The workflow +
-- kernel-consumer grants let it call the loop kernel; nothing else can drive it.
GRANT USAGE ON SCHEMA DEMO_FORGE_SANDBOX.CONTROL TO ROLE FORGE_BUILDER;
