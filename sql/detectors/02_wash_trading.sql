-- Wash trading (market conduct). Spec: architecture.md "Detectors" section + contract Fix #2,
-- #3, #20. Pattern-match, not statistical -- every tunable (time window, price tolerance, which
-- MATCHING_MECHANISM values are exempt from the trigger) is read from
-- DETECTOR_CALIBRATION_CURRENT.PARAMS, never hardcoded (market-agnostic rule #3). Expected
-- PARAMS shape per (JURISDICTION_ID, VENUE_ID, DETECTOR_NAME='wash_trading'):
--   {"time_window_seconds": 30, "price_tolerance_pct": 0.001, "exempt_matching_mechanisms": ["cross"]}
--
-- Two candidate shapes, unioned:
--   (a) same-row self-trade: PARTICIPANT_ID and COUNTERPARTY_PARTICIPANT_ID on one TRADES row
--       resolve to the same BENEFICIAL_OWNER_ID.
--   (b) cross-row matched pair: two TRADES rows, same INSTRUMENT_ID, same beneficial owner across
--       the two participants, opposite sides (read from ORDERS via ORDER_ID -- unresolvable when
--       ORDER_ID is null, which is exactly what WASH_DETECTION_COVERAGE below surfaces),
--       within the calibrated time window and price tolerance, checked ACROSS venues for the
--       same instrument/beneficial owner (architecture.md: a pattern spread across venues to
--       dodge one venue's detection is itself the case to catch), not restricted to one venue.
-- A candidate whose MATCHING_MECHANISM is in the calibrated exempt list is marked
-- IS_TRIGGER_EXEMPT rather than dropped from the result (Fix #20) -- still visible for review,
-- just not flagged as an automatic trigger.
--
-- Anti-joins TRADE_CORRECTIONS (Fix #15) -- a busted trade is never a live wash-trading candidate.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW WASH_TRADING_CANDIDATES AS
WITH LIVE_TRADES AS (
    SELECT t.*
    FROM TRADES t
    LEFT JOIN TRADE_CORRECTIONS tc
        ON tc.TRADE_ID = t.TRADE_ID AND tc.VENUE_ID = t.VENUE_ID AND tc.CORRECTION_TYPE = 'bust'
    WHERE tc.TRADE_ID IS NULL
),
CALIB AS (
    SELECT * FROM DETECTOR_CALIBRATION_CURRENT WHERE DETECTOR_NAME = 'wash_trading'
),
SELF_TRADE AS (
    SELECT
        t.TRADE_ID AS TRADE_ID_1, t.TRADE_ID AS TRADE_ID_2,
        t.JURISDICTION_ID, t.VENUE_ID, t.INSTRUMENT_ID,
        t.PARTICIPANT_ID AS PARTICIPANT_ID_1, t.COUNTERPARTY_PARTICIPANT_ID AS PARTICIPANT_ID_2,
        p1.BENEFICIAL_OWNER_ID,
        t.EXECUTION_TIMESTAMP AS EXECUTION_TIMESTAMP_1, t.EXECUTION_TIMESTAMP AS EXECUTION_TIMESTAMP_2,
        t.PRICE AS PRICE_1, t.PRICE AS PRICE_2,
        t.MATCHING_MECHANISM,
        'same_row_self_trade' AS CANDIDATE_TYPE
    FROM LIVE_TRADES t
    JOIN MARKET_PARTICIPANTS_CURRENT p1 ON p1.PARTICIPANT_ID = t.PARTICIPANT_ID AND p1.JURISDICTION_ID = t.JURISDICTION_ID
    JOIN MARKET_PARTICIPANTS_CURRENT p2 ON p2.PARTICIPANT_ID = t.COUNTERPARTY_PARTICIPANT_ID AND p2.JURISDICTION_ID = t.JURISDICTION_ID
    WHERE t.COUNTERPARTY_PARTICIPANT_ID IS NOT NULL
      AND p1.BENEFICIAL_OWNER_ID IS NOT NULL
      AND p1.BENEFICIAL_OWNER_ID = p2.BENEFICIAL_OWNER_ID
),
-- DIMENSION_KEY-aware calibration resolution for the matched-pair candidate shape (review
-- finding: the original join matched on JURISDICTION_ID/VENUE_ID only, with no awareness that
-- DETECTOR_CALIBRATION can carry an instrument-specific override -- 04_position_limit.sql already
-- has to guard against exactly this. Resolved as its own step, before the time/price filter below,
-- so exactly one calibration row -- the most specific one that actually matches this instrument
-- and venue -- governs both the threshold check and the exemption lookup for this pair. Without
-- this, seeding an instrument-specific override alongside a venue-wide default would let a pair
-- pass using whichever matched row happens to be most lenient, or silently double every candidate.
MATCHED_PAIR_CALIB AS (
    SELECT
        t1.TRADE_ID AS TRADE_ID_1, t2.TRADE_ID AS TRADE_ID_2,
        t1.JURISDICTION_ID, t1.VENUE_ID, t1.INSTRUMENT_ID,
        t1.PARTICIPANT_ID AS PARTICIPANT_ID_1, t2.PARTICIPANT_ID AS PARTICIPANT_ID_2,
        p1.BENEFICIAL_OWNER_ID,
        t1.EXECUTION_TIMESTAMP AS EXECUTION_TIMESTAMP_1, t2.EXECUTION_TIMESTAMP AS EXECUTION_TIMESTAMP_2,
        t1.PRICE AS PRICE_1, t2.PRICE AS PRICE_2,
        t1.MATCHING_MECHANISM,
        'cross_row_matched_pair' AS CANDIDATE_TYPE,
        c.PARAMS AS CALIB_PARAMS
    FROM LIVE_TRADES t1
    JOIN LIVE_TRADES t2
        ON t2.INSTRUMENT_ID = t1.INSTRUMENT_ID
       AND t2.TRADE_ID > t1.TRADE_ID
       AND t2.JURISDICTION_ID = t1.JURISDICTION_ID
    JOIN ORDERS_CURRENT o1 ON o1.ORDER_ID = t1.ORDER_ID AND o1.VENUE_ID = t1.VENUE_ID
    JOIN ORDERS_CURRENT o2 ON o2.ORDER_ID = t2.ORDER_ID AND o2.VENUE_ID = t2.VENUE_ID
    JOIN MARKET_PARTICIPANTS_CURRENT p1 ON p1.PARTICIPANT_ID = t1.PARTICIPANT_ID AND p1.JURISDICTION_ID = t1.JURISDICTION_ID
    JOIN MARKET_PARTICIPANTS_CURRENT p2 ON p2.PARTICIPANT_ID = t2.PARTICIPANT_ID AND p2.JURISDICTION_ID = t2.JURISDICTION_ID
    JOIN CALIB c ON c.JURISDICTION_ID = t1.JURISDICTION_ID
        AND (c.VENUE_ID = t1.VENUE_ID OR c.VENUE_ID IS NULL)
        AND (c.DIMENSION_KEY = t1.INSTRUMENT_ID OR c.DIMENSION_KEY IS NULL)
    WHERE o1.SIDE IS NOT NULL AND o2.SIDE IS NOT NULL AND o1.SIDE != o2.SIDE
      AND p1.BENEFICIAL_OWNER_ID IS NOT NULL AND p1.BENEFICIAL_OWNER_ID = p2.BENEFICIAL_OWNER_ID
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t1.TRADE_ID, t2.TRADE_ID
        ORDER BY (c.VENUE_ID IS NULL) ASC, (c.DIMENSION_KEY IS NULL) ASC
    ) = 1
),
-- Threshold check applied AFTER calibration resolution, against that single resolved row only --
-- not "does any matching calibration's threshold pass," which would let a lenient fallback
-- override a stricter instrument-specific one that should govern exclusively.
MATCHED_PAIR AS (
    SELECT
        TRADE_ID_1, TRADE_ID_2, JURISDICTION_ID, VENUE_ID, INSTRUMENT_ID,
        PARTICIPANT_ID_1, PARTICIPANT_ID_2, BENEFICIAL_OWNER_ID,
        EXECUTION_TIMESTAMP_1, EXECUTION_TIMESTAMP_2, PRICE_1, PRICE_2,
        MATCHING_MECHANISM, CANDIDATE_TYPE
    FROM MATCHED_PAIR_CALIB
    WHERE ABS(DATEDIFF('second', EXECUTION_TIMESTAMP_1, EXECUTION_TIMESTAMP_2)) <= CALIB_PARAMS:time_window_seconds::NUMBER
      AND ABS(PRICE_1 - PRICE_2) <= (CALIB_PARAMS:price_tolerance_pct::FLOAT * PRICE_1)
)
SELECT
    s.*,
    COALESCE(ec.PARAMS, mc.PARAMS) AS CALIBRATION_PARAMS,
    -- COALESCE(..., FALSE): a venue with no wash_trading calibration seeded yet must never be
    -- silently treated as exempt. Without this, ARRAY_CONTAINS against a NULL array (no
    -- calibration found) returns NULL, not FALSE -- and a consumer filtering
    -- "WHERE NOT IS_TRIGGER_EXEMPT" would silently drop those NULL rows via SQL three-valued
    -- logic, the exact "silently blind" failure WASH_DETECTION_COVERAGE (Fix #3) exists to
    -- prevent elsewhere in this same detector. Missing calibration must mean "flag for review",
    -- never "hide from review."
    COALESCE(
        ARRAY_CONTAINS(
            TO_VARIANT(s.MATCHING_MECHANISM),
            COALESCE(ec.PARAMS:exempt_matching_mechanisms, mc.PARAMS:exempt_matching_mechanisms)
        ),
        FALSE
    ) AS IS_TRIGGER_EXEMPT
FROM (
    SELECT * FROM SELF_TRADE
    UNION ALL
    SELECT * FROM MATCHED_PAIR
) s
-- Both ec/mc are also DIMENSION_KEY-aware and QUALIFY-deduped now (same review finding as above,
-- applied here too -- SELF_TRADE rows never resolved a calibration row at all before reaching
-- this join, so this is the only dedup point that covers them).
LEFT JOIN CALIB ec ON ec.JURISDICTION_ID = s.JURISDICTION_ID AND ec.VENUE_ID = s.VENUE_ID
    AND (ec.DIMENSION_KEY = s.INSTRUMENT_ID OR ec.DIMENSION_KEY IS NULL)
LEFT JOIN CALIB mc ON mc.JURISDICTION_ID = s.JURISDICTION_ID AND mc.VENUE_ID IS NULL
    AND (mc.DIMENSION_KEY = s.INSTRUMENT_ID OR mc.DIMENSION_KEY IS NULL)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.TRADE_ID_1, s.TRADE_ID_2
    ORDER BY (ec.DIMENSION_KEY IS NULL) ASC, (mc.DIMENSION_KEY IS NULL) ASC
) = 1;

-- WASH_DETECTION_COVERAGE (Fix #3) -- per VENUE_ID per day, the percentage of trades with a
-- resolvable counterparty (either ORDER_ID resolves to a participant, or COUNTERPARTY_PARTICIPANT_ID
-- is populated). Any wash-trading finding must be presented alongside this figure -- "no wash
-- trades found" and "no wash trades could be checked for" are never conflated.
CREATE OR REPLACE VIEW WASH_DETECTION_COVERAGE AS
SELECT
    t.JURISDICTION_ID,
    t.VENUE_ID,
    DATE(t.EXECUTION_TIMESTAMP) AS TRADE_DATE,
    COUNT(*) AS TOTAL_TRADES,
    COUNT_IF(t.COUNTERPARTY_PARTICIPANT_ID IS NOT NULL OR o.ORDER_ID IS NOT NULL) AS RESOLVABLE_TRADES,
    DIV0(
        COUNT_IF(t.COUNTERPARTY_PARTICIPANT_ID IS NOT NULL OR o.ORDER_ID IS NOT NULL),
        COUNT(*)
    ) AS PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY
FROM TRADES t
LEFT JOIN ORDERS_CURRENT o ON o.ORDER_ID = t.ORDER_ID AND o.VENUE_ID = t.VENUE_ID
GROUP BY t.JURISDICTION_ID, t.VENUE_ID, DATE(t.EXECUTION_TIMESTAMP);

GRANT SELECT ON VIEW WASH_TRADING_CANDIDATES TO ROLE ANALYST_READ;
GRANT SELECT ON VIEW WASH_DETECTION_COVERAGE TO ROLE ANALYST_READ;
