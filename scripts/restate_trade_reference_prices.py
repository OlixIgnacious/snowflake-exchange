#!/usr/bin/env python3
"""One-off restatement of TRADE_REFERENCE_PRICES with the VWAP-based formula (review finding:
the previous trade-price-plus-noise formula was circular by construction). Regenerates the same
deterministic seed=42/n_orders=1500 dataset generator/load_to_snowflake.py originally loaded,
takes only the new TRADE_REFERENCE_PRICES rows, and inserts them as a new LOADED_AT version --
same (TRADE_ID, VENUE_ID) key, later LOADED_AT, never an UPDATE (Fix #15). Does NOT touch any
other table -- everything else in VIGIL.CORE is already loaded and unaffected by this formula
change.

Usage: .venv/bin/python3 scripts/restate_trade_reference_prices.py
"""
from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from generator.generate import generate
from generator.jurisdiction_config import JAPAN_CONFIG
from generator.load_to_snowflake import load_table
from run_sql import connect


def main():
    tables = generate(JAPAN_CONFIG, seed=42, n_orders=1500)
    rows = tables["TRADE_REFERENCE_PRICES"]
    now = datetime.utcnow()
    for r in rows:
        r["LOADED_AT"] = now  # restatement timestamp -- CREATED_AT stays as generated (preserved)

    conn = connect()
    cur = conn.cursor()
    cur.execute("USE ROLE MARKET_DATA_INGEST")
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")

    cur.execute("SELECT COUNT(*) FROM TRADE_REFERENCE_PRICES_CURRENT")
    before = cur.fetchone()[0]

    n = load_table(cur, "TRADE_REFERENCE_PRICES", rows, [])
    print(f"Inserted {n} restated TRADE_REFERENCE_PRICES rows (new LOADED_AT={now}).")

    cur.execute("SELECT COUNT(*) FROM TRADE_REFERENCE_PRICES_CURRENT")
    after = cur.fetchone()[0]
    print(f"TRADE_REFERENCE_PRICES_CURRENT row count: before={before}, after={after} "
          f"(should match -- same keys, new version, not additional rows).")
    conn.close()


if __name__ == "__main__":
    main()
