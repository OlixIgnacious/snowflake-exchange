# Vigil

Citation-backed exchange/securities-market regulatory reporting and surveillance copilot, built on Snowflake Cortex/CoCo — a full-domain pivot from a prior banking-credit-risk prototype (`Praman`), designed market-agnostic from day one.

Covers four obligation types: trade surveillance/market conduct, position/exposure limits, post-trade transaction reporting, and best execution.

See `architecture.md` for the data model, RBAC design, detector framework, and build order. DDL/RBAC scripts are written here and may be executed directly against Snowflake by Claude (see `CLAUDE.md`'s "SQL execution" section) — every run is logged in `NOTES.md`.

## Status

All 8 build-order phases (`plan.md`) are done for the first jurisdiction (Japan, `JURISDICTION_ID = 'JP'`): DDL (18 tables), RBAC (5 roles, live-verified 27/27), detectors (`ZSCORE` UDF + 7 detector/coverage views), Semantic Views (3) + report-generation adaptor, synthetic data generator + Snowflake load, 4 product skills + `VIGIL_SURVEILLANCE_AGENT` (Cortex Agent, live-tested), RBAC live verification, and a demo layer (Streamlit-in-Snowflake dashboard + Jupyter walkthrough). A follow-on pass added a scheduled surveillance-run audit trail (`SP_LOG_SURVEILLANCE_RUN` + `SURVEILLANCE_RUN_LOG`/`SV_SURVEILLANCE_AUDIT`, wired into the agent as a third tool) and a documented-findings pipeline (`scripts/generate_documented_findings.py` + `SP_LOG_DOCUMENTED_FINDING`).

Not yet production-ready — see `NOTES.md`'s production-readiness and full-project review entries for the detailed gap list. In short:
- `RULE_CORPUS`, `OBLIGATION_MAP`, and their rule-chunk junction tables are still empty — real FSA/SESC/JPX rule text for Japan hasn't been sourced (explicitly deferred, `architecture.md`'s "What's explicitly deferred" section), so `rule_interpret.py` has no real content to run against yet.
- US `JURISDICTION_CONFIG` is deliberately not built — blocked on the same live per-venue verification discipline Japan's config went through, not a shortcut.
- `rule_interpret.py`/`narrative_draft.py` have no CLI execution wrapper yet (`assure_report.py` gained one; the other two still take pre-fetched Python objects as arguments).
- No automated (pytest) coverage against a live/mocked Snowflake session — all SQL-layer verification is manual/live, logged in `NOTES.md`.
