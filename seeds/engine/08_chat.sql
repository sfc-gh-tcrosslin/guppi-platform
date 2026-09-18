-- =============================================================================
-- guppi-platform — Engine Seed 08: Agent Chat Store (durable conversation memory)
-- TIER 0/1: Server-side, multi-user conversation history for agent chat surfaces
--   (the See-the-Loop app's Bob dock today; persona-agnostic for a future
--   Riker/Will via the AGENT column). Snowflake Cortex native threads are NOT
--   usable on the DATA_AGENT_RUN *SQL* surface (sync returns no thread_id;
--   background requires one and won't auto-create; no SQL thread-create fn), so
--   we hold the transcript ourselves and REPLAY the last-N turns into the agent's
--   messages[] array (proven: a replayed array recalls prior context). Native
--   threads / REST agent:run remain a future option (needs a PAT).
--
-- SHIPS EMPTY. This seed creates SUBSTRATE only — a consumer's messages are
--   runtime data and are NEVER seeded. Do NOT add INSERTs of messages here.
--
-- GOVERNED WRITES (RULE-028): all writes go through EXECUTE AS OWNER procedures,
--   so invoker roles need only USAGE on the procs — never direct table DML.
--   Per-user isolation is enforced by GET_CHAT_HISTORY filtering on the passed
--   USER_ID (the app derives it from the trusted SPCS ingress header
--   sf-context-current-user; procs run as OWNER so CURRENT_USER() is not the
--   human — the human id MUST be passed in).
--
-- Safe to re-run: CREATE ... IF NOT EXISTS for the table; CREATE OR REPLACE for
--   the procs. Existing rows are never touched.
-- =============================================================================

-- --- Substrate: the message log -------------------------------------------------
CREATE TABLE IF NOT EXISTS GUPPIWHEEL.PUBLIC.AGENT_CHAT_MESSAGES (
    MESSAGE_ID     VARCHAR DEFAULT UUID_STRING(),
    SEQ            NUMBER AUTOINCREMENT START 1 INCREMENT 1,  -- monotonic insertion order (thread ordering)
    AGENT          VARCHAR NOT NULL,        -- persona, e.g. 'BOB'
    USER_ID        VARCHAR NOT NULL,        -- the human (SPCS sf-context-current-user), NOT the owner role
    INITIATIVE_ID  VARCHAR NOT NULL,        -- thread scope: one thread per (AGENT, USER_ID, INITIATIVE_ID)
    ROLE           VARCHAR NOT NULL,        -- 'user' | 'assistant'
    TEXT           VARCHAR,                 -- rendered message text
    BLOCKS         VARIANT,                 -- assistant tool trail (thinking/tool_use/tool_result) for re-render
    META           VARIANT,                 -- {queryId, elapsedMs, error, act, ...} — non-rendering breadcrumbs
    CREATED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- --- SAVE_CHAT_MESSAGE — append one turn ----------------------------------------
-- JSON surfaces (BLOCKS/META) are VARCHAR params parsed inside (PLAT convention:
--   scalar JSON surface, not VARIANT bind — keeps the client driver simple).
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SAVE_CHAT_MESSAGE(
    P_AGENT VARCHAR, P_USER_ID VARCHAR, P_INITIATIVE_ID VARCHAR,
    P_ROLE VARCHAR, P_TEXT VARCHAR, P_BLOCKS VARCHAR DEFAULT NULL, P_META VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER   -- RULE-028: procedure-mediated write; invokers need no direct AGENT_CHAT_MESSAGES DML
AS
BEGIN
    IF (:P_AGENT IS NULL OR :P_USER_ID IS NULL OR :P_INITIATIVE_ID IS NULL OR :P_ROLE IS NULL) THEN
        RETURN 'ERROR: agent, user_id, initiative_id and role are required';
    END IF;
    INSERT INTO GUPPIWHEEL.PUBLIC.AGENT_CHAT_MESSAGES (AGENT, USER_ID, INITIATIVE_ID, ROLE, TEXT, BLOCKS, META)
    SELECT :P_AGENT, :P_USER_ID, :P_INITIATIVE_ID, :P_ROLE, :P_TEXT,
           TRY_PARSE_JSON(:P_BLOCKS), TRY_PARSE_JSON(:P_META);
    RETURN 'OK';
END;

-- --- GET_CHAT_HISTORY — newest-N turns, chronological, as a JSON array -----------
-- Returns a VARIANT array of {role, text, blocks, meta, created_at}. The caller
-- filters are enforced here (per-user isolation). Newest P_LIMIT rows, re-ordered
-- ascending so the array reads oldest->newest (ready for the agent messages[]).
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.GET_CHAT_HISTORY(
    P_AGENT VARCHAR, P_USER_ID VARCHAR, P_INITIATIVE_ID VARCHAR, P_LIMIT NUMBER DEFAULT 20
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
DECLARE
    arr VARIANT;
BEGIN
    -- SELECT ... INTO (not LET := (SELECT ...)): the scripting parser rejects an
    -- ARRAY_AGG ... WITHIN GROUP scalar subquery in a LET assignment. Newest
    -- P_LIMIT rows re-ordered ascending so the array reads oldest -> newest.
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'role', ROLE, 'text', TEXT, 'blocks', BLOCKS, 'meta', META,
               'created_at', TO_VARCHAR(CREATED_AT)))
           WITHIN GROUP (ORDER BY SEQ)
      INTO :arr
      FROM (
          SELECT SEQ, ROLE, TEXT, BLOCKS, META, CREATED_AT
          FROM GUPPIWHEEL.PUBLIC.AGENT_CHAT_MESSAGES
          WHERE AGENT = :P_AGENT
            AND USER_ID = :P_USER_ID
            AND INITIATIVE_ID = :P_INITIATIVE_ID
          ORDER BY SEQ DESC
          LIMIT :P_LIMIT
      );
    RETURN COALESCE(:arr, TO_VARIANT(ARRAY_CONSTRUCT()));
END;

-- --- CLEAR_CHAT_THREAD — wipe one thread (for a "New thread" control) ------------
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.CLEAR_CHAT_THREAD(
    P_AGENT VARCHAR, P_USER_ID VARCHAR, P_INITIATIVE_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
BEGIN
    DELETE FROM GUPPIWHEEL.PUBLIC.AGENT_CHAT_MESSAGES
     WHERE AGENT = :P_AGENT AND USER_ID = :P_USER_ID AND INITIATIVE_ID = :P_INITIATIVE_ID;
    RETURN 'OK';
END;

-- --- Grants (mirror GUPPIWHEEL role tiers; VIEWER < CONTRIBUTOR < ADMIN) ---------
-- Reads (GET) to VIEWER; writes (SAVE/CLEAR) to CONTRIBUTOR. ADMIN inherits
-- CONTRIBUTOR, CONTRIBUTOR inherits VIEWER (see 01_schema.sql), so these cover all tiers.
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.GET_CHAT_HISTORY(VARCHAR,VARCHAR,VARCHAR,NUMBER) TO ROLE GUPPIWHEEL_VIEWER;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.SAVE_CHAT_MESSAGE(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;
GRANT USAGE ON PROCEDURE GUPPIWHEEL.PUBLIC.CLEAR_CHAT_THREAD(VARCHAR,VARCHAR,VARCHAR) TO ROLE GUPPIWHEEL_CONTRIBUTOR;

-- NOTE (per-account, NOT hard-seeded): an agent-app invoker role (e.g. the
-- See-the-Loop app's RSI_APP_READER) gets USAGE on these procs automatically via
-- the account's `GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GUPPIWHEEL.PUBLIC TO
-- ROLE <app_role>` grant (added 2026-09-18). No table DML is granted to the app —
-- all access is proc-mediated. If a new account lacks that future grant, grant
-- USAGE on the three procs above to the app's invoker role explicitly.
