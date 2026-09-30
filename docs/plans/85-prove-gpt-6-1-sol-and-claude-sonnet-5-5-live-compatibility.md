---
id: 85
slug: prove-gpt-6-1-sol-and-claude-sonnet-5-5-live-compatibility
title: "Prove GPT-6.1 Sol and Claude Sonnet 5.5 live compatibility"
kind: exec-plan
created_at: 2026-09-30T04:37:11Z
intention: "intention_01m3r9m6rvejer0pbabq4kfx4q"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-30T04:37:11Z
---

# Prove GPT-6.1 Sol and Claude Sonnet 5.5 live compatibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-09-29, the catalog gained two bindings: `openai_gpt_6_1_sol`, which dispatches to
OpenAI's Responses endpoint, and `anthropic_claude_sonnet_5_5`, which dispatches to
Anthropic's Messages endpoint. Their request-shaping facts and prices came from the official
model pages, and the offline suites pass. A catalog build cannot show that an account can call
either model, or that a real function-tool conversation completes on the selected endpoint.
This plan closes that gap.

After this plan, a maintainer can run four named, bounded, paid cases. Each case sends one
short text request or one deterministic two-call tool conversation. Its dated, redacted JSON
record names the requested and observed model, the endpoint reached, the tool-dispatch count,
and the cost basis. The user guide can then say that both models passed live acceptance,
instead of saying that no live check has been run.


## Progress

- [ ] Offline: `gpt-6.1-sol` joins the Responses binding checks and `claude-sonnet-5-5` joins
  the Opus 5.5 forced-tool and signed-replay contract checks. Four new smoke cases are
  selectable, and the prescribed offline gate passes without network access.
- [ ] Live: `sol61-text`, `sol61-tools`, `sonnet55-text`, and `sonnet55-tools` pass with
  `--require-keys`. The redacted record is preserved under `docs/validation/plan-85/`.
- [ ] Documentation: `docs/user/models-and-providers.md` and the Unreleased changelog entry
  state the observed live result and the fourteen-case selector list.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Extend the existing `--new-models` smoke mode rather than adding a new runner, and
  keep its `baikai.new-model-smoke/1` output shape.
  Rationale: The mode already has credential preflight, a bounded tool conversation,
  redaction, and the evidence format that plans 77 and 82 used. Reusing it keeps evidence
  comparable across bindings.
  Date: 2026-09-29

- Decision: Run only the four new cases live, selecting each with `--case`, rather than the
  full fourteen-case sweep.
  Rationale: The ten existing cases passed on 2026-09-23. Rerunning them adds cost and proves
  nothing about the new bindings.
  Date: 2026-09-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Baikai is a Haskell library for calling large-language-model providers. A *binding* is a
ready-made `Model` value in `baikai/src/Baikai/Models/Generated.hs`. That file is generated
from JSON under `baikai/data/models/` by `cabal run baikai-gen-models`; never edit it by hand.
Each binding carries an `api` tag that selects a provider handler. For a binding, the tag
`OpenAIResponses` selects the handler in `baikai-openai/src/Baikai/Provider/OpenAI/Responses.hs`,
which posts to `/v1/responses`. The tag `AnthropicMessages` selects
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, which posts to `/v1/messages`. Each binding
also carries a compatibility record (`compat`) holding endpoint facts, such as which reasoning
efforts are accepted or whether forced tool choice is allowed.

The two bindings this plan proves were added on 2026-09-29 and use the following facts.

`openai_gpt_6_1_sol` uses `OpenAIResponses`. Its compatibility record accepts efforts low
through max, omits sampling parameters, and uses `prompt_cache_options` (30-minute TTL) instead
of long cache retention. These facts match GPT-6 Astra's and were verified on 2026-09-29 against
https://developers.openai.com/api/docs/models/gpt-6.1-sol and
https://developers.openai.com/api/docs/guides/latest-model. Those pages say "Use the Responses
API for tool calling. Chat Completions is supported without tool calling", and "The `none` and
`minimal` reasoning efforts are not supported." Standard prices are $2 input, $0.10 cached
input, $2.50 cache write, and $10 output per million tokens. Above 272,000 total input tokens,
the whole request is priced at $4/$0.20/$5/$15 in the same order.

