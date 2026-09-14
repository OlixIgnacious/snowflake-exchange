"""Vigil dashboard -- Streamlit in Snowflake (Phase 8 demo layer, plan.md).

Runs inside Snowflake (Snowsight), using the viewer's own role via `get_active_session()` --
deliberately not ACCOUNTADMIN-only: every query below routes through the same detector/semantic
views ANALYST_READ is granted (sql/rbac/), so this app naturally respects the RBAC governance
gate rather than bypassing it for the demo's convenience. Self-contained in one file (no import
of this repo's other modules) since a Streamlit-in-Snowflake stage only ships the files
explicitly uploaded to it -- see NOTES.md for the deployment record.
"""
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Vigil", layout="wide")
session = get_active_session()


@st.cache_data(ttl=60)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


st.title("Vigil — Market Surveillance & Regulatory Reporting")
st.caption(
    "Live against VIGIL.CORE. Every number on this page is a real query result over the "
    "synthetic Japan dataset (Phase 5) — nothing here is mocked or precomputed."
)

jurisdictions = q("SELECT JURISDICTION_ID FROM JURISDICTIONS_CURRENT ORDER BY 1")
jurisdiction_id = st.sidebar.selectbox(
    "Jurisdiction", jurisdictions["JURISDICTION_ID"] if not jurisdictions.empty else ["JP"]
)

tabs = st.tabs([
    "Overview", "Trade Surveillance", "Spoofing / Layering", "Position Limits",
    "Reporting & Templates", "Best Execution",
])

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

    st.subheader("Venues")
    venues = q(f"""
        SELECT VENUE_ID, VENUE_TYPE, STATUS, ACTIVE_FROM, DISCONTINUED_AT
        FROM VENUES_CURRENT WHERE JURISDICTION_ID = '{jurisdiction_id}' ORDER BY STATUS, VENUE_ID
    """)
    st.dataframe(venues, use_container_width=True)
    st.caption(
        "Discontinued venues (DISCONTINUED_AT populated) keep their historical trades fully "
        "representable — a generator/adaptor stops producing new activity past that date, "
        "nothing is deleted or excluded."
    )

# ---------------------------------------------------------------------------
# Trade surveillance (wash trading) -- paired with coverage, never shown alone (Fix #3)
# ---------------------------------------------------------------------------
with tabs[1]:
    st.subheader("Wash-trading candidates")
    wash = q(f"""
        SELECT TRADE_ID_1, TRADE_ID_2, VENUE_ID, INSTRUMENT_ID, CANDIDATE_TYPE,
               MATCHING_MECHANISM, IS_TRIGGER_EXEMPT
        FROM WASH_TRADING_CANDIDATES WHERE JURISDICTION_ID = '{jurisdiction_id}'
        ORDER BY IS_TRIGGER_EXEMPT, VENUE_ID
    """)
    st.dataframe(wash, use_container_width=True)
    null_exempt = wash["IS_TRIGGER_EXEMPT"].isna().sum() if not wash.empty else 0
    if null_exempt:
        st.error(f"{null_exempt} row(s) with NULL IS_TRIGGER_EXEMPT — missing calibration, review required.")
    else:
        st.success("No NULL IS_TRIGGER_EXEMPT rows — every candidate resolves to a definite exempt/flag decision.")

    st.subheader("Detection coverage (Fix #3 — never show a finding without this)")
    st.caption(
        "\"No wash trades found\" and \"no wash trades could be checked for\" are structurally "
        "different claims — this table is what makes that distinction visible."
    )
    coverage = q(f"""
        SELECT VENUE_ID, TRADE_DATE, TOTAL_TRADES, RESOLVABLE_TRADES,
               PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY
        FROM WASH_DETECTION_COVERAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'
        ORDER BY PCT_TRADES_WITH_RESOLVABLE_COUNTERPARTY ASC
    """)
    st.dataframe(coverage, use_container_width=True)

