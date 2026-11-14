---
type: Friction Entry
title: "Mori registry unavailable during final-message correction"
description: "The Mori PostgreSQL socket refused connections, preventing dependency and consumer registry discovery."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T23:51:22Z"
frictionId: FRIC-6
status: "accepted"
impact: blocked
kind: environment
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/mori"
plan: "docs/plans/103-return-only-the-final-codex-agent-message.md"
resolution: "Registry connectivity remains unavailable; this run uses authoritative Hackage and upstream tags plus scoped sibling-checkout identity checks and local manifest validation. Registry refresh remains pending."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T00:01:36Z"
    change: "Accept the registry discovery outage for this run with scoped fallback; do not claim registry registration succeeded."
---
# Mori registry unavailable during final-message correction

## Attempted

mori registry list; mori registry search codex

## Encountered

NotifierConnectError: connection to the local PostgreSQL socket was refused

```text
/Users/shinzui/.local/state/sungkyung-clients/postgresql/.s.PGSQL.5432: Connection refused
```
