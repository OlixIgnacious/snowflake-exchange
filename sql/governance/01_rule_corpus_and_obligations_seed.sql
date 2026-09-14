-- Real regulatory content for RULE_CORPUS/OBLIGATION_MAP/OBLIGATION_RULE_CHUNKS -- closing the
-- gap flagged repeatedly in docs/queries_by_workflow.md and NOTES.md: these tables existed as
-- empty DDL shells since Phase 2, with real FSA/SESC/JPX rule-text sourcing tracked as an
-- explicit, un-started backlog item (architecture.md line 162, plan.md line 189). This is that
-- sourcing pass -- five real citations, one per detector family, fetched live from the
-- authoritative sources' own sites and verified verbatim against the downloaded documents before
-- being loaded (see NOTES.md for the run log and source URLs).
--
-- Sources (both primary, both fetched 2026-09-14):
--   1. Financial Instruments and Exchange Act (Act No. 25 of 1948) -- FSA's own English
--      translation, https://www.fsa.go.jp/common/law/fie01.pdf. The translation itself states:
--      "Only the original Japanese texts of laws and regulations have legal effect... translations
--      are to be used solely as reference material" -- hence SOURCE_AUTHORITY='translation' /
--      ORIGINAL_LANGUAGE='ja' throughout, per architecture.md design rule #6, even though this is
--      the government's own published English version.
--   2. Operational Procedures Related to the Handling of Commodity Futures and Options Positions
--      (Osaka Exchange, Ver. 1.3, July 2024), https://www.jpx.co.jp/english/derivatives/rules/
--      outline/dreu250000001ove-att/OperationalProcedures_OpenInterest_e_OSE.pdf -- same caveat:
--      the underlying rule is JPX/OSE's own Japanese-language business regulation, this is its
--      English operational-procedures rendering.
--
-- Honesty note on JP-RPTTIME-001: the OSE citation is a real, verbatim T+1-business-day reporting
-- deadline, but it is OSE's *large position report* deadline, not a located citation of Japan's
-- own transaction-report deadline rule specifically (still not sourced -- see OBLIGATION_
-- DESCRIPTION below). It is cited here because it is the real-world regulatory precedent for the
-- T+1-business-day submission-timeliness *pattern* generator/generate.py and sql/detectors/
-- 05_reporting_timeliness.sql already implement, not because it is a 1:1 match to Japan's actual
-- transaction-reporting regime. Do not present it as more precise than that.
--
-- REPORT_TEMPLATE_RULE_CHUNKS is deliberately NOT populated in this pass: citing which exact
-- ordinance/form requires a specific report field (e.g. TRANSACTION_REPORTS' Trading_Capacity gap
-- field) needs the underlying Cabinet Office Ordinance's prescribed form specification, which
-- this search pass did not turn up a precise citation for (see NOTES.md) -- left open rather than
-- forcing a citation that doesn't actually say what the field requires.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE GOVERNANCE_WRITE;
USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- RULE_CORPUS -- five real chunks, one per detector family
-- ============================================================================
INSERT INTO RULE_CORPUS (
    CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF, CHUNK_TEXT,
    SOURCE_AUTHORITY, ORIGINAL_LANGUAGE, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT column1, column2, column3, column4, column5, column6, column7,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
(
    'JP-FIEA-159-1-I', 'JP',
    'Financial Instruments and Exchange Act (Act No. 25 of 1948)',
    'Article 159, Paragraph 1, Item (i)',
    'No person shall commit the following acts for the purpose of misleading other persons into believing sales and purchase of Securities... Market Transactions of Derivatives or Over-the-Counter Transactions of Derivatives... are thriving or otherwise misleading other persons about state of these transactions: (i) to conduct fake sales and purchase of Securities, fake Market Transactions of Derivatives... or fake Over-the-Counter Transactions of Derivatives... without purpose of transfer of right;',
    'translation', 'ja'
),
(
    'JP-FIEA-159-2-I', 'JP',
    'Financial Instruments and Exchange Act (Act No. 25 of 1948)',
    'Article 159, Paragraph 2, Item (i)',
    'No person shall commit any of the following acts for the purpose of inducing sales and purchase of Securities, Market Transactions of Derivatives or Over-the-Counter Transactions of Derivatives (hereinafter referred to as "Sales and Purchase of Securities, etc." in this Article): (i) to conduct a series of Sales and Purchase of Securities, etc. or make an offer, Entrustment, etc. or Accepting an Entrustment, etc. therefor that would mislead other persons into believing that Sales and Purchase of Securities, etc. are thriving or would cause fluctuations in prices of Listed Financial Instruments, etc.... in a Financial Instruments Exchange Market or prices of Over-the-Counter Traded Securities in an Over-the-Counter Securities Market;',
    'translation', 'ja'
),
(
    'JP-FIEA-40-2', 'JP',
    'Financial Instruments and Exchange Act (Act No. 25 of 1948)',
    'Article 40-2, Paragraphs 1 and 3 (Best Execution Policy)',
    '(1) A Financial Instruments Business Operator, etc. shall, pursuant to the provisions of a Cabinet Order, establish a policy and method for executing orders from customers for sales and purchase of Securities and Derivative Transactions... under the best terms and conditions (hereinafter referred to as the "Best Execution Policy, etc." in this Article)... (3) A Financial Instruments Business Operator, etc. shall execute orders for Transactions of Securities, etc. in accordance with its Best Execution Policy, etc.',
    'translation', 'ja'
),
(
    'JP-OSE-OPS-IV', 'JP',
    'Operational Procedures Related to the Handling of Commodity Futures and Options Positions (Osaka Exchange, Ver. 1.3, July 2024)',
    'Section IV, Position Limits',
    'The following limits shall be applied to the long and the short positions in the participant''s own account and in its customer accounts... Participants must reduce the positions of their customers to within the position limit that is specified by OSE as soon as possible when said customers'' positions have exceeded or come to exceed said position limit (including cases where OSE deems that said positions have exceeded said position limit).',
    'translation', 'ja'
),
(
    'JP-OSE-OPS-III-1-1', 'JP',
    'Operational Procedures Related to the Handling of Commodity Futures and Options Positions (Osaka Exchange, Ver. 1.3, July 2024)',
    'Section III(1-1), Reporting Deadline',
    'Participants and eligible intermediaries must report to OSE on a trading day basis the details of any long or short positions in applicable commodity derivatives contracts that are held by the same customer when said positions meet the reporting criteria... (1-1) Reporting Deadline: As a general rule, by 1:00 p.m. on the business day following the trading day.',
    'translation', 'ja'
);

-- ============================================================================
-- OBLIGATION_MAP -- proposed rows (Fix #12: STATUS starts 'proposed')
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
    'JP-WASH-001', 'JP',
    'Prohibition of wash sales / fictitious securities transactions conducted without intent to transfer beneficial ownership, used to create a false impression of trading activity (FIEA Art. 159(1)(i)). VIGIL detects candidate matches via WASH_TRADING_CANDIDATES, scoped to non-exempt matched trades between related beneficial owners.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading'
),
(
    'JP-SPOOF-001', 'JP',
    'Prohibition of a series of orders/trades intended to mislead other persons into believing trading is thriving or to move prices (FIEA Art. 159(2)(i)) -- covers spoofing/layering via repeated submit-then-cancel order patterns. VIGIL flags participants whose cancel-to-submit ratio spikes materially above their own baseline.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering'
),
(
    'JP-POSLIM-001', 'JP',
    'Position limits imposed on long/short positions in commodity derivatives contracts per participant/customer account, with a duty to reduce an exceeded position (Osaka Exchange Operational Procedures, Section IV). VIGIL flags accounts whose net position exceeds the calibrated limit.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit'
),
(
    'JP-RPTTIME-001', 'JP',
    'Reporting deadline for a regulator-facing filing must be submitted by a fixed time-of-day on the business day following the trading day (Osaka Exchange Operational Procedures, Section III(1-1) -- cited as the real-world source for the T+1-business-day submission-timeliness pattern VIGIL applies to TRANSACTION_REPORTS deadlines; this is OSE''s large-position-report deadline specifically, not a citation of Japan''s own FIEA transaction-report deadline rule, which has not yet been sourced). VIGIL flags reports submitted after their business-day-adjusted effective deadline.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness'
),
(
    'JP-BESTEX-001', 'JP',
    'Duty to establish, disclose, and execute customer orders in listed securities/derivatives in accordance with a Best Execution Policy (FIEA Art. 40-2, paragraphs 1 and 3). VIGIL checks executed trade prices against the prevailing reference price at execution time.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution'
);

-- ============================================================================
-- Approve each obligation via SP_APPROVE_OBLIGATION (Fix #9 validation + Fix #12 new-row flip)
-- ============================================================================
CALL SP_APPROVE_OBLIGATION('JP-WASH-001', 'JP',
    'Prohibition of wash sales / fictitious securities transactions conducted without intent to transfer beneficial ownership, used to create a false impression of trading activity (FIEA Art. 159(1)(i)). VIGIL detects candidate matches via WASH_TRADING_CANDIDATES, scoped to non-exempt matched trades between related beneficial owners.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading');

CALL SP_APPROVE_OBLIGATION('JP-SPOOF-001', 'JP',
    'Prohibition of a series of orders/trades intended to mislead other persons into believing trading is thriving or to move prices (FIEA Art. 159(2)(i)) -- covers spoofing/layering via repeated submit-then-cancel order patterns. VIGIL flags participants whose cancel-to-submit ratio spikes materially above their own baseline.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering');

CALL SP_APPROVE_OBLIGATION('JP-POSLIM-001', 'JP',
    'Position limits imposed on long/short positions in commodity derivatives contracts per participant/customer account, with a duty to reduce an exceeded position (Osaka Exchange Operational Procedures, Section IV). VIGIL flags accounts whose net position exceeds the calibrated limit.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit');

CALL SP_APPROVE_OBLIGATION('JP-RPTTIME-001', 'JP',
    'Reporting deadline for a regulator-facing filing must be submitted by a fixed time-of-day on the business day following the trading day (Osaka Exchange Operational Procedures, Section III(1-1) -- cited as the real-world source for the T+1-business-day submission-timeliness pattern VIGIL applies to TRANSACTION_REPORTS deadlines; this is OSE''s large-position-report deadline specifically, not a citation of Japan''s own FIEA transaction-report deadline rule, which has not yet been sourced). VIGIL flags reports submitted after their business-day-adjusted effective deadline.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness');

CALL SP_APPROVE_OBLIGATION('JP-BESTEX-001', 'JP',
    'Duty to establish, disclose, and execute customer orders in listed securities/derivatives in accordance with a Best Execution Policy (FIEA Art. 40-2, paragraphs 1 and 3). VIGIL checks executed trade prices against the prevailing reference price at execution time.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution');

-- ============================================================================
-- OBLIGATION_RULE_CHUNKS -- link each obligation to the rule chunk it's backed by
-- ============================================================================
INSERT INTO OBLIGATION_RULE_CHUNKS (
    OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID, IS_ACTIVE,
    CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
)
SELECT column1, 'JP', column2, TRUE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'claude_code_rule_seed'
FROM VALUES
    ('JP-WASH-001', 'JP-FIEA-159-1-I'),
    ('JP-SPOOF-001', 'JP-FIEA-159-2-I'),
    ('JP-POSLIM-001', 'JP-OSE-OPS-IV'),
    ('JP-RPTTIME-001', 'JP-OSE-OPS-III-1-1'),
    ('JP-BESTEX-001', 'JP-FIEA-40-2');
