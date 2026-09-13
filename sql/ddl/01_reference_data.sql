-- Reference data: JURISDICTIONS, VENUES, BENEFICIAL_OWNERS, INSTRUMENTS, MARKET_PARTICIPANTS.
-- Spec: docs/canonical_schema_contract.md v7, "Reference tables" + "Core tables" (INSTRUMENTS,
-- MARKET_PARTICIPANTS). Every table here is milestoned per Fix #11/#19: CREATED_AT/CREATED_BY/
-- LOADED_AT/LOADED_BY on every row, LOADED_AT in the PK, one generic <TABLE>_CURRENT view.
--
-- FK note: every cross-reference in this file targets a milestoned parent (its PK includes
-- LOADED_AT), so a real declarative FOREIGN KEY isn't expressible in Snowflake — it requires the
-- referenced columns to carry a standalone UNIQUE/PK constraint, and adding one on the natural
-- key alone would forbid the multiple LOADED_AT versions milestoning depends on. Relationships
-- are documented via COMMENT instead, same treatment the contract already gives
-- OBLIGATION_MAP.SOURCE_TABLE/SOURCE_COLUMNS (unenforceable in SQL, validated elsewhere).
--
-- Run interactively by a human — never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- JURISDICTIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS JURISDICTIONS (
    JURISDICTION_ID   VARCHAR NOT NULL
        COMMENT 'e.g. JP, US. No default — no implicit single-jurisdiction assumption (market-agnostic rule #1).',
    REGULATOR_NAME    VARCHAR
        COMMENT 'e.g. "FSA/SESC", "SEC".',
    PRIMARY_LANGUAGE  VARCHAR
        COMMENT 'Drives RULE_CORPUS.ORIGINAL_LANGUAGE default expectation, not an override of the per-row field.',
    CREATED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #19. When this JURISDICTION_ID was first created; carried forward unchanged on every later version.',
    CREATED_BY        VARCHAR NOT NULL,
    LOADED_AT         TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #11. A change (e.g. regulator renamed) is a new row with a later LOADED_AT, never an UPDATE.',
    LOADED_BY         VARCHAR NOT NULL,
    CONSTRAINT PK_JURISDICTIONS PRIMARY KEY (JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW JURISDICTIONS_CURRENT AS
SELECT *
FROM JURISDICTIONS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- VENUES
-- ============================================================================
CREATE TABLE IF NOT EXISTS VENUES (
    VENUE_ID          VARCHAR NOT NULL
        COMMENT 'e.g. XTKS, XOSE, TOCOM, JPNX, ODX, ODXST, CBOJ, CBOJBIDS.',
    JURISDICTION_ID   VARCHAR NOT NULL
        COMMENT 'Logical FK -> JURISDICTIONS.JURISDICTION_ID (not a declared FK; parent is milestoned, see file header).',
    VENUE_NAME        VARCHAR,
    VENUE_TYPE        VARCHAR
        COMMENT 'exchange / pts / otc_facility / block_trading.',
    OPERATOR_NAME     VARCHAR,
    STATUS            VARCHAR NOT NULL DEFAULT 'active'
        COMMENT 'active / discontinued.',
    ACTIVE_FROM       DATE
        COMMENT 'Nullable when a venue''s founding date isn''t confirmed live -- do not guess a placeholder date.',
    DISCONTINUED_AT   DATE
        COMMENT 'NULL while STATUS = active. A generator/adaptor must never produce ORDERS/TRADES for this venue dated after this value -- STATUS alone cannot support a discontinued venue''s real historical trades (v4 fix).',
    CREATED_AT        TIMESTAMP_NTZ NOT NULL,
    CREATED_BY        VARCHAR NOT NULL,
    LOADED_AT         TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #10. A STATUS transition (active -> discontinued) is a new row, same VENUE_ID, later LOADED_AT -- never an UPDATE.',
    LOADED_BY         VARCHAR NOT NULL,
    CONSTRAINT PK_VENUES PRIMARY KEY (VENUE_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW VENUES_CURRENT AS
SELECT *
FROM VENUES
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY VENUE_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- BENEFICIAL_OWNERS (new, Fix #8)
-- ============================================================================
CREATE TABLE IF NOT EXISTS BENEFICIAL_OWNERS (
    BENEFICIAL_OWNER_ID  VARCHAR NOT NULL
        COMMENT 'Independent identifier space -- not assumed to equal any MARKET_PARTICIPANTS.PARTICIPANT_ID (Fix #8).',
    JURISDICTION_ID      VARCHAR NOT NULL
        COMMENT 'Logical FK -> JURISDICTIONS.JURISDICTION_ID (not declared, see file header).',
    OWNER_NAME           VARCHAR,
    OWNER_TYPE           VARCHAR
        COMMENT 'individual / corporate / fund, etc.',
    CREATED_AT           TIMESTAMP_NTZ NOT NULL,
    CREATED_BY           VARCHAR NOT NULL,
    LOADED_AT            TIMESTAMP_NTZ NOT NULL
        COMMENT 'A restructuring/correction is a new row, never an UPDATE.',
    LOADED_BY            VARCHAR NOT NULL,
    CONSTRAINT PK_BENEFICIAL_OWNERS PRIMARY KEY (BENEFICIAL_OWNER_ID, JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW BENEFICIAL_OWNERS_CURRENT AS
SELECT *
FROM BENEFICIAL_OWNERS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY BENEFICIAL_OWNER_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- INSTRUMENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS INSTRUMENTS (
    INSTRUMENT_ID    VARCHAR NOT NULL
        COMMENT 'Issuer/venue-local code. Not globally unique across jurisdictions -- paired with JURISDICTION_ID.',
    JURISDICTION_ID  VARCHAR NOT NULL
        COMMENT 'The primary-listing jurisdiction. Logical FK -> JURISDICTIONS (not declared, see file header). Scoped by jurisdiction, not venue -- the same TSE-listed stock also trades on Japannext PTS under one instrument identity.',
    ISIN             VARCHAR
        COMMENT 'Nullable -- not every market assigns one.',
    INSTRUMENT_TYPE  VARCHAR
        COMMENT 'e.g. equity, derivative, bond, security token.',
    TICK_SIZE        NUMBER,
    LOT_SIZE         NUMBER,
    CREATED_AT       TIMESTAMP_NTZ NOT NULL,
    CREATED_BY       VARCHAR NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'A TICK_SIZE/LOT_SIZE change (an exchange rule change, not a typo fix) is a new row, never an UPDATE.',
    LOADED_BY        VARCHAR NOT NULL,
    CONSTRAINT PK_INSTRUMENTS PRIMARY KEY (INSTRUMENT_ID, JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW INSTRUMENTS_CURRENT AS
SELECT *
FROM INSTRUMENTS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY INSTRUMENT_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- MARKET_PARTICIPANTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS MARKET_PARTICIPANTS (
    PARTICIPANT_ID       VARCHAR NOT NULL,
    JURISDICTION_ID      VARCHAR NOT NULL
        COMMENT 'Logical FK -> JURISDICTIONS (not declared, see file header). A participant is registered per jurisdiction (e.g. broker membership with Japan''s FSA), and may be a member of multiple venues within it.',
    PARTICIPANT_TYPE     VARCHAR
        COMMENT 'broker / proprietary / institutional / retail.',
    BENEFICIAL_OWNER_ID  VARCHAR
        COMMENT 'Nullable when genuinely unknown. Logical FK -> BENEFICIAL_OWNERS (+ JURISDICTION_ID), NOT self-referencing PARTICIPANT_ID (Fix #8).',
    CREATED_AT           TIMESTAMP_NTZ NOT NULL,
    CREATED_BY           VARCHAR NOT NULL,
    LOADED_AT            TIMESTAMP_NTZ NOT NULL
        COMMENT 'A reclassification or beneficial-owner change is a new row, never an UPDATE.',
    LOADED_BY            VARCHAR NOT NULL,
    CONSTRAINT PK_MARKET_PARTICIPANTS PRIMARY KEY (PARTICIPANT_ID, JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW MARKET_PARTICIPANTS_CURRENT AS
SELECT *
FROM MARKET_PARTICIPANTS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY PARTICIPANT_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;
