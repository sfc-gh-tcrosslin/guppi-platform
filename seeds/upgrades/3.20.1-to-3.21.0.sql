-- =============================================================================
-- guppi-platform upgrade: 3.20.1 -> 3.21.0
-- "Governed repair doors + drift control"
--
-- Additive only (RULE-019). Safe to re-run. Nothing here rewrites existing artifacts.
--
-- WHY THIS EXISTS
-- ---------------
-- An account-level forensic audit found five conformance failures, and every one of
-- them traced to an UNGOVERNED WRITE rather than an engine bug:
--
--   * a duplicate NAR-39 and three unhashed rows, from raw `INSERT INTO ARTIFACTS`
--     that bypassed CREATE_ARTIFACT entirely (no collision check, no birth hash);
--   * an invalid stage value ('Narrated') written directly, bypassing ADVANCE_STAGE
--     so the stage rules engine never bound;
--   * an ID counter moved BACKWARD by a hardcoded `SET NEXT_SEQ = 40`, after which
--     the allocator re-issued IDs that were already live;
--   * customer-subject research tagged to the SHARED `guppi` product boundary.
--
-- The rows were repairable. The point of this upgrade is to remove the REASONS anyone
-- reaches for raw DML in the first place, and to make a recurrence visible.
--
-- WHAT YOU GET
-- ------------
--   1. RETAG_PRODUCT        — governed PRODUCT_ID change (was: raw UPDATE)
--   2. RESYNC_ID_SERIES     — forward-only counter repair (was: raw UPDATE, backward)
--   3. DIRECT_DML_TRIPWIRE_V— detects ungoverned substrate writes via QUERY_TAG
--   4. NARRATIVE_TEMPLATE_ADOPTION_V + an 8th conformance check
--
-- AFTER APPLYING, run the audit below. On an established install expect some rows in
-- DIRECT_DML_TRIPWIRE_V (historical) and a large LEGACY cohort in the adoption view —
-- both are grandfathered by design. Only `NEW (must fix)` gates conformance.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1 + 2. Governed repair doors.
-- Both live in seeds/engine/03_procs.sql as of 3.21.0; re-applying the engine is the
-- preferred path. They are reproduced here ONLY as a pointer for operators who apply
-- upgrades without re-running the engine seeds.
-- -----------------------------------------------------------------------------
--   ==> Apply seeds/engine/03_procs.sql (idempotent, CREATE OR REPLACE throughout)
--       to install RETAG_PRODUCT + RESYNC_ID_SERIES and their ADMIN grants.
--
-- Both are ADMIN-gated BY GRANT, not by an in-proc role check. That is deliberate:
-- inside EXECUTE AS OWNER, CURRENT_USER() is the caller but CURRENT_ROLE() is the
-- OWNER's role, so checking the role inside the body is unreliable. Grant-based
-- authorization is deterministic — if you can call it, you are authorized.

-- -----------------------------------------------------------------------------
-- 3 + 4. Tripwire + render-contract views, and the 8th conformance check.
-- -----------------------------------------------------------------------------
--   ==> Apply seeds/engine/01_schema.sql to install DIRECT_DML_TRIPWIRE_V,
--       NARRATIVE_TEMPLATE_ADOPTION_V, and the extended GUPPI_CONFORMANCE_V.
--
-- The tripwire is an owner-rights view over SNOWFLAKE.ACCOUNT_USAGE so contributors
-- can read it without their own ACCOUNT_USAGE grants. The view OWNER needs access to
-- SNOWFLAKE.ACCOUNT_USAGE (ACCOUNTADMIN has it by default). If your install creates
-- objects as a non-ACCOUNTADMIN role, grant it:
--
--   GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE <seed_owner_role>;

-- -----------------------------------------------------------------------------
-- 5. Post-upgrade audit. Run these; they are read-only.
-- -----------------------------------------------------------------------------

-- 5a. The gate. Every row must read PASS (now 8 checks, up from 7).
SELECT * FROM GUPPIWHEEL.PUBLIC.GUPPI_CONFORMANCE_V ORDER BY status, check_name;

-- 5b. Ungoverned writes. 'DIRECT-AGENT' = a human or agent typed DML at the substrate.
-- NOTE: ACCOUNT_USAGE latency is 45min-3h, so this is forensics, not enforcement.
-- Prevention is running as GUPPIWHEEL_CONTRIBUTOR (no direct DML) — see 5e.
SELECT severity, target_table, user_name, role_name, COUNT(*) AS n,
       MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
FROM GUPPIWHEEL.PUBLIC.DIRECT_DML_TRIPWIRE_V
GROUP BY 1,2,3,4 ORDER BY n DESC;

-- 5c. Render contract. Only 'NEW (must fix)' gates conformance; LEGACY/MIGRATED are grandfathered.
SELECT cohort, COUNT(*) AS n
FROM GUPPIWHEEL.PUBLIC.NARRATIVE_TEMPLATE_ADOPTION_V
GROUP BY cohort ORDER BY n DESC;

-- 5d. Latent counter drift. Any row where NEXT_SEQ has fallen at or below the max ID
-- actually present WILL re-issue a live ID on the next allocation. Repair each with
--   CALL GUPPIWHEEL.PUBLIC.RESYNC_ID_SERIES('<ENTITY>', '<reason>');
SELECT c.ENTITY, c.ID_PREFIX, c.NEXT_SEQ,
       COALESCE(MAX(TO_NUMBER(SUBSTR(a.ID, LENGTH(c.ID_PREFIX)+1))), 0) AS actual_max
FROM GUPPIWHEEL.PUBLIC.ID_CONVENTIONS c
LEFT JOIN GUPPIWHEEL.PUBLIC.ARTIFACTS a
       ON a.ID LIKE c.ID_PREFIX || '%'
      AND REGEXP_LIKE(SUBSTR(a.ID, LENGTH(c.ID_PREFIX)+1), '[0-9]+')
WHERE c.ID_PREFIX IS NOT NULL
GROUP BY c.ENTITY, c.ID_PREFIX, c.NEXT_SEQ
HAVING c.NEXT_SEQ <= COALESCE(MAX(TO_NUMBER(SUBSTR(a.ID, LENGTH(c.ID_PREFIX)+1))), 0)
ORDER BY c.ENTITY;

-- 5e. The actual prevention: is anyone authoring the wheel with standing DML?
-- The detective controls above only tell you after the fact. Per RULE-034 the IDE
-- agent should run as GUPPIWHEEL_CONTRIBUTOR, which holds NO direct DML on ARTIFACTS.
SHOW GRANTS ON TABLE GUPPIWHEEL.PUBLIC.ARTIFACTS;
