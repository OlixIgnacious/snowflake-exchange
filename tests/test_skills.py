"""Tests for the surveillance-query and assure-report skills (skills/)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from skills.assure_report import assure
from skills.surveillance_query import (
    SurveillanceQueryRequest,
    UnknownDetectorError,
    build_query,
    companion_coverage_query,
)
from ingest.report_adaptor import TemplateField


def test_build_query_routes_to_correct_view():
    q = build_query(SurveillanceQueryRequest("wash_trading", "JP", "XTKS"))
    assert "WASH_TRADING_CANDIDATES" in q
    assert "JURISDICTION_ID = 'JP'" in q
    assert "VENUE_ID = 'XTKS'" in q
    assert "NOT IS_TRIGGER_EXEMPT" in q


def test_build_query_unknown_detector_raises():
    with pytest.raises(UnknownDetectorError):
        build_query(SurveillanceQueryRequest("not_a_real_detector", "JP"))


def test_build_query_never_targets_base_obligation_map():
    """The skill must never be able to construct a query against a table not in
    DETECTOR_VIEWS -- in particular, never the base OBLIGATION_MAP (Fix #6's gate)."""
    for detector, view in build_query.__globals__["DETECTOR_VIEWS"].items():
        assert view != "OBLIGATION_MAP"


def test_wash_trading_requires_companion_coverage_query():
    """Fix #3: a wash-trading finding must always be presentable alongside coverage."""
    req = SurveillanceQueryRequest("wash_trading", "JP")
    companion = companion_coverage_query(req)
    assert companion is not None
    assert "WASH_DETECTION_COVERAGE" in companion


def test_other_detectors_have_no_companion_requirement():
    req = SurveillanceQueryRequest("spoofing_layering", "JP")
    assert companion_coverage_query(req) is None


def test_assure_report_ready_when_complete():
    templates = [TemplateField("Price", "TRADES.PRICE", None, True, "mapped")]
    verdict = assure(templates, {"TRADES.PRICE": 100}, pct_required_fields_mapped=1.0)
    assert verdict.ready_to_submit is True
    assert verdict.reasons == []


def test_assure_report_not_ready_when_required_field_missing():
    templates = [TemplateField("Price", "TRADES.PRICE", None, True, "mapped")]
    verdict = assure(templates, {}, pct_required_fields_mapped=1.0)
    assert verdict.ready_to_submit is False
    assert "Price" in verdict.unresolved_required_fields


def test_assure_report_gap_field_visible_but_not_blocking():
    """Fix #28: gap fields surfaced in reasons for transparency, but don't flip ready_to_submit
    to False on their own."""
    templates = [
        TemplateField("Price", "TRADES.PRICE", None, True, "mapped"),
        TemplateField("Trading_Capacity", None, None, True, "gap"),
    ]
    verdict = assure(templates, {"TRADES.PRICE": 100}, pct_required_fields_mapped=0.5)
    assert verdict.ready_to_submit is True
    assert verdict.gap_fields == ["Trading_Capacity"]
    assert any("gap" in r.lower() for r in verdict.reasons)
    assert any("50%" in r for r in verdict.reasons)
