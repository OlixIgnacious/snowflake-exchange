-- SP_LOG_AUTOMATION_RUN -- closes review finding "NOTES.md (the audit trail) is itself
-- unauditable": NOTES.md is gitignored, plaintext, and hand-maintained by the same non-interactive
-- agent it's supposed to be auditing -- none of AUDIT_LOG's own append-only/RBAC guarantees
-- (no role ever gets UPDATE/DELETE) applied to it. scripts/run_sql.py now calls this procedure
-- after every invocation, giving the automation run log the same real guarantees as everything
-- else in VIGIL.CORE. NOTES.md stays as a human-readable narrative companion (rationale that
-- doesn't belong in a DB row) -- it's no longer the *only* record of what was executed.
--
-- EXECUTE AS OWNER, same pattern as SP_LOG_SURVEILLANCE_RUN/SP_RECORD_SIGNOFF -- AUDIT_INSERT has
-- no direct grant beyond INSERT on AUDIT_LOG itself, and this procedure's own privileges do the
-- write regardless of which role (VIGIL_AUTOMATION or ACCOUNTADMIN, via scripts/run_sql.py
-- --admin) is actually calling it.
--
-- P_CALLER_ROLE is passed in explicitly, not read via CURRENT_ROLE() inside this procedure --
-- a real Snowflake gotcha hit while building this: CURRENT_ROLE() inside an EXECUTE AS OWNER
-- procedure returns the OWNER's role (ACCOUNTADMIN, since that's who created it), not the
-- session role that actually issued the CALL. scripts/run_sql.py captures CURRENT_ROLE() on the
-- caller's side, before calling in, so a --admin run is genuinely distinguishable from routine
-- VIGIL_AUTOMATION work in the log.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

DROP PROCEDURE IF EXISTS SP_LOG_AUTOMATION_RUN(VARCHAR, VARCHAR);

CREATE OR REPLACE PROCEDURE SP_LOG_AUTOMATION_RUN(
    P_SCRIPT_PATHS VARCHAR,
    P_RESULT_SUMMARY VARCHAR,
    P_CALLER_ROLE VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_now    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_user   VARCHAR DEFAULT CURRENT_USER();
BEGIN
    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_id, :v_user, 'automation_run', :P_SCRIPT_PATHS, NULL,
        NULL, NULL,
        OBJECT_CONSTRUCT(
            'connected_as_role', :P_CALLER_ROLE,
            'script_paths', :P_SCRIPT_PATHS,
            'result', :P_RESULT_SUMMARY
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    RETURN :v_run_id;
END;
$$;

GRANT USAGE ON PROCEDURE SP_LOG_AUTOMATION_RUN(VARCHAR, VARCHAR, VARCHAR) TO ROLE AUDIT_INSERT;
