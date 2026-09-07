---
id: 12
slug: support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers
title: "Support GPT-6 Astra and Claude Fable 5.1 across Baikai providers"
kind: master-plan
created_at: 2026-09-07T23:27:01Z
intention: "intention_01m1z3412hetfakj55t5s9zrsq"
---

# Support GPT-6 Astra and Claude Fable 5.1 across Baikai providers

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Deliver usable direct-API support for GPT-6 Astra and Claude Fable 5.1: correct endpoint selection, accepted request options, streaming tool conversations with preserved reasoning state, and token-cost calculations that disclose incomplete billing knowledge. A maintainer will have a focused live command proving both models actually ran; a catalog regeneration or skipped smoke suite will no longer be described as that proof.

The starting catalog commit aaecbf5 added both IDs and the companion skill commit 96e5aed established a repeatable refresh. Inspection then found that Astra function calling requires OpenAI Responses while the binding chooses Chat Completions. The existing mapper also forwards minimal effort and sampling values Astra rejects. Claude's adaptive/sampling facts are already present, but forced tool choices lack a local guard and the stricter history contract needs full replay tests. OpenAI cache-write counts remain zero and pricing is flat. These are source-level findings, not results of live inference.

The initiative includes a Responses provider for ordinary text/image, function-tool and structured-output workflows; compatibility validation; opaque reasoning continuation; accurate standard token pricing where usage permits it; and focused offline/live evidence. It excludes hosted computer/browser tools, background/async jobs, a Baikai-owned retry or fallback policy, changing application defaults, and publishing packages. Existing Anthropic summary, speed and refusal plans keep their scope.


## Decomposition Strategy


Five children divide work by observable outcome. EP-1 prevents invalid requests and corrects catalog claims quickly. EP-2 delivers the new network protocol and its necessary continuation state. EP-3 independently proves Claude's tool/history behavior. EP-4 makes billing calculations truthful across both transports. EP-5 validates the assembled feature through the public Baikai boundary. Combining pricing and Responses would make one child dominate the initiative and hide whether failures were protocol or accounting problems; creating a separate dependency-upgrade plan would be premature because the currently allowed OpenAI SDK already exposes Responses types.

On 2026-09-07, https://developers.openai.com/api/docs/guides/latest-model explicitly requires Responses for Astra tools, accepts low through max effort and rejects minimal and sampling. https://platform.claude.com/docs/en/models/fable-5-1/whats-new-fable-5-1 states forced tool choices are rejected, adaptive thinking is always on, and earlier-history edits invalidate later thinking blocks. Each child embeds the required facts and implementation acceptance rather than relying on readers to reopen these pages.

The source corpus was found through mori://MercuryTechnologies/openai/packages/openai and mori://MercuryTechnologies/claude/packages/claude. Hackage reports OpenAI 2.5.4, matching the inspected corpus; the upstream tag query returned no tags. Local Responses types have gaps in current effort and usage details and do not provide the streaming HTTP driver. The implementation must recheck released APIs before adding any compatibility workaround; no dependency bump is authorized by an assumption in this plan.

Relevant local decisions are [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md), which puts generation facts in generated compatibility records; [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) and [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md), which distinguish requested, translated and observed data and make adapters own the translation; [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md) and [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md), which govern bounded stream lifetime and centralized transport errors; [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md), which requires real records under strict mode; [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md), which excludes automatic retries; [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), which requires compiled capability examples; and [ADR 0018](../adr/0018-a-provider-stop-reason-with-no-baikai-equivalent-maps-to-the-nearest-truthful-one.md), which requires truthful mappings of unfamiliar provider stops. No cross-repository ADR was needed. Mori declares no profiled ADR bundle for this repository; preserve the filesystem ADR convention.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Make model capabilities and catalog refreshes endpoint-aware | docs/plans/73-make-model-capabilities-and-catalog-refreshes-endpoint-aware.md | None | None | Not Started |
| EP-2 | Add an OpenAI Responses provider with tool and reasoning replay | docs/plans/74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md | EP-1 | None | Not Started |
| EP-3 | Enforce Claude Fable 5.1 tool-choice and thinking-history contracts | docs/plans/75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md | None | EP-1 | Not Started |
| EP-4 | Account for cache writes and context-tier model pricing | docs/plans/76-account-for-cache-writes-and-context-tier-model-pricing.md | None | EP-1 | Not Started |
| EP-5 | Prove new-model compatibility with focused offline and live checks | docs/plans/77-prove-new-model-compatibility-with-focused-offline-and-live-checks.md | EP-1, EP-2, EP-3, EP-4 | None | Not Started |

