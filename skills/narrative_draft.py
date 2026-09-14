"""narrative-draft skill (architecture.md "Agent and Skills" section) -- trace a confirmed
surveillance finding to root cause via lineage, draft remediation/regulator narrative. Same name
as Praman's, same thin-orchestration-over-native-lineage design: this module walks a finding's
AUDIT_LOG lineage (sign-off chain via SIGNOFF_FOR_RUN_ID, cited rule chunks via
RETRIEVED_RULE_CHUNK_IDS) and renders a narrative -- it does not invent findings or citations.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class AuditRun:
    run_id: str
    stage: str
    output: str | None
    retrieved_rule_chunk_ids: list[str] = field(default_factory=list)
    signoff_for_run_id: str | None = None
    human_decision: str | None = None
    signoff_by: str | None = None


def build_lineage_chain(run_id: str, runs_by_id: dict[str, AuditRun]) -> list[AuditRun]:
    """Walks SIGNOFF_FOR_RUN_ID backwards from a sign-off row to the run it approved/rejected,
    and forwards to any later sign-off of that run -- returns the chain in chronological order
    (root finding first). Purely a graph walk over caller-supplied AUDIT_LOG rows; no query
    logic here (that's scripts/ or a future ingest job's job)."""
    chain = []
    seen = set()
    current = runs_by_id.get(run_id)
    while current is not None and current.run_id not in seen:
        seen.add(current.run_id)
        chain.append(current)
        current = runs_by_id.get(current.signoff_for_run_id) if current.signoff_for_run_id else None
    return list(reversed(chain))


def draft_narrative(chain: list[AuditRun]) -> str:
    """Renders a plain-language narrative from a lineage chain. A real narrative-draft would
    likely use an LLM completion here; this is the deterministic scaffold/fallback -- every
    fact in the output is drawn directly from the chain, nothing is invented."""
    if not chain:
        return "No lineage found for this finding."

    finding = chain[0]
    lines = [f"Finding (run {finding.run_id}, stage '{finding.stage}'): {finding.output or '(no output recorded)'}"]

    if finding.retrieved_rule_chunk_ids:
        lines.append(f"Cited rule chunks: {', '.join(finding.retrieved_rule_chunk_ids)}")
    else:
        lines.append("No rule chunks cited for this finding.")

    for run in chain[1:]:
        if run.human_decision:
            lines.append(
                f"Sign-off (run {run.run_id}): {run.human_decision} by {run.signoff_by or 'unknown'}"
            )

    return "\n".join(lines)
