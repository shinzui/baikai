---
type: Bug Report
bugId: BUG-2
title: "Codex batch transport concatenates complete messages and corrupts structured output"
description: "The Codex CLI adapter joins intermediate and final agent messages, turning individually valid schema-shaped JSON objects into invalid adjacent JSON and causing downstream MissingField failures."
status: confirmed
severity: degraded
origin: mori://shinzui/mina/plans/260-fix-missingfield-why-failures-in-plan-explain-commands
affects: mori://shinzui/baikai
capability: mori://shinzui/baikai/okf/capabilities/concepts/CAP-15
affectedVersion: "Reproduced: baikai 0.8.0.0 with baikai-openai 0.7.1.1; concatenating implementation also present in released baikai 0.10.1.0 and the report-time checkout."
environment: "aarch64-darwin, GHC 9.12.4, codex-cli 0.169.0; Mina 5d07d72, Shikumi 0.4.1.1; codex-cli / gpt-5.6-luna / high effort. Hermetic reproduction uses a fake executable without credentials."
observed: "parseCodexJsonlStream concatenates every agent_message text. Two complete JSON objects become adjacent JSON; Shikumi rejects that body as JSON and its marker fallback raises MissingField why even though both original messages contain why."
expected: "The Codex provider returns the final agent answer as its response text, preserving the provider-enforced JSON schema; intermediate commentary is not concatenated into that answer."
workaround: "No reliable consumer workaround established. A single-message run succeeds and may be cached, but retrying can repeat the defect. Do not disable schema enforcement or accept arbitrary JSON substrings."
reproduction:
  - "Configure codexCliProvider with a private fake executable that emits the two item.completed agent_message JSONL events shown below and exits zero."
  - "Call the public provider with a native JsonSchema response format requiring why, what, blocking, and status."
  - "Observe response text containing two adjacent JSON objects instead of the final object's text."
  - "Run either Mina explain judge through that provider; both bounded attempts fail with MissingField why."
  - "Run the two transportDiagnosis examples in mori://shinzui/mina at commit 03c14aa; their passing assertions document the current failure, not successful final-answer decoding."
timestamp: "2026-11-14T00:52:59Z"
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-11-13T23:01:23Z"
reviews:
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-11-13T23:01:23Z"
    document_timestamp: "2026-11-13T23:01:23Z"
    context: "Author self-check against CAP-15, the final-message promise in the CLI provider guide, released and owning-checkout parser source, the captured live failure, and two hermetic consumer transport diagnostics. This is not an independent review or a claim that a fix is implemented."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-11-13T23:59:09Z"
    document_timestamp: "2026-11-13T23:59:09Z"
    context: "Implementation self-check of local final-message correction and regression coverage; release and consumer acceptance remain pending; this is not an independent review or a claim of publication."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-11-14T00:07:29Z"
    document_timestamp: "2026-11-14T00:07:29Z"
    context: "Clarify that affected checkout observations refer to report time after local repair. Release preparation is gated; publication and consumer acceptance remain pending. This is an author self-check."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-11-14T00:52:59Z"
    document_timestamp: "2026-11-14T00:52:59Z"
    context: "Author verification of published core and adapter archives, documentation, tags, and isolated tests. Mina adoption remains in progress, so the report stays confirmed."
---

# Codex batch transport concatenates complete messages and corrupts structured output

## Broken shipped behavior and impact

[CAP-15](../capabilities/subscription-cli-backends.md) provides subscription-backed
batch calls with structured-output support. The [CLI provider guide](../user/cli-providers.md),
in its schema-output section, says the Codex response text is the final agent
message constrained to the schema. The adapter instead returns the concatenation
of all agent messages. A valid intermediate message followed by a valid final
answer can therefore break the promised JSON response shape.

This caused repeated failures of Mina's `master-plan explain` command for
`mori://shinzui/kotei/masterplans/27-expose-repository-admission-and-deployment-workflows-for-kotei-ui`.
ExecPlan explain uses the same transport and the hermetic reproduction fails for
both plan kinds. The path picker resolves correctly; supplying an explicit path
also reproduces. Both the global Mina binary and a consumer runtime using the
released dependencies are affected. Single-message successes made initial cold
and cached checks insufficient to expose the defect.

## Minimal sanitized reproduction

Have a private fake executable emit the following JSONL to stdout and exit zero:

```jsonl
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"why\":\"Intermediate\",\"what\":\"X\",\"blocking\":\"B\",\"status\":\"S\"}"}}
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\"why\":\"Final\",\"what\":\"X\",\"blocking\":\"B\",\"status\":\"S\"}"}}
```

Configure `Baikai.Provider.OpenAI.Cli.codexCliProvider` with that executable and
call it with a `JsonSchema` response format requiring four string fields: `why`,
`what`, `blocking`, and `status`. The fixture contains no real provider session,
credentials, authored plans, or private response text.

