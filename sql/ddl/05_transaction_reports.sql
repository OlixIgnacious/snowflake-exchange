-- TRANSACTION_REPORTS + REPORT_TEMPLATES + REPORT_TEMPLATE_RULE_CHUNKS + REPORT_TEMPLATE_COVERAGE.
-- Spec: docs/canonical_schema_contract.md v7, "Core tables" > TRANSACTION_REPORTS /
-- REPORT_TEMPLATES / REPORT_TEMPLATE_COVERAGE / REPORT_TEMPLATE_RULE_CHUNKS.
--
-- REPORT_TEMPLATES/REPORT_TEMPLATE_RULE_CHUNKS mirror OBLIGATION_MAP/OBLIGATION_RULE_CHUNKS
-- (06_governance.sql) exactly -- same STATUS-lifecycle-via-new-row pattern, same tombstone
-- pattern for IS_ACTIVE. TRANSACTION_REPORTS.REPORT_TYPE is a logical FK into REPORT_TEMPLATES'
-- natural key (JURISDICTION_ID, REPORT_TYPE) -- not declared (milestoned parent), see
-- 01_reference_data.sql's file header rationale.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- REPORT_TEMPLATES (new, Fix #21; STATUS lifecycle added Fix #27)
-- ============================================================================
CREATE TABLE IF NOT EXISTS REPORT_TEMPLATES (
    JURISDICTION_ID  VARCHAR NOT NULL,
    REPORT_TYPE      VARCHAR NOT NULL
        COMMENT 'e.g. transaction_report, large_trade_notification, position_report.',
    FIELD_NAME       VARCHAR NOT NULL
        COMMENT 'The regulator''s own field/tag name (e.g. Buyer_LEI, Trading_Capacity) -- not a VIGIL.CORE column name.',
    FIELD_ORDER      NUMBER
        COMMENT 'Position in the format when order-sensitive (fixed-width/CSV); NULL for tag-based formats (XML/JSON).',
    STATUS           VARCHAR NOT NULL DEFAULT 'proposed'
        COMMENT 'Fix #27. proposed (found by gap analysis) / mapped (SOURCE_MAPPING resolves) / gap (Fix #28 -- required field with no current source in VIGIL.CORE; deliberate, non-blocking). Transition = new row via GOVERNANCE_WRITE, same key, later LOADED_AT -- never an UPDATE.',
    SOURCE_MAPPING   VARCHAR
        COMMENT 'Free text (e.g. TRADES.PRICE), unenforceable as a real FK against a dynamic column reference -- same caveat as OBLIGATION_MAP.SOURCE_TABLE/SOURCE_COLUMNS (Fix #9). Must resolve against INFORMATION_SCHEMA before STATUS can be written as mapped; NULL by convention when STATUS = gap.',
    FIELD_FORMAT     VARCHAR
        COMMENT 'e.g. ISO8601, ISIN, decimal(18,4), or a named code-lookup.',
    IS_REQUIRED      BOOLEAN NOT NULL
        COMMENT 'Drives TRANSACTION_REPORTS.FIELDS_COMPLETE (Fix #22/#29, only among STATUS = mapped rows) and REPORT_TEMPLATE_COVERAGE (Fix #28).',
    CREATED_AT       TIMESTAMP_NTZ NOT NULL,
    CREATED_BY       VARCHAR NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'A circular amending the required field list, or a gap field getting mapped, is a new row, same (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME), later LOADED_AT -- never an UPDATE.',
    LOADED_BY        VARCHAR NOT NULL,
    CONSTRAINT PK_REPORT_TEMPLATES PRIMARY KEY (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, LOADED_AT)
);

CREATE OR REPLACE VIEW REPORT_TEMPLATES_CURRENT AS
SELECT *
FROM REPORT_TEMPLATES
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JURISDICTION_ID, REPORT_TYPE, FIELD_NAME
    ORDER BY LOADED_AT DESC
) = 1;

