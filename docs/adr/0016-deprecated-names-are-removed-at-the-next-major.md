---
title: A deprecated name is removed at the next major release after the one that deprecates it
status: accepted
date: 2026-08-27
---

# A deprecated name is removed at the next major release after the one that deprecates it

## Context

Baikai 0.3.0.0 renamed sixteen record base values from the `_Type`
spelling (`_Options`, `_Response`, `_TextContent`, …) to `emptyType` /
`zeroType`, kept the old names as `DEPRECATED` aliases, and said in the
changelog that they "remain for this release". Two majors then shipped —
0.4.0.0 and 0.5.0.0 — and they were still there. So were the eight
`registerWith*` registration shims deprecated when the provider values
became first class, and `Baikai.Trace.newEventId`, which had delegated to
`Baikai.Evidence.newCallId` since 0.5.0.0.

Nothing in the repository was wrong about any of them. The pragmas were
accurate, the replacements existed, and the plan that created them
(`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`) said
"remove them in the next major". What was missing was a *version*. "The
next major" is a statement about an unnamed future release, so at every
release the question "is this the one?" had no answer in the record, and
the safe answer — keep them — won twice. A downstream reading the
pragma got the same non-answer: it told them to migrate but not by when,
so migrating could always wait.

A deprecated name that never dies is worse than either alternative. It
keeps a second spelling of every value in the API, in the Haddock, and in
every consumer's habits, and it makes the deprecation itself
untrustworthy: a reader who has seen one name outlive its removal notice
by two majors reasonably treats the next notice as decoration.

## Decision

A name deprecated in release `A.B.0.0` is removed in the next major
release, `A.(B+1).0.0`. There is exactly one major of overlap.

Three things follow, and all three are mechanical:

1. Every `DEPRECATED` pragma names the release that removes it, as its
   last sentence: `"Use emptyOptions instead. Removed in baikai
   0.6.0.0."` The pragma is written with that sentence already in it, at
   the moment the deprecation is added — the removal version is known
   then, because it is the next major.

2. The changelog entry that announces the deprecation names the same
   version, under `### Deprecated`.

3. Cutting release `A.B.0.0` includes grepping for pragmas that name it:
   `grep -rn 'Removed in .* A.B.0.0' */src` must be empty, because
   everything it would find should already have been deleted in the same
   release. This is a step in the release procedure, not a convention
   someone has to remember.

The rule binds the *library's* names. It says nothing about deprecating a
whole package or a CLI flag, which have their own audiences and their own
timelines.

## Consequences

A consumer building with `-Werror=deprecations` gets exactly one major
release to migrate, and knows from the warning text itself which release
takes the name away. That is a short window, deliberately: it is long
enough to be a real migration path and short enough that the deprecation
is a decision rather than a permanent second surface.

Baikai 0.6.0.0 applies the rule retroactively to everything outstanding —
the sixteen `_X` aliases, the six CLI registration shims, both
`registerWithRegistry` functions, `newEventId` and
`Baikai.Compat.defaultAnthropicThinkingStyle`. Their overlap has been two
majors rather than one; nothing is served by extending it further, and
0.6.0.0 is already a breaking release for other reasons.

The cost is that a deprecation can no longer be added casually. Writing
one now means committing to a removal in the next major, which is a
reason to prefer keeping a name (with an honest Haddock explaining what
to prefer) over deprecating it when there is no real intent to remove it.
That is the right pressure: an unenforced deprecation is a lie about the
future, and a name kept on purpose is not.