# ---------------------------------------------------------------------------
# Spoofing / layering
# ---------------------------------------------------------------------------
with tabs[2]:
    st.subheader("Cancel-ratio z-score vs. own trailing baseline")
    st.caption(
        "This detector flags a change in a participant's own behavior, not a uniformly high "
        "cancel ratio from day one — a participant who has always cancelled heavily has nothing "
        "to deviate from. Pick a participant/instrument/venue below to see their trend."
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
        st.dataframe(spoof, use_container_width=True)
    else:
        st.info("No spoofing signal rows for this jurisdiction.")

    st.subheader("Currently flagged")
    flagged = q(f"""
        SELECT PARTICIPANT_ID, INSTRUMENT_ID, VENUE_ID, EVENT_DATE, CANCEL_RATIO, CANCEL_RATIO_ZSCORE
        FROM SPOOFING_LAYERING_SIGNALS WHERE JURISDICTION_ID = '{jurisdiction_id}' AND IS_FLAGGED
        ORDER BY CANCEL_RATIO_ZSCORE DESC
    """)
    st.dataframe(flagged, use_container_width=True)

# ---------------------------------------------------------------------------
# Position limits
# ---------------------------------------------------------------------------
with tabs[3]:
    st.subheader("Position vs. calibrated limit")
    st.caption("Threshold comes entirely from DETECTOR_CALIBRATION.PARAMS — never a literal in this view.")
    pos = q(f"""
        SELECT PARTICIPANT_ID, INSTRUMENT_ID, AS_OF_DATE, NET_QUANTITY, LIMIT_QUANTITY,
               PCT_OF_LIMIT, IS_BREACH
        FROM POSITION_LIMIT_BREACHES WHERE JURISDICTION_ID = '{jurisdiction_id}'
        ORDER BY PCT_OF_LIMIT DESC
    """)
    st.dataframe(pos, use_container_width=True)
    if not pos.empty:
        st.bar_chart(pos.set_index("PARTICIPANT_ID")["PCT_OF_LIMIT"].head(20))

# ---------------------------------------------------------------------------
# Reporting & templates
# ---------------------------------------------------------------------------
with tabs[4]:
    st.subheader("Reporting timeliness / completeness / match findings")
    timeliness = q(f"""
        SELECT REPORT_ID, VENUE_ID, REPORT_TYPE, IS_OVERDUE_UNSUBMITTED, IS_LATE_SUBMISSION,
               IS_INCOMPLETE, IS_MISMATCHED
        FROM REPORTING_TIMELINESS_SIGNALS
        WHERE JURISDICTION_ID = '{jurisdiction_id}'
          AND (IS_OVERDUE_UNSUBMITTED OR IS_LATE_SUBMISSION OR IS_INCOMPLETE OR IS_MISMATCHED)
        ORDER BY REPORT_ID
    """)
    st.dataframe(timeliness, use_container_width=True)

    st.subheader("Template coverage (Fix #28 — the template's own completeness, not one report's)")
    coverage_tpl = q(f"""
        SELECT REPORT_TYPE, REQUIRED_FIELD_COUNT, MAPPED_REQUIRED_FIELD_COUNT,
               PCT_REQUIRED_FIELDS_MAPPED, GAP_FIELD_NAMES
        FROM REPORT_TEMPLATE_COVERAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'
    """)
    st.dataframe(coverage_tpl, use_container_width=True)
    for _, row in coverage_tpl.iterrows():
        if row["PCT_REQUIRED_FIELDS_MAPPED"] < 1.0:
            st.warning(
                f"{row['REPORT_TYPE']}: {row['GAP_FIELD_NAMES']} required with no current data "
                "source (gap — surfaced, not fabricated or hidden)."
            )

# ---------------------------------------------------------------------------
# Best execution
# ---------------------------------------------------------------------------
with tabs[5]:
    st.subheader("Execution slippage vs. reference price")
    exec_slip = q(f"SELECT * FROM EXECUTION_SLIPPAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'")
    arrival_slip = q(f"SELECT * FROM ARRIVAL_SLIPPAGE WHERE JURISDICTION_ID = '{jurisdiction_id}'")
    if exec_slip.empty and arrival_slip.empty:
        st.info(
            "No rows — TRADE_REFERENCE_PRICES has its own external adaptor (architecture.md) "
            "and isn't populated by the Phase 5 synthetic generator. This is expected, not a bug."
        )
    else:
        st.write("Execution slippage")
        st.dataframe(exec_slip, use_container_width=True)
        st.write("Arrival slippage")
        st.dataframe(arrival_slip, use_container_width=True)
