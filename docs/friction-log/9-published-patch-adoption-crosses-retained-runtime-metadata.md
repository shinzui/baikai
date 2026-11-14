---
type: Friction Entry
title: "Published patch adoption crosses retained runtime metadata"
description: "Mina can execute the released fix, but advancing its Hackage cutoff changes metadata identities owned by the retained runtime and requires a coordinated runtime/cohort update."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T01:11:53Z"
frictionId: FRIC-9
status: logged
impact: blocked
kind: process
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/haskell-nix"
plan: "docs/plans/103-return-only-the-final-codex-agent-message.md"
---
# Published patch adoption crosses retained runtime metadata

## Attempted

Adopt core 0.10.1.1 and adapter 0.7.3.1 into Mina with a targeted solve that holds unrelated versions fixed

## Encountered

The fresh plan preserves package archive hashes and flags but changes pkg-cabal-sha256 for runtime-owned crypton-connection 0.4.6, streamly 0.11.1, and warp 3.4.16. Mina ADR-36 and mkRuntimePackageSet require source and metadata agreement across Cabal and Nix.

```text
Candidate solve and all Mina tests/live checks pass; production adoption remains pending a new retained runtime/cohort and an explicit scope decision.
```
