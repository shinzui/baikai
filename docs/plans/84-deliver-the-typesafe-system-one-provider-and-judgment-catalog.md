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
---

# Deliver the TypeSafe System One provider and judgment catalog

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/ADR.md` for durable decisions.


## Purpose / Big Picture

A user will register `Baikai.Provider.TypeSafe.Api.typesafeProvider`, select `jev-latest`, supply one JSON state and a schema declaring every answer, and receive one structured data block with chosen answers and probabilities. The normal complete and streaming registry entry points both work; streaming delivers atomic synthetic events around one non-streaming HTTP response. A local fixture proves the exact payload and errors without a paid call.

This delivers [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md). Its hard dependency is `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md`: that plan must be Complete before implementation begins. It provides `UserData Value`, `AssistantData DataContent`, `DataStart`/`DataEnd`, typed request-problem errors, named response codecs, and structured terminal trace/log payloads. This plan owns the TypeSafe provider, judgment model capability, catalog and all final packaging/adoption checks.


## Progress

- [ ] Milestone 1: judgment model/catalog facts and a pure schema/request compiler plus strict answer decoder pass offline contract tests.
- [ ] Milestone 2: the registered HTTP provider passes exact-payload, zero-dispatch refusal, error, evidence, timeout and response-persistence tests through both public call modes.
- [ ] Milestone 3: compiled adoption examples, explicitly selected live smoke, package/version preparation, and all offline integration gates pass; IR-10 completion and durable ADRs reflect the delivered contract.


## Surprises & Discoveries

There is no public streaming toggle in `Options`; the generic streaming entry point is the event protocol all providers use. Refusing that entry point would contradict IR-10's synthetic stream allowance. The adapter must always send a non-streaming wire request and may emit one atomic data block afterward.

The consumer at `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs` assumes generation defaults may be dropped, including reasoning/token ceilings. This plan instead refuses explicit controls. Adoption guidance must tell that consumer to clear generation defaults after routing to a judgment-only model. The consumer example also includes boolean criteria; IR-10 and the inspected tagged client describe noul with type/instructions only. Do not forward extra boolean criteria as an undocumented extension.


## Decision Log

2026-09-26: Refuse all explicitly supplied generation/sampling/reasoning controls before dispatch. IR-10 permits refusal, and it avoids silent adaptation or falsely recording a setting as sent. Transport controls and local evidence/metadata are still supported.

2026-09-26: The capability is a Model/catalog fact, not an API-name predicate. Keep a new output-kind discriminator with a legacy generative default and a pure query that consumers can use.

2026-09-26: Keep protocol compilation and transport in one child plan so one owner controls validation order, the declared question set used by decoding, and exact bytes covered by evidence. A successful HTTP body is fully validated before emitting AssistantData.


## Outcomes & Retrospective


## Context and Orientation

Core lives in `baikai/`; API providers live in `baikai-openai/` and `baikai-claude/`. `Baikai.Provider.apiProvider` builds an `ApiProvider` from an API tag and event producer and derives complete via stream folding. Existing examples are `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, `Responses.hs`, and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Explicit registries use `registerApiProviderWith` or `newProviderRegistryFrom`. Do not auto-register by import.

`baikai/src/Baikai/Options.hs` contains optional generation fields, transport timeout/auth/headers, response format and evidence. `Context` owns `systemPrompt`, messages and tools. `JsonSchema` wraps `JsonSchemaFormat`, whose schema is an Aeson Value; the existing comment says Baikai never inspects it and needs updating to describe this provider's closed-set subset. A judgment is a question with all answer keys declared before the call. Jev is the upstream model family; System One is its HTTP dialect.

`baikai/src/Baikai/Model.hs` owns a model's API, URL, pricing and input modalities; constructors are hidden behind `emptyModel`/`mkModel`. `baikai/data/models/*.json` feeds `baikai/gen/GenModelsCore.hs` and `GenModels.hs`, producing `baikai/src/Baikai/Models/Generated.hs`. `baikai/fetch/FetchModelsCore.hs` refreshes curated model facts, and `baikai/test/CatalogSpec.hs` detects generation drift. The new provider's alias catalog is checked in; a credentialed model-list crawler is not required for initial delivery.

