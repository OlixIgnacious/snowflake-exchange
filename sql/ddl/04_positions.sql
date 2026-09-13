-- POSITIONS. Spec: docs/canonical_schema_contract.md v7, "Core tables" > POSITIONS.
-- No VENUE_ID -- deliberate: a concentration/exposure limit is a cross-venue total (Fix #4).
-- Accumulates from TRADES only, never ORDERS. Corporate-actions adjustment explicitly deferred
-- (Fix #4), not silently ignored -- see plan.md backlog.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS POSITIONS (
    PARTICIPANT_ID   VARCHAR NOT NULL,
    INSTRUMENT_ID    VARCHAR NOT NULL,
    JURISDICTION_ID  VARCHAR NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    AS_OF_DATE       DATE NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #4. A restatement for a given AS_OF_DATE is a new row with a later LOADED_AT, never an UPDATE.',
    LOADED_BY        VARCHAR NOT NULL,
    NET_QUANTITY     NUMBER
        COMMENT 'Cumulative signed sum of TRADES.VOLUME through AS_OF_DATE, roll-forward from the prior AS_OF_DATE snapshot -- never derived from ORDERS (Fix #4).',
    MARKET_VALUE     NUMBER,
    CURRENCY         VARCHAR(8) NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    CREATED_AT       TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE) snapshot was first loaded; carried forward on every later restatement of the same AS_OF_DATE.',
    CREATED_BY       VARCHAR NOT NULL,
    CONSTRAINT PK_POSITIONS PRIMARY KEY (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE, LOADED_AT)
);

-- POSITIONS_CURRENT: latest LOADED_AT per (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID,
-- AS_OF_DATE). Not explicitly named in the contract's POSITIONS section, but required by
-- Milestoning discipline rule 5 ("every table gets one generic <TABLE>_CURRENT view, no
-- exceptions") and matches the "consumers read the row with the max LOADED_AT" language there.
CREATE OR REPLACE VIEW POSITIONS_CURRENT AS
SELECT *
FROM POSITIONS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE
    ORDER BY LOADED_AT DESC
) = 1;
