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

**One regulator oversees many venues — verified live, not assumed.** Fetching JPX's own site, Japannext PTS's own site, and Osaka Digital Exchange's own site confirmed Japan alone has at least 5 real trading venues (TSE, OSE, TOCOM as the JPX Group exchanges, plus Japannext PTS and ODX operating outside it — ODX's own site describes itself as "the third PTS in Japan"), all under one regulator (FSA/SESC). The US shows the identical shape at larger scale: the SEC directly oversees 24+ separate national securities exchanges plus FINRA, and — confirmed via the CAT NMS Plan's own site — SEC Rule 613 legally requires all of them to feed one Consolidated Audit Trail specifically so the regulator can surveil across venues. This is why the schema below has a `JURISDICTION_ID` (the regulator, owning obligations/rules/calibration) and a separate `VENUE_ID` (the specific exchange/PTS a trade executed on) rather than one collapsed `MARKET_ID` — full rationale and the verified Japan venue list are in `docs/canonical_schema_contract.md`, which is the authoritative column-level reference; this section is a summary.

```
JURISDICTIONS ──< VENUES

INSTRUMENTS ──┐
              │
MARKET_       ├──< ORDERS >──< TRADES >──< TRANSACTION_REPORTS
PARTICIPANTS ─┘         │           │            (VENUE_ID on all three)
                         │           │
                         └──< POSITIONS (JURISDICTION_ID only — no VENUE_ID,
                                          a cross-venue total by design)
```

- **`JURISDICTIONS`** — one row per regulator (`JURISDICTION_ID`, `REGULATOR_NAME`, `PRIMARY_LANGUAGE`).
- **`VENUES`** — one row per exchange/PTS/OTC facility (`VENUE_ID`, `JURISDICTION_ID`, `VENUE_TYPE`, `OPERATOR_NAME`). New relative to the original single-`MARKET_ID` draft — exists because a jurisdiction has many venues, confirmed above.
- **`INSTRUMENTS`** — reference data, scoped by `JURISDICTION_ID` (an instrument's primary-listing jurisdiction), not by venue — the same TSE-listed stock also trades on Japannext PTS under one instrument identity.
- **`MARKET_PARTICIPANTS`** — brokers/members/counterparties, scoped by `JURISDICTION_ID` (registration is jurisdiction-level; venue membership is implied by which `VENUE_ID`s appear in their orders/trades). `BENEFICIAL_OWNER_ID` nullable — needed for wash-trading detection across nominee accounts.
- **`ORDERS`** — every order submitted, not just filled ones, carrying `VENUE_ID` (where submitted) and `JURISDICTION_ID`. Cancelled-but-unfilled orders are the raw material for spoofing/layering detection — this table exists specifically because `TRADES` alone (executed only) can't see a cancel pattern.
- **`TRADES`** — executed trades, carrying `VENUE_ID` (where it printed). Needed explicitly per venue because the same instrument's reference price can genuinely differ by venue at the same instant (Japannext's own Night Market session is a concrete case with no continuous cross-venue reference price at all hours).
- **`POSITIONS`** — per `PARTICIPANT_ID` x `INSTRUMENT_ID` x `JURISDICTION_ID` x `AS_OF_DATE`, `NET_QUANTITY`, `MARKET_VALUE`. **Deliberately no `VENUE_ID`** — a concentration/exposure limit applies to a participant's total holding across every venue they traded it on, not a per-venue figure; adding venue here would be a modeling error, not extra detail. Same semi-additive shape as `Praman.POSITIONS` otherwise (never summed across `AS_OF_DATE`).
- **`TRANSACTION_REPORTS`** — the actual submission record. `REPORT_ID`, `JURISDICTION_ID`, `VENUE_ID` (nullable — the reporting facility, when distinct from the trade's execution venue), `TRADE_ID` (FK), `SUBMITTED_AT`, `DEADLINE`, `FIELDS_COMPLETE` (computed), `MATCH_STATUS` (computed).
- **`OBLIGATION_MAP`** — the `LINE_ITEM_MAP` equivalent, scoped by `JURISDICTION_ID` (not venue — obligations are set by the regulator, apply across every venue it oversees). `OBLIGATION_ID`, `OBLIGATION_DESCRIPTION`, `SOURCE_TABLE`, `SOURCE_COLUMNS`, `DETECTOR_NAME`, `RULE_CHUNK_ID` (FK to `RULE_CORPUS`), `STATUS` (`proposed`/`approved` — same governance gate as `Praman.LINE_ITEM_MAP`, same reason: a proposing/seeding script never self-approves).
- **`RULE_CORPUS`** — same shape as `Praman`'s, scoped by `JURISDICTION_ID`: chunked regulatory/exchange-rule text with citable section references, plus `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` columns **from day one** (this is a `Praman` finding — Japan's provisional-translation problem — directly relevant here since Japan's FSA/SESC's authoritative text is Japanese).
- **`AUDIT_LOG`** — append-only by grant, same as `Praman`. Every surfaced finding writes a row; a sign-off is a new row referencing the original via `SIGNOFF_FOR_RUN_ID`, never an update.
- **`DETECTOR_CALIBRATION`** — append-only, effective-dated, `JURISDICTION_ID` required, `VENUE_ID` nullable (NULL = applies across all venues in the jurisdiction, e.g. a concentration-limit calibration; non-NULL = venue-specific, e.g. a spoofing cancel-rate baseline), with an `IS_PROVISIONAL` cold-start flag. Built this way **from the first migration**, not retrofitted — this is `Praman`'s plug-and-play doc's Fix #4/#5 applied at day one instead of as a future fix.

