-- OTC-derivatives scoped MVP closing gap 8's field-citation fix for real: LEI-based counterparty
-- identification, one instrument-level product-attributes table, and one trade-level economics
-- table, so REPORT_TEMPLATES' 138-field JP/otc_derivative_transaction_report has real sourced
-- fields beyond the original 3 (Execution timestamp/Price/Price currency). Deliberately does NOT
-- add valuation/margin/collateral (fields 39-63) -- that needs a genuine mark-to-market/
-- collateral-posting model, out of scope for this pass (explicit, user-confirmed scope decision).
--
-- MARKET_PARTICIPANTS.LEI: nullable -- not every participant trades an OTC derivative, so not
-- every participant needs a Legal Entity Identifier. A milestoned ALTER ADD COLUMN, same pattern
-- as every other schema evolution here: existing rows get NULL, a participant later assigned an
-- LEI gets a new row (same PARTICIPANT_ID/JURISDICTION_ID, later LOADED_AT) -- never an UPDATE.
--
-- DERIVATIVE_PRODUCT_ATTRIBUTES: instrument-level (asset class, contract type, underlying,
-- product identifier, delivery type) -- one row per (INSTRUMENT_ID, JURISDICTION_ID), logical FK
-- to INSTRUMENTS (undeclared -- milestoned parent, see 01_reference_data.sql's file header).
--
-- DERIVATIVE_TRADE_DETAILS: trade-level economics (UTI, notional, fixed rate, day count, payment
-- frequency, effective/maturity dates, direction, counterparty-2 identifier type). Real FK to
-- TRADES(TRADE_ID, VENUE_ID) -- that's a genuine non-milestoned unique key (see 03_trades.sql's
-- file header) -- milestoned itself via LOADED_AT, same pattern as TRADE_REFERENCE_PRICES, since
-- a later restatement of a swap's own reported economics is realistic (e.g. a fixing correction).
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

ALTER TABLE MARKET_PARTICIPANTS ADD COLUMN IF NOT EXISTS LEI VARCHAR(20)
    COMMENT 'ISO 17442 Legal Entity Identifier. Nullable -- only participants party to an OTC derivative trade need one. A synthetic dataset''s LEI here is a synthetic-but-correctly-shaped value, never a real registered LOU identifier.';

