---
id: 99
slug: add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core
title: "Add a provider-neutral judgment layer and judgment-only catalog facts to core"
kind: exec-plan
created_at: 2026-10-22T03:14:33Z
intention: "intention_01m3f2jkgpej3s8m0wpa7cw5nz"
master_plan: "docs/masterplans/14-support-typesafe-system-one-judgment-models.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-22T03:14:33Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T04:20:50Z
      mode: "update"
      note: "Fix question order: required-array order when complete, ascending key order otherwise"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T12:36:19Z
      mode: "implement"
      note: "Implement judgment catalog facts, schema compiler, refusal audit and neutral answer validation"
---

# Add a provider-neutral judgment layer and judgment-only catalog facts to core

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/ADR.md` when changing durable project context.


## Purpose / Big Picture

After this change a caller can ask the core package three things it cannot ask today, with no provider package installed and no network. First, whether a catalog model answers only declared judgments: `isJudgmentOnly` is true for the two TypeSafe aliases this plan adds to the generated catalog and false for every existing model, so a router can pick a judgment model without recognising a provider name. Second, what questions a JSON Schema declares: `compileJudgments` turns a closed-set schema (every allowed answer declared before the call) into an ordered list of neutral questions, or a typed refusal naming the offending schema path. Third, whether a set of provider answers is complete and well formed: `validateAnswers` turns neutral answers into exactly one `DataContent` block holding the chosen value, the probability of every declared answer and the provider's confidence, or a typed failure naming the field.

The layer is provider-neutral on purpose. TypeSafe's System One API and OpenAI's Decisions API are two dialects of the same idea (a yes/no question, a choice among labels, a score on ordered levels) with different wire layouts. Everything that does not depend on the wire lives here, so an adapter only maps neutral questions to its request and its answers back to neutral answers. The TypeSafe adapter in `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md` is the first consumer; an OpenAI Decisions adapter would be the second and is not part of this initiative.

This plan is a child of `docs/masterplans/14-support-typesafe-system-one-judgment-models.md` and implements the provider-neutral part of [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md) items 4 and 5. Its hard dependency is `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md`, which must be Complete first: it supplies `DataContent` (with its optional `confidence` map) and the `unsupportedFeature`/`unsupportedModel` error constructors this plan builds on. You can see the result working when `cabal test baikai:test:baikai-test` passes the new `JudgmentSpec` group and the catalog assertions described under Validation and Acceptance.


## Progress

- [x] Milestone 1: the `TypeSafeSystemOne` API tag, `OutputKind` with `isJudgmentOnly`, the `InputData` modality and the checked-in `typesafe.json` catalog are generated, round-trip through model JSON with a generative default, survive a fetch refresh, and every package in the workspace still builds with exhaustive matches.
- [x] Milestone 2: `Baikai.Judgment` compiles the fixture schema into three ordered judgments, refuses every unsupported schema shape and every explicit generation control by path, and `prepareJudgment` enforces the context shape; pure tests prove each rule.
- [x] Milestone 3: `validateAnswers` produces the fixture `DataContent` from neutral answers, rejects every malformed answer set by field, treats a refused answer as a provider refusal, and the changelog and the `JsonSchemaFormat` documentation describe the closed-set subset.


## Surprises & Discoveries

The existing generator emits models as updates from `emptyModel`, so adding `outputKind` does not require editing generated records before regeneration. The fetcher only refreshes its configured provider files; the TypeSafe file remains curated, and its renderer now preserves judgment output/data modality when such a catalog is rendered.


## Decision Log

- Decision: The judgment protocol lives in core as `Baikai.Judgment`, not in the TypeSafe package, and this plan owns it.
  Rationale: OpenAI's Decisions API (public beta since 2026-10-06; see the Surprises & Discoveries of `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md` for its wire shape) is a second dialect with the same three question kinds. Compiling the schema, auditing options and validating answers once in core means a second adapter adds only a wire mapping and transport. This carries plan 84's decision of 2026-10-21 into the plan that now owns the module; the 2026-10-22 split is recorded in the MasterPlan's Decision Log.
  Date: 2026-10-22

- Decision: Provider-reported confidence and expected score are preserved, never derived.
  Rationale: both known dialects return a per-answer confidence and a probability-weighted expected score for ordered questions. Deriving them locally would violate [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) and [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) and would make two adapters disagree about what a score field holds. The chosen value for a score is the provider's expected score when reported; the largest-probability level (ties to the lowest) is only a fallback for a dialect that reports none.
  Date: 2026-10-22

- Decision: The capability is a model and catalog fact (`OutputKind` on `Model`, carried by the generated catalog) with a generative default, read through the pure query `isJudgmentOnly`. It is never inferred from an API tag, a provider name or a `jev-` prefix.
  Rationale: [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md). A missing field in old model JSON must decode as generative so every existing serialized model keeps its meaning.
  Date: 2026-10-22

- Decision: Every explicit generation, sampling, reasoning, cache-retention, speed and tool-choice control is refused before dispatch; nothing is silently dropped or recorded as sent.
  Rationale: IR-10 permits refusal, no known judgment endpoint accepts these controls, and refusal keeps evidence truthful without a new adjustment protocol. The consumer handoff in the MasterPlan tells routing code to clear its generation defaults for judgment-only models.
  Date: 2026-10-22

- Decision: The neutral compiler passes instructions and descriptions through as JSON values and leaves dialect-specific content rules to adapters; the context-shape check, the options audit and the schema compiler run in that fixed order through `prepareJudgment`.
  Rationale: TypeSafe accepts string, object, array or null content while OpenAI accepts only strings, so the compiler cannot pick one rule. A single entry point with a fixed order means every adapter reports the same first error for the same bad request.
  Date: 2026-10-22

- Decision: Question order is the schema's `required` array order when that array lists every declared property exactly once, and ascending key order otherwise.
  Rationale: An aeson `Object` does not preserve the declaration order of its keys, so "schema property order" cannot be read from a `Value`. A caller that cares about order lists every property in `required` in declaration order, which the Shikumi consumer's derived schemas already do; a schema without a complete `required` gets a deterministic fallback. The consumer's parity test between its own schema reader and `compileJudgments` (`mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`) depends on this rule being stated.
  Date: 2026-10-22


## Outcomes & Retrospective

Completed 2026-10-25. The core suite passes all 826 tests, including nine judgment/catalog groups covering ordering, criteria, schema bounds and refusals, options/context checks, malformed and refused answers, provider-selected values and expected scores. A fetch-render → generator parse test preserves judgment/data facts. All workspace packages build with exhaustive matches; OpenAI 298, Claude 433, OpenTelemetry 11, effectful 4, kit 116, agent 116 and doc-shapes pass. Two successive `cabal run baikai-gen-models` executions produce identical bytes (`cmp`), and the generated-catalog gate passes after regeneration. ADR [0028](../adr/0028-judgments-are-a-provider-neutral-core-protocol.md) records ownership and validation policy; ADR 0009 records the catalog facts. No new friction was recorded under this child.


## Context and Orientation

The repository is a Cabal workspace with one directory per package, built inside the Nix development shell (`nix develop`). This plan changes only the core package in `baikai/`. The relevant modules are:

- `baikai/src/Baikai/Api.hs`: the `Api` sum type that names a provider dialect (`OpenAIChatCompletions`, `OpenAIResponses`, `AnthropicMessages`, two CLI tags and `Custom Text`), with `renderApi`, `parseApi` and `normaliseApi`. Every provider registry lookup keys on it, and its JSON form is the rendered text.
- `baikai/src/Baikai/Model.hs`: the `Model` record (`modelId`, `name`, `api`, `provider`, `baseUrl`, `reasoning`, `input :: [InputModality]`, `cost`, `contextWindow`, `maxOutputTokens`, `headers`, `compat` and pricing fields), `InputModality` (`InputText`, `InputImage`), the `emptyModel`/`mkModel` constructors, an explicit `Show` instance that redacts header values, and explicit JSON encoding and decoding with legacy optional fields.
- `baikai/data/models/*.json`: the curated catalog sources, one file per provider, each with `provider`, `baseUrl`, `api`, `compat` and a `models` array whose entries carry `id`, `name`, `reasoning`, `input` (spelled `text` and `image`), `cost`, `contextWindow`, `maxOutputTokens`, `compat` and `enabled`. `baikai/gen/GenModelsCore.hs` and `GenModels.hs` (the `baikai-gen-models` executable) turn them into `baikai/src/Baikai/Models/Generated.hs`; `baikai/fetch/FetchModelsCore.hs` (the `baikai-fetch-models` executable) refreshes facts from upstream while preserving curated ones; `baikai/test/CatalogSpec.hs` fails when the generated module drifts from its sources.
- `baikai/src/Baikai/Options.hs`: the per-call `Options` record. Generation controls are `maxTokens`, `temperature`, `topP`, `stopSequences` (a list, empty by default), `seed`, `frequencyPenalty`, `presencePenalty`, `thinking`, `cacheRetention`, `speed` and `toolChoice`. Transport and local fields are `timeoutMs`, `apiKey`, `headers`, `metadata`, `responseFormat` and `evidence`. Read the module for the constructors that mean "no preference" for `cacheRetention` and `speed`.
- `baikai/src/Baikai/ResponseFormat.hs`: `ResponseFormat` is `JsonSchema JsonSchemaFormat` or `JsonObject`; `JsonSchemaFormat` carries a name, `schema :: Value` and `strict :: Bool`. Its Haddock currently says Baikai never inspects the schema; this plan changes that for the closed-set subset.
- `baikai/src/Baikai/Context.hs` and `Message.hs`: `Context` has `systemPrompt`, `messages :: Vector Message` and `tools :: Vector Tool`; a `Message` is `UserMessage`, `AssistantMessage` or `ToolResultMessage`.
- `baikai/src/Baikai/Content.hs` and `Error.hs`: after plan 83, `DataContent` has `value :: Value`, `probabilities :: Maybe (Map Text (Map Text Double))`, `confidence :: Maybe (Map Text Double)` and `method :: Maybe Text`; `BaikaiError` carries an optional `RequestProblem` (`UnsupportedFeature path` or `UnsupportedModel id`) built by `unsupportedFeature` and `unsupportedModel`, both classified `InvalidRequest`. Error categories also include `ContentFiltered` (the provider refused content) and `DecodeFailure` (a reply could not be understood).
- `baikai/src/Baikai.hs`: the public re-export module. Plan 83 adds its names first; this plan appends `Baikai.Judgment`'s exports after them without reordering anything.

Terms. A judgment is a question whose every allowed answer is declared before the call. A predicate is a yes/no judgment (TypeSafe calls it "noul"). A choice selects one of a declared list of labels. A score picks one of 2 to 10 ordered levels numbered 0 to N-1. A closed-set schema is a JSON Schema object whose every top-level property is one of those three shapes. Jev is TypeSafe's judgment model family; System One is its HTTP dialect.

The protocol baseline for the TypeSafe dialect is its OpenAPI document version 0.2.0 (https://api.typesafe.ai/openapi.json); the limits used here (1 to 255 choice labels, 2 to 10 score levels) come from it. The OpenAI Decisions dialect (names `predicate`/`choice`/`score`, 2 to 255 choices, string-only instructions, per-question refusals) is summarised in the Surprises & Discoveries of `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md`; it shapes the neutral types but nothing here calls it.

ADRs that govern this work, all local: [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) and [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) (preserve what the provider reported; the adapter, not core, describes its translation), [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) (capability facts are catalog-owned), [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md) (documented examples compile) and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) (unknown prices are explicit, never zero-as-free). No ADR defines judgments; this plan creates one at completion. `docs/adr/` is a plain filesystem corpus (`mori.dhall` declares no OKF bundle for it), so a new record is `docs/adr/NNNN-slug.md` with `title`, `status` and `date` frontmatter, numbered after the highest existing record at the time of writing (0026 on 2026-10-22).


## Plan of Work

### Milestone 1 — Judgment-only catalog facts

Add `TypeSafeSystemOne` to `Api` in `baikai/src/Baikai/Api.hs`, rendered and parsed as `typesafe-system-one` and covered by `normaliseApi`. Then fix every match on `Api` across the workspace. Check the `ghc-options` of each package's Cabal file: the workspace treats incomplete patterns as errors, so `cabal build all` is the audit, and any package that does not must be checked with `-Wincomplete-patterns` explicitly. Where a match chooses an evidence-strength default or a structured-output support level per API tag, give the new tag the truthful value for a single non-streaming HTTP reply (the same observed-model ceiling the existing API tags use) rather than a stronger claim.

In `baikai/src/Baikai/Model.hs` add `data OutputKind = GenerativeOutput | JudgmentOutput`, the field `outputKind :: OutputKind` on `Model`, and `isJudgmentOnly :: Model -> Bool` (true exactly for `JudgmentOutput`). `emptyModel` and `mkModel` default to `GenerativeOutput`. Extend the explicit JSON codec: encode the field as `"outputKind": "generative"` or `"judgment"`, and decode a missing field as `GenerativeOutput` so every existing serialized model still parses. Extend the explicit `Show` instance without losing header redaction. Add `InputData` to `InputModality`; its catalog spelling is `data`, beside `text` and `image`, and its `Model` JSON form follows whatever the existing instance produces for the other two constructors.

Add `baikai/data/models/typesafe.json` with provider `typesafe`, base URL `https://api.typesafe.ai`, API `typesafe-system-one`, provider-level compat `auto`, and two enabled models, `jev-latest` and `jev-preview`, each with `reasoning` false, `input` `["text", "data"]`, `outputKind` `"judgment"`, and no invented facts: use the catalog's existing convention for an unknown price and an unknown limit (read `GenModelsCore.hs` and ADR 0020 for the pricing-unavailable basis) rather than values that would read as free or unlimited. Teach the generator to carry `outputKind` (absent means generative) and the `data` modality into `Generated.hs`, and the fetcher to preserve both so that refreshing another provider's catalog cannot drop this file or its facts. Regenerate with `cabal run baikai-gen-models`; a second run must produce no diff. Extend `baikai/test/CatalogSpec.hs` and the model JSON tests: both aliases are present and `isJudgmentOnly`, every pre-existing entry is not, a model JSON document without `outputKind` decodes as generative, one with `"judgment"` round-trips, and a fetch-preservation test keeps `outputKind` and `data`.

### Milestone 2 — Compiling judgments and refusing what judgment models cannot take

Create `baikai/src/Baikai/Judgment.hs`, exported through `baikai/src/Baikai.hs`, with these types. `JudgmentKind` is `PredicateJudgment (Maybe (Value, Value))` (the optional pair holds the true and false criteria descriptions), `ChoiceJudgment (Vector (Text, Maybe Value))` (labels in declared order with their descriptions) or `ScoreJudgment (Vector (Maybe Value))` (level descriptions in index order). `Judgment` is a record with `name :: Text`, `instructions :: Value` and `kind :: JudgmentKind`. `Judgments` is an abstract type holding the judgments in question order plus a name index; expose `judgmentList :: Judgments -> Vector Judgment` and `lookupJudgment :: Text -> Judgments -> Maybe Judgment`, and keep the constructor internal so an adapter cannot build an inconsistent value. Question order is the schema's `required` array order when that array lists every declared property exactly once, and ascending key order otherwise, because an aeson `Object` does not preserve the declaration order of its keys (see the Decision Log).

`compileJudgments :: JsonSchemaFormat -> Either BaikaiError Judgments` applies these rules, each failure an `unsupportedFeature` whose path starts at `Options.responseFormat.schema` (for example `Options.responseFormat.schema.properties.severity`). The schema must be an object with `"type": "object"` and a nonempty `properties` object. A property of `"type": "boolean"` compiles to a predicate without criteria. A property written as `anyOf` or `oneOf` of exactly a `const true` branch and a `const false` branch compiles to a predicate whose branch descriptions become the criteria. A nonempty, distinct string `enum`, or `anyOf`/`oneOf` of string `const` branches, compiles to a choice with 1 to 255 labels in declared order; an adapter whose dialect needs at least two labels applies that stricter bound itself. An integer `enum` or `const` branches whose values are exactly 0 to N-1 with N from 2 to 10 compiles to a score; the order is numeric regardless of the order in the schema, so an object-map ordering can never redefine it. Integer values must be integral JSON numbers; a boolean is not a number. Reject duplicates, mixed types, sparse or nonzero-based integer sets, free-form or nested properties (objects, arrays, open strings, numbers), empty properties, malformed branches and sizes outside the bounds, each by the offending path.

A property's `description` becomes `instructions` verbatim as a JSON value; an absent or null description becomes the property name as a JSON string. Branch descriptions become criteria values; a missing branch description is `Nothing`. Score descriptions form the level vector in index order; a missing or null description is `Nothing`, and an adapter that needs text falls back to the decimal level string. A description that is present but `false`, `0` or an empty structure is preserved, not treated as missing. The compiler does not stringify or reject non-string content, because the TypeSafe dialect accepts any JSON content while the OpenAI dialect accepts only strings, and that difference belongs to the adapter. Allow the annotations `title` and `description`, a `required` list naming only declared properties, and `additionalProperties: false`; every declared property is answered whether or not `required` lists it. Reject `$ref`, `allOf`, `not`, conflicting validation keywords on a property, a `required` entry that is not a declared property, and a permissive `additionalProperties`, rather than silently claiming to enforce them. The format's `strict` flag and name are local metadata and do not reach any wire.

`judgmentUserMessage :: Context -> Either BaikaiError Message` requires no system prompt (a supplied empty prompt is also refused, at `Context.systemPrompt`), exactly one message, which must be a `UserMessage` (`Context.messages` for the count, `Context.messages[0]` for the role), and no tools (`Context.tools`). It returns that message; part cardinality and part kinds inside it are adapter-owned, because the two dialects differ (TypeSafe takes exactly one text or data part; OpenAI takes several text and image parts).

`refuseGenerationControls :: Options -> Either BaikaiError ()` refuses, by field path such as `Options.temperature`, every explicit `maxTokens`, `temperature`, `topP`, nonempty `stopSequences`, `seed`, `frequencyPenalty`, `presencePenalty`, `thinking` and `toolChoice`, and every cache-retention or speed preference other than the module's "no preference" constructor, because no known judgment endpoint accepts them. `Nothing`, an empty `stopSequences` and the no-preference constructors mean absence and pass. `timeoutMs`, `apiKey`, `headers`, `metadata` and `evidence` are untouched; `metadata` stays local and is never copied into a wire body. The model's `maxOutputTokens` is catalog metadata and is never inserted into a request. This function is the one place a future adapter extends when a dialect gains a mappable control (OpenAI Decisions has its own prompt-cache fields); it is never bypassed.

`prepareJudgment :: Context -> Options -> Either BaikaiError (Message, Judgments)` runs `judgmentUserMessage`, then `refuseGenerationControls`, then requires `responseFormat` to be `Just (JsonSchema format)` (a missing format or `JsonObject` is refused at `Options.responseFormat`) and returns the message with `compileJudgments format`. Adapters call this before credential lookup or any connection, then apply their own part checks.

Tests for this milestone live in `baikai/test/JudgmentSpec.hs`, registered in `baikai/test/Main.hs` and `baikai/baikai.cabal`. Use the fixture schema from Validation and Acceptance and assert the three judgments in declared order with the exact instructions, criteria and level descriptions. Cover both predicate spellings, every rejection above with its path, the boundary sizes (1 and 255 labels accepted, 256 rejected; 2 and 10 levels accepted, 1 and 11 rejected), each generation control individually against otherwise valid options, and each context-shape failure. No test opens a socket or touches a provider package.

### Milestone 3 — Validating answers into one data block

Add `JudgmentAnswer` to `Baikai.Judgment`: `PredicateAnswer Double` (the probability of true), `ChoiceAnswer` with `selected :: Text`, `probabilities :: Map Text Double` and `confidence :: Maybe Double`, `ScoreAnswer` with `expected :: Maybe Double`, `probabilities :: Map Text Double` (keys are decimal level indices) and `confidence :: Maybe Double`, and `RefusedAnswer (Maybe Text)` carrying the provider's refusal category when it names one.

`validateAnswers :: Judgments -> Map Text JudgmentAnswer -> Either BaikaiError DataContent` enforces: the answer names equal the judgment names exactly (a missing or extra answer is a `DecodeFailure` naming the field); each answer's kind matches its judgment's kind; a choice or score distribution contains exactly the declared keys, no more and no fewer; every probability and confidence is finite and within 0 to 1 inclusive; a choice's `selected` is a declared label even when another label has a higher probability. It never checks that a distribution sums to one, and never normalizes, clamps or discards a key. A `RefusedAnswer` for any field fails as a provider refusal: the `ContentFiltered` category, the message naming the field, and `refusalCategory` set only to the category the provider gave. Adapters must validate bounds on their wire number representation before converting to `Double`; this validator checks the `Double` it receives again so that no adapter can forward infinity or a value outside the interval.

On success the result is exactly one `DataContent` with `method = Just "provider_classification"` (also exported as the constant `judgmentMethod`). Its `value` is an object with one key per judgment: a predicate yields `true` when its probability is at least 0.5, otherwise `false`; a choice yields the provider's selected label; a score yields the provider's expected score as a JSON number when reported, otherwise the largest-probability level as an integer with ties resolved to the lowest level. Its `probabilities` map holds, per field, `{"true": p, "false": 1 - p}` for a predicate and the provider's distribution for a choice or score. Its `confidence` map holds an entry for each choice or score answer whose confidence was reported, and none for predicates. Thresholds, cuts, weights and any further derivation remain consumer-owned.

Extend `JudgmentSpec.hs` with the fixture answers from Validation and Acceptance, every malformed-answer case, the refused-answer case, the chosen-value rules (a choice that is not the argmax, a score with and without an expected value, a tie), and a round trip of the produced `DataContent` through plan 83's content JSON codec. Then update the `JsonSchemaFormat` Haddock in `baikai/src/Baikai/ResponseFormat.hs` to say that generative providers pass the schema through untouched while judgment providers accept only the closed-set subset compiled by `Baikai.Judgment`, and add the core package's changelog entries under its unreleased section in `CHANGELOG.md`: the new `Api` constructor, `OutputKind`/`outputKind`/`isJudgmentOnly`, `InputData`, the two catalog aliases and the `Baikai.Judgment` module, noting that the `Api` constructor and the new `Model` field are major changes under the PVP. Final version numbers and bounds are chosen once by `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md`.

Before marking the plan Complete, write the ADR for the judgment layer (why the protocol lives in core, which parts are adapter-owned, why provider-reported confidence and expected score are preserved, and that the capability is a catalog fact with a generative default), and extend ADR 0009 if its subject already covers the new catalog field. Follow the plain `docs/adr/` convention described in Context and Orientation.


## Concrete Steps

Run from the repository root inside the development shell:

```bash
nix develop
cabal run baikai-gen-models
git diff --stat baikai/src/Baikai/Models/Generated.hs
cabal build all
cabal test baikai:test:baikai-test
cabal test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-trace-otel:test:baikai-trace-otel-test
cabal test baikai-effectful:test:baikai-effectful-test baikai-kit:test:baikai-kit-test baikai-agent:test:baikai-agent-test baikai-smoke:test:doc-shapes
cabal run baikai-gen-models && git diff --exit-code baikai/src/Baikai/Models/Generated.hs
```

The first generation run changes `Generated.hs` (two new aliases and the new fields); the last command proves a second run is a no-op. `cabal build all` must succeed with no incomplete-pattern warnings in any package after the `Api` and `InputModality` constructors are added. The core suite reports the new `JudgmentSpec` group and the extended catalog and model JSON assertions passing; the other suites prove that no provider, sink or adapter was left with a partial match. Do not run the live smoke suite (`baikai-smoke:test:baikai-smoke`) as part of this plan.

Commits use Conventional Commits with trailers for this plan, `docs/masterplans/14-support-typesafe-system-one-judgment-models.md` and the intention `intention_01m3f2jkgpej3s8m0wpa7cw5nz`.


## Validation and Acceptance

The fixture schema is the one the TypeSafe adapter and its loopback fixture use, so the two plans agree on the exact questions:

```json
{
  "type": "object",
  "properties": {
    "urgent": {"type": "boolean", "description": "Is service blocked?"},
    "category": {
      "description": "Classify the issue.",
      "anyOf": [
        {"const": "billing", "description": "Payment issue"},
        {"const": "technical", "description": "Product malfunction"}
      ]
    },
    "severity": {
      "description": "Rate impact.",
      "anyOf": [
        {"const": 0, "description": "Minor"},
        {"const": 1, "description": "Disruptive"},
        {"const": 2, "description": "Blocking"}
      ]
    }
  },
  "required": ["urgent", "category", "severity"],
  "additionalProperties": false
}
```

`compileJudgments` on it yields, in order, `urgent` as a predicate without criteria and instructions `"Is service blocked?"`, `category` as a choice with labels `billing` then `technical` and their descriptions, and `severity` as a score with levels `Minor`, `Disruptive`, `Blocking`. That order comes from `required`; with `required` removed, the same schema yields `category`, `severity`, `urgent`, in ascending key order, and a test asserts both. A second variant replaces `urgent` with `anyOf` of `{"const": true, "description": "Blocked"}` and `{"const": false, "description": "Degraded or fine"}` and yields a predicate whose criteria are those two strings.

The neutral fixture answers are `urgent` as `PredicateAnswer 0.83`, `category` as a `ChoiceAnswer` selecting `technical` with probabilities billing 0.2 and technical 0.7 and confidence 0.65, and `severity` as a `ScoreAnswer` with expected 1.5, probabilities 0.1, 0.3 and 0.6 for levels 0, 1 and 2, and confidence 0.55. `validateAnswers` must produce one `DataContent` whose value is `{"urgent": true, "category": "technical", "severity": 1.5}`, whose probabilities are `{"urgent": {"true": 0.83, "false": 0.17}, "category": {"billing": 0.2, "technical": 0.7}, "severity": {"0": 0.1, "1": 0.3, "2": 0.6}}` (compare the predicate's false entry as `1 - 0.83` computed in `Double`, not as a literal), whose confidence map is `{"category": 0.65, "severity": 0.55}`, and whose method is `provider_classification`. The choice total of 0.9 must pass unchanged.

Rejections to prove, each with the named path or field: a system prompt, zero and two messages, an assistant or tool-result message, tools, each generation control set individually, a non-default cache retention and speed, a missing response format and `JsonObject`, an empty `properties`, a free-form string property, a nested object, mixed-type branches, a sparse integer set `[0, 2]`, a one-based set `[1, 2, 3]`, duplicate labels, 256 labels, 1 and 11 levels, a `required` entry naming an undeclared property, `additionalProperties: true` and a `$ref`. Accepted boundaries: 1 and 255 labels, 2 and 10 levels, `required` absent. Malformed answer sets: a missing answer, an extra answer, a predicate answer for a choice question, a distribution missing a declared key or carrying an undeclared one, a selected label that is not declared, probabilities or confidences of `-0.1`, `1.1`, infinity and NaN, and a `RefusedAnswer` on one field while the others are valid (expect `ContentFiltered`, not `DecodeFailure`).

Catalog acceptance: `Baikai.Models.Generated` exposes `jev-latest` and `jev-preview` with API `TypeSafeSystemOne`, input `[InputText, InputData]`, `JudgmentOutput` and the catalog's unknown-pricing basis; `isJudgmentOnly` is true for both and false for every other generated model; and a `Model` encoded without `outputKind` decodes as `GenerativeOutput`.


## Idempotence and Recovery

Every step is additive and repeatable. Catalog changes live in `baikai/data/models/typesafe.json`; never hand-edit `Generated.hs`, regenerate it. Tests are pure and need no credentials or network. If the exhaustiveness audit reveals an `Api` match in a package this plan did not expect, fix it in this plan rather than leaving a wildcard; a wildcard would silently give the new tag another dialect's behaviour. Revert only this plan's edits if recovery is needed. No release, publication or data migration happens here.


## Interfaces and Dependencies

Public surface added by this plan, all in the core package: `Baikai.Api.TypeSafeSystemOne` (wire text `typesafe-system-one`); `Baikai.Model.OutputKind` (`GenerativeOutput`, `JudgmentOutput`), `Model.outputKind`, `isJudgmentOnly`, and `InputModality.InputData` (catalog spelling `data`); the two generated catalog aliases; and `Baikai.Judgment` exporting `JudgmentKind (..)`, `Judgment (..)`, `Judgments`, `judgmentList`, `lookupJudgment`, `compileJudgments`, `judgmentUserMessage`, `refuseGenerationControls`, `prepareJudgment`, `JudgmentAnswer (..)`, `validateAnswers` and `judgmentMethod`. `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md` consumes these names exactly and defines none of them; any later adapter does the same and extends only `refuseGenerationControls` when its dialect accepts a control.

Consumed from `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md`: `Baikai.Content.DataContent` with `value`, `probabilities`, `confidence` and `method`; `Baikai.Error.RequestProblem`, `unsupportedFeature` and `unsupportedModel`. This plan adds no Hackage dependency; it uses the core package's existing `aeson`, `containers`, `vector` and `text`. Before relying on an unfamiliar dependency API, locate its source with `mori registry search` and `mori registry show <project> --full` and read it on disk; never search `/nix/store` or the filesystem root.


## Revision Notes

2026-10-22: Fixed how `Judgments` recover question order from an aeson object (`required` order when complete, ascending key order otherwise), found while reconciling the Shikumi consumer's parity test with this plan. Milestone 2, Validation and Acceptance and the Decision Log carry the rule.
