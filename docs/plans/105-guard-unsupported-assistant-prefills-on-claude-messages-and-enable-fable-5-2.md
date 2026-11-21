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
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:46:23Z
      verdict: "changes-requested"
      note: "Resolve thinking-dependent prefill rules, adapt conflicting replay fixtures, and prove structured output and signed live continuation."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:48:28Z
      verdict: "approved"
      note: "Rechecked the revised prefill matrix and effective thinking gate, registered-provider fixtures, pricing expectations and live replay criteria."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:49:28Z
      verdict: "changes-requested"
      note: "Check signed-block equality on the actual live follow-up and validate a schema-conforming answer through public completion; document asymmetric 5.1/5.2 replay on rollback."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T04:16:41Z
      verdict: "approved"
      note: "Verified all three follow-up findings against the revised milestones, the Claude live driver seam, and registered completion."
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:47:48Z
      mode: "update"
      note: "Apply review findings to catalog prefill policy, offline wire and pricing fixtures, and observable live signed-tool replay."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T04:16:30Z
      mode: "update"
      note: "Require real follow-up body equality for signed tool turns, decode a public structured completion, and document model rollback."
    - model: "gpt-6.2-sol"
      harness: "codex-cli"
      at: 2026-11-21T04:21:34Z
      mode: "implement"
      note: "Implement and verify catalog prefill policy, Fable 5.2 support and signed tool replay."
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

- [x] On 2026-11-20, carried the catalog prefill policy through all 14 existing
  bindings and proved restricted requests fail before credentials and transport.
  Supported prefills and ordinary history still mapped successfully. The
  refreshed catalog matched exactly. The core and Claude suites passed
  858 and 479 tests, respectively.
- [ ] Curate Fable 5.2 with explicit thinking, forced-tool, fast mode and
  pricing facts. Verify a caller receives the schema-conforming answer through
  registered completion. Validate streamed terminal handling, signed tool replay,
  billing and evidence using the registered adapter.
- [ ] Pass focused live Fable 5.2 text and tool cases, including a successful
  follow-up whose outbound assistant turn contains the same signed blocks in
  order as the tool response. Save redacted evidence.


## Surprises & Discoveries

