---
id: 101
slug: cache-shared-openai-prompt-prefixes-with-catalog-gated-controls-and-truthful-accounting
title: "Cache shared OpenAI prompt prefixes with catalog-gated controls and truthful accounting"
kind: exec-plan
intention: "intention_01m5srppfjevrte2578x034wxq"
created_at: 2026-10-25T14:50:02Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-25T14:50:02Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T16:13:40Z
      mode: "update"
      note: "Record successful Claude short- and long-retention live verification; OpenAI implementation remains planned."
---

# Cache shared OpenAI prompt prefixes with catalog-gated controls and truthful accounting


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/PLANS.md`; record implementation friction using the companion `FRICTION.md` workflow. The current deliverable is this plan, not an implementation of its milestones.


## Purpose / Big Picture


A caller using `Options.cacheRetention` and a large, stable `Context.systemPrompt` should be able to reuse that prefix across fresh OpenAI conversations whose first user messages differ. Baikai should place the appropriate breakpoint itself, as its Claude adapter now does, while preserving provider-neutral requests and reporting the actual cache usage and corresponding costs.

Support both native OpenAI Responses and OpenAI Chat Completions when the selected model and endpoint declare the required capabilities. Keep older OpenAI models and compatible third-party hosts working. Success is a captured request with the expected shared-prefix marker plus a credential-gated pair of real calls where the first writes and the second reads the prefix. Provider acceptance and a measured hit are separate from successful offline serialization tests.


## Progress


- [ ] Model and endpoint cache capabilities survive legacy decoding, catalog refresh and regeneration, with documented evidence for supported retention values.
- [ ] Responses requests preserve instructions exactly once and cache their stable prefix; public completion and streaming paths use the same prepared request.
- [ ] Chat requests place the native breakpoint only on supported models and preserve the existing OpenRouter/compatible-host behavior.
- [ ] Effective retention drives accurate write pricing and privacy-preserving request evidence, including partial and repeated usage snapshots.
- [ ] Focused live checks, documentation, capability evidence and regression suites demonstrate the supported contract and disclose unverified combinations.

No OpenAI implementation has started. The related Claude fix was implemented separately during review of issue #2 and PR #3 and shipped to the repository in commit `7eb0d56`. Its provider suite passed 473 tests. On 2026-10-25, the focused live `CacheSmoke.runCacheCases` check passed against Claude Sonnet 4.6 with both Short and Long retention: each case wrote 5,084 tokens, read 5,084 on an identical request, then read 5,072 on a fresh conversation with a different first question. All six calls completed successfully and reported nonzero cache costs. This verifies shared-prefix reuse; it does not claim invoice reconciliation or validate OpenAI behavior.


## Surprises & Discoveries


(None yet.)


## Decision Log


On 2026-10-25, keep `Options.cacheRetention` as the caller-facing control and let adapters own breakpoint placement. Do not introduce a vendor JSON escape hatch or make applications rewrite `Context` themselves. Keep the implicit conversation cache enabled alongside the stable-prefix marker; switching to explicit-only caching would change existing conversation behavior.

On 2026-10-25, capability facts must be explicit per model and endpoint, following ADR 0009. Do not recognize model generations by prefixes inside request builders. The existing `supportsPromptCacheOptions` flag alone does not establish explicit-breakpoint support, accepted long TTLs, or legacy short-retention support.

On 2026-10-25, defer public cache keys, per-message placement, explicit-only mode, prewarming and mixed TTLs. These are distinct caller controls and are unnecessary for the shared-system-prefix fix. In particular, Baikai must not derive a cache identity from tenant data, prompts or unrelated `Options.metadata`. A future cache-key feature needs its own option and privacy contract.

On 2026-10-25, long retention is enabled only with verified endpoint/model support and matching prices. Conflicting provider documentation must not become an unconditional `12h` mapping. Unsupported explicit native OpenAI preferences are refused before network dispatch, consistent with the existing Responses behavior. Preserve the existing Anthropic-style compatibility downgrade separately.


## Outcomes & Retrospective


(To be filled during implementation.)


## Context and Orientation


A breakpoint is a boundary after which a provider can save the preceding prompt for reuse. Retention is how long that saved state is eligible for reuse; a TTL is the provider's duration setting. Baikai's `CacheRetentionShort` and `CacheRetentionLong` are coarse preferences, not universal time durations. Neither a requested preference nor a sent marker proves that a cache hit occurred.

The current code is a multi-package Haskell workspace. `baikai/src/Baikai/Options.hs` contains the call-time preference and `baikai/src/Baikai/Context.hs` contains the optional single text system prompt. `baikai/src/Baikai/Compat.hs` declares separate Chat and Responses compatibility records. `baikai/src/Baikai/Model.hs` retrieves the selected record. Changes to exported compatibility records require PVP major-release review even when old JSON remains readable; do not publish or bump versions as an incidental planning step.

`baikai-openai/src/Baikai/Provider/OpenAI/Responses/Request.hs` builds a `PreparedRequest` containing the exact JSON body and reasoning translation. It currently sends `Context.systemPrompt` as top-level `instructions`. Its `cacheFields` maps Short to `prompt_cache_options.ttl = 30m` when `supportsPromptCacheOptions` is true, otherwise to legacy `prompt_cache_retention = in_memory`. It refuses Long on the modern-options path and uses `24h` on legacy models declaring long support. That legacy short mapping must also be capability-checked: a model accepting only `24h` must not receive `in_memory`.

`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` shapes Chat requests after SDK encoding. Its `injectCacheControl` implements only Anthropic-style controls selected by `cacheControlFormat`, such as OpenRouter. It does not implement OpenAI native retention or explicit breakpoints. `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs` maps neutral messages and supplies the initial system message. Preserve its choice of instruction role unless a separately verified endpoint requirement necessitates changing it.

`baikai/fetch/FetchModelsCore.hs`, `baikai/data/models/openai.json`, `baikai/gen/GenModelsCore.hs`, and `baikai/src/Baikai/Models/Generated.hs` form the curated-data-to-generated-code path. Do not hand-edit Generated.hs. `baikai/test/CatalogSpec.hs` checks catalog facts and the refresh/generation path. Older persisted compatibility records currently use generic JSON decoding; new fields need explicit backward-compatible defaults rather than becoming newly required JSON keys.

`baikai-openai/src/Baikai/Provider/OpenAI/Internal/Usage.hs` normalizes inclusive input totals into disjoint ordinary input, cache reads and cache writes. It also merges cumulative snapshots, retaining missing fields and replacing reported ones. Both `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs` and `baikai-openai/src/Baikai/Provider/OpenAI/Responses/Stream.hs` currently call `computeCostForService Nothing Nothing`; they do not carry an effective cache duration into pricing. `baikai/src/Baikai/Cost/Pricing.hs` already supports duration-aware rates, including tier-specific long write prices. Preserve this shared arithmetic.

`baikai/src/Baikai/Evidence.hs` hashes the actual request separately from its configuration projection. The projection is an allow-list, currently omitting native OpenAI cache-policy fields and Responses input. Any new projection must exclude prompt text and encrypted replay content. A fingerprint over wire JSON is not a claim of provider cache reuse.

Read the relevant local decisions: [catalog-owned capabilities](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) requires model facts in generated records; [adapter-owned translation](../adr/0003-the-adapter-owns-the-translation-description.md) requires wire choices and descriptions to come from the same mapper; [requested versus observed facts](../adr/0002-requested-translated-observed-are-never-collapsed.md) forbids treating requested retention as observed usage; [two request digests](../adr/0004-two-digests-commitment-and-configuration.md) requires content-free configuration evidence; and [explicit pricing bases](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) requires missing billing facts and estimates to remain visible. The existing [Responses implementation plan](74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md) explains the already-shipped stateless tool/reasoning replay that this change must preserve.

Provider evidence checked on 2026-10-25: the [OpenAI caching guide](https://developers.openai.com/api/docs/guides/prompt-caching) documents explicit breakpoints on GPT-5.6 and later. Responses requires reusable instructions in a developer `input_text` block because top-level `instructions` cannot carry a breakpoint. The guide documents `30m` and a Responses `12h` setting. The [Chat API reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) accepts `prompt_cache_breakpoint` on text content parts but still restricts request-level TTL to `30m`; its block-level schema also mentions `12h`. The [Responses API reference](https://developers.openai.com/api/reference/resources/responses/methods/create) search excerpt likewise restricted request TTL to `30m`, but full-page retrieval failed. Re-fetch the reference and resolve this discrepancy per endpoint before enabling long retention.

Use Mori to locate the SDK at `mori://MercuryTechnologies/openai/packages/openai`. The local corpus exposes `prompt_cache_key` in Responses but had no native breakpoint/options symbols in the inspected request modules. This does not establish the latest release's capabilities. If any dependency bound or workaround is proposed, first compare authoritative Hackage releases and upstream tags; neither a corpus snapshot nor this plan justifies a new pin.


