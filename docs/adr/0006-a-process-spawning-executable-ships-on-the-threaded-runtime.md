---
title: A process-spawning executable ships on the threaded runtime, and its suite proves it
status: accepted
date: 2026-08-27
---

# A process-spawning executable ships on the threaded runtime, and its suite proves it

## Context

`baikai-agent` ships an executable named `baikai`. Its `agent run`
subcommand starts a coding agent as a child process, writes the prompt
on the child's standard input from a forked thread, drains the child's
two output pipes from two more forked threads, and enforces a configured
deadline by wrapping `System.Process.waitForProcess` in
`System.Timeout.timeout`.

The Haskell runtime system — the scheduler GHC links into every binary —
comes in two forms. In the default, non-threaded form a blocking
operating-system call runs on the one operating-system thread that also
runs every Haskell thread, so the whole program stops until that call
returns. The `process` package documents the consequence on
`waitForProcess` itself: "in order to call `waitForProcess` without
blocking all the other threads in the system, you must compile the
program with `-threaded`." In the threaded runtime such a call is moved
to its own operating-system thread and the other Haskell threads keep
running.

Until this record the `baikai` executable stanza carried no
`ghc-options` at all, so the installed binary used the non-threaded
runtime. Every consequence followed: `timeout "45m"` could never fire,
because the timer thread could not run while the main thread sat in
`waitForProcess`; and a child that wrote more than one pipe buffer —
about 64 kilobytes — blocked on its write while the parent's drain
threads were equally unable to run, which is a deadlock with no deadline
to end it.

The defect survived because the *test suite* stanza did carry
`ghc-options: -threaded -with-rtsopts=-N`, and every runner test
exercised the library inside the test binary. Those tests passed, and
they were evidence about the test binary's runtime and about nothing
else. The 2026-08-27 review recorded this as its only critical finding
(`docs/reviews/correctness-and-api-review-follow-up.md`, item F.1).

## Decision

Every executable in this repository that spawns a child process and
waits for it is compiled with `-threaded`.

Whenever an executable's behaviour depends on the runtime it links —
timeouts over blocking calls, concurrent draining, signal handling — its
test suite spawns the *built executable* at least once and asserts that
behaviour against it. A suite's own `ghc-options` are never evidence
about a binary.

The mechanism for that, in this repository, is
`baikai-agent/test/BinaryTests.hs`. The suite declares
`build-tool-depends: baikai-agent:baikai`, which makes cabal build the
executable before the suite and put its directory on the `PATH` the
suite inherits, so `System.Directory.findExecutable "baikai"` finds the
freshly built binary. `BAIKAI_AGENT_TEST_EXECUTABLE` overrides that for
a suite run outside cabal. Finding no executable is a hard failure, not
a skip.

The suite asserts the runtime directly, by running `baikai +RTS --info`
and requiring the reported `RTS way` to be `rts_thr` rather than the
non-threaded `rts_v`; and it asserts the behaviour that runtime exists
for, by running a stub coding agent that outlives its deadline and
requiring the command to exit 75 within seconds rather than waiting out
the stub.

## Consequences

The executable gains `-threaded` and nothing else. No `-N`, because one
child needs no parallelism and the default single capability is what the
runner has always assumed. No `-rtsopts`, because `+RTS --info` — the
probe the test uses — is already permitted under GHC's default
`-rtsopts=some`.

A future executable in this repository that spawns processes inherits
both halves of this: the flag, and a case that runs the built binary. An
executable that does not spawn processes is not covered and needs no
`-threaded` on this record's account.

Two practical notes for anyone changing an executable's `ghc-options`.
First, cabal does not rebuild an executable when only its `ghc-options`
field changes; the stale binary is what the next `cabal test` runs, and
the `+RTS --info` assertion is what makes that visible rather than
mysterious. Remove the component's build directory, or `cabal clean`,
after such a change. Second, a case that spawns the built binary is
subject to how long the operating system takes to start a process while
the rest of the suite runs in parallel, which on a loaded machine
exceeds a second; a deadline asserted against the built binary is chosen
with room for that, not tuned to the fastest observed run.
