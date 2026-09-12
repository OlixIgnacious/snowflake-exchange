# Canonical schema contract — v3

Versioned reference for `VIGIL.CORE`'s tables, written **before** the DDL exists (per `architecture.md`'s market-agnostic design rule #4), not consolidated from scattered comments afterward. Any DDL change must be reflected here in the same change, not after the fact.

**v3 fixes a batch of structural gaps a review pass found in v2** — every fix below is numbered `[FIX #n]` and traced to a specific finding, same discipline as `Praman`'s `plug_and_play_architecture_v2.md`. v2's `JURISDICTION_ID`/`VENUE_ID` split itself was correct and is unchanged; the gaps were one level down — in what got calibrated, how positions derive, what best execution compares, who can write, and two undefined identifier spaces.

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

## Conventions

- Every jurisdiction-scoped table carries `JURISDICTION_ID VARCHAR NOT NULL` — no default, no implicit single-jurisdiction assumption.
- Every venue-scoped table (execution/reporting events, not obligations) carries `VENUE_ID VARCHAR NOT NULL`, FK → `VENUES`.
- Every monetary column's table carries `CURRENCY VARCHAR(8) NOT NULL` — no default.
- Timestamps are `TIMESTAMP_NTZ`, dates are `DATE`. A venue's local time zone is a property of `VENUES`, resolved by the adaptor before load, not stored per-row.
- Primary/foreign key columns are `VARCHAR` (venue-assigned IDs are rarely numeric across markets) unless noted.
- `STATUS`/`FIELDS_COMPLETE`/boolean-flag columns are computed by a detector or procedure, never raw adaptor input, unless explicitly noted as adaptor-supplied.
- Every event/snapshot table is append-only in practice: no functional role is ever granted `UPDATE`/`DELETE` on `ORDERS`, `TRADES`, `TRANSACTION_REPORTS`, `POSITIONS`, `AUDIT_LOG`, or `DETECTOR_CALIBRATION`. A correction is a new row with a later `LOADED_AT`/`CALIBRATED_AT`, never a mutation.

## Reference tables

### `JURISDICTIONS`
| Column | Type | Notes |
|---|---|---|
| `JURISDICTION_ID` | VARCHAR | e.g. `JP`, `US`. |
| `REGULATOR_NAME` | VARCHAR | e.g. "FSA/SESC", "SEC". |
| `PRIMARY_LANGUAGE` | VARCHAR | Drives `RULE_CORPUS.ORIGINAL_LANGUAGE` default expectation, not an override of the per-row field. |

PK: `JURISDICTION_ID`.

### `VENUES`
| Column | Type | Notes |
|---|---|---|
| `VENUE_ID` | VARCHAR | e.g. `XTKS` (TSE), `XOSE` (Osaka Exchange), `TOCOM`, `JPNX` (Japannext PTS), `ODX`, `ODXST`. |
| `JURISDICTION_ID` | VARCHAR NOT NULL | FK → `JURISDICTIONS`. |
| `VENUE_NAME` | VARCHAR | |
| `VENUE_TYPE` | VARCHAR | `exchange` / `pts` / `otc_facility`. |
| `OPERATOR_NAME` | VARCHAR | |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'active' | `active` / `discontinued`. Exists because venues genuinely stop operating (see Cboe Japan note below) — a discontinued venue's historical rows stay queryable, it's just not a target for new synthetic/live data. |

PK: `VENUE_ID`. A jurisdiction has many venues (verified for Japan: 3 JPX Group exchanges + 2 PTS operators outside the group, one further PTS confirmed discontinued — see below) — this table's whole reason to exist.

### `BENEFICIAL_OWNERS` — new, per Fix #8
| Column | Type | Notes |
|---|---|---|
| `BENEFICIAL_OWNER_ID` | VARCHAR | Independent identifier space — **not** assumed to equal any `MARKET_PARTICIPANTS.PARTICIPANT_ID`. |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `OWNER_NAME` | VARCHAR | |
| `OWNER_TYPE` | VARCHAR | individual / corporate / fund, etc. |

PK: (`BENEFICIAL_OWNER_ID`, `JURISDICTION_ID`).

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

PK: (`INSTRUMENT_ID`, `JURISDICTION_ID`). An instrument's *identity* is jurisdiction-scoped even though it may trade on several venues within that jurisdiction (e.g. TSE-listed stock also trading on Japannext PTS) — venue is recorded on the trade/order, not the instrument.

