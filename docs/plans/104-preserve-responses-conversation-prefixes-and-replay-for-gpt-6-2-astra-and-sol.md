---
id: 104
slug: preserve-responses-conversation-prefixes-and-replay-for-gpt-6-2-astra-and-sol
title: "Preserve Responses conversation prefixes and replay for GPT-6.2 Astra and Sol"
kind: exec-plan
created_at: 2026-11-21T02:55:14Z
intention: "intention_01m7y0dmj9e24sy65vggbvqpf6"
provenance:
  created_by:
    model: "gpt-6.2-sol"
    harness: "codex-cli"
    at: 2026-11-21T02:55:14Z
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:45:23Z
      mode: "update"
      note: "Specify the replay experiment, persisted wire checks, structured output and exact smoke selection."
    - model: "gpt-6.2-sol"
      harness: "codex-cli"
      at: 2026-11-21T03:53:57Z
      mode: "implement"
      note: "Measure live reasoning removal, preserve Responses output items and enable verified catalog bindings."
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-21T03:45:52Z
      verdict: "approved"
      note: "Revised plan checked against Responses diagnostics, adapter replay, generated catalog routing and smoke selection."
---

# Preserve Responses conversation prefixes and replay for GPT-6.2 Astra and Sol

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Enable GPT-6.2 Astra and Sol for streamed text, structured output, and ordinary
function tools through OpenAI Responses. A Baikai system prompt should stay at
the head of the conversation on every turn. When a tool runs, the next request
should carry the preceding response items and tool result in the form OpenAI
needs to continue reasoning and reuse the prefix.


## Progress

- [x] On 2026-11-20, confirmed the replay defect for both GPT-6.2 models.
  Each projected third request lost one reasoning item with `prefix_mismatch`.
  Both original-item branches retained all submitted reasoning.
  See [baseline results](../validation/plan-104/baseline.md).
- [x] On 2026-11-20, preserved the system prefix and complete output items
  through Responses. Offline persistence and wire checks passed. Both models
  matched the original-item branches with zero removals using both default
  cache options and marked 30-minute retention.
  [Corrected replay results](../validation/plan-104/replay.md)
- [x] On 2026-11-20, generated both Responses bindings with Standard rates.
  All four named cases passed with the expected models and endpoint. Each
  tool case used two requests, dispatched once and included replayable reasoning.
  [Smoke results](../validation/plan-104/smoke.md)


## Surprises & Discoveries

The 2026-11-20 audit found that the original adapter used top-level
`instructions` for a default-cache request with a system prompt. GPT-6.2
places this field after input, outside cache breakpoints. Only a request
for an explicit cache breakpoint originally moved the prompt into input.

The original adapter retained encrypted reasoning in item order and projected
completed messages and function calls to their visible Baikai content. This
discarded the message phase, content part boundaries and original item IDs.
OpenAI's migration guide calls for passing prior output items back in order
when using stateless history.

The live probe needed a reasoning-intensive synthetic prompt. Both models
first emitted only a message and a call at medium effort. At high effort
they emitted reasoning in each tool round. On the third request both models
reported `prefix_mismatch` for the Baikai projection and zero removals for the
original items. The earlier message and call precede the second reasoning
item. The visible answer could succeed even when a reasoning item was removed.


## Decision Log

- On 2026-11-20, defer the generated GPT-6.2 bindings until stable system-prefix
  placement and stateless tool replay are verified. Both models require
  Responses for tool calling, and the same adapter and catalog policy will
  cover both.
- On 2026-11-20, attach original output items to their text and tool-call
  blocks. The existing constructors and visible projections still work.
  The optional persisted field lets Responses verify the block's scope and
  content before forwarding the original item. The decision also keeps the
  item available after a response JSON round trip.


## Outcomes & Retrospective

GPT-6.2 Astra and Sol use the Responses adapter for streamed text, strict JSON
schema output and ordinary function tools. Generated catalog checks pinned both
cache durations and the exclusive 272,000-token tier. The core suite passed
858 tests, the OpenAI suite passed 349, and the Claude suite passed 475.
The doc-shapes and smoke-options suites passed. The fetch candidate contained upstream catalog formatting
changes. The checked-in update copied only the two verified entries, and
regeneration added just those two bindings.