## Plan of Work


### Milestone 1: Declare the supported wire contract


Verify the official endpoint schemas and inspect the current released SDK. Add an explicit native cache capability value in `Baikai.Compat` shared by the two OpenAI compatibility records, defaulting conservatively when absent. It must distinguish support for legacy `in_memory`, legacy `24h`, modern `30m`, modern `12h`, and explicit prefix breakpoints. Prefer a named policy type over unrelated guesses from existing Anthropic flags. Keep existing exported fields readable during migration and define deterministic precedence: the explicit native policy is authoritative; absent native policy preserves existing Responses retention behavior and leaves native Chat controls disabled. Contradictory new policies are rejected by catalog validation.

Populate endpoint-specific facts in fetch curation and JSON, with dated source evidence. Unknown models do not gain capabilities through their model name or host spelling. Pin positive and negative examples in `CatalogSpec`, including a modern Responses model, a supported modern Chat binding, a legacy model accepting both legacy values, and a legacy model accepting only `24h`. Use verified entries already in the catalog; this is not a catalog expansion task.

Before enabling a contested long value, run one bounded representative request against the selected endpoint if credentials exist and record acceptance plus the response's usage fields. A 400 leaves that capability disabled with a documented local refusal. If credentials are absent and docs remain inconsistent, implement the supported short contract and explicit refusal; leave live/long acceptance unchecked rather than guessing. This milestone is accepted when legacy JSON round-trips, invalid policies fail locally, and regenerated catalog facts survive the fetch/generate tests.


