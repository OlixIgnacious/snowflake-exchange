"""JURISDICTION_CONFIG -- config-driven synthetic data generation (architecture.md "Synthetic
data" section). Onboarding a jurisdiction is a new config instance, never a generator code
change (market-agnostic design rule #7).

Japan is seeded here with its live-verified venue list from
docs/canonical_schema_contract.md v7 (6 confirmed active + 2 primary-source-confirmed
discontinued).

US and EU (closing the review finding "market-agnostic is proven for one jurisdiction only")
were added 2026-09-15, each live-verified the same way Japan's was -- not fabricated or copied
from a secondary source:
- US: live-fetched the SEC's own current list of exchanges registered under Exchange Act Section
  6(a) (https://www.sec.gov/about/divisions-offices/division-trading-markets/national-securities-exchanges,
  29 exchanges as of this fetch) plus FINRA's own pages confirming its equity trade-reporting
  facilities (Alternative Display Facility, FINRA/Nasdaq TRF Carteret & Chicago, FINRA/NYSE TRF)
  are still active in 2026. Selected 7 major, currently-active national securities exchanges plus
  the ADF as a real OTC/off-exchange reporting facility -- not all 29 registered exchanges (many
  are single-purpose options exchanges, e.g. Nasdaq's GEMX/ISE/MRX/PHLX), matching Japan's own
  precedent of a representative real venue set, not an exhaustive one.
- EU: "EU" is not one exchange -- picked one concrete, real, currently-operating member-state
  market structure (Germany/Deutsche Börse Group) rather than claiming pan-EU coverage, same
  honesty discipline the EU governance-content seed (sql/governance/02_*.sql) already applies.
  Live-verified via Deutsche Börse's own site and independent sources: Xetra (the main electronic
  venue, ~90% of German on-exchange equity trading), the Frankfurt Stock Exchange floor, Tradegate
  Exchange (a real Berlin-based MTF, majority-owned by Deutsche Börse), and Börse Stuttgart.
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
    derivatives_only: bool = False
    # True only for a trade-repository-shaped "venue" (e.g. DDRJ) that exists purely so an OTC
    # derivative trade has somewhere real to point VENUE_ID at -- it is not a place equities (or
    # any other cash instrument) ever trade, so ordinary equity order/trade generation and
    # wash-trading/spoofing detector calibration must exclude it explicitly rather than treating
    # it like every other venue in cfg.venues.


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
    generate_otc_derivatives: bool = False
    # Config-driven, not a hardcoded jurisdiction check (market-agnostic rule #7) -- only set True
    # where a real regulatory citation for an OTC-derivatives report type actually exists
    # (JP: sql/governance/06_jp_otc_derivatives_report_template_seed.sql). Generating uncited
    # derivative data for a jurisdiction with no such citation would be unearned content.
    rfr_benchmark: str = ""
    # The jurisdiction's real, currently-published risk-free reference rate (e.g. Japan's
    # BOJ-administered TONA) -- used as the OTC swap's underlying when generate_otc_derivatives.


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
        # Live-verified 2026-09-15 (DTCC's own site + independent coverage of its 2013 FSA
        # registration): DTCC Data Repository (Japan) K.K. (DDRJ) is the FSA-designated Trade
        # Repository OTC derivatives transactions are reported to under FIEA Art. 156-63/64/65 --
        # the same statutory basis cited in sql/governance/06_jp_otc_derivatives_report_template_
        # seed.sql. Not an execution venue in the equity sense (bilateral OTC swaps aren't
        # exchange-matched), so derivatives_only=True keeps it out of ordinary equity order/trade
        # generation and out of wash-trading/spoofing calibration (those detectors are exchange
        # order-book concepts; applying them to a trade repository doesn't hold real meaning yet).
        VenueSeed("DDRJ", "DTCC Data Repository (Japan) K.K.", "otc_facility", "The Depository Trust & Clearing Corporation", "active", None, None, derivatives_only=True),
    ],
    instrument_count=8,
    participants_per_venue=6,
    beneficial_owner_count=10,
    sim_start=date(2025, 6, 1),
    sim_end=date(2026, 9, 1),
    generate_otc_derivatives=True,
    rfr_benchmark="TONA",  # Tokyo Overnight Average rate, BOJ-administered (verified 2026-09-15)
)


# regulator_name/primary_language match the JURISDICTIONS rows already seeded by
# sql/governance/02_us_eu_rule_corpus_and_obligations_seed.sql -- kept identical here rather than
# introducing a second, differently-worded milestoned version of the same jurisdiction row.
US_CONFIG = JurisdictionConfig(
    jurisdiction_id="US",
    regulator_name="SEC / FINRA / CFTC",
    primary_language="en",
    currency="USD",
    venues=[
        VenueSeed("XNYS", "New York Stock Exchange", "exchange", "NYSE Group, Inc.", "active", None, None),
        VenueSeed("XNAS", "The Nasdaq Stock Market", "exchange", "Nasdaq, Inc.", "active", None, None),
        VenueSeed("ARCX", "NYSE Arca", "exchange", "NYSE Group, Inc.", "active", None, None),
        VenueSeed("BATS", "Cboe BZX Exchange", "exchange", "Cboe Global Markets", "active", None, None),
        VenueSeed("EDGX", "Cboe EDGX Exchange", "exchange", "Cboe Global Markets", "active", None, None),
        VenueSeed("IEXG", "Investors Exchange (IEX)", "exchange", "Investors Exchange LLC", "active", None, None),
        VenueSeed("MEMX", "Members Exchange", "exchange", "MEMX, LLC", "active", None, None),
        VenueSeed("FADF", "FINRA Alternative Display Facility", "otc_facility", "FINRA", "active", None, None),
    ],
    instrument_count=8,
    participants_per_venue=6,
    beneficial_owner_count=10,
    sim_start=date(2025, 6, 1),
    sim_end=date(2026, 9, 1),
)

EU_CONFIG = JurisdictionConfig(
    jurisdiction_id="EU",
    regulator_name="ESMA",
    primary_language="en",
    currency="EUR",
    venues=[
        VenueSeed("XETR", "Xetra", "exchange", "Deutsche Börse Group", "active", None, None),
        VenueSeed("XFRA", "Frankfurt Stock Exchange", "exchange", "Deutsche Börse Group", "active", None, None),
        VenueSeed("XGAT", "Tradegate Exchange", "pts", "Tradegate Exchange GmbH", "active", None, None),
        VenueSeed("XSTU", "Börse Stuttgart", "exchange", "Boerse Stuttgart Group", "active", None, None),
    ],
    instrument_count=8,
    participants_per_venue=6,
    beneficial_owner_count=10,
    sim_start=date(2025, 6, 1),
    sim_end=date(2026, 9, 1),
)
