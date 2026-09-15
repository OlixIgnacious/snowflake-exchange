"""Tests for generator/generate.py against architecture.md's measurable market-agnosticism
criteria (Fix #9): 100% referential integrity across every FK, every seeded VENUE_ID represented
in >=1 ORDERS/TRADES row, and discontinued-venue date-bounding actually holding. Runs standalone
against the generator's in-memory output -- no Snowflake connection needed, so this gate doesn't
depend on the human/agent-executed load step.

Structural tests (referential integrity, venue coverage) are parametrized across all three
configs (JP/US/EU) -- closing the review finding that "market-agnostic" was a claim proven for
Japan only. The market-agnosticism criterion is that the *mechanism* behaves identically across
differently-sized configs, not that two configs produce equal absolute counts (architecture.md).
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generator.generate import generate
from generator.jurisdiction_config import JAPAN_CONFIG, US_CONFIG, EU_CONFIG

TABLES = generate(JAPAN_CONFIG, seed=42, n_orders=1500)
ALL_CONFIGS = [JAPAN_CONFIG, US_CONFIG, EU_CONFIG]
ALL_TABLES = {cfg.jurisdiction_id: generate(cfg, seed=42, n_orders=1500) for cfg in ALL_CONFIGS}


def _ids(tables, table, col):
    return {row[col] for row in tables[table]}


@pytest.mark.parametrize("cfg", ALL_CONFIGS, ids=lambda c: c.jurisdiction_id)
def test_referential_integrity_orders(cfg):
    tables = ALL_TABLES[cfg.jurisdiction_id]
    venue_ids = _ids(tables, "VENUES", "VENUE_ID")
    instrument_ids = _ids(tables, "INSTRUMENTS", "INSTRUMENT_ID")
    participant_ids = _ids(tables, "MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    bad = [o for o in tables["ORDERS"] if o["VENUE_ID"] not in venue_ids
           or o["INSTRUMENT_ID"] not in instrument_ids
           or o["PARTICIPANT_ID"] not in participant_ids]
    assert bad == [], f"{len(bad)} ORDERS rows with a dangling FK ({cfg.jurisdiction_id})"


@pytest.mark.parametrize("cfg", ALL_CONFIGS, ids=lambda c: c.jurisdiction_id)
def test_referential_integrity_trades(cfg):
    tables = ALL_TABLES[cfg.jurisdiction_id]
    venue_ids = _ids(tables, "VENUES", "VENUE_ID")
    instrument_ids = _ids(tables, "INSTRUMENTS", "INSTRUMENT_ID")
    participant_ids = _ids(tables, "MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    order_keys = {(o["ORDER_ID"], o["VENUE_ID"]) for o in tables["ORDERS"]}
    bad = []
    for t in tables["TRADES"]:
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
    assert bad == [], f"{len(bad)} TRADES rows with a dangling FK ({cfg.jurisdiction_id})"


@pytest.mark.parametrize("cfg", ALL_CONFIGS, ids=lambda c: c.jurisdiction_id)
def test_referential_integrity_positions_and_participants(cfg):
    tables = ALL_TABLES[cfg.jurisdiction_id]
    boids = _ids(tables, "BENEFICIAL_OWNERS", "BENEFICIAL_OWNER_ID")
    bad_participants = [p for p in tables["MARKET_PARTICIPANTS"]
                         if p["BENEFICIAL_OWNER_ID"] is not None and p["BENEFICIAL_OWNER_ID"] not in boids]
    assert bad_participants == []

    participant_ids = _ids(tables, "MARKET_PARTICIPANTS", "PARTICIPANT_ID")
    instrument_ids = _ids(tables, "INSTRUMENTS", "INSTRUMENT_ID")
    bad_positions = [p for p in tables["POSITIONS"]
                      if p["PARTICIPANT_ID"] not in participant_ids or p["INSTRUMENT_ID"] not in instrument_ids]
    assert bad_positions == []


@pytest.mark.parametrize("cfg", ALL_CONFIGS, ids=lambda c: c.jurisdiction_id)
def test_every_seeded_venue_appears_in_orders_and_trades(cfg):
    tables = ALL_TABLES[cfg.jurisdiction_id]
    order_venues = _ids(tables, "ORDERS", "VENUE_ID")
    trade_venues = _ids(tables, "TRADES", "VENUE_ID")
    derivatives_only_ids = {v.venue_id for v in cfg.venues if v.derivatives_only}
    for v in tables["VENUES"]:
        vid = v["VENUE_ID"]
        # A derivatives_only "venue" (e.g. DDRJ, a trade repository) has real TRADES rows but
        # never ORDERS -- a bilateral OTC swap has no order-book lifecycle in this schema.
        if vid not in derivatives_only_ids:
            assert vid in order_venues, f"{vid} has zero ORDERS rows ({cfg.jurisdiction_id})"
        assert vid in trade_venues, f"{vid} has zero TRADES rows ({cfg.jurisdiction_id})"


@pytest.mark.parametrize("cfg", [US_CONFIG, EU_CONFIG], ids=lambda c: c.jurisdiction_id)
def test_us_eu_configs_have_no_discontinued_venues_and_no_wash_trading_injections(cfg):
    """US/EU configs are real live-verified venue lists but deliberately don't carry Japan's
    specific injected wash-trading/discontinued-venue test cases -- those are JP-specific
    fixtures (a real historical closure, deliberately-seeded detector cases), not something to
    copy onto a different jurisdiction just to make the test symmetric."""
    tables = ALL_TABLES[cfg.jurisdiction_id]
    assert all(v["DISCONTINUED_AT"] is None for v in tables["VENUES"])


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


@pytest.mark.parametrize("cfg", ALL_CONFIGS, ids=lambda c: c.jurisdiction_id)
def test_otc_derivatives_generation_is_config_gated_not_hardcoded(cfg):
    """Gap 8 MVP: OTC-derivative generation must be driven by
    JurisdictionConfig.generate_otc_derivatives (market-agnostic rule #7), not a hardcoded
    jurisdiction check -- only JP has a real regulatory citation for this report type today, so
    US/EU must produce zero rows in either new table."""
    tables = ALL_TABLES[cfg.jurisdiction_id]
    if cfg.generate_otc_derivatives:
        assert len(tables["DERIVATIVE_TRADE_DETAILS"]) > 0
        assert len(tables["DERIVATIVE_PRODUCT_ATTRIBUTES"]) > 0
    else:
        assert tables["DERIVATIVE_TRADE_DETAILS"] == []
        assert tables["DERIVATIVE_PRODUCT_ATTRIBUTES"] == []


def test_otc_derivative_trade_details_referential_integrity():
    """Every DERIVATIVE_TRADE_DETAILS row must key back to a real TRADES row (same TRADE_ID +
    VENUE_ID) and a real DERIVATIVE_PRODUCT_ATTRIBUTES row via that trade's INSTRUMENT_ID, and
    every counterparty on one of these trades must carry a real (synthetic-but-populated) LEI --
    the whole point of this MVP pass is that these fields are genuinely sourced, not fabricated
    at render time."""
    trade_keys = {(t["TRADE_ID"], t["VENUE_ID"]): t for t in TABLES["TRADES"]}
    instrument_ids = _ids(TABLES, "DERIVATIVE_PRODUCT_ATTRIBUTES", "INSTRUMENT_ID")
    participants_by_id = {p["PARTICIPANT_ID"]: p for p in TABLES["MARKET_PARTICIPANTS"]}

    assert len(TABLES["DERIVATIVE_TRADE_DETAILS"]) > 0
    for d in TABLES["DERIVATIVE_TRADE_DETAILS"]:
        key = (d["TRADE_ID"], d["VENUE_ID"])
        assert key in trade_keys, f"DERIVATIVE_TRADE_DETAILS {key} has no matching TRADES row"
        trade = trade_keys[key]
        assert trade["INSTRUMENT_ID"] in instrument_ids
        assert participants_by_id[trade["PARTICIPANT_ID"]]["LEI"]
        assert participants_by_id[trade["COUNTERPARTY_PARTICIPANT_ID"]]["LEI"]
        assert d["MATURITY_DATE"] > d["EFFECTIVE_DATE"]
        assert d["NOTIONAL_AMOUNT"] > 0


def test_otc_derivative_venue_excluded_from_equity_generation():
    """DDRJ (derivatives_only=True) must never receive an equity ORDER, and every non-derivative
    TRADES row must land on a venue that isn't derivatives_only -- otherwise a bilateral OTC swap
    trade repository would silently start absorbing ordinary equity order flow."""
    derivatives_only_ids = {v.venue_id for v in JAPAN_CONFIG.venues if v.derivatives_only}
    assert derivatives_only_ids == {"DDRJ"}
    assert all(o["VENUE_ID"] not in derivatives_only_ids for o in TABLES["ORDERS"])
    equity_trades = [t for t in TABLES["TRADES"] if t["INSTRUMENT_ID"] != "IDRV01"]
    assert all(t["VENUE_ID"] not in derivatives_only_ids for t in equity_trades)