`anthropic_claude_sonnet_5_5` uses `AnthropicMessages`. Its record has adaptive thinking style
and no sampling parameters, rejects forced tool choice, and has no fast mode. These facts were
verified on 2026-09-29 against
https://platform.claude.com/docs/en/models/sonnet-5-5/whats-new-sonnet-5-5 and
https://platform.claude.com/docs/en/build-with-claude/thinking. Thinking is on by default at
`high` effort, and display defaults to `omitted`, so thinking blocks arrive with empty text.
Between tool calls, the model may write a *progress update*, a short note returned as its own
signed `thinking` block. Sonnet 5.5 rejects `thinking: {"type": "disabled"}`, which Baikai never
sends. It also rejects `tool_choice` `any` or `tool` with HTTP 400. Sonnet 5.5 thinking blocks
are bound to the model, account, and conversation prefix. Replaying one after editing an earlier
turn returns HTTP 400 on accounts created after 2026-08-31. Standard prices are $2 input, $0.20
cache read, $2.50 five-minute cache write, $4 one-hour cache write, and $10 output per million
tokens. There is no long-context premium.

These are the same route shapes that Claude Opus 5.5 and GPT-6 Sol already passed live in
`docs/plans/82-prove-gpt-6-sol-gpt-6-luna-and-claude-opus-5-5-live-compatibility.md`, whose
record is `docs/validation/plan-82/2026-09-23-complete.json`. No provider code change is
expected. If a live case fails with an observed model response, investigate it as a new
protocol finding before changing either provider.

The focused live runner is `baikai-smoke/test/NewModelsSmoke.hs`. Its `cases` list holds
the bindings, and each binding yields a text case and a tool case, in that order. Case names
and provider routing live in `baikai-smoke/test/SmokeOptions.hs` (`caseNames` and
`caseProvider`). `baikai-smoke/test/SmokeOptionsSpec.hs` pins them. The runner reads the
`OPENAI_KEY` or `OPENAI_API_KEY` credential for OpenAI and `ANTHROPIC_KEY` or
`ANTHROPIC_API_KEY` for Anthropic. It sends optional `ANTHROPIC_WORKSPACE_ID` as the
`anthropic-workspace-id` header on Anthropic calls only. Plan 82 found that header necessary
for a key not scoped to one workspace.

The offline binding checks to extend are these. `baikai-openai/test/ResponsesSpec.hs` has the
test "Sol and Luna catalog bindings retain Responses shaping and replay identity", which loops
over `[openai_gpt_6_sol, openai_gpt_6_luna]`. `baikai-claude/test/FableContractsSpec.hs` has
"Opus 5.5 rejects forced tools and replays signed empty thinking", bound to
`anthropic_claude_opus_5_5`.

Relevant ADRs:
[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) says
wire facts live in the generated catalog record, never in adapter tables keyed by model ID.
This plan therefore adds no model-ID branch.
[ADR 0019](../adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md) scopes
OpenAI reasoning replay to its API and model, which the Responses replay check exercises.
[ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) defines the
pricing policies and cost bases that the smoke summary reports.

This plan is independent of
`docs/plans/86-send-explicit-high-effort-so-claude-opus-5-5-honours-thinkinghigh.md`. The smoke
runner sends `ThinkingLow`, which that plan does not change.


## Plan of Work

Milestone 1 (offline) extends existing checks without touching provider code. In
`baikai-openai/test/ResponsesSpec.hs`, add `openai_gpt_6_1_sol` to the Sol and Luna loop and
its import. Rename the test to mention GPT-6.1 Sol. The existing assertions then prove that the
binding sends `reasoning.effort` `low`, omits `temperature` and `top_p`, and replays its own
reasoning item and `call_id` on the second tool turn. In
`baikai-claude/test/FableContractsSpec.hs`, run the Opus 5.5 test body for both
`anthropic_claude_opus_5_5` and `anthropic_claude_sonnet_5_5`. For example, bind the model from
a `forM_` loop and rename the test "Opus 5.5 and Sonnet 5.5 reject forced tools and replay
signed empty thinking". This proves local rejection of `ToolChoiceRequired` and
`ToolChoiceSpecific`, the exact wire meaning of `auto` and `none`, unchanged `system` and
`tools` across turns, and replay of an empty signed thinking block before the tool call.

In `baikai-smoke/test/NewModelsSmoke.hs`, append `Models.openai_gpt_6_1_sol` and
`Models.anthropic_claude_sonnet_5_5` to `cases`, in that order. In
`baikai-smoke/test/SmokeOptions.hs`, append `"sol61-text", "sol61-tools", "sonnet55-text",
"sonnet55-tools"` to `caseNames`, in that order. The runner pairs names with `cases`
positionally. Add the `sol61-*` names to the OpenAI branch of `caseProvider`, and the
`sonnet55-*` names to the Anthropic branch. `baikai-smoke/test/SmokeOptionsSpec.hs` currently
pins ten cases with this assertion:

