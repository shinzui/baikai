---
id: 105
slug: guard-unsupported-assistant-prefills-on-claude-messages-and-enable-fable-5-2
title: "Guard unsupported assistant prefills on Claude Messages and enable Fable 5.2"
kind: exec-plan
created_at: 2026-11-21T02:56:47Z
intention: "intention_01m7y0gketen78re8dzt6yfsyc"
provenance:
  created_by:
    model: "gpt-6.2-sol"
    harness: "codex-cli"
    at: 2026-11-21T02:56:47Z
---

# Guard unsupported assistant prefills on Claude Messages and enable Fable 5.2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Enable Claude Fable 5.2 for Messages streaming, structured output and
ordinary function tools. A conversation can continue after a tool call with
its signed thinking history intact. A caller who ends a request with an
assistant prefill gets actionable local feedback on a model that rejects
that pattern. A prefill is a partial assistant answer that the caller puts
at the very end of the request for the model to complete.


## Progress

- [ ] Carry a catalog-owned prefill capability to the Messages request gate
  and prove affected requests fail locally. Preserve prefill on models with
  documented support and preserve ordinary assistant turns in history.
- [ ] Curate Fable 5.2 with explicit thinking, forced-tool, fast mode and
  pricing facts. Validate streamed terminal handling, signed tool replay,
  billing and evidence using the registered adapter.
- [ ] Pass focused live Fable 5.2 text and tool acceptance and record what
  the account and endpoint actually returned.


## Surprises & Discoveries

The 2026-11-20 audit traced a `Context` ending in a nonempty assistant text
message through `mapRequest`. Baikai maps that message to an assistant role
and sends the request. Anthropic documents an HTTP 400 for this pattern on
Fable 5.2 and Fable 5.1, so the existing Fable 5.1 binding already exposes the
failure. Haiku 5.5's published migration guide also documents the restriction.
Confirm the permitted model set by checking each official migration guide
before changing curations. [Fable 5.2 migration](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide)
[Haiku 5.5 migration](https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide)

On the pinned Claude SDK, `Baikai.Provider.Claude.Internal.Stream` already
reads refusal categories and attaches them to the terminal error. It retains
empty signed thinking and replays original signatures through a versioned SDK
input block. The adapter merges cumulative updates for fresh input, cache
reads, cache writes and output, and prices the write duration selected by
request shaping. The request and accounting work here can reuse those paths.


## Decision Log

- On 2026-11-20, keep the Fable 5.2 ID out of the include set until its prefill
  guard exists. Apply the same catalog fact to already shipped models with a
  verified restriction so callers keep their bindings and get the failure
  before network dispatch.


## Outcomes & Retrospective

The model audit is complete. The request guard and catalog entry remain open.


## Context and Orientation

