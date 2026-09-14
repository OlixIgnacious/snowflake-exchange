# System &amp; flow diagrams

Companion to `architecture.md` and `docs/canonical_schema_contract.md` (v7) — the mechanism behind the data model, the milestoning guarantee, and how each role moves through the system. Diagrams are Mermaid, rendered natively by GitHub/most Markdown viewers; column-level detail and the full FIX-by-FIX rationale live in the two docs above, not here.

## 1. System architecture

One insert-only gate per write path into `VIGIL.CORE`; every read out is a view, never a base table, for anyone but `GOVERNANCE_WRITE` itself. `VIGIL.EVAL` has no arrow reaching it — isolation here means no grant statement exists, not a policy someone has to remember.

```mermaid
flowchart LR
    GOV[Governance Officer] -->|"GOVERNANCE_WRITE<br/>INSERT-only (Fix #12)"| CORE

    subgraph FEEDS["Venue & regulator feeds"]
        F1["XTKS · XOSE · TOCOM<br/>JPNX · ODX · ODXST<br/>CBOJ / CBOJBIDS (historical only,<br/>discontinued 2025-08-29)<br/>+ future jurisdictions (US, ...)"]
    end

    FEEDS -->|"adaptor job<br/>MARKET_DATA_INGEST · INSERT-only"| CORE["VIGIL.CORE<br/>JURISDICTIONS · VENUES · ORDERS · TRADES<br/>POSITIONS · OBLIGATION_MAP · RULE_CORPUS · AUDIT_LOG …<br/>every row: CREATED_AT/LOADED_AT/CREATED_BY/LOADED_BY<br/>never UPDATE / DELETE"]

    CORE -->|"views join<br/>DETECTOR_CALIBRATION"| VIEWS["Detector & semantic views<br/>WASH_DETECTION_COVERAGE<br/>EXECUTION_/ARRIVAL_SLIPPAGE<br/>APPROVED_OBLIGATIONS<br/>&lt;TABLE&gt;_CURRENT ×16"]

    VIEWS -->|"ANALYST_READ<br/>SELECT-only"| AGENT["Cortex Agent<br/>surveillance-query · rule-interpret<br/>assure-report · narrative-draft"]

    AGENT -->|"skill call"| USERS["Analyst · Governance Officer<br/>Reporting Officer · Investigator"]
    USERS -.->|"cited answer"| AGENT

    EVAL["VIGIL.EVAL<br/>INJECTED_CASES · EVAL_RESULTS<br/>zero grants — no functional role"]

    classDef isolated stroke-dasharray: 4 3;
    class EVAL isolated;
```

## 2. Data model