The live comparison established that a successful tool loop can still lose
reasoning when a prior message or function call changes on the wire. The
third-request comparison exercised reasoning produced after that prefix.
[Baseline results](../validation/plan-104/baseline.md)
[Corrected replay results](../validation/plan-104/replay.md)
[Smoke results](../validation/plan-104/smoke.md)


## Context and Orientation

OpenAI released `gpt-6.2-astra` and `gpt-6.2-sol` on 2026-11-17. Both accept
text and images, generate text, and support reasoning, function tools and
structured output on Responses. Both publish a combined 1,050,000-token
context, a 922,000-token input limit and a 128,000-token output limit. The
existing catalog stores the combined and output limits. Set low through max
(including xhigh) as the supported effort list. The model rejects none, and the
migration guidance maps none and minimal to low. Omit temperature and top-p.
Sources verified 2026-11-20. [Release notes](https://developers.openai.com/api/docs/changelog)
[Astra](https://developers.openai.com/api/docs/models/gpt-6.2-astra)
[Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol)
[Migration guide](https://developers.openai.com/api/docs/guides/latest-model#migration-quickstart)

The `OpenAIResponses` tag in `baikai/src/Baikai/Api.hs` selects the registration
in `baikai-openai/src/Baikai/Provider/OpenAI/Responses.hs` through
`baikai/src/Baikai/Provider/Registry.hs`. The adapter sends `store=false` and
requests `reasoning.encrypted_content`. Its request mapper is
`baikai-openai/src/Baikai/Provider/OpenAI/Responses/Request.hs`. The assembler
and stream modules beside it handle ordered SSE events, refusals, errors and
incomplete output. `Baikai.Context.appendToolResult` appends the Baikai
assistant message and tool result without changing the existing messages or the
tool declarations. `baikai/src/Baikai/Content.hs` carries model-scoped reasoning
items in `ThinkingReplay`; a tool result uses the call ID independently of the
output item's ID. OpenAI documents that changes to previously sent prefixes,
certain model changes, and changes to user or organization can drop reasoning.
The adapter owns the conversation it produces itself. Callers rebuilding past
turns need clear documentation of the provider's prefix rules.
[Keep the prefix unchanged](https://developers.openai.com/api/docs/guides/keep-prefix-unchanged)

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md)
keeps endpoint restrictions and new generation facts in catalog records.
[ADR 0019](../adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md)
requires API/model-scoped, lossless opaque reasoning and protects legacy JSON.
[ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md)
keeps the requested effort, the outbound value and provider observations
distinct. [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md)
uses a complete rate record for each context tier and records estimate reasons
when billing facts are missing. This plan extends the existing Responses
adapter from [plan 74](74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md)
and uses the cache and usage contracts from
[plan 101](101-cache-shared-openai-prompt-prefixes-with-catalog-gated-controls-and-truthful-accounting.md).


## Plan of Work

### Milestone 1. Measure stateless continuation

First, drive the public Responses worker with a test-only model record through
a fixed two-turn function conversation. Use synthetic text, a stable system
prompt and unchanged tools. Implement the probe as an opt-in test in the
`baikai-openai:baikai-openai-test` suite, following the injectable driver in
`baikai-openai/test/ResponsesStreamSpec.hs`. Wrap the live driver to inspect
the outgoing JSON and completed response in memory. Keep the first request
identical for both follow-ups, including the leading developer item (use the
existing marked-prefix path for this comparison), tool definitions, format,
effort, model and credentials. Use the same first response and synthetic tool
result for both branches. Send one follow-up using Baikai's projected history
and one with the original ordered output items substituted into that history.
Keep `store=false` and omit `previous_response_id` throughout.

For each branch compare the shared input prefix, item order, message content
parts and phase if present, IDs, exact argument strings and encrypted item
equality. Match each submitted reasoning ID to any removal reported in the
follow-up terminal response's `input_transformations`. Record only counts,
equality flags, removal reasons and whether the field was present. A
`prefix_mismatch` on the projected branch with a clean original branch
demonstrates a replay defect. A clean result only covers items preceding the
submitted reasoning item. If a projected message or tool call follows the last
reasoning item, extend the probe by one tool round and submit a later reasoning
item whose prefix includes that projection. If both branches fail, diagnose the common request
before choosing a representation. A successful answer alone cannot establish
reasoning retention. For an omitted diagnostic, calibrate with an edited
synthetic prefix using the same reasoning item and verify that the provider
reports its removal. Leave the conclusion open if no reasoning item or
interpretable diagnostic is available. Report cache counters independently
using a stable prefix of at least 1,024 visible input tokens when measuring
reads. [Prefix audit](https://developers.openai.com/api/docs/guides/keep-prefix-unchanged)
[Response fields](https://developers.openai.com/api/reference/resources/responses/methods/create)

### Milestone 2. Preserve and verify the registered adapter's history

Next, give `OpenAIResponsesCompat` in `baikai/src/Baikai/Compat.hs` an explicit
catalog flag or policy for putting a stable system prompt in the first developer
item. Its JSON decoder and default record should preserve the existing behavior
for callers with older catalog records. Teach the fetch renderer and
`baikai/gen/GenModelsCore.hs` to carry it through to generated bindings. In
`Responses/Request.hs`, make placement independent of whether a cache
breakpoint is active and attach the marker to the same developer content part
when requested. In `Responses/Assembler.hs` and `Responses/Request.hs`,
preserve the output item identity, order and required wire fields established by
the first milestone. If additional replay state must cross the public content
boundary, define it in `baikai/src/Baikai/Content.hs` with API/model validation,
backward-compatible JSON and redacted display. Annotate the evidence for the
actual shaped prefix. Verify older reasoning items still replay through their
existing paths. Test ordinary calls and malformed or cross-model continuation
before dispatch, with at least one text-and-tool response and two consecutive
tool rounds. A terminal refusal, incomplete call or provider error should keep
its existing classification and leave any partial function call undispatched.

In `baikai-openai/test/ResponsesStreamSpec.hs`, exercise two successive tool
rounds through stream folding and `appendToolResult`. Compare the third
request's input with the entire earlier input followed by the second output
and its tool result. Include a message with multiple parts, distinct item and
call IDs, noncanonical JSON whitespace in the function arguments and reasoning
after an earlier projected item. Round-trip the assistant history through its
JSON instances before the next request. Reject inconsistent replay metadata
before transport so a caller's edited public arguments cannot silently differ
from the replayed call. Cover absent replay fields in legacy saved histories.
Verify request commitment against the actual body in
`baikai-openai/test/ResponsesEvidenceSpec.hs`. Rerun the live comparison on
each corrected adapter path before enabling either binding.

### Milestone 3. Generate and exercise both catalog bindings

Finally, add the two IDs to `openaiInclude` with explicit Responses compat in
`baikai/fetch/FetchModelsCore.hs`. Its `apiFor` already derives the per-model
Responses override from `CatalogResponsesCompat`. Set modern cache support
for 30m, 12h and explicit breakpoints along with the prefix placement policy.
For Astra the base rates per million
input, output, cache-read and 30-minute cache-write tokens are
$8, $40, $0.40 and $10. For Sol they are $2, $10, $0.10 and $2.50. The standard
12-hour writes are $20 and $5 respectively. Above 272,000 total input tokens,
including reads and writes, double input and cache rates and multiply output
by 1.5 for the whole request. Use `pricingPolicies` in
`baikai/fetch/FetchModelsCore.hs` and exercise both cache durations at and above
the threshold. Use `OpenAI/Internal/Usage.hs` to check that writes and reads are
subsets of input, missing counters remain unobserved, and usage duration
counters can flag contradictions. Batch, Fast and Ultrafast remain separate
service products priced as explicit standard-rate estimates when observed and
unsupported locally. [Astra rates](https://developers.openai.com/api/docs/models/gpt-6.2-astra)
[Sol rates](https://developers.openai.com/api/docs/models/gpt-6.2-sol)
[Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)

Update `baikai-smoke/test/NewModelsSmoke.hs`, `SmokeOptions.hs` and
`SmokeOptionsSpec.hs` under the same test directory with the case names below.
Associate each selector with its generated model and tool-or-text case in
`SmokeOptions.hs` so the runner and offline tests use the same definitions.
Verify each new selector resolves to exactly one expected model, case kind and
OpenAI credential group. Fail a named run that selects zero cases. Give both
new tool cases a stable nonempty system prompt. Use each new text case to
request a strict JSON schema requiring an `answer` string with value `pong`,
and parse and check the final streamed text. Check the corresponding generated
model's `text.format` request in `baikai-openai/test/ResponsesSpec.hs`.
Update `docs/user/models-and-providers.md` and `CHANGELOG.md` after the
catalog, adapter and tests agree.


## Concrete Steps

Run from the repository root. For milestone 1, add gated Tasty cases named
`plan104-probe-astra` and `plan104-probe-sol`. Enable network access in those
cases only when the probe environment switch is set, require an OpenAI
credential in that mode and bound each request to 120 seconds and 4,096 output
tokens. After adding the cases, select one model per invocation, for example

```bash
direnv exec . env BAIKAI_PLAN104_PROBE=1 cabal test baikai-openai:baikai-openai-test \
  --test-show-details=direct --test-options='-p plan104-probe-astra'
```

Expect one executed probe with separate results for each branch. Repeat with
`plan104-probe-sol` and save the content-free summaries. The baseline probe
in commit `2847120` uses the marked-prefix path. The corrected probe runs with
default cache options. Set `BAIKAI_PLAN104_PROBE_CACHE=marked` along with
`BAIKAI_PLAN104_PROBE=1` to repeat it with the explicit 30-minute breakpoint.
Once the model cases and compatibility tests exist, build and verify the
catalog and the adapter with these commands.

```bash
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/baikai-models.XXXXXX")
cabal run baikai-fetch-models -- --provider openai --out-dir "$candidate_dir"
diff -u baikai/data/models/openai.json "$candidate_dir/openai.json"
```

Review the candidate and copy the two verified entries into the OpenAI JSON.
The diff should show both IDs selecting Responses with explicit compatibility
and pricing, and leave other bindings intact. Then run:

```bash
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
git diff --check
```

Run each needed paid case with the configured OpenAI credentials. Rerun only
the selected failing case after diagnosis.

```bash
set -e
for case_name in astra62-text astra62-tools sol62-text sol62-tools; do
  direnv exec . cabal test baikai-smoke:baikai-smoke \
    --test-show-details=direct --test-options="--new-models --require-keys --case $case_name"
done
```


## Validation and Acceptance

A request with default cache options with a nonempty system prompt serializes the developer item
first and omits top-level `instructions`; a cache-marked request keeps its
marker on that same first item. Apply those assertions to both new models.
Verify a legacy record without the new flag still emits top-level instructions under default options,
and an absent prompt creates no developer item. The recorded wire shows the
same prefix on both calls. Sampling is omitted with adjustment evidence.
None and minimal become low with adjustment evidence and are refused under strict evidence.
A streamed function call uses a matching call ID for its result, losslessly
replays necessary output items in the original order and receives the expected
synthetic answer on the next call. Usage tests show $10/$20 and $2.50/$5
short-context short/long writes, the exclusive tier boundary and explicit
missing usage. Live summaries identify the exact model, endpoint and cost
basis. Each named summary must contain exactly one result with the expected model
and case, `ran=true` and `status=passed`. Text cases must return the
schema-conforming answer. Tool cases must show at least two calls, one
dispatch and the synthetic result. If no reasoning
block arrives, run a reasoning-bearing selected case before closing replay
acceptance. Save redacted readable output and `baikai.new-model-smoke/1` JSON
under `docs/validation/plan-104/`. A skipped or uncredentialed case leaves
the corresponding acceptance outstanding.


## Idempotence and Recovery

Use test-only model records for the first two milestones. Generate the real
bindings locally for milestone 3 and commit them after its checks pass. Regeneration uses the checked-in JSON and can be repeated. Save each
live result separately, so retrying a failed account or protocol case keeps the
evidence from successful paid calls.


## Interfaces and Dependencies

This plan owns the Responses-specific request and replay extension as well as
its generated facts. A shared content or evidence change must preserve the
existing Claude Messages, Chat Completions and persisted JSON contracts.
Mori located the Responses types at
`mori://MercuryTechnologies/openai/packages/openai`. Hackage listed 2.5.4 as
the current release on 2026-11-20, and its upstream repository advertised no
matching release tag. The adapter already adds raw JSON request fields and
decodes raw SSE frames, so no SDK version change is required for the known
prefix change. Check the released source and upstream tags again if the
probe exposes a new dependency requirement.
[Hackage openai](https://hackage.haskell.org/package/openai)

Revision (2026-11-20). The review added a controlled comparison with provider
removal diagnostics, a persisted multi-round wire check and model-specific
smoke assertions so successful requests can demonstrate each promised behavior.

Revision (2026-11-20). Implementation preserved complete text and function
items after the baseline confirmed the prefix change. The smoke selectors now
share their model mapping with the runner, and the GPT-6.2 tool cases use high
effort and a reasoning-intensive prompt to verify continuation on the generated
bindings.
