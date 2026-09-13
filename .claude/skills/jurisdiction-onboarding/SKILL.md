---
name: jurisdiction-onboarding
description: Scaffold a new JURISDICTION_CONFIG (a new regulator/venue set) for Vigil's synthetic data generator, following the same live-verification discipline Japan's config went through. Use when onboarding jurisdiction #2+ (e.g. finishing the US config, or adding a new one) — never to fabricate venue data from general knowledge.
---

Vigil's design rule 7 (architecture.md) is that onboarding a new jurisdiction is "a new set of
rows, not a schema or SQL change." This skill scaffolds that new row set — a `JURISDICTION_CONFIG`
— but the entire point of Japan's config, per architecture.md, is that its venue list was **live-
verified against each operator's own site**, not asserted from general knowledge. The US config in
this repo is explicitly flagged as incomplete for the same reason: it has a config but its venue
list "still needs the same per-venue verification discipline Japan got, not a bulk copy of the
SEC's list." Do not skip that step for a new jurisdiction just because it's tedious.

## Steps

1. **Identify the regulator and check for an existing config.** Read `docs/canonical_schema_contract.md`
   and `generator/` (once it exists) for the `JURISDICTION_CONFIG` shape already in use — match it,
   don't invent a new shape per jurisdiction (that's the rule this skill exists to enforce).

2. **Live-verify the venue list — do not proceed on memory alone.** For each candidate venue:
   - Fetch the operator's own site (exchange, PTS/ATS, or equivalent) to confirm it's real and
     currently active, the way Japan's TSE/OSE/TOCOM/Japannext/ODX were each confirmed via their
     own sites in this repo's history.
   - If a venue is discontinued or its status is ambiguous, look for a primary-source
     confirmation (the operator's own press release/IR page — Wayback Machine if the live page
     blocks direct fetch, the way Cboe Japan's closure was confirmed) rather than guessing a status.
   - Record the regulator name, venue codes, venue types, operator names, and (for any
     discontinued venue) `ACTIVE_FROM`/`DISCONTINUED_AT` dates — every one of these needs a source,
     not an assumption.
   - If you cannot verify a venue live (e.g. no web access in this session, or the source is
     ambiguous), **stop and say so explicitly** — hand the user the specific unverified items
     rather than filling them in from training data. architecture.md treats an unverified venue
     list as a blocking gap, not a minor caveat.

3. **Check citation-authority implications.** If the jurisdiction's authoritative rule text isn't
   English, flag that any `RULE_CORPUS` content for it is a provisional translation and must carry
   `SOURCE_AUTHORITY`/`ORIGINAL_LANGUAGE` honestly (design rule 6) — same requirement Japan's config
   already documents.

4. **Write the `JURISDICTION_CONFIG`** (currency, trading calendar, verified venue list with
   status/dates, instrument universe, participant count per venue) matching the existing config
   shape. Do not add a jurisdiction-specific column or fork the generator's schema for this
   jurisdiction — if the new jurisdiction genuinely needs a dimension no other one does, that's a
   nullable extension column (design rule 5), which is a generator/schema change to flag to the
   user, not something this skill does silently.

5. **Hand off to `synthetic-data-checker`** (project agent) once the generator produces output for
   the new config, to validate referential integrity, venue coverage, and date-bounding the same
   way Japan's config is validated.

## What this skill must never do
- Never fabricate a venue, operator name, regulator name, or discontinuation date from general
  knowledge presented as verified fact — architecture.md's entire venue list exists because prior
  drafts got this wrong, and it was caught only by live verification.
- Never bulk-copy a regulator's own SRO/venue list without per-venue confirmation, even if that
  list looks authoritative — the US config's outstanding gap in this repo is exactly that shortcut,
  already flagged as unfinished.
