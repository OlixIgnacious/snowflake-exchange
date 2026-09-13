-- DETECTOR_CALIBRATION. Spec: docs/canonical_schema_contract.md v7, "Core tables" >
-- DETECTOR_CALIBRATION. This table exists BEFORE any detector view (sql/detectors/, Phase 3) --
-- every detector, statistical or pattern-match, reads its tunables from here; none embeds a
-- literal (market-agnostic design rule #3).
--
-- PK note: unlike every other table in this schema, the contract does not give
-- DETECTOR_CALIBRATION a composite natural-key-plus-LOADED_AT PK. CALIBRATION_ID is a NUMBER
-- AUTOINCREMENT surrogate key that already makes every recalibration row unique and insert-order
-- traceable -- it satisfies Milestoning discipline rule 2's intent (multiple versions coexist as
-- distinct rows) by a different mechanism than the composite-PK convention used elsewhere, not by
-- omission. Recalibration is still purely additive: a new row, never an UPDATE.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS DETECTOR_CALIBRATION (
    CALIBRATION_ID       NUMBER AUTOINCREMENT,
    JURISDICTION_ID      VARCHAR NOT NULL
        COMMENT 'No default -- market-agnostic design rule #1.',
    VENUE_ID             VARCHAR
        COMMENT 'Nullable -- some detectors calibrate per venue (spoofing/layering cancel-rate), others per jurisdiction regardless of venue (concentration limits, a cross-venue total). NULL means "applies across all venues in this jurisdiction."',
    DETECTOR_NAME        VARCHAR NOT NULL,
    DIMENSION_KEY        VARCHAR
        COMMENT 'e.g. instrument, participant class.',
    Z_THRESHOLD          FLOAT
        COMMENT 'Statistical detectors only; NULL for rules-based or pattern-match ones.',
    MIN_BASELINE_PERIODS NUMBER
        COMMENT 'Statistical detectors only.',
    PARAMS               VARIANT
        COMMENT 'Fix #2. Arbitrary detector-specific parameters for pattern-match/rules-based detectors, e.g. wash trading''s {"time_window_seconds": 30, "price_tolerance_pct": 0.001} and its MATCHING_MECHANISM exemption list (Fix #20). Every detector reads its tunables from this table -- no detector embeds a literal.',
    IS_PROVISIONAL       BOOLEAN NOT NULL
        COMMENT 'Cold-start default flag for a jurisdiction/venue/participant with insufficient history.',
    EFFECTIVE_FROM       TIMESTAMP_NTZ NOT NULL,
    CALIBRATED_AT        TIMESTAMP_NTZ NOT NULL,
    CALIBRATION_METHOD   VARCHAR
        COMMENT 'default-uncalibrated / percentile-historical / manual-override.',
    CALIBRATED_BY        VARCHAR NOT NULL
        COMMENT 'Companion to the pre-existing CALIBRATED_AT, naming kept consistent with it rather than renamed to LOADED_BY.',
    CREATED_AT           TIMESTAMP_NTZ NOT NULL
        COMMENT 'When calibration for this (JURISDICTION_ID, VENUE_ID, DETECTOR_NAME, DIMENSION_KEY) combination was first set; carried forward through every later recalibration.',
    CREATED_BY           VARCHAR NOT NULL,
    CONSTRAINT PK_DETECTOR_CALIBRATION PRIMARY KEY (CALIBRATION_ID)
);

-- DETECTOR_CALIBRATION_CURRENT: latest EFFECTIVE_FROM per (JURISDICTION_ID, VENUE_ID,
-- DETECTOR_NAME, DIMENSION_KEY). Every detector view (sql/detectors/) joins this, not the base
-- table, unless it deliberately needs calibration history.
CREATE OR REPLACE VIEW DETECTOR_CALIBRATION_CURRENT AS
SELECT *
FROM DETECTOR_CALIBRATION
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JURISDICTION_ID, VENUE_ID, DETECTOR_NAME, DIMENSION_KEY
    ORDER BY EFFECTIVE_FROM DESC
) = 1;
