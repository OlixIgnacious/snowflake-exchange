# What Vigil can answer, by workflow

A reference for what's actually queryable today, organized by how you'd ask -- natural language
to the Cortex Agent, a Python skill/CLI call, or direct SQL against a detector view. Every
example below was run against live `VIGIL.CORE` data while writing this doc (2026-09-14, Japan
synthetic dataset) -- the numbers shown are real results, not illustrative guesses. Where
something is *not* answerable today, that's stated as plainly as what is -- this list is meant to
be trusted, not aspirational.

## 1. Ask `VIGIL_SURVEILLANCE_AGENT` (natural language)

Three tools, each backed by one Semantic View, each with a genuinely different scope. The agent
picks the tool; you can also address a tool's underlying Semantic View directly via
`SELECT * FROM SEMANTIC_VIEW(...)` if you want the exact query instead of a chat answer.

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

**Still not answerable in natural language:** which *rule chunk* backs a given obligation --
`SV_OBLIGATIONS_REPORTING` doesn't declare `RULE_CORPUS`/`OBLIGATION_RULE_CHUNKS` as tables, so
that join isn't reachable through the agent yet. Use section 3's `run_rule_gap_analysis.py` or the
direct SQL in section 4 for that.

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

**Not answerable yet:** row-level detail ("show me the actual wash-trading candidate trades") --
this tool only has aggregate counts. For that, use section 3 or 4 below.

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

Not yet wired into the Cortex Agent as a fourth tool (`rule_corpus_search` alongside
`trade_surveillance`/`obligations_reporting`/`surveillance_audit`) -- a natural next step, not done
here.

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

## 5. Presentation surfaces

- **Streamlit (`VIGIL.CORE.VIGIL_DASHBOARD`, Snowsight)** -- 6 tabs: Overview, Trade Surveillance,
  Spoofing/Layering, Position Limits, Reporting & Templates, Best Execution. All query the same
  views as sections 3-4 above, filterable by jurisdiction.
- **Jupyter (`notebooks/vigil_demo.ipynb`)** -- narrated walkthrough of every workflow in this
  document, with real executed outputs already saved in the committed file.

## Known gaps in "what can be asked" (surfaced, not hidden)

- No natural-language path to row-level detector findings -- only aggregate counts
  (`surveillance_audit`) or raw trade facts (`trade_surveillance`). Closing this would mean a
  fourth Semantic View over the detector views themselves.
- `RULE_CORPUS`/`OBLIGATION_MAP`/`OBLIGATION_RULE_CHUNKS` are populated as of 2026-09-14/15 --
  fifteen real citations total, five per jurisdiction (`JP`, `US`, `EU`), one per detector family,
  all approved via `SP_APPROVE_OBLIGATION`'s real `INFORMATION_SCHEMA` validation
  (`sql/governance/01_*.sql` for Japan, `sql/governance/02_*.sql` for US/EU; see NOTES.md for
  source URLs and the original PDFs saved in `docs/sources/`). US/EU are governance content only
  -- no `JURISDICTION_CONFIG`, venues, or synthetic trade data exist for either, so the detector
  views honestly return 0 rows `WHERE JURISDICTION_ID IN ('US','EU')`; the obligations are real
  and approved, just currently unexercised. `REPORT_TEMPLATE_RULE_CHUNKS` is still empty for all
  three jurisdictions -- citing which exact ordinance/form clause requires a specific report field
  (e.g. Japan's `Trading_Capacity` gap field) needs each regulator's prescribed form spec, which
  this pass didn't find precise citations for; left open rather than forcing inexact ones. Note
  also that `JP-RPTTIME-001`'s citation is OSE's *large position report* deadline (a real
  T+1-business-day precedent for the pattern VIGIL implements), not a located citation of Japan's
  own transaction-report deadline rule specifically -- see that obligation's
  `OBLIGATION_DESCRIPTION` for the precise scope of the claim.
- `DOCUMENTED_FINDINGS_LOG` isn't askable in natural language yet (section 2) -- SQL/CLI only.
- Best-execution questions are honest but currently uninteresting: 0 of 901 trades have a
  reference price to check against, since `TRADE_REFERENCE_PRICES` isn't populated by the
  synthetic generator.
- There is no automated pipeline for sourcing regulatory text -- everything in `RULE_CORPUS` was a
  one-time manual pass (web search -> download PDF -> `pdftotext` -> hand-pick the citable excerpt
  -> hand-write into a seed SQL file). Snowflake has native building blocks that could automate
  more of this (External Access Integration for outbound fetches, Cortex Document AI/
  `PARSE_DOCUMENT` for in-Snowflake extraction, Cortex AISQL for text-to-obligation mapping,
  Tasks/Streams for scheduled monitoring of source sites) but none of that is wired up -- see
  `TASK_GOVERNANCE_COVERAGE_AUDIT` below, which deliberately audits *internal* mapping drift, not
  external source documents, since External Access Integration was not enabled in this pass.