Transport precedent is `baikai-openai/src/Baikai/Provider/OpenAI/Transport.hs`, `Sse.hs`, and `baikai/src/Baikai/Http.hs`. Share the core URL, authentication/header and exception-classification contracts without taking a dependency on the OpenAI provider package. The HTTP dependency was located through Mori at `mori://snoyberg/http-client/packages/http-client`; its public API exposes request construction, response scopes, body reads and redirect settings. Inspect it again before implementing unfamiliar calls. No dependency version is selected here.

Read [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md), [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md), [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md), [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md), [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md), [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md), [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md), [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md). Together they require catalog-owned capabilities, adapter-owned truthful evidence, no internal retry loop, scoped HTTP cleanup, shared classification, evidence presence under strict mode, compiled examples, and explicit unknown pricing. No earlier ADR defines the judgment protocol; record it during implementation.

The protocol baseline is the supplied IR-10 and `mori://stanfordnlp/dspy`, project-relative paths `dspy/_vendor/lm15/providers/typesafe.py` and `dspy/_vendor/lm15/judgments.py` (artifact-level URIs pending), tag `3.4.0`. Mori has no local entry for that project at planning time. Tagged primary sources were inspected at https://raw.githubusercontent.com/stanfordnlp/dspy/3.4.0/dspy/_vendor/lm15/providers/typesafe.py and https://raw.githubusercontent.com/stanfordnlp/dspy/3.4.0/dspy/_vendor/lm15/judgments.py on 2026-09-26. Preserve dated protocol fixtures; this is not a dependency on DSPy or a claim that its tag is the newest release.


## Plan of Work

### Milestone 1 — Judgment catalog and pure protocol

Add `TypeSafeSystemOne` to `Baikai.Api`, including render/parse/normalization with `typesafe-system-one`. Audit every API match and declared-evidence-strength default. Add `OutputKind = GenerativeOutput | JudgmentOutput`, `Model.outputKind`, and `isJudgmentOnly :: Model -> Bool`. Default `emptyModel`, existing catalog entries, and legacy model JSON without this field to GenerativeOutput; never infer the value from provider/model names. Update the explicit Show instance and JSON encoder/decoder without losing header redaction or other legacy optional fields. Add `InputData` and its catalog spelling `data`.

Extend model catalog parsing/rendering and fetch-preservation tests for `outputKind`. Add `baikai/data/models/typesafe.json` with provider `typesafe`, base URL `https://api.typesafe.ai`, API `typesafe-system-one`, compat auto, and enabled aliases `jev-latest` and `jev-preview`, both JudgmentOutput with text/data input and no reasoning. Unknown limits/prices use the existing zero/unknown convention and pricing-unavailable basis; do not invent prices or limits. Ensure refreshing unrelated catalogs does not remove this curated file or its capability facts. Generate the Haskell catalog and test both aliases. `mkModel` remains generative by default; documented hand-built System One records must explicitly set the capability.

Create `baikai-typesafe/baikai-typesafe.cabal`, README, CHANGELOG and license, exposing `Baikai.Provider.TypeSafe.Api`. Put the pure compiler in `baikai-typesafe/src/Baikai/Provider/TypeSafe/Internal/Request.hs` and decoder in `Internal/Response.hs`. Define an internal `PreparedJudgments` containing the exact payload Value plus the validated question definitions in declared order. The decoder consumes these definitions instead of reparsing the schema independently. Keep this internal contract out of the core package.

Validate the request before credential lookup or any connection. Require no system prompt (including rejecting a supplied empty prompt), exactly one UserMessage with exactly one UserText or UserData part, no tools and no toolChoice. Reject all other roles, media and history. Require `Options.responseFormat = Just (JsonSchema ...)`, a top-level object with nonempty properties, and only supported closed-set properties. Name the actual offending path in `RequestProblem.UnsupportedFeature`, such as `Context.messages[0].content[1]` or `Options.responseFormat.schema.properties.severity`.

Compile boolean properties to noul; nonempty distinct string enums or homogeneous string anyOf/const branches to choice; and integer enums/const branches containing exactly 0..N-1 to ordered score, with 2..10 levels. Choice cardinality is 1..255. Reject duplicates, mixed types, sparse/nonzero-based integer sets, free-form or nested outputs, empty questions, malformed branches and limits outside bounds. Integer numeric Values must be integral; booleans are not numbers. Preserve string enum order internally; score order is numeric regardless of schema order. Do not let object-map ordering redefine score order.

