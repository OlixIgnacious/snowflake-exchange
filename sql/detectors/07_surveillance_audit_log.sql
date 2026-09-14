-- SURVEILLANCE_RUN_LOG: a read view over AUDIT_LOG WHERE STAGE = 'surveillance_run', normalizing
-- each detector's own JSON shape (SP_LOG_SURVEILLANCE_RUN's OUTPUT column) into one FLAGGED_COUNT
-- column, so a downstream consumer (Semantic View, agent, dashboard) needs one column instead of
-- four detector-specific JSON extractions. Captured here from CoCo's live Snowflake object
-- (created directly via sql_execute, never originally saved to a file) so it's reproducible from
-- sql/ alone -- see NOTES.md/TRACKER.md for the full CoCo-build writeup.
--
-- No milestoning columns of its own: this is a pure derived view over AUDIT_LOG, which is already
-- append-only and immutable -- there is nothing here to version independently of the base table.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW SURVEILLANCE_RUN_LOG(
    RUN_ID,
    DETECTOR_NAME,
    QUERY_SNAPSHOT_ID,
    CREATED_AT,
    APP_USER,
    FLAGGED_COUNT
) AS
-- FLAGGED_COUNT is a single normalized integer whose meaning depends on DETECTOR_NAME:
--   wash_trading:          OUTPUT:non_exempt_candidates  (exempt candidates excluded)
--   spoofing_layering:     OUTPUT:flagged_signals        (z-score above threshold)
--   position_limit:        OUTPUT:breaches               (positions >= regulatory limit)
--   reporting_timeliness:  SUM of OUTPUT:overdue_unsubmitted + late_submissions
--                              + incomplete_reports + mismatched_reports
-- This mapping lives here (the one place the count's meaning is detector-dependent)
-- so every downstream consumer -- Semantic View, agent, dashboard -- gets one column
-- instead of four detector-specific JSON extractions.
SELECT
    RUN_ID,
    PROMPT_OR_QUESTION                              AS DETECTOR_NAME,
    QUERY_SNAPSHOT_ID,
    CREATED_AT,
    APP_USER,
    CASE PROMPT_OR_QUESTION
        WHEN 'wash_trading'
            THEN PARSE_JSON(OUTPUT):non_exempt_candidates::NUMBER
        WHEN 'spoofing_layering'
            THEN PARSE_JSON(OUTPUT):flagged_signals::NUMBER
        WHEN 'position_limit'
            THEN PARSE_JSON(OUTPUT):breaches::NUMBER
        WHEN 'reporting_timeliness'
            THEN COALESCE(PARSE_JSON(OUTPUT):overdue_unsubmitted::NUMBER, 0)
               + COALESCE(PARSE_JSON(OUTPUT):late_submissions::NUMBER, 0)
               + COALESCE(PARSE_JSON(OUTPUT):incomplete_reports::NUMBER, 0)
               + COALESCE(PARSE_JSON(OUTPUT):mismatched_reports::NUMBER, 0)
    END                                             AS FLAGGED_COUNT
FROM VIGIL.CORE.AUDIT_LOG
WHERE STAGE = 'surveillance_run';

GRANT SELECT ON VIEW SURVEILLANCE_RUN_LOG TO ROLE ANALYST_READ;
