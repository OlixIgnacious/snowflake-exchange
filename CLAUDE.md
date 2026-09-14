# CLAUDE.md

Guidance for working in this repository.

## What this is

**Vigil** — exchange/securities-market regulatory reporting and surveillance, built market-agnostic from day one. Read `architecture.md` first; it is the source of truth for the data model, RBAC, detector design, and build order.

This project is a deliberate domain pivot away from a sibling repo (`Praman`, bank credit-risk/Basel Pillar-3 reporting) — do not port banking-specific concepts (NPA classification, Pillar-3 line items, `ADVANCES_FUND`-style account codes) into this schema. Where a *pattern* from that project is reused (RBAC role shape, append-only audit log, the `ZSCORE` UDF, the proposed/approved governance gate, Semantic-View-per-domain-object), `architecture.md` says so explicitly — treat anything not called out as reused as new, domain-specific design.

## Market-agnostic discipline

`architecture.md`'s "Market-agnostic design rules" section is a set of day-one constraints, not aspirational goals to clean up later. Before adding a column, view, or constant, check it doesn't violate one of those rules — in particular: no hardcoded currency/market code/threshold, and every detector view must join `DETECTOR_CALIBRATION` rather than embed a literal.

## SQL execution

SQL runs directly against Snowflake (same account as `Praman`, disjoint `VIGIL.CORE`/`VIGIL.EVAL` schemas), not through a migration tool. **As of 2026-09-14, Claude may execute DDL/RBAC/grant scripts directly against this account** (revised from the original "human-only, interactive" rule — the user made this change explicitly, after being asked to confirm it as a permanent policy change rather than a one-off). Two things carry over unchanged from the original discipline:

- **Credentials are never committed.** They live in environment variables or a local, gitignored file (`.env` — already in `.gitignore`), never hardcoded in a script or checked into the repo.
- **Every executed run is logged in `NOTES.md`** (gitignored; recreate locally if it doesn't exist) — script/statement run, timestamp, result. This preserves the audit trail the original human-run discipline existed to guarantee, even though a human is no longer the one typing the statements in.

This does not change anything about the schema's own append-only/milestoning rules (`architecture.md`) — no functional role is ever granted `UPDATE`/`DELETE` on `VIGIL.CORE`, and that stays a property of the grant scripts themselves, not of who executes them.

## Commands

Python tooling lives in a `.venv` (created with Homebrew's `python@3.12`, not the system Python
3.9 — that one can't build `snowflake-connector-python` from source, see `TRACKER.md`).

- Run any SQL file(s) against `VIGIL.CORE`: `.venv/bin/python3 scripts/run_sql.py <file.sql> ...`
- Connectivity check only: `.venv/bin/python3 scripts/run_sql.py --check`
- Live RBAC verification (positive+negative checks per role): `.venv/bin/python3 scripts/verify_rbac.py`
- Run the test suite (generator acceptance criteria, report adaptor, skills — no Snowflake needed): `.venv/bin/python3 -m pytest`
- Generate synthetic data in-memory: `from generator.generate import generate; from generator.jurisdiction_config import JAPAN_CONFIG`
- Load synthetic data into Snowflake: `.venv/bin/python3 generator/load_to_snowflake.py`

Connection config (account/user/role/warehouse/private-key path) lives in `.env` (gitignored);
the private key itself lives outside the repo entirely, in `~/.snowflake/`.