A property's description supplies instructions verbatim as a JSON Value; absent/null instructions default to the property name. String anyOf branch descriptions supply criteria values; missing descriptions become null. Score descriptions form the ordered criteria array; missing/null descriptions fall back to their decimal level strings. Preserve present JSON descriptions, including false, zero and empty structures, without treating them as missing. Allow normal schema annotations (`title`, `description`, branch descriptions), `required` listing declared names, and `additionalProperties: false`; neither synthesize questions for required names nor permit required names absent from properties. Absent required means all declared properties are still answered. Reject conflicting validation keywords, unsupported references/combinators, and permissive additional properties rather than silently claiming their constraints are enforced. Top-level schema strict/name are local metadata; wire questions remain fixed and complete. Boolean criteria extensions are not part of this initial contract.

Refuse every explicit `maxTokens`, `temperature`, `topP`, nonempty `stopSequences`, `seed`, `frequencyPenalty`, `presencePenalty`, or `thinking`; also refuse nontrivial cache retention and speed preferences unsupported by this endpoint. `Nothing`, empty stops, CacheRetentionNone, and standard speed may be treated as the absence of those preferences and must be documented/tested. The model's default max-output limit is catalog metadata and is never inserted into the payload. Preserve local metadata as local metadata; never copy arbitrary keys into the body as wire extensions. `timeoutMs`, auth sources, headers and evidence remain usable. Options has no native logprobs/stream/top-k control today; do not add such controls solely to reject them. Future additions must extend the refusal audit before being accepted by this provider.

The exact wire body contains only model, state and questions. UserData's Value is embedded unchanged; UserText is a JSON string. Parse success bodies against PreparedJudgments: answer names must equal question names, answer type tags must match, and every distribution must contain exactly the declared keys. Every probability must be numeric, finite and within [0,1]; validate bounds before converting scientific JSON numbers to Double to avoid overflow. Do not validate totals, normalize, clamp, or discard keys. Reject malformed choice selections even when the distribution is otherwise valid. A noul yields true at p >= 0.5 and distribution true=p, false=1-p; choice uses the provider's declared selection even if another label has higher probability; score chooses the largest-probability integer level with ties resolved to the lowest level. These are the base chosen answers required by IR-10; downstream thresholding/weighted means remain consumer-owned. Produce exactly one AssistantData with method `provider_classification` only after every answer passes.

Accept absent/null usage as unobserved; present counts must be nonnegative integral token counts and retain partial availability when only one is supplied. A present model must be a nonempty string; absent model is unobserved. Malformed success JSON is DecodeFailure, never a successful empty data block. Pure tests must prove both the exact three-question body and these failure cases before transport work begins.

### Milestone 2 — Registered HTTP calls and truthful evidence

Implement `Baikai.Provider.TypeSafe.Api` with `register`, `typesafeProvider`, and `typesafeStream`. Construct the provider using `apiProvider TypeSafeSystemOne typesafeStream`, a truthful `describeThinking`, and an evidence strength ceiling supported by this transport. Reuse the established observed-model ceiling; do not claim provider-internal reasoning or stronger attestation. `complete` must reassemble the same events rather than maintain a second decoder.

Use a scoped HTTP request to POST `/v1/systemone` once, with bearer authorization and application/json. Normalize bases with or without a trailing `/v1` so the version segment occurs once; preserve an intentional gateway path prefix. Disable redirects, matching the existing credential-bearing transports. Add the official TypeSafe host to `Baikai.Auth.defaultApiKeyEnvForBaseUrl` with `TYPESAFE_API_KEY`; explicit `Options.apiKey` wins. A custom host requires an explicit source, including `ApiKeyEnv "TYPESAFE_API_KEY"` when the caller intentionally forwards that key. Never silently forward a default credential to an unknown host. Preserve case-insensitive header precedence: provider defaults, then model headers, then option headers.

Reject nonpositive timeoutMs before dispatch. Bound the whole call, including response-body drain, by a positive timeout; map expiration to TransientError. Keep asynchronous cancellation effective and close the connection promptly. A direct scoped action is sufficient for a single response; do not introduce an unbounded detached producer. If a worker is needed, use core's StreamWorker lifecycle. Emit exactly one EventStart, then DataStart/DataEnd on valid success, then EventDone; failures emit EventError instead. No stream flag or SSE parser goes on the wire. Local refusals have zero HTTP calls; malformed replies necessarily follow one HTTP call and fail before any data success event. IR-10 acceptance's wording about malformed replies reaching no bytes cannot literally apply to a reply; this is the testable interpretation.

