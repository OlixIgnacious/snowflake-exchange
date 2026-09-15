-- Correction found while verifying 07_jp_otc_derivatives_field_mapping_gap8_mvp.sql live: fields
-- 64 (Price) and 65 (Price currency) were originally mapped (by 06_jp_otc_derivatives_report_
-- template_seed.sql) to TRADES.PRICE/TRADES.CURRENCY. TRADES.PRICE turns out to be NUMBER(38,0)
-- (bare NUMBER defaults to that in Snowflake -- a real, pre-existing, platform-wide gap this file
-- does not attempt to fix retroactively) -- a swap's fixed rate (e.g. 0.0075) silently truncates
-- to 0 there. DERIVATIVE_TRADE_DETAILS.FIXED_RATE (sql/ddl/10_otc_derivatives.sql) was built with
-- an explicit NUMBER(9,6) precisely so this field type can hold a real decimal rate -- this file
-- re-points field 64/65's SOURCE_MAPPING to it instead, for otc_derivative_transaction_report
-- only. JP's separate equity 'transaction_report' Price/Volume mapping (a different REPORT_TYPE
-- key entirely) is untouched -- this does not fix that report type's own TRADES.PRICE precision
-- gap, which stays a real, separately-tracked, out-of-scope issue for this pass.
--
-- Same STATUS-lifecycle-via-new-row pattern as every other REPORT_TEMPLATES change: new rows,
-- same (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME) key, later LOADED_AT -- never an UPDATE.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE GOVERNANCE_WRITE;
USE DATABASE VIGIL;
USE SCHEMA CORE;

INSERT INTO REPORT_TEMPLATES (
    JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, FIELD_ORDER, STATUS, SOURCE_MAPPING, FIELD_FORMAT,
    IS_REQUIRED, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT 'JP', 'otc_derivative_transaction_report', column2, column1, 'mapped', column3, NULL,
       TRUE, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    (64, 'Price',          'DERIVATIVE_TRADE_DETAILS.FIXED_RATE'),
    (65, 'Price currency', 'DERIVATIVE_TRADE_DETAILS.NOTIONAL_CURRENCY');