### Milestone 2: Make the Responses stable prefix cacheable


Extend `Responses/Request.hs` with a pure cache-planning result containing native cache fields, whether to mark the system prefix, and the effective duration needed by pricing. Retain `Nothing` and `Just CacheRetentionNone` as omission of explicit controls, not a command to disable provider automatic caching. Keep all unrequested-cache request shapes unchanged.

For supported Short or Long requests with non-empty `systemPrompt`, omit top-level `instructions` and prepend exactly one developer input item with one `input_text` block carrying the original text and `prompt_cache_breakpoint: {"mode":"explicit"}`. Leave implicit caching enabled. Apply one request-level TTL; do not add per-block overrides. Absent/empty instructions do not become invalid empty cacheable blocks. Older models retain the existing instructions representation. Preserve input ordering after the prepended item, tool definitions, tool call IDs, structured user data, encrypted reasoning replay, and `store: false`.

Add a representative regression in `baikai-openai/test/ResponsesSpec.hs` and driver-level tests in `ResponsesStreamSpec.hs` or `ResponsesEvidenceSpec.hs`. Capture two requests with identical system text and different initial questions. The marked prefix must match; user items must differ. Verify both public `completeRequestWith` and `streamRequestWith` dispatch through the same shaped body. Also verify a tool-result continuation still preserves its replay payload. A duplicated system instruction or marker in top-level `instructions` fails acceptance.


### Milestone 3: Support native Chat without changing compatible hosts


Extend `Shape.hs` and the Chat request mapper to apply the native cache plan only when the selected compatibility record explicitly declares it. A supported non-empty initial system/developer text message becomes a text content part with the native breakpoint; retain its role and exact text. Never mark user messages, historical assistant content, or tool definitions with an undocumented native field. One stable-prefix marker plus implicit caching stays within the provider's write budget.

Keep native OpenAI shaping separate from `CacheControlFormatAnthropic`: OpenRouter's existing marker shape and long-to-short downgrade remain covered by their existing tests. For native legacy policies, emit only the supported `prompt_cache_retention` value, without a breakpoint. A legacy `24h`-only model refuses Short locally. Unknown compatible hosts retain their existing behavior; do not send modern OpenAI fields merely because they accept Chat-shaped requests.