Use `Baikai.Provider.Transport.Classify` for connection/body exceptions and `Baikai.Error.httpError` for status classification. Verify 401/403 AuthError, 429 RateLimited with Retry-After, 400/422 InvalidRequest, and 5xx TransientError. Recognized TypeSafe unknown-model 400 responses add `UnsupportedModel` request detail while retaining HTTP status and InvalidRequest. Pin the recognized code/message forms as provider-specific fixtures; do not apply broad model-name substring heuristics to every 400. Unsupported local fields use the first plan's typed feature detail. There is no retry loop.

Construct evidence from actual prepared payload bytes and actual observations. Preserve `x-typesafe-request-id` as providerRequestId, separate from responseId; missing headers/model/usage remain Unobserved. Capture headers and useful observations even on malformed/HTTP-error outcomes where available. Commitment includes structured state/questions; configuration projection must exclude their free-form content. The current allow-list drops both entirely; retain that safe behavior unless adding an explicit structure-only summary with its own fixtures. Response commitment includes chosen values, probability maps and method, plus stop reason and provider usage; pricing remains local. Use actual observed usage for token/cost calculation and mark unpriced catalog costs as unavailable estimates. Test evidence opted out, best effort, and required modes; local refusals and partial failures must remain truthful.

Build a loopback HTTP fixture in `baikai-typesafe/test/HttpFixture.hs` and a suite under `test/Main.hs`, using existing repository test techniques (the provider LifecycleSpec/Contract modules are precedents). Count requests and capture decoded body, path and headers. The exact fixture below and the refusal matrix must run through complete and streaming dispatch on explicit registries. Reuse these responses to assert named whole-response codec, trace and call-log preservation through the contracts supplied by the first plan. Do not substitute pure request-builder tests for this gate.

### Milestone 3 — Consumer adoption and package delivery

Add the package to `cabal.project` and `mori.dhall`, including its dependency references and smoke package dependencies. Add a dedicated `typesafe-live` test suite in `baikai-smoke/baikai-smoke.cabal` with `TypeSafeSmoke.hs`: without an explicit `--live` argument it skips, even if a key exists. With --live, require a nonempty TYPESAFE_API_KEY, call jev-latest once with the documented valid request, and verify data shape/range/key invariants rather than stochastic exact answers. Never invoke this selected live command in CI. Missing credentials in explicit live mode must report that live verification did not run.

Document installation, registry setup, catalog selection, JSON state/schema construction, reading distributions, typed refusals, synthetic streaming, base overrides, and the difference between answer evidence and call evidence in `baikai-typesafe/README.md` and a user guide such as `docs/user/typesafe-judgments.md`. Add a capability record with a compiled doc-shapes twin and include baikai-typesafe in that suite's dependencies. Preserve OKF bundle IDs/profiles/log conventions when creating the record; consult the actual bundle rather than hand-picking an ID. The compiled example must register into an explicit registry and work with the offline fixture as well as a real model.

Document the consumer migration under `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`: use isJudgmentOnly, send UserData, consume AssistantData, retain answer probabilities in its own response codec, and clear post-routing generation defaults. Do not add Baikai Response Aeson instances or tell the consumer to reuse cached per-call evidence as a new observation. Do not modify that repository as part of this plan.

Prepare a PVP-compatible version and changelog set. At planning time core is 0.7.1.0, OpenAI/Claude are 0.7.0.0, and the new provider does not exist. Public content/event constructors and error/model/trace/log record fields require a core PVP major increment (normally the second component here); evaluate each other changed package independently. Do not prescribe synchronized versions. Before choosing numbers or dependency bounds, verify Hackage package metadata and upstream release tags for the affected packages, and compare current source manifests. Start the new provider at the repository's normal initial release version. Update every in-repository bound that excludes the new core, list the public type changes and migration instructions in changelogs, and test source distributions. Prepare release notes without publishing or advancing README Hackage badges/capability released-since claims.

