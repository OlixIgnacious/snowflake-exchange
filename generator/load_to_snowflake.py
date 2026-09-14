"""Loads generator output into VIGIL.CORE via the actual RBAC roles -- not ACCOUNTADMIN for
market data, on purpose, so this also exercises MARKET_DATA_INGEST/GOVERNANCE_WRITE's real
grants rather than bypassing them. One known, flagged gap: no functional role in
architecture.md's RBAC section is ever granted INSERT on DETECTOR_CALIBRATION -- calibration
seeding here uses ACCOUNTADMIN as an admin/ops bootstrap action, the same category as DDL itself,
until the project defines who owns that write path.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from generator.generate import generate
from generator.jurisdiction_config import JAPAN_CONFIG
from run_sql import connect

# (table, role, json_columns)
LOAD_PLAN = [
    ("JURISDICTIONS", "MARKET_DATA_INGEST", []),
    ("VENUES", "MARKET_DATA_INGEST", []),
    ("BENEFICIAL_OWNERS", "MARKET_DATA_INGEST", []),
    ("INSTRUMENTS", "MARKET_DATA_INGEST", []),
    ("MARKET_PARTICIPANTS", "MARKET_DATA_INGEST", []),
    ("ORDERS", "MARKET_DATA_INGEST", ["REGULATORY_ATTRIBUTES"]),
    ("TRADES", "MARKET_DATA_INGEST", ["REGULATORY_ATTRIBUTES"]),
    ("POSITIONS", "MARKET_DATA_INGEST", []),
    ("TRANSACTION_REPORTS", "MARKET_DATA_INGEST", []),
    ("REPORT_TEMPLATES", "GOVERNANCE_WRITE", []),
    ("DETECTOR_CALIBRATION", "ACCOUNTADMIN", ["PARAMS"]),  # flagged gap, see module docstring
]


def load_table(cur, table: str, rows: list[dict], json_columns: list[str]):
    if not rows:
        return 0
    columns = [c for c in rows[0].keys() if c != "CALIBRATION_ID"]  # never insert the autoincrement PK
    value_exprs = [f"PARSE_JSON(%({c})s)" if c in json_columns else f"%({c})s" for c in columns]
    sql = f"INSERT INTO {table} ({', '.join(columns)}) SELECT {', '.join(value_exprs)}"

    prepared = []
    for row in rows:
        r = dict(row)
        for jc in json_columns:
            if r.get(jc) is not None:
                r[jc] = json.dumps(r[jc])
        prepared.append(r)

    cur.executemany(sql, prepared)
    return len(prepared)


def main():
    tables = generate(JAPAN_CONFIG, seed=42, n_orders=1500)
    conn = connect()
    cur = conn.cursor()
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")

    current_role = None
    for table, role, json_columns in LOAD_PLAN:
        if role != current_role:
            cur.execute(f"USE ROLE {role}")
            cur.execute("USE SECONDARY ROLES NONE")
            current_role = role
        n = load_table(cur, table, tables[table], json_columns)
        print(f"[{role}] {table}: inserted {n} rows")

    conn.close()


if __name__ == "__main__":
    main()
