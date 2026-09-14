-- Semantic View over the surveillance audit trail: SURVEILLANCE_RUN_LOG (a view over AUDIT_LOG
-- WHERE STAGE = 'surveillance_run'). Makes surveillance run history queryable in natural
-- language via the Cortex Agent -- "how many wash-trading findings today", "which detector
-- flagged the most items in the last run", etc.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE SEMANTIC VIEW SV_SURVEILLANCE_AUDIT
    TABLES (
        RUN AS SURVEILLANCE_RUN_LOG PRIMARY KEY (RUN_ID) WITH SYNONYMS ('surveillance runs', 'audit log', 'detector runs') COMMENT = 'One row per detector per surveillance run, with a normalized flagged count.'
    )
    DIMENSIONS (
        RUN.DETECTOR_NAME AS RUN.DETECTOR_NAME WITH SYNONYMS ('detector', 'detector type') COMMENT = 'Which detector produced this row: wash_trading, spoofing_layering, position_limit, or reporting_timeliness.',
        RUN.CREATED_AT AS DATE(RUN.CREATED_AT) WITH SYNONYMS ('date', 'run date') COMMENT = 'Date the surveillance run executed.',
        RUN.QUERY_SNAPSHOT_ID AS RUN.QUERY_SNAPSHOT_ID WITH SYNONYMS ('snapshot', 'run batch') COMMENT = 'Groups the four detector rows from a single SP_LOG_SURVEILLANCE_RUN call.'
    )
    METRICS (
        RUN.RUN_COUNT AS COUNT(RUN.RUN_ID) COMMENT = 'Number of detector-level audit rows.',
        RUN.TOTAL_FLAGGED AS SUM(RUN.FLAGGED_COUNT) COMMENT = 'Sum of normalized flagged counts across matching rows.'
    )
    COMMENT = 'Surveillance audit trail: detector run history with normalized flagged counts per detector.';

GRANT SELECT ON SEMANTIC VIEW SV_SURVEILLANCE_AUDIT TO ROLE ANALYST_READ;
