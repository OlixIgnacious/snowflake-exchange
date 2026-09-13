-- ORDERS -- event-sourced as of Fix #16: one row per order EVENT (new/modify/partial_fill/
-- fill/cancel), not one mutable row per order. Spec: docs/canonical_schema_contract.md v7,
-- "Core tables" > ORDERS.
--
-- FK note: JURISDICTION_ID/VENUE_ID/INSTRUMENT_ID/PARTICIPANT_ID all target milestoned parents
-- (LOADED_AT in their PK) -- documented via COMMENT, not declared, per 01_reference_data.sql's
-- file header rationale.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS ORDERS (
    ORDER_ID               VARCHAR NOT NULL
        COMMENT 'Stable across every event for the same order.',
    JURISDICTION_ID        VARCHAR NOT NULL
        COMMENT 'Logical FK -> JURISDICTIONS. No default (market-agnostic rule #1).',
    VENUE_ID               VARCHAR NOT NULL
        COMMENT 'Logical FK -> VENUES. Where the order was submitted. No default (market-agnostic rule #1).',
    INSTRUMENT_ID           VARCHAR NOT NULL
        COMMENT 'Logical FK -> INSTRUMENTS (+ JURISDICTION_ID).',
    PARTICIPANT_ID         VARCHAR NOT NULL
        COMMENT 'Logical FK -> MARKET_PARTICIPANTS (+ JURISDICTION_ID).',
    SIDE                   VARCHAR
        COMMENT 'buy / sell.',
    ORDER_TYPE             VARCHAR
        COMMENT 'limit / market / etc.',
    EVENT_TYPE             VARCHAR NOT NULL
        COMMENT 'Fix #16. new / modify / partial_fill / fill / cancel.',
    EVENT_TS               TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #16, replaces SUBMITTED_TS/MODIFIED_TS/CANCELLED_TS. Timestamp of this specific event -- the new event''s EVENT_TS is the order''s submission time.',
    PRICE                  NUMBER
        COMMENT 'As of this event.',
    CURRENCY               VARCHAR(8) NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    QUANTITY               NUMBER
        COMMENT 'As of this event -- a modify event can change it.',
    FILLED_QUANTITY        NUMBER
        COMMENT 'Cumulative-as-of-this-event quantity, adaptor-supplied. 0 if never filled.',
    REGULATORY_ATTRIBUTES  VARIANT
        COMMENT 'Fix #26. Catch-all for jurisdiction-specific, detector-irrelevant regulatory fields (e.g. algo-trading flag) -- same pattern as DETECTOR_CALIBRATION.PARAMS (Fix #2), not a named nullable column per jurisdiction.',
    CREATED_AT             TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this ORDER_ID was first created (the new event); carried forward unchanged on every later event row for the same order.',
    CREATED_BY             VARCHAR NOT NULL,
    LOADED_AT              TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this event row was written to the warehouse -- distinct from EVENT_TS (the business event time reported by the venue feed), since an adaptor can backfill or replay events late.',
    LOADED_BY              VARCHAR NOT NULL,
    CONSTRAINT PK_ORDERS PRIMARY KEY (ORDER_ID, VENUE_ID, EVENT_TS)
);

-- ORDERS_CURRENT = latest EVENT_TS row per (ORDER_ID, VENUE_ID). This is what POSITIONS/
-- reporting/detectors read for an order's present state. Never a source for POSITIONS (Fix #4)
-- -- an order, filled or not, is not itself an economic position; only its resulting TRADES rows
-- are. Spoofing/layering reads this view WHERE EVENT_TYPE = 'cancel' AND FILLED_QUANTITY < QUANTITY
-- for cancelled-unfilled volume.
CREATE OR REPLACE VIEW ORDERS_CURRENT AS
SELECT *
FROM ORDERS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ORDER_ID, VENUE_ID
    ORDER BY EVENT_TS DESC
) = 1;
