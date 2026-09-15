"""Vigil dashboard -- Streamlit in Snowflake (Phase 8 demo layer, plan.md; workflow-stage +
case-centric redesign, 2026-09-16).

Runs inside Snowflake (Snowsight), using the viewer's own role via `get_active_session()`. The
app forces its *resting* role to ANALYST_READ (SELECT everywhere, no write access anywhere --
architecture.md's RBAC section) on every read, and only ever leaves that role for the duration of
one explicit persona action below (`acting_as(...)`), always switching back immediately after --
this app never widens ANALYST_READ's own grants; it switches to a role that already, natively,
holds whatever grant the action needs (sql/rbac/01_roles.sql grants all 5 functional roles
directly to the account that runs this app, so every `USE ROLE` below is real RBAC enforcement,
not a UI simulation).

That enforcement claim depends on one thing that's easy to miss: this account defaults every
session to secondary roles = ALL (confirmed live via `SELECT CURRENT_SECONDARY_ROLES()`), which
means a session's *active* (primary) role restricts nothing by itself -- every grant from every
role the connected user holds is available simultaneously regardless of which role is "current."
Found this the hard way: a live negative-check test (calling a write procedure while on
ANALYST_READ, expecting it to be rejected) unexpectedly succeeded. `USE SECONDARY ROLES NONE`
below is what makes `USE ROLE` below actually mean something -- without it, the whole persona
switcher would still run without errors, but every `acting_as(...)` block would be a no-op label,
not real enforcement. Self-contained in one file (no import of this repo's other modules) since a
Streamlit-in-Snowflake stage only ships the files explicitly uploaded to it -- see NOTES.md for
the deployment record.
"""
import json
from contextlib import contextmanager

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Vigil", layout="wide")
session = get_active_session()
session.sql("USE SECONDARY ROLES NONE").collect()
session.sql("USE ROLE ANALYST_READ").collect()

AGENT_FQN = "VIGIL.CORE.VIGIL_SURVEILLANCE_AGENT"


@st.cache_data(ttl=60)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


@st.cache_data(ttl=60)
def q_params(sql: str, params: tuple) -> pd.DataFrame:
    """Same as q(), bind-parameterized -- used wherever a query embeds free-text user input (a
    case-search box) rather than a value constrained to a selectbox's own DB-backed options."""
    return session.sql(sql, params=list(params)).to_pandas()


@contextmanager
def acting_as(role: str):
    """Switches this shared session's active Snowflake role for one write action, then always
    switches back to ANALYST_READ -- success or failure -- so the session's resting state is
    always least-privilege. Every role this ever switches to already, natively, holds the grant
    the action inside the block needs (see module docstring); this never grants ANALYST_READ
    anything new."""
    session.sql(f"USE ROLE {role}").collect()
    try:
        yield
    finally:
        session.sql("USE ROLE ANALYST_READ").collect()


def download_csv_button(df: pd.DataFrame, label: str, key: str) -> None:
    if df.empty:
        return
    st.download_button(
        label,
        data=df.to_csv(index=False).encode("utf-8"),
        file_name=f"{key}.csv",
        mime="text/csv",
        key=f"dl_{key}",
    )


def ask_agent(messages: list[dict]) -> dict:
    """Calls the already-deployed VIGIL_SURVEILLANCE_AGENT via SNOWFLAKE.CORTEX.DATA_AGENT_RUN --
    a SQL wrapper around the Agent Run REST API, so this works from inside Streamlit-in-Snowflake
    with no REST client/network call needed (ANALYST_READ already has USAGE on the agent, and
    PUBLIC already carries SNOWFLAKE.CORTEX_USER, so no RBAC change was needed for this either).
    Non-streaming (stream: false) since a single JSON reply is all this UI needs.
    """
    request_body = json.dumps({"messages": messages, "stream": False})
    row = session.sql(
        "SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?) AS RESPONSE",
        params=[AGENT_FQN, request_body],
    ).collect()[0]
    return json.loads(row["RESPONSE"])


def extract_answer_and_citations(response: dict) -> tuple[str, list[dict]]:
    """The agent's reply is a list of content blocks (thinking/tool_use/tool_result/text/
    suggested_queries in turn) -- the actual answer is the concatenation of every top-level
    'text' block, in order, not just the last one (a longer answer can span more than one text
    block around inline citations)."""
    if "error" in response:
        return f"Agent error: {response['error'].get('message', response['error'])}", []
    parts, citations = [], []
    for block in response.get("content", []):
        if block.get("type") == "text":
            parts.append(block["text"])
            for ann in block.get("annotations", []):
                if ann.get("type") == "cortex_search_citation":
                    citations.append(ann)
    return "".join(parts).strip() or "(no answer text returned)", citations


