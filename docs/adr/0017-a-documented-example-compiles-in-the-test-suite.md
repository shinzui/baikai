---
title: A documented example compiles in the test suite
status: accepted
date: 2026-08-27
---

# A documented example compiles in the test suite

## Context

`docs/capabilities/` holds twenty-two capability records, and each has a
`## Shape` block: the shortest thing a consumer copies to adopt the
capability. It is the most-copied code in the repository, because a
record exists precisely to be adopted.

The August review (REV-2, Theme H.1) found that twelve of the twenty-two
did not compile. None of the failures were typos. Each was a place where
a shipped change moved the code and left the record behind: `#tools`
moved from `Options` to `Context`, `runToolLoop` took its budget first,
`fileSink` became `IO TraceSink`, `withTrace` never was in the umbrella
`Baikai` module, `registerWith` was removed, `JsonSchema` grew a payload
record, `AgentRenderError` never had an `Exception` instance so
`either throwIO pure` could not type-check, `complete` returned
`Eff es Response` rather than `Eff es Text`. Every one of them had been
true when it was written.

Prose that drifts is a cost. A code block that drifts is a trap: a
consumer copies it, does not compile, and concludes the library is
broken or the documentation is abandoned. And the drift is invisible to
every check the repository had, because Markdown is not compiled.

The same problem in Haddock has a standard answer — `doctest` — which
does not reach here: these blocks live in OKF Markdown concepts, not in
`-- |` comments, and they deliberately refer to free names (`model`,
`ctx`, `opts`) that a record should not have to define.

## Decision

**Every fenced `haskell` block in a capability record is compiled by the
ordinary test suite, and the record and the compiled copy are checked
against each other by the same command.**

The mechanism is `baikai-smoke:test:doc-shapes`. Each record with a
`haskell` Shape has a twin module `baikai-smoke/doc-shapes/Shape/CapN.hs`
carrying that block between `-- BEGIN CAP-N` and `-- END CAP-N` markers;
free names come from `Shape/Fixtures.hs`, where every fixture is an
`error` thunk, because the blocks are compiled and never run. Compiling
the suite proves the blocks type-check against the current exports.
Running it compares each record with its module's marked region and
fails naming the record, the module and the first differing line. Two
completeness checks close the loop: a module with no record and a record
with no module are both failures.

`baikai-smoke` hosts it because it is the one package that may depend on
all seven publishable packages without disturbing publish order, and it
is never uploaded. The suite is in `cabal test all`, so it is in the
release procedure's keyless gate.

A Shape that is not Haskell is still checked, by the honest equivalent.
CAP-18's Shape is KDL, so the suite writes it to a file and resolves it
through `Baikai.Agent.Config`, asserting the job it declares is the job
that comes back: configuration is data, and resolving it is what
compiling is for code.

The rule this places on code authors: **a change that moves a name
documented in a record edits the record in the same commit.** The build
will say which one.

The convention the blocks follow — declarations or an `IO` `do` body, an
optional preamble of the imports a reader actually needs, and lens,
`OverloadedLabels` and `Data.Vector qualified as V` assumed in scope — is
stated in `docs/capabilities/index.md`, the bundle's own contract, rather
than here, because it is about how a record reads.

## Consequences

The repository's formatter became the arbiter of what a documented
example looks like. `nix fmt` runs over the twin modules, so the first
formatted commit made twenty blocks disagree with their records at once:
aligned `let` columns collapsed, a constraint gained parentheses, a
two-space comment gap became one. The resolution was to regenerate every
record's block *from* its formatted module, which is the better
direction — a record can no longer show Haskell the repository would
rewrite — and to have the checker ignore blank lines at the edges of a
marked region, because the formatter puts one before a closing comment
and that is layout, not content.

Supplying fixtures introduces an ambiguity a real consumer would not
meet: `Shape.Fixtures.model` collides with the `model` selector of
`Response` under `DuplicateRecordFields`. The twin modules resolve it
with `import Baikai hiding (model)`; the records are untouched, because
the collision is an artifact of the harness.

The checker reads the *first* `haskell` fence under `## Shape`. A record
that shows two — CAP-10 shows `otelSink` and then `otelSinkWith` under a
caller's parent context — has only its first compiled. Covering the rest
would need either several marker pairs per module or several modules per
record, and neither is worth the shape of the rule; a record that leans
on a second block should ask whether the second block is the Shape.

This does not extend to `docs/user/`. A guide is prose with illustrative
fragments, many of them deliberately elided (`emptyModel { … }`), and
compiling them would mean rewriting them into programs. Guides are held
to the weaker standard the plans already use: every name in a new or
changed fence is resolved in `cabal repl baikai-smoke:test:doc-shapes`,
which has all seven packages in scope, and the transcript goes in the
plan.
