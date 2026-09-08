---
id: 77
slug: prove-new-model-compatibility-with-focused-offline-and-live-checks
title: "Prove new-model compatibility with focused offline and live checks"
kind: exec-plan
created_at: 2026-09-07T23:27:02Z
intention: "intention_01m1z34429evrvs967kqm5q8eh"
master_plan: "docs/masterplans/12-support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers.md"
---

# Prove new-model compatibility with focused offline and live checks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A maintainer can run a focused compatibility command for the two new models, see which cases actually ran, and obtain evidence of a real tool round-trip rather than treating catalog generation or a skipped test as model support. Offline fixtures remain the comprehensive gate; live tests verify the public provider boundary with bounded requests.


## Progress


- [x] Add focused and required-key flags, keeping the ordinary no-argument suite.
- [x] Add bounded text/tool cases, credential-chain resolution, and redacted JSON results.
- [x] Pass the offline provider/documentation gate and option/missing-key checks.
- [x] Add named-case selection for isolated reproduction and exact dispatched endpoint paths.
- [ ] Execute the focused paid run and record dated results for both models.
- [ ] Update reproduction documentation and complete the final master-plan audit.


## Surprises & Discoveries


The focused executable builds successfully. The prerequisite gate passes 708 core,
276 OpenAI, 335 Claude tests, compiled documentation, and nine pure option/credential
checks. An executable-level check removed all four credential environment variables
from its child process: `--new-models` returned exit 0 with four non-executed skips;
adding `--require-keys` returned exit 1 with four non-executed failures and named both
credential alternative groups. Neither check contacted a provider.

2026-09-07 live acceptance: the full required-key command exited 1 before any
request because both Anthropic credential alternatives were absent. OpenAI
credentials were available. Isolated `--case astra-text` passed in one request;
`--case astra-tools` passed in two requests with one dispatcher invocation and an
exact timestamp match. All three responses observed `gpt-6-astra` and standard
token pricing, totaling $0.00355 by local calculation. No reasoning block was
returned, so this run does not establish live encrypted-continuation replay.
Offline replay fixtures remain its proof. Fable live acceptance remains blocked
on a credential being available through its existing chain.

The first text run exposed a missing endpoint path in provider evidence. Responses
and Claude now derive dispatched URLs from the actual normalized client environment
and append their transport's route. Provider regression checks pass (276 OpenAI,
335 Claude), as do doc-shapes. The original text artifact retains its base-only
endpoint; both subsequent tool responses record `/v1/responses`. There was no paid
rerun of the successful text case. Named-case parsing now has 12 passing pure checks.

Redacted, unmodified JSON summaries are preserved in
[the full preflight result](../validation/masterplan-12/2026-09-07-required-credentials.json),
[Astra text](../validation/masterplan-12/2026-09-07-astra-text.json), and
[Astra tools](../validation/masterplan-12/2026-09-07-astra-tools.json).


## Decision Log


2026-09-07: Add a focused new-model mode to the existing smoke executable, with required-key semantics for explicit live validation. Preserve the ordinary keyless skip behavior of the broader smoke suite.

2026-09-07: Use deterministic offline fixtures for pricing thresholds and failure cases; do not spend hundreds of thousands of live tokens to prove arithmetic. Live tests prove access and request compatibility, not exact model internals or billing totals.

2026-09-07: Drive the focused tool loop through `completeRequest` and
`appendToolResult`, retaining every assistant turn and a safe evidence summary for
each call. Bound it to four requests, 4096 output tokens per request, and a 120-second
timeout per request. Require the dispatcher to run and the final answer to contain
the exact fixed timestamp. Do not render raw responses, exceptions, signatures, or
encrypted reasoning. Record structured error categories and HTTP status instead.


## Outcomes & Retrospective


The focused runner, isolated case selection, missing-key contract and reproduction
documentation are implemented. Astra text and deterministic tool use passed live;
Fable live acceptance and the final master-plan audit remain outstanding. The
initiative is not complete. An empty reasoning result is not claimed as a live
encrypted replay test, and local token-cost calculations are not invoice verification.

Validation logs for this increment are `/tmp/baikai-mp12-focused-offline.log` and
`/tmp/baikai-mp12-smoke-build-final.log` (local, uncommitted execution artifacts).


## Context and Orientation


This child has hard dependencies on docs/plans/73-make-model-capabilities-and-catalog-refreshes-endpoint-aware.md, docs/plans/74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md and docs/plans/75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md. It also requires the final pricing integration of docs/plans/76-account-for-cache-writes-and-context-tier-model-pricing.md before its acceptance report is complete. Those plans provide the new route, validation, replay and pricing contracts summarized below.

The smoke executable is the baikai-smoke test suite in baikai-smoke/baikai-smoke.cabal, driven by baikai-smoke/test/Smoke.hs. ToolsSmoke.hs builds a get_time function and calls runToolLoop, but currently hardcodes temperature=0. ThinkingSmoke.hs expects visible thinking in some cases and handles two-turn replay. Blindly adding new IDs to these cases would conflate unsupported sampling, absent default summaries and broken models. The existing smoke suite skips on missing keys; a passing keyless run is not live evidence.

