-- AUDIT_LOG. Spec: docs/canonical_schema_contract.md v7, "Core tables" > AUDIT_LOG.
-- Same column shape as Praman.AUDIT_LOG (architecture.md: reused pattern). Append-only by grant
-- (AUDIT_INSERT is INSERT-only, no SELECT -- sql/rbac/, Phase 2). No <TABLE>_CURRENT view -- an
-- audit row is never itself versioned (CREATED_AT/CREATED_BY and LOADED_AT/LOADED_BY are
-- trivially equal in pairs on every row).
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS AUDIT_LOG (
    RUN_ID                    VARCHAR NOT NULL,
    APP_USER                  VARCHAR,
    STAGE                     VARCHAR,
    PROMPT_OR_QUESTION        VARCHAR,
    MODEL_VERSION             VARCHAR,
    RETRIEVED_RULE_CHUNK_IDS  ARRAY
        COMMENT 'Currently CHUNK_ID values only. Fix #17 flags a follow-up (out of scope here): should pin the exact (CHUNK_ID, LOADED_AT) cited so a historical citation stays reproducible against the version actually shown, since RULE_CORPUS is itself milestoned.',
    QUERY_SNAPSHOT_ID         VARCHAR,
    OUTPUT                    VARCHAR,
    IS_EVAL                   BOOLEAN,
    SIGNOFF_FOR_RUN_ID        VARCHAR
        COMMENT 'Logical FK -> AUDIT_LOG.RUN_ID (self-referencing) when this row records a sign-off decision for an earlier run.',
    HUMAN_DECISION            VARCHAR,
    SIGNOFF_BY                VARCHAR,
    SIGNOFF_AT                TIMESTAMP_NTZ,
    CREATED_AT                TIMESTAMP_NTZ NOT NULL
        COMMENT 'Equal to LOADED_AT on every row -- an audit row is never itself versioned.',
    CREATED_BY                VARCHAR NOT NULL,
    LOADED_AT                 TIMESTAMP_NTZ NOT NULL,
    LOADED_BY                 VARCHAR NOT NULL
        COMMENT 'The AUDIT_INSERT-granted identity that wrote the row -- can differ from APP_USER, whose action is being logged.',
    CONSTRAINT PK_AUDIT_LOG PRIMARY KEY (RUN_ID)
);
