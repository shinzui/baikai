---
title: Library code never calls exitFailure
status: accepted
date: 2026-08-27
---

# Library code never calls exitFailure

## Context

`baikai-kit` is a library. Four command-line tools in this workspace
(`mori`, `rei`, `seihou`, `okf`) embed it as their `kit` subcommand, and
one of them, `rei-cli`, calls into it below the command adapter to drive
an interactive picker.

Its error style was inherited from the program it was factored out of:
`loadManifest`, `installItem`, `listAvailable`, `updateKit`,
`ensureKitRepo` and the internal `requireSafe` printed a message to
stderr and called `exitFailure`. The July hardening pass
(`docs/plans/35-harden-baikai-kit-install-and-status.md`) saw this and
kept it deliberately, "for consistency with the module's established
error style".

The August review recorded the cost as F.11. `exitFailure` throws
`ExitSuccess`/`ExitFailure` as an exception that the runtime turns into a
process exit at the top of `main`. A caller inside a larger program
therefore has its whole process terminated by a missing manifest, an
unsafe manifest name, or a first clone that fails offline — with nothing
in the type to warn it and nothing sensible to catch. Two concrete
consequences were visible in this package:

- `Status.resolveCacheOrEmpty` wrapped `ensureKitRepo` in
  `try @IOException`, intending "no network is fine, report what is
  installed". `ExitCode` is not an `IOException`, so the guard did
  nothing: `kit status` on a fresh machine with no network exited 1
  instead of printing that nothing is installed.
- The library owned messages its callers could not change, could not
  suppress, and could not translate — including the ones it printed on
  the way out.

## Decision

**No exposed module of any baikai package calls `exitFailure`,
`exitWith` or `error` on a failure path.** Failures are values: an
`Either` over a typed error, or a typed exception with a documented
`Exception` instance. Process exit belongs to an executable's `Main`, or
to a function whose documented contract is to *be* a subcommand — today
that is `Baikai.Kit.Command.runKit`, whose Haddock says so.

An adapter that exits gets a twin that does not. `runKitCommand ::
KitConfig -> KitCommand -> IO (Either KitError ())` performs a verb and
prints its normal output; `runKit` calls it, prints `Error: <rendered>`
to stderr, and exits 1. Consumers that want a richer exit vocabulary map
`KitError` themselves.

Matching `ExitCode` from `readProcessWithExitCode` is not an exit and is
unaffected; `Baikai.Kit.Repo` still imports `System.Exit` for that.

A library may still raise its own error type internally and catch it at
each exported boundary — `baikai-kit` does, through a private
`kitTry = try @KitError` — because what a caller observes is the returned
value either way. What it may not do is let a failure leave the package
as an exit or as an untyped exception.

## Consequences

Errors that used to be a message and an exit are now a closed sum
(`Baikai.Kit.Error.KitError`) with one rendering function. Adding a
failure mode means adding a constructor and its line, which is a
compile-time obligation rather than a `printf` somewhere in the middle of
an install.

The change is breaking for a consumer that calls below the adapter, and
breaking in the direction that helps: the compiler flags every call site,
where a thrown exception would have compiled unchanged and kept killing
the process. `rei-cli` binds `Right` from `ensureKitRepo`, `loadManifest`
and `installFrom` when it raises its bound; `mori-cli`, `seihou-cli` and
`okf-cli` use only `runKit` and are unaffected.

Tests assert on values rather than catching `ExitCode`, which is what
made the offline-status bug provable: `kitStatus` now returns a report
whose `upstream` field names the reason the cache was unavailable, and
the suite pins both that value and `runKit`'s exit 0.
