---
id: 75
slug: enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts
title: "Enforce Claude Fable 5.1 tool-choice and thinking-history contracts"
kind: exec-plan
created_at: 2026-09-07T23:27:02Z
intention: "intention_01m1z342veew8adsnnxnhm3vkj"
master_plan: "docs/masterplans/12-support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers.md"
---

# Enforce Claude Fable 5.1 tool-choice and thinking-history contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Claude Fable 5.1 requests with forced tool choice will fail locally with a clear correction, while normal automatic tool loops preserve signed thinking across turns, even when its visible text is empty. Applications can distinguish unsupported configuration from a provider network failure and know which history edits are unsafe.


## Progress


No implementation started.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-07: Reject required/specific tool choice on unsupported generations; never silently weaken a forced request to auto. Allow auto and none.

2026-09-07: Preserve append-only history and opaque signatures through Baikai-owned operations. Do not create a conversation store or pretend a stateless adapter can detect every edit made by callers. Caller-owned edits remain documented responsibilities.


## Outcomes & Retrospective


To be filled during implementation.


## Context and Orientation


baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs maps required to Anthropic any and a named choice to tool, without a generation guard. Its computeThinking already sends adaptive for adaptive models and omits thinking when unset, which is acceptable for always-on models. Its assistantContentToBlock retains signed thinking even with empty text; the stream assembler in baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs collects signatures. These existing good behaviors need end-to-end regression coverage, not speculative rewrites.

Anthropic's 2026-09-07 documentation states Fable 5.1 rejects any/tool forced choices, accepts auto/none, and always uses adaptive thinking. Omitted thinking is allowed; enabled budget and disabled shapes are rejected. It returns thinking with display omitted by default. Editing earlier turns invalidates later thinking blocks, and earlier models cannot consume Fable 5.1 reasoning state. Source: https://platform.claude.com/docs/en/models/fable-5-1/whats-new-fable-5-1. Passing immutable history and provider blocks intact is the default supported workflow.

Generation facts are in AnthropicGenerationFacts and anthropicInclude in baikai/fetch/FetchModelsCore.hs, persisted in baikai/data/models/anthropic.json and generated into Model.compat by baikai/gen/GenModelsCore.hs. [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) prohibits model-ID guesses in adapters. [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) prohibits describing always-on thinking as observed merely because docs promise it. [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) keeps translation evidence beside shaping.

The repository already plans thinking summaries in docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md, fast mode in docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md, and refusal/fallback behavior in docs/plans/72-carry-the-refusal-category-into-the-error-and-settle-server-side-fallbacks.md. Those retain ownership. The current claude dependency is ^>=1.5; this child requires no SDK bump. Source is discoverable through mori://MercuryTechnologies/claude/packages/claude. No cross-repository ADR applies.


## Plan of Work


### Milestone 1: Declare forced-tool capability and validate requests


Add supportsForcedToolChoice to AnthropicMessagesCompat in baikai/src/Baikai/Compat.hs with a backwards-compatible default for hand-rolled models. Carry it through AnthropicGenerationFacts, the fetcher renderer, generator parser and renderer, and the JSON catalog. Verify the flag for every curated generation rather than inferring all adaptive models behave alike. Fable 5.1 must be False; record a dated source. Update expectedAnthropicFacts in baikai/test/CatalogSpec.hs and the provider's pinned table in baikai-claude/test/ThinkingSpec.hs.

In mapRequest or its shared preparation path, reject ToolChoiceRequired and ToolChoiceSpecific when the flag is false, before creating a network worker. Use InvalidRequest with a message naming auto or none as supported alternatives. Preserve existing tool-choice behavior for supporting models and Shape.injectToolChoiceNone. A fake transport proves zero requests are sent for rejected combinations and both complete and streaming return the normal error protocol.


### Milestone 2: Preserve thinking through complete tool conversations


Add fixtures in baikai-claude/test for empty signed thinking, visible summarized thinking, redacted blocks and multiple consecutive tool rounds. Drive the raw stream assembler, responseMessage, baikai/src/Baikai/Context.hs helpers and runToolLoop in baikai/src/Baikai/Provider/Registry.hs. Inspect the next request and assert unchanged signature, payload, block order and prior-message prefix. Test tool results interleaved with reasoning rather than a synthetic text-only second turn.

If these tests expose loss in mapping, fix the responsible mapping only. Never use nonempty summary text as the condition for retaining signed state. Do not request summarized display as a workaround: that feature belongs to the existing summary plan. If the Responses child has added provider-scoped replay metadata, keep its default absent for Claude and reject foreign opaque state rather than forwarding it as a Claude signature.

Preserve thinking behavior for unset effort and low/medium/high/xhigh/max; minimal retains the existing documented low mapping. A low maxTokens request must not cause an illegal budget or disabled-thinking shape on Fable. Describe unset effort as no caller preference, not proof that provider reasoning was off.


### Milestone 3: Document history boundaries and coordinate related plans


Update docs/user/models-and-providers.md, docs/user/tools.md and docs/user/streaming.md with the precise automatic-tool workflow and the limits of stateless history validation. Baikai preserves its own append operations; callers who truncate, rewrite system/tool definitions or switch models must follow the provider's migration policy. Explain that a provider's rejection remains a classified error and Baikai does not repair or retry history automatically.

Add a short integration note to the existing summary plan requiring that its empty-summary handling preserve opaque signed blocks. Keep its intention and parent unchanged. Update the Unreleased changelog and ADR 0009 when the new capability becomes implemented. No beta conversation-control API, mid-turn effort API, fast-mode option or fallback loop is introduced here.


## Concrete Steps


From the repository root:

```bash
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-claude:baikai-claude-test
cabal test baikai-smoke:doc-shapes
git diff --check
```

Run focused tests through the same suites' Tasty pattern option during development. Expected results are exact preservation assertions passing, rejected requests making zero transport calls, and catalog regeneration producing identical bytes. The later integration plan adds the keyed Fable smoke cases.


## Validation and Acceptance


Both forced choices fail before dispatch for Fable, auto/none serialize correctly, and a renamed fixture with identical compat gives identical decisions. Two consecutive tool turns preserve signed empty and redacted thinking. Neither omitted caller effort nor an empty summary is asserted to mean no model reasoning. Older catalog entries retain verified behavior. Test both successful completion and partial/error paths so a cleanup rewrite cannot discard signed state silently.


## Idempotence and Recovery


All fixture checks are offline and repeatable. Keep new compat fields, generated JSON/module and pinned tests together. Read current schemas before editing because plans 69, 71 and the new capability/pricing plans may have extended them. If an upstream history behavior differs, capture the redacted response and revise the plan rather than dropping thinking to make the test pass.


## Interfaces and Dependencies


This plan owns Anthropic forced-choice validation and replay regression tests. It has no hard dependency on the OpenAI work. There is an integration dependency with the Responses child on shared Content serialization and with plans 69/71 on AnthropicGenerationFacts. It preserves the public ApiProvider interface and current SDK bounds. If dependencies need changing, use Mori before reading APIs and verify Hackage and upstream tags before selecting a version.

Commits carry this file's ExecPlan trailer, the parent MasterPlan trailer and intention intention_01m1z342veew8adsnnxnhm3vkj.
