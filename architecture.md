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

**One regulator oversees many venues — verified live, not assumed.** Fetching JPX's own site, Japannext PTS's own site, and Osaka Digital Exchange's own site confirmed Japan alone has at least 5 real active trading venues (TSE, OSE, TOCOM as the JPX Group exchanges, plus Japannext PTS and ODX operating outside it — ODX's own site describes itself as "the third PTS in Japan"), all under one regulator (FSA/SESC). A sixth candidate venue, Cboe Japan, is confirmed **discontinued** (user-confirmed it stopped trading in Japan in 2025, independently corroborated by Cboe's own site listing no Japan/Asia region under "Global Markets") — excluded from the active venue list, not silently assumed active. The US shows the identical one-regulator/many-venues shape at larger scale: the SEC directly oversees 24+ separate national securities exchanges plus FINRA, and — re-confirmed live this session via the CAT NMS Plan's own site — SEC Rule 613 legally requires all of them to feed one Consolidated Audit Trail specifically so the regulator can surveil across venues. This is why the schema below has a `JURISDICTION_ID` (the regulator, owning obligations/rules/calibration) and a separate `VENUE_ID` (the specific exchange/PTS a trade executed on) rather than one collapsed `MARKET_ID` — full rationale, the verified Japan venue list, and a structural-review revision (v3) are in `docs/canonical_schema_contract.md`, the authoritative column-level reference; this section is a summary.

**A structural review of the first schema draft found nine real gaps** — a detector exemption that quietly reintroduced a hardcoded threshold, a wash-trading detector that could go silently blind, a `POSITIONS` diagram that contradicted its own derivation rule, a best-execution formula that was outright wrong (not just deferred), a governance gate enforced by policy instead of structure, a missing write path for the actual market data, and two undefined identifier spaces. All nine are fixed in `docs/canonical_schema_contract.md` v3, marked `[FIX #1]`–`[FIX #9]` there; this section reflects the fixed state, not the original draft.

```
JURISDICTIONS ──< VENUES

BENEFICIAL_OWNERS ──< MARKET_PARTICIPANTS ──< ORDERS
                                                  │
INSTRUMENTS ─────────────────────────────────────┤
                                                  ▼
                                               TRADES ──< TRANSACTION_REPORTS
                                                  │  ╲
                                                  │   ╲──< TRADE_REFERENCE_PRICES
                                                  ▼
                                             POSITIONS (accumulates from TRADES
                                             only, never ORDERS — JURISDICTION_ID
                                             scoped, no VENUE_ID, LOADED_AT for
                                             restatements)
```

- **`JURISDICTIONS`** — one row per regulator (`JURISDICTION_ID`, `REGULATOR_NAME`, `PRIMARY_LANGUAGE`).
- **`VENUES`** — one row per exchange/PTS/OTC facility (`VENUE_ID`, `JURISDICTION_ID`, `VENUE_TYPE`, `OPERATOR_NAME`, `STATUS` — `active`/`discontinued`, added because venues genuinely stop operating, per Cboe Japan above).
- **`BENEFICIAL_OWNERS`** — new reference table (Fix #8). A beneficial owner is not assumed to be a market participant itself; `MARKET_PARTICIPANTS.BENEFICIAL_OWNER_ID` FKs here, not self-referencing `PARTICIPANT_ID`.
- **`INSTRUMENTS`** — reference data, scoped by `JURISDICTION_ID` (an instrument's primary-listing jurisdiction), not by venue — the same TSE-listed stock also trades on Japannext PTS under one instrument identity.
- **`MARKET_PARTICIPANTS`** — brokers/members/counterparties, scoped by `JURISDICTION_ID`. `BENEFICIAL_OWNER_ID` nullable, FK → `BENEFICIAL_OWNERS` when populated — needed for wash-trading detection across nominee accounts.
- **`ORDERS`** — every order submitted, not just filled ones, carrying `VENUE_ID`/`JURISDICTION_ID`/`CURRENCY`. Cancelled-but-unfilled orders are the raw material for spoofing/layering detection. **Never a source for `POSITIONS`** (Fix #4) — an order is not itself an economic position.
- **`TRADES`** — executed trades, carrying `VENUE_ID`/`CURRENCY`. The sole source for `POSITIONS` accumulation. `ORDER_ID` and `COUNTERPARTY_PARTICIPANT_ID` are both independently nullable — when both are null on the same row, that trade is invisible to wash-trading detection, surfaced (not hidden) by `WASH_DETECTION_COVERAGE` below (Fix #3).
- **`TRADE_REFERENCE_PRICES`** — new (Fix #5). `REFERENCE_PRICE_AT_EXECUTION` and `REFERENCE_PRICE_AT_ARRIVAL`, externally sourced by its own adaptor, kept off `TRADES` since reference prices arrive on their own timeline.
- **`POSITIONS`** — per `PARTICIPANT_ID` x `INSTRUMENT_ID` x `JURISDICTION_ID` x `AS_OF_DATE` x `LOADED_AT`, `NET_QUANTITY` (cumulative signed sum of `TRADES.VOLUME`, never `ORDERS`), `MARKET_VALUE`, `CURRENCY`. **No `VENUE_ID`** — a concentration/exposure limit is a cross-venue total. `LOADED_AT` (Fix #4) means a restatement is a new row, never an `UPDATE` — same append-only discipline as `Praman.AUDIT_LOG`. Corporate-actions adjustment is explicitly deferred, not silently ignored.
- **`TRANSACTION_REPORTS`** — the actual submission record. `MATCH_STATUS` is now a defined enum (`full_match`/`partial_match`/`no_match`, Fix #9) against `TRADES`' instrument/price(exact)/volume(exact)/execution-timestamp(documented tolerance).
- **`OBLIGATION_MAP`** — the `LINE_ITEM_MAP` equivalent, scoped by `JURISDICTION_ID`. `RULE_CHUNK_ID` moved out to a new `OBLIGATION_RULE_CHUNKS` junction table (Fix #9 — an obligation can be backed by zero, one, or many rule chunks). `SOURCE_TABLE`/`SOURCE_COLUMNS` stay free text (SQL can't enforce an FK to a dynamic column name) but must pass a schema-existence check before `GOVERNANCE_WRITE` can approve the row.
- **`APPROVED_OBLIGATIONS`** — new view (Fix #6), `WHERE STATUS = 'approved'`. The only obligation-lookup target the agent/`ANALYST_READ` are granted — the governance gate is now structural, not a rule every future query author has to remember to apply.
- **`RULE_CORPUS`** — same shape as `Praman`'s, scoped by `JURISDICTION_ID`, `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` from day one — directly relevant here since Japan's FSA/SESC's authoritative text is Japanese.
- **`AUDIT_LOG`** — append-only by grant, same as `Praman`.
- **`DETECTOR_CALIBRATION`** — append-only, effective-dated, `JURISDICTION_ID` required, `VENUE_ID` nullable, `IS_PROVISIONAL` cold-start flag, plus a new `PARAMS VARIANT` column (Fix #2) so pattern-match detectors (wash trading's time window/price tolerance) also read their tunables from this table — no detector, statistical or not, embeds a literal.

## Market-agnostic design rules (day-one constraints, not later fixes)

Each rule below exists because a specific `Praman` gap is documented as a fix-later item in `plug_and_play_architecture_v2.md` — applying it here up front instead of waiting to hit the same problem twice.

1. **No hardcoded currency, venue, or jurisdiction anywhere.** `CURRENCY`, `JURISDICTION_ID`, and `VENUE_ID` are non-nullable (where applicable), non-defaulted columns from the first DDL — `Praman`'s `DEFAULT 'INR'` was flagged as a "cheap fix" needed later; here there's no default to begin with.
2. **Every detector baseline partitions by `JURISDICTION_ID` and/or `VENUE_ID` (whichever the obligation is actually scoped to) and `CURRENCY` where relevant, in addition to instrument/participant.** A cross-jurisdiction, cross-venue, or cross-currency aggregate is never computed implicitly inside a detector view — `Praman`'s currency/FX gap (summing unlike currencies into one baseline) is avoided by construction, not patched after the views exist. Which scope is correct differs by detector (see "Detectors" below): spoofing/layering is venue-scoped, concentration limits are jurisdiction-scoped only — getting this wrong in either direction is a real modeling error, not a style choice.
3. **No hardcoded detector parameters — statistical or pattern-match.** Every detector reads its tunables from `DETECTOR_CALIBRATION`: `Z_THRESHOLD`/`MIN_BASELINE_PERIODS` for statistical detectors, `PARAMS` (a `VARIANT` column) for pattern-match/rules-based ones. This closed a real gap in the first draft — wash trading's "pattern-match, not a z-score detector" framing had quietly left its time-window and price-tolerance values with no stated home, which was the same hardcoded-threshold problem rule #3 exists to prevent, just relabeled. `Praman` hardcoded `|z| >= 3` and only planned to calibrate it afterward; here `DETECTOR_CALIBRATION` exists before the first detector view does, with a documented cold-start default (`IS_PROVISIONAL = TRUE`) for a jurisdiction/venue/participant with insufficient history.
4. **The canonical schema is versioned and documented as a contract before a second jurisdiction is onboarded**, not consolidated from scattered DDL comments after the fact. `docs/canonical_schema_contract.md` is written alongside the DDL, not after it — and has already been revised twice (v1→v2 after live-verifying Japan's venue structure; v2→v3 after a structural review found nine gaps), both before any DDL existed to make those revisions expensive.
5. **Jurisdiction-specific dimensions are added as nullable extension columns, never by forking the schema per jurisdiction.** If a jurisdiction's regulator requires a dimension no other jurisdiction needs (e.g., a specific participant classification), it's a nullable column, following the same convention `Praman`'s plug-and-play doc settled on for banking (Fix #2) — applied here as the starting convention rather than a later resolution to a contradiction.
6. **`RULE_CORPUS` carries `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` from the first row loaded**, so a non-English-original jurisdiction's content is never treated as equivalent to the authoritative text without an explicit flag saying so — directly applicable to the first real jurisdiction below (Japan).
7. **Detector thresholds and obligation mappings are per-`JURISDICTION_ID` (and per-`VENUE_ID` where the detector is venue-scoped), never global constants** — `DETECTOR_CALIBRATION` and `OBLIGATION_MAP` are keyed this way, so onboarding jurisdiction #2 is a new set of rows, not a schema or SQL change.

## First jurisdiction: Japan (verified, not assumed)

Live-verified against each operator's own site (not general knowledge asserted as fact) before committing to this as the first build/test target:

- **Regulator:** FSA, with the SESC as the actual surveillance/enforcement body — referenced directly on JPX's own homepage as the destination for market-fairness complaints. `JURISDICTION_ID = 'JP'`.
- **JPX Group exchanges (confirmed via JPX's own site):** Tokyo Stock Exchange (`XTKS`, equities), Osaka Exchange (`XOSE`, derivatives), Tokyo Commodity Exchange (`TOCOM`, commodity futures).
- **PTS operators outside JPX Group:** Japannext PTS (`JPNX`, confirmed live — X-Market/U-Market segments, a Night Market session, published FIX/ITCH/OUCH market-data specs) and Osaka Digital Exchange (`ODX`, confirmed live — self-described as "the third PTS in Japan" for equities, plus a separate PTS "START" for security tokens). Cboe Japan (formerly Chi-X Japan) is **confirmed discontinued, not merely unverified** — the user directly confirmed it stopped trading in Japan in 2025, corroborating the independent negative signal already found (Cboe's own "Global Markets" navigation lists only US/Canada/Europe, no Japan/Asia region). Not seeded as an `active` venue; if seeded at all for historical-data completeness, it would carry `STATUS = 'discontinued'` in `VENUES`.
- **Citation-authority implication:** Japan's authoritative rule text is Japanese; any English version used for `RULE_CORPUS` content is a provisional translation. Design rule 6 above exists specifically for this case — every `RULE_CORPUS` row for `JURISDICTION_ID = 'JP'` must carry `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` honestly, and any agent-surfaced citation from a translated chunk must carry that caveat in its output, not just in internal documentation (same requirement `Praman`'s research findings already established for this exact case).

Full verified venue table with confidence notes: `docs/canonical_schema_contract.md`.

## Detectors — one framework, four obligation types

Reusing `Praman`'s "one detector formula, multiple consuming views" pattern (`ZSCORE` UDF), extended with new formulas the banking domain never needed:

- **Wash trading** (market conduct) — a `TRADES` row where the participant on both sides resolves to the same `BENEFICIAL_OWNER_ID`, or a matched buy/sell pair in the same instrument within a time window and price tolerance **read from `DETECTOR_CALIBRATION.PARAMS`** (Fix #2 — not hardcoded, despite being a pattern-match rather than statistical detector). Scoped per `VENUE_ID` but must also check *across* venues for the same instrument/beneficial owner — a pattern spread across TSE and Japannext to avoid one venue's detection is itself the case to catch. **Companion requirement, not optional:** `WASH_DETECTION_COVERAGE` (Fix #3) surfaces, per venue/day, the percentage of trades with neither a resolvable `ORDER_ID` nor a disclosed `COUNTERPARTY_PARTICIPANT_ID` — any wash-trading finding is presented alongside this coverage figure, so "no wash trades found" and "no wash trades could be checked for" are never conflated.
- **Spoofing/layering** (market conduct) — per participant x instrument x venue x day, ratio of cancelled-unfilled order volume to submitted order volume, z-scored against that participant's own trailing baseline **at that venue** (same `ZSCORE` UDF, reused formula) — a structurally identical computation to `Praman.TRANSACTION_SIGNALS`' structuring detector, applied to `ORDERS` instead of `TRANSACTIONS`. Venue-scoped in `DETECTOR_CALIBRATION` because order-book cancel-rate norms genuinely differ by venue (e.g. Japannext's separate Night Market session has its own liquidity profile).
- **Position/exposure limit breach** — `POSITIONS.NET_QUANTITY` (or market value) as a percentage of a regulatory threshold per instrument/participant class, scoped by `JURISDICTION_ID` **only** — structurally identical to `Praman`'s counterparty concentration check on `POSITIONS`, and consistent with `POSITIONS` itself having no `VENUE_ID` (the limit is on a cross-venue total accumulated from `TRADES` only — never `ORDERS`, Fix #4).
- **Post-trade reporting timeliness/completeness** — `TRANSACTION_REPORTS.SUBMITTED_AT` vs. `DEADLINE` (a boolean/interval, not a z-score) and `FIELDS_COMPLETE` (a required-field-presence check) — a rules-based detector, not statistical, since lateness has a hard deadline rather than a distribution. `MATCH_STATUS` is a defined enum (Fix #9), not an unspecified "matches or not." Scoped by `JURISDICTION_ID` + the report's `VENUE_ID` where the reporting facility itself is venue-specific.
- **Best execution — two distinct metrics, not one conflated formula (Fix #5).** `EXECUTION_SLIPPAGE`: `TRADES.PRICE` vs. `TRADE_REFERENCE_PRICES.REFERENCE_PRICE_AT_EXECUTION` (at `EXECUTION_TIMESTAMP`) — was the fill fair given the market at that instant. `ARRIVAL_SLIPPAGE`: `TRADES.PRICE` vs. `REFERENCE_PRICE_AT_ARRIVAL` (at `ORDERS.SUBMITTED_TS`) — did delay/market impact between order entry and execution cost the participant. The original draft used the arrival timestamp while claiming to measure execution quality — that was a wrong formula, not an open question; both metrics are now separately modeled and correctly labeled. Scoped per `VENUE_ID` (the reference price source is itself venue-dependent — some venues publish an NBBO-equivalent, others don't, and `TRADE_REFERENCE_PRICES`' columns are nullable for that reason, not an adaptor failure).

## RBAC — reused role shape, one new role, new object names

Same four functional roles as `Praman`, same boundary rationale, applied to the new schema, plus a fifth role the first draft omitted entirely:

- `ANALYST_READ` — `SELECT` on `RULE_CORPUS`/`APPROVED_OBLIGATIONS` (the view, not the base `OBLIGATION_MAP` table — Fix #6)/all core tables, `SELECT` on detector views including `WASH_DETECTION_COVERAGE`. No write access anywhere.
- `GOVERNANCE_WRITE` — `INSERT`/`UPDATE` on `OBLIGATION_MAP` (the proposed→approved gate) and `OBLIGATION_RULE_CHUNKS`, `INSERT` on `RULE_CORPUS`, `SELECT` on the base `OBLIGATION_MAP` table (to see `proposed` rows for review, which `ANALYST_READ` cannot).
- `AUDIT_INSERT` — `INSERT`-only on `AUDIT_LOG`, no `SELECT`.
- `OFFICER_SIGNOFF` — writes sign-off rows via a stored procedure (`SP_RECORD_SIGNOFF`, ported from `Praman`'s design), no direct table access.
- **`MARKET_DATA_INGEST`** (new, Fix #7 — the first draft had no write path for market data at all) — `INSERT`-only on `JURISDICTIONS`, `VENUES`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `BENEFICIAL_OWNERS`, `ORDERS`, `TRADES`, `TRANSACTION_REPORTS`, `POSITIONS`, `TRADE_REFERENCE_PRICES`. Never `UPDATE`/`DELETE` on any of them — a `POSITIONS` correction is a new row with a later `LOADED_AT` (Fix #4), so this role never needs update/delete and is never granted it.

`VIGIL.EVAL` (holding `INJECTED_CASES`/`EVAL_RESULTS`) is isolated the same way as `Praman.EVAL` — no functional role is ever granted anything on it. RBAC verification (the 22-check live-verification discipline `Praman` ran) is scheduled as a required step before this is considered done, not assumed correct because the grant scripts look right on paper.

## Governance gate

`OBLIGATION_MAP.STATUS` starts `proposed`; only a `GOVERNANCE_WRITE` session flips it to `approved` — and only after a schema-existence check on `SOURCE_TABLE`/`SOURCE_COLUMNS` passes (Fix #9; these are free text because SQL can't enforce an FK to a dynamic column name, but the approval workflow validates them against `INFORMATION_SCHEMA` rather than leaving that a silent drift risk). **The gate is now structural, not just a rule every future query author has to remember (Fix #6):** `APPROVED_OBLIGATIONS` is a view (`WHERE STATUS = 'approved'`) and it's the only obligation-lookup target `ANALYST_READ`/the agent's obligation-lookup tool is granted — an unapproved obligation is invisible to the normal query path structurally, not merely supposed to be checked and skipped. This is the fix for the same real bug `Praman` hit once (a hardcoded default standing in for a missing lookup tool): building the structural constraint instead of trusting every future consumer to apply the discipline correctly, and testing it against a case where the check would actually fail (an unapproved obligation), not just the common case where it happens to pass.

## Agent and Skills

Four skills, parallel to `Praman`'s four but renamed for this domain — exact tool/orchestration split (single agent vs. multiple) to be decided during build, informed by `Praman`'s own finding that shared-resource stages (same Semantic Views/role) merge into one agent while stages needing bespoke multi-step orchestration don't fit a chat-agent tool-call model and stay as CLI skills:

- `surveillance-query` — live queries over trades/orders/positions (wash trading, spoofing candidates, exposure breaches). Parallel to `Praman`'s `signal-query`.
- `rule-interpret` — new exchange rule/circular → `OBLIGATION_MAP` gap analysis. Parallel to `circular-interpret`.
- `assure-report` — validate a draft transaction report / limit filing against rule text and obligation mapping before submission. Parallel to `assure-return`.
- `narrative-draft` — trace a confirmed surveillance finding to root cause via lineage, draft remediation/regulator narrative. Parallel to `narrative-draft` (same name, same thin-orchestration-over-native-lineage design).

## Synthetic data — config-driven, with a measurable agnosticism criterion (Fix #9)

`Praman`'s generator reconciled bottom-up to one real disclosed PDF (HDFC's Pillar 3). No equivalent single document exists for trade surveillance, so this generator is parameterized by a `JURISDICTION_CONFIG` (jurisdiction, its full verified venue list, currency, trading calendar, instrument universe, participant count per venue) instead. Japan's config is the first, seeded from the 6 confirmed active venues (`XTKS`/`XOSE`/`TOCOM`/`JPNX`/`ODX`/`ODXST` — `CBOJ` excluded, confirmed discontinued) — not a single venue standing in for the whole jurisdiction, since the whole point of the `VENUE_ID` split is that a realistic Japan dataset has orders/trades spread across all confirmed venues, with wash-trading/best-execution cases that specifically span venues. `US` is the second config for the agnosticism proof, cross-verified live this session against the SEC's own SRO list and the CAT NMS Plan's own site — its specific `VENUES` seed list (which of the 24+ SEC-registered exchanges to include) still needs the same per-venue verification discipline Japan got, not a bulk copy of the SEC's list.

**"Market-agnostic" is now a measurable claim, not "behave identically" left unspecified:** running the generator against both configs must produce (a) 100% referential integrity across every FK, (b) every seeded `VENUE_ID` represented in at least one `ORDERS`/`TRADES` row, and (c) each detector's trigger rate falling within a documented expected band for that config's synthetic distribution — not literally equal absolute counts across two differently-sized configs, since "agnostic" means the mechanism behaves the same way, not that two different-sized datasets produce equal numbers.

## Build order

1. This doc (done) + `docs/canonical_schema_contract.md` (done, v3 after the `JURISDICTION_ID`/`VENUE_ID` split and a nine-point structural-review fix).
2. DDL: `sql/ddl/` — `JURISDICTIONS`, `VENUES`, `BENEFICIAL_OWNERS`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `ORDERS`, `TRADES`, `TRADE_REFERENCE_PRICES`, `POSITIONS`, `TRANSACTION_REPORTS`, `OBLIGATION_MAP`, `OBLIGATION_RULE_CHUNKS`, `APPROVED_OBLIGATIONS` (view), `RULE_CORPUS`, `AUDIT_LOG`, `DETECTOR_CALIBRATION` — all market-agnostic per the rules above from the first version.
3. RBAC: `sql/rbac/` — port the four-role pattern plus the new `MARKET_DATA_INGEST` role (Fix #7).
4. Detectors: `sql/detectors/` — `ZSCORE` UDF (ported), wash-trading view + `WASH_DETECTION_COVERAGE` (Fix #3), spoofing/layering view, exposure-limit view, reporting-timeliness view, two best-execution views (`EXECUTION_SLIPPAGE`/`ARRIVAL_SLIPPAGE`, Fix #5) — all joining `DETECTOR_CALIBRATION` at the correct scope (venue vs. jurisdiction, per detector above), none with an inline constant, including the pattern-match one (Fix #2).
5. Semantic Views over the core tables + `APPROVED_OBLIGATIONS`.
6. Synthetic data generator, `JURISDICTION_CONFIG`-driven starting with Japan's verified venue list, plus `tests/` reconciliation tests against the measurable acceptance criteria above.
7. Skills (4) + Cortex Agent.
8. RBAC verification (live, 22-check-style) before calling any of the above done.

## What's explicitly deferred

Real regulator/exchange document sourcing (a `Praman`-style `data-sources.md` equivalent) for Japan's actual FSA/SESC/JPX rule text, corporate-actions handling for `POSITIONS` (Fix #4), and finalizing the `US` config's specific venue list against the same per-venue verification discipline applied to Japan, are open items before the generator/`RULE_CORPUS` seed can be written — "market-agnostic" is a schema/detector property, verified for Japan's real venue structure and fixed structurally per the nine points above, not a claim that every piece of jurisdiction-specific content already exists.
