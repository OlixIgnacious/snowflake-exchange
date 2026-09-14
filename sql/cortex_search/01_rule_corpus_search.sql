-- Cortex Search Service over RULE_CORPUS_CURRENT -- semantic retrieval over the real regulatory
-- chunks loaded in sql/governance/01_*.sql (Japan) and 02_*.sql (US/EU). Directly usable by the
-- Cortex Agent as a fourth tool, or by rule_interpret's CLI wrapper, instead of requiring an exact
-- CHUNK_ID lookup the way scripts/run_rule_gap_analysis.py currently does.
--
-- TARGET_LAG='1 day' deliberately -- RULE_CORPUS changes rarely (a new obligation-mapping pass,
-- not a live feed), so there is no reason to pay for near-real-time refresh. Lower it temporarily
-- before a demo if a just-loaded chunk needs to be searchable immediately.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE CORTEX SEARCH SERVICE RULE_CORPUS_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, SOURCE_AUTHORITY, ORIGINAL_LANGUAGE
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 day'
    AS (
        SELECT CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, CHUNK_TEXT,
               SOURCE_AUTHORITY, ORIGINAL_LANGUAGE
        FROM RULE_CORPUS_CURRENT
    );

GRANT USAGE ON CORTEX SEARCH SERVICE RULE_CORPUS_SEARCH TO ROLE ANALYST_READ;
