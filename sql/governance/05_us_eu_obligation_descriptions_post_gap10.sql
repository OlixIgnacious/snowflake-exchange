-- Corrects a real accuracy issue created by closing review finding "market-agnostic is proven
-- for one jurisdiction only" (gap 10): all 10 US/EU obligation descriptions said "No US/EU trade
-- data exists yet -- currently unexercised" -- true when they were approved 2026-09-15, false
-- as of the same day once real US/EU synthetic data was loaded (generator/jurisdiction_config.py
-- US_CONFIG/EU_CONFIG, scripts/load_us_eu_configs.py). Leaving the stale claim in place would
-- have been a new, self-inflicted inaccuracy -- the same "surfaced, not fabricated" discipline
-- this project applies to gaps applies here in reverse: a claim that's gone stale needs
-- correcting, not left to quietly mislead.
--
-- Each call is a new approved row (Fix #12 -- same OBLIGATION_ID, later LOADED_AT, never an
-- UPDATE) with a description replacing "currently unexercised" with the real, live-verified
-- finding counts as of this run. SOURCE_TABLE/SOURCE_COLUMNS/DETECTOR_NAME are unchanged (only
-- the description is being corrected) but still re-validated against INFORMATION_SCHEMA by
-- SP_APPROVE_OBLIGATION regardless, same as every other call.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE GOVERNANCE_WRITE;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CALL SP_APPROVE_OBLIGATION('US-WASH-001', 'US',
    'Prohibition of wash sales and matched orders creating a false or misleading appearance of active trading, without a genuine change in beneficial ownership (Exchange Act Sec 9(a)(1)). Real US synthetic trade data loaded 2026-09-15 (8 live-verified venues -- generator/jurisdiction_config.py US_CONFIG): 37 wash-trading candidates found, 36 non-exempt, as of that load.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading');

CALL SP_APPROVE_OBLIGATION('US-SPOOF-001', 'US',
    'Prohibition of "spoofing" -- bidding or offering with the intent to cancel before execution (CEA Sec 4c(a)(5)(C), the statute that coined the term). Real US synthetic trade data loaded 2026-09-15: 4 flagged spoofing/layering signals as of that load.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering');

CALL SP_APPROVE_OBLIGATION('US-POSLIM-001', 'US',
    'Federal speculative position limits on commodity futures/options -- no person may hold or control a net position (spot month or all-months-combined) in excess of Commission-specified levels (17 CFR 150.2(a)-(b)). Real US synthetic trade data loaded 2026-09-15: 0 breaches as of that load (a real, checked result -- not "uncheckable").',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit');

CALL SP_APPROVE_OBLIGATION('US-RPTTIME-001', 'US',
    'Consolidated Audit Trail reportable-event deadline: reports for events occurring on a Trading Day must be submitted by 8:00 a.m. Eastern Time on the following Trading Day, per the CAT NMS Plan implementing SEC Rule 613. Real US synthetic trade data loaded 2026-09-15: 81 late submissions, 0 overdue-unsubmitted, as of that load.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness');

CALL SP_APPROVE_OBLIGATION('US-BESTEX-001', 'US',
    'Duty to use reasonable diligence to ascertain the best market for a security so the resultant price is as favorable as possible under prevailing market conditions (FINRA Rule 5310(a)(1)). Real US synthetic trade data loaded 2026-09-15: 774 of 884 trades have a usable reference price (mean EXECUTION_SLIPPAGE_PCT ~1.9%, a same-instrument/venue VWAP benchmark, not a real market feed) as of that load.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution');

CALL SP_APPROVE_OBLIGATION('EU-WASH-001', 'EU',
    'Market manipulation via transactions/orders giving false or misleading signals, operationalized for wash trades via the "no change in beneficial ownership" indicator (MAR Art. 12(1)(a) + Annex I Section A(c)). Real EU synthetic trade data loaded 2026-09-15 (4 live-verified Deutsche Börse Group venues -- generator/jurisdiction_config.py EU_CONFIG): 33 wash-trading candidates found, 32 non-exempt, as of that load.',
    'WASH_TRADING_CANDIDATES', 'TRADE_ID_1,TRADE_ID_2,BENEFICIAL_OWNER_ID,IS_TRIGGER_EXEMPT', 'wash_trading');

CALL SP_APPROVE_OBLIGATION('EU-SPOOF-001', 'EU',
    'Market manipulation via placing orders (including cancellation/modification) that disrupt the trading system, obscure genuine orders, or create a false signal of supply/demand/price -- i.e. layering and spoofing (MAR Art. 12(2)(c)). Real EU synthetic trade data loaded 2026-09-15: 5 flagged spoofing/layering signals as of that load.',
    'SPOOFING_LAYERING_SIGNALS', 'CANCEL_RATIO,CANCEL_RATIO_ZSCORE,IS_FLAGGED', 'spoofing_layering');

CALL SP_APPROVE_OBLIGATION('EU-POSLIM-001', 'EU',
    'Position limits on the net position a person can hold at all times in commodity derivatives traded on trading venues, set to prevent market abuse and support orderly pricing (MiFID II Art. 57(1)). Real EU synthetic trade data loaded 2026-09-15: 5 breaches as of that load.',
    'POSITION_LIMIT_BREACHES', 'NET_QUANTITY,LIMIT_QUANTITY,IS_BREACH', 'position_limit');

CALL SP_APPROVE_OBLIGATION('EU-RPTTIME-001', 'EU',
    'Transaction reporting deadline: investment firms must report complete and accurate transaction details to the competent authority as quickly as possible and no later than the close of the following working day (MiFIR Art. 26(1)). Real EU synthetic trade data loaded 2026-09-15: 81 late submissions, 0 overdue-unsubmitted, as of that load.',
    'REPORTING_TIMELINESS_SIGNALS', 'SUBMITTED_AT,EFFECTIVE_DEADLINE,IS_LATE_SUBMISSION,IS_OVERDUE_UNSUBMITTED', 'reporting_timeliness');

CALL SP_APPROVE_OBLIGATION('EU-BESTEX-001', 'EU',
    'Duty to take all sufficient steps to obtain the best possible result for the client when executing orders, considering price, costs, speed, likelihood of execution/settlement, size and nature (MiFID II Art. 27(1)). Real EU synthetic trade data loaded 2026-09-15: 659 of 885 trades have a usable reference price (mean EXECUTION_SLIPPAGE_PCT ~0.2%, a same-instrument/venue VWAP benchmark, not a real market feed) as of that load.',
    'EXECUTION_SLIPPAGE', 'PRICE,REFERENCE_PRICE_AT_EXECUTION,EXECUTION_SLIPPAGE_PCT', 'best_execution');