def send_chat_message(prompt_text: str) -> tuple[str, list[dict]]:
    """Shared by the Chat tab's own input box and every "Ask Chat about this ID" button
    elsewhere -- both append to the same st.session_state.chat_messages history, so a question
    asked from a case view is part of the same conversation as the Chat tab, not a separate one."""
    if "chat_messages" not in st.session_state:
        st.session_state.chat_messages = []
    st.session_state.chat_messages.append({"role": "user", "content": prompt_text})
    api_messages = [
        {"role": m["role"], "content": [{"type": "text", "text": m["content"]}]}
        for m in st.session_state.chat_messages
    ]
    try:
        answer, citations = extract_answer_and_citations(ask_agent(api_messages))
    except Exception as e:
        answer, citations = f"Agent call failed: {e}", []
    st.session_state.chat_messages.append(
        {"role": "assistant", "content": answer, "citations": citations}
    )
    return answer, citations


def ask_chat_inline(id_value: str, key: str) -> None:
    """Renders an "Ask Chat about <id>" button next to a case view. Streamlit has no reliable
    server-side "switch to this tab" API, so rather than fake a tab-jump, the answer is shown
    immediately in an expander where the click happened -- it's also saved into
    st.session_state.chat_messages, so it's there if the viewer opens the Chat tab next."""
    if st.button(f"Ask Chat about {id_value}", key=f"ask_{key}"):
        with st.spinner("Querying VIGIL_SURVEILLANCE_AGENT…"):
            answer, citations = send_chat_message(id_value)
        with st.expander(f"Vigil's answer about {id_value}", expanded=True):
            st.markdown(answer)
            for c in citations:
                st.caption(f"📄 {c.get('doc_title', c.get('doc_id', 'source'))}")


# ---------------------------------------------------------------------------
# Sidebar
# ---------------------------------------------------------------------------

st.title("Vigil — Market Surveillance & Regulatory Reporting")
st.caption(
    "Live against VIGIL.CORE. Every number on this page is a real query result — nothing here "
    "is mocked or precomputed. Covers three live jurisdictions (JP/EU/US) and the full pipeline "
    "through Phase 9 (detector audit trail, documented per-report findings, rule search)."
)

jurisdictions = q("SELECT JURISDICTION_ID FROM JURISDICTIONS_CURRENT ORDER BY 1")
jurisdiction_id = st.sidebar.selectbox(
    "Jurisdiction",
    jurisdictions["JURISDICTION_ID"] if not jurisdictions.empty else ["JP"],
    index=None,
    placeholder="Select a jurisdiction…",
)
if jurisdiction_id is None:
    st.info("Select a jurisdiction from the sidebar to load data.")
    st.stop()

tabs = st.tabs(["Overview", "Investigate", "Report", "Sign off & Submit", "Chat"])

# ---------------------------------------------------------------------------
# Overview
# ---------------------------------------------------------------------------
with tabs[0]:
    counts = q(f"""
        SELECT 'Venues' AS METRIC, COUNT(*) AS VALUE FROM VENUES_CURRENT WHERE JURISDICTION_ID = '{jurisdiction_id}'
        UNION ALL SELECT 'Active venues', COUNT(*) FROM VENUES_CURRENT WHERE JURISDICTION_ID = '{jurisdiction_id}' AND STATUS = 'active'
        UNION ALL SELECT 'Trades', COUNT(*) FROM TRADES WHERE JURISDICTION_ID = '{jurisdiction_id}'
        UNION ALL SELECT 'Open wash-trading candidates', COUNT(*) FROM WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID = '{jurisdiction_id}' AND NOT IS_TRIGGER_EXEMPT
        UNION ALL SELECT 'Spoofing flags', COUNT(*) FROM SPOOFING_LAYERING_SIGNALS WHERE JURISDICTION_ID = '{jurisdiction_id}' AND IS_FLAGGED
        UNION ALL SELECT 'Position-limit breaches', COUNT(*) FROM POSITION_LIMIT_BREACHES WHERE JURISDICTION_ID = '{jurisdiction_id}' AND IS_BREACH
    """)
    cols = st.columns(len(counts))
    for col, (_, row) in zip(cols, counts.iterrows()):
        col.metric(row["METRIC"], int(row["VALUE"]))

    st.info(
        "**Investigate** a trade/participant/instrument/venue by ID · **Report** the status of "
        "one regulatory filing · **Sign off & Submit** its assurance verdict, audit trail, and "
        "final download · **Chat** anything the other tabs don't have a box for — any ID shown "
        "anywhere below is a real question Chat can answer, not just a display value."
    )

    st.subheader("Venues")
    venues = q(f"""
        SELECT VENUE_ID, VENUE_TYPE, STATUS, ACTIVE_FROM, DISCONTINUED_AT
        FROM VENUES_CURRENT WHERE JURISDICTION_ID = '{jurisdiction_id}' ORDER BY STATUS, VENUE_ID
    """)
    st.dataframe(venues, width='stretch')
    download_csv_button(venues, "Download CSV", f"venues_{jurisdiction_id}")
    st.caption(
        "Discontinued venues (DISCONTINUED_AT populated) keep their historical trades fully "
        "representable — a generator/adaptor stops producing new activity past that date, "
        "nothing is deleted or excluded."
    )

