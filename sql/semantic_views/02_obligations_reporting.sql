-- Semantic View over the governance/reporting domain object: approved obligations (never the
-- base OBLIGATION_MAP table -- Fix #6's governance gate stays structural here too), rule corpus,
-- transaction reports, report templates.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE SEMANTIC VIEW SV_OBLIGATIONS_REPORTING
    TABLES (
        OBL AS APPROVED_OBLIGATIONS PRIMARY KEY (OBLIGATION_ID, JURISDICTION_ID) WITH SYNONYMS ('obligations') COMMENT = 'Latest approved obligation-to-detector mappings only.',
        RPT AS TRANSACTION_REPORTS_CURRENT PRIMARY KEY (REPORT_ID, JURISDICTION_ID) WITH SYNONYMS ('reports', 'transaction reports'),
        TMPL AS REPORT_TEMPLATES_CURRENT PRIMARY KEY (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME) WITH SYNONYMS ('report templates', 'required fields')
    )
    -- No RELATIONSHIPS clause: REPORT_TEMPLATES_CURRENT's real key is (JURISDICTION_ID,
    -- REPORT_TYPE, FIELD_NAME) -- one row per required FIELD, not per report type -- so a report
    -- doesn't join to exactly one TMPL row the way a Semantic View relationship requires (the
    -- referenced side's full PK/unique key). TMPL and RPT stay independent tables in this view,
    -- queried separately; REPORT_TEMPLATE_COVERAGE (sql/detectors/) is the per-report-type
    -- aggregate that actually relates the two conceptually.
    DIMENSIONS (
        RPT.REPORT_STATUS AS RPT.REPORT_STATUS,
        RPT.REPORT_SCOPE AS RPT.REPORT_SCOPE,
        RPT.MATCH_STATUS AS RPT.MATCH_STATUS,
        TMPL.FIELD_STATUS AS TMPL.STATUS,
        OBL.DETECTOR_NAME AS OBL.DETECTOR_NAME
    )
    METRICS (
        RPT.REPORT_COUNT AS COUNT(RPT.REPORT_ID) COMMENT = 'Number of transaction reports.',
        -- Business-day-adjusted deadline, duplicated from sql/detectors/05_reporting_timeliness.sql's
        -- EFFECTIVE_DEADLINE -- found and fixed together: this metric originally compared against
        -- the raw, weekend-uncorrected DEADLINE, which would have given a different (wrong) answer
        -- than REPORTING_TIMELINESS_SIGNALS/surveillance_audit for the same question ("how many
        -- reports are late") depending on which agent tool routed it. A Semantic View METRIC can't
        -- reference another view's already-computed column across TABLES not declared here, so this
        -- duplicates the CASE expression rather than adding a fourth TABLE/RELATIONSHIP just for one
        -- column -- if the business-day formula ever changes, both places need it.
        RPT.LATE_COUNT AS COUNT_IF(RPT.SUBMITTED_AT >
            CASE DAYOFWEEKISO(RPT.DEADLINE)
                WHEN 6 THEN DATEADD(day, 2, RPT.DEADLINE)
                WHEN 7 THEN DATEADD(day, 1, RPT.DEADLINE)
                ELSE RPT.DEADLINE
            END) COMMENT = 'Reports submitted after their effective (business-day-adjusted) deadline.',
        TMPL.REQUIRED_FIELD_COUNT AS COUNT_IF(TMPL.IS_REQUIRED) COMMENT = 'Required fields for a report type.'
    )
    COMMENT = 'Governance/reporting domain: approved obligations, transaction reports, report templates.';

GRANT SELECT ON SEMANTIC VIEW SV_OBLIGATIONS_REPORTING TO ROLE ANALYST_READ;