EP-2 and EP-4 also have an integration dependency: both can develop their independent fixtures, but the combined Responses terminal must use EP-4's usage and cost-basis contract before EP-5 begins.


## Dependency Graph


EP-1 starts immediately and leaves Astra's existing exported binding text-only on Chat Completions with explicit restrictions. EP-2 follows EP-1 because it consumes the capability policy, then moves that binding to Responses only after request mapping, registration and tool replay pass. EP-3 can start independently; EP-1 is a soft dependency to reduce simultaneous changes to catalog schemas. EP-4 can likewise start with core arithmetic and Chat usage fixtures and then integrate the Responses path when EP-2 is available. EP-5 waits for all four so its live success cannot mask missing validation or inaccurate cost claims.

An implementation wave can therefore finish EP-1, work through EP-2 and EP-3 while building EP-4's independent pricing core, reconcile EP-2/EP-4 and then run EP-5. This describes work ordering, not a requirement to spawn agents.

Existing work under docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md remains separate. Its SDK-upgrade child docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md is already complete. Plans 69, 71 and 72 for speed, summarized thinking and refusal/fallback are not hard prerequisites here. Summary-display is unnecessary for replaying a signed empty block; the new Claude plan tests that distinction.


## Integration Points


EP-1 owns new OpenAI capability fields in baikai/src/Baikai/Compat.hs and their fetch/generator representation. EP-3 adds the Anthropic forced-choice field to the same pipeline without reverting other facts. EP-2 owns OpenAIResponses, its compatibility record and optional per-model api override. EP-4 owns optional pricing policy on Model and its serialization. Every schema editor must read the current records and preserve additions already landed. None may edit Generated.hs manually.

EP-2 owns provider-scoped replay state in baikai/src/Baikai/Content.hs, backward JSON decoding and canonical commitment coverage. EP-3 consumes that representation only as needed to prevent foreign state from entering Claude; its own signature behavior stays intact. Existing plan 71 owns visible summary requests and must preserve EP-3's empty-summary replay invariant.

EP-4 owns the usage-normalization availability contract and the one rate-resolution helper used by Chat, Responses and Claude. EP-2 supplies the raw terminal fields, final request cache configuration and actual observed metadata to it. Plan 69's speed cost changes integrate there once, not as a second multiplier. When an endpoint cannot report a billed category, EP-4 requires estimate status and EP-5 reports it.

EP-5 owns smoke selection flags and structured live results. EP-1 corrects the update-models skill now, while EP-5 adds the tested command after it exists. Both must retain official migration-guide and endpoint-specific validation. Capability docs and their compiled twins change together under ADR 0017.

Each child has a separate intention created with mina ci --json at the user's request; the explicit child frontmatter is authoritative, not overwritten by the master intention. Planning and implementation commits use Conventional Commits with MasterPlan, applicable ExecPlan, and the matching Intention trailers. Planned public sum/record changes require PVP review before a later release, but these plans do not cut one.

Durable decisions expected during implementation are separate Responses dispatch, provider-scoped opaque replay, endpoint-specific request validation and honest pricing basis. Update or create filesystem ADRs when those contracts are implemented; do not mark a speculative design as already accepted.


## Progress


No implementation started.


## Surprises & Discoveries


None recorded during implementation.


## Decision Log


2026-09-07: Create five children rather than one broad model-upgrade plan because request acceptance, a new streaming protocol, Claude replay, pricing and live verification each have distinct acceptance tests.

2026-09-07: Preserve the current Astra binding initially with explicit text-only restrictions, then change its default API only when the Responses provider is usable. This avoids removing a just-added export while preventing invalid agent calls.

2026-09-07: Keep existing Anthropic capability plans independent and name shared-file ownership instead of duplicating summary, speed or refusal implementation.

2026-09-07: Create six intentions with mina ci --json, one for this master and one for each child, as explicitly requested. Child IDs remain distinct throughout implementation.


## Outcomes & Retrospective


To be filled during implementation. The initiative is complete only after the documented offline checks pass and both live model cases actually execute successfully; unavailable credentials leave live acceptance outstanding.
