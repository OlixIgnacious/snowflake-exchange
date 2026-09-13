-- Vigil bootstrap: database + disjoint CORE/EVAL schemas.
-- Same Snowflake account as Praman; no shared objects (CLAUDE.md, architecture.md).
-- VIGIL.EVAL (INJECTED_CASES/EVAL_RESULTS, added later) is isolated by grant, not by
-- anything in this script — no functional role is ever granted anything on it (architecture.md,
-- "Governance gate" / RBAC sections). This script only creates the two schemas.
--
-- Run interactively by a human in a Snowflake worksheet — never from a non-interactive agent
-- (CLAUDE.md "SQL execution"). Log the run in NOTES.md.

CREATE DATABASE IF NOT EXISTS VIGIL;
CREATE SCHEMA IF NOT EXISTS VIGIL.CORE;
CREATE SCHEMA IF NOT EXISTS VIGIL.EVAL;

USE DATABASE VIGIL;
USE SCHEMA CORE;