### `MARKET_PARTICIPANTS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `PARTICIPANT_TYPE` | VARCHAR | broker / proprietary / institutional / retail. |
| `BENEFICIAL_OWNER_ID` | VARCHAR | Nullable when genuinely unknown; when populated, FK → `BENEFICIAL_OWNERS` (+ `JURISDICTION_ID`) — **not** self-referencing `PARTICIPANT_ID` (Fix #8). |

PK: (`PARTICIPANT_ID`, `JURISDICTION_ID`). A participant is registered per jurisdiction (broker membership is typically jurisdiction-level, e.g. a securities company registered with Japan's FSA), and may be a member of multiple venues within it.

### `ORDERS`
| Column | Type | Notes |
|---|---|---|
| `ORDER_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR NOT NULL | FK → `VENUES`. Where the order was submitted. |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | FK → `INSTRUMENTS` (+ `JURISDICTION_ID`). |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | FK → `MARKET_PARTICIPANTS` (+ `JURISDICTION_ID`). |
| `SIDE` | VARCHAR | buy / sell. |
| `ORDER_TYPE` | VARCHAR | limit / market / etc. |
| `SUBMITTED_TS` | TIMESTAMP_NTZ NOT NULL | |
| `MODIFIED_TS` | TIMESTAMP_NTZ | Nullable. |
| `CANCELLED_TS` | TIMESTAMP_NTZ | Nullable — populated only if the order was cancelled unfilled or partially filled. |
| `PRICE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `QUANTITY` | NUMBER | |
| `FILLED_QUANTITY` | NUMBER | 0 if never filled. |

PK: (`ORDER_ID`, `VENUE_ID`). Cancelled-unfilled rows are the raw material for spoofing/layering detection. **Never a source for `POSITIONS`** (Fix #4) — an order, filled or not, is not itself an economic position; only its resulting `TRADES` rows are.

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

PK: (`TRADE_ID`, `VENUE_ID`). The sole source table for `POSITIONS` accumulation (Fix #4).

### `TRADE_REFERENCE_PRICES` — new, per Fix #5
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR NOT NULL | FK → `TRADES`. |
| `VENUE_ID` | VARCHAR NOT NULL | |
| `REFERENCE_PRICE_AT_EXECUTION` | NUMBER | Nullable — populated only where a venue publishes an NBBO-equivalent; genuinely absent for some venues, not an adaptor failure. Drives `EXECUTION_SLIPPAGE`. |
| `REFERENCE_PRICE_AT_ARRIVAL` | NUMBER | Nullable, same caveat. Drives `ARRIVAL_SLIPPAGE`, compared against `ORDERS.SUBMITTED_TS`. |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `SOURCE` | VARCHAR | Which reference-price feed/adaptor populated this row. |

PK: (`TRADE_ID`, `VENUE_ID`). A separate table, not columns on `TRADES`, because a reference price is externally sourced by its own adaptor job on its own timeline, not part of the trade record itself.

### `POSITIONS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR NOT NULL | |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `AS_OF_DATE` | DATE NOT NULL | |
| `LOADED_AT` | TIMESTAMP_NTZ NOT NULL | New (Fix #4) — a restatement is a new row with a later `LOADED_AT`, never an `UPDATE`. |
| `NET_QUANTITY` | NUMBER | Cumulative signed sum of `TRADES.VOLUME` through `AS_OF_DATE` — never derived from `ORDERS`. |
| `MARKET_VALUE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |

PK: (`PARTICIPANT_ID`, `INSTRUMENT_ID`, `JURISDICTION_ID`, `AS_OF_DATE`, `LOADED_AT`). **No `VENUE_ID`** — deliberately: a concentration/exposure limit applies to a participant's total holding in an instrument, aggregated across every venue they traded it on, not a per-venue figure. Consumers read the row with the max `LOADED_AT` per `(PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE)`. Corporate-actions adjustment is explicitly deferred (Fix #4) — not handled by this accumulation rule.

### `TRANSACTION_REPORTS`
| Column | Type | Notes |
|---|---|---|
| `REPORT_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR | Nullable — the reporting facility, when it differs from the trade's execution venue (e.g. an OTC trade reported to a jurisdiction-level facility rather than an exchange). |
| `TRADE_ID` | VARCHAR NOT NULL | FK → `TRADES`. |
| `SUBMITTED_AT` | TIMESTAMP_NTZ | Nullable if not yet submitted. |
| `DEADLINE` | TIMESTAMP_NTZ NOT NULL | |
| `FIELDS_COMPLETE` | BOOLEAN | Computed by a detector, not adaptor input. |
| `MATCH_STATUS` | VARCHAR | `full_match` / `partial_match` / `no_match` (Fix #9) — computed against `TRADES.INSTRUMENT_ID`/`PRICE`(exact)/`VOLUME`(exact)/`EXECUTION_TIMESTAMP`(documented tolerance). |

PK: (`REPORT_ID`, `JURISDICTION_ID`).

### `OBLIGATION_MAP`
| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | Obligations are regulator-level, not per-venue — this is the whole point of the `JURISDICTION_ID`/`VENUE_ID` split. |
| `OBLIGATION_DESCRIPTION` | VARCHAR | |
| `SOURCE_TABLE` | VARCHAR | Free text — real-schema linkage is unenforceable in SQL; validated by procedure at approval time instead (Fix #9). |
| `SOURCE_COLUMNS` | VARCHAR | Same caveat. |
| `DETECTOR_NAME` | VARCHAR | |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'proposed' | `proposed` / `approved` — flips only via a `GOVERNANCE_WRITE` session, and only after the `SOURCE_TABLE`/`SOURCE_COLUMNS` validation check (Fix #9) passes. |

PK: (`OBLIGATION_ID`, `JURISDICTION_ID`). `RULE_CHUNK_ID` removed (Fix #9) — see `OBLIGATION_RULE_CHUNKS` below.

### `OBLIGATION_RULE_CHUNKS` — new, per Fix #9
| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR NOT NULL | FK → `OBLIGATION_MAP` (+ `JURISDICTION_ID`). |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `RULE_CHUNK_ID` | VARCHAR NOT NULL | FK → `RULE_CORPUS`. |

PK: (`OBLIGATION_ID`, `JURISDICTION_ID`, `RULE_CHUNK_ID`). Zero rows = no rule chunk identified yet (a legitimate in-progress gap-analysis state); one or many rows = an obligation backed by multiple rule paragraphs, common in practice.

### `APPROVED_OBLIGATIONS` — new view, per Fix #6
`SELECT * FROM OBLIGATION_MAP WHERE STATUS = 'approved'`. The only obligation-lookup target `ANALYST_READ`/the agent's obligation-lookup tool is granted — see RBAC below.

### `RULE_CORPUS`
| Column | Type | Notes |
|---|---|---|
| `CHUNK_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `DOC_TITLE` | VARCHAR | |
| `SECTION_REF` | VARCHAR | Citable unit (e.g. rule/paragraph number). |
| `CHUNK_TEXT` | VARCHAR | |
| `SOURCE_AUTHORITY` | VARCHAR NOT NULL | `original` / `translation`. Present from the first row loaded, not added later — directly relevant for Japan, where the SESC/FSA's authoritative text is Japanese and any English version is a provisional translation. |
| `ORIGINAL_LANGUAGE` | VARCHAR NOT NULL | |

PK: `CHUNK_ID`.

### `AUDIT_LOG`
Append-only by grant (no role ever gets `UPDATE`/`DELETE`). Same column shape as `Praman.AUDIT_LOG`: `RUN_ID`, `APP_USER`, `STAGE`, `PROMPT_OR_QUESTION`, `MODEL_VERSION`, `RETRIEVED_RULE_CHUNK_IDS`, `QUERY_SNAPSHOT_ID`, `OUTPUT`, `IS_EVAL`, `SIGNOFF_FOR_RUN_ID`, `HUMAN_DECISION`, `SIGNOFF_BY`, `SIGNOFF_AT`.

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

Append-only — a recalibration inserts a new row, never updates one.

## RBAC additions from this revision

- **`MARKET_DATA_INGEST`** (Fix #7) — `INSERT`-only on `JURISDICTIONS`, `VENUES`, `INSTRUMENTS`, `MARKET_PARTICIPANTS`, `BENEFICIAL_OWNERS`, `ORDERS`, `TRADES`, `TRANSACTION_REPORTS`, `POSITIONS`, `TRADE_REFERENCE_PRICES`. Never `UPDATE`/`DELETE` on any of them.
- **`ANALYST_READ`** is granted `SELECT` on `APPROVED_OBLIGATIONS` (the view), not `SELECT` on the base `OBLIGATION_MAP` table (Fix #6) — direct base-table visibility (including `proposed` rows) stays with `GOVERNANCE_WRITE`.

## First jurisdiction: Japan (JP) — verified venue list to seed `VENUES`

Verified live against each operator's own site before writing this contract, not assumed:

| `VENUE_ID` | Name | Type | Status | Confirmed |
|---|---|---|---|---|
| `XTKS` | Tokyo Stock Exchange | exchange | active | Yes — JPX Group site |
| `XOSE` | Osaka Exchange | exchange | active | Yes — JPX Group site |
| `TOCOM` | Tokyo Commodity Exchange | exchange | active | Yes — JPX Group site (listed as a distinct link on JPX's own homepage; whether its derivatives book has since been operationally folded into `XOSE` needs one more check before finalizing granularity) |
| `JPNX` | Japannext PTS | pts | active | Yes — Japannext's own site (X-Market/U-Market segments, Night Market session, published FIX/ITCH/OUCH specs) |
| `ODX` | Osaka Digital Exchange | pts | active | Yes — ODX's own site, self-described as "the third PTS in Japan" for equities |
| `ODXST` | ODX START (security tokens) | pts | active | Yes — same ODX source; a genuinely different instrument class (security tokens, not equities), kept as its own `VENUE_ID` rather than folded into `ODX` |
| `CBOJ` | Cboe Japan (formerly Chi-X Japan) | pts | **discontinued — do not seed as active** | User-confirmed it stopped trading in Japan in 2025; independently corroborated by Cboe's own site listing no Japan/Asia region under "Global Markets" (checked this session). Not a primary-sourced citation (no dated closure announcement located directly) — corroborated from two independent angles, not zero-confidence, but not the same confidence tier as the six directly-confirmed-active venues above. If seeded at all, seed with `STATUS = 'discontinued'` for historical-data completeness only, never as a live target for new synthetic/ingested data. |

Regulator: `JURISDICTION_ID = 'JP'`, `REGULATOR_NAME = 'FSA/SESC'` (Financial Services Agency / Securities and Exchange Surveillance Commission — SESC referenced directly on JPX's own homepage as the destination for market-fairness complaints).

## US cross-verification (for the second `JURISDICTION_CONFIG`, agnosticism proof)

Re-confirmed live this session, not from memory: the CAT NMS Plan's own site (`catnmsplan.com`) is current and active (2026-dated updates), and its "About CAT" page states SEC Rule 613 (adopted 2012) requires "the national securities exchanges and national securities associations" — the SROs — to jointly build and maintain the Consolidated Audit Trail. Combined with the earlier-confirmed SEC SRO rulemaking page (24+ national securities exchanges + FINRA), this is the same one-regulator/many-venues shape as Japan, at larger scale — supports `US` as the second `JURISDICTION_CONFIG` for the market-agnosticism proof `architecture.md`'s build order requires, though the specific `VENUES` seed list for `US` (which of the 24+ exchanges to actually include) is not yet finalized and should get the same per-venue verification discipline applied to Japan rather than being bulk-copied from the SEC's list without re-checking which are still active.

## Change log

- v1 — initial contract, single `MARKET_ID` conflating regulator and venue.
- v2 — split `MARKET_ID` into `JURISDICTION_ID` (regulator) and `VENUE_ID` (execution venue), after verifying Japan's real venue structure live.
- v3 (this version) — nine fixes from a structural review: `DETECTOR_CALIBRATION.PARAMS` for pattern-match detectors, `WASH_DETECTION_COVERAGE` to surface (not hide) wash-trading blind spots, `POSITIONS` derivation fixed to `TRADES`-only with `LOADED_AT` restatement handling, `TRADE_REFERENCE_PRICES` + two correctly-timed slippage metrics for best execution, `APPROVED_OBLIGATIONS` view making the governance gate structural, new `MARKET_DATA_INGEST` role, new `BENEFICIAL_OWNERS` reference table, `OBLIGATION_RULE_CHUNKS` junction table replacing a single FK, and defined `MATCH_STATUS` semantics. `CBOJ` reclassified from "unverified" to "confirmed discontinued" per user input + independent corroboration.
