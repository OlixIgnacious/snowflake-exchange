"""One-off incremental patch, append-only (no deletes/updates -- consistent with this project's
milestoning discipline): adds what the already-loaded Japan dataset was missing, discovered by
actually checking the detectors' behavior against real data rather than just unit tests.

1. DETECTOR_CALIBRATION rows for CBOJ/CBOJBIDS (wash_trading, spoofing_layering) -- the original
   load only seeded active venues; a discontinued venue's historical trades still need to be
   surveillable (architecture.md's whole rationale for date-bounding instead of exclusion). Fixed
   at the source in generator/generate.py too, for any future from-scratch load.

2. A genuine baseline-then-spike spoofing/layering test case (new participant P999, new
   MARKET_PARTICIPANTS row) -- the original injected spoof_participant behaved uniformly badly
   from day one, so the z-score-against-own-trailing-baseline detector correctly never flagged
   it (no deviation from itself to detect). This adds a case that actually changes behavior
   partway through, which is what this specific detection method is designed to catch.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from run_sql import connect

NOW = datetime(2026, 9, 14)
SIM_START = datetime(2025, 6, 1).date()


def patch_calibration(cur):
    for venue in ["CBOJ", "CBOJBIDS"]:
        cur.execute(
            """
            INSERT INTO DETECTOR_CALIBRATION
            (JURISDICTION_ID, VENUE_ID, DETECTOR_NAME, DIMENSION_KEY, Z_THRESHOLD, MIN_BASELINE_PERIODS,
             PARAMS, IS_PROVISIONAL, EFFECTIVE_FROM, CALIBRATED_AT, CALIBRATION_METHOD, CALIBRATED_BY,
             CREATED_AT, CREATED_BY)
            SELECT 'JP', %(v)s, 'wash_trading', NULL, NULL, NULL,
                   PARSE_JSON(%(params)s), TRUE, %(eff)s, %(now)s, 'default-uncalibrated', 'generator-patch',
                   %(now)s, 'generator-patch'
            """,
            {
                "v": venue,
                "params": json.dumps({
                    "time_window_seconds": 300,
                    "price_tolerance_pct": 0.01,
                    "exempt_matching_mechanisms": ["cross"],
                }),
                "eff": SIM_START,
                "now": NOW,
            },
        )
        cur.execute(
            """
            INSERT INTO DETECTOR_CALIBRATION
            (JURISDICTION_ID, VENUE_ID, DETECTOR_NAME, DIMENSION_KEY, Z_THRESHOLD, MIN_BASELINE_PERIODS,
             PARAMS, IS_PROVISIONAL, EFFECTIVE_FROM, CALIBRATED_AT, CALIBRATION_METHOD, CALIBRATED_BY,
             CREATED_AT, CREATED_BY)
            VALUES ('JP', %(v)s, 'spoofing_layering', NULL, 2.5, 3,
                   NULL, TRUE, %(eff)s, %(now)s, 'default-uncalibrated', 'generator-patch',
                   %(now)s, 'generator-patch')
            """,
            {"v": venue, "eff": SIM_START, "now": NOW},
        )
    print("Calibration patched for CBOJ/CBOJBIDS (wash_trading + spoofing_layering)")


def patch_spoofing_case(cur):
    participant, instrument, venue = "P999", "I00", "XTKS"
    cur.execute(
        """
        INSERT INTO MARKET_PARTICIPANTS
        (PARTICIPANT_ID, JURISDICTION_ID, PARTICIPANT_TYPE, BENEFICIAL_OWNER_ID, CREATED_AT, CREATED_BY, LOADED_AT, LOADED_BY)
        VALUES (%(p)s, 'JP', 'proprietary', NULL, %(now)s, 'generator-patch', %(now)s, 'generator-patch')
        """,
        {"p": participant, "now": NOW},
    )

    order_rows = []
    for day_offset in range(15):
        day = SIM_START + timedelta(days=day_offset * 3)
        is_spike = day_offset >= 10
        n_cancel = 15 if is_spike else 2
        for i in range(n_cancel):
            oid = f"OSPIKE{day_offset:03d}{i:03d}"
            ts = datetime(day.year, day.month, day.day, 10, 0) + timedelta(minutes=i)
            qty = 2000
            order_rows.append((oid, "JP", venue, instrument, participant, "buy", "limit", "new",
                                ts, 300.0, "JPY", qty, 0, ts, "generator-patch", ts, "generator-patch"))
            order_rows.append((oid, "JP", venue, instrument, participant, "buy", "limit", "cancel",
                                ts + timedelta(seconds=5), 300.0, "JPY", qty, 0, ts, "generator-patch",
                                ts + timedelta(seconds=5), "generator-patch"))
        for k in range(8):
            oid2 = f"OSPIKESELL{day_offset:03d}{k:03d}"
            ts2 = datetime(day.year, day.month, day.day, 15, 0) + timedelta(minutes=k)
            order_rows.append((oid2, "JP", venue, instrument, participant, "sell", "limit", "new",
                                ts2, 300.0, "JPY", 500, 0, ts2, "generator-patch", ts2, "generator-patch"))

    cols = ("ORDER_ID, JURISDICTION_ID, VENUE_ID, INSTRUMENT_ID, PARTICIPANT_ID, SIDE, ORDER_TYPE, "
            "EVENT_TYPE, EVENT_TS, PRICE, CURRENCY, QUANTITY, FILLED_QUANTITY, CREATED_AT, CREATED_BY, "
            "LOADED_AT, LOADED_BY")
    placeholders = ", ".join(["%s"] * 17)
    cur.executemany(f"INSERT INTO ORDERS ({cols}) VALUES ({placeholders})", order_rows)
    print(f"Inserted {len(order_rows)} supplementary spoofing-test ORDERS rows for {participant}")


def main():
    conn = connect()
    cur = conn.cursor()
    cur.execute("USE ROLE ACCOUNTADMIN")
    cur.execute("USE SECONDARY ROLES NONE")
    cur.execute("USE DATABASE VIGIL")
    cur.execute("USE SCHEMA CORE")
    patch_calibration(cur)
    patch_spoofing_case(cur)
    conn.close()


if __name__ == "__main__":
    main()