## Market-agnostic design rules (day-one constraints, not later fixes)

Each rule below exists because a specific `Praman` gap is documented as a fix-later item in `plug_and_play_architecture_v2.md` — applying it here up front instead of waiting to hit the same problem twice.

1. **No hardcoded currency, venue, or jurisdiction anywhere.** `CURRENCY`, `JURISDICTION_ID`, and `VENUE_ID` are non-nullable (where applicable), non-defaulted columns from the first DDL — `Praman`'s `DEFAULT 'INR'` was flagged as a "cheap fix" needed later; here there's no default to begin with.
2. **Every detector baseline partitions by `JURISDICTION_ID` and/or `VENUE_ID` (whichever the obligation is actually scoped to) and `CURRENCY` where relevant, in addition to instrument/participant.** A cross-jurisdiction, cross-venue, or cross-currency aggregate is never computed implicitly inside a detector view — `Praman`'s currency/FX gap (summing unlike currencies into one baseline) is avoided by construction, not patched after the views exist. Which scope is correct differs by detector (see "Detectors" below): spoofing/layering is venue-scoped, concentration limits are jurisdiction-scoped only — getting this wrong in either direction is a real modeling error, not a style choice.
3. **No hardcoded z-score thresholds.** Every detector reads its threshold from `DETECTOR_CALIBRATION`, joined on the effective date, from the first version of each view. `Praman` hardcoded `|z| >= 3` and only planned to calibrate it afterward — here `DETECTOR_CALIBRATION` exists before the first detector view does, with a documented cold-start default (`IS_PROVISIONAL = TRUE`) for a jurisdiction/venue/participant with insufficient history, exactly the state a genuinely new onboarding will always start in.
4. **The canonical schema is versioned and documented as a contract before a second jurisdiction is onboarded**, not consolidated from scattered DDL comments after the fact. `docs/canonical_schema_contract.md` is written alongside the DDL, not after it — and was itself already revised once (v1→v2) after live-verifying Japan's real venue structure, before any DDL existed to make that revision expensive.
5. **Jurisdiction-specific dimensions are added as nullable extension columns, never by forking the schema per jurisdiction.** If a jurisdiction's regulator requires a dimension no other jurisdiction needs (e.g., a specific participant classification), it's a nullable column, following the same convention `Praman`'s plug-and-play doc settled on for banking (Fix #2) — applied here as the starting convention rather than a later resolution to a contradiction.
6. **`RULE_CORPUS` carries `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` from the first row loaded**, so a non-English-original jurisdiction's content is never treated as equivalent to the authoritative text without an explicit flag saying so — directly applicable to the first real jurisdiction below (Japan).
7. **Detector thresholds and obligation mappings are per-`JURISDICTION_ID` (and per-`VENUE_ID` where the detector is venue-scoped), never global constants** — `DETECTOR_CALIBRATION` and `OBLIGATION_MAP` are keyed this way, so onboarding jurisdiction #2 is a new set of rows, not a schema or SQL change.

## First jurisdiction: Japan (verified, not assumed)

Live-verified against each operator's own site (not general knowledge asserted as fact) before committing to this as the first build/test target:

- **Regulator:** FSA, with the SESC as the actual surveillance/enforcement body — referenced directly on JPX's own homepage as the destination for market-fairness complaints. `JURISDICTION_ID = 'JP'`.
- **JPX Group exchanges (confirmed via JPX's own site):** Tokyo Stock Exchange (`XTKS`, equities), Osaka Exchange (`XOSE`, derivatives), Tokyo Commodity Exchange (`TOCOM`, commodity futures).
- **PTS operators outside JPX Group:** Japannext PTS (`JPNX`, confirmed live — X-Market/U-Market segments, a Night Market session, published FIX/ITCH/OUCH market-data specs) and Osaka Digital Exchange (`ODX`, confirmed live — self-described as "the third PTS in Japan" for equities, plus a separate PTS "START" for security tokens). Cboe Japan (formerly Chi-X Japan, likely `CBOJ`) is corroborated indirectly by ODX's own "third PTS" framing but **not independently verified live this session** — confirm directly before seeding it as a real row.
- **Citation-authority implication:** Japan's authoritative rule text is Japanese; any English version used for `RULE_CORPUS` content is a provisional translation. Design rule 6 above exists specifically for this case — every `RULE_CORPUS` row for `JURISDICTION_ID = 'JP'` must carry `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` honestly, and any agent-surfaced citation from a translated chunk must carry that caveat in its output, not just in internal documentation (same requirement `Praman`'s research findings already established for this exact case).