# ---------------------------------------------------------------------------
# Investigate (signal -> evidence): case search across all 4 detector families, or browse one
# detector at a time -- both paths reuse the exact detector views Phase 8's tabs always used.
# ---------------------------------------------------------------------------
with tabs[1]:
    st.subheader("Investigate")
    st.caption(
        "Search a TRADE_ID, PARTICIPANT_ID, INSTRUMENT_ID (stock code), or VENUE_ID to see the "
        "underlying trades, any transaction report that covers them, and every detector finding "
        "that touches it — wash trading, spoofing, position limits, best execution, all at once. "
        "Leave it empty to browse one detector family at a time."
    )
    search_id = st.text_input("Search by ID", key="investigate_search").strip()

    if search_id:
        st.markdown(f"#### Case: `{search_id}`")

        trade_hits = q_params("""
            SELECT TRADE_ID, EXECUTION_TIMESTAMP, INSTRUMENT_ID, PARTICIPANT_ID,
                   COUNTERPARTY_PARTICIPANT_ID, VENUE_ID, PRICE, CURRENCY, VOLUME, MATCHING_MECHANISM
            FROM TRADES
            WHERE JURISDICTION_ID = ?
              AND (TRADE_ID = ? OR INSTRUMENT_ID = ? OR PARTICIPANT_ID = ?
                   OR COUNTERPARTY_PARTICIPANT_ID = ? OR VENUE_ID = ?)
            ORDER BY EXECUTION_TIMESTAMP
        """, (jurisdiction_id, search_id, search_id, search_id, search_id, search_id))
        if not trade_hits.empty:
            st.write(f"Trades ({len(trade_hits)})")
            st.dataframe(trade_hits, width='stretch')
            download_csv_button(trade_hits, "Download CSV", f"trades_{search_id}")

            report_hits = q_params("""
                SELECT REPORT_ID, REPORT_TYPE, REPORT_STATUS, TRADE_ID, REPORT_PAYLOAD_REF
                FROM TRANSACTION_REPORTS_CURRENT
                WHERE JURISDICTION_ID = ? AND TRADE_ID IN (
                    SELECT TRADE_ID FROM TRADES
                    WHERE JURISDICTION_ID = ?
                      AND (TRADE_ID = ? OR INSTRUMENT_ID = ? OR PARTICIPANT_ID = ?
                           OR COUNTERPARTY_PARTICIPANT_ID = ? OR VENUE_ID = ?)
                )
            """, (jurisdiction_id, jurisdiction_id, search_id, search_id, search_id, search_id, search_id))
            if not report_hits.empty:
                st.write("Reports covering these trades")
                st.caption("Search the REPORT_ID below in the Report tab for its full status and download.")
                st.dataframe(report_hits, width='stretch')
                download_csv_button(report_hits, "Download CSV", f"reports_for_{search_id}")
            else:
                st.info("No transaction report references any of these trades yet.")

        p = (jurisdiction_id, search_id, search_id, search_id, search_id)
        wash_hits = q_params(f"""
            SELECT TRADE_ID_1, TRADE_ID_2, VENUE_ID, INSTRUMENT_ID, CANDIDATE_TYPE,
                   MATCHING_MECHANISM, IS_TRIGGER_EXEMPT
            FROM WASH_TRADING_CANDIDATES
            WHERE JURISDICTION_ID = ?
              AND (TRADE_ID_1 = ? OR TRADE_ID_2 = ? OR VENUE_ID = ? OR INSTRUMENT_ID = ?)
        """, p)
        spoof_hits = q_params(f"""
            SELECT PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, EVENT_DATE, CANCEL_RATIO,
                   CANCEL_RATIO_ZSCORE, IS_FLAGGED
            FROM SPOOFING_LAYERING_SIGNALS
            WHERE JURISDICTION_ID = ?
              AND (PARTICIPANT_ID = ? OR INSTRUMENT_ID = ? OR VENUE_ID = ?)
        """, (jurisdiction_id, search_id, search_id, search_id))
        poslim_hits = q_params(f"""
            SELECT PARTICIPANT_ID, INSTRUMENT_ID, AS_OF_DATE, NET_QUANTITY, LIMIT_QUANTITY,
                   PCT_OF_LIMIT, IS_BREACH
            FROM POSITION_LIMIT_BREACHES
            WHERE JURISDICTION_ID = ? AND (PARTICIPANT_ID = ? OR INSTRUMENT_ID = ?)
        """, (jurisdiction_id, search_id, search_id))
        exec_hits = q_params(
            "SELECT * FROM EXECUTION_SLIPPAGE WHERE JURISDICTION_ID = ? AND TRADE_ID = ?",
            (jurisdiction_id, search_id),
        )
        arrival_hits = q_params(
            "SELECT * FROM ARRIVAL_SLIPPAGE WHERE JURISDICTION_ID = ? AND TRADE_ID = ?",
            (jurisdiction_id, search_id),
        )

        any_finding_hits = not (wash_hits.empty and spoof_hits.empty and poslim_hits.empty
                                 and exec_hits.empty and arrival_hits.empty)
        if not any_finding_hits:
            if trade_hits.empty:
                st.info(f"Nothing matches `{search_id}` in {jurisdiction_id} — no trades and no detector finding.")
            else:
                st.info(f"No detector finding mentions `{search_id}` — the trades above exist but weren't flagged by anything.")
        else:
            if not wash_hits.empty:
                st.write("Wash-trading candidates")
                st.dataframe(wash_hits, width='stretch')
                download_csv_button(wash_hits, "Download CSV", f"wash_{search_id}")
            if not spoof_hits.empty:
                st.write("Spoofing / layering signals")
                st.dataframe(spoof_hits, width='stretch')
                download_csv_button(spoof_hits, "Download CSV", f"spoof_{search_id}")
            if not poslim_hits.empty:
                st.write("Position-limit breaches")
                st.dataframe(poslim_hits, width='stretch')
                download_csv_button(poslim_hits, "Download CSV", f"poslim_{search_id}")
            if not exec_hits.empty:
                st.write("Execution slippage")
                st.dataframe(exec_hits, width='stretch')
                download_csv_button(exec_hits, "Download CSV", f"execslip_{search_id}")
            if not arrival_hits.empty:
                st.write("Arrival slippage")
                st.dataframe(arrival_hits, width='stretch')
                download_csv_button(arrival_hits, "Download CSV", f"arrslip_{search_id}")
        ask_chat_inline(search_id, key="investigate")
    else:
        detector = st.radio(
            "Detector", ["Wash Trading", "Spoofing / Layering", "Position Limits", "Best Execution"],
            horizontal=True, key="investigate_detector",
        )

        if detector == "Wash Trading":
            st.caption(
                "\"No wash trades found\" and \"no wash trades could be checked for\" are "
                "structurally different claims — the coverage table below is what makes that "
                "distinction visible (Fix #3: never shown without it)."
            )
            wash = q(f"""
                SELECT TRADE_ID_1, TRADE_ID_2, VENUE_ID, INSTRUMENT_ID, CANDIDATE_TYPE,
                       MATCHING_MECHANISM, IS_TRIGGER_EXEMPT
                FROM WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID = '{jurisdiction_id}'
                ORDER BY IS_TRIGGER_EXEMPT, VENUE_ID
            """)
            st.dataframe(wash, width='stretch')
            download_csv_button(wash, "Download CSV", f"wash_{jurisdiction_id}")
            null_exempt = wash["IS_TRIGGER_EXEMPT"].isna().sum() if not wash.empty else 0
            if null_exempt:
                st.error(f"{null_exempt} row(s) with NULL IS_TRIGGER_EXEMPT — missing calibration, review required.")
            else:
                st.success("No NULL IS_TRIGGER_EXEMPT rows — every candidate resolves to a definite exempt/flag decision.")

            st.write("Detection coverage")
            coverage = q(f"""
                SELECT VENUE_ID, TRADE_DATE, TOTAL_TRADES, RESOLVABLE_TRADES,
                       PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY
                FROM WASH_DETECTION_COVERAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'
                ORDER BY PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY ASC
            """)
            st.dataframe(coverage, width='stretch')
            download_csv_button(coverage, "Download CSV", f"wash_coverage_{jurisdiction_id}")

        elif detector == "Spoofing / Layering":
            st.caption(
                "This detector flags a change in a participant's own behavior, not a uniformly "
                "high cancel ratio from day one — pick a participant to see their trend."
            )
            participants = q(f"""
                SELECT DISTINCT PARTICIPANT_ID FROM SPOOFING_LAYERING_SIGNALS
                WHERE JURISDICTION_ID = '{jurisdiction_id}' ORDER BY 1
            """)
            if not participants.empty:
                pid = st.selectbox("Participant", participants["PARTICIPANT_ID"])
                spoof = q(f"""
                    SELECT EVENT_DATE, CANCEL_RATIO, CANCEL_RATIO_ZSCORE, IS_FLAGGED
                    FROM SPOOFING_LAYERING_SIGNALS
                    WHERE JURISDICTION_ID = '{jurisdiction_id}' AND PARTICIPANT_ID = '{pid}'
                    ORDER BY EVENT_DATE
                """)
                st.line_chart(spoof.set_index("EVENT_DATE")[["CANCEL_RATIO", "CANCEL_RATIO_ZSCORE"]])
                st.dataframe(spoof, width='stretch')
                download_csv_button(spoof, "Download CSV", f"spoof_{pid}")
            else:
                st.info("No spoofing signal rows for this jurisdiction.")

            st.write("Currently flagged")
            flagged = q(f"""
                SELECT PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, EVENT_DATE, CANCEL_RATIO, CANCEL_RATIO_ZSCORE
                FROM SPOOFING_LAYERING_SIGNALS WHERE JURISDICTION_ID = '{jurisdiction_id}' AND IS_FLAGGED
                ORDER BY CANCEL_RATIO_ZSCORE DESC
            """)
            st.dataframe(flagged, width='stretch')
            download_csv_button(flagged, "Download CSV", f"spoof_flagged_{jurisdiction_id}")

        elif detector == "Position Limits":
            st.caption("Threshold comes entirely from DETECTOR_CALIBRATION.PARAMS — never a literal in this view.")
            pos = q(f"""
                SELECT PARTICIPANT_ID, INSTRUMENT_ID, AS_OF_DATE, NET_QUANTITY, LIMIT_QUANTITY,
                       PCT_OF_LIMIT, IS_BREACH
                FROM POSITION_LIMIT_BREACHES WHERE JURISDICTION_ID = '{jurisdiction_id}'
                ORDER BY PCT_OF_LIMIT DESC
            """)
            st.dataframe(pos, width='stretch')
            download_csv_button(pos, "Download CSV", f"poslim_{jurisdiction_id}")
            if not pos.empty:
                st.bar_chart(pos.set_index("PARTICIPANT_ID")["PCT_OF_LIMIT"].head(20))

        else:  # Best Execution
            exec_slip = q(f"SELECT * FROM EXECUTION_SLIPPAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'")
            arrival_slip = q(f"SELECT * FROM ARRIVAL_SLIPPAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'")
            if exec_slip.empty and arrival_slip.empty:
                st.info(
                    "No rows — either this jurisdiction has no underlying trade data at all, or "
                    "none of its trades have a TRADE_REFERENCE_PRICES row (real production data "
                    "would come from TRADE_REFERENCE_PRICES' own external adaptor, per "
                    "architecture.md; the demo dataset backfills it with clearly-labeled "
                    "SOURCE='synthetic_nbbo_equivalent' rows instead)."
                )
            else:
                st.write("Execution slippage")
                st.dataframe(exec_slip, width='stretch')
                download_csv_button(exec_slip, "Download CSV", f"execslip_{jurisdiction_id}")
                st.write("Arrival slippage")
                st.dataframe(arrival_slip, width='stretch')
                download_csv_button(arrival_slip, "Download CSV", f"arrslip_{jurisdiction_id}")

    st.divider()
    with st.expander("Surveillance Operator: log an official run (acts as AUDIT_INSERT)"):
        st.caption(
            "Runs the same five detector counts shown across this app through "
            "SP_LOG_SURVEILLANCE_RUN and writes one append-only row per detector to the audit "
            "trail (visible in Sign off & Submit). This really switches this session's Snowflake "
            "role to AUDIT_INSERT for the call, then back to ANALYST_READ immediately after — "
            "not a UI simulation."
        )
        if st.button(f"Log a surveillance run for {jurisdiction_id}", key="run_audit_btn"):
            with st.spinner("Switching role to AUDIT_INSERT and logging…"):
                try:
                    with acting_as("AUDIT_INSERT"):
                        session.sql("CALL SP_LOG_SURVEILLANCE_RUN(?)", params=[jurisdiction_id]).collect()
                    q.clear()
                    q_params.clear()
                    st.success("Logged — see it in Sign off & Submit.")
                except Exception as e:
                    st.error(f"Failed: {e}")

