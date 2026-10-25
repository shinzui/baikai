---
type: Friction Entry
title: "Claude cancellation fixture races fixed startup delay under build load"
description: "The existing Claude lifecycle cancellation fixture failed twice during parallel suite builds and passed when its suite ran serially."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T12:35:22Z"
frictionId: FRIC-1
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/baikai"
affectedVersion: "unreleased"
plan: "docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md"
workaround: "Run the full Claude suite with --test-options=--num-threads=1 after compilation completed; all 433 tests passed."
resolution: "Run the Claude suite serially after compilation for this initiative; the fixture startup race is independent of the structured-content implementation."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T12:35:37Z"
    change: "Triage after EP-83: serial full-suite verification passes; retain the observed startup-race cost."
---
# Claude cancellation fixture races fixed startup delay under build load

## Attempted

Run the offline core, provider, sink, effectful and documentation suites together with cabal test.

## Encountered

LifecycleSpec cancellationReleasesWithoutGcTest killed its consumer after 100ms without synchronizing fake driver startup; closedRef remained false.

```text
test/LifecycleSpec.hs:106: cancellation releases the connection without a GC; two parallel runs failed; serial run: All 433 tests passed (5.54s).
```

## Workaround

Run the full Claude suite with --test-options=--num-threads=1 after compilation completed; all 433 tests passed.