Add exact-body tests in `baikai-openai/test/ShapeSpec.hs`, negative compatibility tests, and a fake-driver dispatch test covering a renamed model with explicit capabilities. Unsupported native retention must fail before credentials or network work. If the Chat mapper needs a fallible result, keep the change within its existing validation/preparation path and adapt every caller. Do not bury a refusal in a pure shaper that cannot report it.


### Milestone 4: Keep prices and evidence tied to the request actually sent


Carry effective duration from request preparation into both stream implementations and their successful and error-terminal cost paths. Use `computeCostForService` with that duration and the catalog's actual prices. Add verified short/long write rates to the affected pricing policies and every applicable input tier. Unsupported or unverified long retention never silently receives a short price. When no explicit preference is supplied, a documented fixed default may be a protocol fact; otherwise preserve `CacheDurationNotReported` or the existing appropriate estimate reason. Never infer a duration from the presence of a read count.

Extend `BillingSpec.hs`, `ResponsesStreamSpec.hs`, and `baikai/test/CostSpec.hs` to show reads and writes are subtracted exactly once from inclusive input; long and short writes select different verified rates; repeated terminal snapshots do not double-charge; missing write counts are not reported zero; partial failures preserve reported billing. Use rational expected amounts and exercise an input-price tier crossing.

Extend configuration evidence only through explicit summaries of known cache fields and breakpoint locations. Keep exact text and opaque replay values solely in request commitments. Do not add arbitrary `input` or content objects to the allow-list. Test planted private strings, changed retention, changed marker placement, and changed prompt text separately in core and provider evidence tests. Version evidence schema changes according to ADR 0004 and preserve legacy golden hashes where the new fields are absent. The plan does not require a new public cache-observation record: existing usage and cost basis report the observable results.


### Milestone 5: Demonstrate and document the contract


Extend `baikai-smoke/test/CacheSmoke.hs` with focused OpenAI cases and add selection support in `baikai-smoke/test/SmokeOptions.hs`, its test, and `Smoke.hs`. Make `--case openai-cache-responses` and `--case openai-cache-chat` run only their case, without unrelated API or CLI calls. `--require-keys` must fail when the selected key is absent; ordinary optional runs must skip cleanly.

Use a run-unique prefix, stable within the case and comfortably above the chosen model's cache threshold, with no tools that could supply a competing cache hit. Keep effort and formatting settings stable. Send one fresh question, then a different fresh question; assert success, a positive initial write and subsequent read, and nonzero corresponding cost. Do not assert a universal exact token count or latency gain. Keep output caps small. Record model, endpoint, date, effective TTL and aggregate usage only, never credentials or prompt contents. If short calls work but long remains uncertain, retain that explicit limitation in the plan and guide.

Update `docs/user/prompt-caching.md`, `docs/capabilities/prompt-cache-retention.md`, `docs/capabilities/openai-responses-backend.md`, and `docs/capabilities/tiered-cache-write-pricing.md` to distinguish Baikai support from provider features. Add release notes without publishing a release. Distill durable new capability/pricing/evidence decisions into the relevant existing ADRs. This milestone is accepted only with the offline suites passing and honest live status recorded; missing credentials leave live verification pending.


## Concrete Steps


Run commands from the Baikai repository root. Keep work on the current branch unless the user requests otherwise. Discover dependencies before relying on an SDK API:

```bash
mori registry list
mori registry search openai
mori registry show MercuryTechnologies/openai --full
mori registry docs MercuryTechnologies/openai
mori path mori://MercuryTechnologies/openai/packages/openai
curl -fsSL https://hackage.haskell.org/package/openai.json
git ls-remote --tags https://github.com/MercuryTechnologies/openai.git
```

Read the returned source path, never `/nix/store`. Recheck the official URLs above. The existing JSON-shaping seams can represent fields the SDK lacks, so a dependency upgrade is not assumed.

After curating facts, regenerate locally and inspect the diff:

```bash
nix develop --no-write-lock-file -c cabal run baikai-gen-models
git diff -- baikai/data/models/openai.json baikai/src/Baikai/Models/Generated.hs
nix develop --no-write-lock-file -c cabal test baikai --test-options='-p CatalogSpec'
```

