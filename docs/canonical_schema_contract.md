# Canonical schema contract — v2

Versioned reference for `VIGIL.CORE`'s tables, written **before** the DDL exists (per `architecture.md`'s market-agnostic design rule #4), not consolidated from scattered comments afterward. Any DDL change must be reflected here in the same change, not after the fact.

**v2 supersedes v1's `MARKET_ID`.** Verifying the first real jurisdiction (Japan/JPX) against live sources surfaced that "market" was doing two separate jobs: which regulator's rules apply (one `OBLIGATION_MAP`/`RULE_CORPUS`/`DETECTOR_CALIBRATION` per regulator), and which venue a trade actually executed on (a regulator oversees *many* venues — this is the real, verified structure both Japan and the US have, and is literally what the US's Consolidated Audit Trail exists to unify across venues under one regulator). v1's single `MARKET_ID` conflated these. v2 splits them:

- **`JURISDICTION_ID`** — the regulator. Owns `OBLIGATION_MAP`, `RULE_CORPUS`, `DETECTOR_CALIBRATION` — obligations don't vary per venue, they're set once per regulator.
- **`VENUE_ID`** — the specific exchange/PTS/OTC facility a trade executed on or a report was submitted to. New `VENUES` reference table, FK'd from `ORDERS`/`TRADES`/`TRANSACTION_REPORTS`.
- **`POSITIONS` deliberately has no `VENUE_ID`** — a participant's position/exposure-limit exposure is a total across venues, not per-venue; adding venue there would be wrong, not just unnecessary.

## Conventions

- Every jurisdiction-scoped table carries `JURISDICTION_ID VARCHAR NOT NULL` — no default, no implicit single-jurisdiction assumption.
- Every venue-scoped table (execution/reporting events, not obligations) carries `VENUE_ID VARCHAR NOT NULL`, FK → `VENUES`.
- Every monetary column's table carries `CURRENCY VARCHAR(8) NOT NULL` — no default.
- Timestamps are `TIMESTAMP_NTZ`, dates are `DATE`. A venue's local time zone is a property of `VENUES`, resolved by the adaptor before load, not stored per-row.
- Primary/foreign key columns are `VARCHAR` (venue-assigned IDs are rarely numeric across markets) unless noted.
- `STATUS`/`FIELDS_COMPLETE`/boolean-flag columns are computed by a detector or procedure, never raw adaptor input, unless explicitly noted as adaptor-supplied.

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
| `VENUE_ID` | VARCHAR | e.g. `XTKS` (TSE), `XOSE` (Osaka Exchange), `TOCOM`, `JPNX` (Japannext PTS), `ODX`, `CBOJ` (Cboe Japan). |
| `JURISDICTION_ID` | VARCHAR NOT NULL | FK → `JURISDICTIONS`. |
| `VENUE_NAME` | VARCHAR | |
| `VENUE_TYPE` | VARCHAR | `exchange` / `pts` / `otc_facility`. |
| `OPERATOR_NAME` | VARCHAR | |

PK: `VENUE_ID`. A jurisdiction has many venues (verified for Japan: 3 JPX Group exchanges + at least 2 PTS operators outside the group) — this table's whole reason to exist.

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
| `BENEFICIAL_OWNER_ID` | VARCHAR | Nullable. The economic entity behind the participant — required for wash-trading detection across nominee/related accounts. |

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

PK: (`ORDER_ID`, `VENUE_ID`). Cancelled-unfilled rows are the raw material for spoofing/layering detection. Spoofing/layering baselines (Fix per `architecture.md`) partition by `VENUE_ID`, not just participant — a cancel-heavy pattern spread across venues to stay under one venue's threshold is itself a detection case, not something to average away.

### `TRADES`
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `VENUE_ID` | VARCHAR NOT NULL | FK → `VENUES`. Where the trade printed. |
| `ORDER_ID` | VARCHAR | Nullable — some venue feeds report executions without order linkage; documented as a real per-venue adaptor variance, not assumed away. |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `EXECUTION_TIMESTAMP` | TIMESTAMP_NTZ NOT NULL | |
| `PRICE` | NUMBER NOT NULL | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `VOLUME` | NUMBER NOT NULL | |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | The reporting side. |
| `COUNTERPARTY_PARTICIPANT_ID` | VARCHAR | Nullable — not every venue discloses the other side. |

PK: (`TRADE_ID`, `VENUE_ID`). Wash-trading and best-execution detectors need `VENUE_ID` explicitly, since the same instrument's reference price can differ by venue at the same instant (Japannext's own Night Market session is a concrete case: no continuous cross-venue reference price exists at all hours).

