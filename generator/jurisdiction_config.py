"""JURISDICTION_CONFIG -- config-driven synthetic data generation (architecture.md "Synthetic
data" section). Onboarding a jurisdiction is a new config instance, never a generator code
change (market-agnostic design rule #7).

Japan is seeded here with its live-verified venue list from
docs/canonical_schema_contract.md v7 (6 confirmed active + 2 primary-source-confirmed
discontinued). A second jurisdiction (US) is explicitly NOT included yet -- its venue list still
needs the same per-venue live-verification discipline Japan's got (architecture.md, "What's
explicitly deferred"), so it is not fabricated here.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date


@dataclass
class VenueSeed:
    venue_id: str
    venue_name: str
    venue_type: str  # exchange / pts / otc_facility / block_trading
    operator_name: str
    status: str  # active / discontinued
    active_from: date | None
    discontinued_at: date | None


@dataclass
class JurisdictionConfig:
    jurisdiction_id: str
    regulator_name: str
    primary_language: str
    currency: str
    venues: list[VenueSeed]
    instrument_count: int
    participants_per_venue: int
    beneficial_owner_count: int
    sim_start: date
    sim_end: date


JAPAN_CONFIG = JurisdictionConfig(
    jurisdiction_id="JP",
    regulator_name="FSA/SESC",
    primary_language="ja",
    currency="JPY",
    venues=[
        VenueSeed("XTKS", "Tokyo Stock Exchange", "exchange", "Japan Exchange Group", "active", None, None),
        VenueSeed("XOSE", "Osaka Exchange", "exchange", "Japan Exchange Group", "active", None, None),
        VenueSeed("TOCOM", "Tokyo Commodity Exchange", "exchange", "Japan Exchange Group", "active", None, None),
        VenueSeed("JPNX", "Japannext PTS", "pts", "Japannext Co., Ltd.", "active", None, None),
        VenueSeed("ODX", "Osaka Digital Exchange", "pts", "Osaka Digital Exchange, Inc.", "active", None, None),
        VenueSeed("ODXST", "ODX START (security tokens)", "pts", "Osaka Digital Exchange, Inc.", "active", None, None),
        VenueSeed("CBOJ", "Cboe Japan PTS", "pts", "Cboe Global Markets", "discontinued", None, date(2025, 8, 29)),
        VenueSeed("CBOJBIDS", "Cboe BIDS Japan", "block_trading", "Cboe Global Markets", "discontinued", None, date(2025, 8, 29)),
    ],
    instrument_count=8,
    participants_per_venue=6,
    beneficial_owner_count=10,
    sim_start=date(2025, 6, 1),
    sim_end=date(2026, 9, 1),
)
