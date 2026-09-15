#!/usr/bin/env python3
"""One-off load of the new US_CONFIG/EU_CONFIG synthetic data (closing the review finding
"market-agnostic is proven for one jurisdiction only") into the already-live VIGIL.CORE.

Deliberately does NOT use generator/load_to_snowflake.py's full LOAD_PLAN as-is -- skips
JURISDICTIONS (US/EU rows already exist, seeded by sql/governance/02_us_eu_rule_corpus_and_
obligations_seed.sql with real regulator names; re-inserting the generator's own copy would
create a second, redundant milestoned version) and REPORT_TEMPLATES (EU's real 65-field RTS 22
template already exists, sql/governance/03_eu_report_template_rts22_seed.sql; the generator's
generic 4-field Price/Volume/Instrument_ID/Trading_Capacity seed would sit alongside it as
duplicate-content rows under different field names -- exactly the "toy template" pattern this
session's own work was fixing, not something to reintroduce for a second jurisdiction).

Usage: .venv/bin/python3 scripts/load_us_eu_configs.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from generator.generate import generate
from generator.jurisdiction_config import US_CONFIG, EU_CONFIG
from generator.load_to_snowflake import load_table
from run_sql import connect

LOAD_PLAN = [
    ("VENUES", "MARKET_DATA_INGEST", []),
    ("BENEFICIAL_OWNERS", "MARKET_DATA_INGEST", []),
    ("INSTRUMENTS", "MARKET_DATA_INGEST", []),
    ("MARKET_PARTICIPANTS", "MARKET_DATA_INGEST", []),
    ("ORDERS", "MARKET_DATA_INGEST", ["REGULATORY_ATTRIBUTES"]),
    ("TRADES", "MARKET_DATA_INGEST", ["REGULATORY_ATTRIBUTES"]),
    ("TRADE_REFERENCE_PRICES", "MARKET_DATA_INGEST", []),
    ("CORPORATE_ACTIONS", "MARKET_DATA_INGEST", []),
    ("POSITIONS", "MARKET_DATA_INGEST", []),
    ("TRANSACTION_REPORTS", "MARKET_DATA_INGEST", []),
    ("DETECTOR_CALIBRATION", "ACCOUNTADMIN", ["PARAMS"]),
]


def main():
    conn = connect(admin=True)  # DETECTOR_CALIBRATION step needs ACCOUNTADMIN; other roles switched per-table
    cur = conn.cursor()
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")

    for cfg in (US_CONFIG, EU_CONFIG):
        print(f"=== {cfg.jurisdiction_id} ===")
        tables = generate(cfg, seed=42, n_orders=1500)
        for table, role, json_columns in LOAD_PLAN:
            cur.execute(f"USE ROLE {role}")
            n = load_table(cur, table, tables[table], json_columns)
            print(f"  {table}: {n} rows via {role}")

    cur.execute("USE ROLE ACCOUNTADMIN")
    cur.execute("SELECT JURISDICTION_ID, COUNT(*) FROM TRADES GROUP BY 1 ORDER BY 1")
    print("\nTRADES row counts by jurisdiction:")
    for row in cur.fetchall():
        print(" ", row)
    conn.close()


if __name__ == "__main__":
    main()