### `POSITIONS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR NOT NULL | |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | |
| `AS_OF_DATE` | DATE NOT NULL | |
| `NET_QUANTITY` | NUMBER | |
| `MARKET_VALUE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |

PK: (`PARTICIPANT_ID`, `INSTRUMENT_ID`, `JURISDICTION_ID`, `AS_OF_DATE`). **No `VENUE_ID`** — deliberately: a concentration/exposure limit applies to a participant's total holding in an instrument, aggregated across every venue they traded it on, not a per-venue figure. Semi-additive by `AS_OF_DATE` — never summed across dates, same convention as `Praman.POSITIONS`.

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
| `MATCH_STATUS` | VARCHAR | Computed — matches the underlying `TRADE_ID`'s fields or not. |

PK: (`REPORT_ID`, `JURISDICTION_ID`).

### `OBLIGATION_MAP`
| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR | |
| `JURISDICTION_ID` | VARCHAR NOT NULL | Obligations are regulator-level, not per-venue — this is the whole point of the `JURISDICTION_ID`/`VENUE_ID` split. |
| `OBLIGATION_DESCRIPTION` | VARCHAR | |
| `SOURCE_TABLE` | VARCHAR | |
| `SOURCE_COLUMNS` | VARCHAR | |
| `DETECTOR_NAME` | VARCHAR | |
| `RULE_CHUNK_ID` | VARCHAR | FK → `RULE_CORPUS`. |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'proposed' | `proposed` / `approved` — flips only via a `GOVERNANCE_WRITE` session. |

PK: (`OBLIGATION_ID`, `JURISDICTION_ID`).

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
| `Z_THRESHOLD` | FLOAT | Statistical detectors only; NULL for rules-based ones (e.g. reporting timeliness). |
| `MIN_BASELINE_PERIODS` | NUMBER | |
| `IS_PROVISIONAL` | BOOLEAN NOT NULL | Cold-start default flag. |
| `EFFECTIVE_FROM` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATED_AT` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATION_METHOD` | VARCHAR | `default-uncalibrated` / `percentile-historical` / `manual-override`. |

Append-only — a recalibration inserts a new row, never updates one.

## First jurisdiction: Japan (JP) — verified venue list to seed `VENUES`

Verified live against each operator's own site before writing this contract, not assumed:

| `VENUE_ID` (proposed) | Name | Type | Confirmed |
|---|---|---|---|
| `XTKS` | Tokyo Stock Exchange | exchange | Yes — JPX Group site |
| `XOSE` | Osaka Exchange | exchange | Yes — JPX Group site |
| `TOCOM` | Tokyo Commodity Exchange | exchange | Yes — JPX Group site (listed as a distinct link on JPX's own homepage; whether its derivatives book has since been operationally folded into `XOSE` needs one more check before finalizing granularity) |
| `JPNX` | Japannext PTS | pts | Yes — Japannext's own site (X-Market/U-Market segments, Night Market session, published FIX/ITCH/OUCH specs) |
| `ODX` | Osaka Digital Exchange | pts | Yes — ODX's own site, self-described as "the third PTS in Japan" for equities, plus a separate PTS ("START") for security tokens |
| `CBOJ` | Cboe Japan (formerly Chi-X Japan) | pts | **Not verified — do not seed.** Five separate live-fetch attempts this session (`cboe.co.jp`, `japan.cboe.com`, `chi-x.jp`, Cboe's own global-markets nav) either 404'd, failed, or redirected to Cboe's global site. Notably, Cboe's own "Global Markets" navigation lists only United States/Canada/Europe — no Japan/Asia region — which is a real negative signal, not just an absence of confirmation. ODX's "third PTS" framing may be counting a venue that's since been discontinued, absorbed, or rebranded. Do not seed this row until confirmed from a primary source; do not treat ODX's claim as sufficient corroboration on its own. |
| `ODXST` | ODX START (security tokens) | pts | Yes — same ODX source; a genuinely different instrument class (security tokens, not equities), worth keeping as its own `VENUE_ID` rather than folding into `ODX`. |

Regulator: `JURISDICTION_ID = 'JP'`, `REGULATOR_NAME = 'FSA/SESC'` (Financial Services Agency / Securities and Exchange Surveillance Commission — SESC referenced directly on JPX's own homepage as the destination for market-fairness complaints).

## Change log

- v1 — initial contract, single `MARKET_ID` conflating regulator and venue.
- v2 (this version) — split `MARKET_ID` into `JURISDICTION_ID` (regulator, owns obligations/rules/calibration) and `VENUE_ID` (execution venue, new `VENUES` table), after verifying Japan's real venue structure live. `POSITIONS` explicitly has no `VENUE_ID`; `OBLIGATION_MAP`/`RULE_CORPUS`/`DETECTOR_CALIBRATION`'s primary key uses `JURISDICTION_ID`, not `VENUE_ID`.