Anthropic released `claude-fable-5-2` on 2026-11-09 for the Messages API.
It accepts text and images, returns text, and publishes a 1,000,000-token
context and a 128,000-token output cap. Adaptive thinking is always on.
Omitted effort defaults to high. It accepts low, medium, high, xhigh and max.
Manual budget and disabled thinking are rejected. Sampling fields must be
omitted, and client function tools accept automatic or no tool choice.
Forced named and required choices fail. Small output budgets can be consumed
entirely by thinking. Structured output uses the existing
`output_config.format` route, subject to Anthropic's account restrictions
for customer-managed encryption keys. Calls require an eligible workspace
with the documented retention policy. Sources verified 2026-11-20.
[Fable 5.2 overview](https://platform.claude.com/docs/en/models/fable-5-2/overview)
[Messages migration guidance](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide)

`baikai/src/Baikai/Provider/Registry.hs` selects the `AnthropicMessages`
registration from `baikai-claude/src/Baikai/Provider/Claude/Api.hs`.
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` maps the
history and options; `baikai-claude/src/Baikai/Provider/Claude/Shape.hs`
completes JSON shaping for the actual HTTP request. The stream and
completion routes share this preparation path. A normalized tool result is
a user-role message carrying a tool-result block. It follows the assistant
tool turn, so the request ends with the tool result during normal replay.
The existing context helpers in `baikai/src/Baikai/Context.hs` preserve the
prior messages and tool declarations when appending a response and result.
`baikai/src/Baikai/Content.hs` stores signed and redacted reasoning. On
Fable 5.2, edits to earlier messages, system prompts or tools invalidate later
thinking signatures. Replay through the account that produced them and
preserve the earlier prefix. This caller restriction is distinct from the
adapter's duty to preserve unedited history. The provider's beta controls
for dropping blocks are outside this plan.

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md)
puts model-generation rules in generated records. [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md)
separates translated effort and observed usage from preferences.
[ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md)
selects write rates from effective duration and marks unobserved billing.
The already completed [plan 75](75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md)
owns the original forced-choice and signed-thinking wire behavior. Extend
its existing fixtures without changing those contracts.


## Plan of Work

Add a prefill capability to `AnthropicMessagesCompat` in
`baikai/src/Baikai/Compat.hs`. Preserve legacy and custom model behavior
when the field is absent. Carry explicit restrictions in
`baikai/fetch/FetchModelsCore.hs`, `baikai/gen/GenModelsCore.hs` and the
catalog JSON. In `Internal/Request.hs`, check the last effective mapped
message, after dropping artificial empty assistant turns. A final nonempty
assistant message on a restricted binding should return `InvalidRequest`
through the existing preparation error path before credentials or the
transport worker. Verify the exact rule for a last assistant message that
contains a tool request without a result. Respect the existing tool pairing
rules. Test a stripped empty tail after an actual prefill, a preceding
assistant message followed by a user message and a normal tool result.
A synthetic rename with the same compatibility record should still be
rejected. An older permissive model should still send documented prefills.

Curate Fable 5.2 as adaptive, without sampling, forced choice or thinking
off, with fast mode available. Add it to `expectedAnthropicFacts` in
`baikai/test/CatalogSpec.hs`. The standard rates per million input, output,
cache-read, five-minute cache-write and one-hour cache-write tokens are
$8, $40, $0.20, $10 and $16. Fast mode is a separate entitled product
reported by the API, with rates $16, $80, $0.40, $20 and $32. Use the
existing `fastModeCost` and long-write pricing policy. Batch pricing is
separate, and this model has flat standard rates across the full context.
Verify fresh input is exclusive of reads and writes and that usage evidence
distinguishes omitted counters from observed zero. Confirm fast pricing
requires observed speed and check both durations in `PricingPolicySpec`.
[Official pricing](https://platform.claude.com/docs/en/about-claude/pricing)

Extend `baikai-claude/test/FableContractsSpec.hs` and the applicable shape and
usage suites. A fixture should exercise a signed empty thinking block
before the function call. After appending the tool result, inspect the mapped
second request for the same signed block, system prompt, tools and tool-call
ID. Keep refusal, max-token and malformed-tool terminals observable. Add
`fable52-text` and `fable52-tools` to the focused runner in
`baikai-smoke/test/NewModelsSmoke.hs`, `SmokeOptions.hs` and
`SmokeOptionsSpec.hs` alongside its existing cases. Keep the test bounded
with low effort and 4096 output tokens, and record any max-token result before
adjusting a failing case. Document the shipped scope and pricing in
`docs/user/models-and-providers.md` and `CHANGELOG.md`.


## Concrete Steps

Run from the repository root, after adding the facts and fixtures.

```bash
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/baikai-models.XXXXXX")
cabal run baikai-fetch-models -- --out-dir "$candidate_dir"
diff -u baikai/data/models/anthropic.json "$candidate_dir/anthropic.json"
```

Review and copy the Fable entry and verified prefill facts for shipped
entries. Regenerate, then run the offline and selected live gates.

```bash
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
git diff --check
direnv exec . cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case fable52-text'
direnv exec . cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case fable52-tools'
```


## Validation and Acceptance

The registered provider rejects a Fable prefill without starting the driver.
The wire fixture keeps earlier assistant history and sends automatic tool
choice. Forced choice fails locally and thinking-off and sampling requests
follow the documented adjustment rules. The next turn contains the original
signature even when its visible text is empty. The tool call and result
carry the same ID. The accounting fixture reports the correct five-minute
and one-hour prices and labels absent price evidence. The live summaries
both observe `claude-fable-5-2` through `/v1/messages`, show the cost basis,
and record a tool dispatch and follow-up for the tool case. Save redacted
readable output and `baikai.new-model-smoke/1` JSON under
`docs/validation/plan-105/`. If the bounded fixture receives no signed
blocks, a targeted signed-thinking live check remains outstanding. Missing
credentials, workspace access, or retention eligibility leave live acceptance
outstanding. Fast rates and request shaping are covered offline. A live Fast
claim needs a successful entitled test showing observed fast speed.


## Idempotence and Recovery

Until the guard is proven, use a test-only model built from Fable 5.1 with
the new facts where a probe needs one. Preserve existing model bindings
while regenerating the new facts. Retry individual live cases after resolving
the observed error, preserving the first result and any successful cases.


## Interfaces and Dependencies

This plan owns Claude Messages prefill compatibility, local validation and the
Fable 5.2 binding. The existing pricing and transport interfaces suffice.
Mori located the SDK at `mori://shinzui/claude-hs/repos/claude-hs`.
Hackage lists 0.1.0.0 and the upstream `v0.1.0.0` tag resolves to commit
`18a58f2d8a98541bdda7b7e53b0ffd3cee844095` (checked 2026-11-20).
The released types include adaptive thinking, speed, streamed stop details,
and usage updates. The adapter uses their versioned blocks to serialize
thinking replay. A model-ID addition and local prefill gate require no
dependency change. [Hackage claude-hs](https://hackage.haskell.org/package/claude-hs)
