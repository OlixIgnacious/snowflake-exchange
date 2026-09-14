"""Synthetic data generator, JURISDICTION_CONFIG-driven (architecture.md "Synthetic data"
section). Produces every VIGIL.CORE table's rows as plain dicts, in-memory -- no Snowflake
dependency here, so the measurable acceptance criteria (referential integrity, venue coverage,
discontinued-venue date-bounding) can be tested standalone against the output (tests/).

Deliberately injects known wash-trading and spoofing/layering cases (not just random noise) so
the detector views built in sql/detectors/ have something real to be validated against, not just
schema-compile-tested on empty tables.
"""
from __future__ import annotations

import random
from datetime import date, datetime, timedelta

from generator.jurisdiction_config import JurisdictionConfig, VenueSeed


def _rand_datetime(rng: random.Random, start: date, end: date) -> datetime:
    delta_days = (end - start).days
    d = start + timedelta(days=rng.randint(0, max(delta_days, 0)))
    return datetime(d.year, d.month, d.day, rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59))


def _next_business_day_deadline(execution_ts: datetime) -> datetime:
    """Regulatory reporting deadlines are conventionally T+1 *business* day, not T+1 calendar
    day -- a real gap found via live behavioral testing: the previous `+ timedelta(days=1)`
    formula put ~27% of deadlines on a Saturday/Sunday, which independently re-checking against
    the loaded data showed produced 23 false-positive "late" findings out of 82 (28%) once
    weekend deadlines are correctly rolled to the following Monday. Deliberately weekend-only,
    not a full market-holiday calendar -- a real holiday calendar is jurisdiction-specific data
    that needs the same live-verification discipline `architecture.md` already applies to venue
    lists (see the US JURISDICTION_CONFIG backlog item), not something to fabricate here."""
    deadline = execution_ts + timedelta(days=1)
    while deadline.weekday() >= 5:  # 5 = Saturday, 6 = Sunday
        deadline += timedelta(days=1)
    return deadline


def _venue_window(v: VenueSeed, cfg: JurisdictionConfig) -> tuple[date, date]:
    start = v.active_from or cfg.sim_start
    # architecture.md's build order requires timestamps strictly BEFORE DISCONTINUED_AT (not
    # on-or-before) -- the discontinued date itself is excluded, not just dates after it.
    end = (v.discontinued_at - timedelta(days=1)) if v.discontinued_at else cfg.sim_end
    return max(start, cfg.sim_start), min(end, cfg.sim_end)


