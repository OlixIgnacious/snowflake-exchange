-- Semantic View over the row-level detector views themselves -- closes the "no natural-language
-- path to row-level detector findings" gap flagged in docs/queries_by_workflow.md's "Known gaps"
-- section: SV_SURVEILLANCE_AUDIT only has aggregate counts per run, SV_TRADE_SURVEILLANCE only has
-- raw trade facts, and neither can answer "show me the actual flagged wash-trading pairs" or
-- "which participants breached their position limit". This view makes the six detector-family
-- views themselves queryable in natural language, at real row-level granularity (fine-grained
-- DIMENSIONS give one row per participant/instrument/date, not a rolled-up count).
--
-- Six independent TABLES, no RELATIONSHIPS -- same "genuinely unrelated keys" situation
-- SV_OBLIGATIONS_REPORTING documents: a wash-trading candidate pair, a spoofing signal, a
-- position-limit breach, a reporting-timeliness signal, and execution/arrival slippage each have
-- their own natural key and aren't meaningfully joinable at the Semantic View relationship level
-- (that's exactly what docs/queries_by_workflow.md section 4d's UNION ALL "full risk profile"
-- query is for -- direct SQL, not this tool).
--
-- Honesty note: EXECSLIP/ARRSLIP currently have 0 rows for every jurisdiction (TRADE_REFERENCE_
-- PRICES isn't populated by the synthetic generator -- see docs/sources and NOTES.md) -- a
-- best-execution question through this tool will honestly come back empty, not fabricated.
--
-- COV (WASH_DETECTION_COVERAGE) added 2026-09-15 as a structural fix, not another instruction:
-- three independent CoCo adversarial-verification passes confirmed an orchestration instruction
-- telling the agent to "also call trade_surveillance to check for underlying data" is advisory and
-- unreliable -- the model kept answering "no findings" from WASH/SPOOF/etc. alone without ever
-- invoking a second tool to check whether a jurisdiction has any trade data at all (see NOTES.md).
-- COV.TOTAL_TRADES is a real per-jurisdiction/venue/day trade count (COUNT(*) FROM TRADES,
-- sql/detectors/02_wash_trading.sql) -- exposing it here means the fact "is there any underlying
-- data" is answerable from the SAME tool call already being made, with no second tool-invocation
-- decision for the model to skip.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE SEMANTIC VIEW SV_DETECTOR_FINDINGS
    TABLES (
        WASH AS WASH_TRADING_CANDIDATES PRIMARY KEY (TRADE_ID_1, TRADE_ID_2) WITH SYNONYMS ('wash trading candidates', 'wash trades') COMMENT = 'Row-level wash-trading candidate pairs, paired with IS_TRIGGER_EXEMPT.',
        SPOOF AS SPOOFING_LAYERING_SIGNALS PRIMARY KEY (PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, JURISDICTION_ID, EVENT_DATE) WITH SYNONYMS ('spoofing signals', 'layering signals') COMMENT = 'Row-level cancel-ratio z-score signals per participant/instrument/day.',
        POSLIM AS POSITION_LIMIT_BREACHES PRIMARY KEY (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE) WITH SYNONYMS ('position limit breaches', 'position breaches') COMMENT = 'Row-level net position vs. calibrated limit per participant/instrument/day.',
        RPTSIG AS REPORTING_TIMELINESS_SIGNALS PRIMARY KEY (REPORT_ID, JURISDICTION_ID) WITH SYNONYMS ('reporting timeliness signals', 'late reports') COMMENT = 'Row-level timeliness/completeness/match findings per transaction report.',
        EXECSLIP AS EXECUTION_SLIPPAGE PRIMARY KEY (TRADE_ID) WITH SYNONYMS ('execution slippage') COMMENT = 'Row-level executed price vs. reference price at execution. Empty until TRADE_REFERENCE_PRICES is populated.',
        ARRSLIP AS ARRIVAL_SLIPPAGE PRIMARY KEY (TRADE_ID) WITH SYNONYMS ('arrival slippage') COMMENT = 'Row-level order price vs. reference price at order arrival. Empty until TRADE_REFERENCE_PRICES is populated.',
        COV AS WASH_DETECTION_COVERAGE PRIMARY KEY (JURISDICTION_ID, VENUE_ID, TRADE_DATE) WITH SYNONYMS ('trade coverage', 'underlying trade volume', 'data availability') COMMENT = 'Real per-jurisdiction/venue/day trade counts (from TRADES directly, not a detector output) -- query this to confirm whether a jurisdiction has any underlying trade data at all before concluding "no findings" means "no data".'
    )
    DIMENSIONS (
        WASH.TRADE_ID_1 AS WASH.TRADE_ID_1,
        WASH.PARTICIPANT_ID_1 AS WASH.PARTICIPANT_ID_1 WITH SYNONYMS ('participant'),
        WASH.PARTICIPANT_ID_2 AS WASH.PARTICIPANT_ID_2,
        WASH.INSTRUMENT_ID AS WASH.INSTRUMENT_ID,
        WASH.VENUE_ID AS WASH.VENUE_ID,
        WASH.JURISDICTION_ID AS WASH.JURISDICTION_ID,
        WASH.CANDIDATE_TYPE AS WASH.CANDIDATE_TYPE,
        WASH.IS_TRIGGER_EXEMPT AS WASH.IS_TRIGGER_EXEMPT WITH SYNONYMS ('exempt'),

        SPOOF.PARTICIPANT_ID AS SPOOF.PARTICIPANT_ID,
        SPOOF.INSTRUMENT_ID AS SPOOF.INSTRUMENT_ID,
        SPOOF.VENUE_ID AS SPOOF.VENUE_ID,
        SPOOF.JURISDICTION_ID AS SPOOF.JURISDICTION_ID,
        SPOOF.EVENT_DATE AS SPOOF.EVENT_DATE,
        SPOOF.IS_FLAGGED AS SPOOF.IS_FLAGGED WITH SYNONYMS ('flagged'),

        POSLIM.PARTICIPANT_ID AS POSLIM.PARTICIPANT_ID,
        POSLIM.INSTRUMENT_ID AS POSLIM.INSTRUMENT_ID,
        POSLIM.JURISDICTION_ID AS POSLIM.JURISDICTION_ID,
        POSLIM.AS_OF_DATE AS POSLIM.AS_OF_DATE,
        POSLIM.IS_BREACH AS POSLIM.IS_BREACH WITH SYNONYMS ('breach'),

        RPTSIG.REPORT_ID AS RPTSIG.REPORT_ID,
        RPTSIG.REPORT_TYPE AS RPTSIG.REPORT_TYPE,
        RPTSIG.JURISDICTION_ID AS RPTSIG.JURISDICTION_ID,
        RPTSIG.IS_LATE_SUBMISSION AS RPTSIG.IS_LATE_SUBMISSION WITH SYNONYMS ('late'),
        RPTSIG.IS_OVERDUE_UNSUBMITTED AS RPTSIG.IS_OVERDUE_UNSUBMITTED WITH SYNONYMS ('overdue'),
        RPTSIG.IS_INCOMPLETE AS RPTSIG.IS_INCOMPLETE,
        RPTSIG.IS_MISMATCHED AS RPTSIG.IS_MISMATCHED,
        RPTSIG.SUBMITTED_AT AS RPTSIG.SUBMITTED_AT,
        RPTSIG.DEADLINE AS RPTSIG.DEADLINE WITH SYNONYMS ('raw deadline') COMMENT = 'The unadjusted deadline, before the business-day correction below.',
        RPTSIG.EFFECTIVE_DEADLINE AS RPTSIG.EFFECTIVE_DEADLINE WITH SYNONYMS ('effective deadline', 'business-day-adjusted deadline') COMMENT = 'The real deadline IS_LATE_SUBMISSION is actually computed against -- DEADLINE moved to the next business day when it falls on a weekend. Query this directly to confirm weekend-handling behavior; do not infer it from RULE_CORPUS text (added 2026-09-15 specifically so this is queryable, not just re-derivable).',

        EXECSLIP.TRADE_ID AS EXECSLIP.TRADE_ID,
        EXECSLIP.INSTRUMENT_ID AS EXECSLIP.INSTRUMENT_ID,
        EXECSLIP.JURISDICTION_ID AS EXECSLIP.JURISDICTION_ID,

        ARRSLIP.TRADE_ID AS ARRSLIP.TRADE_ID,
        ARRSLIP.INSTRUMENT_ID AS ARRSLIP.INSTRUMENT_ID,
        ARRSLIP.JURISDICTION_ID AS ARRSLIP.JURISDICTION_ID,

        COV.JURISDICTION_ID AS COV.JURISDICTION_ID,
        COV.VENUE_ID AS COV.VENUE_ID,
        COV.TRADE_DATE AS COV.TRADE_DATE
    )
    METRICS (
        WASH.CANDIDATE_COUNT AS COUNT(WASH.TRADE_ID_1) COMMENT = 'Number of wash-trading candidate pairs.',
        WASH.NON_EXEMPT_COUNT AS COUNT_IF(NOT WASH.IS_TRIGGER_EXEMPT) COMMENT = 'Candidates not covered by a calibrated exemption.',

        SPOOF.FLAGGED_COUNT AS COUNT_IF(SPOOF.IS_FLAGGED) COMMENT = 'Number of flagged spoofing/layering signal-days.',
        SPOOF.AVG_CANCEL_RATIO_ZSCORE AS AVG(SPOOF.CANCEL_RATIO_ZSCORE) COMMENT = 'Average cancel-ratio z-score across matching rows.',
        SPOOF.MAX_CANCEL_RATIO_ZSCORE AS MAX(SPOOF.CANCEL_RATIO_ZSCORE) COMMENT = 'Peak cancel-ratio z-score across matching rows.',

        POSLIM.BREACH_COUNT AS COUNT_IF(POSLIM.IS_BREACH) COMMENT = 'Number of position-limit breach rows.',
        POSLIM.MAX_PCT_OF_LIMIT AS MAX(POSLIM.PCT_OF_LIMIT) COMMENT = 'Highest percentage of the calibrated limit reached.',

        RPTSIG.LATE_COUNT AS COUNT_IF(RPTSIG.IS_LATE_SUBMISSION) COMMENT = 'Reports submitted after their effective deadline.',
        RPTSIG.OVERDUE_COUNT AS COUNT_IF(RPTSIG.IS_OVERDUE_UNSUBMITTED) COMMENT = 'Reports past deadline and still unsubmitted.',
        RPTSIG.INCOMPLETE_COUNT AS COUNT_IF(RPTSIG.IS_INCOMPLETE) COMMENT = 'Reports missing a required mapped field.',
        RPTSIG.MISMATCHED_COUNT AS COUNT_IF(RPTSIG.IS_MISMATCHED) COMMENT = 'Reports that do not match their underlying trade.',

        EXECSLIP.ROW_COUNT AS COUNT(EXECSLIP.TRADE_ID) COMMENT = 'Trades with a checkable execution reference price (0 until TRADE_REFERENCE_PRICES is populated).',
        EXECSLIP.AVG_SLIPPAGE_PCT AS AVG(EXECSLIP.EXECUTION_SLIPPAGE_PCT) COMMENT = 'Average execution slippage percentage.',

        ARRSLIP.ROW_COUNT AS COUNT(ARRSLIP.TRADE_ID) COMMENT = 'Trades with a checkable arrival reference price (0 until TRADE_REFERENCE_PRICES is populated).',
        ARRSLIP.AVG_SLIPPAGE_PCT AS AVG(ARRSLIP.ARRIVAL_SLIPPAGE_PCT) COMMENT = 'Average arrival slippage percentage.',

        COV.TOTAL_TRADE_VOLUME AS SUM(COV.TOTAL_TRADES) COMMENT = 'Total real trade count for the matching jurisdiction/venue/day(s) -- zero or no rows here means no trade data exists at all, distinct from a detector finding zero flagged rows.'
    )
    COMMENT = 'Row-level detector findings: wash-trading candidates, spoofing/layering signals, position-limit breaches, reporting-timeliness signals, execution/arrival slippage -- not aggregate run counts (that is surveillance_audit) and not raw trade facts (that is trade_surveillance).';

GRANT SELECT ON SEMANTIC VIEW SV_DETECTOR_FINDINGS TO ROLE ANALYST_READ;
