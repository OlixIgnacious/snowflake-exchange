"""assure-report skill (architecture.md "Agent and Skills" section) -- validate a draft
transaction report / limit filing against rule text and obligation mapping before submission.
Parallel to Praman's assure-return. Wraps ingest/report_adaptor.py's mapping mechanism (already
built and tested, Phase 4) rather than reimplementing it -- this module's job is turning that
mapping result into an assurance verdict an agent/analyst can act on, plus surfacing
REPORT_TEMPLATE_COVERAGE (Fix #28) alongside it so "this report is complete" and "this report is
complete among the fields we can currently capture" are never presented as the same claim.
"""
from __future__ import annotations

from dataclasses import dataclass

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ingest.report_adaptor import MappingResult, TemplateField, map_report


@dataclass
class AssuranceVerdict:
    ready_to_submit: bool
    fields_complete: bool
    unresolved_required_fields: list[str]
    gap_fields: list[str]
    reasons: list[str]


def assure(templates: list[TemplateField], canonical_row: dict, pct_required_fields_mapped: float) -> AssuranceVerdict:
    """pct_required_fields_mapped comes from REPORT_TEMPLATE_COVERAGE for this
    (JURISDICTION_ID, REPORT_TYPE) -- passed in rather than queried here, keeping this module
    Snowflake-connection-free and unit-testable."""
    result: MappingResult = map_report(templates, canonical_row)
    reasons: list[str] = []

    if not result.fields_complete:
        reasons.append(
            f"{len(result.unresolved_required_fields)} required mapped field(s) unresolved: "
            f"{result.unresolved_required_fields}"
        )
    if result.gap_fields:
        reasons.append(
            f"{len(result.gap_fields)} required field(s) have no data source yet (gap, not "
            f"blocking): {result.gap_fields}"
        )
    if pct_required_fields_mapped < 1.0:
        reasons.append(
            f"Template itself is only {pct_required_fields_mapped:.0%} mapped -- some required "
            "fields have no source at the template level, independent of this specific report."
        )

    return AssuranceVerdict(
        ready_to_submit=result.fields_complete,  # gap fields and template coverage are visible, not blocking (Fix #28)
        fields_complete=result.fields_complete,
        unresolved_required_fields=result.unresolved_required_fields,
        gap_fields=result.gap_fields,
        reasons=reasons,
    )