Full verified venue table with confidence notes: `docs/canonical_schema_contract.md`.

## Detectors — one framework, four obligation types

Reusing `Praman`'s "one detector formula, multiple consuming views" pattern (`ZSCORE` UDF), extended with new formulas the banking domain never needed:

- **Wash trading** (market conduct) — a `TRADES` row where the participant on both sides resolves to the same `BENEFICIAL_OWNER_ID`, or a matched buy/sell pair in the same instrument within a short time window at the same or near-identical price. Scoped per `VENUE_ID` (a wash trade happens on a specific venue) but must also check *across* venues for the same instrument/beneficial owner — a pattern spread across TSE and Japannext to avoid one venue's detection is itself the case to catch, not something a single-venue view can see alone. Not a z-score detector — a pattern-match view.
- **Spoofing/layering** (market conduct) — per participant x instrument x venue x day, ratio of cancelled-unfilled order volume to submitted order volume, z-scored against that participant's own trailing baseline **at that venue** (same `ZSCORE` UDF, reused formula) — a structurally identical computation to `Praman.TRANSACTION_SIGNALS`' structuring detector, applied to `ORDERS` instead of `TRANSACTIONS`. Venue-scoped in `DETECTOR_CALIBRATION` because order-book cancel-rate norms genuinely differ by venue (e.g. Japannext's separate Night Market session has its own liquidity profile).
- **Position/exposure limit breach** — `POSITIONS.NET_QUANTITY` (or market value) as a percentage of a regulatory threshold per instrument/participant class, scoped by `JURISDICTION_ID` **only** — structurally identical to `Praman`'s counterparty concentration check on `POSITIONS`, and consistent with `POSITIONS` itself having no `VENUE_ID` (the limit is on a cross-venue total).
- **Post-trade reporting timeliness/completeness** — `TRANSACTION_REPORTS.SUBMITTED_AT` vs. `DEADLINE` (a boolean/interval, not a z-score) and `FIELDS_COMPLETE` (a required-field-presence check) — a rules-based detector, not statistical, since lateness has a hard deadline rather than a distribution. Scoped by `JURISDICTION_ID` + the report's `VENUE_ID` where the reporting facility itself is venue-specific.
- **Best execution slippage** — `TRADES.PRICE` vs. a reference price at `ORDERS.SUBMITTED_TS`, scoped per `VENUE_ID` (the reference price source is itself venue-dependent — some venues publish an NBBO-equivalent, others don't — flagged as an open per-venue adaptor question, not assumed solved).

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

`Praman`'s generator reconciled bottom-up to one real disclosed PDF (HDFC's Pillar 3). No equivalent single document exists for trade surveillance, so this generator is parameterized by a `JURISDICTION_CONFIG` (jurisdiction, its full verified venue list, currency, trading calendar, instrument universe, participant count per venue) instead — the same generator script produces a plausible order/trade/position book for any jurisdiction config, and "market-agnostic" is verified by running the generator against at least two different configs and confirming the schema and detectors behave identically, not just designed to be agnostic on paper. Japan's config is the first, seeded from the verified venue list above (5 confirmed venues, `CBOJ` pending direct verification) — not a single venue standing in for the whole jurisdiction, since the whole point of the `VENUE_ID` split is that a realistic Japan dataset has orders/trades spread across all of TSE, OSE, TOCOM, Japannext, and ODX, with wash-trading/best-execution cases that specifically span venues.

## Build order

1. This doc (done) + `docs/canonical_schema_contract.md` (done, v2 after the `JURISDICTION_ID`/`VENUE_ID` split).
2. DDL: `sql/ddl/` — `JURISDICTIONS`, `VENUES`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `ORDERS`, `TRADES`, `POSITIONS`, `TRANSACTION_REPORTS`, `OBLIGATION_MAP`, `RULE_CORPUS`, `AUDIT_LOG`, `DETECTOR_CALIBRATION` — all market-agnostic per the rules above from the first version.
3. RBAC: `sql/rbac/` — port the four-role pattern.
4. Detectors: `sql/detectors/` — `ZSCORE` UDF (ported), wash-trading view, spoofing/layering view, exposure-limit view, reporting-timeliness view, best-execution view — all joining `DETECTOR_CALIBRATION` at the correct scope (venue vs. jurisdiction, per detector above), none with an inline constant.
5. Semantic Views over the core tables + `OBLIGATION_MAP`.
6. Synthetic data generator, `JURISDICTION_CONFIG`-driven starting with Japan's verified venue list, plus `tests/` reconciliation tests.
7. Skills (4) + Cortex Agent.
8. RBAC verification (live, 22-check-style) before calling any of the above done.

## What's explicitly deferred

Real regulator/exchange document sourcing (a `Praman`-style `data-sources.md` equivalent) for Japan's actual FSA/SESC/JPX rule text, and independent verification of `CBOJ` (Cboe Japan) as a real venue row, are open items before the generator/`RULE_CORPUS` seed can be written — "market-agnostic" is a schema/detector property, verified for Japan's real venue structure above, not a claim that every piece of Japan-specific content already exists.
