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


def connect(admin: bool = False):
    """admin=True overrides SNOWFLAKE_ROLE to ACCOUNTADMIN for this connection only -- reserved
    for actual schema/RBAC changes (DDL, GRANT/REVOKE). Routine work (seeding content, running
    detectors/procedures, generator loads) uses SNOWFLAKE_ROLE as configured (VIGIL_AUTOMATION,
    scoped to exactly the 4 non-signoff functional roles -- sql/rbac/07_vigil_automation_role.sql)
    so it no longer runs as the account's most-privileged identity by default."""
    load_dotenv()
    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_ROLE", "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_PRIVATE_KEY_PATH"]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        sys.exit(f"Missing required env vars: {', '.join(missing)} (check .env)")

    role = "ACCOUNTADMIN" if admin else os.environ["SNOWFLAKE_ROLE"]
    if admin:
        print("!! --admin: connecting as ACCOUNTADMIN, not the configured SNOWFLAKE_ROLE -- "
              "use only for actual DDL/RBAC changes !!")

    private_key_der = load_private_key(os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"])
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=role,
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


def log_automation_run(conn, script_paths: str, result_summary: str):
    """Writes one row to AUDIT_LOG via SP_LOG_AUTOMATION_RUN (sql/procedures/
    sp_log_automation_run.sql) -- the real, RBAC-governed, append-only run log that closes the
    review finding that NOTES.md (gitignored, plaintext, hand-maintained) was the *only* record
    of what got executed. Fails soft: a logging failure must never abort or mask the outcome of
    the actual SQL that was run."""
    try:
        cur = conn.cursor()
        cur.execute("USE DATABASE VIGIL")
        cur.execute("USE SCHEMA CORE")
        # CURRENT_ROLE() here, on the caller's side -- captured before calling into the
        # EXECUTE AS OWNER procedure below, whose own CURRENT_ROLE() would otherwise report the
        # procedure owner's role (ACCOUNTADMIN), not whichever role actually issued this CALL.
        cur.execute("SELECT CURRENT_ROLE()")
        caller_role = cur.fetchone()[0]
        cur.execute("CALL SP_LOG_AUTOMATION_RUN(%s, %s, %s)", (script_paths, result_summary, caller_role))
    except Exception as e:
        print(f"(warning: could not log this run to AUDIT_LOG: {str(e).splitlines()[0]})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*", help=".sql files to run, in order")
    parser.add_argument("--check", action="store_true", help="connectivity check only")
    parser.add_argument("--admin", action="store_true",
                         help="connect as ACCOUNTADMIN instead of the configured SNOWFLAKE_ROLE -- "
                              "reserved for actual DDL/RBAC changes, not routine work")
    args = parser.parse_args()

    conn = connect(admin=args.admin)
    try:
        run_check(conn)
        if args.check:
            return
        try:
            for path in args.files:
                run_file(conn, path)
            print("All files executed successfully.")
            log_automation_run(conn, ", ".join(args.files), "success")
        except Exception as e:
            log_automation_run(conn, ", ".join(args.files), f"FAILED: {str(e).splitlines()[0]}")
            raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
