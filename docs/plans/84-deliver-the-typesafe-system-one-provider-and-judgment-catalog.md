---
id: 84
slug: deliver-the-typesafe-system-one-provider-and-judgment-catalog
title: "Deliver the TypeSafe System One provider and judgment catalog"
kind: exec-plan
created_at: 2026-09-26T14:42:51Z
intention: "intention_01m3f2jkgpej3s8m0wpa7cw5nz"
master_plan: "docs/masterplans/14-support-typesafe-system-one-judgment-models.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex"
    at: 2026-09-26T14:42:51Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-21T16:18:25Z
      mode: "update"
      note: "Provider-neutral judgment layer in core, OpenAPI 0.2.0 wire corrections, typesafe-ai-core-only SDK decision, OpenAI Decisions fit"
---

# Deliver the TypeSafe System One provider and judgment catalog

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/ADR.md` for durable decisions.


## Purpose / Big Picture

A user will register `Baikai.Provider.TypeSafe.Api.typesafeProvider`, select `jev-latest`, supply one JSON state and a schema declaring every answer, and receive one structured data block with chosen answers and probabilities. The normal complete and streaming registry entry points both work; streaming delivers atomic synthetic events around one non-streaming HTTP response. A local fixture proves the exact payload and errors without a paid call.

This delivers [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md). Its hard dependency is `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md`: that plan must be Complete before implementation begins. It provides `UserData Value`, `AssistantData DataContent`, `DataStart`/`DataEnd`, typed request-problem errors, named response codecs, and structured terminal trace/log payloads. This plan owns the TypeSafe provider, judgment model capability, catalog and all final packaging/adoption checks.

The schema compiler and answer validator are built as a provider-neutral judgment layer in core, so a second judgment provider (OpenAI's Decisions API, `POST /v1/decisions`, in public beta since 2026-10-06) only has to add a wire mapping. That second adapter is not part of this plan; this plan only guarantees that nothing it ships would have to be redone for it.


## Progress

- [ ] Milestone 1: judgment model/catalog facts, a provider-neutral judgment layer in core (schema compiler, generation-control refusal, strict answer validator), and the TypeSafe wire mapping pass offline contract tests against the OpenAPI 0.2.0 fixture.
- [ ] Milestone 2: the registered HTTP provider passes exact-payload, zero-dispatch refusal, error, evidence, timeout and response-persistence tests through both public call modes.
- [ ] Milestone 3: compiled adoption examples, explicitly selected live smoke, package/version preparation, and all offline integration gates pass; IR-10 completion and durable ADRs reflect the delivered contract.


## Surprises & Discoveries

There is no public streaming toggle in `Options`; the generic streaming entry point is the event protocol all providers use. Refusing that entry point would contradict IR-10's synthetic stream allowance. The adapter must always send a non-streaming wire request and may emit one atomic data block afterward.

The consumer at `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` assumes generation defaults may be dropped, including reasoning/token ceilings. This plan instead refuses explicit controls. Adoption guidance must tell that consumer to clear generation defaults after routing to a judgment-only model. The consumer example also includes boolean criteria; IR-10 and the inspected DSPy client describe noul with type/instructions only. The official specification (next paragraph) does document optional noul criteria, so the 2026-09-26 "undocumented extension" conclusion was wrong; see the 2026-10-21 decision below.

2026-10-21: TypeSafe's own OpenAPI specification, version 0.2.0, is vendored at `mori://byteally/typesafe-sdk/packages/typesafe-ai-core`, project-relative path `typesafe-sdk/typesafe-ai-core/spec/openapi.json` (artifact-level URI pending; upstream source https://api.typesafe.ai/openapi.json). It contradicts the DSPy 3.4.0 baseline this plan was written against in four places. A choice answer carries a required `confidence` number. A score answer carries a required `score` (the probability-weighted average of the level indices, which may fall between levels), a required `confidence`, and a required `legend` object echoing level index to description. A noul question accepts an optional `criteria` object with `true`/`false` descriptions. A successful response requires `model` and `usage` with both token counts. The plan's fixture, decoder contract and refusal rule are corrected below; the DSPy-era fixture is retained in the test suite as a dated regression input that must now be rejected for a missing `confidence`. The specification also shows validation failures as HTTP 422 with a `detail` array of `{loc, msg, type}` entries, and `GET /v1/models` returning `{"models": [{"name", "description", "release_date"}]}`.

2026-10-21: OpenAI's Decisions API has the same three question kinds under different names and a different wire layout: `predicate`/`choice`/`score`, questions as an ordered array with a `name`, choices as `[{value, description}]` where `value` is a string or a boolean, levels as `[{label, description}]`, `input` as a string or user messages with `input_text`/`input_image` parts, and answers as an array that may contain a per-question `refusal` entry while other questions are still answered. A choice answer returns `choice`, `probabilities: [{value, probability}]` and `confidence`; a score answer returns `score` (weighted average), `probabilities: [{value, label, probability}]` and `confidence`; a predicate returns `probability`. Limits are 1 to 200 questions, 2 to 255 choices, and 128 images per request. Only `gpt-6-luna` is served, at 0.10 USD per million input tokens with no output charge. Sources, read 2026-10-21: https://developers.openai.com/api/docs/guides/decisions and the generated types in https://github.com/openai/openai-python at `src/openai/types/decision.py` and `src/openai/types/decision_create_params.py` (openai 3.36.0 on PyPI). The Haskell `openai` package that `baikai-openai` depends on (`mori://MercuryTechnologies/openai/packages/openai`, 2.5.4 on Hackage) has no Decisions binding yet, and the public `openai/openai-openapi` repository does not describe the endpoint. Both providers therefore fit one neutral answer shape: an optional declared selection, a distribution over the declared keys, and an optional confidence.


