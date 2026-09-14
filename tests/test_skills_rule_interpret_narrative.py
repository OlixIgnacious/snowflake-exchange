"""Tests for the rule-interpret and narrative-draft skills."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from skills.narrative_draft import AuditRun, build_lineage_chain, draft_narrative
from skills.rule_interpret import find_gaps


def test_find_gaps_identifies_uncovered_concepts():
    gaps = find_gaps(
        required_concepts={"wash_trading", "position_limit", "large_in_scale_deferral"},
        approved_detector_names={"wash_trading", "position_limit"},
        rule_chunk_id="JP-CIRC-2026-01-S3",
    )
    assert len(gaps) == 1
    assert gaps[0].detector_name == "large_in_scale_deferral"
    assert gaps[0].rule_chunk_id == "JP-CIRC-2026-01-S3"


def test_find_gaps_empty_when_fully_covered():
    gaps = find_gaps({"wash_trading"}, {"wash_trading", "position_limit"}, "JP-CIRC-2026-01-S3")
    assert gaps == []


def test_find_gaps_does_not_treat_proposed_as_covered():
    """approved_detector_names must come from APPROVED_OBLIGATIONS (Fix #6), never the base
    table -- this test just confirms the function has no way to be fooled by a 'proposed' entry
    since it only ever receives what the caller labels 'approved'."""
    gaps = find_gaps({"wash_trading"}, approved_detector_names=set(), rule_chunk_id="X")
    assert len(gaps) == 1


def test_build_lineage_chain_walks_signoff_backwards():
    runs = {
        "RUN1": AuditRun("RUN1", "surveillance-query", "wash trade candidate found", ["CHUNK1"]),
        "RUN2": AuditRun("RUN2", "signoff", None, signoff_for_run_id="RUN1", human_decision="confirmed", signoff_by="analyst1"),
    }
    chain = build_lineage_chain("RUN2", runs)
    assert [r.run_id for r in chain] == ["RUN1", "RUN2"]


def test_draft_narrative_includes_citation_and_signoff():
    runs = {
        "RUN1": AuditRun("RUN1", "surveillance-query", "wash trade candidate found", ["CHUNK1"]),
        "RUN2": AuditRun("RUN2", "signoff", None, signoff_for_run_id="RUN1", human_decision="confirmed", signoff_by="analyst1"),
    }
    chain = build_lineage_chain("RUN2", runs)
    narrative = draft_narrative(chain)
    assert "wash trade candidate found" in narrative
    assert "CHUNK1" in narrative
    assert "confirmed by analyst1" in narrative


def test_draft_narrative_empty_chain():
    assert draft_narrative([]) == "No lineage found for this finding."


def test_draft_narrative_no_citations():
    runs = {"RUN1": AuditRun("RUN1", "surveillance-query", "finding with no citation")}
    chain = build_lineage_chain("RUN1", runs)
    narrative = draft_narrative(chain)
    assert "No rule chunks cited" in narrative
