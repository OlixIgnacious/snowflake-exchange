-- Post-trade reporting timeliness/completeness. Spec: architecture.md "Detectors" section.
-- Rules-based, not statistical -- lateness has a hard deadline, not a distribution. Reads the
-- already-computed FIELDS_COMPLETE (Fix #22/#29, computed at ingest time against
-- REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED AND STATUS='mapped') and MATCH_STATUS (Fix #9)
-- columns rather than recomputing them here -- SOURCE_MAPPING is free text pointing at arbitrary
-- source columns (Fix #9's documented unenforceable-in-SQL limitation), so a live view can't
-- generically re-derive "is every required field populated" without dynamic SQL; that
-- computation belongs to the report-generation adaptor (Phase 4), not this detector.
-- MATCH_STATUS is NULL for REPORT_SCOPE != 'trade' (Fix #23) -- surfaced as-is, not coerced.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW REPORTING_TIMELINESS_SIGNALS AS
SELECT
    r.REPORT_ID, r.JURISDICTION_ID, r.VENUE_ID, r.REPORT_TYPE, r.REPORT_SCOPE,
    r.TRADE_ID, r.REPORT_STATUS, r.SUBMITTED_AT, r.DEADLINE,
    r.FIELDS_COMPLETE, r.MATCH_STATUS, r.DEFERRED_PUBLICATION_UNTIL,
    (r.SUBMITTED_AT IS NULL AND CURRENT_TIMESTAMP()::TIMESTAMP_NTZ > r.DEADLINE) AS IS_OVERDUE_UNSUBMITTED,
    (r.SUBMITTED_AT IS NOT NULL AND r.SUBMITTED_AT > r.DEADLINE) AS IS_LATE_SUBMISSION,
    (COALESCE(r.FIELDS_COMPLETE, FALSE) = FALSE) AS IS_INCOMPLETE,
    (r.REPORT_SCOPE = 'trade' AND r.MATCH_STATUS IN ('partial_match', 'no_match')) AS IS_MISMATCHED
FROM TRANSACTION_REPORTS_CURRENT r;

GRANT SELECT ON VIEW REPORTING_TIMELINESS_SIGNALS TO ROLE ANALYST_READ;