def generate(cfg: JurisdictionConfig, seed: int = 42, n_orders: int = 1500) -> dict[str, list[dict]]:
    rng = random.Random(seed)
    now = datetime(2026, 9, 14, 0, 0, 0)

    tables: dict[str, list[dict]] = {t: [] for t in [
        "JURISDICTIONS", "VENUES", "BENEFICIAL_OWNERS", "INSTRUMENTS", "MARKET_PARTICIPANTS",
        "ORDERS", "TRADES", "POSITIONS", "TRANSACTION_REPORTS",
        "DETECTOR_CALIBRATION", "REPORT_TEMPLATES",
    ]}

    def audit_cols(created_at, created_by, loaded_at=None, loaded_by=None):
        return {
            "CREATED_AT": created_at, "CREATED_BY": created_by,
            "LOADED_AT": loaded_at or created_at, "LOADED_BY": loaded_by or created_by,
        }

    # JURISDICTIONS
    tables["JURISDICTIONS"].append({
        "JURISDICTION_ID": cfg.jurisdiction_id, "REGULATOR_NAME": cfg.regulator_name,
        "PRIMARY_LANGUAGE": cfg.primary_language, **audit_cols(now, "generator"),
    })

    # VENUES
    for v in cfg.venues:
        tables["VENUES"].append({
            "VENUE_ID": v.venue_id, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_NAME": v.venue_name,
            "VENUE_TYPE": v.venue_type, "OPERATOR_NAME": v.operator_name, "STATUS": v.status,
            "ACTIVE_FROM": v.active_from, "DISCONTINUED_AT": v.discontinued_at,
            **audit_cols(now, "generator"),
        })

    # BENEFICIAL_OWNERS
    owner_ids = [f"BO{i:02d}" for i in range(cfg.beneficial_owner_count)]
    for oid in owner_ids:
        tables["BENEFICIAL_OWNERS"].append({
            "BENEFICIAL_OWNER_ID": oid, "JURISDICTION_ID": cfg.jurisdiction_id,
            "OWNER_NAME": f"Owner {oid}", "OWNER_TYPE": rng.choice(["individual", "corporate", "fund"]),
            **audit_cols(now, "generator"),
        })

    # INSTRUMENTS
    instrument_ids = [f"I{i:02d}" for i in range(cfg.instrument_count)]
    for iid in instrument_ids:
        tables["INSTRUMENTS"].append({
            "INSTRUMENT_ID": iid, "JURISDICTION_ID": cfg.jurisdiction_id, "ISIN": None,
            "INSTRUMENT_TYPE": "equity", "TICK_SIZE": 1, "LOT_SIZE": 100,
            **audit_cols(now, "generator"),
        })

    # MARKET_PARTICIPANTS -- some share a beneficial owner deliberately, for wash-trading cases
    n_participants = cfg.participants_per_venue * max(len([v for v in cfg.venues if v.status == "active"]), 1)
    participant_ids = [f"P{i:03d}" for i in range(n_participants)]
    for i, pid in enumerate(participant_ids):
        boid = owner_ids[i % len(owner_ids)] if rng.random() < 0.6 else None
        tables["MARKET_PARTICIPANTS"].append({
            "PARTICIPANT_ID": pid, "JURISDICTION_ID": cfg.jurisdiction_id,
            "PARTICIPANT_TYPE": rng.choice(["broker", "proprietary", "institutional", "retail"]),
            "BENEFICIAL_OWNER_ID": boid, **audit_cols(now, "generator"),
        })

    # Deliberate wash-trading pair: two participants sharing the same beneficial owner
    wash_owner = owner_ids[0]
    wash_participants = [p["PARTICIPANT_ID"] for p in tables["MARKET_PARTICIPANTS"] if p["BENEFICIAL_OWNER_ID"] == wash_owner]
    if len(wash_participants) < 2:
        # force at least 2 for a guaranteed test case
        tables["MARKET_PARTICIPANTS"][0]["BENEFICIAL_OWNER_ID"] = wash_owner
        tables["MARKET_PARTICIPANTS"][1]["BENEFICIAL_OWNER_ID"] = wash_owner
        wash_participants = [tables["MARKET_PARTICIPANTS"][0]["PARTICIPANT_ID"], tables["MARKET_PARTICIPANTS"][1]["PARTICIPANT_ID"]]

    # Deliberate spoofing participant/instrument/venue
    active_venues = [v for v in cfg.venues if v.status == "active"]
    spoof_participant = participant_ids[2 % len(participant_ids)]
    spoof_instrument = instrument_ids[0]
    spoof_venue = active_venues[0].venue_id

    order_counter = 0
    trade_counter = 0

    def new_order_id():
        nonlocal order_counter
        order_counter += 1
        return f"O{order_counter:07d}"

    def new_trade_id():
        nonlocal trade_counter
        trade_counter += 1
        return f"T{trade_counter:07d}"

    # --- Baseline random orders + trades, respecting each venue's active window ---
    for _ in range(n_orders):
        venue = rng.choice(cfg.venues)
        start, end = _venue_window(venue, cfg)
        if start > end:
            continue
        participant = rng.choice(participant_ids)
        instrument = rng.choice(instrument_ids)
        side = rng.choice(["buy", "sell"])
        qty = rng.randint(100, 10000)
        price = round(rng.uniform(100, 5000), 2)
        event_ts = _rand_datetime(rng, start, end)
        currency = cfg.currency
        order_id = new_order_id()

        tables["ORDERS"].append({
            "ORDER_ID": order_id, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": venue.venue_id,
            "INSTRUMENT_ID": instrument, "PARTICIPANT_ID": participant, "SIDE": side, "ORDER_TYPE": "limit",
            "EVENT_TYPE": "new", "EVENT_TS": event_ts, "PRICE": price, "CURRENCY": currency,
            "QUANTITY": qty, "FILLED_QUANTITY": 0, "REGULATORY_ATTRIBUTES": None,
            **audit_cols(event_ts, "generator"),
        })

        outcome = rng.random()
        if outcome < 0.6:
            # filled -> becomes a trade
            fill_ts = event_ts + timedelta(seconds=rng.randint(1, 300))
            tables["ORDERS"].append({
                "ORDER_ID": order_id, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": venue.venue_id,
                "INSTRUMENT_ID": instrument, "PARTICIPANT_ID": participant, "SIDE": side, "ORDER_TYPE": "limit",
                "EVENT_TYPE": "fill", "EVENT_TS": fill_ts, "PRICE": price, "CURRENCY": currency,
                "QUANTITY": qty, "FILLED_QUANTITY": qty, "REGULATORY_ATTRIBUTES": None,
                **audit_cols(event_ts, "generator", loaded_at=fill_ts),
            })
            counterparty = rng.choice(participant_ids) if rng.random() < 0.8 else None
            trade_order_id = order_id if rng.random() < 0.85 else None  # some trades lack ORDER_ID (coverage gap)
            tables["TRADES"].append({
                "TRADE_ID": new_trade_id(), "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": venue.venue_id,
                "ORDER_ID": trade_order_id, "INSTRUMENT_ID": instrument, "EXECUTION_TIMESTAMP": fill_ts,
                "PRICE": price, "CURRENCY": currency, "VOLUME": qty, "PARTICIPANT_ID": participant,
                "COUNTERPARTY_PARTICIPANT_ID": counterparty, "MATCHING_MECHANISM": "continuous",
                "REGULATORY_ATTRIBUTES": None, **audit_cols(fill_ts, "generator"),
            })
        else:
            # cancelled, possibly unfilled (spoofing signal material)
            cancel_ts = event_ts + timedelta(seconds=rng.randint(1, 120))
            tables["ORDERS"].append({
                "ORDER_ID": order_id, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": venue.venue_id,
                "INSTRUMENT_ID": instrument, "PARTICIPANT_ID": participant, "SIDE": side, "ORDER_TYPE": "limit",
                "EVENT_TYPE": "cancel", "EVENT_TS": cancel_ts, "PRICE": price, "CURRENCY": currency,
                "QUANTITY": qty, "FILLED_QUANTITY": 0, "REGULATORY_ATTRIBUTES": None,
                **audit_cols(event_ts, "generator", loaded_at=cancel_ts),
            })

    # --- Injected wash-trading cases: same-row self-trade + cross-row matched pair ---
    wt_venue = active_venues[0]
    wt_start, wt_end = _venue_window(wt_venue, cfg)
    wt_ts = _rand_datetime(rng, wt_start, wt_end)
    # (a) same-row self-trade, continuous mechanism (should trigger)
    tables["TRADES"].append({
        "TRADE_ID": new_trade_id(), "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": wt_venue.venue_id,
        "ORDER_ID": None, "INSTRUMENT_ID": instrument_ids[0], "EXECUTION_TIMESTAMP": wt_ts,
        "PRICE": 500.0, "CURRENCY": cfg.currency, "VOLUME": 1000, "PARTICIPANT_ID": wash_participants[0],
        "COUNTERPARTY_PARTICIPANT_ID": wash_participants[1], "MATCHING_MECHANISM": "continuous",
        "REGULATORY_ATTRIBUTES": None, **audit_cols(wt_ts, "generator"),
    })
    # (b) same pattern but MATCHING_MECHANISM='cross' -- should be exempt from the trigger
    tables["TRADES"].append({
        "TRADE_ID": new_trade_id(), "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": wt_venue.venue_id,
        "ORDER_ID": None, "INSTRUMENT_ID": instrument_ids[0], "EXECUTION_TIMESTAMP": wt_ts + timedelta(minutes=5),
        "PRICE": 500.0, "CURRENCY": cfg.currency, "VOLUME": 500, "PARTICIPANT_ID": wash_participants[0],
        "COUNTERPARTY_PARTICIPANT_ID": wash_participants[1], "MATCHING_MECHANISM": "cross",
        "REGULATORY_ATTRIBUTES": None, **audit_cols(wt_ts, "generator"),
    })
    # (c) cross-row matched pair: two opposite-side orders/trades, same beneficial owner, close in time/price
    pair_order_1, pair_order_2 = new_order_id(), new_order_id()
    for oid, participant, side in [(pair_order_1, wash_participants[0], "buy"), (pair_order_2, wash_participants[1], "sell")]:
        tables["ORDERS"].append({
            "ORDER_ID": oid, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": wt_venue.venue_id,
            "INSTRUMENT_ID": instrument_ids[1], "PARTICIPANT_ID": participant, "SIDE": side, "ORDER_TYPE": "limit",
            "EVENT_TYPE": "fill", "EVENT_TS": wt_ts, "PRICE": 250.0, "CURRENCY": cfg.currency,
            "QUANTITY": 800, "FILLED_QUANTITY": 800, "REGULATORY_ATTRIBUTES": None,
            **audit_cols(wt_ts, "generator"),
        })
    tables["TRADES"].append({
        "TRADE_ID": new_trade_id(), "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": wt_venue.venue_id,
        "ORDER_ID": pair_order_1, "INSTRUMENT_ID": instrument_ids[1], "EXECUTION_TIMESTAMP": wt_ts,
        "PRICE": 250.0, "CURRENCY": cfg.currency, "VOLUME": 800, "PARTICIPANT_ID": wash_participants[0],
        "COUNTERPARTY_PARTICIPANT_ID": None, "MATCHING_MECHANISM": "continuous",
        "REGULATORY_ATTRIBUTES": None, **audit_cols(wt_ts, "generator"),
    })
    tables["TRADES"].append({
        "TRADE_ID": new_trade_id(), "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": wt_venue.venue_id,
        "ORDER_ID": pair_order_2, "INSTRUMENT_ID": instrument_ids[1], "EXECUTION_TIMESTAMP": wt_ts + timedelta(seconds=10),
        "PRICE": 250.10, "CURRENCY": cfg.currency, "VOLUME": 800, "PARTICIPANT_ID": wash_participants[1],
        "COUNTERPARTY_PARTICIPANT_ID": None, "MATCHING_MECHANISM": "continuous",
        "REGULATORY_ATTRIBUTES": None, **audit_cols(wt_ts, "generator"),
    })

    # --- Injected spoofing/layering case: a participant with NORMAL cancel activity for a
    # baseline period, then a SPIKE -- the detector z-scores TODAY against the participant's own
    # trailing baseline (architecture.md), so a uniformly-bad actor from day one never deviates
    # from themselves and would never be flagged; the test case has to include a genuine change
    # in behavior to be a meaningful positive case for this specific detection method.
    spoof_start, spoof_end = _venue_window(next(v for v in cfg.venues if v.venue_id == spoof_venue), cfg)
    n_baseline_days, n_spike_days = 10, 5
    for day_offset in range(n_baseline_days + n_spike_days):
        day = spoof_start + timedelta(days=day_offset * 3)
        if day > spoof_end:
            break
        is_spike_day = day_offset >= n_baseline_days
        n_cancel_orders = 15 if is_spike_day else 2  # normal days: mostly filled, low cancel ratio
        for _ in range(n_cancel_orders):
            oid = new_order_id()
            ts = datetime(day.year, day.month, day.day, rng.randint(9, 15), rng.randint(0, 59))
            qty = rng.randint(1000, 5000)
            tables["ORDERS"].append({
                "ORDER_ID": oid, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": spoof_venue,
                "INSTRUMENT_ID": spoof_instrument, "PARTICIPANT_ID": spoof_participant, "SIDE": "buy",
                "ORDER_TYPE": "limit", "EVENT_TYPE": "new", "EVENT_TS": ts, "PRICE": 300.0,
                "CURRENCY": cfg.currency, "QUANTITY": qty, "FILLED_QUANTITY": 0, "REGULATORY_ATTRIBUTES": None,
                **audit_cols(ts, "generator"),
            })
            tables["ORDERS"].append({
                "ORDER_ID": oid, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": spoof_venue,
                "INSTRUMENT_ID": spoof_instrument, "PARTICIPANT_ID": spoof_participant, "SIDE": "buy",
                "ORDER_TYPE": "limit", "EVENT_TYPE": "cancel", "EVENT_TS": ts + timedelta(seconds=5), "PRICE": 300.0,
                "CURRENCY": cfg.currency, "QUANTITY": qty, "FILLED_QUANTITY": 0, "REGULATORY_ATTRIBUTES": None,
                **audit_cols(ts, "generator", loaded_at=ts + timedelta(seconds=5)),
            })
        # steady submitted-and-filled volume every day, so SUBMITTED_VOLUME is always nonzero
        # and the ratio is meaningful on both normal and spike days.
        for _ in range(8):
            oid2 = new_order_id()
            ts2 = datetime(day.year, day.month, day.day, rng.randint(15, 16), rng.randint(0, 59))
            tables["ORDERS"].append({
                "ORDER_ID": oid2, "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": spoof_venue,
                "INSTRUMENT_ID": spoof_instrument, "PARTICIPANT_ID": spoof_participant, "SIDE": "sell",
                "ORDER_TYPE": "limit", "EVENT_TYPE": "new", "EVENT_TS": ts2, "PRICE": 300.0,
                "CURRENCY": cfg.currency, "QUANTITY": 500, "FILLED_QUANTITY": 0, "REGULATORY_ATTRIBUTES": None,
                **audit_cols(ts2, "generator"),
            })

    # --- POSITIONS: accumulate NET_QUANTITY from TRADES only (Fix #4) ---
    running: dict[tuple, float] = {}
    for t in sorted(tables["TRADES"], key=lambda r: r["EXECUTION_TIMESTAMP"]):
        key = (t["PARTICIPANT_ID"], t["INSTRUMENT_ID"], t["JURISDICTION_ID"])
        signed = t["VOLUME"]  # simplification: treat participant side as always a buy accumulation
        running[key] = running.get(key, 0) + signed
        as_of = t["EXECUTION_TIMESTAMP"].date()
        loaded_at = datetime(as_of.year, as_of.month, as_of.day, 23, 59, 59)
        tables["POSITIONS"].append({
            "PARTICIPANT_ID": key[0], "INSTRUMENT_ID": key[1], "JURISDICTION_ID": key[2],
            "AS_OF_DATE": as_of, "LOADED_AT": loaded_at, "LOADED_BY": "generator",
            "NET_QUANTITY": running[key], "MARKET_VALUE": running[key] * t["PRICE"], "CURRENCY": t["CURRENCY"],
            "CREATED_AT": loaded_at, "CREATED_BY": "generator",
        })

    # --- TRANSACTION_REPORTS: one per trade, some deliberately late ---
    for i, t in enumerate(tables["TRADES"]):
        deadline = _next_business_day_deadline(t["EXECUTION_TIMESTAMP"])
        late = (i % 11 == 0)
        submitted = deadline + timedelta(hours=6) if late else t["EXECUTION_TIMESTAMP"] + timedelta(hours=2)
        tables["TRANSACTION_REPORTS"].append({
            "REPORT_ID": f"R{i:07d}", "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": t["VENUE_ID"],
            "REPORT_TYPE": "transaction_report", "REPORT_SCOPE": "trade", "TRADE_ID": t["TRADE_ID"],
            "PERIOD_START": None, "PERIOD_END": None, "REPORT_STATUS": "new",
            "SUBMITTED_AT": submitted, "DEADLINE": deadline, "DEFERRED_PUBLICATION_UNTIL": None,
            "FIELDS_COMPLETE": (i % 13 != 0), "MATCH_STATUS": "full_match",
            "REPORT_PAYLOAD_REF": None, **audit_cols(t["EXECUTION_TIMESTAMP"], "generator", loaded_at=submitted),
        })

    # --- DETECTOR_CALIBRATION seeds ---
    # All venues, including discontinued ones -- a closed venue's real historical trades still
    # need to be surveillable (architecture.md's whole rationale for date-bounding rather than
    # excluding a discontinued venue). Calibration scope is "can this venue's trades be
    # analyzed," not "is this venue still open."
    for v in cfg.venues:
        tables["DETECTOR_CALIBRATION"].append({
            "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": v.venue_id, "DETECTOR_NAME": "wash_trading",
            "DIMENSION_KEY": None, "Z_THRESHOLD": None, "MIN_BASELINE_PERIODS": None,
            "PARAMS": {"time_window_seconds": 300, "price_tolerance_pct": 0.01, "exempt_matching_mechanisms": ["cross"]},
            "IS_PROVISIONAL": True, "EFFECTIVE_FROM": cfg.sim_start, "CALIBRATED_AT": now,
            "CALIBRATION_METHOD": "default-uncalibrated", "CALIBRATED_BY": "generator",
            "CREATED_AT": now, "CREATED_BY": "generator",
        })
        tables["DETECTOR_CALIBRATION"].append({
            "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": v.venue_id, "DETECTOR_NAME": "spoofing_layering",
            "DIMENSION_KEY": None, "Z_THRESHOLD": 2.5, "MIN_BASELINE_PERIODS": 3, "PARAMS": None,
            "IS_PROVISIONAL": True, "EFFECTIVE_FROM": cfg.sim_start, "CALIBRATED_AT": now,
            "CALIBRATION_METHOD": "default-uncalibrated", "CALIBRATED_BY": "generator",
            "CREATED_AT": now, "CREATED_BY": "generator",
        })
    tables["DETECTOR_CALIBRATION"].append({
        "JURISDICTION_ID": cfg.jurisdiction_id, "VENUE_ID": None, "DETECTOR_NAME": "position_limit",
        "DIMENSION_KEY": None, "Z_THRESHOLD": None, "MIN_BASELINE_PERIODS": None,
        "PARAMS": {"limit_quantity": 50000}, "IS_PROVISIONAL": True, "EFFECTIVE_FROM": cfg.sim_start,
        "CALIBRATED_AT": now, "CALIBRATION_METHOD": "default-uncalibrated", "CALIBRATED_BY": "generator",
        "CREATED_AT": now, "CREATED_BY": "generator",
    })

    # --- REPORT_TEMPLATES seed ---
    for field_name, mapping, is_req, status in [
        ("Price", "TRADES.PRICE", True, "mapped"),
        ("Volume", "TRADES.VOLUME", True, "mapped"),
        ("Instrument_ID", "TRADES.INSTRUMENT_ID", True, "mapped"),
        ("Trading_Capacity", None, True, "gap"),
    ]:
        tables["REPORT_TEMPLATES"].append({
            "JURISDICTION_ID": cfg.jurisdiction_id, "REPORT_TYPE": "transaction_report", "FIELD_NAME": field_name,
            "FIELD_ORDER": None, "STATUS": status, "SOURCE_MAPPING": mapping, "FIELD_FORMAT": None,
            "IS_REQUIRED": is_req, "CREATED_AT": now, "CREATED_BY": "generator",
            "LOADED_AT": now, "LOADED_BY": "generator",
        })

    return tables
