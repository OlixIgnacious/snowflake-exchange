#!/usr/bin/env python3
"""CLI wrapper for the `rule_interpret` skill (skills/rule_interpret.py) -- was import-only until
now (see NOTES.md/docs/queries_by_workflow.md). Reads real APPROVED_OBLIGATIONS/RULE_CORPUS data
(sql/governance/01_rule_corpus_and_obligations_seed.sql) and runs the actual gap-analysis
mechanism against it, instead of the mechanism only ever being exercised by unit tests with
made-up inputs.

Usage:
    .venv/bin/python3 scripts/run_rule_gap_analysis.py --jurisdiction JP \
        --rule-chunk-id JP-FIEA-159-1-I \
        --required-concepts wash_trading,circuit_breaker_compliance
"""
import argparse
import sys

sys.path.insert(0, ".")

from scripts.run_sql import connect
from skills.rule_interpret import find_gaps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jurisdiction", required=True)
    parser.add_argument("--rule-chunk-id", required=True,
                         help="RULE_CORPUS chunk this reading is derived from (for citation only).")
    parser.add_argument("--required-concepts", required=True,
                         help="Comma-separated detector-name concepts this rule chunk's plain "
                              "reading requires an obligation mapping for.")
    args = parser.parse_args()

    required_concepts = {c.strip() for c in args.required_concepts.split(",") if c.strip()}

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("USE ROLE ANALYST_READ")
        cur.execute("USE DATABASE VIGIL")
        cur.execute("USE SCHEMA CORE")

        cur.execute(
            "SELECT DOC_TITLE, SECTION_REF, CHUNK_TEXT FROM RULE_CORPUS_CURRENT "
            "WHERE CHUNK_ID = %s AND JURISDICTION_ID = %s",
            (args.rule_chunk_id, args.jurisdiction),
        )
        chunk_row = cur.fetchone()
        if chunk_row is None:
            sys.exit(f"No RULE_CORPUS chunk '{args.rule_chunk_id}' found for {args.jurisdiction}.")
        doc_title, section_ref, chunk_text = chunk_row

        cur.execute(
            "SELECT DETECTOR_NAME FROM APPROVED_OBLIGATIONS WHERE JURISDICTION_ID = %s",
            (args.jurisdiction,),
        )
        approved_detector_names = {r[0] for r in cur.fetchall()}
    finally:
        conn.close()

    print(f"Rule chunk: {args.rule_chunk_id}")
    print(f"  {doc_title} -- {section_ref}")
    print(f"  \"{chunk_text[:200]}{'...' if len(chunk_text) > 200 else ''}\"")
    print(f"Approved obligation coverage for {args.jurisdiction}: {sorted(approved_detector_names)}")
    print(f"Required concepts (caller-supplied reading of the rule): {sorted(required_concepts)}")
    print()

    gaps = find_gaps(required_concepts, approved_detector_names, args.rule_chunk_id)
    if not gaps:
        print("No gaps -- every required concept already has an APPROVED obligation mapping.")
    else:
        print(f"{len(gaps)} gap(s) found:")
        for gap in gaps:
            print(f"  - {gap.detector_name}: {gap.reason}")


if __name__ == "__main__":
    main()
