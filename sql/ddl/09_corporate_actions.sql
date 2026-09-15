-- CORPORATE_ACTIONS + POSITIONS_ADJUSTED. Closes review finding "no corporate-actions handling
-- for POSITIONS" (04_positions.sql: "Corporate-actions adjustment explicitly deferred (Fix #4),
-- not silently ignored -- see plan.md backlog") -- flagged since Fix #4, never built until now.
--
-- CORPORATE_ACTIONS is its own table, not a column bolted onto POSITIONS/INSTRUMENTS -- a
-- corporate action is an event on an instrument, independent of any one participant's position,
-- and (like everything else here) needs its own milestoning history if a wrongly-recorded ratio
-- is later corrected.
--
-- POSITIONS_ADJUSTED (new view, alongside POSITIONS_CURRENT, not replacing it): for a given
-- (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE) snapshot, computes the cumulative
-- product of every split/merger RATIO whose EFFECTIVE_DATE is strictly after that AS_OF_DATE --
-- standard corporate-actions continuity practice: a pre-split quantity is scaled UP so it's
-- comparable, in current-share terms, to a post-split quantity, without ever mutating the
-- original POSITIONS row (append-only discipline stays intact; POSITIONS_CURRENT keeps meaning
-- exactly what it always meant -- the raw accumulated quantity as of that date).
-- EXP(SUM(LN(RATIO))) computes the product of however many stacked corporate actions apply
-- (Snowflake has no PRODUCT() aggregate) -- correct for one action or several; RATIO is always
-- positive (a split/merger ratio, never zero or negative), so LN is always defined.
-- Delisting is tracked (ACTION_TYPE) but doesn't get a RATIO-based quantity adjustment -- a
-- delisted instrument's position is a status fact, not a share-count conversion.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS CORPORATE_ACTIONS (
    JURISDICTION_ID  VARCHAR NOT NULL
        COMMENT 'No default -- market-agnostic rule #1.',
    INSTRUMENT_ID    VARCHAR NOT NULL,
    ACTION_TYPE      VARCHAR NOT NULL
        COMMENT 'split / merger / delisting.',
    RATIO            NUMBER
        COMMENT 'New units per old unit (e.g. 2.0 for a 2-for-1 split). NULL for delisting, which has no share-count conversion.',
    EFFECTIVE_DATE   DATE NOT NULL,
    CREATED_AT       TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this corporate action was first recorded; carried forward through any later correction.',
    CREATED_BY       VARCHAR NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'A corrected RATIO/EFFECTIVE_DATE is a new row, same (JURISDICTION_ID, INSTRUMENT_ID, ACTION_TYPE, EFFECTIVE_DATE), later LOADED_AT -- never an UPDATE.',
    LOADED_BY        VARCHAR NOT NULL,
    CONSTRAINT PK_CORPORATE_ACTIONS PRIMARY KEY (JURISDICTION_ID, INSTRUMENT_ID, ACTION_TYPE, EFFECTIVE_DATE, LOADED_AT)
);

CREATE OR REPLACE VIEW CORPORATE_ACTIONS_CURRENT AS
SELECT *
FROM CORPORATE_ACTIONS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY JURISDICTION_ID, INSTRUMENT_ID, ACTION_TYPE, EFFECTIVE_DATE
    ORDER BY LOADED_AT DESC
) = 1;

CREATE OR REPLACE VIEW POSITIONS_ADJUSTED AS
WITH ADJUSTMENT_FACTOR AS (
    SELECT
        p.PARTICIPANT_ID, p.INSTRUMENT_ID, p.JURISDICTION_ID, p.AS_OF_DATE,
        COALESCE(EXP(SUM(LN(ca.RATIO))), 1) AS ADJUSTMENT_FACTOR
    FROM POSITIONS_CURRENT p
    LEFT JOIN CORPORATE_ACTIONS_CURRENT ca
        ON ca.JURISDICTION_ID = p.JURISDICTION_ID
       AND ca.INSTRUMENT_ID = p.INSTRUMENT_ID
       AND ca.ACTION_TYPE IN ('split', 'merger')
       AND ca.EFFECTIVE_DATE > p.AS_OF_DATE
    GROUP BY p.PARTICIPANT_ID, p.INSTRUMENT_ID, p.JURISDICTION_ID, p.AS_OF_DATE
)
SELECT
    p.*,
    af.ADJUSTMENT_FACTOR,
    p.NET_QUANTITY * af.ADJUSTMENT_FACTOR AS NET_QUANTITY_ADJUSTED
FROM POSITIONS_CURRENT p
JOIN ADJUSTMENT_FACTOR af
    ON af.PARTICIPANT_ID = p.PARTICIPANT_ID AND af.INSTRUMENT_ID = p.INSTRUMENT_ID
   AND af.JURISDICTION_ID = p.JURISDICTION_ID AND af.AS_OF_DATE = p.AS_OF_DATE;

GRANT SELECT ON VIEW CORPORATE_ACTIONS_CURRENT TO ROLE ANALYST_READ;
GRANT SELECT ON VIEW POSITIONS_ADJUSTED TO ROLE ANALYST_READ;
