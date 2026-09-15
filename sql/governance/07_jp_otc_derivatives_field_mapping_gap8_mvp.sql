-- Scoped MVP closing gap 8 for real: JP/otc_derivative_transaction_report went from 3/138 fields
-- mapped to 23/138, backed by the real schema built in sql/ddl/10_otc_derivatives.sql and
-- generator/generate.py's new OTC-derivatives block (MARKET_PARTICIPANTS.LEI,
-- DERIVATIVE_PRODUCT_ATTRIBUTES, DERIVATIVE_TRADE_DETAILS) -- not a documentation-only relabel.
-- Same STATUS-lifecycle-via-new-row pattern as every other REPORT_TEMPLATES change: a new row,
-- same (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME) key, later LOADED_AT, STATUS flips gap->mapped
-- -- never an UPDATE. REPORT_TEMPLATE_RULE_CHUNKS already links every one of these FIELD_NAMEs to
-- JP-FSA-OTC-DERIV-ART4-1 (keyed by the natural key, not a LOADED_AT version -- see
-- 06_jp_otc_derivatives_report_template_seed.sql), so no new citation link is needed here.
--
-- Deliberately still 'gap' (untouched by this file): valuation (39-43), margin/collateral
-- (44-63), everything derivative-specific this MVP explicitly scoped out (option/CDS/package
-- fields, price/strike schedules) -- a real mark-to-market/collateral-posting model is future
-- work, not silently implied by this fix.
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
    (1,   'Effective date',                                    'DERIVATIVE_TRADE_DETAILS.EFFECTIVE_DATE'),
    (2,   'Expiration date',                                   'DERIVATIVE_TRADE_DETAILS.MATURITY_DATE'),
    (6,   'Entity responsible for reporting',                  'REPORTING_PARTICIPANT.LEI'),
    (7,   'Counterparty 1 (reporting counterparty)',            'REPORTING_PARTICIPANT.LEI'),
    (8,   'Counterparty 2',                                     'COUNTERPARTY_PARTICIPANT.LEI'),
    (9,   'Counterparty 2 identifier type',                     'DERIVATIVE_TRADE_DETAILS.COUNTERPARTY_2_ID_TYPE'),
    (11,  'Direction 2 (Payer/Receiver)',                       'DERIVATIVE_TRADE_DETAILS.REPORTING_PARTY_DIRECTION'),
    (25,  'Unique transaction identifier (UTI)',                'DERIVATIVE_TRADE_DETAILS.UTI'),
    (27,  'Day count convention',                                'DERIVATIVE_TRADE_DETAILS.DAY_COUNT_CONVENTION'),
    (28,  'Payment frequency period',                            'DERIVATIVE_TRADE_DETAILS.PAYMENT_FREQUENCY_PERIOD'),
    (29,  'Payment frequency period multiplier',                 'DERIVATIVE_TRADE_DETAILS.PAYMENT_FREQUENCY_MULTIPLIER'),
    (71,  'Fixed rate',                                          'DERIVATIVE_TRADE_DETAILS.FIXED_RATE'),
    (87,  'Notional amount',                                     'DERIVATIVE_TRADE_DETAILS.NOTIONAL_AMOUNT'),
    (90,  'Notional currency',                                   'DERIVATIVE_TRADE_DETAILS.NOTIONAL_CURRENCY'),
    (107, 'Unique product identifier',                           'DERIVATIVE_PRODUCT_ATTRIBUTES.UPI'),
    (108, 'Delivery type',                                       'DERIVATIVE_PRODUCT_ATTRIBUTES.DELIVERY_TYPE'),
    (109, 'Asset Class',                                         'DERIVATIVE_PRODUCT_ATTRIBUTES.ASSET_CLASS'),
    (110, 'Underlying identification type',                      'DERIVATIVE_PRODUCT_ATTRIBUTES.UNDERLYING_ID_TYPE'),
    (111, 'Underlying identification',                           'DERIVATIVE_PRODUCT_ATTRIBUTES.UNDERLYING_ID'),
    (129, 'Contract type',                                       'DERIVATIVE_PRODUCT_ATTRIBUTES.CONTRACT_TYPE');