Run focused tests during implementation, then these offline suites at the integrated boundary:

```bash
nix develop --no-write-lock-file -c cabal test baikai baikai-openai baikai-claude
nix develop --no-write-lock-file -c cabal test baikai-smoke:smoke-options baikai-smoke:doc-shapes
nix develop --no-write-lock-file -c cabal build baikai-smoke:test:baikai-smoke
nix fmt
okf validate docs/capabilities --strict
git diff --check
```

Expect all named suites to pass, doc-shapes to agree with guide snippets, formatter to leave no further changes, and capability validation to report success. Do not use `cabal test all` as an offline shortcut: the ordinary smoke suite can invoke authenticated local CLIs.

After implementing the focused selector, with `OPENAI_API_KEY` available:

```bash
nix develop --no-write-lock-file -c cabal test baikai-smoke:baikai-smoke --test-options='--case openai-cache-responses --require-keys'
nix develop --no-write-lock-file -c cabal test baikai-smoke:baikai-smoke --test-options='--case openai-cache-chat --require-keys'
```

These selectors do not exist at plan creation. Add and test them in milestone 5 before running the commands. A no-key skip is not live acceptance. Keep commits conventional and include `ExecPlan: docs/plans/101-cache-shared-openai-prompt-prefixes-with-catalog-gated-controls-and-truthful-accounting.md` and `Intention: intention_01m5srppfjevrte2578x034wxq` trailers.


## Validation and Acceptance


The core regression is two fresh conversations sharing only their tools-and-system prefix. On supported native models, request capture must show one identical marked instruction block and different user messages, while live usage confirms reuse. On legacy models, capture must show only supported legacy fields. On unrelated compatible hosts, pre-change request fixtures must still match.

Exercise absent and explicit None preferences, Short, supported Long, refused Long, missing/empty instructions, multiple tools, renamed catalog models, structured user data and reasoning/tool replay. Verify endpoint selection and unsupported preferences through public registry dispatch, not only helpers. Verify exact costs from raw usage fixtures and effective duration. Configuration projections must contain no planted prompt/replay secrets. Legacy compatibility JSON must decode without new mandatory keys; contradictory new policies must fail generation with the offending model named.

Milestone 1's representative API check is the early producer/consumer proof for contested provider behavior. Milestone 5 is the end-to-end cache-hit check. Serialization, catalog facts, API acceptance, actual cache reuse, and cost arithmetic must be reported separately so none is presented as proof of another.


## Idempotence and Recovery


All offline generation and test commands can be repeated. Inspect catalog diffs before retaining them; avoid a network-wide model refresh during this focused change. A failed live request may still cost tokens, so bound the number of calls and do not retry repeatedly to manufacture a passing cache observation. A cache miss calls for checking request equality, model support, minimum size and cache scope before retrying.

Do not delete or rewrite unrelated working-tree changes. Revert only this feature's individual edits if needed. Preserve legacy decoding and golden evidence tests throughout the migration. If provider support cannot be verified, retain the conservative refusal and unchecked live milestone; document the exact outstanding fact. No release, merge, or external review comment is part of this plan.


## Interfaces and Dependencies


The neutral request interface remains `Context.systemPrompt` plus `Options.cacheRetention`; no new `Options` field is required. Native cache compatibility belongs to `Baikai.Compat` and is carried by `Model.compat`. An internal prepared-cache result should provide JSON fields, the prefix-placement decision and the effective `Maybe CacheRetention` used for pricing, deriving all three from the same selected policy. Keep this internal to the provider package unless a concrete second consumer requires exposure.

Continue using the released OpenAI SDK (`mori://MercuryTechnologies/openai/packages/openai`), Aeson and Vector already present in the workspace. Dependency API inspection uses Mori; bounds require current registry/tag verification. Raw JSON shaping is permitted at the existing provider seams without expanding core into vendor request schemas.

The already-shipped Responses stream and continuation implementation is the prerequisite; this plan has no parent MasterPlan. The Claude system-prefix implementation is an architectural example and regression boundary, not a runtime dependency. CLI providers are outside the new wire behavior. Review compatibility-record and evidence-schema changes for the next appropriate release, while leaving release execution to an explicitly requested release task.
