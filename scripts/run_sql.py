#!/usr/bin/env python3
"""Run one or more .sql files against Snowflake using key-pair auth.

Credentials come from environment variables (loaded from .env, gitignored, never committed) --
see CLAUDE.md's "SQL execution" section. Prints a per-statement result summary; on any error,
stops and reports the failing statement so it can be logged in NOTES.md and fixed.

Usage:
    .venv/bin/python3 scripts/run_sql.py sql/ddl/00_setup.sql sql/ddl/01_reference_data.sql ...
    .venv/bin/python3 scripts/run_sql.py --check   # connectivity check only, no file needed
"""
import argparse
import os
import sys

from cryptography.hazmat.primitives import serialization
from dotenv import load_dotenv
import snowflake.connector


def load_private_key(path: str) -> bytes:
    with open(path, "rb") as f:
        pem_bytes = f.read()
    key = serialization.load_pem_private_key(pem_bytes, password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def connect():
    load_dotenv()
    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_ROLE", "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_PRIVATE_KEY_PATH"]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        sys.exit(f"Missing required env vars: {', '.join(missing)} (check .env)")

    private_key_der = load_private_key(os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"])
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        private_key=private_key_der,
    )


def run_check(conn):
    cur = conn.cursor()
    cur.execute("SELECT CURRENT_VERSION(), CURRENT_ACCOUNT(), CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE()")
    version, account, user, role, warehouse = cur.fetchone()
    print(f"Connected. Snowflake {version} | account={account} user={user} role={role} warehouse={warehouse}")


def run_file(conn, path: str):
    with open(path, "r") as f:
        sql_text = f.read()
    print(f"--- {path} ---")
    cursors = conn.execute_string(sql_text)
    for cur in cursors:
        stmt = cur.query.strip().splitlines()[0][:100] if cur.query else ""
        print(f"  OK: {stmt}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*", help=".sql files to run, in order")
    parser.add_argument("--check", action="store_true", help="connectivity check only")
    args = parser.parse_args()

    conn = connect()
    try:
        run_check(conn)
        if args.check:
            return
        for path in args.files:
            run_file(conn, path)
        print("All files executed successfully.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
