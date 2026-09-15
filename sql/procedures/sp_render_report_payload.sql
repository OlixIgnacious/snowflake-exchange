-- SP_RENDER_REPORT_PAYLOAD -- closes the gap docs/canonical_schema_contract.md:148 names directly:
-- "the transformation logic itself (canonical rows + REPORT_TEMPLATES -> the regulator's exact
-- XML/CSV/fixed-width output) is adaptor/generator code ... not modeled here." That adaptor never
-- got built, so TRANSACTION_REPORTS.REPORT_PAYLOAD_REF (Fix #25) was permanently NULL -- a place
-- to record an artifact that nothing ever generated.
--
-- Scope, stated plainly rather than overclaimed: this renders a real CSV from REPORT_TEMPLATES_
-- CURRENT's currently-mapped fields for a trade-scoped report -- see REPORT_TEMPLATE_COVERAGE for
-- the live mapped/gap split. It is not the regulator's actual required XML/fixed-width submission
-- format for every field (SP_RENDER_REPORT_PAYLOAD_XML, added alongside this procedure, covers
-- the XML case for whichever fields are genuinely mapped) -- a full per-regulator schema is still
-- unbuilt, same caveat architecture.md already states for Fix #25. What this closes is narrower
-- and real: REPORT_PAYLOAD_REF now points at an actual artifact instead of being permanently
-- NULL, and the artifact's columns are exactly, only, and honestly the fields REPORT_TEMPLATES_
-- CURRENT says are really mapped -- a gap field can never silently appear with a fabricated value.
--
-- Multi-table field resolution (review finding: the original version only resolved TRADES-sourced
-- fields, refusing to render at all if a mapped field came from anywhere else): SOURCE_MAPPING
-- may now name TRADES or TRANSACTION_REPORTS -- both resolve to exactly one row for a given
-- trade-scoped report (one TRADE_ID, one REPORT_ID), so they're combined via a plain CROSS JOIN
-- of two single-row subqueries rather than needing a real join condition between them.
--
-- Gap-8 MVP extension: SOURCE_MAPPING may also name DERIVATIVE_TRADE_DETAILS,
-- DERIVATIVE_PRODUCT_ATTRIBUTES, or the two pseudo-tables REPORTING_PARTICIPANT/
-- COUNTERPARTY_PARTICIPANT (both really MARKET_PARTICIPANTS, disambiguated by which side of the
-- trade they read -- SOURCE_MAPPING needs two distinct names since one trade has two
-- counterparties). These four are LEFT JOINed off the already-selected TRADES row (real keys:
-- DERIVATIVE_TRADE_DETAILS on TRADE_ID/VENUE_ID, DERIVATIVE_PRODUCT_ATTRIBUTES on
-- INSTRUMENT_ID/JURISDICTION_ID, the two participant aliases on PARTICIPANT_ID or
-- COUNTERPARTY_PARTICIPANT_ID + JURISDICTION_ID) -- LEFT, not INNER, so an equity-only report
-- (no derivative row) still renders its TRADES/TRANSACTION_REPORTS fields untouched.
--
-- EXECUTE AS OWNER (same elevation pattern as sp_record_signoff.sql): MARKET_DATA_INGEST has no
-- SELECT grant on TRADES (Fix #7 -- INSERT-only on every base table by design), so this procedure's
-- own owner rights are what let it read the trade to render, not a grant to the calling role.
--
-- Defense-in-depth against SOURCE_MAPPING being free text (same caveat as OBLIGATION_MAP.SOURCE_
-- TABLE/SOURCE_COLUMNS, Fix #9): every mapped field's SOURCE_MAPPING is re-validated against
-- INFORMATION_SCHEMA.COLUMNS at render time, independent of whatever validated it when STATUS was
-- first written -- refuses to build dynamic SQL from a column reference that doesn't actually
-- exist right now.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE STAGE IF NOT EXISTS REPORT_PAYLOADS
    COMMENT = 'Rendered TRANSACTION_REPORTS payload artifacts (Fix #25). One file per REPORT_ID, path REPORT_PAYLOADS/<JURISDICTION_ID>/<REPORT_ID>.csv.';

CREATE OR REPLACE PROCEDURE SP_RENDER_REPORT_PAYLOAD(
    P_REPORT_ID VARCHAR,
    P_JURISDICTION_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_report_type    VARCHAR;
    v_report_scope   VARCHAR;
    v_trade_id       VARCHAR;
    v_select_list    VARCHAR DEFAULT '';
    v_field_count    NUMBER DEFAULT 0;
    v_stage_path     VARCHAR;
    v_query          VARCHAR;
    v_now            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_fields         RESULTSET;
BEGIN
    SELECT REPORT_TYPE, REPORT_SCOPE, TRADE_ID INTO :v_report_type, :v_report_scope, :v_trade_id
    FROM TRANSACTION_REPORTS_CURRENT
    WHERE REPORT_ID = :P_REPORT_ID AND JURISDICTION_ID = :P_JURISDICTION_ID;

    IF (v_report_type IS NULL) THEN
        RETURN 'ERROR: no TRANSACTION_REPORTS row for REPORT_ID=' || :P_REPORT_ID || ' JURISDICTION_ID=' || :P_JURISDICTION_ID;
    END IF;
    IF (v_report_scope <> 'trade' OR v_trade_id IS NULL) THEN
        RETURN 'ERROR: REPORT_SCOPE=' || :v_report_scope || ' -- payload rendering only supports trade-scoped reports today';
    END IF;

    -- Snowflake Scripting note: a CURSOR declared directly in DECLARE cannot bind :P_JURISDICTION_
    -- ID/:v_report_type (verified live -- "Bind variable not set" even for a real procedure
    -- parameter) -- only a RESULTSET assigned at runtime, then bound to a cursor via LET, resolves
    -- bind variables correctly.
    v_fields := (
        SELECT FIELD_NAME, SOURCE_MAPPING
        FROM REPORT_TEMPLATES_CURRENT
        WHERE JURISDICTION_ID = :P_JURISDICTION_ID
          AND REPORT_TYPE = :v_report_type
          AND STATUS = 'mapped'
        ORDER BY FIELD_ORDER ASC NULLS LAST, FIELD_NAME ASC
    );
    LET field_cursor CURSOR FOR v_fields;
    FOR rec IN field_cursor DO
        LET v_table_name VARCHAR := UPPER(SPLIT_PART(rec.SOURCE_MAPPING, '.', 1));
        LET v_col_expr VARCHAR := SPLIT_PART(rec.SOURCE_MAPPING, '.', 2);
        LET v_base_col VARCHAR := SPLIT_PART(v_col_expr, ':', 1);
        LET v_col_exists NUMBER;
        LET v_alias VARCHAR;
        LET v_check_table VARCHAR;

        IF (v_table_name = 'TRADES') THEN
            v_alias := 't'; v_check_table := 'TRADES';
        ELSEIF (v_table_name = 'TRANSACTION_REPORTS') THEN
            v_alias := 'r'; v_check_table := 'TRANSACTION_REPORTS';
        ELSEIF (v_table_name = 'DERIVATIVE_TRADE_DETAILS') THEN
            v_alias := 'dtd'; v_check_table := 'DERIVATIVE_TRADE_DETAILS';
        ELSEIF (v_table_name = 'DERIVATIVE_PRODUCT_ATTRIBUTES') THEN
            v_alias := 'dpa'; v_check_table := 'DERIVATIVE_PRODUCT_ATTRIBUTES';
        ELSEIF (v_table_name = 'REPORTING_PARTICIPANT') THEN
            v_alias := 'rp'; v_check_table := 'MARKET_PARTICIPANTS';
        ELSEIF (v_table_name = 'COUNTERPARTY_PARTICIPANT') THEN
            v_alias := 'cp'; v_check_table := 'MARKET_PARTICIPANTS';
        ELSE
            RETURN 'ERROR: field ' || rec.FIELD_NAME || ' maps to ' || rec.SOURCE_MAPPING ||
                   ' -- only TRADES/TRANSACTION_REPORTS/DERIVATIVE_TRADE_DETAILS/DERIVATIVE_PRODUCT_ATTRIBUTES/REPORTING_PARTICIPANT/COUNTERPARTY_PARTICIPANT are supported source tables, refusing to render a partial/misleading payload';
        END IF;

        SELECT COUNT(*) INTO :v_col_exists
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'CORE' AND TABLE_NAME = :v_check_table AND COLUMN_NAME = UPPER(:v_base_col);

        IF (v_col_exists = 0) THEN
            RETURN 'ERROR: SOURCE_MAPPING ' || rec.SOURCE_MAPPING || ' for field ' || rec.FIELD_NAME ||
                   ' does not resolve against live INFORMATION_SCHEMA -- refusing to render';
        END IF;

        IF (v_field_count > 0) THEN
            v_select_list := v_select_list || ', ';
        END IF;
        v_select_list := v_select_list || v_alias || '.' || v_col_expr || '::VARCHAR AS "' || rec.FIELD_NAME || '"';
        v_field_count := v_field_count + 1;
    END FOR;

    IF (v_field_count = 0) THEN
        RETURN 'ERROR: no STATUS=mapped fields found for ' || :P_JURISDICTION_ID || '/' || :v_report_type || ' -- nothing to render';
    END IF;

    v_stage_path := '@VIGIL.CORE.REPORT_PAYLOADS/' || :P_JURISDICTION_ID || '/' || :P_REPORT_ID || '.csv';

    v_query := 'COPY INTO ' || v_stage_path ||
               ' FROM (SELECT ' || v_select_list ||
               ' FROM (SELECT * FROM TRADES WHERE TRADE_ID = ''' || :v_trade_id || ''') t' ||
               ' LEFT JOIN DERIVATIVE_TRADE_DETAILS_CURRENT dtd ON dtd.TRADE_ID = t.TRADE_ID AND dtd.VENUE_ID = t.VENUE_ID' ||
               ' LEFT JOIN DERIVATIVE_PRODUCT_ATTRIBUTES_CURRENT dpa ON dpa.INSTRUMENT_ID = t.INSTRUMENT_ID AND dpa.JURISDICTION_ID = t.JURISDICTION_ID' ||
               ' LEFT JOIN MARKET_PARTICIPANTS_CURRENT rp ON rp.PARTICIPANT_ID = t.PARTICIPANT_ID AND rp.JURISDICTION_ID = t.JURISDICTION_ID' ||
               ' LEFT JOIN MARKET_PARTICIPANTS_CURRENT cp ON cp.PARTICIPANT_ID = t.COUNTERPARTY_PARTICIPANT_ID AND cp.JURISDICTION_ID = t.JURISDICTION_ID' ||
               ', (SELECT * FROM TRANSACTION_REPORTS_CURRENT WHERE REPORT_ID = ''' || :P_REPORT_ID ||
               ''' AND JURISDICTION_ID = ''' || :P_JURISDICTION_ID || ''') r)' ||
               ' FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = ''"'' COMPRESSION = NONE)' ||
               ' HEADER = TRUE OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 5000000';
    EXECUTE IMMEDIATE :v_query;

    -- Milestoned: a new TRANSACTION_REPORTS row, same key, later LOADED_AT -- never an UPDATE
    -- (Fix #14). Every other column carried forward unchanged from the current row.
    INSERT INTO TRANSACTION_REPORTS (
        REPORT_ID, JURISDICTION_ID, VENUE_ID, REPORT_TYPE, REPORT_SCOPE, TRADE_ID,
        PERIOD_START, PERIOD_END, REPORT_STATUS, SUBMITTED_AT, DEADLINE,
        DEFERRED_PUBLICATION_UNTIL, FIELDS_COMPLETE, MATCH_STATUS, REPORT_PAYLOAD_REF,
        CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY
    )
    SELECT
        REPORT_ID, JURISDICTION_ID, VENUE_ID, REPORT_TYPE, REPORT_SCOPE, TRADE_ID,
        PERIOD_START, PERIOD_END, REPORT_STATUS, SUBMITTED_AT, DEADLINE,
        DEFERRED_PUBLICATION_UNTIL, FIELDS_COMPLETE, MATCH_STATUS, :v_stage_path,
        CREATED_AT, CREATED_BY, :v_now, CURRENT_USER()
    FROM TRANSACTION_REPORTS_CURRENT
    WHERE REPORT_ID = :P_REPORT_ID AND JURISDICTION_ID = :P_JURISDICTION_ID;

    RETURN 'OK: rendered ' || v_field_count || ' field(s) to ' || v_stage_path;
END;
$$;

GRANT USAGE ON PROCEDURE SP_RENDER_REPORT_PAYLOAD(VARCHAR, VARCHAR) TO ROLE MARKET_DATA_INGEST;
GRANT READ ON STAGE REPORT_PAYLOADS TO ROLE ANALYST_READ;
