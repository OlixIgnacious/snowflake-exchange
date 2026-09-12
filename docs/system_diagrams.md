# System &amp; flow diagrams

Companion to `architecture.md` and `docs/canonical_schema_contract.md` (v5) — the mechanism behind the data model, the milestoning guarantee, and how each role moves through the system. Diagrams are Mermaid, rendered natively by GitHub/most Markdown viewers; column-level detail and the full FIX-by-FIX rationale live in the two docs above, not here.

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
    ORD -.->|"ORDER_ID (nullable)"| TRD[TRADES<br/>immutable print<br/>sole source for POSITIONS]
    TRD --> POS[POSITIONS<br/>no VENUE_ID — cross-venue total<br/>accumulates, never ORDERS]
    TRD --> TXR[TRANSACTION_REPORTS<br/>milestoned, Fix #14<br/>MATCH_STATUS enum]
    TRD --> TRP[TRADE_REFERENCE_PRICES<br/>backfill = new LOADED_AT row]
    TRD -.->|bust / amend| TRC[TRADE_CORRECTIONS<br/>Fix #15 — never mutates the print]

    RC[RULE_CORPUS<br/>amendment = new LOADED_AT row, Fix #17] --> ORC[OBLIGATION_RULE_CHUNKS<br/>0..N per obligation<br/>IS_ACTIVE tombstone, Fix #13]
    OM[OBLIGATION_MAP<br/>proposed → approved = new row, Fix #12] --> ORC
    OM --> AO[APPROVED_OBLIGATIONS<br/>view — latest row per key<br/>WHERE approved]
```

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

| Role | Market-data tables (`JURISDICTIONS`…`TRANSACTION_REPORTS`) | `OBLIGATION_MAP` (base) | `APPROVED_OBLIGATIONS` (view) | `OBLIGATION_RULE_CHUNKS` | `RULE_CORPUS` | `AUDIT_LOG` | `VIGIL.EVAL` |
|---|---|---|---|---|---|---|---|
| `ANALYST_READ` | SELECT | — | SELECT | — | SELECT | — | — |
| `GOVERNANCE_WRITE` | — | INSERT + SELECT | inherits, not granted directly | INSERT | INSERT | — | — |
| `AUDIT_INSERT` | — | — | — | — | — | INSERT (no SELECT) | — |
| `OFFICER_SIGNOFF` | `SP_RECORD_SIGNOFF` only — no direct table grants anywhere | | | | | | — |
| `MARKET_DATA_INGEST` | INSERT (incl. `ORDERS`, `TRADES`, `TRADE_CORRECTIONS`) | — | — | — | — | — | — |

**No role, anywhere, is ever granted `UPDATE` or `DELETE`** (Fix #18) — `OBLIGATION_MAP`'s grant above was the last one that did, closed in the same v5 pass that added milestoning everywhere else.
