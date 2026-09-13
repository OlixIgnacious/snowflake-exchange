-- RULE_CORPUS -- milestoned as of Fix #17: an amended rule is a new row, so a past citation
-- against the old text stays reproducible. Spec: docs/canonical_schema_contract.md v7, "Core
-- tables" > RULE_CORPUS.
--
-- SOURCE_AUTHORITY/ORIGINAL_LANGUAGE are NOT NULL from the first row loaded (market-agnostic
-- design rule #6) -- directly relevant for Japan, where the FSA/SESC's authoritative text is
-- Japanese and any English version is a provisional translation. Any agent-surfaced citation from
-- a translated chunk must carry that caveat in its output, not just in internal documentation.
--
-- Run interactively by a human -- never from a non-interactive agent. Log the run in NOTES.md.

USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE TABLE IF NOT EXISTS RULE_CORPUS (
    CHUNK_ID          VARCHAR NOT NULL,
    JURISDICTION_ID   VARCHAR NOT NULL,
    DOC_TITLE         VARCHAR,
    SECTION_REF       VARCHAR
        COMMENT 'Citable unit (e.g. rule/paragraph number).',
    CHUNK_TEXT        VARCHAR,
    SOURCE_AUTHORITY  VARCHAR NOT NULL
        COMMENT 'original / translation. Present from the first row loaded, not added later (market-agnostic design rule #6).',
    ORIGINAL_LANGUAGE VARCHAR NOT NULL,
    CREATED_AT        TIMESTAMP_NTZ NOT NULL
        COMMENT 'When this CHUNK_ID was first loaded; carried forward through every later amendment.',
    CREATED_BY        VARCHAR NOT NULL,
    LOADED_AT         TIMESTAMP_NTZ NOT NULL
        COMMENT 'Fix #17. A rule amendment is a new row, same CHUNK_ID, later LOADED_AT -- old text is never overwritten.',
    LOADED_BY         VARCHAR NOT NULL,
    CONSTRAINT PK_RULE_CORPUS PRIMARY KEY (CHUNK_ID, LOADED_AT)
);

-- RULE_CORPUS_CURRENT: latest LOADED_AT per CHUNK_ID, for normal lookups.
-- Follow-up flagged in the contract (Fix #17), not yet resolved: AUDIT_LOG.RETRIEVED_RULE_CHUNK_IDS
-- should pin the exact (CHUNK_ID, LOADED_AT) cited, not just CHUNK_ID, so a historical citation
-- stays reproducible against the version actually shown -- an AUDIT_LOG column-level change, out
-- of scope for this table.
CREATE OR REPLACE VIEW RULE_CORPUS_CURRENT AS
SELECT *
FROM RULE_CORPUS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY CHUNK_ID
    ORDER BY LOADED_AT DESC
) = 1;
