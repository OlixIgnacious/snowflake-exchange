# architecture.md

## What this is

**Vigil** — a citation-backed exchange/securities-market regulatory reporting and surveillance copilot, built on Snowflake's Cortex/CoCo stack. Full pivot from a prior banking-credit-risk prototype (`Praman`, a sibling hackathon repo) to a different regulatory domain: **exchange market conduct, position/exposure limits, post-trade transaction reporting, and best execution** — not bank Basel/Pillar-3 reporting. Same Snowflake account as `Praman`, disjoint schema (`VIGIL.CORE` / `VIGIL.EVAL`), no shared objects.

**Design mandate, different from how `Praman` was built:** market-agnostic from the first line of DDL, not retrofitted after a single-market prototype. `Praman`'s own `plug_and_play_architecture.md` found that jurisdiction-agnostic design bolted on afterward still left real gaps (hardcoded currency, hardcoded thresholds, an implicit assumption the schema never needs to change). This project applies those findings as day-one constraints instead of after-the-fact fixes — see "Market-agnostic design rules" below, and note in each section where a rule exists specifically because of a documented `Praman` mistake.

## Scope: four obligation types, one canonical schema

1. **Trade surveillance / market conduct** — wash trading, spoofing/layering, abnormal volume/price patterns.
2. **Position/exposure limits** — concentration of a position in an instrument vs. a regulatory threshold.
3. **Post-trade transaction reporting** — timeliness, completeness, and accuracy of trade reports submitted to a regulator/exchange.
4. **Best execution / order reporting** — execution price vs. a reference price, order-routing quality.

These share one schema and one detector framework the same way `Praman`'s four stages shared one banking schema — the four obligation types are different *queries* over the same core entities (orders, trades, positions, submitted reports), not four independent data models.

## Data model

```
INSTRUMENTS ──┐
              │
MARKET_       ├──< ORDERS >──< TRADES >──< TRANSACTION_REPORTS
PARTICIPANTS ─┘         │           │
                         │           │
                         └──< POSITIONS (derived, per participant x instrument x as_of_date)
```

