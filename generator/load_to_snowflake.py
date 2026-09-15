"""Loads generator output into VIGIL.CORE via the actual RBAC roles -- not ACCOUNTADMIN for
market data, on purpose, so this also exercises MARKET_DATA_INGEST/GOVERNANCE_WRITE's real
grants rather than bypassing them. One known, flagged gap: no functional role in
architecture.md's RBAC section is ever granted INSERT on DETECTOR_CALIBRATION -- calibration
seeding here uses ACCOUNTADMIN as an admin/ops bootstrap action, the same category as DDL itself,
until the project defines who owns that write path.

Running this twice against a non-empty VIGIL.CORE will duplicate rows -- Snowflake doesn't
enforce the declared primary keys (see sql/ddl/'s file headers). It's meant for a fresh/empty
schema; there's no reset/upsert path here by design, matching this project's append-only
discipline (a reset would need TRACKER.md-logged, human-reviewed cleanup, not a script default).
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
    ("TRADE_REFERENCE_PRICES", "MARKET_DATA_INGEST", []),
    ("CORPORATE_ACTIONS", "MARKET_DATA_INGEST", []),
    ("POSITIONS", "MARKET_DATA_INGEST", []),
    ("TRANSACTION_REPORTS", "MARKET_DATA_INGEST", []),
    ("REPORT_TEMPLATES", "GOVERNANCE_WRITE", []),
    ("DETECTOR_CALIBRATION", "ACCOUNTADMIN", ["PARAMS"]),  # flagged gap, see module docstring
]


def load_table(cur, table: str, rows: list[dict], json_columns: list[str]):
    if not rows:
        return 0
    columns = [c for c in rows[0].keys() if c != "CALIBRATION_ID"]  # never insert the autoincrement PK

    # Only wrap a column in PARSE_JSON if it actually has a non-null value somewhere in this
    # table's rows -- a column that's None for every row goes through the fast bulk executemany
    # path as a plain bind param (binds correctly to SQL NULL there). Only a column with real
    # values needs the slower per-row path below.
    columns_needing_json = [c for c in json_columns if any(r.get(c) is not None for r in rows)]

    prepared = []
    for row in rows:
        r = dict(row)
        for jc in columns_needing_json:
            if r.get(jc) is not None:
                r[jc] = json.dumps(r[jc])
        prepared.append(r)

    if columns_needing_json:
        # Snowflake's INSERT ... VALUES (...) clause rejects a function call like PARSE_JSON()
        # as an expression there at all -- confirmed even for a real non-null value, single row,
        # no batching involved. INSERT ... SELECT ... does allow it, so this path uses SELECT and
        # one row per execute() (no executemany -- that combination fails separately with
        # "Failed to rewrite multi-row insert", since executemany's client-side bulk rewrite only
        # recognizes the VALUES form). Only reached for a column with a real non-null value
        # somewhere in the table -- for this dataset, only DETECTOR_CALIBRATION.PARAMS (~12
        # rows), so per-row execution has no real perf cost. A column that's None everywhere
        # (ORDERS/TRADES.REGULATORY_ATTRIBUTES, thousands of rows here) takes the fast bulk
        # VALUES + executemany path in the else branch instead.
        select_exprs = [
            f"IFF(%({c})s IS NULL, NULL, PARSE_JSON(%({c})s))" if c in columns_needing_json else f"%({c})s"
            for c in columns
        ]
        sql = f"INSERT INTO {table} ({', '.join(columns)}) SELECT {', '.join(select_exprs)}"
        for r in prepared:
            cur.execute(sql, r)
    else:
        value_exprs = [f"%({c})s" for c in columns]
        sql = f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join(value_exprs)})"
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
