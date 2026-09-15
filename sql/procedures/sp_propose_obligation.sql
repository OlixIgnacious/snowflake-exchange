-- SP_PROPOSE_OBLIGATION -- the write path GOVERNANCE_WRITE needs for the 'proposed' half of the
-- proposed->approved lifecycle now that its direct INSERT on OBLIGATION_MAP is revoked
-- (sql/rbac/06_close_governance_gate_bypass.sql). No INFORMATION_SCHEMA validation here by
-- design -- 'proposed' isn't the trust boundary (SP_APPROVE_OBLIGATION is, and still validates
-- SOURCE_TABLE/SOURCE_COLUMNS before allowing 'approved'). This procedure exists purely so
-- GOVERNANCE_WRITE has a real, structural way to create the initial row, instead of a direct
-- table grant that would let it also write 'approved' unchecked.
--
-- EXECUTE AS OWNER (unlike SP_APPROVE_OBLIGATION's EXECUTE AS CALLER): GOVERNANCE_WRITE no longer
-- holds any INSERT grant on the base OBLIGATION_MAP table, so the procedure's own owner rights
-- are what perform the write.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_PROPOSE_OBLIGATION(
    P_OBLIGATION_ID VARCHAR,
    P_JURISDICTION_ID VARCHAR,
    P_OBLIGATION_DESCRIPTION VARCHAR,
    P_SOURCE_TABLE VARCHAR,
    P_SOURCE_COLUMNS VARCHAR,
    P_DETECTOR_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_now    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_user   VARCHAR DEFAULT CURRENT_USER();
    v_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO :v_exists
    FROM OBLIGATION_MAP_CURRENT
    WHERE OBLIGATION_ID = :P_OBLIGATION_ID AND JURISDICTION_ID = :P_JURISDICTION_ID AND STATUS = 'approved';

    IF (v_exists > 0) THEN
        RETURN 'REJECTED: ' || :P_OBLIGATION_ID || ' is already approved for ' || :P_JURISDICTION_ID
            || ' -- propose a new OBLIGATION_ID for a materially different obligation rather than re-proposing an approved one.';
    END IF;

    INSERT INTO OBLIGATION_MAP (
        OBLIGATION_ID, JURISDICTION_ID, OBLIGATION_DESCRIPTION, SOURCE_TABLE, SOURCE_COLUMNS,
        DETECTOR_NAME, STATUS, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT :P_OBLIGATION_ID, :P_JURISDICTION_ID, :P_OBLIGATION_DESCRIPTION, :P_SOURCE_TABLE,
           :P_SOURCE_COLUMNS, :P_DETECTOR_NAME, 'proposed', :v_now, :v_user, :v_now, :v_user;

    RETURN 'PROPOSED: ' || :P_OBLIGATION_ID || ' (' || :P_JURISDICTION_ID || ')';
END;
$$;

GRANT USAGE ON PROCEDURE SP_PROPOSE_OBLIGATION(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR)
    TO ROLE GOVERNANCE_WRITE;
