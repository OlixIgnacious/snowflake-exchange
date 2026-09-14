-- TASK_GOVERNANCE_COVERAGE_AUDIT -- scheduled wrapper around SP_AUDIT_OBLIGATION_COVERAGE.
-- Weekly cadence: this checks internal mapping drift, not a live feed -- there's no reason to run
-- it more often than that.
--
-- Created SUSPENDED by default (Snowflake tasks are created suspended unless explicitly RESUMEd)
-- and left that way deliberately, to avoid ongoing warehouse cost for a demo project. Activate
-- only when actually demoing the scheduled behavior:
--   ALTER TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT RESUME;   -- activate for the demo
--   ALTER TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT SUSPEND;  -- deactivate again after
-- To prove the task's logic works without activating the schedule, run it once on demand instead:
--   EXECUTE TASK VIGIL.CORE.TASK_GOVERNANCE_COVERAGE_AUDIT;
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE TASK TASK_GOVERNANCE_COVERAGE_AUDIT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 6 * * MON America/New_York'
AS
    CALL VIGIL.CORE.SP_AUDIT_OBLIGATION_COVERAGE();
