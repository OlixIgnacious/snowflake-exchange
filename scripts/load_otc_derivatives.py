#!/usr/bin/env python3
"""One-off load of the gap-8 MVP's new OTC-derivatives content into the already-live VIGIL.CORE
-- same pattern as scripts/restate_trade_reference_prices.py: regenerate the same deterministic
seed=42/n_orders=1500 JAPAN_CONFIG dataset, extract only the NEW rows the generator's OTC-
derivatives block added, and load exactly those (plus one real milestoned restatement for the
three participants that gained an LEI). Does not touch anything already live -- the equity
baseline is unchanged (same seed, same generation order up to the new block).

New rows are isolated by content, not by count/index, so this is robust regardless of how many
equity rows already exist live:
  - VENUES: only DDRJ (a brand-new VENUE_ID -- everything else already exists).
  - INSTRUMENTS: only IDRV01 (brand-new INSTRUMENT_ID).
  - DERIVATIVE_PRODUCT_ATTRIBUTES / DERIVATIVE_TRADE_DETAILS: brand-new tables, load every row.
  - TRADES: only rows at VENUE_ID='DDRJ' (DDRJ never hosts an equity trade -- see
    generator/generate.py's equity_eligible_venues exclusion).
  - TRANSACTION_REPORTS: only REPORT_TYPE='otc_derivative_transaction_report' rows.
  - MARKET_PARTICIPANTS: NOT a plain insert -- the 3 participants that gained an LEI already have
    a live row (PARTICIPANT_ID, JURISDICTION_ID); this is a real milestoned restatement, same
    (PARTICIPANT_ID, JURISDICTION_ID), CREATED_AT/CREATED_BY/PARTICIPANT_TYPE/BENEFICIAL_OWNER_ID
    carried forward from the live row, LOADED_AT = now, LEI newly populated -- never an UPDATE.

Usage: .venv/bin/python3 scripts/load_otc_derivatives.py
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
    now = datetime.utcnow()

    new_venues = [v for v in tables["VENUES"] if v["VENUE_ID"] == "DDRJ"]
    new_instruments = [i for i in tables["INSTRUMENTS"] if i["INSTRUMENT_ID"] == "IDRV01"]
    new_product_attrs = tables["DERIVATIVE_PRODUCT_ATTRIBUTES"]
    new_trade_details = tables["DERIVATIVE_TRADE_DETAILS"]
    new_trades = [t for t in tables["TRADES"] if t["VENUE_ID"] == "DDRJ"]
    new_reports = [r for r in tables["TRANSACTION_REPORTS"] if r["REPORT_TYPE"] == "otc_derivative_transaction_report"]
    lei_participant_ids = [p["PARTICIPANT_ID"] for p in tables["MARKET_PARTICIPANTS"] if p["LEI"]]
    lei_by_participant = {p["PARTICIPANT_ID"]: p["LEI"] for p in tables["MARKET_PARTICIPANTS"] if p["LEI"]}

    assert len(new_venues) == 1
    assert len(new_instruments) == 1
    assert len(new_product_attrs) == 1
    assert len(new_trade_details) == 2
    assert len(new_trades) == 2
    assert len(new_reports) == 2
    assert len(lei_participant_ids) == 3

    conn = connect()
    cur = conn.cursor()
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")

    # Read while still on the default VIGIL_AUTOMATION role (inherits ANALYST_READ's SELECT
    # grant) -- MARKET_DATA_INGEST itself is INSERT-only, no base-table/view SELECT (Fix #7).
    # MARKET_PARTICIPANTS restatement: carry forward the live row's own CREATED_AT/CREATED_BY/
    # PARTICIPANT_TYPE/BENEFICIAL_OWNER_ID, only adding LEI + a new LOADED_AT (Fix #10 discipline).
    placeholders = ", ".join(["%s"] * len(lei_participant_ids))
    cur.execute(
        f"SELECT PARTICIPANT_ID, JURISDICTION_ID, PARTICIPANT_TYPE, BENEFICIAL_OWNER_ID, CREATED_AT, CREATED_BY "
        f"FROM MARKET_PARTICIPANTS_CURRENT WHERE JURISDICTION_ID = 'JP' AND PARTICIPANT_ID IN ({placeholders})",
        lei_participant_ids,
    )
    live_rows = cur.fetchall()
    assert len(live_rows) == 3, f"expected 3 live MARKET_PARTICIPANTS rows, found {len(live_rows)}"
    restated_participants = []
    for pid, jid, ptype, boid, created_at, created_by in live_rows:
        restated_participants.append({
            "PARTICIPANT_ID": pid, "JURISDICTION_ID": jid, "PARTICIPANT_TYPE": ptype,
            "BENEFICIAL_OWNER_ID": boid, "LEI": lei_by_participant[pid],
            "CREATED_AT": created_at, "CREATED_BY": created_by,
            "LOADED_AT": now, "LOADED_BY": "generator_restatement_gap8_mvp",
        })

    cur.execute("USE ROLE MARKET_DATA_INGEST")
    plan = [
        ("VENUES", new_venues, []),
        ("INSTRUMENTS", new_instruments, []),
        ("DERIVATIVE_PRODUCT_ATTRIBUTES", new_product_attrs, []),
        ("MARKET_PARTICIPANTS", restated_participants, []),
        ("TRADES", new_trades, ["REGULATORY_ATTRIBUTES"]),
        ("DERIVATIVE_TRADE_DETAILS", new_trade_details, []),
        ("TRANSACTION_REPORTS", new_reports, []),
    ]
    for table, rows, json_columns in plan:
        n = load_table(cur, table, rows, json_columns)
        print(f"{table}: inserted {n} row(s)")

    conn.close()


if __name__ == "__main__":
    main()
