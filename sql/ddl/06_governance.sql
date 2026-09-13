-- OBLIGATION_MAP + OBLIGATION_RULE_CHUNKS + APPROVED_OBLIGATIONS.
-- Spec: docs/canonical_schema_contract.md v7, "Core tables" > OBLIGATION_MAP /
-- OBLIGATION_RULE_CHUNKS / APPROVED_OBLIGATIONS. This is the governance gate: OBLIGATION_MAP.
-- STATUS starts 'proposed'; only a GOVERNANCE_WRITE session can write 'approved' (sql/rbac/,
-- Phase 2), and only as a NEW row (Fix #12), never an UPDATE. APPROVED_OBLIGATIONS is the only
-- obligation-lookup target ANALYST_READ/the agent's obligation-lookup tool is granted (Fix #6) --
-- the gate is structural, not a rule every future query has to remember.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

-- ============================================================================
-- OBLIGATION_MAP -- milestoned as of Fix #12
-- ============================================================================
CREATE TABLE IF NOT EXISTS OBLIGATION_MAP (
    OBLIGATION_ID          VARCHAR NOT NULL,
    JURISDICTION_ID        VARCHAR NOT NULL
        COMMENT 'Obligations are regulator-level, not per-venue -- the whole point of the JURISDICTION_ID/VENUE_ID split.',
    OBLIGATION_DESCRIPTION VARCHAR,
    SOURCE_TABLE           VARCHAR
        COMMENT 'Free text -- real-schema linkage is unenforceable in SQL against a dynamic table name; validated by the GOVERNANCE_WRITE approval procedure against INFORMATION_SCHEMA instead (Fix #9).',
    SOURCE_COLUMNS         VARCHAR
        COMMENT 'Same caveat as SOURCE_TABLE.',
    DETECTOR_NAME          VARCHAR,
    STATUS                 VARCHAR NOT NULL DEFAULT 'proposed'
        COMMENT 'proposed / approved. A transition is a NEW ROW, same OBLIGATION_ID, later LOADED_AT (Fix #12), inserted only by a GOVERNANCE_WRITE session after the SOURCE_TABLE/SOURCE_COLUMNS validation check (Fix #9) passes.',
    CREATED_AT             TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this OBLIGATION_ID was first proposed; carried forward through approval and any later status change.',
    CREATED_BY             VARCHAR NOT NULL,
    LOADED_AT              TIMESTAMP_NTZ NOT NULL,
    LOADED_BY              VARCHAR NOT NULL,
    CONSTRAINT PK_OBLIGATION_MAP PRIMARY KEY (OBLIGATION_ID, JURISDICTION_ID, LOADED_AT)
);

-- OBLIGATION_MAP_CURRENT: latest LOADED_AT per obligation, any STATUS. Not the governance-gate
-- view (that's APPROVED_OBLIGATIONS below) -- this exists only for Milestoning discipline rule 5
-- ("every table gets one generic <TABLE>_CURRENT view, no exceptions"). Access to it stays with
-- GOVERNANCE_WRITE (which already holds base-table SELECT); it is not granted to ANALYST_READ --
-- see sql/rbac/ (Phase 2) and Fix #6.
CREATE OR REPLACE VIEW OBLIGATION_MAP_CURRENT AS
SELECT *
FROM OBLIGATION_MAP
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY OBLIGATION_ID, JURISDICTION_ID
    ORDER BY LOADED_AT DESC
) = 1;

-- APPROVED_OBLIGATIONS (new view, Fix #6; redefined Fix #12).
-- The latest LOADED_AT row per obligation, filtered to approved -- not "any row ever approved",
-- so a later 'revoked' status (if added) correctly removes the obligation from this view without
-- deleting its history.
CREATE OR REPLACE VIEW APPROVED_OBLIGATIONS AS
SELECT *
FROM OBLIGATION_MAP
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY OBLIGATION_ID, JURISDICTION_ID ORDER BY LOADED_AT DESC
) = 1
AND STATUS = 'approved';

-- ============================================================================
-- OBLIGATION_RULE_CHUNKS (new, Fix #9; milestoned per Fix #13)
-- ============================================================================
CREATE TABLE IF NOT EXISTS OBLIGATION_RULE_CHUNKS (
    OBLIGATION_ID    VARCHAR NOT NULL
        COMMENT 'Logical FK -> OBLIGATION_MAP (+ JURISDICTION_ID); not declared (milestoned parent).',
    JURISDICTION_ID  VARCHAR NOT NULL,
    RULE_CHUNK_ID    VARCHAR NOT NULL
        COMMENT 'Logical FK -> RULE_CORPUS; not declared (milestoned parent).',
    IS_ACTIVE        BOOLEAN NOT NULL DEFAULT TRUE
        COMMENT 'Fix #13. Removing a wrong association is a tombstone row (IS_ACTIVE = FALSE, later LOADED_AT), never a DELETE.',
    CREATED_AT       TIMESTAMP_NTZ NOT NULL,
    CREATED_BY       VARCHAR NOT NULL,
    LOADED_AT        TIMESTAMP_NTZ NOT NULL,
    LOADED_BY        VARCHAR NOT NULL,
    CONSTRAINT PK_OBLIGATION_RULE_CHUNKS PRIMARY KEY (OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID, LOADED_AT)
);

-- Latest LOADED_AT row per (OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID) WHERE IS_ACTIVE. No
-- rows for an obligation = no rule chunk identified yet (legitimate in-progress gap-analysis
-- state); one or many = an obligation backed by multiple rule paragraphs.
CREATE OR REPLACE VIEW OBLIGATION_RULE_CHUNKS_CURRENT AS
SELECT *
FROM OBLIGATION_RULE_CHUNKS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY OBLIGATION_ID, JURISDICTION_ID, RULE_CHUNK_ID
    ORDER BY LOADED_AT DESC
) = 1
AND IS_ACTIVE;
