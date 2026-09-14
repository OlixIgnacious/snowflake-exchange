-- ZSCORE UDF, ported from Praman (architecture.md: "one detector formula, multiple consuming
-- views"). Every statistical detector below calls this against its own trailing baseline read
-- from DETECTOR_CALIBRATION -- no detector computes a z-score inline with its own formula.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE FUNCTION ZSCORE(VALUE FLOAT, BASELINE_MEAN FLOAT, BASELINE_STDDEV FLOAT)
RETURNS FLOAT
AS
$$
    CASE WHEN BASELINE_STDDEV IS NULL OR BASELINE_STDDEV = 0 THEN NULL
         ELSE (VALUE - BASELINE_MEAN) / BASELINE_STDDEV
    END
$$;

GRANT USAGE ON FUNCTION ZSCORE(FLOAT, FLOAT, FLOAT) TO ROLE ANALYST_READ;
