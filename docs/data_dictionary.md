# Vigil data dictionary

Every column of every object in `VIGIL.CORE`, pulled live from `INFORMATION_SCHEMA.COLUMNS` on
2026-09-15 (not retyped from the DDL files by hand -- this reflects what's actually deployed).
`architecture.md` is the design rationale (why the schema looks like this); this file is the
reference (what's actually in it, column by column). `docs/queries_by_workflow.md` covers how to
query it; this file covers what's there to query.

## Conventions that apply throughout

**Milestoning (every base table below unless noted).** Every base table carries `CREATED_AT` /
`CREATED_BY` / `LOADED_AT` / `LOADED_BY`. No functional role is ever granted `UPDATE`/`DELETE` on
any `VIGIL.CORE` table (architecture.md, "Milestoning rules"). A change is a **new row** with the
same natural key and a later `LOADED_AT`; `CREATED_AT`/`CREATED_BY` are carried forward unchanged
from the first version. A `<TABLE>_CURRENT` view exists for nearly every base table (not
separately documented below -- same columns, filtered to the latest `LOADED_AT` per natural key)
and is the normal query surface for "what's true right now."

**Logical FKs.** A column documented as "Logical FK -> X" is not a declared SQL foreign key --
the referenced table is itself milestoned, so a declarative FK would pin to one historical
version. These are enforced by convention and by the load/insert procedures, not by the database.

**Market-agnostic rule #1.** Columns marked "no default" never have a hardcoded jurisdiction,
currency, or market assumption baked in -- every row states its own `JURISDICTION_ID`/`CURRENCY`
explicitly.

**Detector views (section 6) are not milestoned.** They're `CREATE OR REPLACE VIEW`s computed
fresh from the base tables on every query -- there's nothing to version, since they hold no state
of their own.

---

## 1. Reference data

### JURISDICTIONS
*PK: (JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| JURISDICTION_ID | TEXT | NO | e.g. `JP`, `US`, `EU`. No default -- no implicit single-jurisdiction assumption. |
| REGULATOR_NAME | TEXT | YES | e.g. `FSA/SESC`, `SEC / FINRA / CFTC`, `ESMA`. |
| PRIMARY_LANGUAGE | TEXT | YES | Drives the *expected* `RULE_CORPUS.ORIGINAL_LANGUAGE` for that jurisdiction (not an override of the per-row field). |
| CREATED_AT / CREATED_BY / LOADED_AT / LOADED_BY | — | — | Milestoning columns. A regulator rename is a new row. |

Live content: `JP` (FSA/SESC, ja), `US` (SEC/FINRA/CFTC, en), `EU` (ESMA, en) -- see section 9.

### VENUES
*PK: (VENUE_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| VENUE_ID | TEXT | NO | e.g. `XTKS`, `XOSE`, `TOCOM`, `JPNX`, `ODX`, `CBOJ`, `CBOJBIDS`. |
| JURISDICTION_ID | TEXT | NO | Logical FK -> JURISDICTIONS. |
| VENUE_NAME | TEXT | YES | |
| VENUE_TYPE | TEXT | YES | `exchange` / `pts` / `otc_facility` / `block_trading`. |
| OPERATOR_NAME | TEXT | YES | |
| STATUS | TEXT | NO | `active` / `discontinued`. |
| ACTIVE_FROM | DATE | YES | Nullable when a venue's founding date isn't confirmed live -- never a guessed placeholder. |
| DISCONTINUED_AT | DATE | YES | NULL while active. No ORDERS/TRADES may be dated after this for the venue. |

### BENEFICIAL_OWNERS
*PK: (BENEFICIAL_OWNER_ID, JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| BENEFICIAL_OWNER_ID | TEXT | NO | Independent identifier space -- never assumed equal to a `PARTICIPANT_ID`. |
| JURISDICTION_ID | TEXT | NO | Logical FK -> JURISDICTIONS. |
| OWNER_NAME | TEXT | YES | |
| OWNER_TYPE | TEXT | YES | `individual` / `corporate` / `fund`, etc. |

### INSTRUMENTS
*PK: (INSTRUMENT_ID, JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| INSTRUMENT_ID | TEXT | NO | Issuer/venue-local code -- not globally unique across jurisdictions. |
| JURISDICTION_ID | TEXT | NO | The primary-listing jurisdiction (an instrument keeps one identity across multiple venues, e.g. a TSE-listed stock also trading on Japannext PTS). |
| ISIN | TEXT | YES | Nullable -- not every market assigns one. |
| INSTRUMENT_TYPE | TEXT | YES | e.g. `equity`, `derivative`, `bond`, `security token`. |
| TICK_SIZE / LOT_SIZE | NUMBER | YES | An exchange rule change (not a typo fix) is a new row. |

### MARKET_PARTICIPANTS
*PK: (PARTICIPANT_ID, JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| PARTICIPANT_ID | TEXT | NO | The trading account/entity. |
| JURISDICTION_ID | TEXT | NO | A participant registers per jurisdiction; may belong to multiple venues within it. |
| PARTICIPANT_TYPE | TEXT | YES | `broker` / `proprietary` / `institutional` / `retail`. |
| BENEFICIAL_OWNER_ID | TEXT | YES | Logical FK -> BENEFICIAL_OWNERS. Nullable when genuinely unknown -- deliberately **not** self-referencing `PARTICIPANT_ID`, so the account and the beneficial owner are always two distinct identifier spaces (this is what lets wash-trading detection catch the same owner trading through different accounts). |

---

## 2. Order & trade lifecycle

### ORDERS -- event-sourced, one row per lifecycle event
*PK: (ORDER_ID, VENUE_ID, EVENT_TS)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| ORDER_ID | TEXT | NO | Stable across every event for the same order. |
| JURISDICTION_ID / VENUE_ID / INSTRUMENT_ID / PARTICIPANT_ID | TEXT | NO | Logical FKs. |
| SIDE | TEXT | YES | `buy` / `sell`. |
| ORDER_TYPE | TEXT | YES | `limit` / `market` / etc. |
| EVENT_TYPE | TEXT | NO | `new` / `modify` / `partial_fill` / `fill` / `cancel` -- replaces separate submitted/modified/cancelled timestamp columns with one clean event stream. |
| EVENT_TS | TIMESTAMP_NTZ | NO | Timestamp of *this* event. The `new` event's `EVENT_TS` is the order's submission time -- this is "order time." No declared scale (Snowflake default, up to nanosecond); the synthetic generator currently only populates whole-second values (`generator/generate.py:_rand_datetime`), so no sub-second precision is actually exercised in the data today even though the schema allows it. |
| PRICE | NUMBER | YES | As of this event. |
| CURRENCY | TEXT | NO | No default. |
| QUANTITY | NUMBER | YES | As of this event -- a `modify` can change it. |
| FILLED_QUANTITY | NUMBER | YES | Cumulative-as-of-this-event, adaptor-supplied. |
| REGULATORY_ATTRIBUTES | VARIANT | YES | Catch-all for jurisdiction-specific, detector-irrelevant regulatory fields (e.g. an algo-trading flag) -- same pattern as `DETECTOR_CALIBRATION.PARAMS`, not a named column per jurisdiction. |
| CREATED_AT | TIMESTAMP_NTZ | NO | When the order was first created (the `new` event) -- carried forward unchanged on every later event row. |
| LOADED_AT | TIMESTAMP_NTZ | NO | When *this event row* was written to the warehouse -- distinct from `EVENT_TS`, since an adaptor can backfill/replay late. |

### TRADES -- one immutable row per execution ("transaction time")
*PK: (TRADE_ID, VENUE_ID)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| TRADE_ID | TEXT | NO | |
| JURISDICTION_ID / VENUE_ID / INSTRUMENT_ID | TEXT | NO | Logical FKs. |
| ORDER_ID | TEXT | YES | Nullable -- some venue feeds report executions with no order linkage (real adaptor variance). Feeds `WASH_DETECTION_COVERAGE` when null alongside a null `COUNTERPARTY_PARTICIPANT_ID`. |
| EXECUTION_TIMESTAMP | TIMESTAMP_NTZ | NO | The venue's own execution time -- this is "execution/transaction time," distinct from `LOADED_AT` (warehouse ingestion time) and from `ORDERS.EVENT_TS` (order submission time). Same precision caveat as `ORDERS.EVENT_TS` above. |
| PRICE / CURRENCY / VOLUME | NUMBER/TEXT | NO | |
| PARTICIPANT_ID | TEXT | NO | The reporting side. |
| COUNTERPARTY_PARTICIPANT_ID | TEXT | YES | Nullable -- not every venue discloses the other side. |
| MATCHING_MECHANISM | TEXT | NO | `continuous` / `cross` / `block` / `auction`. Which mechanisms are exempt from the wash-trading trigger (and under what condition) is read from `DETECTOR_CALIBRATION.PARAMS`, never hardcoded. |
| REGULATORY_ATTRIBUTES | VARIANT | YES | Same catch-all pattern as ORDERS -- this is where LEI/trading-capacity/short-sell-flag live today (not as named columns). |
| CREATED_AT | TIMESTAMP_NTZ | NO | Equal to `LOADED_AT` on every row -- a trade print never gets a second version (corrections go to `TRADE_CORRECTIONS` instead). |

### TRADE_CORRECTIONS
*PK: (TRADE_ID, VENUE_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| TRADE_ID / VENUE_ID | TEXT | NO | Logical FK -> TRADES. |
| CORRECTION_TYPE | TEXT | NO | `bust` / `amend`. |
| CORRECTED_FIELDS | VARIANT | YES | For `amend`, the corrected values; null/empty for `bust`. Each correction is its own immutable event row -- a second correction is a new row, not a version of the first. |

### TRADE_REFERENCE_PRICES -- drives best-execution slippage
*PK: (TRADE_ID, VENUE_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| TRADE_ID / VENUE_ID | TEXT | NO | |
| REFERENCE_PRICE_AT_EXECUTION | NUMBER | YES | Nullable -- populated only where a venue publishes an NBBO-equivalent; genuinely absent for others. Drives `EXECUTION_SLIPPAGE`. **This table is not populated by the synthetic generator at all** -- every `EXECUTION_SLIPPAGE`/`ARRIVAL_SLIPPAGE` query returns 0 rows honestly, not a bug (see docs/queries_by_workflow.md's "Known gaps"). |
| REFERENCE_PRICE_AT_ARRIVAL | NUMBER | YES | Drives `ARRIVAL_SLIPPAGE`, compared against the order's `new`-event `EVENT_TS`. |
| SOURCE | TEXT | YES | Which reference-price feed/adaptor populated the row. |

### POSITIONS -- daily snapshots, never derived from ORDERS
*PK: (PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| PARTICIPANT_ID / INSTRUMENT_ID / JURISDICTION_ID / AS_OF_DATE | — | NO | |
| NET_QUANTITY | NUMBER | YES | Cumulative signed sum of `TRADES.VOLUME` through `AS_OF_DATE`, roll-forward from the prior snapshot -- **never** derived from `ORDERS` (an order can be cancelled/rejected; only a trade changes a position). |
| MARKET_VALUE / CURRENCY | — | — | |

---

## 3. Regulatory reporting

### TRANSACTION_REPORTS -- one row per lifecycle event
*PK: (REPORT_ID, JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| REPORT_ID | TEXT | NO | |
| JURISDICTION_ID | TEXT | NO | |
| VENUE_ID | TEXT | YES | The reporting facility, when it differs from the trade's execution venue. |
| REPORT_TYPE | TEXT | NO | Logical FK -> REPORT_TEMPLATES -- which regulator-defined format this must conform to. |
| REPORT_SCOPE | TEXT | NO | `trade` / `periodic` / `nil` -- a periodic/nil filing is legitimate with no `TRADE_ID`. |
| TRADE_ID | TEXT | YES | Required by convention (ingest-procedure-enforced, not a declared constraint) when `REPORT_SCOPE = trade`. |
| PERIOD_START / PERIOD_END | DATE | YES | Populated when `REPORT_SCOPE != trade`. |
| REPORT_STATUS | TEXT | NO | `new` / `amendment` / `cancellation` -- a regulator-facing submission action, distinct from an internal correction. |
| SUBMITTED_AT | TIMESTAMP_NTZ | YES | Null if not yet submitted. |
| DEADLINE | TIMESTAMP_NTZ | NO | The *raw*, un-adjusted submission deadline -- see `REPORTING_TIMELINESS_SIGNALS.EFFECTIVE_DEADLINE` (section 6) for the business-day-corrected version actually used to judge lateness. |
| DEFERRED_PUBLICATION_UNTIL | TIMESTAMP_NTZ | YES | A permitted delayed public-disclosure window for a large-in-scale block trade -- a different clock from `DEADLINE` (submission vs. public disclosure). |
| FIELDS_COMPLETE | BOOLEAN | YES | Computed against `REPORT_TEMPLATES_CURRENT WHERE IS_REQUIRED AND STATUS='mapped'` -- never measured against a gap field it could never satisfy. |
| MATCH_STATUS | TEXT | YES | `full_match` / `partial_match` / `no_match` against the underlying trade's instrument (exact), price (exact), volume (exact), execution timestamp (documented tolerance). NULL when not a trade report. |
| REPORT_PAYLOAD_REF | TEXT | YES | Pointer to the generated submission artifact; nullable until generated. |

### REPORT_TEMPLATES -- the regulator's own required field list
*PK: (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| JURISDICTION_ID / REPORT_TYPE / FIELD_NAME | TEXT | NO | `FIELD_NAME` is the regulator's own field/tag name (e.g. `Trading_Capacity`) -- not a `VIGIL.CORE` column name. |
| FIELD_ORDER | NUMBER | YES | Position for order-sensitive formats; NULL for tag-based (XML/JSON). |
| STATUS | TEXT | NO | `proposed` (found by gap analysis) / `mapped` (`SOURCE_MAPPING` resolves) / `gap` (a required field with no current data source -- deliberate, non-blocking, surfaced not hidden). |
| SOURCE_MAPPING | TEXT | YES | Free text (e.g. `TRADES.PRICE`) -- unenforceable as a real FK against a dynamic column reference; validated against `INFORMATION_SCHEMA` before `STATUS` can become `mapped`. |
| FIELD_FORMAT | TEXT | YES | e.g. `ISO8601`, `ISIN`, `decimal(18,4)`. |
| IS_REQUIRED | BOOLEAN | NO | Drives `TRANSACTION_REPORTS.FIELDS_COMPLETE` and `REPORT_TEMPLATE_COVERAGE`. |

Live content (JP, `transaction_report`): `Instrument_ID`, `Price`, `Volume` (mapped), `Trading_Capacity` (gap -- no current data source; see the `data_dictionary` comparison discussion in NOTES.md on why this couldn't yet be traced to a specific rule citation).

### REPORT_TEMPLATE_RULE_CHUNKS
*PK: (JURISDICTION_ID, REPORT_TYPE, FIELD_NAME, RULE_CHUNK_ID, LOADED_AT)*

Mirrors `OBLIGATION_RULE_CHUNKS` (section 4) exactly -- links a required report field to the
`RULE_CORPUS` chunk that requires it, with the same `IS_ACTIVE` tombstone pattern. **Currently
empty for all three jurisdictions** -- see section 9.

### REPORT_TEMPLATE_COVERAGE *(view)*
One row per `(JURISDICTION_ID, REPORT_TYPE)`: `REQUIRED_FIELD_COUNT`, `MAPPED_REQUIRED_FIELD_COUNT`,
`PCT_REQUIRED_FIELDS_MAPPED`, `GAP_FIELD_NAMES` (array). The completeness companion query --
"never look at `FIELDS_COMPLETE` on one report without also checking this."

---

## 4. Governance: rule corpus & obligations

### RULE_CORPUS -- real regulatory text, one row per amendment
*PK: (CHUNK_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| CHUNK_ID | TEXT | NO | e.g. `JP-FIEA-159-1-I`, `US-EXCHACT-9A1`, `EU-MAR-12-2C`. |
| JURISDICTION_ID | TEXT | NO | |
| DOC_TITLE / SECTION_REF | TEXT | YES | The citable document + paragraph/article. |
| CHUNK_TEXT | TEXT | YES | The actual excerpt, verified verbatim against the source document (see `docs/sources/`). |
| SOURCE_AUTHORITY | TEXT | NO | `original` / `translation` -- present from the first row loaded (never added later). `translation` for Japan (FIEA/OSE text is legally Japanese-original); `original` for US/EU (both authored/adopted in English as authentic text). |
| ORIGINAL_LANGUAGE | TEXT | NO | `ja` for Japan, `en` for US/EU. |

Indexed by `RULE_CORPUS_SEARCH`, a Cortex Search service (section 10).

### OBLIGATION_MAP -- proposed/approved obligation-to-detector mappings
*PK: (OBLIGATION_ID, JURISDICTION_ID, LOADED_AT)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| OBLIGATION_ID | TEXT | NO | e.g. `JP-WASH-001`, `US-BESTEX-001`, `EU-SPOOF-001`. |
| JURISDICTION_ID | TEXT | NO | Obligations are regulator-level, not per-venue. |
| OBLIGATION_DESCRIPTION | TEXT | YES | Plain-language statement of the requirement, with its rule citation. |
| SOURCE_TABLE / SOURCE_COLUMNS | TEXT | YES | Free text (unenforceable as a real FK against a dynamic table/column name) -- validated against live `INFORMATION_SCHEMA` by `SP_APPROVE_OBLIGATION` before approval. |
| DETECTOR_NAME | TEXT | YES | `wash_trading` / `spoofing_layering` / `position_limit` / `reporting_timeliness` / `best_execution`. |
| STATUS | TEXT | NO | `proposed` / `approved`. The flip is a **new row**, same `OBLIGATION_ID`, later `LOADED_AT` -- never an `UPDATE`, and only ever inserted by `SP_APPROVE_OBLIGATION` after its validation passes. |

### OBLIGATION_RULE_CHUNKS
*PK: (OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID, LOADED_AT)*

Links an obligation to the `RULE_CORPUS` chunk(s) that back it. `IS_ACTIVE` tombstone pattern --
a wrong association is corrected by a new row, never a `DELETE`.

### APPROVED_OBLIGATIONS *(view)*
The **only** obligation-lookup surface `ANALYST_READ`/the agent are granted -- latest `LOADED_AT`
row per obligation, filtered `WHERE STATUS = 'approved'`. An unapproved mapping is structurally
invisible through this view, not merely supposed to be filtered out by every consumer.

---

## 5. Detector calibration

### DETECTOR_CALIBRATION
*PK: (CALIBRATION_ID)*

| Column | Type | Null? | Notes |
|---|---|---|---|
| CALIBRATION_ID | NUMBER | NO | Surrogate key. |
| JURISDICTION_ID | TEXT | NO | No default. |
| VENUE_ID | TEXT | YES | NULL means "applies across all venues in this jurisdiction." |
| DETECTOR_NAME | TEXT | NO | Only `wash_trading`/`spoofing_layering`/`position_limit` are calibrated today -- `reporting_timeliness`/`best_execution` have no tunable thresholds. |
| DIMENSION_KEY | TEXT | YES | e.g. instrument, participant class. |
| Z_THRESHOLD / MIN_BASELINE_PERIODS | FLOAT/NUMBER | YES | Statistical detectors only. |
| PARAMS | VARIANT | YES | Arbitrary detector-specific tunables (e.g. wash trading's `{"time_window_seconds": 30, "price_tolerance_pct": 0.001}` and its `MATCHING_MECHANISM` exemption list). **Every detector reads its thresholds from here -- none embeds a literal.** |
| IS_PROVISIONAL | BOOLEAN | NO | Cold-start flag for insufficient history. |
| CALIBRATION_METHOD | TEXT | YES | `default-uncalibrated` / `percentile-historical` / `manual-override`. |

---

## 6. Detector views (computed, read-only, not milestoned)

These recompute from base tables on every query -- nothing here is stored state.

### WASH_TRADING_CANDIDATES
`TRADE_ID_1, TRADE_ID_2, JURISDICTION_ID, VENUE_ID, INSTRUMENT_ID, PARTICIPANT_ID_1,
PARTICIPANT_ID_2, BENEFICIAL_OWNER_ID, EXECUTION_TIMESTAMP_1, EXECUTION_TIMESTAMP_2, PRICE_1,
PRICE_2, MATCHING_MECHANISM, CANDIDATE_TYPE, CALIBRATION_PARAMS, IS_TRIGGER_EXEMPT`

### WASH_DETECTION_COVERAGE -- never look at candidates without this
`JURISDICTION_ID, VENUE_ID, TRADE_DATE, TOTAL_TRADES, RESOLVABLE_TRADES,
PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY` — `TOTAL_TRADES` is a real trade count from `TRADES`
directly (not a detector output); this is what "no wash trades *found*" vs. "no wash trades could
*be checked for*" actually rests on. Also the basis for `SV_DETECTOR_FINDINGS.COV.TOTAL_TRADE_VOLUME`
(section 8) -- the jurisdiction-level version of the same distinction.

### SPOOFING_LAYERING_SIGNALS
`PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, JURISDICTION_ID, EVENT_DATE, SUBMITTED_VOLUME,
CANCELLED_UNFILLED_VOLUME, CANCEL_RATIO, BASELINE_MEAN, BASELINE_STDDEV, BASELINE_PERIODS,
Z_THRESHOLD, MIN_BASELINE_PERIODS, IS_PROVISIONAL, CANCEL_RATIO_ZSCORE, IS_FLAGGED` — flags a
change in a participant's *own* behavior against its own trailing baseline, not a uniformly high
cancel ratio from day one.

### POSITION_LIMIT_BREACHES
`PARTICIPANT_ID, INSTRUMENT_ID, JURISDICTION_ID, AS_OF_DATE, NET_QUANTITY, MARKET_VALUE, CURRENCY,
LIMIT_QUANTITY, PCT_OF_LIMIT, IS_BREACH`

### REPORTING_TIMELINESS_SIGNALS
`REPORT_ID, JURISDICTION_ID, VENUE_ID, REPORT_TYPE, REPORT_SCOPE, TRADE_ID, REPORT_STATUS,
SUBMITTED_AT, DEADLINE, EFFECTIVE_DEADLINE, FIELDS_COMPLETE, MATCH_STATUS,
DEFERRED_PUBLICATION_UNTIL, IS_OVERDUE_UNSUBMITTED, IS_LATE_SUBMISSION, IS_INCOMPLETE,
IS_MISMATCHED` — `EFFECTIVE_DEADLINE` is `DEADLINE` moved to the next business day when it falls
on a weekend (fixed 2026-09-14 after a real bug: the uncorrected formula put 27% of deadlines on a
Saturday/Sunday, producing 23 false-positive "late" findings out of 82). This is the column to
query directly to confirm weekend-handling behavior -- not something to infer from rule text.

### EXECUTION_SLIPPAGE / ARRIVAL_SLIPPAGE
`TRADE_ID, VENUE_ID, JURISDICTION_ID, INSTRUMENT_ID, EXECUTION_TIMESTAMP` (or
`ORDER_SUBMITTED_TS`), `PRICE, CURRENCY, REFERENCE_PRICE_AT_EXECUTION` (or `_AT_ARRIVAL`),
`*_SLIPPAGE_ABS, *_SLIPPAGE_PCT`. **0 rows for every jurisdiction today** -- `TRADE_REFERENCE_PRICES`
isn't populated by the synthetic generator.

---

## 7. Audit trail

### AUDIT_LOG -- the append-only backbone; every other audit view reads from this
*PK: (RUN_ID)*

| Column | Type | Notes |
|---|---|---|
| RUN_ID | TEXT | |
| APP_USER | TEXT | Whose action is being logged (can differ from `LOADED_BY`, the granted identity that wrote the row). |
| STAGE | TEXT | `surveillance_run` / `documented_finding` / a sign-off stage, etc. -- which downstream view (`SURVEILLANCE_RUN_LOG`/`DOCUMENTED_FINDINGS_LOG`) reads this row. |
| PROMPT_OR_QUESTION | TEXT | Overloaded by stage: the detector name for a surveillance run, the report ID for a documented finding. |
| RETRIEVED_RULE_CHUNK_IDS | ARRAY | Currently `CHUNK_ID` values only -- a flagged follow-up (not yet done) is to pin the exact `(CHUNK_ID, LOADED_AT)` cited, since `RULE_CORPUS` is itself milestoned. |
| OUTPUT | TEXT | JSON payload, shape depends on `STAGE` (see `SURVEILLANCE_RUN_LOG`/`DOCUMENTED_FINDINGS_LOG` below for how it's parsed). |
| SIGNOFF_FOR_RUN_ID / HUMAN_DECISION / SIGNOFF_BY / SIGNOFF_AT | — | Self-referencing sign-off decision for an earlier run. |

### SURVEILLANCE_RUN_LOG *(view over `AUDIT_LOG WHERE STAGE='surveillance_run'`)*
`RUN_ID, DETECTOR_NAME, JURISDICTION_ID, QUERY_SNAPSHOT_ID, CREATED_AT, APP_USER, FLAGGED_COUNT`
-- `JURISDICTION_ID` added 2026-09-15 (extracted from `OUTPUT`, which had carried it all along;
until then the view had no jurisdiction column at all, invisible only because every run to date
had been Japan-only). `FLAGGED_COUNT`'s meaning is `DETECTOR_NAME`-dependent -- see the view's own
header comment in `sql/detectors/07_surveillance_audit_log.sql` for the exact mapping per
detector, including `best_execution`'s different semantics (a coverage gap, not a breach count).

### DOCUMENTED_FINDINGS_LOG *(view over `AUDIT_LOG WHERE STAGE='documented_finding'`)*
`RUN_ID, REPORT_ID, CREATED_AT, APP_USER, READY_TO_SUBMIT, FIELDS_COMPLETE,
UNRESOLVED_REQUIRED_FIELDS, GAP_FIELDS, REASONS` -- the actual per-report assurance verdict
(`skills/assure_report.py` via `scripts/generate_documented_findings.py`), distinct from
`SURVEILLANCE_RUN_LOG`'s aggregate count: this is the finding itself, not evidence of one.

---

## 8. Semantic Views (Cortex Agent-facing)

Four Semantic Views, each backing one `cortex_analyst_text_to_sql` agent tool (section 10).
None declare cross-table `RELATIONSHIPS` unless noted -- most of these tables are genuinely
independent at the grain they're queried, a real modeling constraint documented in each file's
own header, not an oversight.

- **SV_TRADE_SURVEILLANCE** -- 1 table (TRADES). Raw trade facts only: volume/count/price sliced
  by date, matching mechanism, participant/instrument/venue type. No findings.
- **SV_OBLIGATIONS_REPORTING** -- 4 independent tables: `OBL` (APPROVED_OBLIGATIONS), `RPT`
  (TRANSACTION_REPORTS_CURRENT), `TMPL` (REPORT_TEMPLATES_CURRENT), `DFL`
  (DOCUMENTED_FINDINGS_LOG, added 2026-09-15). `RPT.LATE_COUNT` duplicates the business-day
  `EFFECTIVE_DEADLINE` CASE expression from `REPORTING_TIMELINESS_SIGNALS` (a Semantic View metric
  can't reference another table's computed column) -- if the formula changes, both places need it.
- **SV_SURVEILLANCE_AUDIT** -- 1 table (SURVEILLANCE_RUN_LOG). `RUN.LAST_RUN_AT` metric exists
  specifically so a same-day count is never presented as final ("as of `LAST_RUN_AT`", not "the
  total").
- **SV_DETECTOR_FINDINGS** -- 7 independent tables: `WASH`, `SPOOF`, `POSLIM`, `RPTSIG`
  (REPORTING_TIMELINESS_SIGNALS, exposing `SUBMITTED_AT`/`DEADLINE`/`EFFECTIVE_DEADLINE` directly
  -- added 2026-09-15 so weekend-adjustment behavior is queryable, not something to re-derive from
  rule text), `EXECSLIP`, `ARRSLIP`, and `COV` (WASH_DETECTION_COVERAGE, added 2026-09-15
  specifically so "does this jurisdiction have any trade data at all" is answerable from the same
  tool call as any other detector-findings question, via `COV.TOTAL_TRADE_VOLUME`).

---

## 9. Live governance content (as of 2026-09-15)

15 real regulatory citations, 5 detector families x 3 jurisdictions, each proposed then approved
through `SP_APPROVE_OBLIGATION`'s live `INFORMATION_SCHEMA` validation:

| Detector | JP citation | US citation | EU citation |
|---|---|---|---|
| wash_trading | FIEA Art. 159(1)(i) | Exchange Act Sec 9(a)(1) | MAR Art. 12(1)(a) + Annex I Sec. A(c) |
| spoofing_layering | FIEA Art. 159(2)(i) | CEA Sec 4c(a)(5)(C) | MAR Art. 12(2)(c) |
| position_limit | OSE Ops. Procedures Sec. IV | 17 CFR 150.2(a)-(b) | MiFID II Art. 57(1) |
| reporting_timeliness | OSE Ops. Procedures Sec. III(1-1) | CAT NMS Plan reporting hours | MiFIR Art. 26(1) |
| best_execution | FIEA Art. 40-2 | FINRA Rule 5310(a)(1) | MiFID II Art. 27(1) |

Source PDFs: `docs/sources/`. Full sourcing detail and honesty caveats (e.g. `JP-RPTTIME-001` is
OSE's *position-report* deadline, not a located citation of Japan's own transaction-report
deadline): NOTES.md, `sql/governance/01_*.sql` (JP) and `02_*.sql` (US/EU).

US/EU have **no trade data at all** -- no `JURISDICTION_CONFIG`, venues, participants, orders, or
trades. The obligations above are real and approved; querying any detector view or `TRADES`
directly `WHERE JURISDICTION_ID IN ('US','EU')` honestly returns 0 rows.

`REPORT_TEMPLATE_RULE_CHUNKS` is empty for all three jurisdictions -- no jurisdiction's
field-level report-format citation (e.g. Japan's `Trading_Capacity`) was traced to a specific
source with enough precision to cite honestly.

---

## 10. Cortex Search & Agent

### RULE_CORPUS_SEARCH *(Cortex Search service)*
Indexes `RULE_CORPUS_CURRENT.CHUNK_TEXT` (`snowflake-arctic-embed-m-v1.5` embeddings,
`TARGET_LAG='1 day'`), attributes `CHUNK_ID, JURISDICTION_ID, DOC_TITLE, SECTION_REF,
SOURCE_AUTHORITY, ORIGINAL_LANGUAGE`. Granted to `ANALYST_READ`.

### VIGIL_SURVEILLANCE_AGENT *(Cortex Agent, `cortex_project/vigil_agent.sql`)*
5 tools: `trade_surveillance`, `obligations_reporting`, `surveillance_audit`, `detector_findings`
(all `cortex_analyst_text_to_sql`, each backed by one Semantic View above), `rule_search`
(`cortex_search`, backed by `RULE_CORPUS_SEARCH`). Orchestration model `claude-haiku-4-5`.

---

## 11. RBAC roles (who can touch what)

| Role | Can write | Can read |
|---|---|---|
| `MARKET_DATA_INGEST` | Reference data + ORDERS/TRADES/TRADE_CORRECTIONS/TRANSACTION_REPORTS/POSITIONS/TRADE_REFERENCE_PRICES/JURISDICTIONS (INSERT only) | REPORT_TEMPLATES_CURRENT |
| `GOVERNANCE_WRITE` | OBLIGATION_MAP, OBLIGATION_RULE_CHUNKS, RULE_CORPUS, REPORT_TEMPLATES, REPORT_TEMPLATE_RULE_CHUNKS (INSERT only) | OBLIGATION_MAP (base table, to see `proposed` rows) |
| `AUDIT_INSERT` | AUDIT_LOG (INSERT only, no direct grant elsewhere -- all writes go through `EXECUTE AS OWNER` procedures) | — |
| `ANALYST_READ` | **nothing** -- no write access anywhere | Everything in sections 1-8 above, `RULE_CORPUS_SEARCH`, `VIGIL_SURVEILLANCE_AGENT` |
| `OFFICER_SIGNOFF` | Sign-off rows via `SP_RECORD_SIGNOFF` (`EXECUTE AS OWNER`) | — |

No functional role ever holds `UPDATE`/`DELETE` on anything in `VIGIL.CORE` -- a property of the
grant scripts themselves (`sql/rbac/`), not of who happens to be running them.
