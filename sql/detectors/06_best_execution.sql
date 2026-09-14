-- Best execution -- two distinct metrics, not one conflated formula (Fix #5). Spec:
-- architecture.md "Detectors" section. EXECUTION_SLIPPAGE: TRADES.PRICE vs. the reference price
-- AT EXECUTION_TIMESTAMP (was the fill fair given the market at that instant). ARRIVAL_SLIPPAGE:
-- TRADES.PRICE vs. the reference price AT the order's ORIGINAL 'new'-event EVENT_TS (did
-- delay/market impact between order entry and execution cost the participant) -- explicitly the
-- order's first event, not whatever ORDERS_CURRENT's latest state happens to be. Both scoped per
-- VENUE_ID (the reference-price source is itself venue-dependent; TRADE_REFERENCE_PRICES'
-- columns are nullable for that reason, not an adaptor failure -- rows with no reference price
-- are naturally excluded here via the inner joins, not coerced to zero slippage).

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW EXECUTION_SLIPPAGE AS
SELECT
    t.TRADE_ID, t.VENUE_ID, t.JURISDICTION_ID, t.INSTRUMENT_ID,
    t.EXECUTION_TIMESTAMP, t.PRICE, t.CURRENCY,
    rp.REFERENCE_PRICE_AT_EXECUTION,
    (t.PRICE - rp.REFERENCE_PRICE_AT_EXECUTION) AS EXECUTION_SLIPPAGE_ABS,
    DIV0(t.PRICE - rp.REFERENCE_PRICE_AT_EXECUTION, rp.REFERENCE_PRICE_AT_EXECUTION) AS EXECUTION_SLIPPAGE_PCT
FROM TRADES t
JOIN TRADE_REFERENCE_PRICES_CURRENT rp
    ON rp.TRADE_ID = t.TRADE_ID AND rp.VENUE_ID = t.VENUE_ID
WHERE rp.REFERENCE_PRICE_AT_EXECUTION IS NOT NULL;

CREATE OR REPLACE VIEW ARRIVAL_SLIPPAGE AS
SELECT
    t.TRADE_ID, t.VENUE_ID, t.JURISDICTION_ID, t.INSTRUMENT_ID,
    o.EVENT_TS AS ORDER_SUBMITTED_TS, t.PRICE, t.CURRENCY,
    rp.REFERENCE_PRICE_AT_ARRIVAL,
    (t.PRICE - rp.REFERENCE_PRICE_AT_ARRIVAL) AS ARRIVAL_SLIPPAGE_ABS,
    DIV0(t.PRICE - rp.REFERENCE_PRICE_AT_ARRIVAL, rp.REFERENCE_PRICE_AT_ARRIVAL) AS ARRIVAL_SLIPPAGE_PCT
FROM TRADES t
JOIN ORDERS o
    ON o.ORDER_ID = t.ORDER_ID AND o.VENUE_ID = t.VENUE_ID AND o.EVENT_TYPE = 'new'
JOIN TRADE_REFERENCE_PRICES_CURRENT rp
    ON rp.TRADE_ID = t.TRADE_ID AND rp.VENUE_ID = t.VENUE_ID
WHERE rp.REFERENCE_PRICE_AT_ARRIVAL IS NOT NULL;

GRANT SELECT ON VIEW EXECUTION_SLIPPAGE TO ROLE ANALYST_READ;
GRANT SELECT ON VIEW ARRIVAL_SLIPPAGE TO ROLE ANALYST_READ;