GPT-6 Astra needs Responses for tools, rejects minimal effort and sampling, and has cache/context pricing rules. Fable 5.1 needs auto/none tool choice and preserves signed thinking even when the displayed summary is empty. These facts were verified 2026-09-07 from https://developers.openai.com/api/docs/guides/latest-model and https://platform.claude.com/docs/en/models/fable-5-1/whats-new-fable-5-1.

[ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) prevents a requested model from masquerading as an observation. [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md) requires strict evidence to exist. [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md) requires capability examples to compile through baikai-smoke:doc-shapes. Existing plans 69, 71 and 72 retain fast-mode, summary-display and refusal/fallback ownership; this plan does not make those optional features prerequisites for basic Fable support. No cross-repository ADR applies.


## Plan of Work


### Milestone 1: Add a bounded focused smoke mode


Add --new-models and --require-keys arguments to baikai-smoke/test/Smoke.hs. The first runs only GPT-6 Astra and Fable 5.1 cases; the second exits nonzero with a clear missing-environment-variable message instead of silently skipping. Use the existing credential resolution chain and never print key contents. Register the Responses provider explicitly alongside Claude. Preserve existing no-argument behavior.

Add NewModelsSmoke.hs and register it in the Cabal file. Give each case explicit Options appropriate to the selected model; remove hardcoded temperature from generic tools tests or make it a per-case option. Use low reasoning and a bounded output budget initially (4096 tokens, adjustable once if documented provider minimums require it), an explicit timeout and at most four tool turns. No automatic retry loop or unrelated model suite is run.


### Milestone 2: Exercise useful conversations and evidence


For each model, make a small text request and a deterministic function round-trip where the function returns a unique fixed timestamp. Require that the dispatcher ran and the final answer contains the supplied timestamp; fluent text alone is not a tool-use success. Preserve first-turn assistant content in the follow-up. For Fable, allow an empty visible summary when its signature is retained; for Responses inspect preserved reasoning continuation without printing it. Run low/max request-shaping permutations offline rather than paying for every effort level live.

Record a concise result per case: model requested, endpoint, whether the call ran, success/failure, observed response model when supplied, response/request IDs if safe, tool-turn count and cost-basis classification. Evidence must show the final shaped endpoint and options; an absent observation stays absent. Emit a structured JSON summary as well as readable lines so later release workflows can distinguish passed, skipped and failed.

Add offline tests for the smoke option parsing and missing-key contract without touching real credentials. Keep failure, cancellation, schema-output and unsupported-choice assertions in provider fixtures and run them as the prerequisite gate.


### Milestone 3: Close the claims and document reproduction


Run the offline suites, then the exact focused live command below when credentials are available. If account access or credentials prevent it, mark live acceptance outstanding in the plan and summary; do not mark the initiative complete or call a skipped suite a pass. Record dated redacted evidence and failures in this plan's living sections. Do not commit provider secrets, raw prompts from other sessions or opaque thinking tokens.

Update docs/user/models-and-providers.md and agents/skills/update-models/SKILL.md with the verified command and route-specific scope. Resolve all newly added documentation names in the existing doc-shapes environment, and update capability twins when capability snippets change. Distill established architectural conclusions into docs/adr/ and note any remaining price-estimate limitations. This plan does not publish a release; the release skill handles versioning and distribution separately.


## Concrete Steps


All commands run at the repository root. The first commands are offline and must pass before any paid request.

```bash
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys'
git diff --check
```

The new flags are to be implemented in milestone 1; they do not exist at planning time. API keys come from the existing OPENAI_API_KEY and Anthropic credential chains. With missing required keys the live command must exit nonzero and list names only. With accessible models it must report both executed and passed, with at least one successful real tool round-trip per model.


## Validation and Acceptance


The offline gate covers route dispatch, low/max effort encoding, minimal translation and strict rejection, forced Fable tool-choice rejection, opaque-state replay, streaming cancellation and error protocol, observed versus missing usage, and context-tier arithmetic. The focused live run must actually execute both models and finish the deterministic tool conversations inside the configured budget. Missing keys, model access denial and timeout are never successes. An empty thinking summary alone is not a failure.

Review the final generated catalog and documentation together: Astra selects Responses, Fable uses its explicit Messages facts, older bindings retain their intended routes, and no statement claims a capability merely from a global feature list. The structured result must distinguish verified behavior from remaining account-specific or billing limitations.


## Idempotence and Recovery


Offline checks are repeatable. Every live rerun creates real billable requests, so keep the selection bounded and retry only the failing named case after diagnosing its error. Preserve the result of a failed run rather than overwriting it with a later successful summary. Stop dependent acceptance on missing credentials or account denial and report precisely what remains; elapsed time is not permission or evidence of access.


## Interfaces and Dependencies


This child owns smoke selection/required-key flags, NewModelsSmoke and the result summary schema. It consumes the existing ApiProvider, Model, Options, tool-loop and evidence interfaces from earlier plans, not raw provider SDK calls that bypass Baikai. Each child keeps its own explicit intention; the master tracks their completion and integration.

Commits carry this file's ExecPlan trailer, the parent MasterPlan trailer and intention intention_01m1z34429evrvs967kqm5q8eh.
