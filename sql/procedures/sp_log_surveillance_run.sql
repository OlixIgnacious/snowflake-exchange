-- SP_LOG_SURVEILLANCE_RUN: runs all five detector families for a given jurisdiction and inserts
-- one AUDIT_LOG row per detector summarizing what was flagged. Same EXECUTE AS OWNER pattern
-- as SP_RECORD_SIGNOFF -- the calling role (AUDIT_INSERT) has no direct SELECT on detector views;
-- the procedure's owner privileges write the rows. Each detector gets its own RUN_ID (AUDIT_LOG
-- PK), and a shared QUERY_SNAPSHOT_ID ties the five rows to one surveillance run.
--
-- best_execution is logged even though EXECUTION_SLIPPAGE/ARRIVAL_SLIPPAGE currently return 0
-- rows (TRADE_REFERENCE_PRICES has its own external adaptor, not populated by the synthetic
-- generator) -- the coverage gap itself ("0 of N trades had a reference price to check against")
-- is evidence worth logging, same "surfaced, not silently skipped" discipline as
-- WASH_DETECTION_COVERAGE elsewhere in this schema.
--
-- AUDIT_LOG is append-only by grant (no role ever gets UPDATE/DELETE) -- each call produces
-- new rows, never mutates existing ones.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_LOG_SURVEILLANCE_RUN(
    P_JURISDICTION_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_snapshot_id VARCHAR DEFAULT UUID_STRING();
    v_now         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_user        VARCHAR DEFAULT CURRENT_USER();

    v_run_wash    VARCHAR DEFAULT UUID_STRING();
    v_run_spoof   VARCHAR DEFAULT UUID_STRING();
    v_run_pos     VARCHAR DEFAULT UUID_STRING();
    v_run_report  VARCHAR DEFAULT UUID_STRING();

    v_wash_total       NUMBER DEFAULT 0;
    v_wash_non_exempt  NUMBER DEFAULT 0;
    v_spoof_flagged    NUMBER DEFAULT 0;
    v_pos_breaches     NUMBER DEFAULT 0;
    v_report_overdue   NUMBER DEFAULT 0;
    v_report_late      NUMBER DEFAULT 0;
    v_report_incomplete NUMBER DEFAULT 0;
    v_report_mismatched NUMBER DEFAULT 0;

    v_run_bestexec        VARCHAR DEFAULT UUID_STRING();
    v_trade_total         NUMBER DEFAULT 0;
    v_exec_checked        NUMBER DEFAULT 0;
    v_arrival_checked     NUMBER DEFAULT 0;
BEGIN
    -- Wash trading candidates
    SELECT COUNT(*), COUNT_IF(NOT IS_TRIGGER_EXEMPT)
      INTO :v_wash_total, :v_wash_non_exempt
      FROM WASH_TRADING_CANDIDATES
     WHERE JURISDICTION_ID = :P_JURISDICTION_ID;

    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_wash, :v_user, 'surveillance_run', 'wash_trading', NULL,
        NULL, :v_snapshot_id,
        OBJECT_CONSTRUCT(
            'detector', 'wash_trading',
            'jurisdiction_id', :P_JURISDICTION_ID,
            'total_candidates', :v_wash_total,
            'non_exempt_candidates', :v_wash_non_exempt
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    -- Spoofing/layering signals
    SELECT COUNT_IF(IS_FLAGGED)
      INTO :v_spoof_flagged
      FROM SPOOFING_LAYERING_SIGNALS
     WHERE JURISDICTION_ID = :P_JURISDICTION_ID;

    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_spoof, :v_user, 'surveillance_run', 'spoofing_layering', NULL,
        NULL, :v_snapshot_id,
        OBJECT_CONSTRUCT(
            'detector', 'spoofing_layering',
            'jurisdiction_id', :P_JURISDICTION_ID,
            'flagged_signals', :v_spoof_flagged
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    -- Position limit breaches
    SELECT COUNT_IF(IS_BREACH)
      INTO :v_pos_breaches
      FROM POSITION_LIMIT_BREACHES
     WHERE JURISDICTION_ID = :P_JURISDICTION_ID;

    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_pos, :v_user, 'surveillance_run', 'position_limit', NULL,
        NULL, :v_snapshot_id,
        OBJECT_CONSTRUCT(
            'detector', 'position_limit',
            'jurisdiction_id', :P_JURISDICTION_ID,
            'breaches', :v_pos_breaches
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    -- Reporting timeliness signals
    SELECT
        COUNT_IF(IS_OVERDUE_UNSUBMITTED),
        COUNT_IF(IS_LATE_SUBMISSION),
        COUNT_IF(IS_INCOMPLETE),
        COUNT_IF(IS_MISMATCHED)
      INTO :v_report_overdue, :v_report_late, :v_report_incomplete, :v_report_mismatched
      FROM REPORTING_TIMELINESS_SIGNALS
     WHERE JURISDICTION_ID = :P_JURISDICTION_ID;

    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_report, :v_user, 'surveillance_run', 'reporting_timeliness', NULL,
        NULL, :v_snapshot_id,
        OBJECT_CONSTRUCT(
            'detector', 'reporting_timeliness',
            'jurisdiction_id', :P_JURISDICTION_ID,
            'overdue_unsubmitted', :v_report_overdue,
            'late_submissions', :v_report_late,
            'incomplete_reports', :v_report_incomplete,
            'mismatched_reports', :v_report_mismatched
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    -- Best execution -- logged even at 0 rows checked; the coverage gap itself is the finding.
    SELECT COUNT(*) INTO :v_trade_total FROM TRADES WHERE JURISDICTION_ID = :P_JURISDICTION_ID;
    SELECT COUNT(*) INTO :v_exec_checked FROM EXECUTION_SLIPPAGE WHERE JURISDICTION_ID = :P_JURISDICTION_ID;
    SELECT COUNT(*) INTO :v_arrival_checked FROM ARRIVAL_SLIPPAGE WHERE JURISDICTION_ID = :P_JURISDICTION_ID;

    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, MODEL_VERSION,
        RETRIEVED_RULE_CHUNK_IDS, QUERY_SNAPSHOT_ID, OUTPUT, IS_EVAL,
        SIGNOFF_FOR_RUN_ID, HUMAN_DECISION, SIGNOFF_BY, SIGNOFF_AT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        :v_run_bestexec, :v_user, 'surveillance_run', 'best_execution', NULL,
        NULL, :v_snapshot_id,
        OBJECT_CONSTRUCT(
            'detector', 'best_execution',
            'jurisdiction_id', :P_JURISDICTION_ID,
            'total_trades', :v_trade_total,
            'execution_slippage_checked', :v_exec_checked,
            'arrival_slippage_checked', :v_arrival_checked,
            'execution_slippage_uncheckable', :v_trade_total - :v_exec_checked
        )::VARCHAR,
        FALSE,
        NULL, NULL, NULL, NULL,
        :v_now, :v_user, :v_now, :v_user;

    RETURN :v_snapshot_id;
END;
$$;

GRANT USAGE ON PROCEDURE SP_LOG_SURVEILLANCE_RUN(VARCHAR) TO ROLE AUDIT_INSERT;
