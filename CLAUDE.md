# CLAUDE.md

Guidance for working in this repository.

## What this is

**Vigil** — exchange/securities-market regulatory reporting and surveillance, built market-agnostic from day one. Read `architecture.md` first; it is the source of truth for the data model, RBAC, detector design, and build order.

This project is a deliberate domain pivot away from a sibling repo (`Praman`, bank credit-risk/Basel Pillar-3 reporting) — do not port banking-specific concepts (NPA classification, Pillar-3 line items, `ADVANCES_FUND`-style account codes) into this schema. Where a *pattern* from that project is reused (RBAC role shape, append-only audit log, the `ZSCORE` UDF, the proposed/approved governance gate, Semantic-View-per-domain-object), `architecture.md` says so explicitly — treat anything not called out as reused as new, domain-specific design.

## Market-agnostic discipline

`architecture.md`'s "Market-agnostic design rules" section is a set of day-one constraints, not aspirational goals to clean up later. Before adding a column, view, or constant, check it doesn't violate one of those rules — in particular: no hardcoded currency/market code/threshold, and every detector view must join `DETECTOR_CALIBRATION` rather than embed a literal.

## SQL execution

SQL runs directly against Snowflake (same account as `Praman`, disjoint `VIGIL.CORE`/`VIGIL.EVAL` schemas), not through a migration tool, and not from a non-interactive agent — DDL/RBAC/grant scripts are written here but executed by a human interactively (mirroring `Praman`'s `NOTES.md` discipline; recreate that file locally if it doesn't exist here yet, since it's gitignored).

## Commands

Not yet established — no generator, tests, or ingestion scripts exist yet. This section should be filled in as `uv`/Python tooling is added, following the same pattern as `Praman`'s `CLAUDE.md`.