# ---------------------------------------------------------------------------
# Report (obligation -> report): search one REPORT_ID's full status, or browse everything
# needing attention / template coverage, as before.
# ---------------------------------------------------------------------------
with tabs[2]:
    st.subheader("Report")
    st.caption(
        "Search a REPORT_ID for that report's full status — template coverage, timeliness/match "
        "status, and whether a submission payload has been rendered. Leave it empty to browse "
        "reports needing attention or overall template coverage."
    )
    search_report_id = st.text_input("Search by REPORT_ID", key="report_search").strip()

    if search_report_id:
        st.markdown(f"#### Case: `{search_report_id}`")
        report_row = q_params(
            "SELECT * FROM TRANSACTION_REPORTS_CURRENT WHERE JURISDICTION_ID = ? AND REPORT_ID = ?",
            (jurisdiction_id, search_report_id),
        )
        if report_row.empty:
            st.info(f"No report `{search_report_id}` found for {jurisdiction_id}.")
        else:
            st.dataframe(report_row, width='stretch')
            download_csv_button(report_row, "Download CSV", f"report_{search_report_id}")

            timeliness_row = q_params(
                "SELECT * FROM REPORTING_TIMELINESS_SIGNALS WHERE JURISDICTION_ID = ? AND REPORT_ID = ?",
                (jurisdiction_id, search_report_id),
            )
            if not timeliness_row.empty:
                st.write("Timeliness / completeness / match status")
                st.dataframe(timeliness_row, width='stretch')
                download_csv_button(timeliness_row, "Download CSV", f"timeliness_{search_report_id}")

            payload_ref = report_row.iloc[0].get("REPORT_PAYLOAD_REF")
            if payload_ref:
                file_bytes = session.file.get_stream(payload_ref, decompress=False).read()
                file_name = payload_ref.rsplit("/", 1)[-1]
                st.download_button(
                    f"Download rendered payload ({file_name})",
                    data=file_bytes,
                    file_name=file_name,
                    mime="application/xml" if file_name.endswith(".xml") else "text/csv",
                    key=f"payload_dl_{search_report_id}",
                )
            else:
                st.info("No payload rendered yet for this report — see Market Data Ops below.")
        ask_chat_inline(search_report_id, key="report")
    else:
        st.write("Reports needing attention")
        timeliness = q(f"""
            SELECT REPORT_ID, VENUE_ID, REPORT_TYPE, IS_OVERDUE_UNSUBMITTED, IS_LATE_SUBMISSION,
                   IS_INCOMPLETE, IS_MISMATCHED
            FROM REPORTING_TIMELINESS_SIGNALS
            WHERE JURISDICTION_ID = '{jurisdiction_id}'
              AND (IS_OVERDUE_UNSUBMITTED OR IS_LATE_SUBMISSION OR IS_INCOMPLETE OR IS_MISMATCHED)
            ORDER BY REPORT_ID
        """)
        st.dataframe(timeliness, width='stretch')
        download_csv_button(timeliness, "Download CSV", f"reports_attention_{jurisdiction_id}")

        st.write("Template coverage (Fix #28 — the template's own completeness, not one report's)")
        coverage_tpl = q(f"""
            SELECT REPORT_TYPE, REQUIRED_FIELD_COUNT, MAPPED_REQUIRED_FIELD_COUNT,
                   PCT_REQUIRED_FIELDS_MAPPED, GAP_FIELD_NAMES
            FROM REPORT_TEMPLATE_COVERAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'
        """)
        st.dataframe(coverage_tpl, width='stretch')
        download_csv_button(coverage_tpl, "Download CSV", f"template_coverage_{jurisdiction_id}")
        for _, row in coverage_tpl.iterrows():
            if row["PCT_REQUIRED_FIELDS_MAPPED"] < 1.0:
                st.warning(
                    f"{row['REPORT_TYPE']}: {row['GAP_FIELD_NAMES']} required with no current "
                    "data source (gap — surfaced, not fabricated or hidden)."
                )

    st.divider()
    with st.expander("Market Data Ops: render a report payload (acts as MARKET_DATA_INGEST)"):
        unrendered = q_params("""
            SELECT REPORT_ID, REPORT_TYPE FROM TRANSACTION_REPORTS_CURRENT
            WHERE JURISDICTION_ID = ? AND REPORT_PAYLOAD_REF IS NULL ORDER BY REPORT_ID
        """, (jurisdiction_id,))
        if unrendered.empty:
            st.info("Every report for this jurisdiction already has a rendered payload.")
        else:
            render_target = st.selectbox("Report to render", unrendered["REPORT_ID"], key="render_target")
            render_fmt = st.radio("Format", ["CSV", "XML"], horizontal=True, key="render_fmt")
            if st.button(f"Render {render_target}", key="render_btn"):
                proc = "SP_RENDER_REPORT_PAYLOAD" if render_fmt == "CSV" else "SP_RENDER_REPORT_PAYLOAD_XML"
                with st.spinner(f"Switching role to MARKET_DATA_INGEST and calling {proc}…"):
                    try:
                        with acting_as("MARKET_DATA_INGEST"):
                            session.sql(f"CALL {proc}(?, ?)", params=[render_target, jurisdiction_id]).collect()
                        q.clear()
                        q_params.clear()
                        st.success(f"Rendered — search {render_target} above to download it.")
                    except Exception as e:
                        st.error(f"Failed: {e}")

    with st.expander("Governance Reviewer: propose a new obligation (acts as GOVERNANCE_WRITE)"):
        with st.form("propose_obligation_form"):
            p_obligation_id = st.text_input("Obligation ID")
            p_description = st.text_area("Description")
            p_source_table = st.text_input("Source table")
            p_source_columns = st.text_input("Source columns (comma-separated)")
            p_detector_name = st.text_input("Detector name")
            propose_submitted = st.form_submit_button("Propose")
        if propose_submitted:
            with st.spinner("Switching role to GOVERNANCE_WRITE and proposing…"):
                try:
                    with acting_as("GOVERNANCE_WRITE"):
                        session.sql(
                            "CALL SP_PROPOSE_OBLIGATION(?, ?, ?, ?, ?, ?)",
                            params=[p_obligation_id, jurisdiction_id, p_description,
                                    p_source_table, p_source_columns, p_detector_name],
                        ).collect()
                    st.success(f"Proposed {p_obligation_id}.")
                except Exception as e:
                    st.error(f"Failed: {e}")

    with st.expander("Governance Reviewer: approve a pending obligation (acts as GOVERNANCE_WRITE)"):
        st.caption(
            "ANALYST_READ structurally cannot see a proposed-but-unapproved obligation "
            "(architecture.md's governance gate) — this list is queried as GOVERNANCE_WRITE."
        )
        try:
            with acting_as("GOVERNANCE_WRITE"):
                pending = session.sql("""
                    SELECT OBLIGATION_ID, OBLIGATION_DESCRIPTION, SOURCE_TABLE, SOURCE_COLUMNS,
                           DETECTOR_NAME
                    FROM OBLIGATION_MAP
                    WHERE JURISDICTION_ID = ?
                    QUALIFY ROW_NUMBER() OVER (
                        PARTITION BY OBLIGATION_ID, JURISDICTION_ID ORDER BY LOADED_AT DESC
                    ) = 1
                    AND STATUS = 'proposed'
                """, params=[jurisdiction_id]).to_pandas()
        except Exception as e:
            pending = pd.DataFrame()
            st.error(f"Could not load pending obligations: {e}")
        if pending.empty:
            st.info("No proposed obligations pending approval for this jurisdiction.")
        else:
            st.dataframe(pending, width='stretch')
            approve_target = st.selectbox("Obligation to approve", pending["OBLIGATION_ID"], key="approve_target")
            if st.button(f"Approve {approve_target}", key="approve_btn"):
                row = pending.loc[pending["OBLIGATION_ID"] == approve_target].iloc[0]
                with st.spinner("Switching role to GOVERNANCE_WRITE and approving…"):
                    try:
                        with acting_as("GOVERNANCE_WRITE"):
                            session.sql(
                                "CALL SP_APPROVE_OBLIGATION(?, ?, ?, ?, ?, ?)",
                                params=[approve_target, jurisdiction_id, row["OBLIGATION_DESCRIPTION"],
                                        row["SOURCE_TABLE"], row["SOURCE_COLUMNS"], row["DETECTOR_NAME"]],
                            ).collect()
                        st.success(f"Approved {approve_target}.")
                    except Exception as e:
                        st.error(f"Failed: {e}")

