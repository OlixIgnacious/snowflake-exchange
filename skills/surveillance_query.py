"""surveillance-query skill (architecture.md "Agent and Skills" section) -- live queries over
trades/orders/positions (wash trading, spoofing candidates, exposure breaches). Parallel to
Praman's signal-query. Thin dispatch over the Phase 3 detector views -- no query logic lives
here that isn't already in sql/detectors/; this module's job is parameter validation and
routing, the "thin orchestration" architecture.md calls for.
"""
from __future__ import annotations

from dataclasses import dataclass

DETECTOR_VIEWS = {
    "wash_trading": "WASH_TRADING_CANDIDATES",
    "wash_detection_coverage": "WASH_DETECTION_COVERAGE",
    "spoofing_layering": "SPOOFING_LAYERING_SIGNALS",
    "position_limit": "POSITION_LIMIT_BREACHES",
    "reporting_timeliness": "REPORTING_TIMELINESS_SIGNALS",
    "execution_slippage": "EXECUTION_SLIPPAGE",
    "arrival_slippage": "ARRIVAL_SLIPPAGE",
}

# Detectors whose findings must never be presented without their companion coverage figure
# (Fix #3) -- "no wash trades found" and "no wash trades could be checked for" are never
# conflated. The skill enforces this pairing structurally, not by convention.
COMPANION_COVERAGE = {
    "wash_trading": "wash_detection_coverage",
}


@dataclass
class SurveillanceQueryRequest:
    detector: str
    jurisdiction_id: str
    venue_id: str | None = None
    flagged_only: bool = True


class UnknownDetectorError(ValueError):
    pass


def build_query(req: SurveillanceQueryRequest) -> str:
    """Builds the SELECT against the appropriate detector view. Never constructs a query
    against a base table directly -- every surveillance question routes through a detector view
    or governance view, same discipline as the governance gate (Fix #6)."""
    if req.detector not in DETECTOR_VIEWS:
        raise UnknownDetectorError(
            f"Unknown detector '{req.detector}'. Known: {sorted(DETECTOR_VIEWS)}"
        )
    view = DETECTOR_VIEWS[req.detector]
    clauses = [f"JURISDICTION_ID = '{req.jurisdiction_id}'"]
    if req.venue_id:
        clauses.append(f"VENUE_ID = '{req.venue_id}'")
    if req.flagged_only:
        flag_column = {
            "wash_trading": "NOT IS_TRIGGER_EXEMPT",
            "spoofing_layering": "IS_FLAGGED",
            "position_limit": "IS_BREACH",
            "reporting_timeliness": "(IS_OVERDUE_UNSUBMITTED OR IS_LATE_SUBMISSION OR IS_INCOMPLETE OR IS_MISMATCHED)",
        }.get(req.detector)
        if flag_column:
            clauses.append(flag_column)
    where = " AND ".join(clauses)
    return f"SELECT * FROM {view} WHERE {where}"


def companion_coverage_query(req: SurveillanceQueryRequest) -> str | None:
    """Returns the companion coverage query that must accompany this detector's result, if any
    (Fix #3) -- None when the detector has no coverage-gap concept."""
    companion = COMPANION_COVERAGE.get(req.detector)
    if companion is None:
        return None
    coverage_req = SurveillanceQueryRequest(companion, req.jurisdiction_id, req.venue_id, flagged_only=False)
    return build_query(coverage_req)
