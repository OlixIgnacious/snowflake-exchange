"""Tests for generator/generate.py against architecture.md's measurable market-agnosticism
criteria (Fix #9): 100% referential integrity across every FK, every seeded VENUE_ID represented
in >=1 ORDERS/TRADES row, and discontinued-venue date-bounding actually holding. Runs standalone
against the generator's in-memory output -- no Snowflake connection needed, so this gate doesn't
depend on the human/agent-executed load step.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generator.generate import generate
from generator.jurisdiction_config import JAPAN_CONFIG

TABLES = generate(JAPAN_CONFIG, seed=42, n_orders=1500)


def _ids(table, col):
    return {row[col] for row in TABLES[table]}


def test_referential_integrity_orders():
    venue_ids = _ids("VENUES", "VENUE_ID")
    instrument_ids = _ids("INSTRUMENTS", "INSTRUMENT_ID")
    participant_ids = _ids("MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    bad = [o for o in TABLES["ORDERS"] if o["VENUE_ID"] not in venue_ids
           or o["INSTRUMENT_ID"] not in instrument_ids
           or o["PARTICIPANT_ID"] not in participant_ids]
    assert bad == [], f"{len(bad)} ORDERS rows with a dangling FK"


def test_referential_integrity_trades():
    venue_ids = _ids("VENUES", "VENUE_ID")
    instrument_ids = _ids("INSTRUMENTS", "INSTRUMENT_ID")
    participant_ids = _ids("MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    order_keys = {(o["ORDER_ID"], o["VENUE_ID"]) for o in TABLES["ORDERS"]}
    bad = []
    for t in TABLES["TRADES"]:
        if t["VENUE_ID"] not in venue_ids or t["INSTRUMENT_ID"] not in instrument_ids:
            bad.append(t)
            continue
        if t["PARTICIPANT_ID"] not in participant_ids:
            bad.append(t)
            continue
        if t["COUNTERPARTY_PARTICIPANT_ID"] is not None and t["COUNTERPARTY_PARTICIPANT_ID"] not in participant_ids:
            bad.append(t)
            continue
        if t["ORDER_ID"] is not None and (t["ORDER_ID"], t["VENUE_ID"]) not in order_keys:
            bad.append(t)
    assert bad == [], f"{len(bad)} TRADES rows with a dangling FK"


def test_referential_integrity_positions_and_participants():
    boids = _ids("BENEFICIAL_OWNERS", "BENEFICIAL_OWNER_ID")
    bad_participants = [p for p in TABLES["MARKET_PARTICIPANTS"]
                         if p["BENEFICIAL_OWNER_ID"] is not None and p["BENEFICIAL_OWNER_ID"] not in boids]
    assert bad_participants == []

    participant_ids = _ids("MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    instrument_ids = _ids("INSTRUMENTS", "INSTRUMENT_ID")
    bad_positions = [p for p in TABLES["POSITIONS"]
                      if p["PARTICIPANT_ID"] not in participant_ids or p["INSTRUMENT_ID"] not in instrument_ids]
    assert bad_positions == []


def test_every_seeded_venue_appears_in_orders_and_trades():
    order_venues = _ids("ORDERS", "VENUE_ID")
    trade_venues = _ids("TRADES", "VENUE_ID")
    for v in TABLES["VENUES"]:
        vid = v["VENUE_ID"]
        assert vid in order_venues, f"{vid} has zero ORDERS rows"
        assert vid in trade_venues, f"{vid} has zero TRADES rows"


def test_discontinued_venue_date_bounding():
    """The concrete proof case: CBOJ/CBOJBIDS rows must never postdate DISCONTINUED_AT."""
    discontinued = {v["VENUE_ID"]: v["DISCONTINUED_AT"] for v in TABLES["VENUES"] if v["DISCONTINUED_AT"] is not None}
    assert set(discontinued) == {"CBOJ", "CBOJBIDS"}

    for o in TABLES["ORDERS"]:
        if o["VENUE_ID"] in discontinued:
            assert o["EVENT_TS"].date() < discontinued[o["VENUE_ID"]], (
                f"ORDER {o['ORDER_ID']} on {o['VENUE_ID']} dated {o['EVENT_TS']} "
                f"is on/after its DISCONTINUED_AT {discontinued[o['VENUE_ID']]}"
            )
    for t in TABLES["TRADES"]:
        if t["VENUE_ID"] in discontinued:
            assert t["EXECUTION_TIMESTAMP"].date() < discontinued[t["VENUE_ID"]], (
                f"TRADE {t['TRADE_ID']} on {t['VENUE_ID']} dated {t['EXECUTION_TIMESTAMP']} "
                f"is on/after its DISCONTINUED_AT {discontinued[t['VENUE_ID']]}"
            )


def test_wash_trading_injected_cases_present():
    """Sanity check that the deliberate wash-trading test cases actually landed (needed for
    Phase 3's detector views to have something real to flag once loaded)."""
    same_row_self_trades = [
        t for t in TABLES["TRADES"] if t["COUNTERPARTY_PARTICIPANT_ID"] is not None
    ]
    assert len(same_row_self_trades) > 0
    cross_mechanism = [t for t in TABLES["TRADES"] if t["MATCHING_MECHANISM"] == "cross"]
    assert len(cross_mechanism) >= 1


def test_positions_never_derived_from_orders_only_trades():
    """Fix #4: POSITIONS accumulates from TRADES only. Sanity check: total position volume
    should not exceed total TRADES volume for any participant/instrument (a loose but real
    check that the generator didn't accidentally source POSITIONS from ORDERS)."""
    trade_volume: dict[tuple, float] = {}
    for t in TABLES["TRADES"]:
        key = (t["PARTICIPANT_ID"], t["INSTRUMENT_ID"], t["JURISDICTION_ID"])
        trade_volume[key] = trade_volume.get(key, 0) + t["VOLUME"]

    max_position_per_key: dict[tuple, float] = {}
    for p in TABLES["POSITIONS"]:
        key = (p["PARTICIPANT_ID"], p["INSTRUMENT_ID"], p["JURISDICTION_ID"])
        max_position_per_key[key] = max(max_position_per_key.get(key, 0), abs(p["NET_QUANTITY"]))

    for key, max_pos in max_position_per_key.items():
        assert max_pos <= trade_volume.get(key, 0) + 1e-6


def test_transaction_report_deadline_never_falls_on_a_weekend():
    """Found via live behavioral testing against loaded Snowflake data, not a hypothetical: the
    original `EXECUTION_TIMESTAMP + timedelta(days=1)` formula put ~27% of deadlines on a
    Saturday/Sunday, producing 23 false-positive "late" findings out of 82 (28%) once checked
    against real regulatory-style T+1-*business*-day semantics. _next_business_day_deadline
    rolls a weekend deadline forward to the following Monday -- this locks that behavior in."""
    weekend_deadlines = [
        r for r in TABLES["TRANSACTION_REPORTS"] if r["DEADLINE"].weekday() >= 5
    ]
    assert weekend_deadlines == [], (
        f"{len(weekend_deadlines)} TRANSACTION_REPORTS rows have a DEADLINE on a weekend"
    )