# ---------------------------------------------------------------------------
# Sign off & Submit (assurance -> audit -> submission): search a REPORT_ID or RUN_ID's verdict
# and audit-trail entries together, or browse everything logged so far.
# ---------------------------------------------------------------------------
with tabs[3]:
    st.subheader("Sign off & Submit")
    st.caption(
        "Search a REPORT_ID or RUN_ID to see its assurance verdict and matching audit-trail "
        "entries together. Leave it empty to browse everything logged so far."
    )
    search_id2 = st.text_input("Search by REPORT_ID or RUN_ID", key="signoff_search").strip()

    if search_id2:
        st.markdown(f"#### Case: `{search_id2}`")
        findings_hit = q_params("""
            SELECT F.RUN_ID, F.REPORT_ID, F.CREATED_AT, F.APP_USER, F.READY_TO_SUBMIT,
                   F.FIELDS_COMPLETE, F.UNRESOLVED_REQUIRED_FIELDS, F.GAP_FIELDS, F.REASONS
            FROM DOCUMENTED_FINDINGS_LOG F
            JOIN TRANSACTION_REPORTS_CURRENT R ON R.REPORT_ID = F.REPORT_ID
            WHERE R.JURISDICTION_ID = ? AND (F.REPORT_ID = ? OR F.RUN_ID = ?)
            ORDER BY F.CREATED_AT DESC
        """, (jurisdiction_id, search_id2, search_id2))
        audit_hit = q_params("""
            SELECT RUN_ID, DETECTOR_NAME, CREATED_AT, APP_USER, FLAGGED_COUNT
            FROM SURVEILLANCE_RUN_LOG WHERE JURISDICTION_ID = ? AND RUN_ID = ?
        """, (jurisdiction_id, search_id2))
        if findings_hit.empty and audit_hit.empty:
            st.info(f"No assurance verdict or audit-trail entry for `{search_id2}` in {jurisdiction_id}.")
        else:
            if not findings_hit.empty:
                st.write("Assurance verdict")
                st.dataframe(findings_hit, width='stretch')
                download_csv_button(findings_hit, "Download CSV", f"findings_{search_id2}")
            if not audit_hit.empty:
                st.write("Audit trail")
                st.dataframe(audit_hit, width='stretch')
                download_csv_button(audit_hit, "Download CSV", f"audit_{search_id2}")
        ask_chat_inline(search_id2, key="signoff")
    else:
        st.write("Assurance verdicts")
        st.caption(
            "Each verdict is computed offline by assure_report.py's real field-mapping/gap-"
            "analysis logic (scripts/generate_documented_findings.py) — REPORT_TEMPLATES."
            "SOURCE_MAPPING is free text a live view can't generically resolve, so this is a "
            "read-only log, not a query this dashboard re-issues on demand."
        )
        findings = q(f"""
            SELECT F.RUN_ID, F.REPORT_ID, F.CREATED_AT, F.APP_USER, F.READY_TO_SUBMIT,
                   F.FIELDS_COMPLETE, F.UNRESOLVED_REQUIRED_FIELDS, F.GAP_FIELDS, F.REASONS
            FROM DOCUMENTED_FINDINGS_LOG F
            JOIN TRANSACTION_REPORTS_CURRENT R ON R.REPORT_ID = F.REPORT_ID
            WHERE R.JURISDICTION_ID = '{jurisdiction_id}'
            ORDER BY F.CREATED_AT DESC
        """)
        if findings.empty:
            st.info("No documented findings logged yet for this jurisdiction.")
        else:
            not_ready = int((~findings["READY_TO_SUBMIT"].astype(bool)).sum())
            if not_ready:
                st.warning(f"{not_ready} report(s) not ready to submit — see REASONS below.")
            else:
                st.success("Every documented report is ready to submit.")
            st.dataframe(findings, width='stretch')
            download_csv_button(findings, "Download CSV", f"findings_{jurisdiction_id}")

        st.write("Detector run history")
        st.caption(
            "Every row is a real logged snapshot (SP_LOG_SURVEILLANCE_RUN, AUDIT_LOG, append-"
            "only) of the same detector counts shown live in Investigate — not a separate "
            "computation. Produced by the scheduled TASK_SURVEILLANCE_RUN_JP (created suspended, "
            "see sql/tasks/) when resumed, or by the Surveillance Operator action in Investigate."
        )
        runs = q(f"""
            SELECT RUN_ID, DETECTOR_NAME, CREATED_AT, APP_USER, FLAGGED_COUNT
            FROM SURVEILLANCE_RUN_LOG WHERE JURISDICTION_ID = '{jurisdiction_id}'
            ORDER BY CREATED_AT DESC
        """)
        if runs.empty:
            st.info("No surveillance runs logged yet for this jurisdiction.")
        else:
            st.caption(
                f"As of {runs['CREATED_AT'].max()} — a same-day count is only current as of this "
                "timestamp, not a final total, since more scheduled runs may still occur before "
                "the day ends."
            )
            st.dataframe(runs, width='stretch')
            download_csv_button(runs, "Download CSV", f"audit_{jurisdiction_id}")

    st.divider()
    with st.expander("Compliance Officer: record a sign-off (acts as OFFICER_SIGNOFF)"):
        st.caption(
            "SP_RECORD_SIGNOFF binds SIGNOFF_BY to CURRENT_USER() — un-spoofable, the recorded "
            "identity is always whoever's session actually calls it, never an asserted value."
        )
        signoff_runs = q(f"""
            SELECT RUN_ID, DETECTOR_NAME, CREATED_AT FROM SURVEILLANCE_RUN_LOG
            WHERE JURISDICTION_ID = '{jurisdiction_id}' ORDER BY CREATED_AT DESC
        """)
        if signoff_runs.empty:
            st.info("No logged runs to sign off on yet for this jurisdiction.")
        else:
            signoff_target = st.selectbox(
                "Run to sign off on",
                signoff_runs["RUN_ID"],
                format_func=lambda rid: f"{rid} ({signoff_runs.set_index('RUN_ID').loc[rid, 'DETECTOR_NAME']})",
                key="signoff_target",
            )
            decision = st.radio("Decision", ["approved", "rejected"], horizontal=True, key="signoff_decision")
            if st.button("Record sign-off", key="signoff_btn"):
                with st.spinner("Switching role to OFFICER_SIGNOFF and recording…"):
                    try:
                        with acting_as("OFFICER_SIGNOFF"):
                            session.sql(
                                "CALL SP_RECORD_SIGNOFF(?, ?)", params=[signoff_target, decision]
                            ).collect()
                        q.clear()
                        q_params.clear()
                        st.success(f"Recorded: {decision} for {signoff_target}.")
                    except Exception as e:
                        st.error(f"Failed: {e}")

