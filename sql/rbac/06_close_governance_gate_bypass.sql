-- Closes review finding "the governance gate is not structural -- it's a suggestion": until now,
-- GOVERNANCE_WRITE held direct INSERT on the base OBLIGATION_MAP table, so any session holding
-- that role could `INSERT ... STATUS='approved'` directly, skipping SP_APPROVE_OBLIGATION's
-- INFORMATION_SCHEMA validation entirely -- exactly the failure mode architecture.md's Fix #6
-- ("not merely supposed to be checked and skipped") explicitly set out to eliminate, and it was
-- still there.
--
-- Fix: revoke INSERT on the base table. GOVERNANCE_WRITE keeps SELECT (to review 'proposed' rows,
-- Fix #6) and USAGE on both procedures -- SP_PROPOSE_OBLIGATION (new, sql/procedures/
-- sp_propose_obligation.sql) for the 'proposed' half, SP_APPROVE_OBLIGATION (existing) for the
-- validated 'approved' half. Every write to OBLIGATION_MAP now goes through a procedure; there is
-- no longer a raw-insert path for this role at all.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

REVOKE INSERT ON TABLE OBLIGATION_MAP FROM ROLE GOVERNANCE_WRITE;
