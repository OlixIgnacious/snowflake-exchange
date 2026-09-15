# What Vigil can answer, by workflow

A reference for what's actually queryable today, organized by how you'd ask -- natural language
to the Cortex Agent, a Python skill/CLI call, or direct SQL against a detector view. Every
example below was run against live `VIGIL.CORE` data while writing this doc (2026-09-14, Japan
synthetic dataset) -- the numbers shown are real results, not illustrative guesses. Where
something is *not* answerable today, that's stated as plainly as what is -- this list is meant to
be trusted, not aspirational.

## 1. Ask `VIGIL_SURVEILLANCE_AGENT` (natural language)

Five tools as of 2026-09-15: four Semantic Views (`trade_surveillance`, `obligations_reporting`,
`surveillance_audit`, `detector_findings`) plus one Cortex Search service (`rule_search`), each
with a genuinely different scope. The agent picks the tool; you can also address a Semantic-View
tool's underlying view directly via `SELECT * FROM SEMANTIC_VIEW(...)`, or the search tool via
`SNOWFLAKE.CORTEX.SEARCH_PREVIEW(...)`, if you want the exact query instead of a chat answer.

**Verification caveat, stated plainly:** every number below was confirmed via direct SQL against
the same Semantic Views/search service the agent uses (`DESCRIBE AGENT` also confirms the live
spec matches this file byte-for-byte). What is *not* independently confirmed from this side is
that the agent's own LLM orchestration actually picks the right tool for a given natural-language
question in a live chat turn -- that needs the Agent Run API, which isn't reachable from here (see
NOTES.md; CoCo has done this kind of live `:run` check in earlier passes). Treat "the tool answers
this correctly when queried directly" and "the agent will route to it correctly in chat" as two
separate claims until the second one is actually checked.

### `trade_surveillance` -- `SV_TRADE_SURVEILLANCE`
Raw trade facts only -- volume, count, average price -- sliced by execution date, matching
mechanism, participant type, instrument type, or venue type. **Does not** expose wash-trading/
spoofing/position-limit *findings* -- those live in detector views this Semantic View was never
built over (see section 3 for how to actually get findings).

| You could ask | Confirmed real answer |
|---|---|
| "How many trades happened on each type of venue?" | `pts`: 499 trades, 2,578,659 volume, avg price 2536.00; `exchange`: 302 trades, 1,424,084 volume, avg price 2489.74; `block_trading`: 100 trades, 503,772 volume, avg price 2611.48 |
| "How many trades were crosses vs. continuous matching?" | `continuous`: 900; `cross`: 1 |
| "What's the total trade volume for Japan?" | Sum of the venue-type breakdown above: 4,506,515 |

