-- Post-trade reporting timeliness/completeness. Spec: architecture.md "Detectors" section.
-- Rules-based, not statistical -- lateness has a hard deadline, not a distribution. Reads the
-- already-computed FIELDS_COMPLETE (Fix #22/#29, computed at ingest time against
-- REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED AND STATUS='mapped') and MATCH_STATUS (Fix #9)
-- columns rather than recomputing them here -- SOURCE_MAPPING is free text pointing at arbitrary
-- source columns (Fix #9's documented unenforceable-in-SQL limitation), so a live view can't
-- generically re-derive "is every required field populated" without dynamic SQL; that
-- computation belongs to the report-generation adaptor (Phase 4), not this detector.
-- MATCH_STATUS is NULL for REPORT_SCOPE != 'trade' (Fix #23) -- surfaced as-is, not coerced.
--
-- EFFECTIVE_DEADLINE (found via live behavioral testing, not a design assumption): a regulatory
-- T+1 deadline is conventionally T+1 *business* day, not calendar day. Rolling DEADLINE forward
-- past a Saturday/Sunday to the following Monday here -- rather than mutating the stored
-- DEADLINE on TRANSACTION_REPORTS, which would misrepresent what was actually recorded at
-- generation time -- reclassified 23 of 82 previously-flagged "late" reports (28%) as correctly
-- on time once checked against the real loaded data. DEADLINE itself is left untouched and still
-- exposed as-is; IS_OVERDUE_UNSUBMITTED/IS_LATE_SUBMISSION now compare against
-- EFFECTIVE_DEADLINE. Deliberately weekend-only, not a full market-holiday calendar -- see
-- generator/generate.py's _next_business_day_deadline for the same scoping note.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW REPORTING_TIMELINESS_SIGNALS AS
SELECT
    r.REPORT_ID, r.JURISDICTION_ID, r.VENUE_ID, r.REPORT_TYPE, r.REPORT_SCOPE,
    r.TRADE_ID, r.REPORT_STATUS, r.SUBMITTED_AT, r.DEADLINE,
    CASE DAYOFWEEKISO(r.DEADLINE)
        WHEN 6 THEN DATEADD(day, 2, r.DEADLINE)  -- Saturday -> Monday
        WHEN 7 THEN DATEADD(day, 1, r.DEADLINE)  -- Sunday -> Monday
        ELSE r.DEADLINE
    END AS EFFECTIVE_DEADLINE,
    r.FIELDS_COMPLETE, r.MATCH_STATUS, r.DEFERRED_PUBLICATION_UNTIL,
    (r.SUBMITTED_AT IS NULL AND CURRENT_TIMESTAMP()::TIMESTAMP_NTZ >
        CASE DAYOFWEEKISO(r.DEADLINE)
            WHEN 6 THEN DATEADD(day, 2, r.DEADLINE)
            WHEN 7 THEN DATEADD(day, 1, r.DEADLINE)
            ELSE r.DEADLINE
        END) AS IS_OVERDUE_UNSUBMITTED,
    (r.SUBMITTED_AT IS NOT NULL AND r.SUBMITTED_AT >
        CASE DAYOFWEEKISO(r.DEADLINE)
            WHEN 6 THEN DATEADD(day, 2, r.DEADLINE)
            WHEN 7 THEN DATEADD(day, 1, r.DEADLINE)
            ELSE r.DEADLINE
        END) AS IS_LATE_SUBMISSION,
    (COALESCE(r.FIELDS_COMPLETE, FALSE) = FALSE) AS IS_INCOMPLETE,
    (r.REPORT_SCOPE = 'trade' AND r.MATCH_STATUS IN ('partial_match', 'no_match')) AS IS_MISMATCHED
FROM TRANSACTION_REPORTS_CURRENT r;

GRANT SELECT ON VIEW REPORTING_TIMELINESS_SIGNALS TO ROLE ANALYST_READ;
