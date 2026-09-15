# Vigil

**A citation-backed regulatory reporting and market-surveillance copilot for exchanges and
trading venues, built natively on Snowflake Cortex.**

Vigil turns raw order/trade/position data into surveillance findings, timeliness and best-execution
metrics, and regulator-ready reports — every finding traceable back to the specific rule text that
requires it, and every write path governed by role-based access control instead of application-layer
trust.

## Why Vigil

Regulatory surveillance systems are usually built for one market and retrofitted for others later,
which is where hardcoded currencies, market codes, and thresholds tend to creep in. Vigil is built
**market-agnostic from the first line of schema**: every detector reads its thresholds from a
calibration table scoped by jurisdiction, not a literal in the query, so extending coverage to a new
regulator is a data problem, not a code change.

## Core capabilities

| Obligation type | What it covers |
|---|---|
| **Trade surveillance** | Wash trading, spoofing/layering, and abnormal volume/price detection over order and trade event streams |
| **Position & exposure limits** | Concentration of a position in an instrument against a regulatory threshold, corporate-action-adjusted |
| **Transaction reporting** | Timeliness, completeness, and field-level accuracy of trade reports submitted to a regulator |
| **Best execution** | Execution price vs. reference price, order-routing quality |

Findings and reports are grounded in real rule text — a governed corpus of regulatory citations
(`RULE_CORPUS`) is mapped to obligations and report fields, so the agent can answer *why* a
requirement exists, not just *whether* it was met.

## Architecture

```
Orders / Trades / Positions (event-sourced, append-only, milestoned)
            │
            ▼
   Detector views (ZSCORE UDF + calibration-driven thresholds)
            │
            ▼
   Semantic Views  ──►  Cortex Agent (VIGIL_SURVEILLANCE_AGENT)
            │                    │
            ▼                    ▼
   Report-rendering        Skills: surveillance query · rule interpretation
   procedures (governed)   narrative drafting · report assurance
```

- **Schema** — one canonical data model shared by all four obligation types, scoped by
  `JURISDICTION_ID` (regulator) and `VENUE_ID` (exchange/PTS), append-only with explicit
  milestoning — no table is ever `UPDATE`d or `DELETE`d in place.
- **RBAC** — five functional roles (market-data ingest, analyst read, governance write, audit
  insert, officer sign-off) plus a scoped automation role for programmatic execution; none of them
  hold write access beyond their documented boundary.
- **Detectors** — SQL views joined against a per-jurisdiction `DETECTOR_CALIBRATION` table, so
  thresholds are configuration, not code.
- **Governance gate** — new obligations and report-template mappings move through a
  proposed → approved workflow validated against live `INFORMATION_SCHEMA`, not just inserted.
- **Agent layer** — a Snowflake Cortex Agent backed by four skills (surveillance querying, rule
  interpretation, narrative drafting, report assurance) and a scheduled audit trail of every
  surveillance run.

Full data model, RBAC matrix, detector design, and build order: [`architecture.md`](architecture.md).
Diagrams (system architecture, milestoning, ingestion/detection sequence, governance-gate
sequence, per-role flows): [`docs/system_diagrams.md`](docs/system_diagrams.md).

## Tech stack

| Layer | Technology |
|---|---|
| Data platform | Snowflake (native SQL, no migration tool) |
| AI/agent layer | Snowflake Cortex — Cortex Agents, Cortex Search |
| Language | Python 3.12 |
| Demo UI | Streamlit-in-Snowflake |
| Testing | pytest |

## Repository structure

```
sql/
  ddl/              Schema (reference data, orders, trades, positions, reports, governance, audit)
  rbac/             Role and grant scripts
  detectors/        Detector views + ZSCORE UDF
  semantic_views/   Semantic Views backing the Cortex Agent
  procedures/       Governed stored procedures (sign-off, report rendering, audit logging)
  governance/       Seeded rule corpus / obligation mappings
generator/          Synthetic data generator + Snowflake loader, per-jurisdiction config
skills/             Agent skills (surveillance query, rule interpretation, narrative draft, report assurance)
cortex_project/     Cortex Agent definition + live routing regression suite
ui/                 Streamlit dashboard
notebooks/          Demo walkthrough
docs/               Schema contract, data dictionary, workflow query reference, diagrams
scripts/            Operational scripts (SQL runner, RBAC verification, restatement)
tests/              pytest suite (generator, skills, report adaptor)
```

## Getting started

Python tooling runs from a `.venv` built with Homebrew's `python@3.12` (the system Python can't
build `snowflake-connector-python` from source).

```bash
# Connectivity check
.venv/bin/python3 scripts/run_sql.py --check

# Run SQL against VIGIL.CORE
.venv/bin/python3 scripts/run_sql.py sql/ddl/00_setup.sql

# Live RBAC verification (positive + negative checks per role)
.venv/bin/python3 scripts/verify_rbac.py

# Run the test suite (no Snowflake connection required)
.venv/bin/python3 -m pytest

# Generate and load synthetic data
.venv/bin/python3 generator/load_to_snowflake.py
```

Connection config (account/user/role/warehouse/private-key path) is read from a local, gitignored
`.env` file; the private key itself is kept outside the repository entirely.

## Status

All build-order phases are complete for the first jurisdiction, Japan (`JURISDICTION_ID = 'JP'`):
schema, RBAC, detectors, semantic views, agent + skills, synthetic data, and a demo layer, along
with a scheduled audit trail and a documented-findings pipeline. Since the initial build the
project has been through several rounds of adversarial review — see [`NOTES.md`](NOTES.md) for the
full, dated history — covering least-privilege execution, structural (not prompt-only)
agent-honesty guarantees, and deeper audit-trail coverage.

**Known limitations:**

- Only Japan has a complete jurisdiction config with synthetic trade data. US and EU currently have
  regulatory citation coverage seeded (including a fully sourced EU transaction-reporting field
  list) but no synthetic trade data behind them — a second fully built jurisdiction is needed to
  substantiate the market-agnostic design end to end.
- Field-level report-format citations are sourced for the EU but not yet for Japan.
- SQL-layer correctness (RBAC, detectors, schema conformance) is verified manually against a live
  Snowflake session and logged in `NOTES.md`, not yet covered by automated tests. The Python-only
  layers (generator, skills, report adaptor) have full pytest coverage.