-- REPORT_TEMPLATE_COVERAGE (new view, Fix #28): one row per (JURISDICTION_ID, REPORT_TYPE),
-- PCT_REQUIRED_FIELDS_MAPPED = fraction of REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED rows with
-- STATUS = mapped, plus the list of currently-gap FIELD_NAMEs. Same "surfaced, not hidden"
-- discipline as WASH_DETECTION_COVERAGE (Fix #3).
CREATE OR REPLACE VIEW REPORT_TEMPLATE_COVERAGE AS
SELECT
    JURISDICTION_ID,
    REPORT_TYPE,
    COUNT_IF(IS_REQUIRED) AS REQUIRED_FIELD_COUNT,
    COUNT_IF(IS_REQUIRED AND STATUS = 'mapped') AS MAPPED_REQUIRED_FIELD_COUNT,
    DIV0(
        COUNT_IF(IS_REQUIRED AND STATUS = 'mapped'),
        COUNT_IF(IS_REQUIRED)
    ) AS PCT_REQUIRED_FIELDS_MAPPED,
    ARRAY_COMPACT(
        ARRAY_AGG(CASE WHEN IS_REQUIRED AND STATUS = 'gap' THEN FIELD_NAME END)
            WITHIN GROUP (ORDER BY FIELD_NAME)
    ) AS GAP_FIELD_NAMES
FROM REPORT_TEMPLATES_CURRENT
GROUP BY JURISDICTION_ID, REPORT_TYPE;

-- ============================================================================
-- REPORT_TEMPLATE_RULE_CHUNKS (new, Fix #21; mirrors OBLIGATION_RULE_CHUNKS, Fix #9/#13)
-- ============================================================================
CREATE TABLE IF NOT EXISTS REPORT_TEMPLATE_RULE_CHUNKS (
    JURISDICTION_ID  VARCHAR NOT NULL,
    REPORT_TYPE      VARCHAR NOT NULL,
    FIELD_NAME       VARCHAR NOT NULL
        COMMENT 'References REPORT_TEMPLATES'' natural key (not a specific LOADED_AT version) -- same convention OBLIGATION_RULE_CHUNKS uses relative to OBLIGATION_MAP.',
    RULE_CHUNK_ID    VARCHAR NOT NULL
        COMMENT 'Logical FK -> RULE_CORPUS (not declared, milestoned parent).',
    IS_ACTIVE        BOOLEAN NOT NULL DEFAULT TRUE
        COMMENT 'Tombstone pattern (Fix #13) -- a wrong citation is corrected by a new row, never a DELETE.',
    CREATED_AT       TIMESTAMP_NTZ NOT NULL,
    CREATED_BY       VARCHAR NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL,
    LOADED_BY        VARCHAR NOT NULL,
    CONSTRAINT PK_REPORT_TEMPLATE_RULE_CHUNKS PRIMARY KEY (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, RULE_CHUNK_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW REPORT_TEMPLATE_RULE_CHUNKS_CURRENT AS
SELECT *
FROM REPORT_TEMPLATE_RULE_CHUNKS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, RULE_CHUNK_ID
    ORDER BY LOADED_AT DESC
) = 1
AND IS_ACTIVE;

-- ============================================================================
-- TRANSACTION_REPORTS -- milestoned as of Fix #14; extended Fix #21-#26
-- ============================================================================
CREATE TABLE IF NOT EXISTS TRANSACTION_REPORTS (
    REPORT_ID                    VARCHAR NOT NULL,
    JURISDICTION_ID              VARCHAR NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    VENUE_ID                     VARCHAR
        COMMENT 'Nullable -- the reporting facility, when it differs from the trade''s execution venue (e.g. an OTC trade reported to a jurisdiction-level facility).',
    REPORT_TYPE                  VARCHAR NOT NULL
        COMMENT 'Fix #21. Logical FK (+ JURISDICTION_ID) -> REPORT_TEMPLATES -- which regulator-defined format this report must conform to.',
    REPORT_SCOPE                 VARCHAR NOT NULL DEFAULT 'trade'
        COMMENT 'Fix #23. trade / periodic / nil -- a periodic/nil filing is a legitimate report with no TRADE_ID.',
    TRADE_ID                     VARCHAR
        COMMENT 'Fix #23: now nullable. Logical FK -> TRADES, required by convention (enforced by the ingest procedure, not a declarative constraint) when REPORT_SCOPE = trade; NULL otherwise.',
    PERIOD_START                 DATE
        COMMENT 'Fix #23. Populated when REPORT_SCOPE != trade -- the period a periodic/nil filing covers.',
    PERIOD_END                   DATE,
    REPORT_STATUS                VARCHAR NOT NULL DEFAULT 'new'
        COMMENT 'Fix #24. new / amendment / cancellation -- a regulator-facing submission action, distinct from an internal correction (which is just another new-status row via the normal milestoning path).',
    SUBMITTED_AT                 TIMESTAMP_NTZ
        COMMENT 'Nullable if not yet submitted.',
    DEADLINE                     TIMESTAMP_NTZ NOT NULL
        COMMENT 'Submission-to-regulator deadline.',
    DEFERRED_PUBLICATION_UNTIL   TIMESTAMP_NTZ
        COMMENT 'Fix #26. Nullable -- a permitted delayed public-disclosure window for a large-in-scale block trade, distinct from DEADLINE (submission and public-disclosure timing are two different clocks).',
    FIELDS_COMPLETE               BOOLEAN
        COMMENT 'Computed against REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED AND STATUS = mapped for this (JURISDICTION_ID, REPORT_TYPE) (Fix #22/#29) -- never measured against a gap field it could never satisfy.',
    MATCH_STATUS                  VARCHAR
        COMMENT 'full_match / partial_match / no_match (Fix #9), computed against TRADES.INSTRUMENT_ID / PRICE (exact) / VOLUME (exact) / EXECUTION_TIMESTAMP (documented tolerance). NULL when REPORT_SCOPE != trade.',
    REPORT_PAYLOAD_REF            VARCHAR
        COMMENT 'Fix #25. Pointer to the generated submission artifact (e.g. a Snowflake stage path); nullable until generated.',
    CREATED_AT                    TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this REPORT_ID was first created; carried forward on every later lifecycle-event row.',
    CREATED_BY                    VARCHAR NOT NULL,
    LOADED_AT                     TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #14. Each lifecycle event (created / submitted / match computed / amended / cancelled) is a new row with a later LOADED_AT, never an UPDATE.',
    LOADED_BY                     VARCHAR NOT NULL,
    CONSTRAINT PK_TRANSACTION_REPORTS PRIMARY KEY (REPORT_ID, JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW TRANSACTION_REPORTS_CURRENT AS
SELECT *
FROM TRANSACTION_REPORTS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY REPORT_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;
