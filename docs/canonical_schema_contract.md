# Canonical schema contract — v1

Versioned reference for `VIGIL.CORE`'s tables, written **before** the DDL exists (per `architecture.md`'s market-agnostic design rule #4), not consolidated from scattered comments afterward. Any DDL change must be reflected here in the same change, not after the fact.

## Conventions

- Every table with market-specific meaning carries `MARKET_ID VARCHAR NOT NULL` — no default, no implicit single-market assumption.
- Every monetary column's table carries `CURRENCY VARCHAR(8) NOT NULL` — no default.
- Timestamps are `TIMESTAMP_NTZ`, dates are `DATE`. A market's local time zone is a property of `MARKET_ID`, resolved by the adaptor before load, not stored per-row.
- Primary/foreign key columns are `VARCHAR` (venue-assigned IDs are rarely numeric across markets) unless noted.
- `STATUS`/`FIELDS_COMPLETE`/boolean-flag columns are computed by a detector or procedure, never raw adaptor input, unless explicitly noted as adaptor-supplied.

## Tables

### `INSTRUMENTS`
| Column | Type | Notes |
|---|---|---|
| `INSTRUMENT_ID` | VARCHAR | Venue-local code. Not globally unique across markets — always paired with `MARKET_ID`. |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `ISIN` | VARCHAR | Nullable — not every market assigns one. |
| `INSTRUMENT_TYPE` | VARCHAR | e.g. equity, derivative, bond. |
| `TICK_SIZE` | NUMBER | |
| `LOT_SIZE` | NUMBER | |

PK: (`INSTRUMENT_ID`, `MARKET_ID`).

### `MARKET_PARTICIPANTS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `PARTICIPANT_TYPE` | VARCHAR | broker / proprietary / institutional / retail. |
| `BENEFICIAL_OWNER_ID` | VARCHAR | Nullable. The economic entity behind the participant — required for wash-trading detection across nominee/related accounts. |

PK: (`PARTICIPANT_ID`, `MARKET_ID`).

### `ORDERS`
| Column | Type | Notes |
|---|---|---|
| `ORDER_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | FK → `INSTRUMENTS` (+ `MARKET_ID`). |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | FK → `MARKET_PARTICIPANTS` (+ `MARKET_ID`). |
| `SIDE` | VARCHAR | buy / sell. |
| `ORDER_TYPE` | VARCHAR | limit / market / etc. |
| `SUBMITTED_TS` | TIMESTAMP_NTZ NOT NULL | |
| `MODIFIED_TS` | TIMESTAMP_NTZ | Nullable. |
| `CANCELLED_TS` | TIMESTAMP_NTZ | Nullable — populated only if the order was cancelled unfilled or partially filled. |
| `PRICE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `QUANTITY` | NUMBER | |
| `FILLED_QUANTITY` | NUMBER | 0 if never filled. |

PK: (`ORDER_ID`, `MARKET_ID`). Cancelled-unfilled rows are the raw material for spoofing/layering detection.

### `TRADES`
| Column | Type | Notes |
|---|---|---|
| `TRADE_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `ORDER_ID` | VARCHAR | Nullable — some venue feeds report executions without order linkage; documented as a real per-market adaptor variance, not assumed away. |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `EXECUTION_TIMESTAMP` | TIMESTAMP_NTZ NOT NULL | |
| `PRICE` | NUMBER NOT NULL | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |
| `VOLUME` | NUMBER NOT NULL | |
| `PARTICIPANT_ID` | VARCHAR NOT NULL | The reporting side. |
| `COUNTERPARTY_PARTICIPANT_ID` | VARCHAR | Nullable — not every venue discloses the other side. |

PK: (`TRADE_ID`, `MARKET_ID`).

### `POSITIONS`
| Column | Type | Notes |
|---|---|---|
| `PARTICIPANT_ID` | VARCHAR NOT NULL | |
| `INSTRUMENT_ID` | VARCHAR NOT NULL | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `AS_OF_DATE` | DATE NOT NULL | |
| `NET_QUANTITY` | NUMBER | |
| `MARKET_VALUE` | NUMBER | |
| `CURRENCY` | VARCHAR(8) NOT NULL | |

PK: (`PARTICIPANT_ID`, `INSTRUMENT_ID`, `MARKET_ID`, `AS_OF_DATE`). Semi-additive by `AS_OF_DATE` — never summed across dates, same convention as `Praman.POSITIONS`.

### `TRANSACTION_REPORTS`
| Column | Type | Notes |
|---|---|---|
| `REPORT_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `TRADE_ID` | VARCHAR NOT NULL | FK → `TRADES`. |
| `SUBMITTED_AT` | TIMESTAMP_NTZ | Nullable if not yet submitted. |
| `DEADLINE` | TIMESTAMP_NTZ NOT NULL | |
| `FIELDS_COMPLETE` | BOOLEAN | Computed by a detector, not adaptor input. |
| `MATCH_STATUS` | VARCHAR | Computed — matches the underlying `TRADE_ID`'s fields or not. |

