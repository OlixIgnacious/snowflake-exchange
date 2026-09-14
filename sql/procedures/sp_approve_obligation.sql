-- SP_APPROVE_OBLIGATION -- the "GOVERNANCE_WRITE approval procedure" architecture.md's Fix #9
-- comment refers to (sql/ddl/06_governance.sql: "validated by the GOVERNANCE_WRITE approval
-- procedure against INFORMATION_SCHEMA instead") but that was never actually built until now --
-- OBLIGATION_MAP.SOURCE_TABLE/SOURCE_COLUMNS were free text with no enforced existence check.
--
-- Approving an obligation is the proposed -> approved flip (Fix #12): a NEW row, same
-- OBLIGATION_ID/JURISDICTION_ID, later LOADED_AT, never an UPDATE of the proposed row. This
-- procedure only ever INSERTs.
--
-- EXECUTE AS CALLER (not OWNER): GOVERNANCE_WRITE already holds direct INSERT+SELECT grants on
-- OBLIGATION_MAP (sql/rbac/03_governance_write.sql) -- unlike AUDIT_INSERT/ANALYST_READ, which
-- have no direct table grants and rely on EXECUTE AS OWNER procedures for every write. This
-- procedure exists to centralize the *validation* logic (Fix #9), not to grant a privilege
-- GOVERNANCE_WRITE doesn't already have.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_APPROVE_OBLIGATION(
    P_OBLIGATION_ID VARCHAR,
    P_JURISDICTION_ID VARCHAR,
    P_OBLIGATION_DESCRIPTION VARCHAR,
    P_SOURCE_TABLE VARCHAR,
    P_SOURCE_COLUMNS VARCHAR,  -- comma-separated; validated column-by-column, Fix #9
    P_DETECTOR_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_table_exists   NUMBER DEFAULT 0;
    v_col_count      NUMBER DEFAULT 0;
    v_expected_count NUMBER DEFAULT 0;
    v_now            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_user           VARCHAR DEFAULT CURRENT_USER();
    v_created_at     TIMESTAMP_NTZ;
    v_created_by     VARCHAR;
    v_columns        ARRAY;
BEGIN
    -- Fix #9: SOURCE_TABLE must be a real object in VIGIL.CORE before it can back an approved
    -- obligation -- SQL can't enforce this as a declarative FK against a dynamic table name, so
    -- it's checked here against INFORMATION_SCHEMA instead.
    SELECT COUNT(*) INTO :v_table_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = 'CORE' AND TABLE_NAME = UPPER(:P_SOURCE_TABLE);

    IF (:v_table_exists = 0) THEN
        RETURN 'REJECTED: SOURCE_TABLE ' || :P_SOURCE_TABLE || ' does not exist in VIGIL.CORE.';
    END IF;

    v_columns := SPLIT(:P_SOURCE_COLUMNS, ',');
    v_expected_count := ARRAY_SIZE(:v_columns);

    SELECT COUNT(*) INTO :v_col_count
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'CORE'
      AND TABLE_NAME = UPPER(:P_SOURCE_TABLE)
      AND UPPER(TRIM(COLUMN_NAME)) IN (
          SELECT UPPER(TRIM(VALUE::VARCHAR)) FROM TABLE(FLATTEN(INPUT => :v_columns))
      );

    IF (:v_col_count < :v_expected_count) THEN
        RETURN 'REJECTED: one or more SOURCE_COLUMNS not found on ' || :P_SOURCE_TABLE
            || ' (expected ' || :v_expected_count || ', matched ' || :v_col_count || ').';
    END IF;

    -- An obligation must already exist as 'proposed' before it can be approved -- approval is a
    -- status transition on an existing OBLIGATION_ID, not a way to create one from nothing.
    SELECT CREATED_AT, CREATED_BY INTO :v_created_at, :v_created_by
    FROM OBLIGATION_MAP
    WHERE OBLIGATION_ID = :P_OBLIGATION_ID AND JURISDICTION_ID = :P_JURISDICTION_ID
    ORDER BY LOADED_AT DESC
    LIMIT 1;

    IF (:v_created_at IS NULL) THEN
        RETURN 'REJECTED: no proposed OBLIGATION_MAP row found for ' || :P_OBLIGATION_ID
            || ' -- insert a proposed row first.';
    END IF;

    INSERT INTO OBLIGATION_MAP (
        OBLIGATION_ID, JURISDICTION_ID, OBLIGATION_DESCRIPTION, SOURCE_TABLE, SOURCE_COLUMNS,
        DETECTOR_NAME, STATUS, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT :P_OBLIGATION_ID, :P_JURISDICTION_ID, :P_OBLIGATION_DESCRIPTION, :P_SOURCE_TABLE,
           :P_SOURCE_COLUMNS, :P_DETECTOR_NAME, 'approved', :v_created_at, :v_created_by,
           :v_now, :v_user;

    RETURN 'APPROVED: ' || :P_OBLIGATION_ID || ' (' || :P_DETECTOR_NAME || ')';
END;
$$;

GRANT USAGE ON PROCEDURE SP_APPROVE_OBLIGATION(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR)
    TO ROLE GOVERNANCE_WRITE;
