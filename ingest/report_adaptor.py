"""Report-generation adaptor: canonical rows + REPORT_TEMPLATES -> a regulator's required
output. Python, not SQL -- architecture.md's build order explicitly calls this out as separate
from the Semantic Views (sql/semantic_views/).

What this does NOT do: produce a real regulator-specific format (XML/CSV/fixed-width matching
Japan's actual FSA/SESC circular). That requires the real rule text, which architecture.md's
"What's explicitly deferred" section flags as not yet sourced. This module implements the
*mechanism* -- map a template's required fields against a canonical source row, respecting the
STATUS lifecycle (mapped/gap/proposed) -- and emits a generic JSON payload as a placeholder
output format. Swapping in a real regulator format later means changing `render_payload`, not
this mapping logic.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Any


@dataclass
class TemplateField:
    field_name: str
    source_mapping: str | None
    field_format: str | None
    is_required: bool
    status: str  # 'proposed' / 'mapped' / 'gap'


@dataclass
class MappingResult:
    payload: dict[str, Any]
    fields_complete: bool
    gap_fields: list[str] = field(default_factory=list)
    unresolved_required_fields: list[str] = field(default_factory=list)


def format_value(value: Any, field_format: str | None) -> Any:
    """Minimal, format-agnostic value formatting. A real regulator adaptor would extend this
    per FIELD_FORMAT (e.g. a specific fixed-width numeric encoding) -- kept generic here since
    no real format spec exists yet."""
    if value is None:
        return None
    if field_format == "ISO8601" and isinstance(value, (date, datetime)):
        return value.isoformat()
    if field_format and field_format.startswith("decimal(") and isinstance(value, (int, float)):
        try:
            precision = int(field_format.split(",")[1].rstrip(")"))
        except (IndexError, ValueError):
            precision = 4
        return round(float(value), precision)
    return value


def map_report(templates: list[TemplateField], canonical_row: dict[str, Any]) -> MappingResult:
    """Map a report's required fields against a canonical source row.

    Only STATUS='mapped' fields are ever included in the payload or counted toward
    fields_complete -- a 'gap' field (Fix #28: a required field with no current data source) is
    surfaced separately, never fabricated and never silently dropped from visibility (Fix #29:
    fields_complete is computed against mapped fields only, so a structural gap shows up once,
    as a template-level finding, not as permanent per-report incompleteness).
    """
    payload: dict[str, Any] = {}
    gap_fields: list[str] = []
    unresolved_required: list[str] = []

    for t in templates:
        if t.status == "gap":
            gap_fields.append(t.field_name)
            continue
        if t.status != "mapped":
            continue  # 'proposed' fields aren't ready to drive report generation yet

        raw_value = canonical_row.get(t.source_mapping) if t.source_mapping else None
        formatted = format_value(raw_value, t.field_format)
        payload[t.field_name] = formatted

        if t.is_required and formatted is None:
            unresolved_required.append(t.field_name)

    fields_complete = len(unresolved_required) == 0
    return MappingResult(
        payload=payload,
        fields_complete=fields_complete,
        gap_fields=gap_fields,
        unresolved_required_fields=unresolved_required,
    )


def render_payload(mapping_result: MappingResult) -> str:
    """Placeholder rendering -- generic JSON. A real adaptor swaps this for the regulator's
    actual XML/CSV/fixed-width format once that spec is sourced (architecture.md, deferred)."""
    return json.dumps(mapping_result.payload, default=str, sort_keys=True)