The 2026-11-20 audit traced a `Context` ending in a nonempty assistant text
message through `mapRequest`. Baikai maps that message to an assistant role
and sends the request. Anthropic documents an HTTP 400 for this pattern on
Fable 5.2 and Fable 5.1, so the existing Fable 5.1 binding already exposes the
failure. Haiku 5.5's published migration guide also documents the restriction.
Anthropic's API error reference places the unconditional cutoff at Claude 4.6.
Its thinking guide also rules out prefills on earlier models while thinking
is enabled. Both restrictions apply to bindings in today's catalog.
[API validation errors](https://platform.claude.com/docs/en/api/errors#prefill-not-supported)
[Thinking and response prefill](https://platform.claude.com/docs/en/build-with-claude/thinking#response-prefill-and-forced-tool-use)
[Fable 5.2 migration](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide)
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
- On 2026-11-20, use an optional catalog policy so shipped 4.5 models can
  enforce their thinking-dependent rule and older serialized bindings can
  retain their existing behavior.


## Outcomes & Retrospective

The prefill guard is complete. Fable 5.2 catalog and live acceptance remain open.


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
for customer-managed encryption keys, where JSON outputs and strict tools are
unavailable. Calls require a workspace with 30-day data retention or express
authorization from Anthropic. Sources verified 2026-11-20.
[Fable 5.2 overview](https://platform.claude.com/docs/en/models/fable-5-2/overview)
[Messages migration guidance](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide)

`baikai/src/Baikai/Provider/Registry.hs` selects the `AnthropicMessages`
registration from `baikai-claude/src/Baikai/Provider/Claude/Api.hs`.
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` maps the
history and options. `baikai-claude/src/Baikai/Provider/Claude/Shape.hs`
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
for dropping blocks are outside this plan. On the direct Claude API, Fable 5.2
can read Fable 5.1 thinking. On rollback, Fable 5.1 can finish a request
after the API drops thinking produced by 5.2. Document this when describing
fallbacks and saved conversations. [Fable migration guide](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide#breaking-changes)

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md)
puts model-generation rules in generated records. [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md)
separates translated effort and observed usage from preferences.
[ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md)
selects write rates from effective duration and marks unobserved billing.
The already completed [plan 75](75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md)
owns the original forced-choice and signed-thinking wire behavior. Extend
its existing fixtures without changing those contracts.


## Plan of Work

### Milestone 1. Reject an unsupported final assistant turn before dispatch

Add an optional prefill policy to `AnthropicMessagesCompat` in
`baikai/src/Baikai/Compat.hs`. An absent field in persisted JSON, custom
bindings or automatic host detection preserves the existing pass-through.
Give every shipped Anthropic row an explicit policy. Haiku 4.5, Opus 4.5
and Sonnet 4.5 allow prefill only with thinking off. Fable 5 and 5.1,
Haiku 5.5, Opus 4.6, 4.7, 4.8, 5 and 5.5, and Sonnet 4.6, 5 and 5.5
reject it for every thinking setting. Fable 5.2 joins the latter group in
milestone 2. Carry the policy from `AnthropicGenerationFacts` and its JSON
renderer in `baikai/fetch/FetchModelsCore.hs` through
`baikai/data/models/anthropic.json`, the parser and renderer in
`baikai/gen/GenModelsCore.hs`, and the generated binding. Pin the catalog
matrix in `baikai/test/CatalogSpec.hs` and update the fetcher's fixture and
expected JSON in `baikai/test/FetchModelsSpec.hs`.

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, examine
the final role of `msgs` after `traverse mapMessage` succeeds and `catMaybes`
drops empty assistant artifacts. For the conditional policy, use the thinking
field produced by `planRequest`. A manual budget enables thinking on 4.5.
An omitted field or an explicit disabled setting permits prefill.
This handles a requested budget that was dropped to fit the output cap.
When the policy rejects an assistant tail, return an actionable message
through the existing `Left` path. Ask for a user turn or a system instruction
for text prefills, and for the matching tool result after a client tool call.
A signed-thinking-only tail also has the assistant role. The adapter's client
tool results map to the user role. Server-tool `pause_turn` continuations
use block types outside this adapter's client tool interface.

Use the injected-driver tests in `baikai-claude/test/FableContractsSpec.hs`
to prove both streaming and blocking completion return `InvalidRequest`
before credentials or driver invocation. Use `ApiKeyEnvChain []` on the
rejected cases so reaching key resolution would produce an authentication
error. Assert the prefill-specific message and zero driver calls. Cover a
final client tool call both before and after appending its result, a signed
thinking-only tail, a renamed restricted model,
a prefill followed by a stripped empty assistant artifact, an empty artifact
after a user turn, and ordinary assistant history followed by a user or tool
result. Pin the 4.5 behavior with thinking on, off and dropped, and the
missing-policy JSON default. The existing summary-visibility test maps a
signed or redacted Fable 5.1 block as the final assistant turn. Append a real
user follow-up before mapping and keep the exact block equality assertion
on the preceding turn. Run the core and Claude suites before enabling 5.2.

### Milestone 2. Enable the binding and prove its wire behavior offline

Curate Fable 5.2 as adaptive, without sampling, forced choice or thinking
off, with fast mode available. Add it to `expectedAnthropicFacts` in
`baikai/test/CatalogSpec.hs` and to `anthropicModels` in
`baikai-claude/test/ThinkingSpec.hs`. Both suites require exact coverage of
the generated catalog. The standard rates per million input, output,
cache-read, five-minute cache-write and one-hour cache-write tokens are
$8, $40, $0.20, $10 and $16. Fast mode has its own rate limit on eligible
usage tiers and doubles each rate to $16, $80, $0.40, $20 and $32. Use the
existing `fastModeCost` and long-write pricing policy. Batch pricing is
separate, and this model has flat standard rates across the full context.
Verify fresh input is exclusive of reads and writes and that usage evidence
distinguishes omitted counters from observed zero. Confirm fast pricing
requires observed speed and check both durations in `baikai/test/PricingPolicySpec.hs`.
For 1,000 writes and zero other tokens the short and long totals are $0.010
and $0.016 at standard speed, or $0.020 and $0.032 at observed fast speed.
With fast requested and speed absent, expect the standard estimate with
`SpeedNotReported`. In `baikai-claude/test/ShapeSpec.hs` capture the
`speed` field for a fast request. Anthropic accepts the adapter's existing
fast-mode beta header on the direct Claude API.
[Official pricing](https://platform.claude.com/docs/en/about-claude/pricing)
[Fast-mode availability and pricing](https://platform.claude.com/docs/en/build-with-claude/fast-mode)
[Fast-mode header compatibility](https://platform.claude.com/docs/en/models/fable-5-2/migration-guide)

Run the existing two-tool-round loopback HTTP fixture in
`baikai-claude/test/FableContractsSpec.hs` for Fable 5.1 and 5.2. Set
the synthetic `message_start.model` to the model under test. Compare the
complete earlier messages, system prompt and tool definitions on the captured
requests, including the empty signed thinking block, the redacted block, and
each tool-use/result ID. Exercise `JsonSchema` with low effort on Fable 5.2
through `completeRequestWith` and a registry containing `claudeMessagesProvider`.
Point the binding at the loopback server and require an object with a single
string field `answer`. Check the captured request's `output_config.format.schema`
and `output_config.effort = "low"`. Have the server stream the JSON text
`{"answer":"pong"}` across two text deltas and finish with `end_turn`. Require
a successful `Stop` response, decode its assembled text, and compare the whole
object with the fixture value.
Use `baikai-claude/test/SseSpec.hs` and the existing stream fixtures to prove
a refusal retains its category, a thinking-only max-token stop yields
`Length`, and incomplete tool arguments never reach the dispatcher.
Document the supported scope and rates in `docs/user/models-and-providers.md`
and `CHANGELOG.md`. In the user guide, explain the encryption-key restriction
on JSON output and the direction-dependent thinking replay on model changes.

### Milestone 3. Verify a live text turn and tool continuation

Add `fable52-text` and `fable52-tools` to `baikai-smoke/test/SmokeOptions.hs`
and the generated model to the corresponding position in
`baikai-smoke/test/NewModelsSmoke.hs`. The runner zips names to model pairs
by position. Check the single selected result and its requested model, and
update the case count and Anthropic credential mapping in
`baikai-smoke/test/SmokeOptionsSpec.hs`. Start both cases with the existing
low effort, 4,096 output tokens and 120-second per-request timeout. Preserve
the four-request tool-loop limit. Add a per-response count of non-redacted
thinking blocks with a nonempty signature to the redacted summary.
`reasoning_blocks` includes redacted blocks and `reasoning_continuation_valid`
is true for an empty list, so neither establishes a signed replay alone.

For the Fable 5.2 tool case, retain the signed blocks from each completed
`ToolUse` response in memory, including their content positions, thinking text
(which may be empty), and signatures. Use an isolated registry for this case
with the Claude provider's stream and completion both backed by
`claudeMessagesStreamWith` and a test wrapper around `liveSseDriver`. At the
driver boundary, compare the expected blocks with the corresponding assistant
turn in the shaped `requestBody` immediately before its matching tool result.
Forward that same call to the live driver. Record only the block count and
equality result for the comparison. Fail the case on any omitted, reordered,
extra or changed signed block. Exercise the comparison offline with a dropped
block and a changed signature so an always-true result fails the test.


## Concrete Steps

Run from the repository root, after adding the facts and fixtures.

```bash
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/baikai-models.XXXXXX")
cabal run baikai-fetch-models -- --provider anthropic --out-dir "$candidate_dir"
diff -u baikai/data/models/anthropic.json "$candidate_dir/anthropic.json"
```

The diff should show the existing rows' prefill policies in milestone 1 and
the Fable row in milestone 2. Copy only the reviewed changes into the catalog.
Regenerate `baikai/src/Baikai/Models/Generated.hs` at each milestone. The
first two test suites exercise milestone 1. Run all four before live calls.

```bash
cabal run baikai-gen-models
env -u OPENAI_KEY -u OPENAI_API_KEY TASTY_NUM_THREADS=1 cabal test baikai:baikai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
git diff --check
direnv exec . cabal test baikai-smoke:baikai-smoke --test-show-details=direct --test-options='--new-models --require-keys --case fable52-text'
direnv exec . cabal test baikai-smoke:baikai-smoke --test-show-details=direct --test-options='--new-models --require-keys --case fable52-tools'
```


## Validation and Acceptance

The registered provider rejects a Fable prefill without starting the driver.
The wire fixture keeps earlier assistant history and sends automatic tool
choice. Required and named choices fail locally. On Fable 5.2, requesting
thinking off sends adaptive thinking at low effort and records `EffortClamped`.
An omitted preference leaves effort unset. A temperature preference is
dropped and recorded as `SamplingDroppedUnsupportedModel`. The next turn contains the original
signature even when its visible text is empty. The tool call and result
carry the same ID. The structured-output fixture checks both the outbound
schema and the caller's decoded answer object. The accounting fixture reports the correct five-minute
and one-hour prices and labels absent price evidence. The live summaries
both observe `claude-fable-5-2` through `/v1/messages`, show the cost basis,
and record a tool dispatch and follow-up for the tool case. Save redacted
readable output and `baikai.new-model-smoke/1` JSON under
`docs/validation/plan-105/`, with a separate dated result per attempt. With
`ANTHROPIC_KEY` or `ANTHROPIC_API_KEY` available, each selection must produce
exactly one result with `ran = true`, `status = "passed"` and the observed
model and endpoint on each response. For tools, require a positive signed
block count on a `ToolUse` response, a matching ordered-block comparison on
its actual follow-up request, successful completion and the final test timestamp. If low effort yields no signed block on a replayed
turn, retain that run and repeat only the tool case with higher effort in
a bounded targeted fixture. Record the actual settings in the report. A
thinking block on the final answer alone leaves live replay open. Missing
credentials, workspace access, or retention eligibility leave live acceptance
outstanding. Fast rates and request shaping are covered offline. A live Fast
claim needs a successful request showing observed fast speed.


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

Revision 2026-11-20. Review resolved the prefill policy for the shipped
catalog and specified how the existing wire fixtures and live reports can
prove structured output, signed replay and fast pricing.

Revision 2026-11-20. The follow-up review added an outbound signed-block
comparison, a caller-visible structured completion and the rollback behavior
for saved Fable 5.2 conversations.
