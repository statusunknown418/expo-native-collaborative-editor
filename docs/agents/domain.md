# Domain Docs

## Layout

Single-context: `GLOSSARY.md` at the repository root; ADRs in `docs/adr/`.

## Before exploring

- Read root `GLOSSARY.md`.
- Read ADRs in `docs/adr/` relevant to the area being explored.

If these files do not exist, proceed silently. Do not flag their absence or suggest creating them upfront. `/domain-modeling` creates them lazily when terms or decisions are resolved.

## Use the glossary's vocabulary

Use glossary terms when naming domain concepts in issue titles, refactor proposals, hypotheses, and tests. Avoid synonyms the glossary explicitly rejects.

If a needed concept is missing, reconsider whether it belongs to the project or note the gap for `/domain-modeling`.

## Flag ADR conflicts

Explicitly identify any existing ADR your proposal contradicts and explain why reopening the decision is worthwhile.
