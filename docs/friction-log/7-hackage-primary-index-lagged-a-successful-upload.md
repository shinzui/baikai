---
type: Friction Entry
title: "Hackage primary index lagged a successful upload"
description: "Hackage published the core package and docs while its primary signed index still predated the release, blocking dependent archive verification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T00:33:22Z"
frictionId: FRIC-7
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/baikai"
affects: "https://hackage.haskell.org"
plan: "docs/plans/103-return-only-the-final-codex-agent-message.md"
workaround: "Use the official hackage-content HTTPS endpoint in a scratch build-only Cabal config, retaining signed repository verification and the existing trusted root; preserve global config and upload credentials."
resolution: "The official hackage-content HTTPS endpoint supplied a fresh signed index, and the adapter archive downloaded the published core and passed all 339 tests using curl transport. Uploaded and downloaded core archive SHA-256 values match."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T00:41:12Z"
    change: "Complete isolated adapter verification against signed Hackage sources after diagnosing primary-index lag and the HTTP mirror failure."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T00:42:19Z"
    change: "Complete isolated adapter verification against signed Hackage sources after diagnosing primary-index lag and the HTTP mirror failure."
---
# Hackage primary index lagged a successful upload

## Attempted

cabal update and verify baikai 0.10.1.1 in the index before isolated adapter verification

## Encountered

The primary host served timestamp version 112284 and index-state 2026-11-13T23:46:56Z after successful publication; switching only HTTP to HTTPS still returned that snapshot.

```text
hackage.haskell.org timestamp version 112284; hackage-content.haskell.org timestamp version 112285
```

## Workaround

Use the official hackage-content HTTPS endpoint in a scratch build-only Cabal config, retaining signed repository verification and the existing trusted root; preserve global config and upload credentials.
