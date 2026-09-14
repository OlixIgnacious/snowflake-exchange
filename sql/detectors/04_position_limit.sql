-- Position/exposure limit breach. Spec: architecture.md "Detectors" section. POSITIONS.NET_QUANTITY
-- as a percentage of a regulatory threshold per instrument/participant class, scoped by
-- JURISDICTION_ID ONLY -- structurally consistent with POSITIONS itself having no VENUE_ID (the
-- limit is on a cross-venue total accumulated from TRADES only). Rules-based, not statistical --
-- the threshold quantity itself comes entirely from DETECTOR_CALIBRATION.PARAMS
-- ({"limit_quantity": <number>}), never a literal (market-agnostic rule #3); "100% of the limit"
-- is a structural ratio definition, not a market-specific value, so it's the only inline constant.
-- DIMENSION_KEY, when populated, scopes the limit to one INSTRUMENT_ID; a NULL DIMENSION_KEY row
-- is the jurisdiction-wide default, used only when no instrument-specific override exists.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE VIEW POSITION_LIMIT_BREACHES AS
WITH LATEST_POSITIONS AS (
    SELECT *
    FROM POSITIONS_CURRENT
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID
        ORDER BY AS_OF_DATE DESC
    ) = 1
)
SELECT
    p.PARTICIPANT_ID, p.INSTRUMENT_ID, p.JURISDICTION_ID, p.AS_OF_DATE,
    p.NET_QUANTITY, p.MARKET_VALUE, p.CURRENCY,
    c.PARAMS:limit_quantity::NUMBER AS LIMIT_QUANTITY,
    DIV0(ABS(p.NET_QUANTITY), c.PARAMS:limit_quantity::NUMBER) AS PCT_OF_LIMIT,
    (ABS(p.NET_QUANTITY) >= c.PARAMS:limit_quantity::NUMBER) AS IS_BREACH
FROM LATEST_POSITIONS p
JOIN DETECTOR_CALIBRATION_CURRENT c
    ON c.JURISDICTION_ID = p.JURISDICTION_ID
   AND c.VENUE_ID IS NULL
   AND c.DETECTOR_NAME = 'position_limit'
   AND (c.DIMENSION_KEY = p.INSTRUMENT_ID OR c.DIMENSION_KEY IS NULL)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY p.PARTICIPANT_ID, p.INSTRUMENT_ID, p.JURISDICTION_ID
    ORDER BY (c.DIMENSION_KEY IS NULL) ASC
) = 1;

GRANT SELECT ON VIEW POSITION_LIMIT_BREACHES TO ROLE ANALYST_READ;
