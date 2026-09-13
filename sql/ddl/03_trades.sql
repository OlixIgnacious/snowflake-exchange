-- TRADES + companions (TRADE_CORRECTIONS, TRADE_REFERENCE_PRICES).
-- Spec: docs/canonical_schema_contract.md v7, "Core tables" > TRADES / TRADE_CORRECTIONS /
-- TRADE_REFERENCE_PRICES.
--
-- TRADES itself is immutable (PK does NOT include LOADED_AT -- a trade print is a fact, not
-- corrected in place) and deliberately has NO <TABLE>_CURRENT view: CREATED_AT = LOADED_AT on
-- every row by construction (Fix #19), since no entity here ever gets a second version. A
-- bust/amendment goes to TRADE_CORRECTIONS instead. TRADE_CORRECTIONS itself also has no
-- _CURRENT view -- each correction row is its own immutable event; a second correction to the
-- same trade is a new, distinct row, not a version of the first (per the contract's own note).
--
-- FK note: TRADES(TRADE_ID, VENUE_ID) is a genuine, non-milestoned unique key, so
-- TRADE_CORRECTIONS/TRADE_REFERENCE_PRICES can and do declare a real FK against it.
-- JURISDICTION_ID/INSTRUMENT_ID/PARTICIPANT_ID/ORDER_ID target milestoned parents and stay
-- documented-only, per 01_reference_data.sql's file header rationale.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- TRADES
-- ============================================================================
CREATE TABLE IF NOT EXISTS TRADES (
    TRADE_ID                       VARCHAR NOT NULL,
    JURISDICTION_ID                VARCHAR NOT NULL
        COMMENT 'Logical FK -> JURISDICTIONS. No default (market-agnostic rule #1).',
    VENUE_ID                       VARCHAR NOT NULL
        COMMENT 'Logical FK -> VENUES. Where the trade printed. No default (market-agnostic rule #1).',
    ORDER_ID                       VARCHAR
        COMMENT 'Nullable -- some venue feeds report executions without order linkage (real per-venue adaptor variance, not assumed away). Contributes to WASH_DETECTION_COVERAGE (Fix #3) when null alongside a null COUNTERPARTY_PARTICIPANT_ID.',
    INSTRUMENT_ID                  VARCHAR NOT NULL,
    EXECUTION_TIMESTAMP            TIMESTAMP_NTZ NOT NULL,
    PRICE                          NUMBER NOT NULL,
    CURRENCY                       VARCHAR(8) NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    VOLUME                         NUMBER NOT NULL,
    PARTICIPANT_ID                 VARCHAR NOT NULL
        COMMENT 'The reporting side.',
    COUNTERPARTY_PARTICIPANT_ID    VARCHAR
        COMMENT 'Nullable -- not every venue discloses the other side. Contributes to WASH_DETECTION_COVERAGE (Fix #3) when null alongside a null ORDER_ID.',
    MATCHING_MECHANISM             VARCHAR NOT NULL
        COMMENT 'Fix #20. continuous / cross / block / auction. Which mechanisms are exempt from the wash-trading pattern-match trigger (and under what disclosure condition) is read from DETECTOR_CALIBRATION.PARAMS, never hardcoded. A cross trade is exempt from the trigger only, not from WASH_DETECTION_COVERAGE or downstream review.',
    REGULATORY_ATTRIBUTES          VARIANT
        COMMENT 'Fix #26. Catch-all for jurisdiction-specific, detector-irrelevant regulatory fields (LEI, trading capacity, short-sell flag, etc.) -- same pattern as DETECTOR_CALIBRATION.PARAMS (Fix #2).',
    CREATED_AT                     TIMESTAMP_NTZ NOT NULL
        COMMENT 'Equal to LOADED_AT on every row -- a trade print never gets a second version (corrections go to TRADE_CORRECTIONS).',
    CREATED_BY                     VARCHAR NOT NULL,
    LOADED_AT                      TIMESTAMP_NTZ NOT NULL
        COMMENT 'When the print was written to the warehouse -- distinct from EXECUTION_TIMESTAMP (the venue''s own execution time).',
    LOADED_BY                      VARCHAR NOT NULL,
    CONSTRAINT PK_TRADES PRIMARY KEY (TRADE_ID, VENUE_ID)
);

-- ============================================================================
-- TRADE_CORRECTIONS (new, Fix #15)
-- ============================================================================
CREATE TABLE IF NOT EXISTS TRADE_CORRECTIONS (
    TRADE_ID          VARCHAR NOT NULL,
    VENUE_ID          VARCHAR NOT NULL,
    CORRECTION_TYPE   VARCHAR NOT NULL
        COMMENT 'bust / amend.',
    CORRECTED_FIELDS  VARIANT
        COMMENT 'For amend, the corrected field values; null/empty for bust.',
    CREATED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'Equal to LOADED_AT -- each correction row is its own immutable event (a second correction to the same trade is a new, distinct row, not a version of this one).',
    CREATED_BY        VARCHAR NOT NULL,
    LOADED_AT         TIMESTAMP_NTZ NOT NULL,
    LOADED_BY         VARCHAR NOT NULL,
    CONSTRAINT PK_TRADE_CORRECTIONS PRIMARY KEY (TRADE_ID, VENUE_ID, LOADED_AT),
    CONSTRAINT FK_TRADE_CORRECTIONS_TRADES FOREIGN KEY (TRADE_ID, VENUE_ID)
        REFERENCES TRADES (TRADE_ID, VENUE_ID)
);

-- Note: POSITIONS accumulation and every detector must anti-join against the latest correction
-- row per trade (max LOADED_AT per TRADE_ID/VENUE_ID) before treating a TRADES row as live -- a
-- busted trade is surfaced, not silently hidden (Fix #3/#15 discipline). Enforced in the
-- consuming views (sql/detectors/), not here.

-- ============================================================================
-- TRADE_REFERENCE_PRICES (new, Fix #5)
-- ============================================================================
CREATE TABLE IF NOT EXISTS TRADE_REFERENCE_PRICES (
    TRADE_ID                        VARCHAR NOT NULL,
    VENUE_ID                        VARCHAR NOT NULL,
    REFERENCE_PRICE_AT_EXECUTION    NUMBER
        COMMENT 'Nullable -- populated only where a venue publishes an NBBO-equivalent; genuinely absent for some venues, not an adaptor failure. Drives EXECUTION_SLIPPAGE.',
    REFERENCE_PRICE_AT_ARRIVAL      NUMBER
        COMMENT 'Nullable, same caveat. Drives ARRIVAL_SLIPPAGE, compared against the order''s new-event EVENT_TS in ORDERS (the original submission, not necessarily the latest event in ORDERS_CURRENT).',
    CURRENCY                        VARCHAR(8) NOT NULL,
    SOURCE                          VARCHAR
        COMMENT 'Which reference-price feed/adaptor populated this row.',
    CREATED_AT                      TIMESTAMP_NTZ NOT NULL
        COMMENT 'When a reference price for this (TRADE_ID, VENUE_ID) was first recorded; carried forward on a later backfill/restatement.',
    CREATED_BY                      VARCHAR NOT NULL,
    LOADED_AT                       TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #15. A late-arriving or restated reference price is a new row, never an UPDATE.',
    LOADED_BY                       VARCHAR NOT NULL,
    CONSTRAINT PK_TRADE_REFERENCE_PRICES PRIMARY KEY (TRADE_ID, VENUE_ID, LOADED_AT),
    CONSTRAINT FK_TRADE_REFERENCE_PRICES_TRADES FOREIGN KEY (TRADE_ID, VENUE_ID)
        REFERENCES TRADES (TRADE_ID, VENUE_ID)
);

CREATE OR REPLACE VIEW TRADE_REFERENCE_PRICES_CURRENT AS
SELECT *
FROM TRADE_REFERENCE_PRICES
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY TRADE_ID, VENUE_ID
    ORDER BY LOADED_AT DESC
) = 1;
