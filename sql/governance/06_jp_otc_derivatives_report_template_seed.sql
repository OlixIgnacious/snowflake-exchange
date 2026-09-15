-- Closes gap 8 from the review plan: JP's own transaction-report field citation. Two prior
-- research passes plus a fresh 2026-09-15 pass through JPX's Business/Trading Participant
-- Regulations all found nothing usable for *equity* transaction reporting -- but a real,
-- field-level, FSA-published citation exists for a different, real product scope: OTC
-- derivatives transaction reporting to a Trade Repository.
--
-- Real primary source, extracted+verified via `pdftotext` against
-- docs/sources/JP_FSA_OTC_derivatives_reporting_guideline.pdf (not paraphrased):
-- "Guidelines for Creating, Recordkeeping and Reporting of Transaction Information specified in
-- Article 4(1) of the Cabinet Office Order on the Regulation of Over-the-Counter Derivatives
-- Transactions, etc." (FSA, December 2022, November 2023 Revision) -- a [Provisional
-- Translation] of the original Japanese, hence SOURCE_AUTHORITY='translation'/
-- ORIGINAL_LANGUAGE='ja', same convention as JP's other citations. Implements FIEA Art. 156-63
-- to 156-65 and Cabinet Office Order No. 48 of 2012, Art. 4(1). Its "List of Reporting Matters"
-- is a real, numbered, 138-field table, each field's definition sourced from the internationally
-- harmonized CDE (Critical Data Elements) standard, or CFTC/ESMA equivalents where CDE doesn't
-- cover it -- Japan adopted the same international OTC-derivatives-reporting field taxonomy used
-- for EMIR/Dodd-Frank, not a bespoke domestic one.
--
-- Deliberately a NEW REPORT_TYPE ('otc_derivative_transaction_report'), not folded into JP's
-- existing 'transaction_report' (which is equity-shaped: Price/Volume/Instrument_ID/
-- Trading_Capacity, matching JAPAN_CONFIG's equity-only instrument universe) -- this document
-- governs OTC derivatives specifically, a different product scope, and mixing the two would
-- misattribute a real citation to the wrong report type. Same jurisdiction-precision discipline
-- already applied to the EU RTS 22 seed, applied here to REPORT_TYPE instead of JURISDICTION_ID.
--
-- Honest mapped/gap split: only 3 of 138 fields resolve to a real TRADES column --
-- field 5 (Execution timestamp) -> EXECUTION_TIMESTAMP, field 64 (Price) -> PRICE, field 65
-- (Price currency) -> CURRENCY. The other 135 (counterparty/LEI identifiers, margin/collateral,
-- valuation, every derivative-specific notional/strike/option/underlying field) are real,
-- required fields this equity-only schema has no source for at all -- JAPAN_CONFIG generates no
-- derivatives instruments, so this is a genuine, large gap, not a token one. Marked STATUS='gap',
-- IS_REQUIRED=TRUE throughout. Deliberately did NOT stretch TRADES.VOLUME onto any of the
-- quantity-related fields (67, 93, 97-100) -- those are all derivatives notional/quantity
-- *schedules* (leg-based, amortizing), a different concept from a simple equity share count, and
-- forcing that mapping would misrepresent what the field actually means.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE GOVERNANCE_WRITE;
USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- REPORT_TEMPLATES -- all 138 real fields for JP/otc_derivative_transaction_report
-- ============================================================================
INSERT INTO REPORT_TEMPLATES (
    JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, FIELD_ORDER, STATUS, SOURCE_MAPPING, FIELD_FORMAT,
    IS_REQUIRED, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT 'JP', 'otc_derivative_transaction_report', column2, column1, column4, column3, NULL,
       TRUE, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    (1, 'Effective date', NULL, 'gap'),
    (2, 'Expiration date', NULL, 'gap'),
    (3, 'Early termination date', NULL, 'gap'),
    (4, 'Reporting timestamp', NULL, 'gap'),
    (5, 'Execution timestamp', 'TRADES.EXECUTION_TIMESTAMP', 'mapped'),
    (6, 'Entity responsible for reporting', NULL, 'gap'),
    (7, 'Counterparty 1 (reporting counterparty)', NULL, 'gap'),
    (8, 'Counterparty 2', NULL, 'gap'),
    (9, 'Counterparty 2 identifier type', NULL, 'gap'),
    (10, 'Direction 1 (Buyer/Seller)', NULL, 'gap'),
    (11, 'Direction 2 (Payer/Receiver)', NULL, 'gap'),
    (12, 'Submitter identifier', NULL, 'gap'),
    (13, 'New SDR identifier', NULL, 'gap'),
    (14, 'Original swap SDR identifier', NULL, 'gap'),
    (15, 'Cleared', NULL, 'gap'),
    (16, 'Central counterparty', NULL, 'gap'),
    (17, 'Clearing member', NULL, 'gap'),
    (18, 'Platform identifier', NULL, 'gap'),
    (19, 'Confirmed', NULL, 'gap'),
    (20, 'Final contractual settlement date', NULL, 'gap'),
    (21, 'Settlement currency', NULL, 'gap'),
    (22, 'Clearing account origin', NULL, 'gap'),
    (23, 'Original swap UTI', NULL, 'gap'),
    (24, 'Clearing receipt timestamp', NULL, 'gap'),
    (25, 'Unique transaction identifier (UTI)', NULL, 'gap'),
    (26, 'Prior UTI (for one-to-one and one-to-many relations between transactions)', NULL, 'gap'),
    (27, 'Day count convention', NULL, 'gap'),
    (28, 'Payment frequency period', NULL, 'gap'),
    (29, 'Payment frequency period multiplier', NULL, 'gap'),
    (30, 'Fixing date', NULL, 'gap'),
    (31, 'Floating rate reset frequency period', NULL, 'gap'),
    (32, 'Floating rate reset frequency period multiplier', NULL, 'gap'),
    (33, 'Other payment amount', NULL, 'gap'),
    (34, 'Other payment type', NULL, 'gap'),
    (35, 'Other payment currency', NULL, 'gap'),
    (36, 'Other payment date', NULL, 'gap'),
    (37, 'Other payment payer', NULL, 'gap'),
    (38, 'Other payment receiver', NULL, 'gap'),
    (39, 'Valuation amount', NULL, 'gap'),
    (40, 'Valuation currency', NULL, 'gap'),
    (41, 'Valuation timestamp', NULL, 'gap'),
    (42, 'Valuation method', NULL, 'gap'),
    (43, 'Delta', NULL, 'gap'),
    (44, 'Collateral portfolio indicator', NULL, 'gap'),
    (45, 'Initial margin posted by the reporting counterparty (pre-haircut)', NULL, 'gap'),
    (46, 'Initial margin posted by the reporting counterparty (post-haircut)', NULL, 'gap'),
    (47, 'Currency of initial margin posted', NULL, 'gap'),
    (48, 'Initial margin collected by the reporting counterparty (pre-haircut)', NULL, 'gap'),
    (49, 'Initial margin collected by the reporting counterparty (post-haircut)', NULL, 'gap'),
    (50, 'Currency of initial margin collected', NULL, 'gap'),
    (51, 'Variation margin posted by the reporting counterparty (pre-haircut)', NULL, 'gap'),
    (52, 'Variation margin posted by the reporting counterparty (post-haircut)', NULL, 'gap'),
    (53, 'Currency of variation margin posted', NULL, 'gap'),
    (54, 'Variation margin collected by the reporting counterparty (pre-haircut)', NULL, 'gap'),
    (55, 'Variation margin collected by the reporting counterparty (post-haircut)', NULL, 'gap'),
    (56, 'Currency of variation margin collected', NULL, 'gap'),
    (57, 'Excess collateral posted by the reporting counterparty', NULL, 'gap'),
    (58, 'Currency of excess collateral posted', NULL, 'gap'),
    (59, 'Excess collateral collected by the reporting counterparty', NULL, 'gap'),
    (60, 'Currency of excess collateral collected', NULL, 'gap'),
    (61, 'Collateralisation category', NULL, 'gap'),
    (62, 'Initial margin collateral portfolio code', NULL, 'gap'),
    (63, 'Variation margin collateral portfolio code', NULL, 'gap'),
    (64, 'Price', 'TRADES.PRICE', 'mapped'),
    (65, 'Price currency', 'TRADES.CURRENCY', 'mapped'),
    (66, 'Price notation', NULL, 'gap'),
    (67, 'Price unit of measure', NULL, 'gap'),
    (68, 'Price schedules - Unadjusted effective date of the price', NULL, 'gap'),
    (69, 'Price schedules - Unadjusted end date of the price', NULL, 'gap'),
    (70, 'Price schedules - Price in effect between the unadjusted effective date and unadjusted end date inclusive', NULL, 'gap'),
    (71, 'Fixed rate', NULL, 'gap'),
    (72, 'Spread', NULL, 'gap'),
    (73, 'Spread currency', NULL, 'gap'),
    (74, 'Spread notation', NULL, 'gap'),
    (75, 'Strike price', NULL, 'gap'),
    (76, 'Strike price currency/currency pair', NULL, 'gap'),
    (77, 'Strike price notation', NULL, 'gap'),
    (78, 'Strike price schedules - Unadjusted effective date of the strike price', NULL, 'gap'),
    (79, 'Strike price schedules - Unadjusted end date of the strike price', NULL, 'gap'),
    (80, 'Strike price schedules - Strike price in effect between the unadjusted effective date and unadjusted end date inclusive', NULL, 'gap'),
    (81, 'Option premium amount', NULL, 'gap'),
    (82, 'Option premium currency', NULL, 'gap'),
    (83, 'Option premium payment date', NULL, 'gap'),
    (84, 'First exercise date', NULL, 'gap'),
    (85, 'Exchange rate', NULL, 'gap'),
    (86, 'Exchange rate basis', NULL, 'gap'),
    (87, 'Notional amount', NULL, 'gap'),
    (88, 'Call amount', NULL, 'gap'),
    (89, 'Put amount', NULL, 'gap'),
    (90, 'Notional currency', NULL, 'gap'),
    (91, 'Call currency', NULL, 'gap'),
    (92, 'Put currency', NULL, 'gap'),
    (93, 'Quantity unit of measure', NULL, 'gap'),
    (94, 'Notional amount schedule - notional amount in effect on associated effective date', NULL, 'gap'),
    (95, 'Notional amount schedule - unadjusted effective date of the notional amount', NULL, 'gap'),
    (96, 'Notional amount schedule - unadjusted end date of the notional amount', NULL, 'gap'),
    (97, 'Total notional quantity', NULL, 'gap'),
    (98, 'Notional quantity schedules - Unadjusted date on which the associated notional quantity becomes effective', NULL, 'gap'),
    (99, 'Notional quantity schedules - Unadjusted end date of the notional quantity', NULL, 'gap'),
    (100, 'Notional quantity schedules - Notional quantity which becomes effective on the associated unadjusted effective date', NULL, 'gap'),
    (101, 'Action type', NULL, 'gap'),
    (102, 'Event type', NULL, 'gap'),
    (103, 'Event identifier', NULL, 'gap'),
    (104, 'Event timestamp', NULL, 'gap'),
    (105, 'Index factor', NULL, 'gap'),
    (106, 'Embedded option type', NULL, 'gap'),
    (107, 'Unique product identifier', NULL, 'gap'),
    (108, 'Delivery type', NULL, 'gap'),
    (109, 'Asset Class', NULL, 'gap'),
    (110, 'Underlying identification type', NULL, 'gap'),
    (111, 'Underlying identification', NULL, 'gap'),
    (112, 'Indicator of the underlying index', NULL, 'gap'),
    (113, 'Name of the underlying index', NULL, 'gap'),
    (114, 'Reference entity', NULL, 'gap'),
    (115, 'Indicator of the floating rate', NULL, 'gap'),
    (116, 'Name of the floating rate', NULL, 'gap'),
    (117, 'Floating rate reference period - time period', NULL, 'gap'),
    (118, 'Floating rate reference period - multiplier', NULL, 'gap'),
    (119, 'Derivative based on crypto-assets', NULL, 'gap'),
    (120, 'Maturity date of the underlying', NULL, 'gap'),
    (121, 'Seniority (CD)', NULL, 'gap'),
    (122, 'Series (CD)', NULL, 'gap'),
    (123, 'Version (CD)', NULL, 'gap'),
    (124, 'CDS index attachment point', NULL, 'gap'),
    (125, 'CDS index detachment point', NULL, 'gap'),
    (126, 'Custom basket code', NULL, 'gap'),
    (127, 'Identifier of the basket''s constituents', NULL, 'gap'),
    (128, 'Basket constituent identifier source', NULL, 'gap'),
    (129, 'Contract type', NULL, 'gap'),
    (130, 'Option style', NULL, 'gap'),
    (131, 'Option type', NULL, 'gap'),
    (132, 'Package identifier', NULL, 'gap'),
    (133, 'Package transaction price', NULL, 'gap'),
    (134, 'Package transaction price currency', NULL, 'gap'),
    (135, 'Package transaction price notation', NULL, 'gap'),
    (136, 'Package transaction spread', NULL, 'gap'),
    (137, 'Package transaction spread currency', NULL, 'gap'),
    (138, 'Package transaction spread notation', NULL, 'gap');

-- ============================================================================
-- RULE_CORPUS -- the real citation backing every field above
-- ============================================================================
INSERT INTO RULE_CORPUS (
    CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, CHUNK_TEXT,
    SOURCE_AUTHORITY, ORIGINAL_LANGUAGE, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT
    'JP-FSA-OTC-DERIV-ART4-1', 'JP',
    'Guidelines for Creating, Recordkeeping and Reporting of Transaction Information specified in Article 4(1) of the Cabinet Office Order on the Regulation of Over-the-Counter Derivatives Transactions, etc. (FSA, December 2022, November 2023 Revision)',
    'FIEA Art. 156-63 to 156-65; Cabinet Office Order No. 48 of 2012, Art. 4(1) -- "List of Reporting Matters"',
    'Under Article 156-63 and Article 156-64 of the FIEA, Financial Instruments Clearing Organization, etc. and Financial Instruments Business Operators, etc. must provide transaction information to a Trade Repository, etc. In addition, under Article 156-65 of the FIEA, the TR must prepare and preserve records on matters specified in Article 4, Paragraph 1 of the Cabinet Office Order with respect to the transaction information provided ..., and report the retained transaction information to the Prime Minister. These Guidelines provide ... details of matters specified in Article 4, Paragraph 1 of the Cabinet Office Order. [List of Reporting Matters, 138 numbered data elements across categories: transaction date/time; valuation, collateral and margin; clearing and transaction identification; day-count/payment matters; transaction prices; contract-type matters; and package-transaction matters -- each element'' s definition sourced from the internationally harmonized CDE (Critical Data Elements) standard, or CFTC/ESMA equivalents.] Please refer to "CFTC Technical Specification Parts 43 and 45 swap data reporting and public dissemination requirements August 30, 2022 Version 3.1" and the "Harmonisation of critical OTC derivatives data elements (other than UTI and UPI) Revised CDE Technical Guidance -- version 3" published by the ROC for the items so marked.',
    'translation', 'ja', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed';

-- ============================================================================
-- REPORT_TEMPLATE_RULE_CHUNKS -- link every one of the 138 fields to the chunk above
-- ============================================================================
INSERT INTO REPORT_TEMPLATE_RULE_CHUNKS (
    JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, RULE_CHUNK_ID, IS_ACTIVE,
    CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT 'JP', 'otc_derivative_transaction_report', FIELD_NAME, 'JP-FSA-OTC-DERIV-ART4-1', TRUE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM REPORT_TEMPLATES_CURRENT
WHERE JURISDICTION_ID = 'JP' AND REPORT_TYPE = 'otc_derivative_transaction_report';
