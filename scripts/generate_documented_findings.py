#!/usr/bin/env python3
"""Generates a real documented finding -- an assurance verdict, not a count -- for every
currently-flagged TRANSACTION_REPORTS row in a jurisdiction/report_type, using the already-tested
skills/assure_report.py + ingest/report_adaptor.py logic directly (not a SQL re-implementation --
REPORT_TEMPLATES.SOURCE_MAPPING is free text pointing at an arbitrary source column, Fix #9's
documented unenforceable-in-SQL limitation, which is exactly why the mapping logic lives in
Python and stays there).

Closes the gap TRACKER.md flagged after the surveillance audit trail was built:
SP_LOG_SURVEILLANCE_RUN only logs a *count* of flagged reports (the evidence); this script
produces the actual per-report *documented finding* (a real assurance verdict, with reasons),
written to AUDIT_LOG via SP_LOG_DOCUMENTED_FINDING -- queryable through DOCUMENTED_FINDINGS_LOG
(sql/detectors/07_surveillance_audit_log.sql).

Usage:
    .venv/bin/python3 scripts/generate_documented_findings.py --jurisdiction JP --report-type transaction_report
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ingest.report_adaptor import TemplateField
from skills.assure_report import assure
from run_sql import connect


def main(jurisdiction_id: str, report_type: str) -> None:
    conn = connect()
    cur = conn.cursor()
    cur.execute("USE ROLE ACCOUNTADMIN")
    cur.execute("USE SECONDARY ROLES NONE")
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")

    cur.execute(
        """
        SELECT REPORT_ID, TRADE_ID
        FROM REPORTING_TIMELINESS_SIGNALS
        WHERE JURISDICTION_ID = %(jid)s AND REPORT_TYPE = %(rtype)s
          AND (IS_INCOMPLETE OR IS_MISMATCHED OR IS_LATE_SUBMISSION OR IS_OVERDUE_UNSUBMITTED)
        """,
        {"jid": jurisdiction_id, "rtype": report_type},
    )
    flagged = cur.fetchall()
    print(f"{len(flagged)} flagged report(s) for {jurisdiction_id}/{report_type}")
    if not flagged:
        conn.close()
        return

    cur.execute(
        """
        SELECT FIELD_NAME, SOURCE_MAPPING, FIELD_FORMAT, IS_REQUIRED, STATUS
        FROM REPORT_TEMPLATES_CURRENT
        WHERE JURISDICTION_ID = %(jid)s AND REPORT_TYPE = %(rtype)s
        """,
        {"jid": jurisdiction_id, "rtype": report_type},
    )
    templates = [
        TemplateField(field_name, source_mapping, field_format, bool(is_required), status)
        for field_name, source_mapping, field_format, is_required, status in cur.fetchall()
    ]

    cur.execute(
        """
        SELECT PCT_REQUIRED_FIELDS_MAPPED
        FROM REPORT_TEMPLATE_COVERAGE
        WHERE JURISDICTION_ID = %(jid)s AND REPORT_TYPE = %(rtype)s
        """,
        {"jid": jurisdiction_id, "rtype": report_type},
    )
    pct_row = cur.fetchone()
    pct_mapped = float(pct_row[0]) if pct_row else 0.0

    for report_id, trade_id in flagged:
        cur.execute(
            "SELECT PRICE, VOLUME, INSTRUMENT_ID FROM TRADES WHERE TRADE_ID = %(tid)s",
            {"tid": trade_id},
        )
        trade_row = cur.fetchone()
        price, volume, instrument_id = trade_row if trade_row else (None, None, None)
        canonical_row = {
            "TRADES.PRICE": price,
            "TRADES.VOLUME": volume,
            "TRADES.INSTRUMENT_ID": instrument_id,
        }

        verdict = assure(templates, canonical_row, pct_mapped)

        cur.execute(
            "CALL SP_LOG_DOCUMENTED_FINDING(%(rid)s, %(ready)s, %(fc)s, %(unresolved)s, %(gap)s, %(reasons)s)",
            {
                "rid": report_id,
                "ready": verdict.ready_to_submit,
                "fc": verdict.fields_complete,
                "unresolved": json.dumps(verdict.unresolved_required_fields),
                "gap": json.dumps(verdict.gap_fields),
                "reasons": json.dumps(verdict.reasons),
            },
        )
        run_id = cur.fetchone()[0]
        print(f"  {report_id}: ready_to_submit={verdict.ready_to_submit} -> AUDIT_LOG run {run_id}")

    conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--jurisdiction", default="JP")
    parser.add_argument("--report-type", default="transaction_report")
    args = parser.parse_args()
    main(args.jurisdiction, args.report_type)
