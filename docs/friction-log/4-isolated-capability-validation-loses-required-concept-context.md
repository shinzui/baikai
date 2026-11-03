---
type: Friction Entry
title: "Isolated capability validation loses required concept context"
description: "The plan-recommended isolated strict capability check cannot resolve CAP-32 requirements or body links without the rest of the bundle."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T14:21:07Z"
frictionId: FRIC-4
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/baikai/plans/102-deliver-aborted-call-evidence-through-the-effectful-binding"
plan: "docs/plans/102-deliver-aborted-call-evidence-through-the-effectful-binding.md"
workaround: "Run strict validation in the full dependency context, assert that every diagnostic is a historical missing-reviews recommendation, and verify there are no diagnostics for CAP-32; separately pass required whole-bundle validation."
resolution: "Validate strict CAP-32 diagnostics in the full dependency context while retaining the known historical missing-reviews baseline; the plan now documents this reproducible check."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T14:21:38Z"
    change: "Replace isolated validation advice with full-context strict diagnostic classification without changing historical review provenance."
---
# Isolated capability validation loses required concept context

## Attempted

Validate CAP-32 with index.md and log.md in a scratch bundle using okf validate --strict --profile-enforce --log-enforce.

## Encountered

Isolation removes CAP-20, CAP-9 and CAP-19, causing missing-concept and requires-reference failures.

```text
profile: traced-effectful-collection: requires[0] references CAP-20, which does not exist in this bundle
```

## Workaround

Run strict validation in the full dependency context, assert that every diagnostic is a historical missing-reviews recommendation, and verify there are no diagnostics for CAP-32; separately pass required whole-bundle validation.
