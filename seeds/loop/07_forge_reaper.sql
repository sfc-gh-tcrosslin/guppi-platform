-- =============================================================================
-- guppi-platform -- Forge Config Seed 07: sandbox reaper (TTL compensation)
-- =============================================================================
-- Dropping a per-run sandbox schema IS the forge's compensation step: it undoes
-- any partial build and reclaims storage. FORGE_REAP drops RUN_* schemas older
-- than the TTL and marks their kernel runs 'reaped'. FORGE_REAP_TASK runs it
-- daily. The durable CONTROL schema is never touched.
--
-- Owned by FORGE_BUILDER (owns the sandbox). Safe to re-run.
-- =============================================================================

-- EXECUTE TASK so FORGE_BUILDER can run its own scheduled reaper.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE FORGE_BUILDER;

USE ROLE FORGE_BUILDER;
USE WAREHOUSE SI_DEMO_WH;

CREATE OR REPLACE PROCEDURE DEMO_FORGE_SANDBOX.CONTROL.FORGE_REAP(P_TTL_DAYS NUMBER DEFAULT 7)
RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION='3.11'
PACKAGES=('snowflake-snowpark-python') HANDLER='run' EXECUTE AS OWNER AS
$$
def run(session, ttl_days):
    ttl = int(ttl_days or 7)
    rows = session.sql(
        "SELECT SCHEMA_NAME FROM DEMO_FORGE_SANDBOX.INFORMATION_SCHEMA.SCHEMATA "
        "WHERE SCHEMA_NAME LIKE 'RUN\\_%' ESCAPE '\\\\' "
        "AND CREATED < DATEADD(day, ?, CURRENT_TIMESTAMP())", params=[-ttl]).collect()
    dropped, marked = [], []
    for r in rows:
        sn = r[0]
        try:
            session.sql('DROP SCHEMA IF EXISTS DEMO_FORGE_SANDBOX."%s"' % sn).collect()
            dropped.append(sn)
            rid = sn[4:].replace("_", "-", 1)   # RUN_FORGE_abc -> FORGE-abc
            try:
                session.sql("CALL GUPPI_LOOP_ENGINE.CORE.LOOP_SET_STATUS(?, 'reaped', NULL)", params=[rid]).collect()
                marked.append(rid)
            except Exception:
                pass
        except Exception:
            pass
    return {"ttl_days": ttl, "dropped": dropped, "runs_marked_reaped": marked}
$$;

CREATE OR REPLACE TASK DEMO_FORGE_SANDBOX.CONTROL.FORGE_REAP_TASK
  WAREHOUSE = SI_DEMO_WH
  SCHEDULE = 'USING CRON 0 3 * * * America/Los_Angeles'
  COMMENT = 'Daily Demo Forge sandbox reaper: drops RUN_* schemas past TTL (compensation) and marks runs reaped.'
  AS CALL DEMO_FORGE_SANDBOX.CONTROL.FORGE_REAP(7);

ALTER TASK DEMO_FORGE_SANDBOX.CONTROL.FORGE_REAP_TASK RESUME;