-- A `CREATE VIEW ... AS SELECT *` binds its column list at creation time (verified live --
-- ALTER TABLE ADD COLUMN alone left MARKET_PARTICIPANTS_CURRENT declaring 8 columns while its
-- underlying SELECT * now produces 9, erroring "View definition ... declared 8 column(s), but
-- view query produces 9 column(s)" on every subsequent read). Re-declaring the view is required
-- after every column addition to MARKET_PARTICIPANTS, not just this one -- noted here since this
-- is where it was first hit.
CREATE OR REPLACE VIEW MARKET_PARTICIPANTS_CURRENT AS
SELECT *
FROM MARKET_PARTICIPANTS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY PARTICIPANT_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- DERIVATIVE_PRODUCT_ATTRIBUTES
-- ============================================================================
CREATE TABLE IF NOT EXISTS DERIVATIVE_PRODUCT_ATTRIBUTES (
    INSTRUMENT_ID       VARCHAR NOT NULL
        COMMENT 'Logical FK -> INSTRUMENTS (+ JURISDICTION_ID), where INSTRUMENT_TYPE = derivative.',
    JURISDICTION_ID      VARCHAR NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    UPI                  VARCHAR
        COMMENT 'Unique Product Identifier (DSB-format-shaped). Nullable -- not every derivative product has one sourced yet.',
    ASSET_CLASS           VARCHAR NOT NULL
        COMMENT 'CDE asset class, e.g. Interest Rate / Credit / FX / Equity / Commodity.',
    CONTRACT_TYPE         VARCHAR NOT NULL
        COMMENT 'e.g. Swap / Forward / Option.',
    UNDERLYING_ID_TYPE    VARCHAR
        COMMENT 'e.g. "Reference rate name" for a rate swap, "ISIN" for a single-name product.',
    UNDERLYING_ID         VARCHAR
        COMMENT 'The underlying itself, e.g. a real published reference rate name.',
    DELIVERY_TYPE         VARCHAR
        COMMENT 'Cash / Physical.',
    CREATED_AT            TIMESTAMP_NTZ NOT NULL,
    CREATED_BY            VARCHAR NOT NULL,
    LOADED_AT             TIMESTAMP_NTZ NOT NULL
        COMMENT 'A corrected product attribute is a new row, same (INSTRUMENT_ID, JURISDICTION_ID), later LOADED_AT -- never an UPDATE.',
    LOADED_BY             VARCHAR NOT NULL,
    CONSTRAINT PK_DERIVATIVE_PRODUCT_ATTRIBUTES PRIMARY KEY (INSTRUMENT_ID, JURISDICTION_ID, LOADED_AT)
);

CREATE OR REPLACE VIEW DERIVATIVE_PRODUCT_ATTRIBUTES_CURRENT AS
SELECT *
FROM DERIVATIVE_PRODUCT_ATTRIBUTES
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY INSTRUMENT_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- ============================================================================
-- DERIVATIVE_TRADE_DETAILS
-- ============================================================================
CREATE TABLE IF NOT EXISTS DERIVATIVE_TRADE_DETAILS (
    TRADE_ID                        VARCHAR NOT NULL,
    VENUE_ID                        VARCHAR NOT NULL,
    UTI                              VARCHAR NOT NULL
        COMMENT 'Unique Transaction Identifier (CPMI-IOSCO shape: generating entity''s LEI + a unique code). Synthetic here, same discipline as MARKET_PARTICIPANTS.LEI.',
    EFFECTIVE_DATE                   DATE NOT NULL,
    MATURITY_DATE                    DATE NOT NULL,
    NOTIONAL_AMOUNT                  NUMBER(20,2) NOT NULL
        COMMENT 'Explicit precision/scale -- bare NUMBER defaults to NUMBER(38,0) (verified live: TRADES.PRICE/VOLUME and every other bare-NUMBER column in this schema are silently integer-only as a result, a real pre-existing platform-wide gap this file does not attempt to fix retroactively -- flagged, not silently repeated here).',
    NOTIONAL_CURRENCY                VARCHAR(8) NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    FIXED_RATE                       NUMBER(9,6)
        COMMENT 'Nullable -- not every product shape has a fixed leg (e.g. a basis swap). Explicit precision/scale, see NOTIONAL_AMOUNT''s comment -- a bare NUMBER here would silently truncate e.g. 0.0075 to 0.',
    DAY_COUNT_CONVENTION              VARCHAR
        COMMENT 'e.g. ACT/365F, 30/360.',
    PAYMENT_FREQUENCY_PERIOD          VARCHAR
        COMMENT 'ISO 20022-style period code, e.g. YEAR / MNTH / QUTR.',
    PAYMENT_FREQUENCY_MULTIPLIER      NUMBER,
    REPORTING_PARTY_DIRECTION         VARCHAR NOT NULL
        COMMENT 'payer / receiver -- of the fixed leg, from the reporting counterparty''s side.',
    COUNTERPARTY_2_ID_TYPE            VARCHAR NOT NULL DEFAULT 'LEI'
        COMMENT 'Identifier-type tag for the counterparty side of the trade -- LEI is the only identifier scheme this schema currently supports.',
    CREATED_AT                        TIMESTAMP_NTZ NOT NULL,
    CREATED_BY                        VARCHAR NOT NULL,
    LOADED_AT                         TIMESTAMP_NTZ NOT NULL
        COMMENT 'A restated economics field (e.g. a fixing correction) is a new row, never an UPDATE.',
    LOADED_BY                         VARCHAR NOT NULL,
    CONSTRAINT PK_DERIVATIVE_TRADE_DETAILS PRIMARY KEY (TRADE_ID, VENUE_ID, LOADED_AT),
    CONSTRAINT FK_DERIVATIVE_TRADE_DETAILS_TRADES FOREIGN KEY (TRADE_ID, VENUE_ID)
        REFERENCES TRADES (TRADE_ID, VENUE_ID)
);

CREATE OR REPLACE VIEW DERIVATIVE_TRADE_DETAILS_CURRENT AS
SELECT *
FROM DERIVATIVE_TRADE_DETAILS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY TRADE_ID, VENUE_ID
    ORDER BY LOADED_AT DESC
) = 1;

GRANT SELECT ON VIEW DERIVATIVE_PRODUCT_ATTRIBUTES_CURRENT TO ROLE ANALYST_READ;
GRANT SELECT ON VIEW DERIVATIVE_TRADE_DETAILS_CURRENT TO ROLE ANALYST_READ;