## Decision Log

2026-09-26: Refuse all explicitly supplied generation/sampling/reasoning controls before dispatch. IR-10 permits refusal, and it avoids silent adaptation or falsely recording a setting as sent. Transport controls and local evidence/metadata are still supported.

2026-09-26: The capability is a Model/catalog fact, not an API-name predicate. Keep a new output-kind discriminator with a legacy generative default and a pure query that consumers can use.

2026-09-26: Keep protocol compilation and transport in one child plan so one owner controls validation order, the declared question set used by decoding, and exact bytes covered by evidence. A successful HTTP body is fully validated before emitting AssistantData.

2026-10-21: Make the judgment protocol provider-neutral and put it in core as `Baikai.Judgment`, still owned by this plan. The module compiles the closed-set JSON Schema subset into neutral question definitions (predicate, choice, score), audits `Options` for refused generation controls, validates a neutral answer set against those definitions, and builds the `DataContent`. A provider adapter only maps neutral questions to its wire and its wire answers back to neutral answers. The TypeSafe adapter is the first user; an OpenAI Decisions adapter in `baikai-openai` would be the second and needs no core change beyond a new `Api` tag and catalog record. This replaces the 2026-09-26 placement of the compiler inside `baikai-typesafe` internals; the single-owner rationale still holds because this plan owns the core module too.

2026-10-21: Do not depend on the community `typesafe-ai` client package; depend on `typesafe-ai-core` for `TypeSafe.Wire` only if, at implementation time, its codecs still match the vendored specification and its bounds fit the workspace; otherwise hand-write the wire codecs in `baikai-typesafe`. The client package's retries (ADR 0005 forbids an internal retry loop), its own status classification (ADR 0011 gives that to core), its own timeout and TLS manager, and its `TYPESAFE_BASE_URL`/`TYPESAFE_DEFAULT_MODEL` environment lookups all conflict with Baikai's contracts, so `TypeSafe.Client`, `TypeSafe.Call`, `TypeSafe.Error` and `TypeSafe.Retry` are not used. `TypeSafe.Wire` is a conformance-tested, forward-compatible mirror of the official OpenAPI document, and the SDK's daily specification-drift workflow is the cheapest way to learn about protocol changes. Whichever option is taken, Baikai's strict validator runs on the decoded wire values and the offline fixture bytes stay in this repository, so an upstream codec change cannot silently alter accepted behaviour. The vendored specification is the protocol baseline from now on; DSPy 3.4.0 is a historical cross-check only.

2026-10-21: Preserve provider-reported confidence and expected score instead of re-deriving them. Both TypeSafe and OpenAI return a per-answer `confidence`, and both return a weighted-average `score` for ordered questions. Dropping them would violate the never-re-derive rule in ADR 0002/0003 and would make the two adapters disagree about what a score field holds. This requires one additive change to plan 83's `DataContent`: an optional per-field confidence map. That amendment is recorded in plan 83 before its implementation starts; this plan's contract below is written against the amended shape.

2026-10-21: Accept noul criteria from a boolean property's `anyOf`/`oneOf` of `const true`/`const false` branches with descriptions, now that the specification documents them. A plain `boolean` property still compiles to a noul with no criteria. For OpenAI, whose predicate has no criteria, the adapter must refuse such a property with `UnsupportedFeature` rather than drop the descriptions.

2026-10-21, superseding the `typesafe-ai-core` option above: the TypeSafe wire types and codecs come from the in-house client at `mori://shinzui/typesafe-hs` (checkout bootstrapped the same day with a Nix shell on GHC 9.12.4 and no Cabal package yet; Mori registration pending). `baikai-typesafe` must not depend on `typesafe-ai` or `typesafe-ai-core`. The client is specified against this plan in that repository's `docs/initial-spec.md` (artifact-level URI pending), requirements R1 to R12: a servant-style SDK in the shape of the Mercury `openai` and `claude` packages, whose client Baikai's provider does not call, with no retries, credentials, environment lookups or status classification in the library; a type per schema with plain field names; deterministic request bytes with declared criteria order; lossless `Scientific` numbers so Baikai validates bounds before any `Double`; required fields enforced and unknown discriminators surfaced as explicit constructors; error-body codecs without classification; conformance tests against the vendored OpenAPI 0.2.0 document; this plan's fixture as a golden test; and bounds, compiler and Hackage publication that fit this workspace's release gate. Reasons: a community 0.1.0.0 package with one maintainer would be a release-blocking dependency of `baikai-typesafe` on Hackage, its prefixed field names and lenient numeric decoding do not match this repository's conventions, and owning the specification mirror keeps drift handling under this project's control. If a requirement in that specification cannot be met, record the gap here before working around it in the adapter.