- **`INSTRUMENTS`** — market-published reference data. `INSTRUMENT_ID` (venue-local code, e.g. NSE symbol / JPX code / ticker — never assumed to be globally unique across markets), `MARKET_ID`, `ISIN` (nullable — not every market assigns one), `INSTRUMENT_TYPE`, `TICK_SIZE`, `LOT_SIZE`.
- **`MARKET_PARTICIPANTS`** — brokers/members/counterparties. `PARTICIPANT_ID`, `MARKET_ID`, `PARTICIPANT_TYPE` (broker/proprietary/institutional/retail), `BENEFICIAL_OWNER_ID` (nullable — the entity actually economically behind the participant, needed for wash-trading detection across nominee accounts).
- **`ORDERS`** — every order submitted, not just filled ones. `ORDER_ID`, `INSTRUMENT_ID`, `PARTICIPANT_ID`, `SIDE` (buy/sell), `ORDER_TYPE`, `SUBMITTED_TS`, `MODIFIED_TS` (nullable), `CANCELLED_TS` (nullable), `PRICE`, `QUANTITY`, `FILLED_QUANTITY`. Cancelled-but-unfilled orders are the raw material for spoofing/layering detection — this table exists specifically because `TRADES` alone (executed only) can't see a cancel pattern.
- **`TRADES`** — executed trades. `TRADE_ID`, `ORDER_ID` (FK, nullable if trade data arrives without order linkage from a given market's feed — documented as a real per-market variance, not assumed away), `INSTRUMENT_ID`, `EXECUTION_TIMESTAMP`, `PRICE`, `VOLUME`, `COUNTERPARTY_PARTICIPANT_ID` (the other side of the trade, when disclosed by the venue).
- **`POSITIONS`** — per `PARTICIPANT_ID` x `INSTRUMENT_ID` x `AS_OF_DATE`, `NET_QUANTITY`, `MARKET_VALUE`. Same semi-additive shape as `Praman.POSITIONS` (never summed across `AS_OF_DATE`, only within it) — this pattern is reused because it's a correct, already-tested modeling choice, not because the domain requires it.
- **`TRANSACTION_REPORTS`** — the actual submission record to the regulator/exchange. `REPORT_ID`, `TRADE_ID` (FK), `SUBMITTED_AT`, `DEADLINE`, `FIELDS_COMPLETE` (boolean, computed by a detector, not stored as raw input), `MATCH_STATUS` (matches the underlying `TRADE_ID`'s fields or not).
- **`OBLIGATION_MAP`** — the `LINE_ITEM_MAP` equivalent. `OBLIGATION_ID`, `MARKET_ID`, `OBLIGATION_DESCRIPTION`, `SOURCE_TABLE`, `SOURCE_COLUMNS`, `DETECTOR_NAME`, `RULE_CHUNK_ID` (FK to `RULE_CORPUS`), `STATUS` (`proposed`/`approved` — same governance gate as `Praman.LINE_ITEM_MAP`, same reason: a proposing/seeding script never self-approves).
- **`RULE_CORPUS`** — same shape as `Praman`'s: chunked regulatory/exchange-rule text with citable section references, plus `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` columns **from day one** (this is a `Praman` finding — Japan's provisional-translation problem — applied here as an initial design constraint, not a later patch).
- **`AUDIT_LOG`** — append-only by grant, same as `Praman`. Every surfaced finding writes a row; a sign-off is a new row referencing the original via `SIGNOFF_FOR_RUN_ID`, never an update.
- **`DETECTOR_CALIBRATION`** — append-only, effective-dated, with an `IS_PROVISIONAL` cold-start flag. Built this way **from the first migration**, not retrofitted — this is `Praman`'s plug-and-play doc's Fix #4/#5 applied at day one instead of as a future fix.

## Market-agnostic design rules (day-one constraints, not later fixes)

Each rule below exists because a specific `Praman` gap is documented as a fix-later item in `plug_and_play_architecture_v2.md` — applying it here up front instead of waiting to hit the same problem twice.

1. **No hardcoded currency, market code, or jurisdiction anywhere.** `CURRENCY` and `MARKET_ID` are non-nullable, non-defaulted columns on every table that needs them from the first DDL — `Praman`'s `DEFAULT 'INR'` was flagged as a "cheap fix" needed later; here there's no default to begin with.
2. **Every detector baseline partitions by `MARKET_ID` (and `CURRENCY` where relevant) in addition to instrument/participant.** A cross-market or cross-currency aggregate is never computed implicitly inside a detector view — `Praman`'s currency/FX gap (summing unlike currencies into one baseline) is avoided by construction, not patched after the views exist.
3. **No hardcoded z-score thresholds.** Every detector reads its threshold from `DETECTOR_CALIBRATION`, joined on the effective date, from the first version of each view. `Praman` hardcoded `|z| >= 3` and only planned to calibrate it afterward — here `DETECTOR_CALIBRATION` exists before the first detector view does, with a documented cold-start default (`IS_PROVISIONAL = TRUE`) for a market/participant with insufficient history, exactly the state a genuinely new market onboarding will always start in.
4. **The canonical schema is versioned and documented as a contract before a second market is onboarded**, not consolidated from scattered DDL comments after the fact. `docs/canonical_schema_contract.md` is written alongside the DDL, not after it.
5. **Jurisdiction/market-specific dimensions are added as nullable extension columns, never by forking the schema per market.** If a market's regulator requires a dimension no other market needs (e.g., a specific participant classification), it's a nullable column, following the same convention `Praman`'s plug-and-play doc settled on for banking (Fix #2) — applied here as the starting convention rather than a later resolution to a contradiction.
6. **`RULE_CORPUS` carries `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` from the first row loaded**, so a non-English-original market's content is never treated as equivalent to the authoritative text without an explicit flag saying so.
7. **Detector thresholds and obligation mappings are per-`MARKET_ID`, never global constants** — `DETECTOR_CALIBRATION` and `OBLIGATION_MAP` are both keyed by `MARKET_ID`, so onboarding market #2 is a new set of rows, not a schema or SQL change.

## Detectors — one framework, four obligation types

Reusing `Praman`'s "one detector formula, multiple consuming views" pattern (`ZSCORE` UDF), extended with new formulas the banking domain never needed:

- **Wash trading** (market conduct) — a `TRADES` row where the participant on both sides resolves to the same `BENEFICIAL_OWNER_ID`, or a matched buy/sell pair in the same instrument within a short time window at the same or near-identical price. Not a z-score detector — a pattern-match view.
- **Spoofing/layering** (market conduct) — per participant x instrument x day, ratio of cancelled-unfilled order volume to submitted order volume, z-scored against that participant's own trailing baseline (same `ZSCORE` UDF, reused formula) — a structurally identical computation to `Praman.TRANSACTION_SIGNALS`' structuring detector, applied to `ORDERS` instead of `TRANSACTIONS`.
- **Position/exposure limit breach** — `POSITIONS.NET_QUANTITY` (or market value) as a percentage of a regulatory threshold per instrument/participant class, structurally identical to `Praman`'s counterparty concentration check on `POSITIONS`.
- **Post-trade reporting timeliness/completeness** — `TRANSACTION_REPORTS.SUBMITTED_AT` vs. `DEADLINE` (a boolean/interval, not a z-score) and `FIELDS_COMPLETE` (a required-field-presence check) — a rules-based detector, not statistical, since lateness has a hard deadline rather than a distribution.
- **Best execution slippage** — `TRADES.PRICE` vs. a reference price at `ORDERS.SUBMITTED_TS` (the reference price source is itself market-dependent — some markets publish an NBBO-equivalent, others don't — flagged as an open per-market adaptor question, not assumed solved).

## RBAC — reused role shape, new object names

Same four functional roles as `Praman`, same boundary rationale, applied to the new schema:

- `ANALYST_READ` — `SELECT` on `RULE_CORPUS`/`OBLIGATION_MAP`/all core tables, `SELECT` on detector views. No write access anywhere.
- `GOVERNANCE_WRITE` — `INSERT`/`UPDATE` on `OBLIGATION_MAP` (the proposed→approved gate), `INSERT` on `RULE_CORPUS`.
- `AUDIT_INSERT` — `INSERT`-only on `AUDIT_LOG`, no `SELECT`.
- `OFFICER_SIGNOFF` — writes sign-off rows via a stored procedure (`SP_RECORD_SIGNOFF`, ported from `Praman`'s design), no direct table access.

`VIGIL.EVAL` (holding `INJECTED_CASES`/`EVAL_RESULTS`) is isolated the same way as `Praman.EVAL` — no functional role is ever granted anything on it. RBAC verification (the 22-check live-verification discipline `Praman` ran) is scheduled as a required step before this is considered done, not assumed correct because the grant scripts look right on paper.

## Governance gate

`OBLIGATION_MAP.STATUS` starts `proposed`; only a `GOVERNANCE_WRITE` session flips it to `approved`. Any Stage that computes a value against an obligation (the surveillance/limit-check/best-execution equivalents of `Praman`'s Stage 2 "Assure") must query `OBLIGATION_MAP` first and refuse to proceed against an unapproved mapping — same real bug `Praman` hit once (a hardcoded default standing in for a missing lookup tool) is avoided here by building the lookup tool as the first tool in the agent spec, not an afterthought, and by testing it against a case where the check would actually fail (an unapproved obligation), not just the common case where it happens to pass.

## Agent and Skills

Four skills, parallel to `Praman`'s four but renamed for this domain — exact tool/orchestration split (single agent vs. multiple) to be decided during build, informed by `Praman`'s own finding that shared-resource stages (same Semantic Views/role) merge into one agent while stages needing bespoke multi-step orchestration don't fit a chat-agent tool-call model and stay as CLI skills:

- `surveillance-query` — live queries over trades/orders/positions (wash trading, spoofing candidates, exposure breaches). Parallel to `Praman`'s `signal-query`.
- `rule-interpret` — new exchange rule/circular → `OBLIGATION_MAP` gap analysis. Parallel to `circular-interpret`.
- `assure-report` — validate a draft transaction report / limit filing against rule text and obligation mapping before submission. Parallel to `assure-return`.
- `narrative-draft` — trace a confirmed surveillance finding to root cause via lineage, draft remediation/regulator narrative. Parallel to `narrative-draft` (same name, same thin-orchestration-over-native-lineage design).

## Synthetic data — config-driven, not one hardcoded market

`Praman`'s generator reconciled bottom-up to one real disclosed PDF (HDFC's Pillar 3). No equivalent single document exists for trade surveillance, so this generator is parameterized by a `MARKET_CONFIG` (tick size, currency, trading calendar, instrument universe, participant count) instead — the same generator script produces a plausible order/trade/position book for any market config, and "market-agnostic" is verified by running the generator against at least two different configs and confirming the schema and detectors behave identically, not just designed to be agnostic on paper.

## Build order

1. This doc (done) + `docs/canonical_schema_contract.md`.
2. DDL: `sql/ddl/` — `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `ORDERS`, `TRADES`, `POSITIONS`, `TRANSACTION_REPORTS`, `OBLIGATION_MAP`, `RULE_CORPUS`, `AUDIT_LOG`, `DETECTOR_CALIBRATION` — all market-agnostic per the rules above from the first version.
3. RBAC: `sql/rbac/` — port the four-role pattern.
4. Detectors: `sql/detectors/` — `ZSCORE` UDF (ported), wash-trading view, spoofing/layering view, exposure-limit view, reporting-timeliness view, best-execution view — all joining `DETECTOR_CALIBRATION`, none with an inline constant.
5. Semantic Views over the core tables + `OBLIGATION_MAP`.
6. Synthetic data generator, config-driven, plus `tests/` reconciliation tests.
7. Skills (4) + Cortex Agent.
8. RBAC verification (live, 22-check-style) before calling any of the above done.

## What's explicitly deferred

Real regulator/exchange document sourcing (a `Praman`-style `data-sources.md` equivalent) and a specific first market to actually calibrate/test against are open choices, not solved by this doc — "market-agnostic" is a schema/detector property, not a claim that zero real market has been chosen for the first build-and-test pass. Pick one concrete market before writing the synthetic generator's first `MARKET_CONFIG`, the same way `Praman` needed one real disclosure before its generator could reconcile against anything.
