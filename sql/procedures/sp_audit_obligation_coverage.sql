-- SP_AUDIT_OBLIGATION_COVERAGE -- scheduled governance-drift check, one AUDIT_LOG row per
-- JURISDICTIONS_CURRENT row, listing which of the five detector families have a real, active
-- APPROVED_OBLIGATIONS -> OBLIGATION_RULE_CHUNKS_CURRENT -> RULE_CORPUS_CURRENT chain and which
-- don't. Same EXECUTE AS OWNER / AUDIT_INSERT pattern as SP_LOG_SURVEILLANCE_RUN.
--
-- Scope note (deliberate, not a shortcut): this audits internal consistency of what's already
-- loaded -- it does NOT fetch FSA/JPX/SEC/EUR-Lex sites to check for new or amended source
-- documents. That would need External Access Integration (outbound network access from
-- Snowflake), which was intentionally not built in this pass -- see NOTES.md. Calling this a
-- "new document" monitor would overclaim; it is a coverage-drift monitor: it would catch a
-- revoked/un-mapped obligation or a newly added jurisdiction/detector with no rule citation yet,
-- which is real and useful on its own, but it is not source-document monitoring.
--
-- The five DETECTOR_NAME values are hardcoded (not read from DETECTOR_CALIBRATION, which only
-- covers 3 of the 5 -- reporting_timeliness/best_execution have no calibration params) -- this is
-- the fixed set of detector views this codebase implements, not a per-market variable, so it does
-- not violate the "no hardcoded threshold/currency" market-agnostic rule.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_AUDIT_OBLIGATION_COVERAGE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       VARCHAR DEFAULT UUID_STRING();
    v_now          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_user         VARCHAR DEFAULT CURRENT_USER();
    v_gap_count    NUMBER DEFAULT 0;
BEGIN
    INSERT INTO AUDIT_LOG (
        RUN_ID, APP_USER, STAGE, PROMPT_OR_QUESTION, OUTPUT,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT :v_run_id, :v_user, 'governance_coverage_audit', j.JURISDICTION_ID,
        OBJECT_CONSTRUCT(
            'jurisdiction_id', j.JURISDICTION_ID,
            'covered_detectors', ARRAY_COMPACT(ARRAY_AGG(
                CASE WHEN ao.OBLIGATION_ID IS NOT NULL AND orc.RULE_CHUNK_ID IS NOT NULL
                     THEN d.DETECTOR_NAME END
            ) WITHIN GROUP (ORDER BY d.DETECTOR_NAME)),
            'missing_detectors', ARRAY_COMPACT(ARRAY_AGG(
                CASE WHEN ao.OBLIGATION_ID IS NULL OR orc.RULE_CHUNK_ID IS NULL
                     THEN d.DETECTOR_NAME END
            ) WITHIN GROUP (ORDER BY d.DETECTOR_NAME))
        )::VARCHAR,
        :v_now, :v_user, :v_now, :v_user
    FROM JURISDICTIONS_CURRENT j
    CROSS JOIN (
        SELECT column1 AS DETECTOR_NAME FROM VALUES
            ('wash_trading'), ('spoofing_layering'), ('position_limit'),
            ('reporting_timeliness'), ('best_execution')
    ) d
    LEFT JOIN APPROVED_OBLIGATIONS ao
        ON ao.JURISDICTION_ID = j.JURISDICTION_ID AND ao.DETECTOR_NAME = d.DETECTOR_NAME
    LEFT JOIN OBLIGATION_RULE_CHUNKS_CURRENT orc
        ON orc.OBLIGATION_ID = ao.OBLIGATION_ID AND orc.JURISDICTION_ID = ao.JURISDICTION_ID
    GROUP BY j.JURISDICTION_ID;

    SELECT COUNT(*) INTO :v_gap_count
    FROM AUDIT_LOG
    WHERE RUN_ID = :v_run_id
      AND ARRAY_SIZE(PARSE_JSON(OUTPUT):missing_detectors) > 0;

    RETURN 'RUN_ID=' || :v_run_id || ', jurisdictions_with_gaps=' || :v_gap_count;
END;
$$;

GRANT USAGE ON PROCEDURE SP_AUDIT_OBLIGATION_COVERAGE() TO ROLE AUDIT_INSERT;
