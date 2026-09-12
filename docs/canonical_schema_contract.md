# Canonical schema contract — v6

Versioned reference for `VIGIL.CORE`'s tables, written **before** the DDL exists (per `architecture.md`'s market-agnostic design rule #4), not consolidated from scattered comments afterward. Any DDL change must be reflected here in the same change, not after the fact.

**v3 fixes a batch of structural gaps a review pass found in v2** — every fix below is numbered `[FIX #n]` and traced to a specific finding, same discipline as `Praman`'s `plug_and_play_architecture_v2.md`. v2's `JURISDICTION_ID`/`VENUE_ID` split itself was correct and is unchanged; the gaps were one level down — in what got calibrated, how positions derive, what best execution compares, who can write, and two undefined identifier spaces.

**v4 fixes one more gap v3 introduced but didn't fully solve:** `VENUES.STATUS` (`active`/`discontinued`) has no date, and a discontinued venue genuinely has real historical trades that must stay representable — `STATUS` alone can't distinguish "this venue has no future trades past its closure" from "this venue never happened." Fixed with `ACTIVE_FROM`/`DISCONTINUED_AT` date columns. Also upgrades `CBOJ` from corroborated-but-unverified to primary-source confirmed (Cboe's own July 2025 press release, found via Wayback Machine after the live IR page blocked a direct fetch) and adds a second venue, `CBOJBIDS`, the same source surfaced. See the "First jurisdiction: Japan" table and change log below for specifics.

**v5 makes milestoning a universal, plug-and-play property of every `VIGIL.CORE` table, not a per-table judgment call.** A milestoning audit (prompted by a hard requirement: nothing in `VIGIL.CORE` is ever deleted or mutated in place — every state change is a new, dated row) found that only `POSITIONS` (`LOADED_AT`) and `DETECTOR_CALIBRATION` (`EFFECTIVE_FROM`) actually satisfied that today. Every other table either had no versioning at all, or — worse — the doc itself required an in-place `UPDATE` with no append-only path defined (`OBLIGATION_MAP.STATUS`'s proposed→approved flip, `ORDERS`' `MODIFIED_TS`/`CANCELLED_TS`/`FILLED_QUANTITY` lifecycle fields, `TRANSACTION_REPORTS`' submission/match fields) — a direct contradiction of the append-only discipline the Conventions section already claimed applied schema-wide. See "Milestoning discipline" below for the one generic rule every table now follows, and `[FIX #10]`–`[FIX #19]` for the specific gaps it closes.

**v6 closes two gaps a review of two market-structure cases (internal cross trades, and how a report actually gets generated) found in v5.** First: nothing in `TRADES` distinguished a legitimate, disclosed internal/agency cross from a wash trade — the wash-trading detector's own definition (a matched buy/sell pair, same beneficial owner, within a time window and price tolerance) is structurally identical to what an internal cross looks like, so every legitimate cross a broker runs would have false-positived. Second, and larger: the schema tracked whether a report was submitted **on time** and **matched** its trade, but never modeled what a regulator's own circular actually requires — a fixed field list, in a fixed format, that changes when the regulator amends it. `FIELDS_COMPLETE` had no home for what "complete" means, the same class of bug `PARAMS` (Fix #2) closed for wash trading's time window; `TRANSACTION_REPORTS.TRADE_ID` being `NOT NULL` assumed every report is trade-linked, which is false for periodic/nil filings; nothing distinguished "we corrected our own record" from "we sent the regulator an amendment"; and nothing stored what was actually submitted. Fixed in `[FIX #20]`–`[FIX #26]` below — a new `REPORT_TEMPLATES` table (milestoned, citation-backed to `RULE_CORPUS` the same way `OBLIGATION_MAP` already is) plus targeted `TRADES`/`ORDERS`/`TRANSACTION_REPORTS` additions.

## [FIX #1] `CURRENCY` was already in this file but missing from `architecture.md`'s prose

Not a schema gap — `CURRENCY` was correctly on `ORDERS`/`TRADES`/`POSITIONS` in v2 of this file. `architecture.md`'s summary bullets just didn't mention it, which made the two docs look inconsistent (and made the "no hardcoded currency" rule look unenforced when it wasn't). Fixed in `architecture.md`, not here — flagged so the inconsistency doesn't get reintroduced.

## [FIX #2] `DETECTOR_CALIBRATION` didn't have a home for pattern-match detector parameters

`Z_THRESHOLD`/`MIN_BASELINE_PERIODS` only serve statistical detectors (spoofing/layering, best-execution slippage). Wash trading is a pattern-match detector — "matched buy/sell pair... within a short time window at the same or near-identical price" — and v2 never said where that time window or price tolerance came from, which meant the rule "every detector reads its threshold from `DETECTOR_CALIBRATION`" was quietly not true for one of the four flagship detectors. Fixed by adding a `PARAMS` `VARIANT` column holding detector-specific key/value parameters (e.g. `{"time_window_seconds": 30, "price_tolerance_pct": 0.001}` for wash trading) — every detector, statistical or pattern-match, reads its parameters from this table now, no exceptions. See the updated `DETECTOR_CALIBRATION` table below.

## [FIX #3] Wash trading can go silently blind — now surfaced, not hidden

`TRADES.ORDER_ID` and `TRADES.COUNTERPARTY_PARTICIPANT_ID` are both independently nullable, each individually justified as real per-venue variance. Compounded, a venue feed missing both leaves no data path to detect wash trading at all for that venue — and nothing said so. Fixed by adding a required companion view (not a table — computed): `WASH_DETECTION_COVERAGE`, one row per `VENUE_ID` per day, `PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY` (a trade counts as resolvable if either `ORDER_ID` resolves to a participant or `COUNTERPARTY_PARTICIPANT_ID` is populated). Any obligation mapped to the wash-trading detector must be considered **degraded, not silently absent**, for a venue/day where this coverage figure is low — the agent-facing tool surfaces this figure alongside any wash-trading finding, so "no wash trades found" and "no wash trades could be checked for" are never presented as the same thing.

## [FIX #4] `POSITIONS` derivation — fixed the diagram contradiction, not just documented it

v2's diagram showed `POSITIONS` deriving from both `ORDERS` and `TRADES`. That's wrong: a position is built from **executed fills only** (`TRADES`), never from live or cancelled orders — an unfilled order has no economic position attached to it. Fixed:

- `POSITIONS.NET_QUANTITY` on a given `AS_OF_DATE` = the cumulative signed sum of `TRADES.VOLUME` for that participant/instrument up to and including that date, roll-forward from the prior `AS_OF_DATE` snapshot — not recomputed from full history every time (a real accumulation rule, not "derived" left unspecified).
- **Restatement handling, applying the lesson from `Praman`'s plug-and-play doc up front instead of retrofitting it later:** `POSITIONS` gains a `LOADED_AT TIMESTAMP_NTZ NOT NULL` column, distinct from `AS_OF_DATE`. A corrected snapshot for a given `AS_OF_DATE` is a **new row with a later `LOADED_AT`**, never an `UPDATE` of the original — the same append-only discipline the rest of this schema already uses elsewhere. Consumers read the latest `LOADED_AT` per `(PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE)`.
- **Corporate actions (splits, mergers, delistings) are explicitly deferred, not silently ignored** — `NET_QUANTITY` accumulation as specified above does not adjust for a corporate action, and a jurisdiction/instrument with corporate-action activity will show a discontinuity the accumulation rule alone can't explain. Flagged as a real gap for the build order, not assumed away.

## [FIX #5] Best execution — the comparison point was wrong, and the schema had nowhere to put a reference price at all

Two separate problems, both fixed:

- **No `REFERENCE_PRICE` column existed anywhere**, despite best execution being one of the four headline obligation types the doc's intro claims one schema covers. Fixed by adding a new table, `TRADE_REFERENCE_PRICES` (below) rather than bolting columns onto `TRADES` — a reference price comes from an external per-venue source (an NBBO-equivalent feed, where one exists), populated by a separate adaptor job, not part of the trade record itself.
- **The comparison timestamp was wrong, not just deferred.** v2 compared `TRADES.PRICE` to a reference price "at `ORDERS.SUBMITTED_TS`" — that measures market impact/delay (implementation shortfall), not execution quality. Fixed by modeling **two distinct, correctly labeled metrics** instead of conflating them into one wrong formula: `EXECUTION_SLIPPAGE` (`TRADES.PRICE` vs. the reference price **at `EXECUTION_TIMESTAMP`** — was this fill fair given the market at that instant) and `ARRIVAL_SLIPPAGE` (`TRADES.PRICE` vs. the reference price **at `ORDERS.SUBMITTED_TS`** — did market impact/delay between order entry and execution cost the participant). Both are legitimate, real best-execution metrics; the mistake was using the second one's timestamp while claiming to measure the first one's concept.

## [FIX #6] Governance gate — now structural, not just a rule every future query has to remember

v2 required every consuming stage to "query `OBLIGATION_MAP` first and refuse to proceed against an unapproved mapping" — a discipline, not a guarantee. Fixed by adding `APPROVED_OBLIGATIONS`, a view (`SELECT * FROM OBLIGATION_MAP WHERE STATUS = 'approved'`) — the agent/skill tool for obligation lookup targets this view, not the base table, so an unapproved obligation is structurally invisible to the normal query path rather than merely supposed to be checked and skipped. `ANALYST_READ` is granted `SELECT` on the view; direct `SELECT` on the base `OBLIGATION_MAP` table (to see proposed-but-not-yet-approved rows, e.g. for a governance dashboard) stays restricted to `GOVERNANCE_WRITE`.

## [FIX #7] No write path existed for market data at all — new `MARKET_DATA_INGEST` role

RBAC covered read/governance/audit/sign-off but nothing owned `INSERT` on the actual trade/order/position data — ingestion was implicitly assumed away. Fixed with a new role, `MARKET_DATA_INGEST`: `INSERT`-only (never `UPDATE`/`DELETE`, consistent with the append-only discipline used elsewhere) on `JURISDICTIONS`, `VENUES`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `BENEFICIAL_OWNERS`, `ORDERS`, `TRADES`, `TRANSACTION_REPORTS`, `POSITIONS`, `TRADE_REFERENCE_PRICES`. `POSITIONS` corrections use the `LOADED_AT` append pattern (Fix #4) rather than needing `UPDATE` at all — this role never needs update/delete on anything, so it's never granted either.

## [FIX #8] `BENEFICIAL_OWNER_ID`'s identifier space — was undefined, now a real reference table

v2 left `BENEFICIAL_OWNER_ID` as a bare nullable `VARCHAR` with no stated identifier space — self-referencing `MARKET_PARTICIPANTS.PARTICIPANT_ID`, or an independent entity space? The wash-trading detector's core join depends on this being resolved, not left ambiguous. Fixed: a beneficial owner is **not** assumed to be a market participant itself (an individual behind a nominee broker account typically never submits an order directly) — new `BENEFICIAL_OWNERS` reference table, `MARKET_PARTICIPANTS.BENEFICIAL_OWNER_ID` is now a real `NOT NULL`-FK-able column pointing at it (nullable at the row level when genuinely unknown, but no longer an undefined space when populated).

## [FIX #9] Minor gaps, fixed together

- **`OBLIGATION_MAP.RULE_CHUNK_ID` was a single FK** — a real obligation is often backed by more than one rule chunk, or none yet during an in-progress gap analysis. Fixed: removed from `OBLIGATION_MAP`, replaced with a junction table `OBLIGATION_RULE_CHUNKS` (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`) — zero, one, or many rows per obligation.
- **`OBLIGATION_MAP.SOURCE_TABLE`/`SOURCE_COLUMNS` are free text with no enforced link to the real schema**, and Snowflake can't enforce an FK against dynamic table/column name strings. Not solved by a schema change — documented here as a genuine, structurally-unenforceable-in-SQL limitation, mitigated by a required check in the `GOVERNANCE_WRITE` approval workflow (a test/procedure step that validates `SOURCE_TABLE`/`SOURCE_COLUMNS` resolve against `INFORMATION_SCHEMA` before a row can flip to `approved`) rather than left as a silent, undetectable drift risk.
- **`TRANSACTION_REPORTS.MATCH_STATUS` didn't say which fields need to match.** Fixed: defined as an enum (`full_match` / `partial_match` / `no_match`), computed by comparing `TRANSACTION_REPORTS`' submitted fields against `TRADES.INSTRUMENT_ID`, `TRADES.PRICE` (exact), `TRADES.VOLUME` (exact), `TRADES.EXECUTION_TIMESTAMP` (within a documented tolerance, not exact — clock skew between a venue feed and a regulator submission is real) — `partial_match` when some but not all of these agree, not a binary.
- **The synthetic-data acceptance criterion ("behave identically" across two configs) was unmeasurable.** Fixed in `architecture.md`'s Synthetic data section — replaced with concrete checks: 100% referential integrity across all FKs, every seeded `VENUE_ID` represented in at least one `ORDERS`/`TRADES` row, and each detector's trigger rate falling within a documented expected band for that config's synthetic distribution (not literally identical counts across two different-sized configs — "agnostic" means the *mechanism* behaves the same way, not that two differently-sized datasets produce equal absolute numbers).

## Milestoning discipline — one generic rule, applied uniformly (v5)

Not a per-table design decision — a day-one, plug-and-play convention exactly like the market-agnostic rules in `architecture.md`: onboarding a new table means adding one column and one view from a fixed template, never inventing a bespoke versioning scheme for that table. The rule:

1. **Every table in `VIGIL.CORE` carries the same four audit columns, no exceptions: `CREATED_AT`, `CREATED_BY`, `LOADED_AT`, `LOADED_BY`.**
   - `LOADED_AT TIMESTAMP_NTZ NOT NULL` / `LOADED_BY VARCHAR NOT NULL` — *when* and *who or what* wrote **this specific row** (the role, service account, or named adaptor job, e.g. `MARKET_DATA_INGEST`, `GOVERNANCE_WRITE`, `jpx-order-feed-adaptor`). This is the pair that changes on every milestoned version.
   - `CREATED_AT TIMESTAMP_NTZ NOT NULL` / `CREATED_BY VARCHAR NOT NULL` — *when* and *who* the underlying entity (the natural key) was **first ever created**. On a natural key's first row these equal `LOADED_AT`/`LOADED_BY`; on every later milestoned version for the same key, they are copied forward unchanged from that first row — so "when was this entity created" stays answerable without a self-join back through every intermediate version, even after many corrections.
   - `POSITIONS` already had `LOADED_AT` (Fix #4) and `DETECTOR_CALIBRATION` already had the equivalent `EFFECTIVE_FROM`/`CALIBRATED_AT` (left as-is, same pattern, not renamed) — neither had an actor column or a creation-time column distinct from their latest-version timestamp. All four columns are now universal, retrofitted onto both (Fix #19).
2. **Every table's primary key includes `LOADED_AT`** (or, for tables already keyed by a natural event timestamp, that timestamp serves the same role). This is what makes multiple versions of the same logical entity coexist as distinct rows instead of colliding on the old PK.
3. **No functional role is ever granted `UPDATE` or `DELETE` on any table in `VIGIL.CORE` — full stop.** This replaces the old enumerated exception list (below), which by omission implied every table *not* named was fair game for mutation — that gap is exactly how `OBLIGATION_MAP`'s `UPDATE` grant crept into v4. The grant scripts in `sql/rbac/` simply never issue `UPDATE`/`DELETE`, so this is a structural property of the grants, not a rule someone has to remember to apply.
4. **A state change, correction, or removal is always a new row with a later `LOADED_AT` for the same natural key.** A "removal" (e.g. an `OBLIGATION_RULE_CHUNKS` association made in error) is a tombstone row, not a `DELETE` — see Fix #13.
5. **Every table gets one generic `<TABLE>_CURRENT` view**, mechanically identical across every table:
   ```sql
   SELECT * FROM <TABLE>
   QUALIFY ROW_NUMBER() OVER (
     PARTITION BY <natural key columns, excluding LOADED_AT>
     ORDER BY LOADED_AT DESC
   ) = 1
   ```
   This is the one piece of SQL every table reuses verbatim (column list changes, the pattern doesn't) — the actual "plug and play" mechanism: a new table is milestoned by adding `LOADED_AT` to its PK and pointing this template at its natural key, not by designing a new scheme.

`[FIX #10]`–`[FIX #18]` below are the specific tables this rule was not yet applied to as of v4, and what changes on each.

## [FIX #10] `VENUES.STATUS` had no append-only transition path

v4 added `DISCONTINUED_AT` for *seeding* a venue as already-discontinued (Cboe Japan), but never addressed a currently-*active* venue later discontinuing — flipping `STATUS` would require an `UPDATE`, and no role was ever granted one (the RBAC section didn't grant `MARKET_DATA_INGEST` — or anyone — `UPDATE` on `VENUES`, so the transition described in prose had no legal write path at all). Fixed: `LOADED_AT` added, PK becomes (`VENUE_ID`, `LOADED_AT`). A status change is a new row with the same `VENUE_ID` and a later `LOADED_AT`; `MARKET_DATA_INGEST`'s existing `INSERT`-only grant already covers it — no RBAC change needed for this one.

## [FIX #11] `JURISDICTIONS`, `BENEFICIAL_OWNERS`, `INSTRUMENTS`, `MARKET_PARTICIPANTS` had no milestoning at all

Each represents reference data that genuinely changes over time — a regulator is renamed, a beneficial-owner entity restructures, an instrument's `TICK_SIZE`/`LOT_SIZE` changes (an exchange rule change, not a typo fix), a participant is reclassified. v4 had no way to record any of these except by mutating the existing row and losing the prior value. Fixed uniformly: each gains `LOADED_AT`, each PK is extended to include it, each gets a `_CURRENT` view. Concretely: `JURISDICTIONS` PK → (`JURISDICTION_ID`, `LOADED_AT`); `BENEFICIAL_OWNERS` PK → (`BENEFICIAL_OWNER_ID`, `JURISDICTION_ID`, `LOADED_AT`); `INSTRUMENTS` PK → (`INSTRUMENT_ID`, `JURISDICTION_ID`, `LOADED_AT`); `MARKET_PARTICIPANTS` PK → (`PARTICIPANT_ID`, `JURISDICTION_ID`, `LOADED_AT`).

## [FIX #12] `OBLIGATION_MAP.STATUS`'s proposed→approved flip was the schema's one explicit `UPDATE` grant

v4's `GOVERNANCE_WRITE` role was granted `INSERT`/`UPDATE` on `OBLIGATION_MAP` specifically so `STATUS` could flip from `proposed` to `approved` — a direct contradiction of the append-only discipline the Conventions section claimed applied schema-wide, and it silently discarded the obligation's own timeline (when it was proposed vs. when/by whom it was approved is exactly the kind of governance detail an append-only audit trail should never overwrite). Fixed: `LOADED_AT` added, PK becomes (`OBLIGATION_ID`, `JURISDICTION_ID`, `LOADED_AT`). Approval is a new row — same `OBLIGATION_ID`, `STATUS = 'approved'`, later `LOADED_AT` — after the same `SOURCE_TABLE`/`SOURCE_COLUMNS` validation check (Fix #9) passes. `GOVERNANCE_WRITE`'s grant on `OBLIGATION_MAP` changes from `INSERT`/`UPDATE` to **`INSERT`-only**. `APPROVED_OBLIGATIONS` is redefined accordingly (see below) — the full proposed/approved history (and, in future, a `revoked` status) is preserved instead of overwritten.

## [FIX #13] `OBLIGATION_RULE_CHUNKS` had no way to correct a wrong association without `DELETE`

A junction row created in error (wrong rule chunk linked to an obligation) had no append-only fix — only `DELETE`, which no role is ever granted. Fixed: adds `LOADED_AT` and `IS_ACTIVE BOOLEAN NOT NULL DEFAULT TRUE`, PK extended to (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`, `LOADED_AT`). Removing an association is a tombstone row — same key, `IS_ACTIVE = FALSE`, later `LOADED_AT` — never a `DELETE`. The `_CURRENT` view filters to the latest `LOADED_AT` per (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`) `WHERE IS_ACTIVE`.

## [FIX #14] `TRANSACTION_REPORTS`' own lifecycle required mutation with no path defined

A report is created, then later `SUBMITTED_AT` is populated, then `FIELDS_COMPLETE`/`MATCH_STATUS` are computed — three points in time on what v4 modeled as one row, granted only `INSERT` (never `UPDATE`) to `MARKET_DATA_INGEST`. As written, v4 had no legal way to ever populate `SUBMITTED_AT` after the initial insert. Fixed: `LOADED_AT` added, PK becomes (`REPORT_ID`, `JURISDICTION_ID`, `LOADED_AT`). Each lifecycle event (created, submitted, match computed) is a new row with the same `REPORT_ID` and a later `LOADED_AT`; `TRANSACTION_REPORTS_CURRENT` surfaces the latest state. No RBAC change — `MARKET_DATA_INGEST`'s existing `INSERT`-only grant already covers every lifecycle event.

## [FIX #15] `TRADES`/`TRADE_REFERENCE_PRICES` had no correction path for a bust, amendment, or reference-price backfill

A real trade bust/amendment, or a reference-price feed arriving late or being restated, would have required mutating a row under v4's fixed PKs. Fixed two ways: `TRADE_REFERENCE_PRICES` gains `LOADED_AT` (PK → `TRADE_ID`, `VENUE_ID`, `LOADED_AT`) so a backfill or correction is a new row, same pattern as everywhere else. `TRADES` itself is left immutable (a trade print is a fact, not corrected in place) but gains a companion append-only table, `TRADE_CORRECTIONS` (new — `TRADE_ID`, `VENUE_ID`, `CORRECTION_TYPE` [`bust`/`amend`], `CORRECTED_FIELDS VARIANT`, `LOADED_AT`; PK = all four). `POSITIONS` accumulation and every detector must anti-join against the latest correction row per trade before treating it as live — busted trades are **surfaced, not silently hidden**, same discipline as `WASH_DETECTION_COVERAGE` (Fix #3): a query can always tell "no correction exists" from "a correction exists and was applied."

## [FIX #16] `ORDERS`' lifecycle columns assumed in-place mutation of a single row per order

`MODIFIED_TS`, `CANCELLED_TS`, and `FILLED_QUANTITY` on one mutable row per `(ORDER_ID, VENUE_ID)` contradicted the append-only rule the doc already claimed covered `ORDERS` — an order book genuinely emits a stream of events (new, modify, partial fill, fill, cancel), not one row that gets edited five times. Fixed: `ORDERS` becomes event-sourced. Adds `EVENT_TYPE` (`new`/`modify`/`partial_fill`/`fill`/`cancel`) and `EVENT_TS TIMESTAMP_NTZ NOT NULL`; PK becomes (`ORDER_ID`, `VENUE_ID`, `EVENT_TS`). `FILLED_QUANTITY` on each row is the cumulative-as-of-this-event quantity (adaptor-supplied, same as v4). `ORDERS_CURRENT` = latest `EVENT_TS` row per (`ORDER_ID`, `VENUE_ID`) — this is what `POSITIONS`/reporting read when they need an order's present state. The spoofing/layering detector's cancelled-unfilled-volume logic is unchanged in substance, just re-sourced: it reads `ORDERS_CURRENT WHERE EVENT_TYPE = 'cancel' AND FILLED_QUANTITY < QUANTITY` instead of a single mutable row's `CANCELLED_TS IS NOT NULL`.

## [FIX #17] `RULE_CORPUS` had no versioning, so an amended rule would overwrite the text a past citation actually pointed to

A regulator amends a rule; `CHUNK_TEXT` for that `CHUNK_ID` changes. Under v4, doing so in place would silently invalidate every past `AUDIT_LOG.RETRIEVED_RULE_CHUNK_IDS` citation — a citation must stay reproducible against exactly the text that was shown at the time, not whatever the corpus says today. Fixed: `LOADED_AT` added, PK becomes (`CHUNK_ID`, `LOADED_AT`). An amendment is a new row, same `CHUNK_ID`, later `LOADED_AT`, old text preserved. `RULE_CORPUS_CURRENT` surfaces the latest text per `CHUNK_ID` for normal lookups. **Follow-up flagged, not resolved here:** `AUDIT_LOG.RETRIEVED_RULE_CHUNK_IDS` should record the exact `(CHUNK_ID, LOADED_AT)` pair cited, not just `CHUNK_ID`, so a historical citation stays pinned to the version actually retrieved — an `AUDIT_LOG` column-level change, out of scope for this table-level pass.

## [FIX #18] Conventions' append-only rule was an enumerated exception list, not a blanket rule

v4 said no role is granted `UPDATE`/`DELETE` on six named tables (`ORDERS`, `TRADES`, `TRANSACTION_REPORTS`, `POSITIONS`, `AUDIT_LOG`, `DETECTOR_CALIBRATION`) — every other table was left unaddressed, which is exactly how `OBLIGATION_MAP`'s `UPDATE` grant (Fix #12) and the `VENUES`/`TRANSACTION_REPORTS` mutation gaps (Fixes #10, #14) crept in unnoticed. Fixed: replaced with the single blanket rule in "Milestoning discipline" above — no role is ever granted `UPDATE`/`DELETE` on **any** `VIGIL.CORE` table.

## [FIX #19] No table recorded who or what wrote a row, or when the underlying entity was first created

Fixes #10–#17 added `LOADED_AT` for *when* a version was written, but nothing anywhere recorded *who or what* wrote it — not even `POSITIONS` or `DETECTOR_CALIBRATION`, the two tables that already had timestamp-based milestoning before this pass. For a regulatory audit trail, "an obligation was approved" or "a position was restated" with no record of which role, service account, or adaptor run performed it is not a complete record — `AUDIT_LOG` already carries `APP_USER`/`SIGNOFF_BY` for agent/governance actions, but the underlying data tables had no equivalent. Separately, `LOADED_AT` alone conflates two different questions once a row has been through several corrections: "when was this version written" and "when did this entity first come into existence" — the latter is silently lost the moment a second version exists, recoverable only via `MIN(LOADED_AT)`, which gets more expensive and less obvious the more versions pile up.

Fixed with the four-column audit quartet in "Milestoning discipline" above (`CREATED_AT`/`CREATED_BY`/`LOADED_AT`/`LOADED_BY`), applied identically to **every** table in this document — including `TRADES`, `AUDIT_LOG`, and other single-insert fact tables where `CREATED_AT = LOADED_AT` and `CREATED_BY = LOADED_BY` trivially on every row (no entity ever gets a second version), because the point of a plug-and-play convention is that every table carries the same four columns without a per-table judgment call about whether it "needs" all of them. `POSITIONS` and `DETECTOR_CALIBRATION` are retrofitted with the same quartet (`CALIBRATED_BY` alongside `DETECTOR_CALIBRATION`'s existing `CALIBRATED_AT`, naming kept consistent with its pre-existing column) even though they predate this fix. `_CURRENT`-view logic is unaffected — `CREATED_AT`/`CREATED_BY` are carried-forward attributes of the winning row, never part of a natural key or a `QUALIFY` partition.

## [FIX #20] Internal/agency cross trades were indistinguishable from wash trades

The wash-trading detector's own definition — "a matched buy/sell pair in the same instrument, same beneficial owner, within a time window and price tolerance" — is structurally identical to a legitimate, disclosed internal (agency) cross a broker runs as ordinary business. Nothing in `TRADES` recorded *how* a trade matched, so every legitimate cross would false-positive identically to an actual wash trade, with no way to suppress the known-legitimate case. Fixed: `TRADES` gains `MATCHING_MECHANISM VARCHAR NOT NULL` (`continuous` / `cross` / `block` / `auction`). The wash-trading detector reads which mechanisms are exempt (and under what disclosure condition) from `DETECTOR_CALIBRATION.PARAMS` for that jurisdiction/venue — **not** a hardcoded exclusion list, per rule #3 — so a jurisdiction where crosses require no special disclosure and one where they require a specific marking both configure this without a schema change. A `cross`-mechanism trade is not automatically exempt from every check — it's exempt from the *pattern-match* trigger, not from `WASH_DETECTION_COVERAGE` or downstream review; a mispriced or excessively frequent cross is still a legitimate finding.

## [FIX #21] No representation of a regulator's own required report format at all

`TRANSACTION_REPORTS` tracked timeliness (`SUBMITTED_AT` vs. `DEADLINE`) and trade-match accuracy (`MATCH_STATUS`), but nothing anywhere modeled what a regulator's own circular actually requires to be submitted — a fixed field list, in a fixed format, sourced from specific internal columns, that changes when the regulator amends the circular. This is a real gap for a product whose first line describes itself as "citation-backed" — the report's *content* had no citation trail the way `OBLIGATION_MAP` already has via `OBLIGATION_RULE_CHUNKS`. Fixed with two new tables, mirroring the `OBLIGATION_MAP`/`OBLIGATION_RULE_CHUNKS` pattern exactly — see `REPORT_TEMPLATES`/`REPORT_TEMPLATE_RULE_CHUNKS` under "Core tables" below.

## [FIX #22] `FIELDS_COMPLETE` had no home for what "complete" means

Same class of bug `PARAMS` (Fix #2) closed for wash trading's time window: `FIELDS_COMPLETE` was "computed by a detector," with no table saying which fields that detector should check. Fixed: `FIELDS_COMPLETE` is computed against `REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED` for the report's (`JURISDICTION_ID`, `REPORT_TYPE`) — a required-field-presence check with an actual, versioned, citation-backed field list behind it, not an unspecified black box.

## [FIX #23] `TRANSACTION_REPORTS.TRADE_ID` being `NOT NULL` assumed every report is trade-linked

Real reporting regimes also require periodic, aggregate, or nil filings (e.g. "confirm zero reportable trades this period") that are not tied to one specific trade — v5's schema had no way to represent one. Fixed: `TRADE_ID` becomes nullable; new `REPORT_SCOPE VARCHAR NOT NULL DEFAULT 'trade'` (`trade` / `periodic` / `nil`) and nullable `PERIOD_START`/`PERIOD_END DATE` columns, populated when `REPORT_SCOPE != 'trade'`. A `trade`-scoped report keeps `TRADE_ID NOT NULL` by convention (enforced by the ingest procedure, not a `CHECK` conditional on another column, which Snowflake doesn't support declaratively) — this is a documented invariant, not a structural constraint.

## [FIX #24] No distinction between an internal correction and a regulator-facing amendment

`TRANSACTION_REPORTS`' own milestoning (Fix #14) means every lifecycle event — created, submitted, match computed — is a new row. But real reporting regimes also have a *regulator-facing* action with its own semantics: submitting an amendment or cancellation of a report the regulator already has on file (distinct concepts many regimes label explicitly, e.g. new/amendment/cancellation submission types). v5's milestoning conflated "we corrected our own record of this row" with "we told the regulator something changed." Fixed: new `REPORT_STATUS VARCHAR NOT NULL DEFAULT 'new'` (`new` / `amendment` / `cancellation`) — an `amendment`/`cancellation` row represents an actual outbound message to the regulator, not merely an internal restatement.

## [FIX #25] Nothing stored what was actually submitted

Timeliness and match status were both checkable, but nothing let you reproduce or audit the actual payload sent to a regulator — a real gap for a product whose value proposition includes defensibility under audit. Fixed: `REPORT_PAYLOAD_REF VARCHAR` — a pointer to the generated artifact (e.g. a Snowflake stage path), nullable until generated. The transformation logic itself (canonical rows + `REPORT_TEMPLATES` → the regulator's exact XML/CSV/fixed-width output) is adaptor/generator code, not schema — flagged for the build order, not modeled here — but the schema now has a place to record which artifact was produced from which template version.

## [FIX #26] Regulator-required, detector-irrelevant fields (LEI, trading capacity, short-sell/algo flags) had no home; block-trade deferred publication had none either

Real transaction-reporting regimes require fields no detector reads — a counterparty LEI, trading capacity (principal/agent), a short-sell flag, an algorithmic-trading flag, a large-in-scale waiver code — and these vary enough by jurisdiction that a named nullable column per field, per jurisdiction, would violate the spirit of rule #5 (extend, don't fork) at the field level even though it's technically permitted by it. Fixed: `ORDERS` and `TRADES` each gain `REGULATORY_ATTRIBUTES VARIANT` — a catch-all for jurisdiction-specific, detector-irrelevant regulatory fields, same pattern as `DETECTOR_CALIBRATION.PARAMS` (Fix #2). Separately: many regimes permit delayed public disclosure of a large-in-scale block trade even though the report itself is filed with the regulator on the normal `DEADLINE` — `TRANSACTION_REPORTS` gains `DEFERRED_PUBLICATION_UNTIL TIMESTAMP_NTZ`, nullable, kept distinct from `DEADLINE` because regulator-submission timing and public-disclosure timing are two different clocks.

## Conventions

- Every jurisdiction-scoped table carries `JURISDICTION_ID VARCHAR NOT NULL` — no default, no implicit single-jurisdiction assumption.
- Every venue-scoped table (execution/reporting events, not obligations) carries `VENUE_ID VARCHAR NOT NULL`, FK → `VENUES`.
- Every monetary column's table carries `CURRENCY VARCHAR(8) NOT NULL` — no default.
- Timestamps are `TIMESTAMP_NTZ`, dates are `DATE`. A venue's local time zone is a property of `VENUES`, resolved by the adaptor before load, not stored per-row.
- Primary/foreign key columns are `VARCHAR` (venue-assigned IDs are rarely numeric across markets) unless noted.
- `STATUS`/`FIELDS_COMPLETE`/boolean-flag columns are computed by a detector or procedure, never raw adaptor input, unless explicitly noted as adaptor-supplied.
- **Every table in `VIGIL.CORE` is append-only, no exceptions (v5, see "Milestoning discipline" above):** every table carries `CREATED_AT`/`CREATED_BY`/`LOADED_AT`/`LOADED_BY`, with `LOADED_AT` (or an equivalent natural event timestamp) in its primary key; no functional role is ever granted `UPDATE`/`DELETE` on anything; every table has a generic `_CURRENT` view. A correction, state change, or removal is always a new row with a later `LOADED_AT` (carrying `CREATED_AT`/`CREATED_BY` forward unchanged from that key's first row), never a mutation.

## Reference tables

### `JURISDICTIONS`
| Column | Type | Notes |
|---|---|---|
| `JURISDICTION_ID` | VARCHAR | e.g. `JP`, `US`. |
| `REGULATOR_NAME` | VARCHAR | e.g. "FSA/SESC", "SEC". |
| `PRIMARY_LANGUAGE` | VARCHAR | Drives `RULE_CORPUS.ORIGINAL_LANGUAGE` default expectation, not an override of the per-row field. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `JURISDICTION_ID` was first created; carried forward unchanged on every later version. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #11).** A change (e.g. regulator renamed) is a new row with a later `LOADED_AT`, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`JURISDICTION_ID`, `LOADED_AT`). `JURISDICTIONS_CURRENT` view = latest `LOADED_AT` per `JURISDICTION_ID` (see "Milestoning discipline").

### `VENUES`
| Column | Type | Notes |
|---|---|---|
| `VENUE_ID` | VARCHAR | e.g. `XTKS` (TSE), `XOSE` (Osaka Exchange), `TOCOM`, `JPNX` (Japannext PTS), `ODX`, `ODXST`, `CBOJ` (Cboe Japan PTS, discontinued), `CBOJBIDS` (Cboe BIDS Japan, discontinued). |
| `JURISDICTION_ID` | VARCHAR NOT NULL | FK → `JURISDICTIONS`. |
| `VENUE_NAME` | VARCHAR | |
| `VENUE_TYPE` | VARCHAR | `exchange` / `pts` / `otc_facility` / `block_trading`. |
| `OPERATOR_NAME` | VARCHAR | |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'active' | `active` / `discontinued`. |
| `ACTIVE_FROM` | DATE | Nullable when the venue's founding date isn't confirmed — do not guess a placeholder date. |
| `DISCONTINUED_AT` | DATE | **New — `STATUS` alone can't support historical data for a closed venue.** A synthetic generator or live adaptor must never produce `ORDERS`/`TRADES` for a venue dated after this value; a query reasoning about "was this venue open at trade time" checks the trade's timestamp against this range, not just today's `STATUS`. NULL while `STATUS = 'active'`. This is the fix for a real gap: a `STATUS` flag alone would either wrongly exclude a discontinued venue's real historical trades, or wrongly allow new trades to be generated for it past its actual closure — a date range is required, not optional. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `VENUE_ID` was first created; carried forward unchanged on every later version. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #10).** A `STATUS` transition (e.g. active → discontinued) is a new row with the same `VENUE_ID` and a later `LOADED_AT`, never an `UPDATE` — `MARKET_DATA_INGEST`'s existing `INSERT`-only grant covers it. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`VENUE_ID`, `LOADED_AT`). `VENUES_CURRENT` view = latest `LOADED_AT` per `VENUE_ID`. A jurisdiction has many venues, including ones that later stop operating — verified for Japan: 3 JPX Group exchanges + 2 active PTS operators outside the group + 2 further venues (Cboe Japan PTS and Cboe BIDS Japan) confirmed discontinued but with real historical trade data to represent — see below. This table's whole reason to exist includes carrying that history correctly, not just listing who's currently open.

### `BENEFICIAL_OWNERS` — new, per Fix #8
| Column | Type | Notes |
|---|---|---|
| `BENEFICIAL_OWNER_ID` | VARCHAR | Independent identifier space — **not** assumed to equal any `MARKET_PARTICIPANTS.PARTICIPANT_ID`. |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `OWNER_NAME` | VARCHAR | |
| `OWNER_TYPE` | VARCHAR | individual / corporate / fund, etc. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #11).** A restructuring/correction is a new row, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`BENEFICIAL_OWNER_ID`, `JURISDICTION_ID`, `LOADED_AT`). `BENEFICIAL_OWNERS_CURRENT` view = latest `LOADED_AT` per (`BENEFICIAL_OWNER_ID`, `JURISDICTION_ID`).

## Core tables

### `INSTRUMENTS`
| Column | Type | Notes |
|---|---|---|
| `INSTRUMENT_ID` | VARCHAR | Issuer/venue-local code. Not globally unique across jurisdictions — paired with `JURISDICTION_ID`. |
| `JURISDICTION_ID` | VARCHAR NOT NULL | The primary-listing jurisdiction. |
| `ISIN` | VARCHAR | Nullable — not every market assigns one. |
| `INSTRUMENT_TYPE` | VARCHAR | e.g. equity, derivative, bond, security token. |
| `TICK_SIZE` | NUMBER | |
| `LOT_SIZE` | NUMBER | |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #11).** A `TICK_SIZE`/`LOT_SIZE` change (an exchange rule change, not a typo fix) is a new row, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`INSTRUMENT_ID`, `JURISDICTION_ID`, `LOADED_AT`). `INSTRUMENTS_CURRENT` view = latest `LOADED_AT` per (`INSTRUMENT_ID`, `JURISDICTION_ID`). An instrument's *identity* is jurisdiction-scoped even though it may trade on several venues within that jurisdiction (e.g. TSE-listed stock also trading on Japannext PTS) — venue is recorded on the trade/order, not the instrument.

### `MARKET_PARTICIPANTS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `PARTICIPANT_TYPE` | VARCHAR | broker / proprietary / institutional / retail. |
| `BENEFICIAL_OWNER_ID` | VARCHAR | Nullable when genuinely unknown; when populated, FK → `BENEFICIAL_OWNERS` (+ `JURISDICTION_ID`) — **not** self-referencing `PARTICIPANT_ID` (Fix #8). |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #11).** A reclassification or beneficial-owner change is a new row, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`PARTICIPANT_ID`, `JURISDICTION_ID`, `LOADED_AT`). `MARKET_PARTICIPANTS_CURRENT` view = latest `LOADED_AT` per (`PARTICIPANT_ID`, `JURISDICTION_ID`). A participant is registered per jurisdiction (broker membership is typically jurisdiction-level, e.g. a securities company registered with Japan's FSA), and may be a member of multiple venues within it.

### `ORDERS`
**Event-sourced as of Fix #16** — one row per order *event* (new/modify/fill/cancel), not one mutable row per order. `MODIFIED_TS`/`CANCELLED_TS`/in-place `FILLED_QUANTITY` updates (v4) contradicted the append-only rule the doc already claimed covered this table; a real order book genuinely emits a stream of events.

| Column | Type | Notes |
|---|---|---|
| `ORDER_ID` | VARCHAR | Stable across every event for the same order. |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR NOT NULL | FK → `VENUES`. Where the order was submitted. |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | FK → `INSTRUMENTS` (+ `JURISDICTION_ID`). |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | FK → `MARKET_PARTICIPANTS` (+ `JURISDICTION_ID`). |
| `SIDE` | VARCHAR | buy / sell. |
| `ORDER_TYPE` | VARCHAR | limit / market / etc. |
| `EVENT_TYPE` | VARCHAR NOT NULL | **New (Fix #16).** `new` / `modify` / `partial_fill` / `fill` / `cancel`. |
| `EVENT_TS` | TIMESTAMP_NTZ NOT NULL | **New (Fix #16), replaces `SUBMITTED_TS`/`MODIFIED_TS`/`CANCELLED_TS`.** Timestamp of this specific event. The original `new` event's `EVENT_TS` is the order's submission time. |
| `PRICE` | NUMBER | As of this event. |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `QUANTITY` | NUMBER | As of this event (a `modify` event can change it). |
| `FILLED_QUANTITY` | NUMBER | Cumulative-as-of-this-event quantity, adaptor-supplied. 0 if never filled. |
| `REGULATORY_ATTRIBUTES` | VARIANT | **New (Fix #26).** Catch-all for jurisdiction-specific, detector-irrelevant regulatory fields an order-level report may require (e.g. an algorithmic-trading flag) — same pattern as `DETECTOR_CALIBRATION.PARAMS` (Fix #2), not a named nullable column per jurisdiction's idiosyncratic field. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `ORDER_ID` was first created (the `new` event); carried forward unchanged on every later event row for the same order. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this event row was written to the warehouse — distinct from `EVENT_TS` (the business event time reported by the venue feed), since an adaptor can backfill or replay events late. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`ORDER_ID`, `VENUE_ID`, `EVENT_TS`). `ORDERS_CURRENT` view = latest `EVENT_TS` row per (`ORDER_ID`, `VENUE_ID`) — this is what `POSITIONS`/reporting/detectors read for an order's present state. The spoofing/layering detector reads `ORDERS_CURRENT WHERE EVENT_TYPE = 'cancel' AND FILLED_QUANTITY < QUANTITY` for cancelled-unfilled volume — same detection logic as v4, re-sourced from the current view instead of a mutable row. **Never a source for `POSITIONS`** (Fix #4) — an order, filled or not, is not itself an economic position; only its resulting `TRADES` rows are.

### `TRADES`
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR NOT NULL | FK → `VENUES`. Where the trade printed. |
| `ORDER_ID` | VARCHAR | Nullable — some venue feeds report executions without order linkage; documented as a real per-venue adaptor variance, not assumed away. Contributes to `WASH_DETECTION_COVERAGE` (Fix #3) when null alongside a null `COUNTERPARTY_PARTICIPANT_ID`. |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `EXECUTION_TIMESTAMP` | TIMESTAMP_NTZ NOT NULL | |
| `PRICE` | NUMBER NOT NULL | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `VOLUME` | NUMBER NOT NULL | |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | The reporting side. |
| `COUNTERPARTY_PARTICIPANT_ID` | VARCHAR | Nullable — not every venue discloses the other side. Contributes to `WASH_DETECTION_COVERAGE` (Fix #3) when null alongside a null `ORDER_ID`. |
| `MATCHING_MECHANISM` | VARCHAR NOT NULL | **New (Fix #20).** `continuous` / `cross` / `block` / `auction`. The wash-trading detector reads which mechanisms are exempt from its pattern-match, and under what condition, from `DETECTOR_CALIBRATION.PARAMS` — not a hardcoded exclusion list. A `cross` trade is exempt from the *pattern-match trigger only*, not from `WASH_DETECTION_COVERAGE` or downstream review. |
| `REGULATORY_ATTRIBUTES` | VARIANT | **New (Fix #26).** Catch-all for jurisdiction-specific, detector-irrelevant regulatory fields (LEI, trading capacity, short-sell flag, etc.) — same pattern as `DETECTOR_CALIBRATION.PARAMS` (Fix #2). |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** Equal to `LOADED_AT` on every row — a trade print never gets a second version (corrections go to `TRADE_CORRECTIONS`), so `CREATED_AT`/`LOADED_AT` coincide by construction here, not as a special case. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When the print was written to the warehouse — distinct from `EXECUTION_TIMESTAMP` (the venue's own execution time). |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`TRADE_ID`, `VENUE_ID`). The sole source table for `POSITIONS` accumulation (Fix #4). `TRADES` itself stays immutable — a trade print is a fact, not corrected in place; see `TRADE_CORRECTIONS` below for how a bust/amendment is represented instead.

### `TRADE_CORRECTIONS` — new, per Fix #15
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR NOT NULL | FK → `TRADES`. |
| `VENUE_ID` | VARCHAR NOT NULL | |
| `CORRECTION_TYPE` | VARCHAR NOT NULL | `bust` / `amend`. |
| `CORRECTED_FIELDS` | VARIANT | For `amend`, the corrected field values; null/empty for `bust`. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** Equal to `LOADED_AT` — each correction row is its own immutable event (a second correction to the same trade is a new, distinct row, not a version of this one). |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`TRADE_ID`, `VENUE_ID`, `LOADED_AT`). A companion table, not a mutation of `TRADES` — a real-world trade bust or amendment is represented as a new row here rather than editing the original print. `POSITIONS` accumulation and every detector must anti-join against the latest correction per trade before treating it as live — a busted trade is **surfaced, not silently hidden**, same discipline as `WASH_DETECTION_COVERAGE` (Fix #3).

### `TRADE_REFERENCE_PRICES` — new, per Fix #5
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR NOT NULL | FK → `TRADES`. |
| `VENUE_ID` | VARCHAR NOT NULL | |
| `REFERENCE_PRICE_AT_EXECUTION` | NUMBER | Nullable — populated only where a venue publishes an NBBO-equivalent; genuinely absent for some venues, not an adaptor failure. Drives `EXECUTION_SLIPPAGE`. |
| `REFERENCE_PRICE_AT_ARRIVAL` | NUMBER | Nullable, same caveat. Drives `ARRIVAL_SLIPPAGE`, compared against the order's `new`-event `EVENT_TS` in `ORDERS` (the original submission, not necessarily the latest event in `ORDERS_CURRENT`). |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `SOURCE` | VARCHAR | Which reference-price feed/adaptor populated this row. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When a reference price for this (`TRADE_ID`, `VENUE_ID`) was first recorded; carried forward on a later backfill/restatement. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #15).** A late-arriving or restated reference price is a new row, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`TRADE_ID`, `VENUE_ID`, `LOADED_AT`). `TRADE_REFERENCE_PRICES_CURRENT` view = latest `LOADED_AT` per (`TRADE_ID`, `VENUE_ID`). A separate table, not columns on `TRADES`, because a reference price is externally sourced by its own adaptor job on its own timeline, not part of the trade record itself.

### `POSITIONS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR NOT NULL | |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `AS_OF_DATE` | DATE NOT NULL | |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | New (Fix #4) — a restatement is a new row with a later `LOADED_AT`, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `NET_QUANTITY` | NUMBER | Cumulative signed sum of `TRADES.VOLUME` through `AS_OF_DATE` — never derived from `ORDERS`. |
| `MARKET_VALUE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this (`PARTICIPANT_ID`, `INSTRUMENT_ID`, `JURISDICTION_ID`, `AS_OF_DATE`) snapshot was first loaded; carried forward on every later restatement of the same `AS_OF_DATE`. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`PARTICIPANT_ID`, `INSTRUMENT_ID`, `JURISDICTION_ID`, `AS_OF_DATE`, `LOADED_AT`). **No `VENUE_ID`** — deliberately: a concentration/exposure limit applies to a participant's total holding in an instrument, aggregated across every venue they traded it on, not a per-venue figure. Consumers read the row with the max `LOADED_AT` per `(PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE)`. Corporate-actions adjustment is explicitly deferred (Fix #4) — not handled by this accumulation rule.

### `TRANSACTION_REPORTS`
**Milestoned as of Fix #14** — a report is created, then later `SUBMITTED_AT` is populated, then `FIELDS_COMPLETE`/`MATCH_STATUS` are computed; each of these is a new row with the same `REPORT_ID` and a later `LOADED_AT`, not an in-place update of one mutable row. **Extended in Fix #21–#26** to actually represent what a regulator requires, not just whether the submission was timely.

| Column | Type | Notes |
|---|---|---|
| `REPORT_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR | Nullable — the reporting facility, when it differs from the trade's execution venue (e.g. an OTC trade reported to a jurisdiction-level facility rather than an exchange). |
| `REPORT_TYPE` | VARCHAR NOT NULL | **New (Fix #21).** FK (+ `JURISDICTION_ID`) into `REPORT_TEMPLATES` — which regulator-defined format this report must conform to. |
| `REPORT_SCOPE` | VARCHAR NOT NULL DEFAULT 'trade' | **New (Fix #23).** `trade` / `periodic` / `nil` — not every regulatory filing is tied to one trade (a nil/periodic filing is a legitimate report with no `TRADE_ID`). |
| `TRADE_ID` | VARCHAR | **Fix #23: now nullable.** FK → `TRADES`, required by convention (enforced by the ingest procedure, not a declarative constraint) when `REPORT_SCOPE = 'trade'`; NULL otherwise. |
| `PERIOD_START` / `PERIOD_END` | DATE | **New (Fix #23).** Nullable; populated when `REPORT_SCOPE != 'trade'` — the period a periodic/nil filing covers. |
| `REPORT_STATUS` | VARCHAR NOT NULL DEFAULT 'new' | **New (Fix #24).** `new` / `amendment` / `cancellation` — a regulator-facing submission action, distinct from an internal correction (which is just another `new`-status row via the normal milestoning path). |
| `SUBMITTED_AT` | TIMESTAMP_NTZ | Nullable if not yet submitted. |
| `DEADLINE` | TIMESTAMP_NTZ NOT NULL | Submission-to-regulator deadline. |
| `DEFERRED_PUBLICATION_UNTIL` | TIMESTAMP_NTZ | **New (Fix #26).** Nullable — a permitted delayed *public-disclosure* window for a large-in-scale block trade, distinct from `DEADLINE` (public disclosure and regulator submission are two different clocks). |
| `FIELDS_COMPLETE` | BOOLEAN | Computed against `REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED` for this report's (`JURISDICTION_ID`, `REPORT_TYPE`) (Fix #22) — not an unspecified black box. |
| `MATCH_STATUS` | VARCHAR | `full_match` / `partial_match` / `no_match` (Fix #9) — computed against `TRADES.INSTRUMENT_ID`/`PRICE`(exact)/`VOLUME`(exact)/`EXECUTION_TIMESTAMP`(documented tolerance). NULL when `REPORT_SCOPE != 'trade'` (nothing to match against). |
| `REPORT_PAYLOAD_REF` | VARCHAR | **New (Fix #25).** Pointer to the generated submission artifact (e.g. a Snowflake stage path); nullable until generated. The rendering logic itself is adaptor/generator code, not modeled here. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `REPORT_ID` was first created; carried forward on every later lifecycle-event row. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #14).** Each lifecycle event (created / submitted / match computed / amended / cancelled) is a new row with a later `LOADED_AT`, never an `UPDATE`. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`REPORT_ID`, `JURISDICTION_ID`, `LOADED_AT`). `TRANSACTION_REPORTS_CURRENT` view = latest `LOADED_AT` per (`REPORT_ID`, `JURISDICTION_ID`) — this is what a reporting-timeliness/completeness detector reads. No RBAC change: `MARKET_DATA_INGEST`'s existing `INSERT`-only grant already covers every lifecycle event; generating a compliant payload additionally requires `MARKET_DATA_INGEST` to hold `SELECT` on `REPORT_TEMPLATES_CURRENT` (new grant, Fix #21 — see RBAC below).

### `OBLIGATION_MAP`
**Milestoned as of Fix #12** — the proposed→approved flip is a new row, not the `UPDATE` v4 required.

| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | Obligations are regulator-level, not per-venue — this is the whole point of the `JURISDICTION_ID`/`VENUE_ID` split. |
| `OBLIGATION_DESCRIPTION` | VARCHAR | |
| `SOURCE_TABLE` | VARCHAR | Free text — real-schema linkage is unenforceable in SQL; validated by procedure at approval time instead (Fix #9). |
| `SOURCE_COLUMNS` | VARCHAR | Same caveat. |
| `DETECTOR_NAME` | VARCHAR | |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'proposed' | `proposed` / `approved` — a transition is a **new row**, same `OBLIGATION_ID`, later `LOADED_AT` (Fix #12), inserted only by a `GOVERNANCE_WRITE` session and only after the `SOURCE_TABLE`/`SOURCE_COLUMNS` validation check (Fix #9) passes. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `OBLIGATION_ID` was first proposed; carried forward through approval and any later status change. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #12).** |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`OBLIGATION_ID`, `JURISDICTION_ID`, `LOADED_AT`). `RULE_CHUNK_ID` removed (Fix #9) — see `OBLIGATION_RULE_CHUNKS` below. `GOVERNANCE_WRITE`'s grant on this table is **`INSERT`-only** (Fix #12) — it never needed `UPDATE` once approval became a new row.

### `OBLIGATION_RULE_CHUNKS` — new, per Fix #9; milestoned per Fix #13
| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR NOT NULL | FK → `OBLIGATION_MAP` (+ `JURISDICTION_ID`). |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `RULE_CHUNK_ID` | VARCHAR NOT NULL | FK → `RULE_CORPUS`. |
| `IS_ACTIVE` | BOOLEAN NOT NULL DEFAULT TRUE | **New (Fix #13).** Removing a wrong association is a tombstone row (`IS_ACTIVE = FALSE`, later `LOADED_AT`), never a `DELETE`. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #13).** |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`, `LOADED_AT`). `OBLIGATION_RULE_CHUNKS_CURRENT` view = latest `LOADED_AT` row per (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`) `WHERE IS_ACTIVE`. No rows in the current view = no rule chunk identified yet (a legitimate in-progress gap-analysis state); one or many = an obligation backed by multiple rule paragraphs, common in practice.

### `APPROVED_OBLIGATIONS` — new view, per Fix #6; redefined per Fix #12
```sql
SELECT * FROM OBLIGATION_MAP
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY OBLIGATION_ID, JURISDICTION_ID ORDER BY LOADED_AT DESC
) = 1
AND STATUS = 'approved'
```
The latest `LOADED_AT` row per obligation, filtered to `approved` — not "any row ever approved," so a later `revoked` status (if added) correctly removes the obligation from this view without deleting its history. The only obligation-lookup target `ANALYST_READ`/the agent's obligation-lookup tool is granted — see RBAC below.

### `RULE_CORPUS`
**Milestoned as of Fix #17** — an amended rule is a new row, so a past citation against the old text stays reproducible.

| Column | Type | Notes |
|---|---|---|
| `CHUNK_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `DOC_TITLE` | VARCHAR | |
| `SECTION_REF` | VARCHAR | Citable unit (e.g. rule/paragraph number). |
| `CHUNK_TEXT` | VARCHAR | |
| `SOURCE_AUTHORITY` | VARCHAR NOT NULL | `original` / `translation`. Present from the first row loaded, not added later — directly relevant for Japan, where the SESC/FSA's authoritative text is Japanese and any English version is a provisional translation. |
| `ORIGINAL_LANGUAGE` | VARCHAR NOT NULL | |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When this `CHUNK_ID` was first loaded; carried forward through every later amendment. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #17).** A rule amendment is a new row, same `CHUNK_ID`, later `LOADED_AT` — old text is never overwritten. |
| `LOADED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

PK: (`CHUNK_ID`, `LOADED_AT`). `RULE_CORPUS_CURRENT` view = latest `LOADED_AT` per `CHUNK_ID`, for normal lookups. **Follow-up flagged (Fix #17):** `AUDIT_LOG.RETRIEVED_RULE_CHUNK_IDS` should pin the exact `(CHUNK_ID, LOADED_AT)` cited, not just `CHUNK_ID`, so a historical citation stays reproducible against the version actually shown.

### `AUDIT_LOG`
Append-only by grant (no role ever gets `UPDATE`/`DELETE`). Same column shape as `Praman.AUDIT_LOG`: `RUN_ID`, `APP_USER`, `STAGE`, `PROMPT_OR_QUESTION`, `MODEL_VERSION`, `RETRIEVED_RULE_CHUNK_IDS`, `QUERY_SNAPSHOT_ID`, `OUTPUT`, `IS_EVAL`, `SIGNOFF_FOR_RUN_ID`, `HUMAN_DECISION`, `SIGNOFF_BY`, `SIGNOFF_AT`, plus **`CREATED_AT`/`CREATED_BY`/`LOADED_AT`/`LOADED_BY`** (Fix #19 — trivially equal in pairs on every row, since an audit row is never itself versioned; `LOADED_BY` is the `AUDIT_INSERT`-granted identity that wrote the row, which can differ from `APP_USER`, the identity whose *action* is being logged).

### `DETECTOR_CALIBRATION`
| Column | Type | Notes |
|---|---|---|
| `CALIBRATION_ID` | NUMBER AUTOINCREMENT | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR | Nullable — some detectors calibrate per venue (spoofing/layering cancel-rate), others per jurisdiction regardless of venue (concentration limits, which apply to a cross-venue total). NULL means "applies across all venues in this jurisdiction." |
| `DETECTOR_NAME` | VARCHAR NOT NULL | |
| `DIMENSION_KEY` | VARCHAR | e.g. instrument, participant class. |
| `Z_THRESHOLD` | FLOAT | Statistical detectors only; NULL for rules-based or pattern-match ones. |
| `MIN_BASELINE_PERIODS` | NUMBER | Statistical detectors only. |
| `PARAMS` | VARIANT | **New (Fix #2)** — arbitrary detector-specific parameters for pattern-match/rules-based detectors, e.g. wash trading's `{"time_window_seconds": 30, "price_tolerance_pct": 0.001}`. Every detector reads its tunable values from this table now, statistical or not — no detector embeds a literal. |
| `IS_PROVISIONAL` | BOOLEAN NOT NULL | Cold-start default flag. |
| `EFFECTIVE_FROM` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATED_AT` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATION_METHOD` | VARCHAR | `default-uncalibrated` / `percentile-historical` / `manual-override`. |
| `CALIBRATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** Companion to the pre-existing `CALIBRATED_AT`, naming kept consistent with it rather than renamed to `LOADED_BY`. |
| `CREATED_AT` | TIMESTAMP_NTZ NOT NULL | **New (Fix #19).** When calibration for this (`JURISDICTION_ID`, `VENUE_ID`, `DETECTOR_NAME`, `DIMENSION_KEY`) combination was first set; carried forward through every later recalibration. |
| `CREATED_BY` | VARCHAR NOT NULL | **New (Fix #19).** |

Append-only — a recalibration inserts a new row, never updates one. `DETECTOR_CALIBRATION_CURRENT` view = latest `EFFECTIVE_FROM` per (`JURISDICTION_ID`, `VENUE_ID`, `DETECTOR_NAME`, `DIMENSION_KEY`).

## RBAC additions from this revision

- **`MARKET_DATA_INGEST`** (Fix #7) — `INSERT`-only on `JURISDICTIONS`, `VENUES`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `BENEFICIAL_OWNERS`, `ORDERS`, `TRADES`, `TRADE_CORRECTIONS`, `TRANSACTION_REPORTS`, `POSITIONS`, `TRADE_REFERENCE_PRICES`. Never `UPDATE`/`DELETE` on any of them — the milestoning pass (Fixes #10, #14, #16) confirms every lifecycle event on these tables (a `VENUES` status change, an `ORDERS` event, a `TRANSACTION_REPORTS` submission) is an `INSERT`, so this role's grant never needed to change even though several of these tables' write patterns did.
- **`ANALYST_READ`** is granted `SELECT` on `APPROVED_OBLIGATIONS` (the view), not `SELECT` on the base `OBLIGATION_MAP` table (Fix #6) — direct base-table visibility (including `proposed` rows) stays with `GOVERNANCE_WRITE`.
- **`GOVERNANCE_WRITE`** (Fix #12) — grant on `OBLIGATION_MAP` changes from `INSERT`/`UPDATE` to **`INSERT`-only**; `OBLIGATION_RULE_CHUNKS` and `RULE_CORPUS` were already `INSERT`-only and are unaffected. No functional role holds `UPDATE`/`DELETE` on any `VIGIL.CORE` table as of v5 (Fix #18) — this was the last one that did.

## First jurisdiction: Japan (JP) — verified venue list to seed `VENUES`

Verified live against each operator's own site before writing this contract, not assumed:

| `VENUE_ID` | Name | Type | Status | `ACTIVE_FROM` / `DISCONTINUED_AT` | Confirmed |
|---|---|---|---|---|---|
| `XTKS` | Tokyo Stock Exchange | exchange | active | unconfirmed / — | Yes — JPX Group site |
| `XOSE` | Osaka Exchange | exchange | active | unconfirmed / — | Yes — JPX Group site |
| `TOCOM` | Tokyo Commodity Exchange | exchange | active | unconfirmed / — | Yes — JPX Group site (listed as a distinct link on JPX's own homepage; whether its derivatives book has since been operationally folded into `XOSE` needs one more check before finalizing granularity) |
| `JPNX` | Japannext PTS | pts | active | unconfirmed / — | Yes — Japannext's own site (X-Market/U-Market segments, Night Market session, published FIX/ITCH/OUCH specs) |
| `ODX` | Osaka Digital Exchange | pts | active | unconfirmed / — | Yes — ODX's own site, self-described as "the third PTS in Japan" for equities |
| `ODXST` | ODX START (security tokens) | pts | active | unconfirmed / — | Yes — same ODX source; a genuinely different instrument class (security tokens, not equities), kept as its own `VENUE_ID` rather than folded into `ODX` |
| `CBOJ` | Cboe Japan proprietary trading system (formerly Chi-X Japan) | pts | **discontinued** | unconfirmed / **2025-08-29** | **Primary-source confirmed**, per Cboe Global Markets' own investor-relations press release, "Cboe Plans to Cease Japanese Equities Operations," July 23, 2025 (retrieved via Wayback Machine archive after the live IR page returned HTTP 403 to a direct fetch — archived copy is the actual source read, not the live URL). Announced wind-down of its Japanese equities business; operations expected to suspend **August 29, 2025**, subject to regulatory consultation for formal closure. Now the same confidence tier as the six directly-confirmed-active venues above, not merely corroborated. **Seed this row** — real historical trades predate the closure date and must remain representable; `DISCONTINUED_AT = '2025-08-29'` is what stops a generator/adaptor from producing new trades for it past that date, not the exclusion of the row itself. |
| `CBOJBIDS` | Cboe BIDS Japan block trading platform | block_trading | **discontinued** | unconfirmed / **2025-08-29** | **Primary-source confirmed**, same press release — a second, distinct venue (block trading, not the continuous PTS order book) wound down in the same announcement. Not previously identified before this source was read; **seed this row too**, same `DISCONTINUED_AT` and same rationale as `CBOJ`. |

`ACTIVE_FROM` is left `unconfirmed` for every row above, including the six active ones — a founding/listing date was not verified for any venue this session, and none should be guessed or defaulted. Populate before seeding, or leave `NULL` (per convention, do not guess a placeholder date) rather than treat "unconfirmed" as license to invent one.

Regulator: `JURISDICTION_ID = 'JP'`, `REGULATOR_NAME = 'FSA/SESC'` (Financial Services Agency / Securities and Exchange Surveillance Commission — SESC referenced directly on JPX's own homepage as the destination for market-fairness complaints).

## US cross-verification (for the second `JURISDICTION_CONFIG`, agnosticism proof)

Re-confirmed live this session, not from memory: the CAT NMS Plan's own site (`catnmsplan.com`) is current and active (2026-dated updates), and its "About CAT" page states SEC Rule 613 (adopted 2012) requires "the national securities exchanges and national securities associations" — the SROs — to jointly build and maintain the Consolidated Audit Trail. Combined with the earlier-confirmed SEC SRO rulemaking page (24+ national securities exchanges + FINRA), this is the same one-regulator/many-venues shape as Japan, at larger scale — supports `US` as the second `JURISDICTION_CONFIG` for the market-agnosticism proof `architecture.md`'s build order requires, though the specific `VENUES` seed list for `US` (which of the 24+ exchanges to actually include) is not yet finalized and should get the same per-venue verification discipline applied to Japan rather than being bulk-copied from the SEC's list without re-checking which are still active.

## Change log

- v1 — initial contract, single `MARKET_ID` conflating regulator and venue.
- v2 — split `MARKET_ID` into `JURISDICTION_ID` (regulator) and `VENUE_ID` (execution venue), after verifying Japan's real venue structure live.
- v3 — nine fixes from a structural review: `DETECTOR_CALIBRATION.PARAMS` for pattern-match detectors, `WASH_DETECTION_COVERAGE` to surface (not hide) wash-trading blind spots, `POSITIONS` derivation fixed to `TRADES`-only with `LOADED_AT` restatement handling, `TRADE_REFERENCE_PRICES` + two correctly-timed slippage metrics for best execution, `APPROVED_OBLIGATIONS` view making the governance gate structural, new `MARKET_DATA_INGEST` role, new `BENEFICIAL_OWNERS` reference table, `OBLIGATION_RULE_CHUNKS` junction table replacing a single FK, and defined `MATCH_STATUS` semantics. `CBOJ` reclassified from "unverified" to "confirmed discontinued" per user input + independent corroboration.
- v4 — `VENUES` gains `ACTIVE_FROM`/`DISCONTINUED_AT` date columns: a `STATUS` flag alone can't support historical trades from a now-closed venue, which real data requires (a discontinued venue still has real past trades to represent; a generator/adaptor must stop producing *new* trades for it at its actual closure date, not before, and not never). `CBOJ` upgraded from "corroborated" to **primary-source confirmed** — Cboe Global Markets' own July 23, 2025 press release ("Cboe Plans to Cease Japanese Equities Operations"), retrieved via Wayback Machine after the live IR page returned HTTP 403 — with an exact closure date (`DISCONTINUED_AT = '2025-08-29'`) and now seeded, not excluded. Same source surfaced a second, previously unidentified venue, `CBOJBIDS` (Cboe BIDS Japan block trading platform), wound down in the same announcement — added and seeded with the same date.
- v5 (this version) — milestoning made a universal, plug-and-play property of every `VIGIL.CORE` table (`[FIX #10]`–`[FIX #19]`), prompted by a hard requirement that nothing in `VIGIL.CORE` is ever deleted or mutated. Every table now carries `CREATED_AT`/`CREATED_BY`/`LOADED_AT`/`LOADED_BY` with `LOADED_AT` in its PK and a generic `<TABLE>_CURRENT` view; no functional role is ever granted `UPDATE`/`DELETE` on anything (closing `OBLIGATION_MAP`'s one remaining `UPDATE` grant, Fix #12). `ORDERS` becomes event-sourced (`EVENT_TYPE`/`EVENT_TS` replace mutable `MODIFIED_TS`/`CANCELLED_TS`, Fix #16); `TRADES` gains a companion `TRADE_CORRECTIONS` table for busts/amendments (Fix #15) instead of ever mutating a trade print; `TRANSACTION_REPORTS` and `RULE_CORPUS` become append-only for the same reason (Fixes #14, #17); `OBLIGATION_RULE_CHUNKS` gains an `IS_ACTIVE` tombstone flag so a wrong association is corrected without `DELETE` (Fix #13); `APPROVED_OBLIGATIONS` is redefined against the latest `LOADED_AT` row per obligation (Fix #12).
