---
type: Improvement Request
title: Pass structured-output schemas through the CLI providers
description: >-
  Let the Codex CLI and Claude CLI providers honour a request's JSON schema by passing it to
  `codex exec --output-schema` and `claude --json-schema`, and advertise that capability, so a
  typed caller gets schema-enforced output on a subscription CLI as it does on the APIs.
timestamp: 2026-09-30T00:00:00Z
generated:
  by: agent:anthropic/claude-opus-5-5
  at: "2026-09-30T00:00:00Z"
requestId: IR-11
status: proposed
origin: mori://shinzui/mina
targetPlan: mori://shinzui/mina/plans/240-evaluate-plan-judgment-quality-and-verify-the-complete-workflow
---

# Improvement Request: Pass Structured-Output Schemas Through the CLI Providers

## Status

Proposed. This is the Baikai-owned half of enforcing typed judge output on CLI providers; the
Shikumi half is `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-4`, which depends on
it.

## Context

Mina's plan-assessment judges are typed Shikumi programs whose outputs contain lists of records
(readiness concerns, promised behaviors, delivery rows, coverage rows). On the OpenAI and Anthropic
APIs Shikumi sends the derived JSON schema as the provider's response format and the provider
enforces it. Through `codex-cli` or `claude-cli` it cannot: the request's schema never reaches the
CLI, so Shikumi falls back to a marker-section prompt and the model free-writes each field.

A bounded live evaluation in Mina (codex-cli, gpt-5.6-luna, 62 judge runs over 24 cases) failed 43
runs for exactly this reason: arrays of plain strings where arrays of objects were required, e.g.
`SchemaMismatch "concerns.[0]: expected object, got string"` and
`MissingField "behaviors.[0].statement"`. Both CLIs already accept a schema:

```text
codex exec --output-schema <FILE>    (codex-cli 0.159.0)
claude --json-schema <schema>        (Claude Code 2.1.285)
```

At `baikai-0.7.1.0` (master `f2bf6b7`) neither `Baikai.Provider.OpenAI.Cli`, `Baikai.Provider.Claude.Cli`,
nor `Baikai.Provider.Cli.Internal` reads a request's response format, so a caller that pays nothing
per call through a subscription CLI loses schema enforcement it would get on the metered API.

## Requested Change

When a request carries a JSON-schema response format, the Codex CLI provider writes the schema to
a temporary file and passes `--output-schema <file>`; the Claude CLI provider passes
`--json-schema <schema>`. The final structured reply is returned as the response content exactly
as the API providers return theirs. Expose the capability on the model or provider (for example a
`supportsJsonSchema` flag, or a documented `api` value) so a caller can decide between native and
fallback output without hard-coding provider names. A CLI version that rejects the flag must
produce a clear, typed error rather than a silent fallback. Keep requests without a response
format unchanged.

## Acceptance

1. A hermetic fake `codex` and fake `claude` receive the schema flag with the request's exact
   schema when a response format is set, and no schema flag otherwise.
2. A nested schema (an array of objects with enum-valued fields) round-trips: the fake returns
   conforming JSON and the provider yields it unmodified.
3. The capability is observable from the model/provider value without calling the CLI.
4. An unsupported-flag failure from the CLI surfaces as a distinct, documented error.
5. Existing CLI behavior without a response format is byte-for-byte unchanged.

## Requested Deliverables

- Schema passthrough in both CLI providers, with the temporary-file lifecycle for Codex.
- A public capability signal for native structured output.
- Hermetic tests and a user-guide note on structured output through CLIs.
- A tagged release in the Baikai cohort Shikumi consumes.