PK: (`REPORT_ID`, `MARKET_ID`).

### `OBLIGATION_MAP`
| Column | Type | Notes |
|---|---|---|
| `OBLIGATION_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `OBLIGATION_DESCRIPTION` | VARCHAR | |
| `SOURCE_TABLE` | VARCHAR | |
| `SOURCE_COLUMNS` | VARCHAR | |
| `DETECTOR_NAME` | VARCHAR | |
| `RULE_CHUNK_ID` | VARCHAR | FK → `RULE_CORPUS`. |
| `STATUS` | VARCHAR NOT NULL DEFAULT 'proposed' | `proposed` / `approved` — flips only via a `GOVERNANCE_WRITE` session. |

PK: (`OBLIGATION_ID`, `MARKET_ID`).

### `RULE_CORPUS`
| Column | Type | Notes |
|---|---|---|
| `CHUNK_ID` | VARCHAR | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `DOC_TITLE` | VARCHAR | |
| `SECTION_REF` | VARCHAR | Citable unit (e.g. rule/paragraph number). |
| `CHUNK_TEXT` | VARCHAR | |
| `SOURCE_AUTHORITY` | VARCHAR NOT NULL | `original` / `translation`. Present from the first row loaded, not added later. |
| `ORIGINAL_LANGUAGE` | VARCHAR NOT NULL | |

PK: `CHUNK_ID`.

### `AUDIT_LOG`
Append-only by grant (no role ever gets `UPDATE`/`DELETE`). Same column shape as `Praman.AUDIT_LOG`: `RUN_ID`, `APP_USER`, `STAGE`, `PROMPT_OR_QUESTION`, `MODEL_VERSION`, `RETRIEVED_RULE_CHUNK_IDS`, `QUERY_SNAPSHOT_ID`, `OUTPUT`, `IS_EVAL`, `SIGNOFF_FOR_RUN_ID`, `HUMAN_DECISION`, `SIGNOFF_BY`, `SIGNOFF_AT`.

### `DETECTOR_CALIBRATION`
| Column | Type | Notes |
|---|---|---|
| `CALIBRATION_ID` | NUMBER AUTOINCREMENT | |
| `MARKET_ID` | VARCHAR NOT NULL | |
| `DETECTOR_NAME` | VARCHAR NOT NULL | |
| `DIMENSION_KEY` | VARCHAR | e.g. instrument, participant class. |
| `Z_THRESHOLD` | FLOAT | Statistical detectors only; NULL for rules-based ones (e.g. reporting timeliness). |
| `MIN_BASELINE_PERIODS` | NUMBER | |
| `IS_PROVISIONAL` | BOOLEAN NOT NULL | Cold-start default flag. |
| `EFFECTIVE_FROM` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATED_AT` | TIMESTAMP_NTZ NOT NULL | |
| `CALIBRATION_METHOD` | VARCHAR | `default-uncalibrated` / `percentile-historical` / `manual-override`. |

Append-only — a recalibration inserts a new row, never updates one.

## Change log

- v1 (this version) — initial contract, written before any DDL, per `architecture.md`'s day-one market-agnostic rules.
