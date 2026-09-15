#!/usr/bin/env python3
"""Live RBAC verification -- the "22-check" discipline from architecture.md's Governance-gate
section, run for real against Snowflake rather than left as a written checklist for a human.

For each functional role, runs positive checks (things that role must be able to do) and
negative checks (things it must NOT be able to do) and reports pass/fail against expectation.
All test rows use JURISDICTION_ID/OBLIGATION_ID/etc. prefixed 'ZZTEST' so they're identifiable
and safe to clean up afterward with ACCOUNTADMIN (the only role with that latitude -- none of
the five functional roles are ever granted UPDATE/DELETE, so cleanup can't and shouldn't be done
as any of them).
"""
import sys

sys.path.insert(0, "scripts")
from run_sql import connect

CHECKS = []  # (role, description, sql, expect) where expect is "pass" or "fail"

NOW = "CURRENT_TIMESTAMP()::TIMESTAMP_NTZ"

CHECKS += [
    ("ANALYST_READ", "SELECT RULE_CORPUS", "SELECT * FROM RULE_CORPUS LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT APPROVED_OBLIGATIONS", "SELECT * FROM APPROVED_OBLIGATIONS LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT TRADES", "SELECT * FROM TRADES LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT ORDERS_CURRENT", "SELECT * FROM ORDERS_CURRENT LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT REPORT_TEMPLATE_COVERAGE", "SELECT * FROM REPORT_TEMPLATE_COVERAGE LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT OBLIGATION_RULE_CHUNKS_CURRENT", "SELECT * FROM OBLIGATION_RULE_CHUNKS_CURRENT LIMIT 1", "pass"),
    ("ANALYST_READ", "SELECT base OBLIGATION_MAP (must fail -- Fix #6 gate)", "SELECT * FROM OBLIGATION_MAP LIMIT 1", "fail"),
    ("ANALYST_READ", "SELECT AUDIT_LOG (must fail -- no role gets SELECT)", "SELECT * FROM AUDIT_LOG LIMIT 1", "fail"),
    ("ANALYST_READ", "SELECT DETECTOR_CALIBRATION (must fail -- not directly granted)", "SELECT * FROM DETECTOR_CALIBRATION LIMIT 1", "fail"),
    ("ANALYST_READ", "INSERT TRADES (must fail -- read-only role)",
     f"INSERT INTO TRADES SELECT 'ZZTEST_T1','ZZ','ZZV',NULL,'ZZI',{NOW},1,'USD',1,'ZZP',NULL,'continuous',NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "fail"),
]

CHECKS += [
    ("GOVERNANCE_WRITE", "Direct INSERT OBLIGATION_MAP (must fail -- Fix #6/#30 gate-bypass close, review finding 1)",
     f"INSERT INTO OBLIGATION_MAP SELECT 'ZZTEST_OB_BYPASS','ZZ','attempted raw insert','TRADES','TRADE_ID','wash_trading','approved',{NOW},'rbactest',{NOW},'rbactest'",
     "fail"),
    ("GOVERNANCE_WRITE", "CALL SP_PROPOSE_OBLIGATION (the real, structural write path)",
     "CALL SP_PROPOSE_OBLIGATION('ZZTEST_OB1', 'ZZ', 'rbac test obligation', NULL, NULL, NULL)",
     "pass"),
    ("GOVERNANCE_WRITE", "SELECT base OBLIGATION_MAP (can see proposed rows)", "SELECT * FROM OBLIGATION_MAP WHERE OBLIGATION_ID = 'ZZTEST_OB1'", "pass"),
    ("GOVERNANCE_WRITE", "INSERT RULE_CORPUS",
     f"INSERT INTO RULE_CORPUS SELECT 'ZZTEST_RC1','ZZ','test doc','1','test text','original','en',{NOW},'rbactest',{NOW},'rbactest'",
     "pass"),
    ("GOVERNANCE_WRITE", "INSERT REPORT_TEMPLATES",
     f"INSERT INTO REPORT_TEMPLATES SELECT 'ZZ','test_report','test_field',1,'proposed',NULL,NULL,TRUE,{NOW},'rbactest',{NOW},'rbactest'",
     "pass"),
    ("GOVERNANCE_WRITE", "UPDATE OBLIGATION_MAP (must fail -- append-only, no UPDATE ever)",
     "UPDATE OBLIGATION_MAP SET STATUS = 'approved' WHERE OBLIGATION_ID = 'ZZTEST_OB1'", "fail"),
    ("GOVERNANCE_WRITE", "SELECT TRADES (must fail -- no market-data read access)", "SELECT * FROM TRADES LIMIT 1", "fail"),
    ("GOVERNANCE_WRITE", "INSERT TRADES (must fail -- wrong role for market data)",
     f"INSERT INTO TRADES SELECT 'ZZTEST_T2','ZZ','ZZV',NULL,'ZZI',{NOW},1,'USD',1,'ZZP',NULL,'continuous',NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "fail"),
]

CHECKS += [
    ("AUDIT_INSERT", "INSERT AUDIT_LOG",
     f"INSERT INTO AUDIT_LOG SELECT 'ZZTEST_RUN1','tester','test',NULL,NULL,NULL,NULL,NULL,TRUE,NULL,NULL,NULL,NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "pass"),
    ("AUDIT_INSERT", "SELECT AUDIT_LOG (must fail -- insert-only, no SELECT even on own writes)", "SELECT * FROM AUDIT_LOG LIMIT 1", "fail"),
    ("AUDIT_INSERT", "INSERT TRADES (must fail -- wrong role)",
     f"INSERT INTO TRADES SELECT 'ZZTEST_T3','ZZ','ZZV',NULL,'ZZI',{NOW},1,'USD',1,'ZZP',NULL,'continuous',NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "fail"),
]

CHECKS += [
    ("MARKET_DATA_INGEST", "INSERT TRADES",
     f"INSERT INTO TRADES SELECT 'ZZTEST_T4','ZZ','ZZV',NULL,'ZZI',{NOW},1,'USD',1,'ZZP',NULL,'continuous',NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "pass"),
    ("MARKET_DATA_INGEST", "SELECT REPORT_TEMPLATES_CURRENT (its one SELECT grant)", "SELECT * FROM REPORT_TEMPLATES_CURRENT LIMIT 1", "pass"),
    ("MARKET_DATA_INGEST", "SELECT TRADES (must fail -- insert-only, no base-table read)", "SELECT * FROM TRADES LIMIT 1", "fail"),
    ("MARKET_DATA_INGEST", "UPDATE TRADES (must fail -- append-only, no UPDATE ever)",
     "UPDATE TRADES SET PRICE = 2 WHERE TRADE_ID = 'ZZTEST_T4'", "fail"),
]

CHECKS += [
    ("OFFICER_SIGNOFF", "CALL SP_RECORD_SIGNOFF (SIGNOFF_BY now bound to CURRENT_USER(), not caller-supplied)",
     "CALL SP_RECORD_SIGNOFF('ZZTEST_RUN1', 'approved')", "pass"),
    ("OFFICER_SIGNOFF", "INSERT AUDIT_LOG directly (must fail -- no direct table grant)",
     f"INSERT INTO AUDIT_LOG SELECT 'ZZTEST_RUN2','tester','test',NULL,NULL,NULL,NULL,NULL,TRUE,NULL,NULL,NULL,NULL,{NOW},'rbactest',{NOW},'rbactest'",
     "fail"),
    ("OFFICER_SIGNOFF", "SELECT AUDIT_LOG (must fail)", "SELECT * FROM AUDIT_LOG LIMIT 1", "fail"),
]


def main():
    conn = connect()
    cur = conn.cursor()
    results = []
    current_role = None
    for role, desc, sql, expect in CHECKS:
        if role != current_role:
            cur.execute(f"USE ROLE {role}")
            cur.execute("USE SECONDARY ROLES NONE")  # isolate this role -- this account's user has
            # DEFAULT_SECONDARY_ROLES=ALL, which otherwise activates every granted role at once
            # regardless of USE ROLE, making negative checks meaningless.
            cur.execute("USE DATABASE VIGIL")
            cur.execute("USE SCHEMA CORE")
            current_role = role
        err = None
        try:
            cur.execute(sql)
            outcome = "pass"
        except Exception as e:
            outcome = "fail"
            err = str(e).splitlines()[0]
        verdict = "OK" if outcome == expect else "MISMATCH"
        line = f"[{verdict}] {role}: {desc} -> expected {expect}, got {outcome}"
        if err is not None:
            line += f" ({err})"
        results.append((verdict, line))
        print(line)

    cur.execute("USE ROLE ACCOUNTADMIN")

    # OFFICER_SIGNOFF identity check (review finding: SP_RECORD_SIGNOFF's SIGNOFF_BY is now
    # un-spoofable via CURRENT_USER(), but that only means something if the role itself is only
    # ever granted to a real human -- never to an automation identity). EXPECTED_HUMAN_SIGNOFF_
    # USERS is the allow-list; anything else granted this role is a MISMATCH.
    EXPECTED_HUMAN_SIGNOFF_USERS = {"ASHWINISHARMA0807"}
    cur.execute("SHOW GRANTS OF ROLE OFFICER_SIGNOFF")
    grantee_users = {row[3] for row in cur.fetchall() if row[2] == "USER"}
    unexpected = grantee_users - EXPECTED_HUMAN_SIGNOFF_USERS
    missing = EXPECTED_HUMAN_SIGNOFF_USERS - grantee_users
    if unexpected or missing:
        verdict = "MISMATCH"
    else:
        verdict = "OK"
    line = (f"[{verdict}] OFFICER_SIGNOFF grantees are exactly the expected human user(s) "
            f"-> expected {sorted(EXPECTED_HUMAN_SIGNOFF_USERS)}, got {sorted(grantee_users)}")
    results.append((verdict, line))
    print(line)

    mismatches = [r for v, r in results if v == "MISMATCH"]
    print(f"\n{len(results)} checks run, {len(mismatches)} mismatch(es).")
    conn.close()
    return len(mismatches)


if __name__ == "__main__":
    sys.exit(main())
