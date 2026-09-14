-- TASK_SURVEILLANCE_RUN_JP -- captured from the live object via GET_DDL (built by CoCo CLI during
-- the "Execution" phase of the CoCo hackathon build, never saved to a file at the time -- same
-- reproducibility gap SURVEILLANCE_RUN_LOG had, see sql/detectors/07_surveillance_audit_log.sql's
-- header and NOTES.md). Runs SP_LOG_SURVEILLANCE_RUN('JP') on a fixed interval.
--
-- Created SUSPENDED by default (Snowflake tasks are created suspended unless explicitly RESUMEd)
-- and left that way to avoid ongoing warehouse cost -- resume only when actually demoing the
-- scheduled-run behavior:
--   ALTER TASK VIGIL.CORE.TASK_SURVEILLANCE_RUN_JP RESUME;   -- activate
--   ALTER TASK VIGIL.CORE.TASK_SURVEILLANCE_RUN_JP SUSPEND;  -- deactivate again after the demo
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

-- Task is created SUSPENDED by default -- no ALTER TASK ... SUSPEND needed here. Do not RESUME
-- as part of this script; resuming is a deliberate, separate action (see header above).
CREATE OR REPLACE TASK TASK_SURVEILLANCE_RUN_JP
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '10 MINUTE'
AS
    CALL VIGIL.CORE.SP_LOG_SURVEILLANCE_RUN('JP');
