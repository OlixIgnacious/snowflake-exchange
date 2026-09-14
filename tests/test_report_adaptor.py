"""Tests for ingest/report_adaptor.py's mapping mechanism (Fix #22, #28, #29) -- not a real
regulator format, which is explicitly deferred (architecture.md). These tests use synthetic
template/source data, not real Japan FSA/SESC circular content.
"""
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ingest.report_adaptor import TemplateField, map_report, render_payload


def test_mapped_field_resolves_from_canonical_row():
    templates = [
        TemplateField("Price", "TRADES.PRICE", "decimal(18,4)", True, "mapped"),
        TemplateField("Volume", "TRADES.VOLUME", None, True, "mapped"),
    ]
    row = {"TRADES.PRICE": 101.23456, "TRADES.VOLUME": 100}
    result = map_report(templates, row)
    assert result.payload == {"Price": 101.2346, "Volume": 100}
    assert result.fields_complete is True
    assert result.gap_fields == []


def test_gap_field_excluded_from_payload_and_fields_complete():
    """Fix #28/#29: a 'gap' field never blocks fields_complete and is never fabricated."""
    templates = [
        TemplateField("Price", "TRADES.PRICE", None, True, "mapped"),
        TemplateField("Trading_Capacity", None, None, True, "gap"),
    ]
    row = {"TRADES.PRICE": 100}
    result = map_report(templates, row)
    assert "Trading_Capacity" not in result.payload
    assert result.gap_fields == ["Trading_Capacity"]
    assert result.fields_complete is True  # gap field doesn't count against it
    assert result.unresolved_required_fields == []


def test_missing_required_mapped_field_marks_incomplete():
    templates = [
        TemplateField("Price", "TRADES.PRICE", None, True, "mapped"),
        TemplateField("Buyer_LEI", "TRADES.REGULATORY_ATTRIBUTES:buyer_lei", None, True, "mapped"),
    ]
    row = {"TRADES.PRICE": 100}  # LEI source column absent
    result = map_report(templates, row)
    assert result.fields_complete is False
    assert result.unresolved_required_fields == ["Buyer_LEI"]


def test_proposed_field_not_yet_included():
    templates = [
        TemplateField("New_Field", "TRADES.SOMETHING", None, True, "proposed"),
    ]
    row = {"TRADES.SOMETHING": "value"}
    result = map_report(templates, row)
    assert result.payload == {}
    assert result.gap_fields == []
    assert result.fields_complete is True  # no mapped required fields to fail on


def test_optional_field_absent_does_not_affect_completeness():
    templates = [
        TemplateField("Optional_Note", "TRADES.NOTE", None, False, "mapped"),
    ]
    row = {}
    result = map_report(templates, row)
    assert result.payload == {"Optional_Note": None}
    assert result.fields_complete is True


def test_iso8601_date_formatting():
    templates = [TemplateField("Trade_Date", "TRADES.DATE", "ISO8601", True, "mapped")]
    row = {"TRADES.DATE": date(2026, 9, 14)}
    result = map_report(templates, row)
    assert result.payload["Trade_Date"] == "2026-09-14"


def test_render_payload_is_valid_json():
    templates = [TemplateField("Price", "TRADES.PRICE", None, True, "mapped")]
    result = map_report(templates, {"TRADES.PRICE": 100})
    rendered = render_payload(result)
    assert rendered == '{"Price": 100}'
