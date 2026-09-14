"""rule-interpret skill (architecture.md "Agent and Skills" section) -- new exchange rule/
circular -> OBLIGATION_MAP gap analysis. Parallel to Praman's circular-interpret.

What this implements: the gap-analysis MECHANISM (given the set of detector-backed concepts a
rule chunk requires, and the set already covered by APPROVED_OBLIGATIONS, which ones are
missing). What this does NOT implement: real extraction of "what a rule chunk requires" from
actual FSA/SESC circular text -- that needs the real rule corpus, which architecture.md's "What's
explicitly deferred" section flags as not yet sourced. `required_concepts` is caller-supplied
here (an analyst's or an NLP step's own reading of the rule), not derived from real text.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ObligationGap:
    detector_name: str
    rule_chunk_id: str
    reason: str


def find_gaps(
    required_concepts: set[str],
    approved_detector_names: set[str],
    rule_chunk_id: str,
) -> list[ObligationGap]:
    """required_concepts: detector names (or detector-equivalent concept keys) a rule chunk's
    plain reading requires an obligation mapping for. approved_detector_names: the
    DETECTOR_NAME values already present in APPROVED_OBLIGATIONS (Fix #6 -- read from that view,
    never the base OBLIGATION_MAP, so a gap analysis never treats an unapproved, in-review
    mapping as if it already covers the requirement)."""
    missing = required_concepts - approved_detector_names
    return [
        ObligationGap(
            detector_name=concept,
            rule_chunk_id=rule_chunk_id,
            reason=f"'{concept}' has no APPROVED obligation mapping yet; a 'proposed' "
                   f"OBLIGATION_MAP row citing {rule_chunk_id} is needed.",
        )
        for concept in sorted(missing)
    ]
