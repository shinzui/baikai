---
type: Friction Entry
title: "Capability strict validation encounters pre-existing missing review metadata"
description: "Strict capability-bundle validation reports missing recommended reviews on older records unrelated to TypeSafe."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T13:00:50Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/baikai"
affectedVersion: "unreleased"
plan: "docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md"
workaround: "Preserve historical provenance, validate required bundle/profile/log rules, and strictly validate the new CAP-27 record in an isolated bundle with its honest implementation self-check."
resolution: "The new CAP-27 record passes isolated strict validation with honest implementation self-check provenance; the full existing bundle passes required profile/log validation, while historical missing-review recommendations remain recorded without fabricated attribution."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T13:02:29Z"
    change: "Triage the pre-existing strict-metadata baseline separately from TypeSafe acceptance."
---
# Capability strict validation encounters pre-existing missing review metadata

## Attempted

okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce

## Encountered

All older records except subscription-cli-backends lack the newly recommended reviews field; strict validation fails despite no required-field errors.

## Workaround

Preserve historical provenance, validate required bundle/profile/log rules, and strictly validate the new CAP-27 record in an isolated bundle with its honest implementation self-check.
