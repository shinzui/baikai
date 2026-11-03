---
type: Friction Entry
title: "Hackage index refresh lags the published core package"
description: "The default HTTP Cabal index refresh omits a core version already published on Hackage, preventing the dependent binding archive from resolving."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T14:44:10Z"
frictionId: FRIC-5
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/baikai"
affects: "https://hackage.haskell.org/"
plan: "docs/plans/102-deliver-aborted-call-evidence-through-the-effectful-binding.md"
workaround: "Use a scratch Cabal config pointing at official HTTPS with secure verification enabled, retaining the original global config and credentials; refresh the index before retrying dependent verification."
resolution: "Official signed Hackage snapshots now include core 0.10.1.0 at index-state 2026-11-03T14:41:31Z and binding 0.5.0.0 at 2026-11-03T14:46:56Z; HTTPS scratch refresh preserves signed verification, original credentials, bounds and published tags."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T14:45:44Z"
    change: "Resolve publication-to-index lag through signed HTTPS refresh, preserving credentials, package bounds and published tags."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T14:50:34Z"
    change: "Record both cohort versions reaching the signed index and retain the official HTTPS refresh workaround for downstream consumers."
---
# Hackage index refresh lags the published core package

## Attempted

After publishing baikai 0.10.1.0, run cabal update, verify the refreshed version list, and resolve the isolated baikai-effectful 0.5.0.0 archive.

## Encountered

The package page and metadata include 0.10.1.0, but the refreshed index lists only 0.10.0.0 and rejects the binding lower bound.

```text
rejecting: baikai-0.10.0.0 (conflict: baikai-effectful => baikai^>=0.10.1)
```

## Workaround

Use a scratch Cabal config pointing at official HTTPS with secure verification enabled, retaining the original global config and credentials; refresh the index before retrying dependent verification.