## Outcomes & Retrospective


## Context and Orientation

Core lives in `baikai/`; API providers live in `baikai-openai/` and `baikai-claude/`. `Baikai.Provider.apiProvider` builds an `ApiProvider` from an API tag and event producer and derives complete via stream folding. Existing examples are `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, `Responses.hs`, and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Explicit registries use `registerApiProviderWith` or `newProviderRegistryFrom`. Do not auto-register by import.

`baikai/src/Baikai/Options.hs` contains optional generation fields, transport timeout/auth/headers, response format and evidence. `Context` owns `systemPrompt`, messages and tools. `JsonSchema` wraps `JsonSchemaFormat`, whose schema is an Aeson Value; the existing comment says Baikai never inspects it and needs updating to describe the closed-set subset that `Baikai.Judgment` compiles. A judgment is a question with all answer keys declared before the call. Jev is the upstream model family; System One is its HTTP dialect. OpenAI's Decisions API is a second dialect of the same idea with its own names (predicate, choice, score) and its own wire layout; it is described in Surprises & Discoveries and is the reason the protocol layer lives in core rather than in the TypeSafe package.

`baikai/src/Baikai/Model.hs` owns a model's API, URL, pricing and input modalities; constructors are hidden behind `emptyModel`/`mkModel`. `baikai/data/models/*.json` feeds `baikai/gen/GenModelsCore.hs` and `GenModels.hs`, producing `baikai/src/Baikai/Models/Generated.hs`. `baikai/fetch/FetchModelsCore.hs` refreshes curated model facts, and `baikai/test/CatalogSpec.hs` detects generation drift. The new provider's alias catalog is checked in; a credentialed model-list crawler is not required for initial delivery.

Transport precedent is `baikai-openai/src/Baikai/Provider/OpenAI/Transport.hs`, `Sse.hs`, and `baikai/src/Baikai/Http.hs`. Share the core URL, authentication/header and exception-classification contracts without taking a dependency on the OpenAI provider package. The HTTP dependency was located through Mori at `mori://snoyberg/http-client/packages/http-client`; its public API exposes request construction, response scopes, body reads and redirect settings. Inspect it again before implementing unfamiliar calls. No dependency version is selected here.

Read [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md), [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md), [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md), [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md), [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md), [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md), [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md), [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md). Together they require catalog-owned capabilities, adapter-owned truthful evidence, no internal retry loop, scoped HTTP cleanup, shared classification, evidence presence under strict mode, compiled examples, and explicit unknown pricing. No earlier ADR defines the judgment protocol; record it during implementation.

The protocol baseline is TypeSafe's OpenAPI specification, version 0.2.0, published at https://api.typesafe.ai/openapi.json. The wire types and codecs for it come from the in-house client at `mori://shinzui/typesafe-hs`, which is specified against this plan in that repository's `docs/initial-spec.md` (artifact-level URI pending) and which vendors the specification at `spec/openapi.json` once its Cabal package exists. Run `mori registry show shinzui/typesafe-hs --full` once it is registered to find the checkout; until the client vendors the document, a reference copy is readable in the registered community SDK at `mori://byteally/typesafe-sdk/packages/typesafe-ai-core`, project-relative path `typesafe-sdk/typesafe-ai-core/spec/openapi.json` (artifact-level URI pending), which is used for reading only and is not a dependency. The schemas that matter are `SystemOneRequest`, `Question` (noul, choice, score), `SystemOneResponse`, `Answer` (`NoulAnswer`, `ChoiceAnswer`, `ScoreAnswer`), `Usage` and `HTTPValidationError`. The earlier baseline, `mori://stanfordnlp/dspy` tag `3.4.0` at project-relative paths `dspy/_vendor/lm15/providers/typesafe.py` and `dspy/_vendor/lm15/judgments.py` (artifact-level URIs pending; inspected 2026-09-26 at https://raw.githubusercontent.com/stanfordnlp/dspy/3.4.0/dspy/_vendor/lm15/providers/typesafe.py and https://raw.githubusercontent.com/stanfordnlp/dspy/3.4.0/dspy/_vendor/lm15/judgments.py), remains the source of the JSON Schema convention for declaring questions but is no longer authoritative for the wire. Preserve dated protocol fixtures; none of this is a dependency on DSPy or a claim about which release is newest.

The OpenAI Decisions API was read on 2026-10-21 at https://developers.openai.com/api/docs/guides/decisions and from the generated Python types in https://github.com/openai/openai-python (`src/openai/types/decision.py`, `src/openai/types/decision_create_params.py`). It is in public beta, serves only `gpt-6-luna`, and is not yet bound by the Haskell `openai` package (`mori://MercuryTechnologies/openai/packages/openai`, 2.5.4) that `baikai-openai` builds on. Nothing in this plan calls it; it is the second consumer the core judgment layer is designed for.


## Plan of Work

### Milestone 1 — Judgment catalog and the provider-neutral protocol

Add `TypeSafeSystemOne` to `Baikai.Api`, including render/parse/normalization with `typesafe-system-one`. Audit every API match and declared-evidence-strength default. Add `OutputKind = GenerativeOutput | JudgmentOutput`, `Model.outputKind`, and `isJudgmentOnly :: Model -> Bool`. Default `emptyModel`, existing catalog entries, and legacy model JSON without this field to GenerativeOutput; never infer the value from provider/model names. Update the explicit Show instance and JSON encoder/decoder without losing header redaction or other legacy optional fields. Add `InputData` and its catalog spelling `data`.

Extend model catalog parsing/rendering and fetch-preservation tests for `outputKind`. Add `baikai/data/models/typesafe.json` with provider `typesafe`, base URL `https://api.typesafe.ai`, API `typesafe-system-one`, compat auto, and enabled aliases `jev-latest` and `jev-preview`, both JudgmentOutput with text/data input and no reasoning. Unknown limits/prices use the existing zero/unknown convention and pricing-unavailable basis; do not invent prices or limits. Ensure refreshing unrelated catalogs does not remove this curated file or its capability facts. Generate the Haskell catalog and test both aliases. `mkModel` remains generative by default; documented hand-built System One records must explicitly set the capability.

Add the provider-neutral judgment layer to core as `baikai/src/Baikai/Judgment.hs`, exported through `baikai/src/Baikai.hs`. It defines `JudgmentKind = PredicateJudgment (Maybe (Value, Value)) | ChoiceJudgment (Vector (Text, Maybe Value)) | ScoreJudgment (Vector (Maybe Value))` (the optional pair is the true/false criteria; the choice vector keeps labels in declared order with their descriptions; the score vector holds level descriptions in index order), `Judgment = Judgment {name :: Text, instructions :: Value, kind :: JudgmentKind}`, and `Judgments`, a vector of `Judgment` in schema property order with a derived name index. `compileJudgments :: JsonSchemaFormat -> Either BaikaiError Judgments` performs every schema rule below. `refuseGenerationControls :: Options -> Either BaikaiError ()` performs the options audit below and is the one place a future provider extends it. On the answer side, `JudgmentAnswer = PredicateAnswer Double | ChoiceAnswer {selected :: Text, probabilities :: Map Text Double, confidence :: Maybe Double} | ScoreAnswer {expected :: Maybe Double, probabilities :: Map Text Double, confidence :: Maybe Double} | RefusedAnswer`, and `validateAnswers :: Judgments -> Map Text JudgmentAnswer -> Either BaikaiError DataContent` enforces the answer rules below and produces exactly one `DataContent` with method `provider_classification`. The adapter never builds `DataContent` itself. `Judgments` is the value a provider adapter maps to its wire and the value its decoder maps back against; the TypeSafe-specific equivalent of the earlier `PreparedJudgments` is just `Judgments` plus the exact encoded payload bytes.

Create `baikai-typesafe/baikai-typesafe.cabal`, README, CHANGELOG and license, exposing `Baikai.Provider.TypeSafe.Api`. Put the wire mapping in `baikai-typesafe/src/Baikai/Provider/TypeSafe/Internal/Request.hs` (neutral `Judgments` plus the single user part to the `SystemOneRequest` body) and `Internal/Response.hs` (wire answers to the neutral `Map Text JudgmentAnswer`). These modules convert to and from the in-house client's wire types from `mori://shinzui/typesafe-hs` (its `SystemOneRequest`, `Question`, `Answer`, `Usage` and error-body types), encode the request with that client's deterministic encoder so the committed bytes are the sent bytes, and reject its unknown-discriminator constructors as unsupported. The TypeSafe package contains no wire codecs, no schema interpretation and no probability validation of its own.

Validate the request before credential lookup or any connection. The neutral preflight in core requires no system prompt (including rejecting a supplied empty prompt), exactly one UserMessage, no tools and no toolChoice, and rejects all other roles and history. Part cardinality and part kinds are adapter-owned because the two known dialects differ: TypeSafe requires exactly one UserText or UserData part and refuses images; OpenAI Decisions accepts several text and image parts and no data part. Each adapter checks its parts against the model's declared `input` modalities so the refusal is a catalog fact, not a name test. Require `Options.responseFormat = Just (JsonSchema ...)`, a top-level object with nonempty properties, and only supported closed-set properties. Name the actual offending path in `RequestProblem.UnsupportedFeature`, such as `Context.messages[0].content[1]` or `Options.responseFormat.schema.properties.severity`.

Compile boolean properties to predicate (TypeSafe's noul); nonempty distinct string enums or homogeneous string anyOf/const branches to choice; and integer enums/const branches containing exactly 0..N-1 to ordered score, with 2..10 levels. Choice cardinality is 1..255 for TypeSafe; the neutral compiler enforces 1..255 and leaves a stricter lower bound (OpenAI requires at least 2) to the adapter. A boolean property written as `anyOf`/`oneOf` of `const true` and `const false` branches compiles to a predicate whose branch descriptions become the true/false criteria; a bare `boolean` has none. Reject duplicates, mixed types, sparse/nonzero-based integer sets, free-form or nested outputs, empty questions, malformed branches and limits outside bounds. Integer numeric Values must be integral; booleans are not numbers. Preserve string enum order in `Judgments`; score order is numeric regardless of schema order. Do not let object-map ordering redefine score order.

A property's description supplies instructions verbatim as a JSON Value; absent/null instructions default to the property name. String anyOf branch descriptions supply criteria values; missing descriptions become null. Score descriptions form the ordered criteria array; missing/null descriptions fall back to their decimal level strings. Preserve present JSON descriptions, including false, zero and empty structures, without treating them as missing. Allow normal schema annotations (`title`, `description`, branch descriptions), `required` listing declared names, and `additionalProperties: false`; neither synthesize questions for required names nor permit required names absent from properties. Absent required means all declared properties are still answered. Reject conflicting validation keywords, unsupported references/combinators, and permissive additional properties rather than silently claiming their constraints are enforced. Top-level schema strict/name are local metadata; wire questions remain fixed and complete. The TypeSafe specification accepts instructions and criteria as string, object, array or null, so the compiler passes any JSON Value through; an adapter whose wire only accepts strings (OpenAI) must refuse non-string instructions by path rather than stringify them.

`refuseGenerationControls` refuses every explicit `maxTokens`, `temperature`, `topP`, nonempty `stopSequences`, `seed`, `frequencyPenalty`, `presencePenalty`, or `thinking`; it also refuses nontrivial cache retention and speed preferences, because no known judgment endpoint accepts them (OpenAI Decisions has its own prompt-cache fields, which a future adapter may map from `cacheRetention` by extending this audit, not by bypassing it). `Nothing`, empty stops, CacheRetentionNone, and standard speed may be treated as the absence of those preferences and must be documented/tested. The model's default max-output limit is catalog metadata and is never inserted into the payload. Preserve local metadata as local metadata; never copy arbitrary keys into the body as wire extensions. `timeoutMs`, auth sources, headers and evidence remain usable. Options has no native logprobs/stream/top-k control today; do not add such controls solely to reject them. Future additions must extend the refusal audit before being accepted by any judgment provider.

The exact TypeSafe wire body contains only model, state and questions. UserData's Value is embedded unchanged (the specification allows a string, object or array state, so a scalar or null UserData is refused by path); UserText is a JSON string. A predicate becomes `{"type":"noul","instructions":…}` plus `"criteria":{"true":…,"false":…}` only when criteria were declared; a choice becomes `{"type":"choice","instructions":…,"criteria":{label: description-or-null}}` in declared order; a score becomes `{"type":"score","instructions":…,"criteria":[…]}`.

Decode success bodies into neutral answers and hand them to `validateAnswers` with the same `Judgments`: answer names must equal question names, answer kinds must match, and every distribution must contain exactly the declared keys. Every probability and confidence must be numeric, finite and within [0,1]; validate bounds before converting scientific JSON numbers to Double to avoid overflow. Do not validate totals, normalize, clamp, or discard keys. The TypeSafe decoder requires `confidence` on choice and score answers and `score` and `legend` on score answers because the specification marks them required; `legend` must echo exactly the declared level keys and is then dropped, since the request already holds the descriptions. A choice answer's declared selection must be a declared label even when another label has higher probability. A `RefusedAnswer` fails validation as a provider refusal (the existing `ContentFiltered` error category, with `refusalCategory` set only when the provider names one, never `DecodeFailure`), because `DataContent` must hold a value for every declared field; TypeSafe never produces one, OpenAI can.

The chosen value per field is: a predicate yields true at p >= 0.5 with distribution true=p, false=1-p; a choice yields the provider's declared selection; a score yields the provider's expected score as a JSON number when the provider reports one (both known dialects do), otherwise the largest-probability integer level with ties resolved to the lowest level. Per-field confidence goes into the `DataContent` confidence map added by plan 83's amendment; a predicate has none. These are the base chosen answers required by IR-10; downstream thresholding and any further derivation remain consumer-owned. Produce exactly one AssistantData with method `provider_classification` only after every answer passes.

The specification requires `model` and `usage` with both token counts on every success. Treat them as required when decoding, and record them as observed; a nonempty model string and nonnegative integral counts are the only valid forms. Malformed success JSON is DecodeFailure, never a successful empty data block. Pure tests in core must prove the compiler, the options audit and the validator with neutral values and no wire at all, so a second adapter inherits them; pure tests in the TypeSafe package must prove the exact three-question body and the decoder failure cases before transport work begins.

### Milestone 2 — Registered HTTP calls and truthful evidence

Implement `Baikai.Provider.TypeSafe.Api` with `register`, `typesafeProvider`, and `typesafeStream`. Construct the provider using `apiProvider TypeSafeSystemOne typesafeStream`, a truthful `describeThinking`, and an evidence strength ceiling supported by this transport. Reuse the established observed-model ceiling; do not claim provider-internal reasoning or stronger attestation. `complete` must reassemble the same events rather than maintain a second decoder.

Use a scoped HTTP request to POST `/v1/systemone` once, with bearer authorization and application/json. Normalize bases with or without a trailing `/v1` so the version segment occurs once; preserve an intentional gateway path prefix. Disable redirects, matching the existing credential-bearing transports. Add the official TypeSafe host to `Baikai.Auth.defaultApiKeyEnvForBaseUrl` with `TYPESAFE_API_KEY`; explicit `Options.apiKey` wins. A custom host requires an explicit source, including `ApiKeyEnv "TYPESAFE_API_KEY"` when the caller intentionally forwards that key. Never silently forward a default credential to an unknown host. Preserve case-insensitive header precedence: provider defaults, then model headers, then option headers.

Reject nonpositive timeoutMs before dispatch. Bound the whole call, including response-body drain, by a positive timeout; map expiration to TransientError. Keep asynchronous cancellation effective and close the connection promptly. A direct scoped action is sufficient for a single response; do not introduce an unbounded detached producer. If a worker is needed, use core's StreamWorker lifecycle. Emit exactly one EventStart, then DataStart/DataEnd on valid success, then EventDone; failures emit EventError instead. No stream flag or SSE parser goes on the wire. Local refusals have zero HTTP calls; malformed replies necessarily follow one HTTP call and fail before any data success event. IR-10 acceptance's wording about malformed replies reaching no bytes cannot literally apply to a reply; this is the testable interpretation.

Use `Baikai.Provider.Transport.Classify` for connection/body exceptions and `Baikai.Error.httpError` for status classification. Verify 401/403 AuthError, 429 RateLimited with Retry-After, 400/422 InvalidRequest, and 5xx TransientError, and treat 529 (the specification's overloaded status) as TransientError. A 422 body is `{"detail":[{"loc":[…],"msg":…,"type":…}]}`; surface the first entry's joined `loc` path and `msg` in the error message without claiming it maps to a local field. Recognized TypeSafe unknown-model 400 responses add `UnsupportedModel` request detail while retaining HTTP status and InvalidRequest. Pin the recognized code/message forms as provider-specific fixtures; do not apply broad model-name substring heuristics to every 400. Unsupported local fields use the first plan's typed feature detail. There is no retry loop, which is also why the community client package is not used.

Construct evidence from actual prepared payload bytes and actual observations. Preserve `x-typesafe-request-id` as providerRequestId, separate from responseId; missing headers/model/usage remain Unobserved. Capture headers and useful observations even on malformed/HTTP-error outcomes where available. Commitment includes structured state/questions; configuration projection must exclude their free-form content. The current allow-list drops both entirely; retain that safe behavior unless adding an explicit structure-only summary with its own fixtures. Response commitment includes chosen values, probability maps and method, plus stop reason and provider usage; pricing remains local. Use actual observed usage for token/cost calculation and mark unpriced catalog costs as unavailable estimates. Test evidence opted out, best effort, and required modes; local refusals and partial failures must remain truthful.

Build a loopback HTTP fixture in `baikai-typesafe/test/HttpFixture.hs` and a suite under `test/Main.hs`, using existing repository test techniques (the provider LifecycleSpec/Contract modules are precedents). Count requests and capture decoded body, path and headers. The exact fixture below and the refusal matrix must run through complete and streaming dispatch on explicit registries. Reuse these responses to assert named whole-response codec, trace and call-log preservation through the contracts supplied by the first plan. Do not substitute pure request-builder tests for this gate.

### Milestone 3 — Consumer adoption and package delivery

Add the package to `cabal.project` and `mori.dhall`, including its dependency references and smoke package dependencies. Add a dedicated `typesafe-live` test suite in `baikai-smoke/baikai-smoke.cabal` with `TypeSafeSmoke.hs`: without an explicit `--live` argument it skips, even if a key exists. With --live, require a nonempty TYPESAFE_API_KEY, call jev-latest once with the documented valid request, and verify data shape/range/key invariants rather than stochastic exact answers. Never invoke this selected live command in CI. Missing credentials in explicit live mode must report that live verification did not run.

Document installation, registry setup, catalog selection, JSON state/schema construction, reading distributions, typed refusals, synthetic streaming, base overrides, and the difference between answer evidence and call evidence in `baikai-typesafe/README.md` and a user guide such as `docs/user/typesafe-judgments.md`. Add a capability record with a compiled doc-shapes twin and include baikai-typesafe in that suite's dependencies. Preserve OKF bundle IDs/profiles/log conventions when creating the record; consult the actual bundle rather than hand-picking an ID. The compiled example must register into an explicit registry and work with the offline fixture as well as a real model.

Document the consumer migration under `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`: use isJudgmentOnly, send UserData, consume AssistantData, retain answer probabilities in its own response codec, and clear post-routing generation defaults. Do not add Baikai Response Aeson instances or tell the consumer to reuse cached per-call evidence as a new observation. Do not modify that repository as part of this plan.

Prepare a PVP-compatible version and changelog set. As of 2026-10-21 core is 0.8.0.0, OpenAI and Claude are 0.7.1.1, and the new provider does not exist; re-read the manifests before choosing numbers. Public content/event constructors, the new `Baikai.Judgment` module, and error/model/trace/log record fields require a core PVP major increment (normally the second component here); evaluate each other changed package independently. Do not prescribe synchronized versions. Before choosing numbers or dependency bounds, verify Hackage package metadata and upstream release tags for the affected packages, and compare current source manifests. The in-house client from `mori://shinzui/typesafe-hs` must be published to Hackage under its declared package name before `baikai-typesafe` can pass the isolated source-distribution build; a `source-repository-package` reference is acceptable only on the development branch and must be removed from `cabal.project` before release. Start the new provider at the repository's normal initial release version. Update every in-repository bound that excludes the new core, list the public type changes and migration instructions in changelogs, and test source distributions. Prepare release notes without publishing or advancing README Hackage badges/capability released-since claims.

Update IR-10 and its bundle log to completed only when its implementation acceptance is met, linking the local plans and test evidence. Record whether live verification ran separately. Update/create ADRs for judgment capability, strict refusal, request/reply validation, synthetic events, and the provider-neutral judgment layer (why the protocol lives in core, which parts are adapter-owned, and why provider confidence and expected score are preserved rather than derived), then distill both child plans at MasterPlan completion. Existing evidence, pricing and classification ADRs should be extended where their existing subjects apply.


## Concrete Steps

Run from the repository root in the Nix development shell. Before choosing unfamiliar HTTP or test APIs, resolve dependencies through Mori:

```bash
mori registry search http-client
mori registry show snoyberg/http-client --full
mori registry docs snoyberg/http-client
mori registry show shinzui/typesafe-hs --full
mori registry show byteally/typesafe-sdk --full
```

The first of the last two commands prints the in-house client checkout (`docs/initial-spec.md`, its Cabal package and, once vendored, `spec/openapi.json`); the second prints the community SDK whose `typesafe-sdk/typesafe-ai-core/spec/openapi.json` is a reference copy of the same document and nothing more. Before implementing the wire mapping, confirm that the client's `apiSpecVersion` is 0.2.0 and that it satisfies requirements R1 to R12 of its specification; while it is unpublished, reference it from `cabal.project` with a `source-repository-package` stanza pinned to a commit, never with an absolute local path that would not survive a fresh checkout.

After adding the package and catalog:

```bash
nix develop
cabal run baikai-gen-models
cabal build all
cabal test baikai-typesafe:test:baikai-typesafe-test baikai:test:baikai-test
cabal test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-trace-otel:test:baikai-trace-otel-test
cabal test baikai-effectful:test:baikai-effectful-test baikai-kit:test:baikai-kit-test baikai-agent:test:baikai-agent-test
cabal test baikai-smoke:test:doc-shapes baikai-smoke:test:smoke-options baikai-smoke:test:typesafe-live
cabal sdist baikai baikai-typesafe
```

The new suite should report passing protocol, local-refusal, transport/evidence and persistence groups. The unselected TypeSafe live suite must report a skip without making a network call, even with a fixture key in its environment. Re-running catalog generation with unchanged inputs must yield no diff. Build the produced source distributions in an isolated temporary project to catch missing data/module files and dependence on workspace-only files. Verify every affected package distribution, extending the sdist selection to the final changed set.

Only when deliberately exercising the live gate, with the key already in the environment:

```bash
cabal test baikai-smoke:test:typesafe-live --test-options='--live'
```

This command performs one paid provider call. Its absence must not be reported as successful live verification. Do not print credentials. Routine test commands above exercise no live provider call. Use Conventional Commits with this ExecPlan, `docs/masterplans/14-support-typesafe-system-one-judgment-models.md`, and intention `intention_01m3f2jkgpej3s8m0wpa7cw5nz` trailers.


## Validation and Acceptance

The fixture schema describes urgent as boolean, category as described billing/technical anyOf string constants, and severity as described integer constants 0,1,2. Supply `UserData {"ticket":"Checkout is unavailable."}`. The server must observe POST `/v1/systemone`, the fixture bearer header, and this JSON body (compare exact structure and scalar types, not incidental object ordering); a second request variant declares urgent through `anyOf` const true/false branches with descriptions and must additionally carry `"criteria": {"true": "...", "false": "..."}` on the noul question:

```json
{
  "model": "jev-latest",
  "state": {"ticket": "Checkout is unavailable."},
  "questions": {
    "urgent": {"type": "noul", "instructions": "Is service blocked?"},
    "category": {"type": "choice", "instructions": "Classify the issue.", "criteria": {"billing": "Payment issue", "technical": "Product malfunction"}},
    "severity": {"type": "score", "instructions": "Rate impact.", "criteria": ["Minor", "Disruptive", "Blocking"]}
  }
}
```

Return the following, which follows the OpenAPI 0.2.0 answer schemas, with `x-typesafe-request-id: fixture-42`:

```json
{
  "answers": {
    "urgent": {"type": "noul", "noul": 0.83},
    "category": {"type": "choice", "probabilities": {"billing": 0.2, "technical": 0.7}, "choice": "technical", "confidence": 0.65},
    "severity": {"type": "score", "probabilities": {"0": 0.1, "1": 0.3, "2": 0.6}, "score": 1.5, "confidence": 0.55, "legend": {"0": "Minor", "1": "Disruptive", "2": "Blocking"}}
  },
  "usage": {"input_tokens": 120, "output_tokens": 3},
  "model": "jev-fixture-version"
}
```

Both public entry points produce exactly one AssistantData, with urgent=true, category=technical, severity=1.5; its distributions preserve 0.83/1-0.83, 0.2/0.7, and 0.1/0.3/0.6, and its confidence map holds category=0.65 and severity=0.55 with no entry for urgent. The 0.9 choice total must pass unchanged. The same reply with `score` absent is a DecodeFailure, and the DSPy-era reply without `confidence` and `legend` is retained as a dated fixture that must now fail decoding. Evidence keeps requested jev-latest separate from observed jev-fixture-version and records fixture-42 as providerRequestId. A canonical response encode/decode/re-encode is byte-stable; trace JSONL, call-log JSONL and compiled consumer examples retain all distributions and confidences.

Core's own suite proves the neutral layer without any wire: `compileJudgments` on the fixture schema yields the three `Judgment` values in declared order; `validateAnswers` on neutral answers produces the `DataContent` above; and a `RefusedAnswer` for any field fails as a provider refusal with that field named. These tests are what a future OpenAI Decisions adapter reuses unchanged.

The preflight matrix must cover system prompt, zero/multiple messages, wrong role, zero/multiple parts, image/media, tools, every explicit tool choice, each generation option, unsupported cache/speed, missing/JsonObject response format, empty/free-form/mixed properties, bad schemas, 256 choices, and 1/11 score levels. For every case assert typed detail naming the field and the fixture's request counter remaining zero through complete and stream; ensure the test starts from otherwise valid inputs. Also cover accepted boundary sizes of 255 choices and 2/10 levels. A streaming API call with valid input succeeds but sends no native stream field.

Malformed reply cases include missing/extra answers, mismatched answer tags, missing/extra distribution keys, a `legend` that disagrees with the declared levels, undeclared choice labels, nonnumeric/boolean/out-of-range/overflowing probabilities or confidences, a missing `confidence`, `score`, `usage` or `model`, invalid usage/model values, truncated JSON and wrong top-level shape. Assert one fixture request, DecodeFailure, and no AssistantData success event. Include choice-not-argmax and non-integer `score` fixtures. Verify 401, 429, 400/422 (including the `detail` array form), unknown-model 400, 529 and 5xx classification separately from malformed success replies; verify a stalled body times out, cancellation closes the response, and no internal retry occurs. Unknown/missing pricing must not become fabricated observations.


## Idempotence and Recovery

Use temporary loopback servers with scoped shutdown and explicit registries; rerunning tests must not mutate global provider state or contact TypeSafe. Keep model aliases in source JSON and regenerate instead of hand-editing Generated.hs. Temporary package projects must not modify tracked dependency files. If upstream protocol evidence differs, keep the failing fixture, record the dated primary source and update this plan's contract before changing production behavior; do not weaken strict decoding to make an unexplained response pass. Publication, credential changes and consumer-repository migrations are outside this implementation.


## Interfaces and Dependencies

The provider exports `register :: IO ()`, `typesafeProvider :: ApiProvider`, and `typesafeStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent`. Core adds `TypeSafeSystemOne`, `OutputKind`, `outputKind`, `isJudgmentOnly`, `InputData`, and the `Baikai.Judgment` module with `Judgment`, `JudgmentKind`, `Judgments`, `compileJudgments`, `refuseGenerationControls`, `JudgmentAnswer` and `validateAnswers`. Catalog generation exports the two aliases through the existing naming convention. The request/response implementation consumes the first child plan's DataContent (including its amended optional confidence map) and RequestProblem types without redefining them.

A second judgment adapter, such as OpenAI Decisions in `baikai-openai`, is expected to add only an `Api` tag, a catalog record with `JudgmentOutput` and its input modalities, a wire mapping from `Judgments` and the user parts to its request, a decoder from its answers array to `Map Text JudgmentAnswer`, and its own transport; it must not duplicate the compiler, the options audit or the validator. That adapter is a separate plan and waits for the API to leave beta and for a Haskell binding (the `openai` package or hand-written types in `baikai-openai`).

Reuse core and its existing HTTP/Aeson/vector/containers/streamly dependencies. The package depends on the in-house client from `mori://shinzui/typesafe-hs` for wire types and codecs, and must not depend on baikai-openai, baikai-claude, `typesafe-ai` or `typesafe-ai-core`. The client must satisfy requirements R1 to R12 of its `docs/initial-spec.md`; if one cannot be met, record the gap in this plan's Decision Log before working around it. `http-client`, the in-house client and any fixture dependencies must be located with Mori, inspected on disk, and checked against authoritative registry releases and upstream tags before setting bounds. Use canonical Mori references for durable cross-repository references; never traverse `/nix/store` or search `/`.


## Revision Notes

2026-10-21: Revised after reviewing TypeSafe's OpenAPI 0.2.0 specification, the community `typesafe-sdk` Haskell packages, and OpenAI's Decisions API. The schema compiler, generation-control audit and answer validator move from TypeSafe package internals into a provider-neutral core module so a future OpenAI Decisions adapter reuses them; the wire contract, fixture and decoder rules are corrected to the specification (required `confidence`, `score`, `legend`, `model` and `usage`; optional noul criteria); the SDK decision limits any dependency to `typesafe-ai-core`'s wire codecs; and the version baseline in Milestone 3 is refreshed. Plan 83 needs one additive amendment (an optional per-field confidence map on `DataContent`) before its implementation starts.

2026-10-21, later the same day: Replaced the conditional `typesafe-ai-core` dependency with the in-house client at `mori://shinzui/typesafe-hs` and wrote that client's conformance specification (`docs/initial-spec.md` there, requirements R1 to R12) from this plan's needs. Context and Orientation, Milestone 1, Milestone 3, Concrete Steps and Interfaces now name the client; the earlier Decision Log entry is superseded, not removed.