# ---------------------------------------------------------------------------
# Chat -- natural-language surface over VIGIL_SURVEILLANCE_AGENT (cortex_project/vigil_agent.sql).
# Same 5 tools the tabs above are hardcoded proxies for (trade_surveillance, obligations_reporting,
# surveillance_audit, detector_findings, rule_search) -- this tab lets a viewer ask a question the
# fixed tabs don't have a filter for. Any ID shown anywhere above is a real question here too.
# ---------------------------------------------------------------------------
with tabs[4]:
    st.subheader("Ask Vigil")
    st.caption(
        "Backed by the live VIGIL_SURVEILLANCE_AGENT (SNOWFLAKE.CORTEX.DATA_AGENT_RUN) -- the "
        "same agent verified in NOTES.md's adversarial routing/honesty tests, not a separate "
        "chatbot. Runs under your own role, same as every other tab. Try pasting any ID from "
        "Investigate, Report, or Sign off & Submit."
    )

    if "chat_messages" not in st.session_state:
        st.session_state.chat_messages = []

    for msg in st.session_state.chat_messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            for c in msg.get("citations", []):
                st.caption(f"📄 {c.get('doc_title', c.get('doc_id', 'source'))}")

    if st.session_state.chat_messages and st.button("Clear conversation"):
        st.session_state.chat_messages = []
        st.rerun()

    user_prompt = st.chat_input("Ask about trades, obligations, detector findings, or a rule…")
    if user_prompt:
        with st.chat_message("user"):
            st.markdown(user_prompt)
        with st.chat_message("assistant"):
            with st.spinner("Querying VIGIL_SURVEILLANCE_AGENT…"):
                answer, citations = send_chat_message(user_prompt)
            st.markdown(answer)
            for c in citations:
                st.caption(f"📄 {c.get('doc_title', c.get('doc_id', 'source'))}")
