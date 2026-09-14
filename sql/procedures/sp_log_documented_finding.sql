-- SP_LOG_DOCUMENTED_FINDING: writes one AUDIT_LOG row (STAGE = 'documented_finding') per real
-- assurance verdict, called by scripts/generate_documented_findings.py after it computes that
-- verdict via the already-tested skills/assure_report.py + ingest/report_adaptor.py logic.
--
-- Deliberately NOT reimplemented as a SQL view/procedure that recomputes the verdict itself --
-- REPORT_TEMPLATES.SOURCE_MAPPING is free text pointing at an arbitrary source column
-- (sql/detectors/05_reporting_timeliness.sql's header comment documents this same limitation:
-- "a live view can't generically re-derive... without dynamic SQL; that computation belongs to
-- the report-generation adaptor"). This procedure is intentionally a thin logging sink, matching
-- SP_RECORD_SIGNOFF/SP_LOG_SURVEILLANCE_RUN's EXECUTE AS OWNER pattern -- the caller (AUDIT_INSERT)
-- has no direct INSERT on AUDIT_LOG; the procedure's owner privileges write the row. Array/object
-- fields are passed as JSON text and parsed here, not as native ARRAY bind params -- consistent
-- with this project's own documented finding (generator/load_to_snowflake.py) that passing a
-- function-call expression through the Python connector's bind interface is fragile; a plain
-- VARCHAR bind + PARSE_JSON inside the procedure body sidesteps that entirely.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_LOG_DOCUMENTED_FINDING(
    P_REPORT_ID VARCHAR,
    P_READY_TO_SUBMIT BOOLEAN,
    P_FIELDS_COMPLETE BOOLEAN,
    P_UNRESOLVED_REQUIRED_FIELDS_JSON VARCHAR,
    P_GAP_FIELDS_JSON VARCHAR,
    P_REASONS_JSON VARCHAR
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
        :v_run_id, :v_user, 'documented_finding', :P_REPORT_ID, NULL,
        NULL, NULL,
        OBJECT_CONSTRUCT(
            'report_id', :P_REPORT_ID,
            'ready_to_submit', :P_READY_TO_SUBMIT,
            'fields_complete', :P_FIELDS_COMPLETE,
            'unresolved_required_fields', PARSE_JSON(:P_UNRESOLVED_REQUIRED_FIELDS_JSON),
            'gap_fields', PARSE_JSON(:P_GAP_FIELDS_JSON),
            'reasons', PARSE_JSON(:P_REASONS_JSON)
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;
    RETURN :v_run_id;
END;
$$;

GRANT USAGE ON PROCEDURE SP_LOG_DOCUMENTED_FINDING(VARCHAR, BOOLEAN, BOOLEAN, VARCHAR, VARCHAR, VARCHAR) TO ROLE AUDIT_INSERT;