### `obligations_reporting` -- `SV_OBLIGATIONS_REPORTING`
Approved obligations (never the base `OBLIGATION_MAP`), transaction reports, report templates --
three independent tables (no `RELATIONSHIPS` between them; a real modeling constraint, not an
oversight -- see the file's own header comment). `LATE_COUNT` uses the business-day-adjusted
deadline (fixed 2026-09-14 to agree with `surveillance_audit` below -- see NOTES.md for the
cross-tool inconsistency this closed).

`APPROVED_OBLIGATIONS`/`RULE_CORPUS` were empty backlog items until 2026-09-14 (see NOTES.md) --
now populated with five real citations, one per detector family, fetched live from the FSA's own
English translation of the Financial Instruments and Exchange Act and Osaka Exchange's own
Operational Procedures document (`sql/governance/01_rule_corpus_and_obligations_seed.sql`; both
are Japan's own primary sources, marked `SOURCE_AUTHORITY='translation'` per architecture.md's
design rule #6 since the legally authoritative text is Japanese).

| You could ask | Confirmed real answer |
|---|---|
| "How many transaction reports are late?" | 59 (business-day-adjusted; was incorrectly 82 before the weekend-deadline fix) |
| "How many required fields does the transaction_report template have, mapped vs. gap?" | `mapped`: 3; `gap`: 1 (`Trading_Capacity` -- a real required field with no current data source, surfaced not hidden, per Fix #28) |
| "How many reports are in 'new' status?" | 901 |
| "Which detectors have an approved obligation mapping?" | `best_execution`, `position_limit`, `spoofing_layering`, `reporting_timeliness`, `wash_trading` -- all five detector families now have one |
| "How many documented-finding verdicts are ready to submit?" | 124 of 124 (added 2026-09-15 -- `DOCUMENTED_FINDINGS_LOG` is now a 4th table, `DFL`, in this same Semantic View) |

**Still not answerable in natural language:** which *rule chunk* backs a given obligation --
`SV_OBLIGATIONS_REPORTING` doesn't declare `RULE_CORPUS`/`OBLIGATION_RULE_CHUNKS` as tables, so
that join isn't reachable through this tool. Use the new `rule_search` tool below,
`detector_findings` below, `run_rule_gap_analysis.py` (section 3), or the direct SQL in section 4d
for that.

### `surveillance_audit` -- `SV_SURVEILLANCE_AUDIT`
The scheduled-run audit trail (`SP_LOG_SURVEILLANCE_RUN` → `AUDIT_LOG` →
`SURVEILLANCE_RUN_LOG`) -- aggregate counts per detector per run, not row-level detail. Any
same-day/in-progress count must be presented with `LAST_RUN_AT` and "as of" framing per the
agent's instructions (added 2026-09-14) -- a count here is a snapshot, not a final total.

| You could ask | Confirmed real answer (as of the last run, 2026-09-14) |
|---|---|
| "How many wash-trading findings have been logged?" | 84 total across 3 runs (28 each) |
| "How many best-execution checks found a usable reference price?" | 0 of 901 -- `TRADE_REFERENCE_PRICES` isn't populated by the synthetic generator, surfaced as a coverage gap, not silently skipped |
| "When did the last surveillance run happen?" | 2026-09-14 (date-grain only -- a known Semantic View limitation, not full timestamp precision) |

**Fixed 2026-09-15:** row-level detail ("show me the actual wash-trading candidate trades") is now
answerable -- via the new `detector_findings` tool immediately below, not this one (this tool
stays aggregate-only by design; the two are deliberately separate tools, not one merged view).

### `detector_findings` -- `SV_DETECTOR_FINDINGS` (added 2026-09-15)
The actual flagged rows themselves -- wash-trading candidate pairs, spoofing/layering signal-days,
position-limit breach days, reporting-timeliness signals, execution/arrival slippage -- as six
independent tables (same "genuinely unrelated keys" situation as `obligations_reporting`; no
`RELATIONSHIPS` between them). This is the tool that closes the "no natural-language path to
row-level detector findings" gap -- previously the only options were an aggregate count
(`surveillance_audit`) or raw trade facts with no findings at all (`trade_surveillance`).

| You could ask | Confirmed real answer |
|---|---|
| "Show me the wash-trading candidates for participant P030, with instrument and exemption status" | Real rows, e.g. `(P030, P001, I07, exempt=False)`, `(P005, P025, I00, exempt=False)` -- actual pairs, not a count |
| "Which position limit breaches happened, and by how much?" | One real row: `P011, I05, 2026-07-31, 101.8% of limit` |
| "Show me participant P999's spoofing signal history by date, flagged or not" | 15 real daily rows, cancel-ratio z-score per day, correctly showing `IS_FLAGGED=True` only for 2025-07-04 (z-score 3.02) -- the rest unflagged, including several with no z-score at all (not enough baseline history yet) |

**Honesty note:** the two slippage tables (`EXECSLIP`/`ARRSLIP`) will honestly return 0 rows for
every question -- `TRADE_REFERENCE_PRICES` isn't populated by the synthetic generator, so
best-execution has nothing to check row-level detail against yet, same gap as `surveillance_audit`
above. This tool doesn't hide that; it surfaces it as an empty, real result.

### `rule_search` -- `RULE_CORPUS_SEARCH` (Cortex Search, added 2026-09-15)
Semantic search over all 15 real rule citations (5 detectors x 3 jurisdictions -- JP/US/EU) --
answers "what rule covers this conduct" without needing to already know the exact citation or
`CHUNK_ID`. Backed by `snowflake-arctic-embed-m-v1.5` embeddings, not keyword matching.

| You could ask | Confirmed real answer |
|---|---|
| "What rule covers placing orders and then cancelling them to make the market look more active than it is?" | Top hit: EU MAR Article 12(2)(c) (layering/spoofing); also surfaces US Exchange Act 9(a)(1), EU Annex I Section A(c), US CEA 4c(a)(5)(C), and JP FIEA 159(2)(i) in the top 5 -- a real cross-jurisdiction semantic match, not a keyword hit (none of those chunks contain the word "cancelling") |

Cross-referencing a `rule_search` hit against `obligations_reporting`/`detector_findings` for the
live obligation and any actual flagged rows (rather than answering from the citation text alone)
is the agent's own orchestration instruction, not something this tool does by itself -- see
`cortex_project/vigil_agent.sql`.

## 2. `DOCUMENTED_FINDINGS_LOG` -- real per-report assurance verdicts

Not yet wired into any Semantic View/agent tool (a natural next step, not done here) -- query
directly via SQL as `ANALYST_READ`:

```sql
SELECT REPORT_ID, READY_TO_SUBMIT, GAP_FIELDS, REASONS
FROM DOCUMENTED_FINDINGS_LOG
ORDER BY CREATED_AT DESC;
```

Confirmed real: 124 rows, all `READY_TO_SUBMIT = TRUE` (the one gap field, `Trading_Capacity`,
never blocks submission per Fix #28/#29). Generated by `scripts/generate_documented_findings.py`
(see section 3) -- this is the actual "documented finding" step, distinct from the aggregate
count `surveillance_audit` gives you.

## 3. Python skills -- CLI / script-callable

| Skill | How to run it today | What it does |
|---|---|---|
| `assure_report` | `.venv/bin/python3 scripts/generate_documented_findings.py --jurisdiction JP --report-type transaction_report` | Live: pulls every currently-flagged `TRANSACTION_REPORTS` row, calls `assure_report.assure()` against real data, writes a real verdict to `DOCUMENTED_FINDINGS_LOG`. |
| `surveillance_query` | `python3 -c "from skills.surveillance_query import *; print(build_query(SurveillanceQueryRequest('wash_trading', 'JP')))"` | Builds the `SELECT` string for a detector view + its companion coverage query (Fix #3) -- does not execute it itself (by design); pipe the string into `scripts/run_sql.py` or a SQL client. |
| `rule_interpret` | `.venv/bin/python3 scripts/run_rule_gap_analysis.py --jurisdiction JP --rule-chunk-id JP-FIEA-159-1-I --required-concepts wash_trading,circuit_breaker_compliance` | Live: reads the real `RULE_CORPUS` chunk + `APPROVED_OBLIGATIONS` coverage, runs the actual set-difference gap analysis. Confirmed real: 0 gaps when asked only about `wash_trading` (already approved); 1 gap (`circuit_breaker_compliance`) when a concept with no obligation mapping is added -- both outcomes real, not illustrative. |
| `narrative_draft` | Import-only today -- no CLI entry point yet. CLI wrapper in progress (CoCo). | Walks an `AUDIT_LOG` sign-off lineage chain, renders a plain-language narrative. Real, live rows exist to walk now (`SP_LOG_SURVEILLANCE_RUN`'s output), just no wrapper to invoke it from a terminal yet. |

## 4. Direct SQL -- detector views (row-level detail, `ANALYST_READ`)

For anything the agent can't answer in natural language yet -- actual flagged rows, not counts:

```sql
-- Wash-trading candidates, paired with coverage (Fix #3 -- never look at one without the other)
SELECT * FROM WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID = 'JP' AND NOT IS_TRIGGER_EXEMPT;
SELECT * FROM WASH_DETECTION_COVERAGE WHERE JURISDICTION_ID = 'JP';

-- Spoofing/layering signals for one participant, to see the baseline-then-spike pattern
SELECT * FROM SPOOFING_LAYERING_SIGNALS WHERE PARTICIPANT_ID = 'P999' ORDER BY EVENT_DATE;

-- Position-limit breaches
SELECT * FROM POSITION_LIMIT_BREACHES WHERE IS_BREACH;

-- Reporting timeliness, with the business-day-adjusted effective deadline visible
SELECT REPORT_ID, DEADLINE, EFFECTIVE_DEADLINE, IS_LATE_SUBMISSION
FROM REPORTING_TIMELINESS_SIGNALS WHERE IS_LATE_SUBMISSION;

-- Which real rule text backs each detector's obligation (added 2026-09-14 -- see NOTES.md)
SELECT o.OBLIGATION_ID, o.DETECTOR_NAME, r.DOC_TITLE, r.SECTION_REF, r.CHUNK_TEXT
FROM APPROVED_OBLIGATIONS o
JOIN OBLIGATION_RULE_CHUNKS_CURRENT c
    ON c.OBLIGATION_ID = o.OBLIGATION_ID AND c.JURISDICTION_ID = o.JURISDICTION_ID
JOIN RULE_CORPUS_CURRENT r ON r.CHUNK_ID = c.RULE_CHUNK_ID
WHERE o.JURISDICTION_ID = 'JP';
```

## 4b. Cortex Search -- semantic retrieval over `RULE_CORPUS` (added 2026-09-14)

`RULE_CORPUS_SEARCH` (`sql/cortex_search/01_rule_corpus_search.sql`) indexes `RULE_CORPUS_CURRENT`
(`CHUNK_TEXT`, `snowflake-arctic-embed-m-v1.5` embeddings, `TARGET_LAG='1 day'`) -- lets a caller
find the relevant citation by describing the conduct instead of needing the exact `CHUNK_ID`.
Confirmed real (`ANALYST_READ`, `SNOWFLAKE.CORTEX.SEARCH_PREVIEW`): querying "placing orders and
cancelling them to create a false impression of market activity" ranks `EU-MAR-12-2C` (EU
layering/spoofing) first, followed by `US-EXCHACT-9A1`, `EU-MAR-12-1A-ANNEXI-AC`,
`US-CEA-4C-A5-C`, and `JP-FIEA-159-2-I` -- a real cross-jurisdiction semantic match, not a keyword
match (none of those chunks contain the word "cancelling").

```sql
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'VIGIL.CORE.RULE_CORPUS_SEARCH',
    '{"query": "<describe the conduct>", "columns": ["CHUNK_ID","JURISDICTION_ID","DOC_TITLE","SECTION_REF"], "limit": 5}'
));
```

**Wired into the Cortex Agent as of 2026-09-15** -- the `rule_search` tool (section 1 above),
alongside a new `detector_findings` tool for row-level findings. `DESCRIBE AGENT
VIGIL_SURVEILLANCE_AGENT` confirms the live spec matches `cortex_project/vigil_agent.sql` exactly.
Not independently confirmed from this side: that the agent's own orchestration actually routes to
`rule_search`/`detector_findings` correctly in a live chat turn (needs the Agent Run API, not
reachable here) -- see section 1's verification caveat.

## 4c. Scheduled governance-coverage audit (added 2026-09-15)

`TASK_GOVERNANCE_COVERAGE_AUDIT` (`sql/tasks/02_governance_coverage_audit.sql`, weekly cron) calls
`SP_AUDIT_OBLIGATION_COVERAGE` (`sql/procedures/sp_audit_obligation_coverage.sql`), which logs one
`AUDIT_LOG` row per jurisdiction listing which of the five detector families have a real, active
obligation-to-rule-chunk chain and which don't. **Deliberately created `SUSPENDED`** and left that
way to avoid ongoing warehouse cost on a demo project -- activate only when actually demoing it:

```sql
ALTER TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT RESUME;   -- activate for the demo
ALTER TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT SUSPEND;  -- deactivate again afterward
EXECUTE TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT;        -- run once on demand, no schedule change
```

Confirmed real via `EXECUTE TASK` (task remained `suspended` afterward -- proven, not just
claimed): all three jurisdictions currently show `missing_detectors: []` (full 5/5 coverage).
**Scope note:** this checks internal mapping drift only -- it does not fetch FSA/JPX/SEC/EUR-Lex
sites for new or amended source documents (that needs External Access Integration, not enabled in
this pass -- see the "Known gaps" section above).

## 4d. Complex / cross-cutting queries (added 2026-09-15)

None of these are reachable through the agent's three tools -- each spans multiple detector views,
jurisdictions, or Cortex Search, which is exactly why they belong here rather than in section 4's
single-view examples. Every result below is real, run against live data on 2026-09-15.

**Cross-detector risk correlation** -- a participant flagged for spoofing/layering who also
appears in a non-exempt wash-trading pair (a genuine "repeat offender" signal no single detector
view can answer):
```sql
SELECT DISTINCT s.PARTICIPANT_ID, s.JURISDICTION_ID
FROM SPOOFING_LAYERING_SIGNALS s
JOIN WASH_TRADING_CANDIDATES w
    ON w.JURISDICTION_ID = s.JURISDICTION_ID
   AND (w.PARTICIPANT_ID_1 = s.PARTICIPANT_ID OR w.PARTICIPANT_ID_2 = s.PARTICIPANT_ID)
WHERE s.IS_FLAGGED AND NOT w.IS_TRIGGER_EXEMPT;
```
Confirmed real result: **0 rows.** P999 (the only flagged spoofing participant) never appears in a
wash-trading pair, and P011 (the only position-limit breach) doesn't either -- the synthetic
dataset has no built-in multi-detector repeat-offender scenario. Honest, not a bug; the query is
real and would fire the moment such a participant exists.

**Escalating-behavior trend** -- participants whose cancel-ratio z-score rose for two consecutive
periods and ended flagged (a window-function pattern no detector view computes on its own):
```sql
WITH trend AS (
    SELECT PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, EVENT_DATE, CANCEL_RATIO_ZSCORE, IS_FLAGGED,
           LAG(CANCEL_RATIO_ZSCORE, 1) OVER (PARTITION BY PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID ORDER BY EVENT_DATE) AS Z1,
           LAG(CANCEL_RATIO_ZSCORE, 2) OVER (PARTITION BY PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID ORDER BY EVENT_DATE) AS Z2
    FROM SPOOFING_LAYERING_SIGNALS
)
SELECT PARTICIPANT_ID, INSTRUMENT_ID, EVENT_DATE, Z2, Z1, CANCEL_RATIO_ZSCORE
FROM trend WHERE CANCEL_RATIO_ZSCORE > Z1 AND Z1 > Z2 AND IS_FLAGGED;
```
Confirmed real result: **0 rows** -- P999's flagged day is a single-day spike test case (Fix
P999/patch_spoofing_and_calibration.py), not a multi-day escalation, so there's nothing for this
pattern to catch yet. Same honesty note as above.

**Compound reporting risk** -- report types with both a nonzero late-submission count *and* an
unmapped required field (two independently-tracked risk signals that only matter together):
```sql
SELECT sig.JURISDICTION_ID, sig.REPORT_TYPE, COUNT_IF(sig.IS_LATE_SUBMISSION) AS LATE_COUNT,
       cov.PCT_REQUIRED_FIELDS_MAPPED, cov.GAP_FIELD_NAMES
FROM REPORTING_TIMELINESS_SIGNALS sig
JOIN REPORT_TEMPLATE_COVERAGE cov
    ON cov.REPORT_TYPE = sig.REPORT_TYPE AND cov.JURISDICTION_ID = sig.JURISDICTION_ID
GROUP BY sig.JURISDICTION_ID, sig.REPORT_TYPE, cov.PCT_REQUIRED_FIELDS_MAPPED, cov.GAP_FIELD_NAMES
HAVING LATE_COUNT > 0;
```
Confirmed real result: `JP, transaction_report, LATE_COUNT=59, PCT_REQUIRED_FIELDS_MAPPED=0.75,
GAP_FIELD_NAMES=["Trading_Capacity"]` -- the same 59 late reports from section 1, now shown
alongside the fact that 25% of the template's required fields (just `Trading_Capacity`) have no
data source, in one query.

**Cross-jurisdiction obligation-citation pivot** -- every detector family's real citation, JP vs.
US vs. EU, side by side:
```sql
SELECT d.DETECTOR_NAME,
    MAX(CASE WHEN o.JURISDICTION_ID='JP' THEN r.SECTION_REF END) AS JP_CITATION,
    MAX(CASE WHEN o.JURISDICTION_ID='US' THEN r.SECTION_REF END) AS US_CITATION,
    MAX(CASE WHEN o.JURISDICTION_ID='EU' THEN r.SECTION_REF END) AS EU_CITATION
FROM (SELECT column1 AS DETECTOR_NAME FROM VALUES
        ('wash_trading'),('spoofing_layering'),('position_limit'),('reporting_timeliness'),('best_execution')) d
LEFT JOIN APPROVED_OBLIGATIONS o ON o.DETECTOR_NAME = d.DETECTOR_NAME
LEFT JOIN OBLIGATION_RULE_CHUNKS_CURRENT c ON c.OBLIGATION_ID = o.OBLIGATION_ID AND c.JURISDICTION_ID = o.JURISDICTION_ID
LEFT JOIN RULE_CORPUS_CURRENT r ON r.CHUNK_ID = c.RULE_CHUNK_ID
GROUP BY d.DETECTOR_NAME ORDER BY d.DETECTOR_NAME;
```
Confirmed real, all 15 cells populated (no NULLs) -- e.g. `wash_trading`: JP=`Article 159,
Paragraph 1, Item (i)`, US=`Section 9(a)(1) [15 U.S.C. Sec 78i(a)(1)]`, EU=`Article 12(1)(a) and
Annex I, Section A(c)`.

**Full cross-detector risk profile for one participant** -- every finding across every detector,
for a single `PARTICIPANT_ID`, one query (`UNION ALL`, not achievable via any single view):
```sql
SELECT 'spoofing_layering' AS DETECTOR, EVENT_DATE::VARCHAR AS EVENT_DATE, CANCEL_RATIO_ZSCORE::VARCHAR AS DETAIL
FROM SPOOFING_LAYERING_SIGNALS WHERE PARTICIPANT_ID = 'P999' AND IS_FLAGGED
UNION ALL
SELECT 'wash_trading', EXECUTION_TIMESTAMP_1::VARCHAR, CANDIDATE_TYPE
FROM WASH_TRADING_CANDIDATES WHERE (PARTICIPANT_ID_1 = 'P999' OR PARTICIPANT_ID_2 = 'P999') AND NOT IS_TRIGGER_EXEMPT
UNION ALL
SELECT 'position_limit', AS_OF_DATE::VARCHAR, PCT_OF_LIMIT::VARCHAR
FROM POSITION_LIMIT_BREACHES WHERE PARTICIPANT_ID = 'P999' AND IS_BREACH;
```
Confirmed real: exactly one row, `('spoofing_layering', '2025-07-04', '3.015113451')` -- P999 is a
single-detector test case, and this query proves that (not just asserts it) by actually checking
the other two detectors and finding nothing.

**Hybrid Cortex Search -> live obligation + flagged-count pipeline** -- the most complex one:
describe the conduct in plain English, let Cortex Search rank the matching citations across all
three jurisdictions, then join each hit to its real approved obligation and (for JP, the only
jurisdiction with run history) its latest live flagged count:
```sql
WITH hit AS (
    SELECT f.value:CHUNK_ID::VARCHAR AS CHUNK_ID, f.index AS RANK
    FROM TABLE(FLATTEN(
        INPUT => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'VIGIL.CORE.RULE_CORPUS_SEARCH',
            '{"query": "trading without intent to transfer ownership to create false trading activity", "columns": ["CHUNK_ID"], "limit": 3}'
        )):results
    )) f
)
SELECT hit.RANK, o.JURISDICTION_ID, o.OBLIGATION_ID, r.SECTION_REF, run.FLAGGED_COUNT
FROM hit
JOIN RULE_CORPUS_CURRENT r ON r.CHUNK_ID = hit.CHUNK_ID
JOIN OBLIGATION_RULE_CHUNKS_CURRENT c ON c.RULE_CHUNK_ID = r.CHUNK_ID
JOIN APPROVED_OBLIGATIONS o ON o.OBLIGATION_ID = c.OBLIGATION_ID AND o.JURISDICTION_ID = c.JURISDICTION_ID
LEFT JOIN SURVEILLANCE_RUN_LOG run
    ON run.DETECTOR_NAME = o.DETECTOR_NAME AND run.JURISDICTION_ID = o.JURISDICTION_ID
    AND run.CREATED_AT = (SELECT MAX(CREATED_AT) FROM SURVEILLANCE_RUN_LOG r2
                           WHERE r2.DETECTOR_NAME = o.DETECTOR_NAME AND r2.JURISDICTION_ID = o.JURISDICTION_ID)
ORDER BY hit.RANK;
```
Confirmed real result -- the query never once mentioned "wash trading" and correctly surfaced all
three wash-trading citations, ranked by semantic relevance, each annotated honestly:
| RANK | JURISDICTION | OBLIGATION | CITATION | FLAGGED_COUNT |
|---|---|---|---|---|
| 0 | US | US-WASH-001 | Section 9(a)(1) [15 U.S.C. Sec 78i(a)(1)] | NULL (no US run history) |
| 1 | JP | JP-WASH-001 | Article 159, Paragraph 1, Item (i) | 28 (real, from the last surveillance run) |
| 2 | EU | EU-WASH-001 | Article 12(1)(a) and Annex I, Section A(c) | NULL (no EU run history) |

Building this query surfaced a real gap and fixed it in the process:
`SURVEILLANCE_RUN_LOG` had no `JURISDICTION_ID` column at all (every run to date being Japan-only
had hidden this), so joining on `DETECTOR_NAME` alone would have silently misattributed JP's
flagged count to US/EU rows the moment those jurisdictions got their own runs. Fixed 2026-09-15 by
extracting `PARSE_JSON(OUTPUT):jurisdiction_id` (already written by `SP_LOG_SURVEILLANCE_RUN`,
just never surfaced as a column) into `SURVEILLANCE_RUN_LOG` and adding a matching
`RUN.JURISDICTION_ID` dimension to `SV_SURVEILLANCE_AUDIT` -- verified via
`SELECT * FROM SEMANTIC_VIEW(SV_SURVEILLANCE_AUDIT DIMENSIONS RUN.JURISDICTION_ID METRICS RUN.TOTAL_FLAGGED)`
returning `('JP', 1424)`. The query above now joins correctly with no jurisdiction guard needed.

## 5. Presentation surfaces

- **Streamlit (`VIGIL.CORE.VIGIL_DASHBOARD`, Snowsight)** -- 6 tabs: Overview, Trade Surveillance,
  Spoofing/Layering, Position Limits, Reporting & Templates, Best Execution. All query the same
  views as sections 3-4 above, filterable by jurisdiction.
- **Jupyter (`notebooks/vigil_demo.ipynb`)** -- narrated walkthrough of every workflow in this
  document, with real executed outputs already saved in the committed file.

## Known gaps in "what can be asked" (surfaced, not hidden)

- ~~No natural-language path to row-level detector findings~~ -- FIXED 2026-09-15: the
  `detector_findings` tool (`SV_DETECTOR_FINDINGS`, section 1) exposes wash-trading candidates,
  spoofing signals, position-limit breaches, reporting-timeliness signals, and execution/arrival
  slippage at real row-level granularity. Not yet independently confirmed: live agent-chat routing
  to this tool (see section 1's verification caveat -- confirmed via direct SQL, not a live `:run`
  call).
- `RULE_CORPUS`/`OBLIGATION_MAP`/`OBLIGATION_RULE_CHUNKS` are populated as of 2026-09-14/15 --
  fifteen real citations total, five per jurisdiction (`JP`, `US`, `EU`), one per detector family,
  all approved via `SP_APPROVE_OBLIGATION`'s real `INFORMATION_SCHEMA` validation
  (`sql/governance/01_*.sql` for Japan, `sql/governance/02_*.sql` for US/EU; see NOTES.md for
  source URLs and the original PDFs saved in `docs/sources/`). US/EU are governance content only
  -- no `JURISDICTION_CONFIG`, venues, or synthetic trade data exist for either, so the detector
  views honestly return 0 rows `WHERE JURISDICTION_ID IN ('US','EU')`; the obligations are real
  and approved, just currently unexercised. `REPORT_TEMPLATE_RULE_CHUNKS` now has 65 real
  field-level citations for **EU** `transaction_report` (RTS 22 Annex I Table 2,
  `sql/governance/03_eu_report_template_rts22_seed.sql`, 2026-09-15) -- still empty for **JP**:
  citing which exact ordinance/form clause requires a specific JP report field needs Japan's own
  prescribed form spec, which two research passes haven't found precise citations for; left open
  rather than forcing inexact ones. Note
  also that `JP-RPTTIME-001`'s citation is OSE's *large position report* deadline (a real
  T+1-business-day precedent for the pattern VIGIL implements), not a located citation of Japan's
  own transaction-report deadline rule specifically -- see that obligation's
  `OBLIGATION_DESCRIPTION` for the precise scope of the claim.
- ~~`DOCUMENTED_FINDINGS_LOG` isn't askable in natural language yet~~ -- FIXED 2026-09-15: it's
  now the `DFL` table inside `SV_OBLIGATIONS_REPORTING`, reachable via the existing
  `obligations_reporting` tool (section 1).
- Best-execution: `TRADE_REFERENCE_PRICES` is populated (773 of 901 JP trades have a reference
  price; one venue deliberately excluded to keep that coverage gap real) -- being reworked
  2026-09-15 from a trade-price-plus-noise formula (mathematically near-zero by construction) to
  a same-day VWAP of other trades in the instrument (a genuinely independent signal) -- see NOTES.md.
- There is no automated pipeline for sourcing regulatory text -- everything in `RULE_CORPUS` was a
  one-time manual pass (web search -> download PDF -> `pdftotext` -> hand-pick the citable excerpt
  -> hand-write into a seed SQL file). Snowflake has native building blocks that could automate
  more of this (External Access Integration for outbound fetches, Cortex Document AI/
  `PARSE_DOCUMENT` for in-Snowflake extraction, Cortex AISQL for text-to-obligation mapping,
  Tasks/Streams for scheduled monitoring of source sites) but none of that is wired up -- see
  `TASK_GOVERNANCE_COVERAGE_AUDIT` below, which deliberately audits *internal* mapping drift, not
  external source documents, since External Access Integration was not enabled in this pass.
