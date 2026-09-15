-- SP_RECORD_SIGNOFF, ported from Praman's design (architecture.md RBAC section). OFFICER_SIGNOFF
-- has no direct table grants at all -- it can only write a sign-off row through this procedure,
-- which runs with the OWNER's rights (Snowflake's default for a stored procedure), so the
-- procedure's own INSERT privilege on AUDIT_LOG is what actually writes the row, not a grant to
-- the calling role. This is a stronger boundary than "INSERT-only on AUDIT_LOG" (that's
-- AUDIT_INSERT's grant) -- OFFICER_SIGNOFF can insert exactly the shape of row this procedure
-- constructs, nothing else.
--
-- A sign-off is its own new AUDIT_LOG row (a fresh RUN_ID), never a mutation of the run it signs
-- off on -- consistent with AUDIT_LOG being append-only by grant (no role ever gets UPDATE/DELETE).
--
-- SIGNOFF_BY is bound to CURRENT_USER() -- review finding: the original P_SIGNOFF_BY VARCHAR
-- parameter let any caller assert an arbitrary "who signed off" identity, so a session holding
-- OFFICER_SIGNOFF could record a fabricated human decision it never actually made a human make.
-- Binding to CURRENT_USER() makes the identity exactly whoever's Snowflake session is calling
-- this procedure -- un-spoofable by the caller. This doesn't by itself guarantee a human is
-- calling it (that's enforced by which users OFFICER_SIGNOFF is granted to, verified live in
-- scripts/verify_rbac.py), but it does guarantee the recorded identity is real, not asserted.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

-- Drop the old 3-arg signature explicitly -- CREATE OR REPLACE with a different parameter list
-- creates a new overload in Snowflake rather than replacing it, which would leave the spoofable
-- P_SIGNOFF_BY version callable alongside the fixed one.
DROP PROCEDURE IF EXISTS SP_RECORD_SIGNOFF(VARCHAR, VARCHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE SP_RECORD_SIGNOFF(
    P_SIGNOFF_FOR_RUN_ID VARCHAR,
    P_HUMAN_DECISION VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_now TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_signoff_by VARCHAR DEFAULT CURRENT_USER();
BEGIN
    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_id, :v_signoff_by, 'signoff', NULL, NULL,
        NULL, NULL, NULL, FALSE,
        :P_SIGNOFF_FOR_RUN_ID, :P_HUMAN_DECISION, :v_signoff_by, :v_now,
        :v_now, :v_signoff_by, :v_now, :v_signoff_by;
    RETURN :v_run_id;
END;
$$;

GRANT USAGE ON PROCEDURE SP_RECORD_SIGNOFF(VARCHAR, VARCHAR) TO ROLE OFFICER_SIGNOFF;