```haskell
check "ten unique cases" (length caseNames == 10 && length (filter (`elem` caseNames) ["sol-text", "sol-tools", "luna-text", "luna-tools", "opus55-text", "opus55-tools"]) == 6)
```

Change it to require fourteen unique names that include the four new ones. Also extend the
provider-expectation line in that spec, which currently reads:

```haskell
let expected = if name `elem` ["fable-text", "fable-tools", "opus55-text", "opus55-tools"] then Just "anthropic" else Just "openai"
```

Add `"sonnet55-text"` and `"sonnet55-tools"` to its Anthropic list. Milestone 1 is complete when
the offline gate in Concrete Steps passes.

Milestone 2 (live) runs the four new cases one at a time with `--require-keys`. It then
preserves the redacted summary lines as a dated JSON record in `docs/validation/plan-85/`,
following the shape of `docs/validation/plan-82/2026-09-23-complete.json`. Keep endpoints,
observed models, statuses, call and dispatch counts, and cost bases. Remove request and
response IDs, and never record credentials, the workspace ID, prompts, or opaque reasoning. A
case that returns HTTP 401, or the workspace-selection HTTP 400, observed no model. Record that
case as an account-setup failure and retry it after the account is fixed. It is not a
compatibility result.

Milestone 3 (documentation) updates the September 29 paragraph and the focused-check selector
list in `docs/user/models-and-providers.md`. Replace the "neither has passed a live check yet"
sentence with the observed result and a link to the record. Update the Unreleased `### Added`
entry in `CHANGELOG.md` the same way.


## Concrete Steps

Run all commands from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

The offline gate, which makes no network requests:

```bash
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
```

Each suite should end with a line like the following, and the command should exit 0:

```text
All N tests passed
```

The live cases, one at a time. Each is paid. Set `ANTHROPIC_WORKSPACE_ID` only if the Anthropic
key is not scoped to one workspace.

```bash
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case sol61-text'
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case sol61-tools'
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case sonnet55-text'
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case sonnet55-tools'
```

Each run prints a readable stderr line, for example:

```text
[baikai-smoke] gpt-6.1-sol tools: passed (...)
```

It also prints one JSON line whose `schema` is `baikai.new-model-smoke/1`. Save each run's full
output separately before combining the results.


## Validation and Acceptance

Offline acceptance requires the gate above to pass after the edits. The renamed ResponsesSpec
and FableContractsSpec tests must now cover `gpt-6.1-sol` and `claude-sonnet-5-5`. `smoke-options`
must accept `--case sonnet55-tools`, require only Anthropic credentials for that case, and reject
an unknown case name.

Live acceptance requires all four cases to report `passed` with `--require-keys`. For each
case, the observed model must equal the requested model or a documented snapshot of it. The
endpoint must be `/v1/responses` for `sol61-*` and `/v1/messages` for `sonnet55-*`. Each tool
case must use exactly two model calls and one dispatcher invocation, and its final answer must
contain the fixed timestamp the runner checks. The cost basis must be the standard token-rate
basis. A skipped case, a missing key, an HTTP 401, or the workspace-selection HTTP 400 leaves
acceptance outstanding. If the Sonnet 5.5 tool case returns HTTP 400 with a thinking or
tool-choice message, record the provider message in Surprises & Discoveries and stop. That
outcome would be a protocol finding for a new plan, not something to work around in the smoke
runner.


## Idempotence and Recovery

The offline edits are additive and can be rerun freely. Each live case is independent and can
be rerun alone with `--case`. Every rerun is a new paid request, so keep earlier outputs rather
than overwriting them. If a run fails before any model is observed, fix credentials or the
workspace header and rerun only that case.


## Interfaces and Dependencies

No library interface changes. The plan uses the generated bindings
`Baikai.Models.Generated.openai_gpt_6_1_sol` and
`Baikai.Models.Generated.anthropic_claude_sonnet_5_5`, the existing
`Baikai.Provider.OpenAI.Responses` and `Baikai.Provider.Claude.Api` handlers, and the
`baikai-smoke` test suite's `SmokeOptions` module. The live check needs an OpenAI key with
GPT-6.1 Sol access and an Anthropic key with Claude Sonnet 5.5 access.
