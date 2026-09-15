-- Closes review finding "only 4 fields is a toy template, not a real regulatory report":
-- REPORT_TEMPLATES previously had exactly 4 fields (Price/Volume/Instrument_ID/Trading_Capacity,
-- seeded by generator/generate.py for JP only) against a real transaction-reporting regime's
-- actual field count -- real regimes look more like the ~65-field table below.
--
-- Deliberately seeded under JURISDICTION_ID='EU', not JP: RTS 22 (Commission Delegated Regulation
-- (EU) 2017/590) is the EU's own transaction-reporting technical standard, supplementing MiFIR
-- Article 26(1) -- the same obligation already cited as EU-MIFIR-26-1 in
-- 02_us_eu_rule_corpus_and_obligations_seed.sql. Seeding JP's REPORT_TEMPLATES with an EU
-- standard's field list would misattribute a European rule to Japan's actual (still-unsourced,
-- per NOTES.md 2026-09-14/15) transaction-report format -- exactly the jurisdiction-mixing the
-- market-agnostic design rules forbid. JP's existing 4-field template is left untouched.
--
-- All 65 fields are real, extracted+verified via `pdftotext -layout` against
-- docs/sources/EU_RTS22_2017_590.pdf (Annex I, Table 2 -- "Details to be reported in transaction
-- reports"), not paraphrased from memory. Fields 17-24 mirror fields 8-15 relabeled for the seller
-- (the regulation states this explicitly rather than repeating the text) -- field names below
-- reflect that.
--
-- Honest mapped/gap split, single-table scope (see sp_render_report_payload.sql's own
-- TRADES-only restriction): only fields resolving to a real TRADES column via live
-- INFORMATION_SCHEMA get STATUS='mapped' --
--   28 Trading date time      -> TRADES.EXECUTION_TIMESTAMP
--   29 Trading capacity       -> TRADES.REGULATORY_ATTRIBUTES:Trading_Capacity
--   30 Quantity               -> TRADES.VOLUME
--   33 Price                  -> TRADES.PRICE
--   34 Price currency         -> TRADES.CURRENCY
--   36 Venue                  -> TRADES.VENUE_ID
--   41 Instrument identification code -> TRADES.INSTRUMENT_ID
-- The other 58 -- buyer/seller LEI and natural-person identity fields, decision-maker/execution-
-- within-firm fields, every derivative/option/swap field (this schema has no derivatives model at
-- all), waiver/short-sale/OTC/commodity-derivative/SFT indicators -- are real, required RTS 22
-- fields this schema genuinely has no source for today. Marked STATUS='gap', IS_REQUIRED=TRUE
-- (the regulation's own "all fields are mandatory unless stated otherwise"): an honest, surfaced
-- gap per REPORT_TEMPLATE_COVERAGE, not hidden by a falsely-narrow field list.
--
-- No live EU trade data exists yet (NOTES.md 2026-09-15) -- that doesn't block this seed.
-- REPORT_TEMPLATES is a template definition, independent of whether any TRANSACTION_REPORTS row
-- currently references it; the TRADES columns these mappings resolve against are real,
-- market-agnostic schema, present regardless of which jurisdiction's rows happen to be loaded.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE GOVERNANCE_WRITE;
USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- REPORT_TEMPLATES -- all 65 real RTS 22 Annex I Table 2 fields for EU/transaction_report
-- ============================================================================
INSERT INTO REPORT_TEMPLATES (
    JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, FIELD_ORDER, STATUS, SOURCE_MAPPING, FIELD_FORMAT,
    IS_REQUIRED, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT 'EU', 'transaction_report', column2, column1, column4, column3, NULL,
       TRUE, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    (1, 'Report status', NULL, 'gap'),
    (2, 'Transaction Reference Number', NULL, 'gap'),
    (3, 'Trading venue transaction identification code', NULL, 'gap'),
    (4, 'Executing entity identification code', NULL, 'gap'),
    (5, 'Investment Firm covered by Directive 2014/65/EU', NULL, 'gap'),
    (6, 'Submitting entity identification code', NULL, 'gap'),
    (7, 'Buyer identification code', NULL, 'gap'),
    (8, 'Country of the branch for the buyer', NULL, 'gap'),
    (9, 'Buyer - first name(s)', NULL, 'gap'),
    (10, 'Buyer - surname(s)', NULL, 'gap'),
    (11, 'Buyer - date of birth', NULL, 'gap'),
    (12, 'Buyer decision maker code', NULL, 'gap'),
    (13, 'Buy decision maker - first name(s)', NULL, 'gap'),
    (14, 'Buy decision maker - surname(s)', NULL, 'gap'),
    (15, 'Buy decision maker - date of birth', NULL, 'gap'),
    (16, 'Seller identification code', NULL, 'gap'),
    (17, 'Country of the branch for the seller', NULL, 'gap'),
    (18, 'Seller - first name(s)', NULL, 'gap'),
    (19, 'Seller - surname(s)', NULL, 'gap'),
    (20, 'Seller - date of birth', NULL, 'gap'),
    (21, 'Seller decision maker code', NULL, 'gap'),
    (22, 'Sell decision maker - first name(s)', NULL, 'gap'),
    (23, 'Sell decision maker - surname(s)', NULL, 'gap'),
    (24, 'Sell decision maker - date of birth', NULL, 'gap'),
    (25, 'Transmission of order indicator', NULL, 'gap'),
    (26, 'Transmitting firm identification code for the buyer', NULL, 'gap'),
    (27, 'Transmitting firm identification code for the seller', NULL, 'gap'),
    (28, 'Trading date time', 'TRADES.EXECUTION_TIMESTAMP', 'mapped'),
    (29, 'Trading capacity', 'TRADES.REGULATORY_ATTRIBUTES:Trading_Capacity', 'mapped'),
    (30, 'Quantity', 'TRADES.VOLUME', 'mapped'),
    (31, 'Quantity currency', NULL, 'gap'),
    (32, 'Derivative notional increase/decrease', NULL, 'gap'),
    (33, 'Price', 'TRADES.PRICE', 'mapped'),
    (34, 'Price currency', 'TRADES.CURRENCY', 'mapped'),
    (35, 'Net amount', NULL, 'gap'),
    (36, 'Venue', 'TRADES.VENUE_ID', 'mapped'),
    (37, 'Country of the branch membership', NULL, 'gap'),
    (38, 'Up-front payment', NULL, 'gap'),
    (39, 'Up-front payment currency', NULL, 'gap'),
    (40, 'Complex trade component id', NULL, 'gap'),
    (41, 'Instrument identification code', 'TRADES.INSTRUMENT_ID', 'mapped'),
    (42, 'Instrument full name', NULL, 'gap'),
    (43, 'Instrument classification', NULL, 'gap'),
    (44, 'Notional currency 1', NULL, 'gap'),
    (45, 'Notional currency 2', NULL, 'gap'),
    (46, 'Price multiplier', NULL, 'gap'),
    (47, 'Underlying instrument code', NULL, 'gap'),
    (48, 'Underlying index name', NULL, 'gap'),
    (49, 'Term of the underlying index', NULL, 'gap'),
    (50, 'Option type', NULL, 'gap'),
    (51, 'Strike price', NULL, 'gap'),
    (52, 'Strike price currency', NULL, 'gap'),
    (53, 'Option exercise style', NULL, 'gap'),
    (54, 'Maturity date', NULL, 'gap'),
    (55, 'Expiry date', NULL, 'gap'),
    (56, 'Delivery type', NULL, 'gap'),
    (57, 'Investment decision within firm', NULL, 'gap'),
    (58, 'Country of the branch supervising the person responsible for the investment decision', NULL, 'gap'),
    (59, 'Execution within firm', NULL, 'gap'),
    (60, 'Country of the branch supervising the person responsible for the execution', NULL, 'gap'),
    (61, 'Waiver indicator', NULL, 'gap'),
    (62, 'Short selling indicator', NULL, 'gap'),
    (63, 'OTC post-trade indicator', NULL, 'gap'),
    (64, 'Commodity derivative indicator', NULL, 'gap'),
    (65, 'Securities financing transaction indicator', NULL, 'gap');

-- ============================================================================
-- RULE_CORPUS -- the real citation backing every field above (one chunk, Table 2 as a whole is
-- the source for the entire field list, same granularity OBLIGATION_MAP citations use elsewhere)
-- ============================================================================
INSERT INTO RULE_CORPUS (
    CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, CHUNK_TEXT,
    SOURCE_AUTHORITY, ORIGINAL_LANGUAGE, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT
    'EU-RTS22-ANNEXI-TABLE2', 'EU',
    'Commission Delegated Regulation (EU) 2017/590 (RTS 22, supplementing MiFIR Article 26)',
    'Article 1 + Annex I, Table 2',
    'Article 1 (Data standards and formats for transaction reporting): A transaction report shall include all details referred to in Table 2 of Annex I that pertain to the financial instruments concerned. All details to be included in transaction reports shall be submitted in accordance with the standards and formats specified in Table 2 of Annex I, in an electronic and machine-readable form and in a common XML template in accordance with the ISO 20022 methodology. Annex I, Table 2 (Details to be reported in transaction reports): "All fields are mandatory, unless stated otherwise." Table 2 lists 65 numbered fields (Report status; Transaction Reference Number; Trading venue transaction identification code; Executing/Submitting entity identification codes; Buyer/Seller identification and natural-person/decision-maker details, fields 7-24; Transmission-of-order details, fields 25-27; Trading date time; Trading capacity; Quantity and currency; Price and currency; Net amount; Venue; Instrument identification code and classification; notional/derivative/option fields, fields 37-56; Investment decision and execution-within-firm fields; Waiver, short selling, OTC post-trade, commodity derivative, and securities financing transaction indicators, fields 57-65).',
    'original', 'en', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed';

-- ============================================================================
-- REPORT_TEMPLATE_RULE_CHUNKS -- link every one of the 65 fields to the chunk above
-- ============================================================================
INSERT INTO REPORT_TEMPLATE_RULE_CHUNKS (
    JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, RULE_CHUNK_ID, IS_ACTIVE,
    CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT 'EU', 'transaction_report', FIELD_NAME, 'EU-RTS22-ANNEXI-TABLE2', TRUE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM REPORT_TEMPLATES_CURRENT
WHERE JURISDICTION_ID = 'EU' AND REPORT_TYPE = 'transaction_report';
