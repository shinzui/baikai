---
type: Friction Entry
title: "Scoped family refresh repeats whole-flake evaluation"
description: "The scoped Baikai/Shikumi metadata refresh warmed every flake check and then evaluated the whole flake again, spending over ten minutes before completing."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T00:57:26Z"
frictionId: FRIC-8
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/haskell-nix"
plan: "docs/plans/103-return-only-the-final-codex-agent-message.md"
workaround: "Keep the required production validation, reuse its completed result for unchanged metadata, and continue independent consumer preparation while it runs."
resolution: "Keep the production updater validation for this metadata change. Reuse the completed check for unchanged inputs and perform independent consumer work while it runs; optimizing broad evaluation is outside this correction."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T01:10:31Z"
    change: "Accept the measured scoped-refresh cost for this run without weakening validation."
---
# Scoped family refresh repeats whole-flake evaluation

## Attempted

haskell-nix-update refresh --family baikai --hackage-version baikai-effectful=0.4.0.5

## Encountered

Both nix eval of every Darwin check and nix flake check --no-build --no-eval-cache traversed the complete retained check graph; each took several minutes with RSS above 20 GiB.

## Workaround

Keep the required production validation, reuse its completed result for unchanged metadata, and continue independent consumer preparation while it runs.
