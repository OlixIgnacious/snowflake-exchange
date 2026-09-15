-- Closes review finding "ACCOUNTADMIN is the real write identity, not the 5 functional roles":
-- every DDL/detector/RBAC script in this repo, and the automated connection's own .env
-- (SNOWFLAKE_ROLE), ran as ACCOUNTADMIN -- the account's most-privileged role. The "no functional
-- role ever gets UPDATE/DELETE" guarantee (milestoning discipline rule 3) only ever held against
-- the 5 named functional roles, which nobody actually used for day-to-day writes -- it did not
-- hold against the identity actually doing the work.
--
-- VIGIL_AUTOMATION is the union of the 4 non-signoff functional roles' privileges, nothing more --
-- no DDL, no UPDATE/DELETE anywhere (it inherits none, since none of its 4 member roles have any).
-- OFFICER_SIGNOFF is deliberately excluded: that role exists specifically to be held only by a
-- named human (verified live in scripts/verify_rbac.py), never by an automation identity, so
-- bundling it into VIGIL_AUTOMATION would defeat the point.
--
-- This does not replace ACCOUNTADMIN for actual schema/RBAC changes (DDL, new GRANT/REVOKE
-- statements) -- those still need elevated privileges by nature. What changes is that ROUTINE
-- work (seeding governance content, running detectors/procedures, generator loads, ad hoc
-- queries) now runs as VIGIL_AUTOMATION, scoped to exactly what a functional role can do, not as
-- the account's broadest identity. scripts/run_sql.py's new --admin flag switches to ACCOUNTADMIN
-- explicitly, for that run only, and says so loudly.

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS VIGIL_AUTOMATION
    COMMENT = 'Scoped automation identity for routine VIGIL.CORE work (2026-09-15) -- union of MARKET_DATA_INGEST/GOVERNANCE_WRITE/AUDIT_INSERT/ANALYST_READ, deliberately excluding OFFICER_SIGNOFF. Used by scripts/run_sql.py by default; ACCOUNTADMIN is reserved for explicit --admin (DDL/RBAC) runs.';

GRANT ROLE MARKET_DATA_INGEST TO ROLE VIGIL_AUTOMATION;
GRANT ROLE GOVERNANCE_WRITE TO ROLE VIGIL_AUTOMATION;
GRANT ROLE AUDIT_INSERT TO ROLE VIGIL_AUTOMATION;
GRANT ROLE ANALYST_READ TO ROLE VIGIL_AUTOMATION;

GRANT ROLE VIGIL_AUTOMATION TO USER ASHWINISHARMA0807;
