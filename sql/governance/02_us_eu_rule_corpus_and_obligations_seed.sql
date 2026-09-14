-- Real regulatory content for US and EU/EMEA, mirroring 01_rule_corpus_and_obligations_seed.sql's
-- Japan pattern exactly: five real citations per jurisdiction, one per detector family, loaded
-- into RULE_CORPUS/OBLIGATION_MAP/OBLIGATION_RULE_CHUNKS via the same SP_APPROVE_OBLIGATION gate.
--
-- Sources (all fetched live 2026-09-15, verified verbatim via pdftotext/direct fetch against the
-- documents saved in docs/sources/ -- see NOTES.md for the run log):
--   US: Securities Exchange Act of 1934 Section 9(a)(1) [15 U.S.C. Sec 78i(a)(1)] (wash sales);
--       Commodity Exchange Act Section 4c(a)(5)(C) [7 U.S.C. Sec 6c(a)(5)(C)] (spoofing, the
--       statute that coined the term); 17 CFR 150.2(a)-(b) (CFTC federal speculative position
--       limits); the CAT NMS Plan's own Reporting Hours FAQ, implementing SEC Rule 613 (17 CFR
--       242.613) -- "8:00 a.m. ET the following Trading Day" deadline; FINRA Rule 5310(a)(1)
--       (best execution).
--   EU: Regulation (EU) No 596/2014 (Market Abuse Regulation / MAR), Article 12(1)(a) + Annex I
--       Section A(c) (wash trades) and Article 12(2)(c) (layering/spoofing); Directive 2014/65/EU
--       (MiFID II) Article 57(1) (position limits) and Article 27(1) (best execution); Regulation
--       (EU) No 600/2014 (MiFIR) Article 26(1) (transaction reporting deadline).
--
-- SOURCE_AUTHORITY note -- deliberately different from the Japan seed: US federal statutes/CFR/
-- FINRA rules are authored and published in English as the sole authoritative text (no
-- translation), and EU regulations are adopted with equal legal force in all official EU
-- languages, English being one of the authentic language versions, not a translation of a
-- non-English original -- unlike Japan's FIEA, where English is explicitly a provisional
-- translation of the legally authoritative Japanese text (architecture.md design rule #6). So
-- these rows use SOURCE_AUTHORITY='original', ORIGINAL_LANGUAGE='en' throughout, correctly
-- distinct from the Japan seed's 'translation'/'ja'.
--
-- Scope note -- read before assuming this means "US/EU are demo-ready": this loads governance
-- CONTENT only (rule text + obligation mappings). It does NOT build US/EU JURISDICTION_CONFIG,
-- venues, participants, or synthetic trade data -- architecture.md is explicit that a full US
-- config is a separate, deliberately-deferred piece of work (live per-venue verification, same
-- discipline Japan went through). The JURISDICTIONS rows below are minimal regulator-level
-- reference rows, not a claim that a full jurisdiction config exists. Querying WASH_TRADING_
-- CANDIDATES/SPOOFING_LAYERING_SIGNALS/etc. WHERE JURISDICTION_ID IN ('US','EU') will honestly
-- return 0 rows until that generator work is done -- these obligations exist and are approved,
-- but there is no trade data yet for them to ever flag anything against.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

-- ============================================================================
-- JURISDICTIONS -- minimal regulator-level reference rows (not a full JURISDICTION_CONFIG)
-- ============================================================================
USE ROLE MARKET_DATA_INGEST;
USE DATABASE VIGIL;
USE SCHEMA CORE;

INSERT INTO JURISDICTIONS (JURISDICTION_ID, REGULATOR_NAME, PRIMARY_LANGUAGE, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY)
SELECT column1, column2, column3,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    ('US', 'SEC / FINRA / CFTC', 'en'),
    ('EU', 'ESMA', 'en');

-- ============================================================================
-- RULE_CORPUS -- ten real chunks, five US + five EU, one per detector family
-- ============================================================================
USE ROLE GOVERNANCE_WRITE;

INSERT INTO RULE_CORPUS (
    CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, CHUNK_TEXT,
    SOURCE_AUTHORITY, ORIGINAL_LANGUAGE, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT column1, column2, column3, column4, column5, column6, column7,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
(
    'US-EXCHACT-9A1', 'US',
    'Securities Exchange Act of 1934 (15 U.S.C. Sec 78a et seq.)',
    'Section 9(a)(1) [15 U.S.C. Sec 78i(a)(1)]',
    'For the purpose of creating a false or misleading appearance of active trading in any security other than a government security, or a false or misleading appearance with respect to the market for any such security, (A) to effect any transaction in such security which involves no change in the beneficial ownership thereof, or (B) to enter an order or orders for the purchase of such security with the knowledge that an order or orders of substantially the same size, at substantially the same time, and at substantially the same price, for the sale of any such security, has been or will be entered by or for the same or different parties, or (C) to enter any order or orders for the sale of any such security with the knowledge that an order or orders of substantially the same size, at substantially the same time, and at substantially the same price, for the purchase of such security, has been or will be entered by or for the same or different parties.',
    'original', 'en'
),
(
    'US-CEA-4C-A5-C', 'US',
    'Commodity Exchange Act (7 U.S.C. Sec 1 et seq.)',
    'Section 4c(a)(5)(C) [7 U.S.C. Sec 6c(a)(5)(C)]',
    'It shall be unlawful for any person to engage in any trading, practice, or conduct on or subject to the rules of a registered entity that... is, is of the character of, or is commonly known to the trade as, "spoofing" (bidding or offering with the intent to cancel the bid or offer before execution).',
    'original', 'en'
),
(
    'US-CFR-17-150-2', 'US',
    'Code of Federal Regulations, Title 17 -- Commodity and Securities Exchanges',
    'Sec 150.2(a)-(b) (CFTC Federal Speculative Position Limits)',
    '(a) Spot month. ...no person may hold or control positions in the spot month, net long or net short, in excess of the levels specified by the Commission. (b) Single month and all-months-combined. ...no person may hold or control positions in a single month or in all-months-combined (including the spot month), net long or net short, in excess of the levels specified by the Commission.',
    'original', 'en'
),
(
    'US-CATNMS-REPORTING-HOURS', 'US',
    'Consolidated Audit Trail NMS Plan (implementing SEC Rule 613, 17 CFR 242.613)',
    'CAT Reporting Hours FAQ (catnmsplan.com)',
    'CAT will accept files 24 hours a day, 7 days a week... Reports for events that occur during a particular Trading Day must be reported by 8:00 a.m., ET the following Trading Day or they are marked late by CAT.',
    'original', 'en'
),
(
    'US-FINRA-5310-A1', 'US',
    'FINRA Rules',
    'Rule 5310(a)(1) (Best Execution and Interpositioning)',
    'In any transaction for or with a customer, a member and persons associated with a member shall use reasonable diligence to ascertain the best market for the subject security and buy or sell in such market so that the resultant price to the customer is as favorable as possible under prevailing market conditions.',
    'original', 'en'
),
(
    'EU-MAR-12-1A-ANNEXI-AC', 'EU',
    'Regulation (EU) No 596/2014 (Market Abuse Regulation)',
    'Article 12(1)(a) and Annex I, Section A(c)',
    'Article 12(1): For the purposes of this Regulation, market manipulation shall comprise the following activities: (a) entering into a transaction, placing an order to trade or any other behaviour which: (i) gives, or is likely to give, false or misleading signals as to the supply of, demand for, or price of, a financial instrument... unless the person entering into a transaction, placing an order to trade or engaging in any other behaviour establishes that such transaction, order or behaviour have been carried out for legitimate reasons, and conform with an accepted market practice. Annex I, Section A(c) (indicator for applying Article 12(1)(a)): whether transactions undertaken lead to no change in beneficial ownership of a financial instrument, a related spot commodity contract, or an auctioned product based on emission allowances.',
    'original', 'en'
),
(
    'EU-MAR-12-2C', 'EU',
    'Regulation (EU) No 596/2014 (Market Abuse Regulation)',
    'Article 12(2)(c)',
    '(2) The following behaviour shall, inter alia, be considered as market manipulation: ... (c) the placing of orders to a trading venue, including any cancellation or modification thereof, by any available means of trading, including by electronic means, such as algorithmic and high-frequency trading strategies, and which has one of the effects referred to in paragraph 1(a) or (b), by: (i) disrupting or delaying the functioning of the trading system of the trading venue or being likely to do so; (ii) making it more difficult for other persons to identify genuine orders on the trading system of the trading venue or being likely to do so, including by entering orders which result in the overloading or destabilisation of the order book; or (iii) creating or being likely to create a false or misleading signal about the supply of, or demand for, or price of, a financial instrument, in particular by entering orders to initiate or exacerbate a trend.',
    'original', 'en'
),
(
    'EU-MIFID2-57-1', 'EU',
    'Directive 2014/65/EU (MiFID II)',
    'Article 57(1)',
    '1. Member States shall ensure that competent authorities, in line with the methodology for calculation determined by ESMA, establish and apply position limits on the size of a net position which a person can hold at all times in commodity derivatives traded on trading venues and economically equivalent OTC contracts. The limits shall be set on the basis of all positions held by a person and those held on its behalf at an aggregate group level in order to: (a) prevent market abuse; (b) support orderly pricing and settlement conditions, including preventing market distorting positions, and ensuring, in particular, convergence between prices of derivatives in the delivery month and spot prices for the underlying commodity, without prejudice to price discovery on the market for the underlying commodity. Position limits shall not apply to positions held by or on behalf of a non-financial entity and which are objectively measurable as reducing risks directly relating to the commercial activity of that non-financial entity.',
    'original', 'en'
),
(
    'EU-MIFIR-26-1', 'EU',
    'Regulation (EU) No 600/2014 (MiFIR)',
    'Article 26(1)',
    '1. Investment firms which execute transactions in financial instruments shall report complete and accurate details of such transactions to the competent authority as quickly as possible, and no later than the close of the following working day.',
    'original', 'en'
),
(
    'EU-MIFID2-27-1', 'EU',
    'Directive 2014/65/EU (MiFID II)',
    'Article 27(1)',
    '1. Member States shall require that investment firms take all sufficient steps to obtain, when executing orders, the best possible result for their clients taking into account price, costs, speed, likelihood of execution and settlement, size, nature or any other consideration relevant to the execution of the order. Nevertheless, where there is a specific instruction from the client the investment firm shall execute the order following the specific instruction.',
    'original', 'en'
);

-- ============================================================================
-- OBLIGATION_MAP -- proposed rows, ten obligations
-- ============================================================================
INSERT INTO OBLIGATION_MAP (
    OBLIGATION_ID, JURISDICTION_ID, OBLIGATION_DESCRIPTION, SOURCE_TABLE, SOURCE_COLUMNS,
    DETECTOR_NAME, STATUS, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT column1, column2, column3, column4, column5, column6, 'proposed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
(
    'US-WASH-001', 'US',
    'Prohibition of wash sales and matched orders creating a false or misleading appearance of active trading, without a genuine change in beneficial ownership (Exchange Act Sec 9(a)(1)). No US trade data exists yet -- this obligation is approved but currently unexercised (0 rows expected from WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID=''US'').',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading'
),
(
    'US-SPOOF-001', 'US',
    'Prohibition of "spoofing" -- bidding or offering with the intent to cancel before execution (CEA Sec 4c(a)(5)(C), the statute that coined the term). No US trade data exists yet -- currently unexercised.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering'
),
(
    'US-POSLIM-001', 'US',
    'Federal speculative position limits on commodity futures/options -- no person may hold or control a net position (spot month or all-months-combined) in excess of Commission-specified levels (17 CFR 150.2(a)-(b)). No US trade data exists yet -- currently unexercised.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit'
),
(
    'US-RPTTIME-001', 'US',
    'Consolidated Audit Trail reportable-event deadline: reports for events occurring on a Trading Day must be submitted by 8:00 a.m. Eastern Time on the following Trading Day, per the CAT NMS Plan implementing SEC Rule 613. No US trade data exists yet -- currently unexercised.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness'
),
(
    'US-BESTEX-001', 'US',
    'Duty to use reasonable diligence to ascertain the best market for a security so the resultant price is as favorable as possible under prevailing market conditions (FINRA Rule 5310(a)(1)). No US trade data exists yet -- currently unexercised.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution'
),
(
    'EU-WASH-001', 'EU',
    'Market manipulation via transactions/orders giving false or misleading signals, operationalized for wash trades via the "no change in beneficial ownership" indicator (MAR Art. 12(1)(a) + Annex I Section A(c)). No EU trade data exists yet -- currently unexercised.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading'
),
(
    'EU-SPOOF-001', 'EU',
    'Market manipulation via placing orders (including cancellation/modification) that disrupt the trading system, obscure genuine orders, or create a false signal of supply/demand/price -- i.e. layering and spoofing (MAR Art. 12(2)(c)). No EU trade data exists yet -- currently unexercised.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering'
),
(
    'EU-POSLIM-001', 'EU',
    'Position limits on the net position a person can hold at all times in commodity derivatives traded on trading venues, set to prevent market abuse and support orderly pricing (MiFID II Art. 57(1)). No EU trade data exists yet -- currently unexercised.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit'
),
(
    'EU-RPTTIME-001', 'EU',
    'Transaction reporting deadline: investment firms must report complete and accurate transaction details to the competent authority as quickly as possible and no later than the close of the following working day (MiFIR Art. 26(1)). No EU trade data exists yet -- currently unexercised.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness'
),
(
    'EU-BESTEX-001', 'EU',
    'Duty to take all sufficient steps to obtain the best possible result for the client when executing orders, considering price, costs, speed, likelihood of execution/settlement, size and nature (MiFID II Art. 27(1)). No EU trade data exists yet -- currently unexercised.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution'
);

-- ============================================================================
-- Approve each obligation via SP_APPROVE_OBLIGATION (same Fix #9/#12 gate as Japan)
-- ============================================================================
CALL SP_APPROVE_OBLIGATION('US-WASH-001', 'US',
    'Prohibition of wash sales and matched orders creating a false or misleading appearance of active trading, without a genuine change in beneficial ownership (Exchange Act Sec 9(a)(1)). No US trade data exists yet -- this obligation is approved but currently unexercised (0 rows expected from WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID=''US'').',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading');

CALL SP_APPROVE_OBLIGATION('US-SPOOF-001', 'US',
    'Prohibition of "spoofing" -- bidding or offering with the intent to cancel before execution (CEA Sec 4c(a)(5)(C), the statute that coined the term). No US trade data exists yet -- currently unexercised.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering');

CALL SP_APPROVE_OBLIGATION('US-POSLIM-001', 'US',
    'Federal speculative position limits on commodity futures/options -- no person may hold or control a net position (spot month or all-months-combined) in excess of Commission-specified levels (17 CFR 150.2(a)-(b)). No US trade data exists yet -- currently unexercised.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit');

CALL SP_APPROVE_OBLIGATION('US-RPTTIME-001', 'US',
    'Consolidated Audit Trail reportable-event deadline: reports for events occurring on a Trading Day must be submitted by 8:00 a.m. Eastern Time on the following Trading Day, per the CAT NMS Plan implementing SEC Rule 613. No US trade data exists yet -- currently unexercised.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness');

CALL SP_APPROVE_OBLIGATION('US-BESTEX-001', 'US',
    'Duty to use reasonable diligence to ascertain the best market for a security so the resultant price is as favorable as possible under prevailing market conditions (FINRA Rule 5310(a)(1)). No US trade data exists yet -- currently unexercised.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution');

CALL SP_APPROVE_OBLIGATION('EU-WASH-001', 'EU',
    'Market manipulation via transactions/orders giving false or misleading signals, operationalized for wash trades via the "no change in beneficial ownership" indicator (MAR Art. 12(1)(a) + Annex I Section A(c)). No EU trade data exists yet -- currently unexercised.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading');

CALL SP_APPROVE_OBLIGATION('EU-SPOOF-001', 'EU',
    'Market manipulation via placing orders (including cancellation/modification) that disrupt the trading system, obscure genuine orders, or create a false signal of supply/demand/price -- i.e. layering and spoofing (MAR Art. 12(2)(c)). No EU trade data exists yet -- currently unexercised.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering');

CALL SP_APPROVE_OBLIGATION('EU-POSLIM-001', 'EU',
    'Position limits on the net position a person can hold at all times in commodity derivatives traded on trading venues, set to prevent market abuse and support orderly pricing (MiFID II Art. 57(1)). No EU trade data exists yet -- currently unexercised.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit');

CALL SP_APPROVE_OBLIGATION('EU-RPTTIME-001', 'EU',
    'Transaction reporting deadline: investment firms must report complete and accurate transaction details to the competent authority as quickly as possible and no later than the close of the following working day (MiFIR Art. 26(1)). No EU trade data exists yet -- currently unexercised.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness');

CALL SP_APPROVE_OBLIGATION('EU-BESTEX-001', 'EU',
    'Duty to take all sufficient steps to obtain the best possible result for the client when executing orders, considering price, costs, speed, likelihood of execution/settlement, size and nature (MiFID II Art. 27(1)). No EU trade data exists yet -- currently unexercised.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution');

-- ============================================================================
-- OBLIGATION_RULE_CHUNKS -- link each obligation to the rule chunk it's backed by
-- ============================================================================
INSERT INTO OBLIGATION_RULE_CHUNKS (
    OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID, IS_ACTIVE,
    CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT column1, column2, column3, TRUE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    ('US-WASH-001', 'US', 'US-EXCHACT-9A1'),
    ('US-SPOOF-001', 'US', 'US-CEA-4C-A5-C'),
    ('US-POSLIM-001', 'US', 'US-CFR-17-150-2'),
    ('US-RPTTIME-001', 'US', 'US-CATNMS-REPORTING-HOURS'),
    ('US-BESTEX-001', 'US', 'US-FINRA-5310-A1'),
    ('EU-WASH-001', 'EU', 'EU-MAR-12-1A-ANNEXI-AC'),
    ('EU-SPOOF-001', 'EU', 'EU-MAR-12-2C'),
    ('EU-POSLIM-001', 'EU', 'EU-MIFID2-57-1'),
    ('EU-RPTTIME-001', 'EU', 'EU-MIFIR-26-1'),
    ('EU-BESTEX-001', 'EU', 'EU-MIFID2-27-1');
