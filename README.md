# Vigil

Citation-backed exchange/securities-market regulatory reporting and surveillance copilot, built on Snowflake Cortex/CoCo — a full-domain pivot from a prior banking-credit-risk prototype (`Praman`), designed market-agnostic from day one.

Covers four obligation types: trade surveillance/market conduct, position/exposure limits, post-trade transaction reporting, and best execution.

See `architecture.md` for the data model, RBAC design, detector framework, and build order. No SQL has been run against Snowflake yet — DDL/RBAC scripts are written but must be executed interactively, not by a non-interactive agent (same discipline as the `Praman` project this was forked in spirit from).

## Status

Scaffold + architecture doc only. Next: `docs/canonical_schema_contract.md`, then `sql/ddl/`.