Update IR-10 and its bundle log to completed only when its implementation acceptance is met, linking the local plans and test evidence. Record whether live verification ran separately. Update/create ADRs for judgment capability, strict refusal, request/reply validation and synthetic events, then distill both child plans at MasterPlan completion. Existing evidence, pricing and classification ADRs should be extended where their existing subjects apply.


## Concrete Steps

Run from the repository root in the Nix development shell. Before choosing unfamiliar HTTP or test APIs, resolve dependencies through Mori:

```bash
mori registry search http-client
mori registry show snoyberg/http-client --full
mori registry docs snoyberg/http-client
```

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

The fixture schema describes urgent as boolean, category as described billing/technical anyOf string constants, and severity as described integer constants 0,1,2. Supply `UserData {"ticket":"Checkout is unavailable."}`. The server must observe POST `/v1/systemone`, the fixture bearer header, and this JSON body (compare exact structure and scalar types, not incidental object ordering):

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

Return the following with `x-typesafe-request-id: fixture-42`:

```json
{
  "answers": {
    "urgent": {"type": "noul", "noul": 0.83},
    "category": {"type": "choice", "probabilities": {"billing": 0.2, "technical": 0.7}, "choice": "technical"},
    "severity": {"type": "score", "probabilities": {"0": 0.1, "1": 0.3, "2": 0.6}}
  },
  "usage": {"input_tokens": 120, "output_tokens": 3},
  "model": "jev-fixture-version"
}
```

Both public entry points produce exactly one AssistantData, with urgent=true, category=technical, severity=2; its distributions preserve 0.83/1-0.83, 0.2/0.7, and 0.1/0.3/0.6. The 0.9 choice total must pass unchanged. Evidence keeps requested jev-latest separate from observed jev-fixture-version and records fixture-42 as providerRequestId. A canonical response encode/decode/re-encode is byte-stable; trace JSONL, call-log JSONL and compiled consumer examples retain all distributions.

The preflight matrix must cover system prompt, zero/multiple messages, wrong role, zero/multiple parts, image/media, tools, every explicit tool choice, each generation option, unsupported cache/speed, missing/JsonObject response format, empty/free-form/mixed properties, bad schemas, 256 choices, and 1/11 score levels. For every case assert typed detail naming the field and the fixture's request counter remaining zero through complete and stream; ensure the test starts from otherwise valid inputs. Also cover accepted boundary sizes of 255 choices and 2/10 levels. A streaming API call with valid input succeeds but sends no native stream field.

Malformed reply cases include missing/extra answers, mismatched answer tags, missing/extra distribution keys, undeclared choice labels, nonnumeric/boolean/out-of-range/overflowing probabilities, invalid usage/model, truncated JSON and wrong top-level shape. Assert one fixture request, DecodeFailure, and no AssistantData success event. Include tie and choice-not-argmax fixtures. Verify 401, 429, 400/422, unknown-model 400 and 5xx classification separately from malformed success replies; verify a stalled body times out, cancellation closes the response, and no internal retry occurs. Unknown/missing pricing and usage must not become fabricated observations.


## Idempotence and Recovery

Use temporary loopback servers with scoped shutdown and explicit registries; rerunning tests must not mutate global provider state or contact TypeSafe. Keep model aliases in source JSON and regenerate instead of hand-editing Generated.hs. Temporary package projects must not modify tracked dependency files. If upstream protocol evidence differs, keep the failing fixture, record the dated primary source and update this plan's contract before changing production behavior; do not weaken strict decoding to make an unexplained response pass. Publication, credential changes and consumer-repository migrations are outside this implementation.


## Interfaces and Dependencies

The provider exports `register :: IO ()`, `typesafeProvider :: ApiProvider`, and `typesafeStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent`. Core adds `TypeSafeSystemOne`, `OutputKind`, `outputKind`, `isJudgmentOnly` and `InputData`. Catalog generation exports the two aliases through the existing naming convention. The request/response implementation consumes the first child plan's DataContent and RequestProblem types without redefining them.

Reuse core and its existing HTTP/Aeson/vector/containers/streamly dependencies. The package must not depend on baikai-openai or baikai-claude. `http-client` and any fixture dependencies must be located with Mori, inspected on disk, and checked against authoritative registry releases and upstream tags before setting bounds. Use canonical Mori references for durable cross-repository references; never traverse `/nix/store` or search `/`.
