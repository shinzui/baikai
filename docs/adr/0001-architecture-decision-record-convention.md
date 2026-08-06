---
title: Record architecture decisions as plain Markdown files in docs/adr
status: accepted
date: 2026-08-05
---

# Record architecture decisions as plain Markdown files in `docs/adr`

## Context

Until this record, baikai had no Architecture Decision Records and no
convention for writing one. Durable project judgment lived in ExecPlan
Decision Logs under `docs/plans/`, which is the right home for a
decision while a plan is being executed and the wrong home for one that
outlives it: a reader looking for "why is the evidence record shaped
this way" should not have to know which of seven plans made the call.

The initiative documented in
[docs/masterplans/9](../masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md)
produced four decisions that are clearly durable — they constrain how
every future provider is written — and forced the question of where
they go.

The repository's `mori.dhall` manifest declares exactly one OKF bundle,
`improvement-requests` at `docs/improvement-requests`, with the profile
`mori/improvement-requests-profile.dhall`. `mori show --full` reports no
ADR bundle. So there is no profile to validate against, no allocated
`ADR-N` handle to preserve, and no existing convention to follow.

## Decision

Architecture Decision Records live in `docs/adr/` as
`NNNN-kebab-case-slug.md`, one decision per file, numbered sequentially
from `0001` and never renumbered. Each carries a small YAML frontmatter
block with `title`, `status`, and `date`, and a body organised as
Context, Decision, Consequences.

`status` is one of `accepted`, `superseded`, or `rejected`. A superseded
record is kept and its status changed, with a line naming what replaced
it. Records are not deleted: a decision that turned out wrong is more
useful than a gap where it used to be.

Cite a record from a plan or from another record by repository-relative
link. Cite a decision in another repository by the exact
project-and-bundle-scoped `mori://` handle the registry returns, never
by a guessed path.

## Consequences

This is deliberately the lighter of the two options `ADR.md` describes.
The alternative — adopting the shared `documentation.architectureDecisions`
OKF profile, adding an `adr` bundle to `mori.dhall`, allocating stable
`ADR-N` handles through `okf id next`, and running `okf validate
--strict --profile-enforce` in the repository's checks — buys
cross-repository discoverability and a machine-checkable contract. It
also brings a profile descriptor, a reserved `log.md`, and a validation
step into a repository that currently has none of that for its one
existing bundle's sake.

`ADR.md` is explicit that adopting a profiled bundle should not happen
as an incidental plan edit, and that migrating an existing corpus is
separate work with its own blueprint. Establishing the corpus first and
migrating it deliberately later is the ordering that guidance implies.

The cost is that these records are not addressable as
`mori://shinzui/baikai/okf/adrs/concepts/ADR-N` and will not appear in
`mori registry concepts`. A repository that wants to cite one today must
link the file. If that becomes a real obstacle, the migration is
mechanical: the frontmatter here is a subset of what the profile
requires, so adopting it means adding fields rather than restructuring.
