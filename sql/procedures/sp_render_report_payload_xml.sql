-- SP_RENDER_REPORT_PAYLOAD_XML -- the XML half of closing docs/canonical_schema_contract.md:148
-- ("the regulator's exact XML/CSV/fixed-width output ... not modeled here"). RTS 22 (Commission
-- Delegated Regulation (EU) 2017/590) Annex I explicitly requires XML, ISO 20022-flavored,
-- submission -- SP_RENDER_REPORT_PAYLOAD's CSV alone can never be a real answer for that
-- jurisdiction's actual required format.
--
-- Scope, stated plainly: this is a real, correctly-tagged XML artifact for whichever fields
-- REPORT_TEMPLATES_CURRENT says are genuinely mapped -- same "never render a gap field" rule as
-- the CSV procedure, same multi-table resolution (TRADES/TRANSACTION_REPORTS, plus, since the
-- gap-8 OTC-derivatives MVP, DERIVATIVE_TRADE_DETAILS/DERIVATIVE_PRODUCT_ATTRIBUTES/
-- REPORTING_PARTICIPANT/COUNTERPARTY_PARTICIPANT), same live INFORMATION_SCHEMA re-validation.
-- It is NOT a claim of full ISO 20022 schema conformance (no
-- namespace/schema-version declarations, no envelope structure beyond a simple root element) --
-- that would require modeling ISO 20022's actual message schema, out of scope here. What's real:
-- the tag names are the regulator's own field names (sanitized to valid XML element names), and a
-- gap field can never silently appear with a fabricated value, exactly like the CSV version.
--
-- Field-resolution logic is intentionally duplicated from SP_RENDER_REPORT_PAYLOAD rather than
-- shared -- Snowflake SQL scripting procedures have no subroutine-call mechanism between them
-- short of a UDF/UDTF, which would be a bigger structural change than this fix warrants.
--
-- Writing an arbitrary XML string to a stage (not a COPY INTO's usual CSV/JSON/Parquet unload):
-- a real Snowflake technique, not a hack -- COPY INTO with FILE_FORMAT (TYPE = CSV,
-- FIELD_DELIMITER = NONE, RECORD_DELIMITER = NONE, FIELD_OPTIONALLY_ENCLOSED_BY = NONE) against a
-- single-row, single-column SELECT writes exactly that column's raw bytes, no CSV-specific
-- framing added.

USE ROLE ACCOUNTADMIN;
USE DATABASE VIGIL;
USE SCHEMA CORE;

CREATE OR REPLACE PROCEDURE SP_RENDER_REPORT_PAYLOAD_XML(
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
    v_instrument_id  VARCHAR;
    v_participant_id VARCHAR;
    v_counterparty_id VARCHAR;
    v_field_count    NUMBER DEFAULT 0;
    v_stage_path     VARCHAR;
    v_query          VARCHAR;
    v_now            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    v_fields         RESULTSET;
    v_xml_body       VARCHAR DEFAULT '';
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

    -- Gap-8 MVP extension: captured once so DERIVATIVE_PRODUCT_ATTRIBUTES/REPORTING_PARTICIPANT/
    -- COUNTERPARTY_PARTICIPANT-sourced fields below don't need to re-derive them per field.
    SELECT INSTRUMENT_ID, PARTICIPANT_ID, COUNTERPARTY_PARTICIPANT_ID
    INTO :v_instrument_id, :v_participant_id, :v_counterparty_id
    FROM TRADES WHERE TRADE_ID = :v_trade_id;

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
        LET v_tag VARCHAR := REGEXP_REPLACE(rec.FIELD_NAME, '[^A-Za-z0-9_]', '_');
        LET v_value VARCHAR;

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

        -- EXECUTE IMMEDIATE has no INTO clause in Snowflake Scripting (verified live -- that
        -- syntax simply doesn't parse). The working pattern, same as the field-list RESULTSET
        -- above: assign the dynamic query's result to a RESULTSET, bind a cursor to it, and read
        -- the single row's single (explicitly aliased -- an unaliased cast expression's column
        -- name isn't guaranteed accessible positionally) column.
        LET v_val_sql VARCHAR;
        LET v_val_res RESULTSET;
        IF (v_alias = 't') THEN
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM TRADES WHERE TRADE_ID = ''' || :v_trade_id || '''';
        ELSEIF (v_alias = 'r') THEN
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM TRANSACTION_REPORTS_CURRENT WHERE REPORT_ID = ''' ||
                :P_REPORT_ID || ''' AND JURISDICTION_ID = ''' || :P_JURISDICTION_ID || '''';
        ELSEIF (v_alias = 'dtd') THEN
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM DERIVATIVE_TRADE_DETAILS_CURRENT WHERE TRADE_ID = ''' || :v_trade_id || '''';
        ELSEIF (v_alias = 'dpa') THEN
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM DERIVATIVE_PRODUCT_ATTRIBUTES_CURRENT WHERE INSTRUMENT_ID = ''' ||
                :v_instrument_id || ''' AND JURISDICTION_ID = ''' || :P_JURISDICTION_ID || '''';
        ELSEIF (v_alias = 'rp') THEN
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM MARKET_PARTICIPANTS_CURRENT WHERE PARTICIPANT_ID = ''' ||
                :v_participant_id || ''' AND JURISDICTION_ID = ''' || :P_JURISDICTION_ID || '''';
        ELSE
            v_val_sql := 'SELECT ' || v_col_expr || '::VARCHAR AS V FROM MARKET_PARTICIPANTS_CURRENT WHERE PARTICIPANT_ID = ''' ||
                :v_counterparty_id || ''' AND JURISDICTION_ID = ''' || :P_JURISDICTION_ID || '''';
        END IF;
        v_val_res := (EXECUTE IMMEDIATE :v_val_sql);
        LET v_val_cursor CURSOR FOR v_val_res;
        FOR v_val_rec IN v_val_cursor DO
            v_value := v_val_rec.V;
        END FOR;

        -- Minimal XML entity escaping -- these are simple scalar fields (numbers, codes,
        -- timestamps), not free text, but escape defensively rather than assume.
        v_value := REPLACE(REPLACE(REPLACE(COALESCE(v_value, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
        v_xml_body := v_xml_body || '  <' || v_tag || '>' || v_value || '</' || v_tag || '>\n';
        v_field_count := v_field_count + 1;
    END FOR;

    IF (v_field_count = 0) THEN
        RETURN 'ERROR: no STATUS=mapped fields found for ' || :P_JURISDICTION_ID || '/' || :v_report_type || ' -- nothing to render';
    END IF;

    LET v_xml_doc VARCHAR := '<?xml version="1.0" encoding="UTF-8"?>\n<TransactionReport reportId="' ||
        :P_REPORT_ID || '" jurisdictionId="' || :P_JURISDICTION_ID || '">\n' || v_xml_body || '</TransactionReport>\n';

    v_stage_path := '@VIGIL.CORE.REPORT_PAYLOADS/' || :P_JURISDICTION_ID || '/' || :P_REPORT_ID || '.xml';

    -- Plain quote-delimited string here, not a dollar-quoted one -- this procedure's own body is
    -- itself dollar-quoted (see CREATE PROCEDURE above), so literal dollar-quote-delimiter
    -- characters inside a string built here would prematurely end the procedure body (hit live --
    -- an earlier draft of this exact comment describing that fact contained the delimiter itself
    -- and broke compilation this same way). Escape single quotes the standard SQL way instead.
    v_query := 'COPY INTO ' || v_stage_path ||
               ' FROM (SELECT ''' || REPLACE(v_xml_doc, '''', '''''') || ''')' ||
               ' FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE FIELD_OPTIONALLY_ENCLOSED_BY = NONE COMPRESSION = NONE)' ||
               ' HEADER = FALSE OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 5000000';
    EXECUTE IMMEDIATE :v_query;

    RETURN 'OK: rendered ' || v_field_count || ' field(s) to ' || v_stage_path;
END;
$$;

GRANT USAGE ON PROCEDURE SP_RENDER_REPORT_PAYLOAD_XML(VARCHAR, VARCHAR) TO ROLE MARKET_DATA_INGEST;