Two chains share `JURISDICTION_ID`: the market-data chain (who traded what, where) and the governance chain (what obligation applies, backed by which rule text). `POSITIONS` only ever derives from `TRADES` — the arrow from `ORDERS` a v2 draft once drew was a real diagram bug (Fix #4), not a simplification.

```mermaid
flowchart TD
    JUR[JURISDICTIONS] -->|1:N| VEN[VENUES<br/>event-sourced STATUS, Fix #10]
    BO[BENEFICIAL_OWNERS<br/>not = a participant] --> MP[MARKET_PARTICIPANTS]
    MP --> ORD[ORDERS<br/>event-sourced, Fix #16<br/>PK: id, VENUE_ID, EVENT_TS]
    INS[INSTRUMENTS<br/>scoped by jurisdiction] -.->|scopes| ORD
    VEN -.->|scopes| ORD
    ORD -.->|"ORDER_ID (nullable)"| TRD[TRADES<br/>immutable print<br/>sole source for POSITIONS<br/>MATCHING_MECHANISM, Fix #20]
    TRD --> POS[POSITIONS<br/>no VENUE_ID — cross-venue total<br/>accumulates, never ORDERS]
    TRD --> TXR[TRANSACTION_REPORTS<br/>milestoned, Fix #14<br/>MATCH_STATUS enum]
    TRD --> TRP[TRADE_REFERENCE_PRICES<br/>backfill = new LOADED_AT row]
    TRD -.->|bust / amend| TRC[TRADE_CORRECTIONS<br/>Fix #15 — never mutates the print]

    RC[RULE_CORPUS<br/>amendment = new LOADED_AT row, Fix #17] --> ORC[OBLIGATION_RULE_CHUNKS<br/>0..N per obligation<br/>IS_ACTIVE tombstone, Fix #13]
    OM[OBLIGATION_MAP<br/>proposed → approved = new row, Fix #12] --> ORC
    OM --> AO[APPROVED_OBLIGATIONS<br/>view — latest row per key<br/>WHERE approved]

    TXR --> RT["REPORT_TEMPLATES<br/>what the regulator requires, Fix #21<br/>STATUS: proposed/mapped/gap, Fix #27<br/>field-level, milestoned, citation-backed"]
    RT --> RTC[REPORT_TEMPLATE_RULE_CHUNKS<br/>mirrors OBLIGATION_RULE_CHUNKS]
    RC --> RTC
```

A required field with no current source is `STATUS = 'gap'` — a deliberate, non-blocking state (Fix #28), not an error or a silent omission. `REPORT_TEMPLATE_COVERAGE` surfaces which fields are `gap` per (`JURISDICTION_ID`, `REPORT_TYPE`), the same "surfaced, not hidden" role `WASH_DETECTION_COVERAGE` plays for wash trading.

Every box above is milestoned identically (`CREATED_AT`/`CREATED_BY`/`LOADED_AT`/`LOADED_BY`, latest-row `_CURRENT` view) — that fact is stated once here rather than sixteen times; the labels called out per box are the ways each table's write pattern differs from the uniform rule.

## 3. The milestoning guarantee

The mechanism, traced through one real row: the `VENUES` row for `CBOJ` (Cboe Japan) going from active to discontinued. Three physical rows exist for the same `VENUE_ID`; none was ever touched after it was written.

```mermaid
flowchart TD
    R1["Row 1 — as first loaded<br/>VENUE_ID = CBOJ, STATUS = active<br/>CREATED_AT = 2019-04-01T00:00:00<br/>LOADED_AT = 2019-04-01T00:00:00"]
    R2["Row 2 — e.g. OPERATOR_NAME corrected<br/>VENUE_ID = CBOJ, STATUS = active<br/>CREATED_AT = 2019-04-01T00:00:00<br/>LOADED_AT = 2024-11-02T00:00:00"]
    R3["Row 3 — latest<br/>VENUE_ID = CBOJ, STATUS = discontinued<br/>DISCONTINUED_AT = 2025-08-29<br/>CREATED_AT = 2019-04-01T00:00:00<br/>LOADED_AT = 2025-07-24T00:00:00"]
    CUR([VENUES_CURRENT])

    R1 -->|"later correction → INSERT, same VENUE_ID"| R2
    R2 -->|"Cboe IR press release, 2025-07-23 → INSERT"| R3
    R3 -->|"ROW_NUMBER() OVER (ORDER BY LOADED_AT DESC) = 1"| CUR

    classDef current fill:#d7f0e6,stroke:#1f6f5c,stroke-width:2px;
    class R3,CUR current;
```

**Never granted, any role:** `UPDATE`, `DELETE`. **Always, every table:** `INSERT`. `CREATED_AT` stays fixed across every version of the row; `LOADED_AT` is what a reader orders by. No SQL grant script in `sql/rbac/` issues `UPDATE` or `DELETE` against any table — the guarantee is structural, not a review checklist.

**What this closes (v5, Fix #10–#19):** before this pass, only `POSITIONS` and `DETECTOR_CALIBRATION` actually worked this way. `OBLIGATION_MAP`'s proposed→approved flip was an explicit `UPDATE` grant; `ORDERS`' `MODIFIED_TS`/`CANCELLED_TS` assumed a mutation path no role was ever given. Both are fixed structurally, not documented as known gaps.

## 4. Ingestion &amp; detection

No detector reads a literal threshold; every one joins `DETECTOR_CALIBRATION`. Wash-trading findings never travel alone — `WASH_DETECTION_COVERAGE` rides along so "no wash trades found" and "no wash trades could be checked for" are never the same sentence.

```mermaid
sequenceDiagram
    participant Adaptor as Venue adaptor
    participant Core as VIGIL.CORE (ORDERS/TRADES/POSITIONS)
    participant Calib as DETECTOR_CALIBRATION
    participant Det as Detector view
    participant Analyst

    Adaptor->>Core: INSERT ORDERS event (new/modify/fill/cancel)
    Adaptor->>Core: INSERT TRADES row (immutable print)
    Core->>Core: accumulate → POSITIONS (new LOADED_AT row)
    Det-->>Core: reads ORDERS_CURRENT, TRADES
    Det->>Calib: join PARAMS / Z_THRESHOLD
    Calib-->>Det: no detector embeds a literal (Fix #2, #3)
    Det->>Det: compute finding + WASH_DETECTION_COVERAGE
    Analyst->>Det: SELECT (ANALYST_READ)
    Note over Analyst,Det: finding always paired with coverage %
```

The only mutable-looking step is the self-loop on `VIGIL.CORE` — and even that is an `INSERT` into `POSITIONS` with a later `LOADED_AT`, never an update to the prior snapshot.

## 5. Governance gate

The gate used to be a policy: "query `OBLIGATION_MAP` and refuse an unapproved row." It's now structural on two axes — `APPROVED_OBLIGATIONS` is the only lookup surface granted to a reader (Fix #6), and approval itself can no longer overwrite the record of when something was proposed (Fix #12).

```mermaid
sequenceDiagram
    participant Officer as Governance Officer
    participant OM as OBLIGATION_MAP
    participant Schema as INFORMATION_SCHEMA
    participant AO as APPROVED_OBLIGATIONS
    participant Agent

    Officer->>OM: INSERT (id=X, STATUS=proposed, LOADED_AT=t1)
    Officer->>Schema: validate SOURCE_TABLE / SOURCE_COLUMNS (Fix #9)
    Schema-->>Officer: pass
    Officer->>OM: INSERT (same id=X, STATUS=approved, LOADED_AT=t2)
    Note over OM: t1 row kept, intact — never an UPDATE
    OM->>AO: latest LOADED_AT per id, WHERE STATUS=approved
    Agent->>AO: SELECT (ANALYST_READ)
    Note over Agent,AO: proposed-only rows structurally invisible
```

The obligation's full history — proposed at `t1`, approved at `t2` — survives in two rows. A future `revoked` status is a third row and a third timestamp, not a lost second one.

## 6. User flows

Every flow below bottoms out in the same place: a `VIGIL.CORE` read through a view, or a governed write through an insert-only grant. What differs is which skill mediates it.

**Compliance Analyst — `surveillance-query`**

```mermaid
flowchart LR
    A1[Open surveillance-query] --> A2["Query TRADES / ORDERS_CURRENT /<br/>POSITIONS (ANALYST_READ)"]
    A2 --> A3["Review finding + coverage %<br/>(Fix #3, never hidden)"]
    A3 --> A4[Escalate to Investigator]
```

**Governance Officer — `rule-interpret`**

```mermaid
flowchart LR
    B1[New rule / circular arrives] --> B2["Gap analysis vs.<br/>OBLIGATION_MAP"]
    B2 --> B3["Propose: INSERT row,<br/>STATUS=proposed"]
    B3 --> B4["Validate + approve:<br/>INSERT new row, STATUS=approved"]
```

**Reporting Officer — `assure-report`**

```mermaid
flowchart LR
    C1[Draft transaction report] --> C2["Validate vs.<br/>APPROVED_OBLIGATIONS + rule text"]
    C2 -->|pass| C3[Submit]
    C2 -->|fail| C4[Fix gaps]
    C3 --> C5["TRANSACTION_REPORTS:<br/>new LOADED_AT row"]
    C4 --> C5
```

**Investigator — `narrative-draft`**

```mermaid
flowchart LR
    D1[Confirmed finding from analyst] --> D2["Trace lineage:<br/>ORDERS → TRADES → POSITIONS"]
    D2 --> D3[Draft root-cause narrative]
    D3 --> D4["AUDIT_LOG entry +<br/>OFFICER_SIGNOFF"]
```

## 7. RBAC matrix

Every non-empty cell below is `INSERT` or `SELECT`. There is no `UPDATE`/`DELETE` column because no role holds either, on anything, anywhere in `VIGIL.CORE`.

| Role | Market-data tables (`JURISDICTIONS`…`TRANSACTION_REPORTS`) | `OBLIGATION_MAP` (base) | `APPROVED_OBLIGATIONS` (view) | `OBLIGATION_RULE_CHUNKS` | `RULE_CORPUS` | `REPORT_TEMPLATES` / `_RULE_CHUNKS` | `REPORT_TEMPLATE_COVERAGE` (view) | `AUDIT_LOG` | `VIGIL.EVAL` |
|---|---|---|---|---|---|---|---|---|---|
| `ANALYST_READ` | SELECT | — | SELECT | — | SELECT | — | SELECT | — | — |
| `GOVERNANCE_WRITE` | — | INSERT + SELECT | inherits, not granted directly | INSERT | INSERT | INSERT | — | — | — |
| `AUDIT_INSERT` | — | — | — | — | — | — | — | INSERT (no SELECT) | — |
| `OFFICER_SIGNOFF` | `SP_RECORD_SIGNOFF` only — no direct table grants anywhere | | | | | | | | — |
| `MARKET_DATA_INGEST` | INSERT (incl. `ORDERS`, `TRADES`, `TRADE_CORRECTIONS`) | — | — | — | — | SELECT on `REPORT_TEMPLATES_CURRENT` only | — | — | — |

**No role, anywhere, is ever granted `UPDATE` or `DELETE`** (Fix #18) — `OBLIGATION_MAP`'s grant above was the last one that did, closed in the same v5 pass that added milestoning everywhere else. `MARKET_DATA_INGEST`'s `SELECT` on `REPORT_TEMPLATES_CURRENT` (Fix #21, v6) is its only read grant anywhere — needed to know which fields a report requires before generating one, still no base-table read access. A `STATUS = 'gap'` transition (Fix #27, v7) is written by `GOVERNANCE_WRITE`'s existing `INSERT`-only grant — no new role or grant needed for a required field to be honestly marked unsourceable. `ANALYST_READ`'s `SELECT` on `REPORT_TEMPLATE_COVERAGE` (Fix #28, v7) is the same grant category as its existing `WASH_DETECTION_COVERAGE` access — without it, `rule-interpret`/`assure-report` would have no role able to run the completeness-companion query.

## 8. Surveillance audit trail (built via Snowflake CoCo CLI, 2026-09-14)

Added after the diagrams above, as a demo-layer pipeline turning a detector view's live result into a persisted, queryable audit row — closing a gap that existed since Phase 2/6 (`AUDIT_LOG` was RBAC-governed and read by `narrative-draft`, but nothing had ever written a real row to it). Full build/review log in `TRACKER.md`/`NOTES.md`.

### 8.1 Current architecture

```mermaid
flowchart TD
    GEN["generator/generate.py<br/>synthetic Japan dataset"] -->|"MARKET_DATA_INGEST"| CORE[("VIGIL.CORE<br/>18 tables, milestoned, append-only")]

    CAL[("DETECTOR_CALIBRATION<br/>thresholds, never hardcoded")]

    subgraph DETECTORS["Detectors (Phase 3)"]
        WT["WASH_TRADING_CANDIDATES<br/>+ WASH_DETECTION_COVERAGE"]
        SP["SPOOFING_LAYERING_SIGNALS"]
        PL["POSITION_LIMIT_BREACHES"]
        RT["REPORTING_TIMELINESS_SIGNALS<br/>+ REPORT_TEMPLATE_COVERAGE"]
        BE["EXECUTION_SLIPPAGE / ARRIVAL_SLIPPAGE<br/>(0 rows -- no reference price data yet)"]
    end

    CORE --> WT & SP & PL & RT & BE
    CAL -.-> WT & SP & PL & RT

    subgraph AUDIT["Evidence trail -- built via CoCo CLI"]
        TASK["TASK_SURVEILLANCE_RUN_JP<br/>every 10 min"] -->|CALL| SPROC["SP_LOG_SURVEILLANCE_RUN<br/>EXECUTE AS OWNER"]
        SPROC -->|"INSERT, 1 row/detector"| ALOG[("AUDIT_LOG<br/>append-only")]
        ALOG --> SRL["SURVEILLANCE_RUN_LOG<br/>normalized FLAGGED_COUNT"]
    end

    WT & SP & PL & RT --> SPROC

    subgraph ASK["Ask in natural language"]
        SV1["SV_TRADE_SURVEILLANCE"]
        SV2["SV_OBLIGATIONS_REPORTING"]
        SV3["SV_SURVEILLANCE_AUDIT"]
        AGENT{{"VIGIL_SURVEILLANCE_AGENT<br/>claude-haiku-4-5, 3 tools"}}
        SV1 & SV2 & SV3 --> AGENT
    end

    CORE --> SV1 & SV2
    SRL --> SV3
    AGENT --> ANALYST(["Analyst / compliance user"])

    subgraph PRESENT["Presentation"]
        DASH["Streamlit -- VIGIL_DASHBOARD"]
        NB["Jupyter -- vigil_demo.ipynb"]
    end

    WT & SP & PL & RT & BE --> DASH & NB
```

### 8.2 Signal → evidence → documented finding: coverage vs. the gap

`SP_LOG_SURVEILLANCE_RUN` covers 3 of Vigil's 4 obligation types (trade surveillance, position limits, post-trade reporting timeliness) end to end. Best execution was never wired in, and even where the pipeline is complete, it stops at a queryable count -- it does not yet produce an actual filed report or assurance verdict as the "documented finding."

```mermaid
flowchart LR
    subgraph COVERED["Covered today"]
        direction TB
        S1["Signal:<br/>wash trading / spoofing /<br/>position limit / reporting"] --> E1["Evidence:<br/>AUDIT_LOG row via<br/>SP_LOG_SURVEILLANCE_RUN"]
        E1 --> Q1["Queryable:<br/>SURVEILLANCE_RUN_LOG<br/>SV_SURVEILLANCE_AUDIT -- agent"]
    end

    subgraph GAP["Not covered yet"]
        direction TB
        S2["Signal:<br/>best execution slippage"] -.->|"never logged to AUDIT_LOG"| E2["Evidence:<br/>none"]
        Q1 -.->|"answer is a number,<br/>not a filed document"| F["Documented finding:<br/>a real report/assurance artifact"]
    end

    style GAP stroke-dasharray: 5 5
```

### 8.3 Scheduled run -- exact call sequence

```mermaid
sequenceDiagram
    participant T as Snowflake Task<br/>(10 min cron)
    participant P as SP_LOG_SURVEILLANCE_RUN
    participant D as Detector views (x4)
    participant A as AUDIT_LOG
    participant S as SURVEILLANCE_RUN_LOG /<br/>SV_SURVEILLANCE_AUDIT
    participant AG as VIGIL_SURVEILLANCE_AGENT
    participant U as Analyst

    T->>P: CALL SP_LOG_SURVEILLANCE_RUN('JP')
    loop for each of 4 detectors
        P->>D: SELECT flagged rows WHERE JURISDICTION_ID='JP'
        D-->>P: counts (e.g. 28 non-exempt, 1 breach)
        P->>A: INSERT AUDIT_LOG row (JSON OUTPUT, shared snapshot_id)
    end
    Note over A: 4 new rows, append-only,<br/>never mutated

    U->>AG: "How many wash-trading findings today?"
    AG->>S: generated SQL (self-corrected once, live)
    S-->>AG: SUM(flagged_count) = 56
    AG-->>U: "56 wash-trading findings logged today"
```

## 9. The other three product skills

Section 8 only diagrams `surveillance-query`'s path (the one skill that fits the chat-agent tool-call model). The other three are directly-callable Python/CLI skills doing bespoke multi-step orchestration, per architecture.md's own decision rule -- none of them have ever been diagrammed until now.

### 9.1 `rule-interpret` — gap analysis

`find_gaps()` is the mechanism only -- `required_concepts` is caller-supplied (an analyst's or a future NLP step's reading of a rule chunk), not derived from real FSA/SESC text yet (architecture.md's "What's explicitly deferred").

```mermaid
flowchart TD
    RULE["New rule/circular text<br/>chunked into RULE_CORPUS"] --> EXTRACT["Analyst reads a rule chunk:<br/>which detector-backed concepts<br/>does it require? (required_concepts)"]
    APPROVED[("APPROVED_OBLIGATIONS<br/>view, never base OBLIGATION_MAP")] --> DIFF
    EXTRACT --> DIFF["find_gaps()<br/>required_concepts minus approved_detector_names"]
    DIFF --> GAPS{"Any gaps?"}
    GAPS -->|"yes, per gap"| PROPOSE["New 'proposed' OBLIGATION_MAP row<br/>citing this RULE_CHUNK_ID<br/>GOVERNANCE_WRITE, INSERT-only"]
    GAPS -->|"no"| DONE["Already covered -- no action"]
    PROPOSE --> REVIEW["Governance officer reviews"]
    REVIEW -->|"approved"| APPROVED2["New 'approved' row<br/>new INSERT, never UPDATE, Fix #12"]
    APPROVED2 -.-> APPROVED
```

### 9.2 `assure-report` — pre-submission assurance verdict

Wraps `ingest/report_adaptor.py` (section 10 below) rather than reimplementing it -- this skill's job is turning a `MappingResult` into a verdict an analyst can act on.

```mermaid
flowchart TD
    TR["TRANSACTION_REPORTS_CURRENT row<br/>a draft/pending report"] --> CANON["Canonical source row<br/>e.g. TRADES.PRICE, .VOLUME"]
    TPL["REPORT_TEMPLATES_CURRENT<br/>WHERE JURISDICTION_ID, REPORT_TYPE"] --> MAP
    CANON --> MAP["map_report()<br/>ingest/report_adaptor.py"]
    MAP --> RESULT["MappingResult:<br/>payload, fields_complete,<br/>gap_fields, unresolved_required_fields"]
    COV[("REPORT_TEMPLATE_COVERAGE<br/>PCT_REQUIRED_FIELDS_MAPPED")] --> VERDICT
    RESULT --> VERDICT["assure()<br/>skills/assure_report.py"]
    VERDICT --> OUT{"AssuranceVerdict"}
    OUT -->|"ready_to_submit = TRUE"| SUBMIT["render_payload() --<br/>REPORT_PAYLOAD_REF"]
    OUT -->|"gap / unresolved fields"| ANALYST2["Surfaced with exact reasons,<br/>never fabricated or hidden -- Fix #28/#29"]
```

### 9.3 `narrative-draft` — lineage & remediation narrative

A pure graph walk over caller-supplied `AUDIT_LOG` rows -- no query logic, no LLM fabrication. Every fact in the output traces to a row in the chain.

```mermaid
flowchart TD
    FINDING["AUDIT_LOG row --<br/>a detector finding / surveillance run"] --> WALK["build_lineage_chain()<br/>walks SIGNOFF_FOR_RUN_ID"]
    SIGNOFF["Later AUDIT_LOG row --<br/>a sign-off, SP_RECORD_SIGNOFF"] --> WALK
    WALK --> CHAIN["Chronological chain:<br/>finding -- cited rule chunks -- sign-off decisions"]
    CHAIN --> DRAFT["draft_narrative()<br/>plain-language render"]
    DRAFT --> OUT2["Every fact traceable to the chain --<br/>nothing invented"]
```

## 10. Report generation / adaptor (`ingest/report_adaptor.py`)

Python, not SQL -- architecture.md's build order explicitly separates this from the Semantic Views. `STATUS` on each `REPORT_TEMPLATES_CURRENT` field drives three different outcomes per field, not one blanket rule.

```mermaid
flowchart TD
    START["For each TemplateField in<br/>REPORT_TEMPLATES_CURRENT"] --> STATUS{"STATUS?"}
    STATUS -->|"gap"| GAPLIST["Add to gap_fields --<br/>surfaced, Fix #28, never fabricated<br/>or silently dropped"]
    STATUS -->|"proposed"| SKIP["Skip -- not ready to drive<br/>report generation yet"]
    STATUS -->|"mapped"| LOOKUP["raw_value = canonical_row[SOURCE_MAPPING]"]
    LOOKUP --> FORMAT["format_value() --<br/>ISO8601 / decimal(p) / passthrough"]
    FORMAT --> PAYLOAD["Add FIELD_NAME: formatted_value<br/>to payload"]
    PAYLOAD --> REQCHECK{"IS_REQUIRED and<br/>formatted is NULL?"}
    REQCHECK -->|"yes"| UNRESOLVED["Add to unresolved_required_fields"]
    REQCHECK -->|"no"| CONTINUE["Next field"]
    GAPLIST & SKIP & UNRESOLVED & CONTINUE --> COMPLETE["All fields processed"]
    COMPLETE --> FC["fields_complete =<br/>len(unresolved_required_fields) == 0<br/>gap fields never block this -- Fix #29"]
    FC --> RENDER["render_payload() --<br/>JSON placeholder format,<br/>real regulator format deferred"]
    RENDER --> STORE["Stored as<br/>TRANSACTION_REPORTS.REPORT_PAYLOAD_REF -- Fix #25"]
```

## 11. CoCo demo-video phase map

Maps the hackathon's four required phases onto what actually happened and which tool did it -- for structuring the recording, not a system diagram. Full detail in `TRACKER.md`/`NOTES.md`.

```mermaid
flowchart TD
    subgraph PLAN["1. Planning -- CoCo CLI, 2026-09-12"]
        direction TB
        P1["Reviewed Praman's plug_and_play_architecture.md,<br/>found faults, via CoCo"]
        P2["Pivoted: 'exchange regulatory reporting,<br/>not banking' -- Vigil's origin"]
        P3["Selected JPX/SEC, checked for<br/>multiple venues per region TSE/ODX/JPNX"]
        P1 --> P2 --> P3
    end

    subgraph DEV["2. Development"]
        direction TB
        D1["Claude Code: DDL, RBAC, detectors,<br/>generator, skills, Cortex Agent -- Phases 1-6"]
        D2["CoCo CLI: SP_LOG_SURVEILLANCE_RUN --<br/>RBAC violation caught and self-corrected"]
        D1 --> D2
    end

    subgraph EXEC["3. Execution"]
        direction TB
        E1["Claude Code: scripts/run_sql.py,<br/>synthetic data load, 3600+ orders"]
        E2["CoCo CLI: TASK_SURVEILLANCE_RUN_JP --<br/>created, resumed, EXECUTE TASK triggered live"]
        E1 --> E2
    end

    subgraph TEST["4. Testing & validation"]
        direction TB
        T1["Claude Code: pytest 29 tests,<br/>verify_rbac.py 27 checks,<br/>notebook executed against live data"]
        T2["CoCo CLI: RUN_ID uniqueness check,<br/>AUDIT_INSERT negative-SELECT proof,<br/>live NL question -- agent self-corrected SQL"]
        T1 --> T2
    end

    PLAN --> DEV --> EXEC --> TEST
```

Where to find the Planning-phase evidence for the recording: `~/.snowflake/cortex/history`, timestamped `2026-09-12`, in the sibling `Praman` repo directory (not this one) -- it predates this project's own git history entirely.
