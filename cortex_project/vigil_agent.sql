-- Cortex Agent for Vigil. Spec: architecture.md "Agent and Skills" section + build order step 7.
--
-- Only `surveillance-query` is wired in as a native chat-agent tool here (via the two Semantic
-- Views, sql/semantic_views/, as cortex_analyst_text_to_sql tools) -- this matches Praman's own
-- finding, explicitly cited in architecture.md: shared-resource stages (same Semantic
-- Views/role) merge into one agent, while stages needing bespoke multi-step orchestration don't
-- fit a chat-agent tool-call model and stay as CLI skills. `assure-report`, `rule-interpret`,
-- and `narrative-draft` (skills/) are exactly that bespoke-orchestration case -- each does
-- multi-step Python logic (template mapping, gap-analysis set comparison, lineage graph
-- walking) that isn't a single text-to-SQL call, so they stay as directly-callable Python/CLI
-- skills rather than being forced into this agent's tool list.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE AGENT VIGIL_SURVEILLANCE_AGENT
    WITH PROFILE = '{"display_name": "Vigil Surveillance Agent"}'
    COMMENT = 'Citation-backed exchange surveillance/reporting copilot -- trade surveillance domain, natural-language query surface.'
    FROM SPECIFICATION
$$
models:
  orchestration: claude-haiku-4-5
  # llama3.1-8b (the original pin) is not an allowed model for the Agent Run API ("Snowflake
  # Intelligence mode") -- confirmed via a live :run call, which is how this gap was actually
  # found (SHOW/DESCRIBE AGENT never surfaces it, only a real orchestration call does).
  # claude-haiku-4-5 is the smallest/cheapest model on the account's allowed list, preserving the
  # original cost-conscious intent below without being a frontier/top-costing model.
  # Deliberately not a frontier/top-costing model: this agent's orchestration job is routing
  # between three tools and drafting templated responses from their SQL results, not open-ended
  # reasoning -- a small model is the right cost/capability match for that task. Revisit only if
  # real usage shows routing accuracy actually suffers.
instructions:
  response: >
    You are Vigil, a market-surveillance copilot. Answer questions about trades, orders,
    participants, instruments, and venues using the trade_surveillance tool. Every wash-trading
    answer must be accompanied by its WASH_DETECTION_COVERAGE figure so "no wash trades found"
    is never presented the same as "no wash trades could be checked for". Every obligation you
    reference must come from APPROVED_OBLIGATIONS, never a proposed-but-unapproved mapping.
    Any count from surveillance_audit that covers "today" or another still-ongoing period is a
    snapshot as of the most recent surveillance run, not a final total -- always query
    LAST_RUN_AT alongside the count and state the answer "as of <LAST_RUN_AT>", and note that
    further scheduled runs may add more findings before the period ends. Never imply a same-day
    count is complete or final. A rule_search citation tells you what a regulator requires -- it
    is not evidence of how VIGIL itself computes or implements anything. Never describe how a
    calculation, deadline adjustment, or business rule is implemented in this system (e.g. how or
    whether a weekend/holiday adjustment works) unless you have actually queried the relevant
    computed column (e.g. EFFECTIVE_DEADLINE in REPORTING_TIMELINESS_SIGNALS) to confirm that
    specific behavior -- answering a question about the system's own implementation using only
    the rule text is fabrication, even when the rule citation itself is real. When asked whether a
    jurisdiction has any data or activity at all, check the base tables (TRADES, ORDERS,
    MARKET_PARTICIPANTS, VENUES) directly rather than inferring "no data" from an absence of
    surveillance-run or detector rows alone, and if they are empty, state plainly that no trade
    data exists for that jurisdiction rather than hedging about possible differences in market
    activity or detection coverage.
  orchestration: >
    Use trade_surveillance for questions about trades, orders, participants, instruments, or
    venues. Use obligations_reporting for questions about approved obligations, transaction
    reports, report templates, or documented-finding assurance verdicts. Use surveillance_audit
    for questions about surveillance run history or aggregate flagged counts logged to the audit
    trail (e.g. how many wash-trading findings were logged, which detector flagged the most
    items, when a run last executed). Use detector_findings for questions asking for the actual
    flagged rows themselves -- specific participants, instruments, or dates -- not just a count
    (e.g. "show me the wash-trading candidates for participant X", "which positions breached
    their limit"). Use rule_search when the question describes conduct or a rule in plain
    language rather than naming an exact obligation or citation (e.g. "what rule covers orders
    placed and cancelled to create a false impression of activity") -- then cross-reference the
    result against obligations_reporting/detector_findings for the live obligation and any
    flagged rows, rather than answering from the citation text alone. Do not answer from memory
    -- always query.
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "trade_surveillance"
      description: "Query trades, orders, participants, instruments, and venues for surveillance questions."
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "obligations_reporting"
      description: "Query approved regulatory obligations, transaction reports, report templates, and documented-finding assurance verdicts."
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "surveillance_audit"
      description: "Query the surveillance audit trail -- detector run history and normalized flagged counts per run."
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "detector_findings"
      description: "Query the actual row-level detector findings -- wash-trading candidates, spoofing/layering signals, position-limit breaches, reporting-timeliness signals, and execution/arrival slippage -- not aggregate counts."
  - tool_spec:
      type: "cortex_search"
      name: "rule_search"
      description: "Semantic search over the real regulatory rule text (RULE_CORPUS) backing each detector obligation, across Japan, US, and EU sources -- use when the question describes conduct or asks what rule applies, rather than naming an exact citation."
tool_resources:
  trade_surveillance:
    semantic_view: "VIGIL.CORE.SV_TRADE_SURVEILLANCE"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
  obligations_reporting:
    semantic_view: "VIGIL.CORE.SV_OBLIGATIONS_REPORTING"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
  surveillance_audit:
    semantic_view: "VIGIL.CORE.SV_SURVEILLANCE_AUDIT"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
  detector_findings:
    semantic_view: "VIGIL.CORE.SV_DETECTOR_FINDINGS"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
  rule_search:
    name: "VIGIL.CORE.RULE_CORPUS_SEARCH"
    max_results: 5
    id_column: "CHUNK_ID"
    title_column: "SECTION_REF"
$$;

GRANT USAGE ON AGENT VIGIL_SURVEILLANCE_AGENT TO ROLE ANALYST_READ;