Expected response text:

```json
{"why":"Final","what":"X","blocking":"B","status":"S"}
```

Actual response text:

```text
{"why":"Intermediate","what":"X","blocking":"B","status":"S"}{"why":"Final","what":"X","blocking":"B","status":"S"}
```

Each original body parses independently and contains all four required fields.
The concatenated body fails JSON decoding with `Extra data`. With Shikumi's
`parseResponse`, non-JSON bodies take the marker decoder, which finds no markers
and raises the misleading `MissingField "why"`. Both of Mina's two allowed
attempts can fail this way; increasing retries does not repair extraction.

## Executable consumer evidence

Originating work: `mori://shinzui/mina/plans/260-fix-missingfield-why-failures-in-plan-explain-commands`.
Consumer source: `mori://shinzui/mina`, project-relative
`mina-core/test/Mina/PlanDigest/ExplainSpec.hs`, function `transportDiagnosis`
(artifact-level source URI pending), commit `03c14aa`.

Those examples run Mina's configured judge runtime through the actual public
Codex adapter and its stdout parser, replacing only the spawned executable with
a temporary fixture. They cover both explain programs and assert the current
exception. Once the upstream correction is adopted, replace those diagnostic
failure expectations with successful final-briefing assertions.

Run in the consumer checkout at that commit:

```bash
cd "$(mori path mori://shinzui/mina)"
cabal test mina-core:test:mina-core-test \
  --test-options='--match "reproduces MissingField why through the Codex transport"'
```

The complete focused explain suite passed 34 examples on 2026-11-13, including
both diagnostics. In a live cold-cache run of Kotei MP-27 using the same action
settings as the user's shell, captured stdout contained multiple individually
valid four-field JSON agent messages on both attempts; Mina exited 1 with:

```text
explain error: skill output: explain failed: user error (MissingField "why")
```

Raw captures remain local to the reporting session. The sanitized fixture above
is sufficient to reproduce without a model or access to Kotei.

## Source and release observations

At report time, `baikai/src/Baikai/Provider/Cli/Internal.hs` documented `CodexRunReport.message`
as the concatenation of every agent message, and `parseCodexJsonlStream` built it
with `Text.concat (reverse (acc ^. #messages))`. The Codex adapter in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` returns that value as the
assistant response text. Separate `item.completed` messages are therefore
incorrectly treated as pieces of one response.

Reproduction uses core 0.8.0.0 and adapter 0.7.1.1. On 2026-11-13, Hackage's
package-version JSON and upstream tags were checked: latest published core
0.10.1.0 still contains the same concatenating implementation. Its release tag
`baikai-0.10.1.0` peels to `cdb79e5805613ab60074bb2c9279d779af610c05`.
The owning checkout retained it when this report was filed. No fixed release or
last-working version was established at report time. This does not assert that every intermediate release was
executed against a real model.

## Fix acceptance

- Return the authoritative final agent answer, retaining native schema enforcement.
  Codex's `--output-schema` describes the final response shape; its documented
  `--output-last-message FILE` is one possible extraction mechanism. The exact
  transport implementation belongs to Baikai.
- Add positive hermetic provider tests with intermediate plus final messages,
  a single final message, and malformed final output. Do not repair malformed
  final output by selecting an earlier valid object or an arbitrary substring.
- Preserve independently collected usage, thread identity, evidence, process
  cleanup, and failure handling. If a temporary final-answer file is introduced,
  cover its lifetime and cleanup on success, nonzero exit, and cancellation.
- Publish the correction and rerun Mina's two transport diagnostics as positive
  final-answer checks, followed by cold/repeated/preview command checks under the
  original explain settings. Do not treat existing cache hits as proof of repair.

## Correction progress

[Plan 103](../plans/103-return-only-the-final-codex-agent-message.md) implements
last-completed-message selection and hermetic parser and public-provider
regressions. The report remains confirmed until the correction is published and
Mina's positive diagnostics and cold/repeated/preview checks pass. Local acceptance
and correcting release versions are recorded in the plan; local success alone
does not resolve this report.

## Published correction

`baikai 0.10.1.1` and `baikai-openai 0.7.3.1` are published on Hackage with
documentation. Both annotated release tags peel to
`7a1d45ee7437e5f572cec741bcf68e464a3e43c2`. The adapter requires
`baikai ^>=0.10.1.1` in library and tests. Its archive passed all 339 tests
outside the workspace while resolving core 0.10.1.1 from the signed Hackage
repository. The core archive independently passed all 857 tests.

Mina's existing cohort pins the affected core and Shikumi family. Its adoption
and positive final-briefing diagnostics are in progress; cold/repeated/preview
checks have not yet been rerun with the fix. The report therefore remains
confirmed.
