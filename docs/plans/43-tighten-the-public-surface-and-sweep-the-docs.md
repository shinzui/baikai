---
id: 43
slug: tighten-the-public-surface-and-sweep-the-docs
title: "Tighten the public surface and sweep the docs"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Tighten the public surface and sweep the docs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This is the last plan of the master plan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md` (EP-10). It
makes the baikai library's public surface safe to freeze and makes the documentation
truthful about the behavior the earlier plans (EP-1 through EP-9) delivered. It implements
API design recommendations 5, 8, 12, 13, and 14 plus Theme 10 items 5 and 9 from the
review at `docs/reviews/correctness-and-api-review.md`.

After this change a downstream user gets four things they did not have before. First,
adding a field to `Options`, `Context`, `Model`, the compat records, the launch request,
or the CLI configs no longer breaks their build, because those records export selectors
and an empty base value instead of their data constructors — construction happens by
record update, which tolerates new fields. Second, the confusing `_Options`/`_Context`/
`_Model` names — which read as lens *prisms* to anyone using the `Control.Lens`
vocabulary that `Baikai.Prelude` itself re-exports — are renamed to `emptyOptions`,
`emptyContext`, `emptyModel` (and the rest of the `_X` family follows), with deprecated
aliases easing migration. Third, genuinely internal machinery (`mapRequest`, the
`ErrorClass` modules) lives under an `.Internal` namespace with an explicit
no-stability-guarantee note, and `Baikai.Prelude` is documented as a convenience module
outside the compatibility contract. Fourth, README.md and every file in `docs/user/`
describe the library as it actually behaves after this initiative — correct error types,
correct environment variable names, correct field types, no Hackage contradictions.

Along the way three small robustness holes are closed: an empty `data` array from an
embeddings endpoint returns a typed error instead of crashing on `V.head`, the model-fetch
tool's hand-rolled JSON escaping handles control characters, and the model-catalog
generator refuses to emit two Haskell bindings with the same sanitized name.

This plan is deliberately a breaking release boundary: it ships as a PVP major bump
(0.2.0.0 → 0.3.0.0 for the released packages) with full CHANGELOG.md entries. You can see
it working by building and testing everything (`cabal build all --enable-tests`,
`cabal test all`), building the haddocks (`cabal haddock baikai`), and observing in
`cabal repl baikai` that `:browse Baikai.Options` lists `emptyOptions` and the field
selectors but no `Options` data constructor.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

Milestone 1 — constructor export policy, renames, consistency nits:

- [x] Read the Decision Logs of `docs/plans/42-add-core-ergonomic-helpers-before-the-api-freeze.md` (hard dependency) and `docs/plans/34…41` (soft) and record in this plan's Decision Log the final names/locations of EP-9's helpers and any field additions that change the export lists below.
- [x] Hide the `Options` constructor and rename `_Options` → `emptyOptions` in `baikai/src/Baikai/Options.hs` (deprecated alias kept).
- [x] Hide the `Context` constructor, rename `_Context` → `emptyContext`, and add the lawful `Semigroup`/`Monoid` instances in `baikai/src/Baikai/Context.hs` (skip the instances if EP-9 already added them).
- [x] Hide the `Model` constructor, rename `_Model` → `emptyModel` and `_ModelCost` → `zeroModelCost`, and delete `unModel` in `baikai/src/Baikai/Model.hs`.
- [x] Hide the `OpenAICompletionsCompat` and `AnthropicMessagesCompat` constructors and rewrite the "intentionally public in baikai 0.1" haddock in `baikai/src/Baikai/Compat.hs`.
- [x] Hide the `InteractiveLaunchRequest` constructor, rename its `model` field to `modelId`, and rename `_InteractiveLaunchRequest`/`_InteractiveLaunchResult` to `interactiveLaunchRequest`/`interactiveLaunchResult` in `baikai/src/Baikai/Interactive.hs`.
- [x] Hide the four CLI/interactive config constructors and change their `extraArgs` fields from `Vector Text` to `[Text]` in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`, `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`, `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`.
- [x] Rename the remaining `_X` bases (`_Usage`, `_Cost`, `_CostBreakdown`, `_Response`, `_Tool`, `_TextContent`, `_ThinkingContent`, `_ToolCall`, `_ImageContent`, `_EmbeddingModel`) with deprecated aliases.
- [x] Change `latencyMs` from `Integer` to `Int` in `baikai/src/Baikai/Response.hs` and `baikai/src/Baikai/Trace/Event.hs` and sweep producers/consumers.
- [x] Update `baikai/gen/GenModels.hs` to emit record-update-style catalog entries and regenerate `baikai/src/Baikai/Models/Generated.hs`.
- [x] Sweep every in-repo use of the renamed values and hidden constructors (core src, `baikai/test`, `baikai-claude/test`, `baikai-openai/test`, `baikai-effectful/test`, `baikai-smoke/test`, `baikai-trace-otel/test`, `baikai-kit`) and get `cabal build all --enable-tests` and `cabal test all` green.
- [x] Add the surface-probe test module `baikai/test/SurfaceSpec.hs` and the documented repl check.

Milestone 2 — internal namespacing and Prelude/umbrella policy:

- [x] Rename `Baikai.Provider.Claude.ErrorClass` → `Baikai.Provider.Claude.Internal.ErrorClass` and `Baikai.Provider.OpenAI.ErrorClass` → `Baikai.Provider.OpenAI.Internal.ErrorClass`, updating both `.cabal` files and all imports.
- [x] Extract `mapRequest` (and its pure helper closure) into `Baikai.Provider.Claude.Internal.Request` and `Baikai.Provider.OpenAI.Internal.Request`; stop exporting `mapRequest` from the `Api` modules; update the request-mapping tests.
- [x] Add no-PVP-guarantees haddock headers to all four `.Internal.*` modules and strengthen the one on `baikai/src/Baikai/Provider/Cli/Internal.hs`.
- [x] Document `Baikai.Prelude` as convenience-only with no PVP guarantees in `baikai/src/Baikai/Prelude.hs`.
- [x] State the umbrella policy (what `Baikai` deliberately omits, and the constructor-export policy) in the haddock of `baikai/src/Baikai.hs`.
- [x] `cabal build all --enable-tests && cabal test all` green.

Milestone 3 — robustness cleanups:

- [x] Replace the partial `V.head` in `baikai/src/Baikai/Embedding.hs` with a total, typed-error path (`firstEmbedding`) and test the empty-vector case in `baikai/test/EmbeddingSpec.hs`.
- [x] Replace the hand-rolled `jsonString` in `baikai/fetch/FetchModelsCore.hs` with aeson-backed escaping and add a control-character round-trip test in `baikai/test/FetchModelsSpec.hs`.
- [x] Extract the pure generator core into `baikai/gen/GenModelsCore.hs` (fields renamed to drop the `gen` prefixes), add `checkIdentifierCollisions`, wire it into the generator `main`, and unit-test the collision case.
- [x] `cabal test all` green; `cabal run baikai-gen-models` produces an unchanged catalog.

Milestone 4 — documentation sweep, CHANGELOG, version bumps:

- [x] Fix every enumerated drift item in README.md and `docs/user/*.md` (list in Plan of Work, Milestone 4).
- [x] Sweep renamed values, hidden constructors, and post-fix behavior (EP-1..EP-9 outcomes) through every code snippet in README.md, `docs/user/*.md`, and `baikai-effectful/README.md`, spot-checking each snippet against the real export lists.
- [x] Write CHANGELOG.md entries and bump versions: baikai/baikai-claude/baikai-openai/baikai-effectful/baikai-trace-otel 0.2.0.0 → 0.3.0.0, baikai-kit 0.1.0.0 → 0.1.0.1; update all `baikai ^>=0.2.0` bounds to `^>=0.3.0`.
- [x] `cabal build all --enable-tests && cabal test all && cabal haddock baikai` all green; final grep sweeps clean.
- [x] Update the master plan's Progress section for the two EP-10 entries.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Fixing `AssistantPayload.timestamp` to `Maybe UTCTime` in EP-9 left one trace-otel
  fixture as `timestamp = read "2026-05-14 00:00:00 UTC"`. It compiled by inferring
  `read :: String -> Maybe UTCTime` and failed only at runtime during `cabal test all`.
  The fixture now uses `Just (read "2026-05-14 00:00:00 UTC")`.
- The documented constructor-hidden check must be run from a downstream-style target,
  not `cabal repl baikai`: the library REPL loads the defining modules and can display
  internal constructors. `printf 'import Baikai.Options\n:t Options\n:quit\n' | cabal repl
  baikai-test` rejects term-level `Options` as expected.
- Extracting request-shaping internals did not move all OpenAI compat lookups out of
  `Baikai.Provider.OpenAI.Api`: streaming response handling still needs
  `requiresThinkingAsText` while converting provider events into reasoning content.
  Only request-building helpers moved to `Baikai.Provider.OpenAI.Internal.Request`;
  stream-time response decoding stays in `Api`.
- Moving generator records from `genIdent`-style fields to unprefixed fields made
  `CatalogFile` and `GeneratedEntry` share selector names (`provider`, `api`, `baseUrl`,
  `compat`). The pure core uses `OverloadedRecordDot` (`c.provider`, `g.ident`) where
  needed so duplicate-record selectors remain explicit and warning-free.


## Decision Log

- Decision: EP-9 landed the helper surface in these final homes: `contextOf`,
  `systemUser`, `addUser`, `addMessage`, and `addResponse` in `Baikai.Context`;
  `flattenAssistantText` in `Baikai.Response`; `runToolLoop`, `runToolLoopWith`,
  `completeText`, `newProviderRegistryFrom`, and `assertRegistered` in
  `Baikai.Provider.Registry` and re-exported by `Baikai.Provider`;
  `streamRequestEach`, `streamRequestEachWith`, `streamRequestList`, and
  `streamRequestListWith` in `Baikai.Stream`; `ApiKeyEnvChain` in `Baikai.Auth`;
  `mkModel` in `Baikai.Model`; first-class provider values
  `claudeMessagesProvider`, `openaiChatProvider`,
  `claudeCliProvider :: ClaudeCliConfig -> ApiProvider`, and
  `codexCliProvider :: CodexCliConfig -> ApiProvider` in their provider modules.
  `Options` also now carries `topP`, `stopSequences`, `seed`, `frequencyPenalty`,
  and `presencePenalty`, and `unModel` has already been deleted.
  Rationale: the first EP-10 milestone changes export lists and constructor policy, so
  the prior plan's final public names must be treated as fixed inputs rather than
  re-decided while doing the surface sweep.
  Date: 2026-07-03
- Decision: Rename the *entire* `_X` empty-base family, not just the three names the
  review calls out. Final names: `emptyOptions`, `emptyContext`, `emptyModel`,
  `emptyResponse`, `emptyTool`, `emptyTextContent`, `emptyThinkingContent`,
  `emptyToolCall`, `emptyImageContent`, `emptyEmbeddingModel` for blank-slate bases;
  `zeroUsage`, `zeroCost`, `zeroCostBreakdown`, `zeroModelCost` for all-numeric-zero
  bases; `interactiveLaunchRequest`, `interactiveLaunchResult` for the two argument-taking
  smart constructors in `baikai/src/Baikai/Interactive.hs`.
  Rationale: the defect is the convention itself — `Baikai.Prelude` re-exports all of
  `Control.Lens`, where a leading-underscore capitalized name means a prism — so renaming
  three of sixteen would leave the library half-in, half-out of its own convention at the
  freeze boundary. The master plan's progress entry already says "`_X` renames applied".
  Date: 2026-07-01
- Decision: Use the `empty*`/`zero*` naming scheme, not `default*` and not a `Default`
  type class. Specifically `emptyOptions`, not `defaultOptions`.
  Rationale: `Data.Aeson` exports a value named `defaultOptions` that baikai's own source
  already uses in three modules (`baikai/src/Baikai/Usage.hs:35`,
  `baikai/src/Baikai/Content.hs:148`, `baikai/src/Baikai/Error.hs:74`); downstream users
  writing aeson instances routinely import `Data.Aeson` unqualified, so
  `defaultOptions` would be a permanent ambiguity trap. A `Default` class was rejected
  because it adds a dependency or an ad-hoc class for zero expressive gain and hides
  which fields are meaningful defaults versus placeholders. The compat records and CLI
  configs keep their existing `defaultOpenAICompletionsCompat`/`defaultClaudeCliConfig`
  style names: those values carry *meaningful* defaults (OpenAI's own behavior, the real
  executable name), not blank placeholders, and no clash exists.
  Date: 2026-07-01
- Decision: Keep deprecated aliases (`_Options = emptyOptions` etc., with `{-# DEPRECATED #-}`
  pragmas) for exactly this release; remove them in the next major version.
  Rationale: the release is already breaking (hidden constructors), but the aliases cost
  nothing, let downstream code migrate warning-driven instead of error-driven, and keep
  the in-repo diff reviewable. `unModel` is the exception — the review (rec 10) says to
  delete the shim before freeze, and EP-9 introduces `mkModel` as the sanctioned
  constructor, so `unModel` is deleted outright.
  Date: 2026-07-01
- Decision: Constructor export policy — stop exporting the data constructors of
  `Options`, `Context`, `Model`, `OpenAICompletionsCompat`, `AnthropicMessagesCompat`,
  `InteractiveLaunchRequest`, `ClaudeCliConfig`, `ClaudeInteractiveConfig`,
  `CodexCliConfig`, and `CodexInteractiveConfig`. Keep constructors exported for closed
  or provider-constructed shapes: `ToolCall`, the content records, `Response`, `Usage`,
  `Cost`, `ModelCost`, `InteractiveLaunchResult`, every event payload in
  `Baikai.Stream.Event`, and all sum types (`Api`, `Compat`, `InteractiveSafety`,
  `ThinkingFormat`, …).
  Rationale: the ten listed records are the ones expected to grow fields (the review
  calls them "evolvable"); the empty-base pattern already assumes construction by record
  update, so the constructor buys nothing except a silent downstream break on every field
  addition. `Response`/`Usage`/`Cost` must stay constructible because provider packages
  build them; sum types must stay matchable because dispatch and configuration pattern
  match on them.
  Date: 2026-07-01
- Decision: The generated catalog (`baikai/src/Baikai/Models/Generated.hs`) and the
  generator's own record building switch to record-update-on-base style
  (`emptyModel { … }`, `defaultOpenAICompletionsCompat { … }`) rather than keeping a
  constructor-exporting internal module.
  Rationale: with constructors hidden in their defining modules, *no* other module can
  use them — Haskell has no package-private export. Record update over the exported base
  values needs only selectors, keeps the generated file valid under the new policy, and
  makes generated code robust to future field additions for free.
  Date: 2026-07-01
- Decision: `Baikai.Prelude` stays a public, exposed module, documented as
  convenience-only with an explicit no-PVP-guarantees note, rather than being trimmed to
  named re-exports.
  Rationale: it is the project-wide prelude used by every internal module and advertised
  in the README; trimming `module Control.Lens` + `Data.Generics.Product`/`Sum` to a
  named list would churn every module and still track upstream names. The PVP hazard
  (upstream lens releases change the export set) is real but is honestly disclosed
  instead: applications wanting stability import `Control.Lens` themselves.
  Date: 2026-07-01
- Decision: The `Baikai` umbrella module keeps *omitting* `Baikai.Trace` (and
  `Baikai.Trace.Event`/`Baikai.Trace.Sink`), `Baikai.Embedding`, `Baikai.Cost.Log`,
  `Baikai.Cost.Pricing`, `Baikai.Provider.Registry`, `Baikai.Models.Generated`, and
  `Baikai.Prelude`, and now says so in its haddock.
  Rationale: tracing, embeddings, call-logging, and pricing lookups are opt-in
  subsystems with their own vocabularies; the generated catalog is huge; the registry's
  advanced surface is re-exported selectively through `Baikai.Provider`. Omission was
  already the de-facto state — the change is making the intent explicit (review rec 12).
  Date: 2026-07-01
- Decision: Internal namespacing — rename the two provider `ErrorClass` modules to
  `Baikai.Provider.Claude.Internal.ErrorClass` / `Baikai.Provider.OpenAI.Internal.ErrorClass`,
  and move `mapRequest` plus its pure request-shaping helpers into new
  `Baikai.Provider.Claude.Internal.Request` / `Baikai.Provider.OpenAI.Internal.Request`
  modules. `Baikai.Provider.Cli.Internal` keeps its existing name (it already sits under
  `.Internal`) and only gains a stronger haddock note.
  Rationale: rec 12 asks for an `.Internal` namespace with a no-guarantees note; the
  modules stay *exposed* (the providers' own test suites and the generator need them,
  and hiding them entirely would force test-suite gymnastics) but their names and
  haddocks now scream "not covered by PVP". Moving `mapRequest` into a module `Api.hs`
  imports (never the reverse) avoids import cycles.
  Date: 2026-07-01
- Decision: Consistency nits (rec 14) — `extraArgs` on the four vendor config records
  becomes `[Text]` (matching `InteractiveLaunchRequest.extraArgs`); `Model.input` stays
  `[InputModality]`; `extraDirs` stays `[FilePath]`; `InteractiveLaunchRequest.model` is
  renamed `modelId` (matching `Model.modelId` and `EmbeddingModel.modelId`);
  `Response.latencyMs` and the two `latencyMs` fields on `Baikai.Trace.Event.TraceEvent`
  become `Int` while `Options.timeoutMs` stays `Maybe Int`.
  Rationale: the rule adopted is "lists for caller-side configuration inputs, `Vector`
  for provider-bound message/content sequences" — config args are written by hand, where
  list literals are ergonomic, while message vectors are indexed and streamed. For
  millisecond values one machine type everywhere ends the `Int` vs `Integer` split;
  `Int` is safe because EP-5 clamps latency to non-negative wall-clock ms (consult
  `docs/plans/38-…`'s Decision Log) and 2^63 ms is ~292 million years.
  Date: 2026-07-01
- Decision: Lockstep version bump to 0.3.0.0 for baikai, baikai-claude, baikai-openai,
  baikai-effectful, and baikai-trace-otel; baikai-kit goes 0.1.0.0 → 0.1.0.1;
  baikai-smoke (never released) stays 0.1.0.0.
  Rationale: baikai's surface changes are PVP-major; the two provider packages rename
  exposed modules (major); effectful and trace-otel must raise their `baikai ^>=0.2.0`
  bound and the project has released the five packages in lockstep since 0.2.0.0.
  baikai-kit only raises a dependency bound (patch-level under PVP).
  Date: 2026-07-01
- Decision: The export-surface regression check is a compile-time "surface probe" test
  module plus a documented `cabal repl` transcript, not a golden text file of `:browse`
  output.
  Rationale: a golden `:browse` dump is brittle across GHC versions (formatting, kind
  signatures) and would fail for cosmetic reasons; a module that references every
  intended-public name fails compilation the moment a name drops, which is the actual
  regression we care about, and the repl check covers the "constructor is hidden"
  direction cheaply.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Milestones 1 and 2 leave the intended public API boundary in place: evolvable records
  construct through exported base values, provider request mappers and error
  classifiers are now under `.Internal` module names, and the umbrella/prelude haddocks
  state what is and is not covered by the compatibility promise. Validation for Milestone
  2 passed with `cabal build all --enable-tests` and
  `cabal test all --test-show-details=direct` before committing the slice.
- Milestone 3 removes three crash/drift hazards: embeddings now report an empty provider
  `data` array as `decodeError`, catalog JSON string escaping comes from aeson and
  round-trips control characters, and the model generator refuses sanitized Haskell
  binding collisions before rendering. Validation passed with
  `cabal build all --enable-tests`, `cabal run baikai-gen-models` with no
  `Baikai.Models.Generated` diff, and `cabal test all --test-show-details=direct`.
- Milestone 4 completes the public-surface release boundary: README and `docs/user/`
  use the new `empty*`/`zero*` names, describe in-band provider errors and real API-key
  variables, keep Hackage status truthful, and show selector imports for hidden config
  constructors. The release bookkeeping now records `baikai`/providers/effectful/trace
  at `0.3.0.0`, `baikai-kit` at `0.1.0.1`, and all released package bounds on
  `baikai ^>=0.3.0`. Final validation passed with `cabal build all --enable-tests`,
  `cabal test all --test-show-details=direct`, `cabal haddock baikai`, and the M4 grep
  sweeps.


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/baikai`) is a multi-package Haskell
project built with cabal (`cabal.project` at the root). The packages:

- `baikai/` — the core library. `baikai/src/Baikai.hs` is the *umbrella module* (a module
  that only re-exports other modules; importing `Baikai` gives users the whole intended
  surface). Types live one module per concept: `baikai/src/Baikai/Options.hs`,
  `Context.hs`, `Model.hs`, `Compat.hs`, `Interactive.hs`, `Response.hs`, `Usage.hs`,
  `Cost.hs`, `Content.hs`, `Tool.hs`, `Error.hs`, `Stream.hs`, `Stream/Event.hs`,
  `Trace.hs`, `Embedding.hs`, etc. `baikai/src/Baikai/Models/Generated.hs` is an
  AUTO-GENERATED model catalog produced by the executable in `baikai/gen/GenModels.hs`
  from JSON files under `baikai/data/models/`; `baikai/fetch/FetchModelsCore.hs` +
  `FetchModels.hs` fetch and render those JSON files. The test suite
  (`baikai/test/Main.hs` plus `*Spec.hs` modules; `hs-source-dirs: test fetch`) uses
  hspec.
- `baikai-claude/`, `baikai-openai/` — provider packages, each exposing four modules
  (`…Claude.Api`, `…Claude.Cli`, `…Claude.ErrorClass`, `…Claude.Interactive` and the
  OpenAI mirror). The `Api` modules currently export `mapRequest` (the pure
  request-shaping function) for tests.
- `baikai-effectful/` (effect binding), `baikai-trace-otel/` (OpenTelemetry sink),
  `baikai-kit/` (kit installer), `baikai-smoke/` (live smoke tests, never released).

Released versions today are 0.2.0.0 for baikai/-claude/-openai/-effectful/-trace-otel
and 0.1.0.0 for baikai-kit (see each `.cabal` file and the root `CHANGELOG.md`, which
follows Keep-a-Changelog with per-package headings).

Three conventions you must understand:

*The empty-base pattern.* Instead of constructing records positionally, callers start
from an exported base value and use record-update syntax:
`emptyOptions { maxTokens = Just 32 }` or, with the generic-lens labels that
`Baikai.Prelude` provides, `emptyOptions & #maxTokens .~ Just 32`. Today those base
values are named with a leading underscore (`_Options`, `_Context`, `_Model`,
`_Response`, `_Usage`, `_Cost`, `_CostBreakdown`, `_ModelCost`, `_Tool`, `_TextContent`,
`_ThinkingContent`, `_ToolCall`, `_ImageContent`, `_EmbeddingModel`,
`_InteractiveLaunchRequest`, `_InteractiveLaunchResult` — sixteen values, all defined at
the top level of their type's module). That naming collides with the lens *prism*
convention: in `Control.Lens` (which `baikai/src/Baikai/Prelude.hs` re-exports in full),
`_Just`, `_Left`, `_Cons` are prisms — first-class patterns — so `_Options` reads as "a
prism into Options", which it is not.

*PVP.* The Package Versioning Policy is Hackage's semantic-versioning contract: any
change that can break a downstream build (removing an export, changing a type) requires
a *major* version bump (the first two components, e.g. 0.2 → 0.3). Exporting a record's
data constructor means every field addition is such a break; exporting only selectors
and a base value means field additions are *minor* (0.3.0 → 0.3.1).

*Selector-only exports.* In a Haskell export list, `Options (..)` exports the type, its
constructor, and its fields. Writing `Options (maxTokens, temperature, …)` — the type
with an explicit field list — exports the type and those selectors but *not* the
constructor. Record update (`base { field = value }`) and generic-lens labels
(`#field`) keep working; record *construction* (`Options { … }`) and positional
application stop compiling outside the defining module. That is the whole mechanism this
plan uses. Note there is no package-private visibility in Haskell: if the defining
module hides a constructor, sibling modules in the same package lose it too — which is
why the generated catalog must switch to record-update style (see Decision Log).

Sibling plans. This plan hard-depends on
`docs/plans/42-add-core-ergonomic-helpers-before-the-api-freeze.md` (EP-9), which adds
helpers including (per the review, recs 2, 3, 6, 7, 9, 10) `runToolLoop`, `contextOf`,
`addUser`, `addResponse`, `completeText`, an exported `flattenAssistantText`,
streamly-free streaming entry points, `assertRegistered`, `ApiKeyEnvChain`, and
`mkModel`. **The exact final names and module homes are decided in that plan — before
starting Milestone 1, read plan 42's Decision Log and adjust every mention of those
helpers in this plan's sweeps.** It soft-depends on EP-1..EP-8
(`docs/plans/34-…` through `41-…`): the documentation sweep in Milestone 4 must describe
their *post-fix* behavior (in-band error contract with `responseError`, working thinking
replay, implemented-or-deleted compat flags, wired `timeoutMs`, hardened CLI arguments).
Where this plan states post-fix behavior it cites the owning plan; if an owning plan
changed course, its Decision Log wins and this plan must be revised.

The review that defines this plan's scope is
`docs/reviews/correctness-and-api-review.md` — recommendations 5
(constructor exports), 8 (`_X` renames), 12 (export hygiene), 13 (doc drift), 14
(consistency nits), and Theme 10 items 5 (`baikai/src/Baikai/Embedding.hs:95` partial
`V.head`) and 9 (`baikai/fetch/FetchModelsCore.hs:522-524` JSON escaping;
`baikai/gen/GenModels.hs:336-360` no identifier-collision check).

One repository rule to honor throughout: record fields must never carry Hungarian-style
prefixes, even on internal records. The generator's `GeneratedEntry` record currently
violates this (`genIdent`, `genModelId`, …); Milestone 3 moves that record and renames
its fields (`ident`, `modelId`, …) while doing so. `DuplicateRecordFields` is already a
default extension in every package's `common-options`, so bare field names cannot clash.


## Plan of Work

The work is four milestones. Milestones 1–3 each leave the whole project building and
green (`cabal build all --enable-tests && cabal test all` from the repo root); Milestone 4
finishes with the haddock proof and release bookkeeping. All file paths below are
repository-relative; run all commands from `/Users/shinzui/Keikaku/bokuno/baikai`.


### Milestone 1 — Constructor export policy, `_X` renames, and consistency nits

Scope: every breaking *shape* change to the surface lands here, in one pass, so the rest
of the plan (and the CHANGELOG) describes a single coherent new surface. At the end,
the ten evolvable records no longer export constructors, every `_X` base value has its
new name (old names remain as deprecated aliases), the rec-14 type unifications are
done, and the entire repo — including tests, smoke tests, and the generated catalog —
compiles and passes tests against the new surface.

First, do the cross-plan reconciliation: read the Decision Log of
`docs/plans/42-add-core-ergonomic-helpers-before-the-api-freeze.md`. Note (a) the final
names of its helpers and which modules export them, (b) whether it already gave
`Context` a `Semigroup`/`Monoid`, (c) whether it already deleted `unModel` and/or added
fields to `Options` (the review's rec 11 — `topP`, `stopSequences`, `seed` — may or may
not have landed there). Record what you find in this plan's Decision Log and fold any
new `Options`/`Context` fields into the export lists you are about to write.

**Export-list changes, module by module.** For each record, change the export from
`T (..)` to `T (field1, field2, …)` (type plus explicit selectors, no constructor),
enumerate *every field present at implementation time*, and add a short haddock note on
the type stating the policy. The note, adapted per record:

```haskell
-- | Construction: this record's constructor is deliberately not
-- exported. Start from 'emptyOptions' and use record-update syntax
-- (or the @#field@ lenses from "Baikai.Prelude"). This lets baikai
-- add fields in /minor/ releases without breaking downstream code.
```

1. `baikai/src/Baikai/Options.hs` — export
   `Options (maxTokens, temperature, apiKey, timeoutMs, headers, metadata, toolChoice, cacheRetention, thinking, responseFormat)`
   (plus any EP-8/EP-9-era fields), `emptyOptions`, and the deprecated `_Options`.
2. `baikai/src/Baikai/Context.hs` — export
   `Context (systemPrompt, messages, tools)`, `emptyContext`, deprecated `_Context`,
   and the existing `appendToolResult`/`appendToolResultText` (plus whatever EP-9 put
   here). If EP-9 did not already do it, add the lawful instances:

   ```haskell
   instance Semigroup Context where
     a <> b =
       Context
         { systemPrompt = systemPrompt a <|> systemPrompt b,
           messages = messages a <> messages b,
           tools = tools a <> tools b
         }

   instance Monoid Context where
     mempty = emptyContext
   ```

   (`<|>` on `Maybe` is left-biased, so `emptyContext` is a two-sided identity and the
   operation is associative — a lawful Monoid. Inside the defining module the
   constructor is still available.)
3. `baikai/src/Baikai/Model.hs` — export
   `Model (modelId, name, api, provider, baseUrl, reasoning, input, cost, contextWindow, maxOutputTokens, headers, compat)`,
   `emptyModel`, `zeroModelCost`, deprecated `_Model`/`_ModelCost`; keep
   `ModelCost (..)`, `InputModality (..)`, `Compat (..)`,
   `openaiCompletionsCompatFor`, `anthropicMessagesCompatFor` exported with
   constructors (see Decision Log). Delete `unModel` and its haddock mention (the
   module header's "preserved as a convenience" sentence goes too).
4. `baikai/src/Baikai/Compat.hs` — export the two records selector-only
   (`OpenAICompletionsCompat (maxTokensField, supportsDeveloperRole, supportsStrictMode, requiresThinkingAsText, thinkingFormat, …)`
   and the `AnthropicMessagesCompat` equivalent — enumerate the fields as they exist
   after EP-8, which may have deleted some). Keep `defaultOpenAICompletionsCompat`,
   `defaultAnthropicMessagesCompat`, the enum types with constructors, and the
   auto-detect functions. Rewrite the module-header paragraph that currently says
   "These record constructors are intentionally public in baikai 0.1" to state the new
   policy (start from the `default*` values, record-update the diffs).
5. `baikai/src/Baikai/Interactive.hs` — export
   `InteractiveLaunchRequest (systemPrompt, userPrompt, modelId, workingDir, extraDirs, safety, extraArgs)`
   selector-only (note the `model` → `modelId` field rename happens here), keep
   `InteractiveLaunchResult (..)` and all sum types with constructors, rename
   `_InteractiveLaunchRequest` → `interactiveLaunchRequest` and
   `_InteractiveLaunchResult` → `interactiveLaunchResult` (deprecated aliases for both).
6. `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` — `ClaudeCliConfig` selector-only;
   change `extraArgs :: !(Vector Text)` to `extraArgs :: ![Text]` and update the launch
   site (`Vector.toList` disappears at line ~171). `defaultClaudeCliConfig` stays.
7. `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` — `ClaudeInteractiveConfig`
   selector-only; `extraArgs` to `[Text]`.
8. `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` — `CodexCliConfig` selector-only;
   `extraArgs` to `[Text]`.
9. `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` — `CodexInteractiveConfig`
   selector-only; `extraArgs` to `[Text]`.

**The rename sweep.** In each defining module, rename the base value and keep the old
name as a deprecated alias next to it:

```haskell
-- | The all-@Nothing@/empty 'Options' — the record-update base.
emptyOptions :: Options
emptyOptions = Options { maxTokens = Nothing, … }

{-# DEPRECATED _Options "Use emptyOptions. The _X names collide with the lens prism convention re-exported by Baikai.Prelude; the aliases will be removed in the next major release." #-}
_Options :: Options
_Options = emptyOptions
```

The full rename map (defining files): `_Options` → `emptyOptions`
(`baikai/src/Baikai/Options.hs`); `_Context` → `emptyContext` (`Context.hs`); `_Model` →
`emptyModel` and `_ModelCost` → `zeroModelCost` (`Model.hs`); `_Response` →
`emptyResponse` (`Response.hs`); `_Usage` → `zeroUsage` (`Usage.hs`); `_Cost` →
`zeroCost` and `_CostBreakdown` → `zeroCostBreakdown` (`Cost.hs`); `_Tool` → `emptyTool`
(`Tool.hs`); `_TextContent` → `emptyTextContent`, `_ThinkingContent` →
`emptyThinkingContent`, `_ToolCall` → `emptyToolCall`, `_ImageContent` →
`emptyImageContent` (`Content.hs`); `_EmbeddingModel` → `emptyEmbeddingModel`
(`Embedding.hs`); `_InteractiveLaunchRequest` → `interactiveLaunchRequest`,
`_InteractiveLaunchResult` → `interactiveLaunchResult` (`Interactive.hs`). The naming
rule: `empty*` when the base's fields are empty containers and `Nothing`s, `zero*` when
they are numeric zeros, plain camelCase for the two that take arguments (they are smart
constructors, not bases). Update all *internal* uses to the new names so the deprecation
warnings don't trip `-Wall` builds of the library itself — known internal users include
`baikai/src/Baikai/Cost/Pricing.hs`, `baikai/src/Baikai/Response.hs`, both provider
`Api.hs` files (they import `_Cost`), and `baikai/src/Baikai/Embedding.hs`'s
`openAIEmbeddingModel`. Then sweep the test suites listed in Progress; the earlier
survey found `_X` uses in `baikai/test/{Main,CostSpec,ErrorInfoSpec,TraceSpec}.hs`,
`baikai-claude/test/Main.hs`, `baikai-openai/test/Main.hs`,
`baikai-effectful/test/{LiveSpec,StubProvider}.hs`, `baikai-smoke/test/{Smoke,
MultiHostSmoke,StructuredSmoke,ToolsSmoke}.hs`, and `baikai-trace-otel/test/Main.hs`.
`baikai-kit` had no hits, but verify with the grep in Concrete Steps.

**Millisecond unification.** Change `latencyMs :: !Integer` to `latencyMs :: !Int` in
`baikai/src/Baikai/Response.hs` (line ~40) and in both `CallFinished` and `CallFailed`
payloads of `baikai/src/Baikai/Trace/Event.hs` (lines ~54 and ~64). Fix the producers —
the latency computation in `baikai/src/Baikai/Stream.hs` (EP-5 clamps it non-negative;
use `fromIntegral`/`min` so the `Int` conversion is total) and the plumbing in
`baikai/src/Baikai/Trace.hs` — and the consumers: `baikai/src/Baikai/Trace/Sink.hs`,
`baikai/src/Baikai/Cost/Log.hs` if it touches latency, and
`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` (its
`fromIntegral latencyMs :: Int` keeps compiling but the annotation becomes redundant —
tidy it). `Options.timeoutMs` stays `Maybe Int`; `Model.input` stays `[InputModality]`;
`extraDirs` stays `[FilePath]` (decisions recorded in the Decision Log).

**Generator and generated catalog.** `baikai/src/Baikai/Models/Generated.hs` currently
constructs `Model { … }` and compat records positionally with constructors this
milestone hides. Edit the renderer in `baikai/gen/GenModels.hs` (the `renderModule`
region) to emit record updates on the exported bases instead — an entry becomes:

```haskell
anthropic_claude_fable_5 :: Model
anthropic_claude_fable_5 =
  emptyModel
    { modelId = "claude-fable-5"
    , name = "Claude Fable 5"
    , …
    , cost = ModelCost { inputCost = 10 % 1, … }
    , compat = CompatNone
    }
```

(`ModelCost` keeps its constructor so its rendering can stay as-is.) Compat overrides
render as `CompatOpenAICompletions (defaultOpenAICompletionsCompat { … changed fields … })`.
The generator's own catalog-JSON parsers (`parseOpenAICompat`/`parseAnthropicCompat`,
around lines 181–215) also construct the compat records — rewrite them as updates on
`defaultOpenAICompletionsCompat`/`defaultAnthropicMessagesCompat` (a local `d` is
already in scope there). Update the generated import list accordingly (`emptyModel`
instead of `Model (..)`, etc.), run `cabal run baikai-gen-models`, and commit the
regenerated `baikai/src/Baikai/Models/Generated.hs`. The values must be semantically
identical — `baikai/test/CatalogSpec.hs` passing unchanged is the proof.

**Surface probe.** Add `baikai/test/SurfaceSpec.hs` (register it in `baikai/test/Main.hs`
and the `other-modules` of the `baikai-test` stanza in `baikai/baikai.cabal`): a module
that imports `Baikai` (and `Baikai.Trace`, `Baikai.Embedding` directly) and mentions
every intended-public name this plan touches — the new base values, the selectors via a
record update on each of the ten records, `interactiveLaunchRequest`, and EP-9's helpers
— in trivially-true hspec assertions (e.g. building `emptyOptions { maxTokens = Just 1 }`
and asserting on the field). Its compilation *is* the test: if a name drops out of the
surface, `cabal build baikai:test:baikai-test` fails. The "constructors are hidden"
direction is checked manually with the repl transcript in Validation.

Acceptance for Milestone 1: `cabal build all --enable-tests` and `cabal test all`
succeed; `git grep -n "_Options\|_Context\b\|_Model\b"` (and the rest of the rename map)
hits only the deprecated alias definitions and CHANGELOG/plan documents; the repl check
shows no constructor for `Baikai.Options`.


### Milestone 2 — Internal namespacing, Prelude policy, umbrella statement

Scope: rec 12. At the end, everything a user should not depend on either lives under an
`.Internal` module name or carries an explicit no-guarantees haddock, and `Baikai.hs`
states what it deliberately omits.

In `baikai-claude`: `git mv src/Baikai/Provider/Claude/ErrorClass.hs
src/Baikai/Provider/Claude/Internal/ErrorClass.hs`, change its `module` line, and update
the `exposed-modules` list in `baikai-claude/baikai-claude.cabal` and every import
(`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, `Cli.hs` if it imports it, and the
test suite). Then create `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`
and move `mapRequest` there together with the pure helpers only it uses (identify the
closure at implementation time — EP-7 and EP-8 both reshaped `mapRequest`; helpers
shared with response mapping move too, and `Api.hs` imports them back — the dependency
must point only from `Api.hs` to `Internal.Request`, never the reverse). Remove
`mapRequest` from `Api.hs`'s export list; the request-mapping tests in
`baikai-claude/test/` now import `Baikai.Provider.Claude.Internal.Request`. Mirror all
of this in `baikai-openai` (`Baikai.Provider.OpenAI.Internal.ErrorClass`,
`Baikai.Provider.OpenAI.Internal.Request`). Every `.Internal.*` module gets this header:

```haskell
-- | __Internal module — no stability guarantees.__ This module is
-- exposed so baikai's own test suites and sibling packages can reach
-- it, but it is not part of the public API: its contents may change
-- in /any/ release without a PVP major bump. Do not import it from
-- application code.
```

`baikai/src/Baikai/Provider/Cli/Internal.hs` already sits under an `.Internal` name;
replace its softer "should not be relied on" sentence with the same explicit block.

`baikai/src/Baikai/Prelude.hs`: extend the module haddock to state that the module is a
convenience prelude whose export set tracks `lens` and `generic-lens` upstream and is
therefore *outside* baikai's PVP contract; applications that want a stable import
surface should import `Control.Lens`/`Data.Generics.Product` themselves. (Decision Log:
kept public, not trimmed.)

`baikai/src/Baikai.hs`: extend the module haddock with two short paragraphs — (1) the
constructor-export policy (evolvable records are built by record update on `empty*`
bases; constructors of closed shapes remain exported), (2) the deliberate omissions:
`Baikai.Trace`/`Baikai.Trace.Event`/`Baikai.Trace.Sink` (opt-in tracing),
`Baikai.Embedding` (opt-in embeddings client), `Baikai.Cost.Log` and
`Baikai.Cost.Pricing` (opt-in accounting), `Baikai.Provider.Registry` (advanced surface,
partially re-exported via `Baikai.Provider`), `Baikai.Models.Generated` (import
explicitly for the catalog), and `Baikai.Prelude` (convenience only). Verify EP-9 did
not add helper modules that *should* be in the umbrella — if it did (per plan 42's
Decision Log), add them to the export list here.

Acceptance: `cabal build all --enable-tests && cabal test all` green;
`git grep -n "Provider.Claude.ErrorClass\|Provider.OpenAI.ErrorClass"` finds only
CHANGELOG/plan mentions; importing `Baikai.Provider.Claude.Api (mapRequest)` in the repl
fails with an out-of-scope error while
`Baikai.Provider.Claude.Internal.Request (mapRequest)` succeeds.


### Milestone 3 — Robustness cleanups (review Theme 10, items 5 and 9)

Scope: three small correctness fixes, each with a test that fails before and passes
after.

**Embedding empty-data crash.** In `baikai/src/Baikai/Embedding.hs` the SDK call returns
a `Vector` of embedding objects and the code takes `V.head` (line ~95) — a *partial*
function that crashes the process if a host returns an empty `data` array. Add a pure,
exported, testable function and use it on both paths:

```haskell
-- | Total accessor for the first embedding in a response. A host that
-- returns an empty @data@ array yields a typed 'BaikaiError'
-- ('Baikai.Error.decodeError') instead of a 'V.head' crash.
firstEmbedding :: Vector Emb.Embedding -> Either BaikaiError (Vector Double)
firstEmbedding objs = case objs V.!? 0 of
  Nothing -> Left (decodeError "embeddings response contained no data")
  Just e -> Right (Emb.embedding e)
```

`embedText` becomes `either throwIO pure . firstEmbedding =<< create (mkEmbeddingRequest m t)`
(import `Control.Exception (throwIO)` and `Baikai.Error (BaikaiError, decodeError)`;
throwing matches the module's documented behavior of letting transport exceptions
propagate). `embedOne` replaces its own `V.head` with the same `V.!? 0`-plus-`throwIO`
guard (unreachable by construction, but total). Export `firstEmbedding` and add a case
to `baikai/test/EmbeddingSpec.hs`: `firstEmbedding V.empty` is `Left` with an error
whose category is `DecodeFailure` (no SDK record needs constructing for the empty case).

**Fetcher JSON escaping.** `jsonString` in `baikai/fetch/FetchModelsCore.hs` (lines
~522-524) escapes only backslash and double-quote; a model name containing a control
character (or a newline) would emit invalid JSON into the catalog files. Replace the
hand-rolled version with aeson's own encoder:

```haskell
jsonString :: Text -> Text
jsonString = TL.toStrict . Aeson.encodeToLazyText
```

using `Data.Aeson.Text (encodeToLazyText)` and `Data.Text.Lazy qualified as TL` (aeson
and text are already dependencies of both the executable and the test suite). Add a
test to `baikai/test/FetchModelsSpec.hs`: for an adversarial input such as
`"a\"b\\c\nd\x01e"`, `Aeson.decode (encodeUtf8 (fromStrict (jsonString s)))` returns
`Just s` — i.e. the rendered literal is valid JSON that round-trips.

**Generator identifier collisions.** `sanitizeIdentifier` in `baikai/gen/GenModels.hs`
(lines ~336-360) maps every non-identifier character to `_`, so two distinct model ids
(e.g. `provider/a.b` and `provider/a-b`) can sanitize to the same Haskell binding, and
the generated module would silently shadow one model with another. The generator's main
module is `module Main`, which cannot be imported by tests, so first extract the pure
core: create `baikai/gen/GenModelsCore.hs` (`module GenModelsCore`) and move
`GeneratedEntry`, `flattenEntries`, `sanitizeIdentifier`, and the catalog-record types
they need into it; while moving, rename `GeneratedEntry`'s fields to drop the
Hungarian `gen` prefixes (`ident`, `modelId`, `name`, `api`, `provider`, `baseUrl`,
`reasoning`, `input`, `cost`, `contextWindow`, `maxOutputTokens`, `compat`) — the
repository rule forbids prefixed record fields, and `DuplicateRecordFields` is already
on. Add the check:

```haskell
-- | Fail when two catalog entries sanitize to the same Haskell
-- identifier. Returns the entries unchanged when all names are unique.
checkIdentifierCollisions ::
  [(Text, GeneratedEntry)] -> Either Text [(Text, GeneratedEntry)]
```

which groups the full (all catalog files, concatenated) entry list by identifier and,
on any duplicate, returns a `Left` naming the identifier and each colliding
(provider, model id) pair. In `GenModels.hs`'s `main`, run the check on the complete
entry list immediately before rendering and die (`exitFailure` after printing the
message to stderr) on `Left`. Update `baikai/baikai.cabal`: the `baikai-gen-models`
executable gains `other-modules: GenModelsCore`; the `baikai-test` stanza's
`hs-source-dirs` gains `gen` (alongside `test fetch`) and its `other-modules` gains
`GenModelsCore` (add any missing `build-depends` the moved code needs, e.g.
`scientific`). Add `baikai/test/GenModelsSpec.hs` (register in `Main.hs` and the cabal
stanza) testing that two synthetic entries whose ids sanitize identically produce a
`Left` mentioning both model ids, and that distinct ids pass through as `Right`.

Acceptance: `cabal test all` green with the three new/extended specs;
`cabal run baikai-gen-models` still succeeds and leaves
`baikai/src/Baikai/Models/Generated.hs` unchanged (`git diff --stat` empty for it).


### Milestone 4 — Documentation sweep, CHANGELOG, version bumps

Scope: make every user-facing document truthful about the post-initiative library, and
do the release bookkeeping that marks this plan's breaking boundary.

The known drift items (review rec 13 plus items found while surveying; brevity would
suffer in prose, hence the list — each item is "fix and then re-read the surrounding
section for collateral staleness"):

- `README.md:109` — "an unregistered tag throws `ProviderError`". Post-EP-6
  (`docs/plans/39-…`), unregistered dispatch reports *in-band*: `completeRequest`
  returns a `Response` with `stopReason = ErrorReason` and `errorInfo = Just e` where
  `e`'s category is `ProviderUnavailable`; `responseError` extracts it. Rewrite here and
  wherever the "throws" phrasing recurs.
- `docs/user/getting-started.md:72` — same `ProviderError` claim; same fix.
- `docs/user/models-and-providers.md:204` — same claim ("Unregistered tag ->
  `Baikai.Error.ProviderError`"); same fix.
- `docs/user/getting-started.md:106-110` — claims key fallback reads `OPENAI_KEY` and
  `ANTHROPIC_KEY`; the real variables are `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`
  (see the provider haddocks in `baikai-{openai,claude}/src/…/Api.hs`). If EP-9's
  `ApiKeyEnvChain` landed, document the chain mechanism instead of inventing fallback
  names (consult plan 42's Decision Log).
- `docs/user/streaming.md:106` — shows `latencyMs :: !Int`; after Milestone 1 this is
  *correct* — verify rather than change, and confirm the surrounding record listing
  matches `baikai/src/Baikai/Response.hs` field-for-field (including `errorInfo` and
  the EP-5 `responseId` carriage).
- `docs/user/cli-providers.md:162-171` — describes `latencyMs` (fine) but names the
  pre-0.2 error constructors `DecodeError msg`/`ProviderError msg`; rewrite in terms of
  the categorised `BaikaiError` (`decodeError`/`processError` smart constructors,
  `errorInfo` in-band per EP-6).
- `README.md:59-65` — the package table's "Hackage" column says "published";
  `README.md:132` says "The core packages are being published to Hackage. Once
  available:", while `docs/user/getting-started.md:26` says "baikai is not yet on
  Hackage". The master plan rules Hackage publishing out of scope, so standardize on
  *not yet published*: change the table column values to "not yet", rewrite the Install
  section to lead with the `cabal.project` `source-repository-package` instructions that
  getting-started already shows, and keep the `build-depends` block as "once published".
- `docs/user/models-and-providers.md:117` — "are public 0.1 API" describing the compat
  records: now wrong twice (version is 0.3, constructors are hidden). Rewrite to state
  the record-update-on-`default*` construction story.
- `docs/user/streaming.md:135` — "`AssistantMessageEvent` is a closed 0.1 API": make the
  claim version-neutral ("a closed API: the constructor list only grows in major
  releases") and check the constructor list against post-EP-5
  `baikai/src/Baikai/Stream/Event.hs` (thinking signatures, redacted payloads,
  response-id carriage).
- `baikai-effectful/README.md:10` — "the blocking path throws
  `Baikai.Error.BaikaiError`": false for API providers post-EP-6 (in-band contract).
  Align with the wording EP-6 put on `baikai-effectful/src/Baikai/Effectful.hs`.

Beyond the enumerated items, do the *systematic* sweep. For each of `README.md`,
`docs/user/getting-started.md`, `models-and-providers.md`, `streaming.md`, `tools.md`,
`cli-providers.md`, `interactive-launches.md`, `agent-assets.md`, `kit.md`, and
`baikai-effectful/README.md`: (1) replace every `_Options`/`_Context`/`_Model`/other
`_X` mention with the new names (the survey counted 24 occurrences across README,
getting-started, models-and-providers, cli-providers, and tools); (2) update
`interactive-launches.md`'s snippets for the `model` → `modelId` field rename (lines
~29 and ~58) and the `[Text]` `extraArgs`; (3) spot-check every Haskell code fence
against the real surface — for each snippet, confirm every identifier it uses is
exported from the module the prose implies (open the module's export list; for umbrella
users that means `baikai/src/Baikai.hs`'s re-export closure), that no snippet constructs
a hidden-constructor record positionally, and that EP-9's helpers are called by their
final names (`flattenAssistantText` is advertised in README and getting-started — EP-9
exports it; verify the import path); (4) check behavioral claims against EP-1..EP-8
outcomes — thinking works with default options (EP-7), compat flags are real (EP-8),
`timeoutMs` bounds a stalled stream (EP-8), CLI providers survive `-`-prefixed prompts
(EP-3) — consulting each plan's Decision Log rather than assuming this plan's summary
is current.

**CHANGELOG and versions.** In `CHANGELOG.md` add, above the 0.2.0.0 entries, a
`[baikai 0.3.0.0]` section with Added (new `empty*`/`zero*` names as the documented
construction story; `firstEmbedding`), Changed-with-**Breaking** markers (constructors
of the ten records no longer exported; `_X` values deprecated in favor of the new
names; `unModel` deleted; `InteractiveLaunchRequest.model` renamed `modelId`;
`latencyMs` now `Int`; `extraArgs` now `[Text]`; `Baikai.Prelude` and the `.Internal`
modules excluded from the PVP contract), and Fixed (embedding empty-`data` typed error;
fetcher JSON escaping; generator collision check). Add `[baikai-claude 0.3.0.0]` and
`[baikai-openai 0.3.0.0]` sections (ErrorClass module renamed under `.Internal`;
`mapRequest` moved to `.Internal.Request`; CLI/interactive config constructors hidden;
`extraArgs` type change), `[baikai-effectful 0.3.0.0]` and `[baikai-trace-otel 0.3.0.0]`
(dependency bound raised to `^>=0.3.0`; trace-otel also notes the `latencyMs` type
change it consumes), and `[baikai-kit 0.1.0.1]` (bound raise only). Then bump `version:`
in `baikai/baikai.cabal`, `baikai-claude/baikai-claude.cabal`,
`baikai-openai/baikai-openai.cabal`, `baikai-effectful/baikai-effectful.cabal`,
`baikai-trace-otel/baikai-trace-otel.cabal` to `0.3.0.0` and
`baikai-kit/baikai-kit.cabal` to `0.1.0.1`, and change every `baikai ^>=0.2.0`
dependency bound (in baikai-claude, baikai-openai, baikai-effectful, baikai-trace-otel,
baikai-kit) to `^>=0.3.0`. `baikai-smoke` stays at 0.1.0.0 (never released).

Finally, update the master plan
(`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`): check
the two EP-10 Progress boxes and set the registry row's Status.

Acceptance: `cabal build all --enable-tests`, `cabal test all`, and
`cabal haddock baikai` all succeed (the haddock run proves every rewritten doc comment
parses and every cross-reference resolves); the grep sweeps in Concrete Steps return
only intentional hits.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Before Milestone 1 — reconcile with the sibling plans:

```bash
sed -n '/## Decision Log/,/## /p' docs/plans/42-add-core-ergonomic-helpers-before-the-api-freeze.md
git log --oneline -20
```

Record EP-9's final helper names in this plan's Decision Log before editing.

The build-and-test loop after each batch of edits (expect the final lines to report all
suites passing; individual suite names include `baikai-test`, the provider test suites,
`baikai-effectful-test`, `baikai-kit-test`):

```bash
cabal build all --enable-tests
cabal test all
```

Regenerating the catalog after the Milestone 1 generator change (expected: the command
exits 0 and prints the output path; `git diff` for the generated file shows only the
constructor-to-record-update style change in Milestone 1, and *no* diff when re-run in
Milestone 3):

```bash
cabal run baikai-gen-models
git diff --stat baikai/src/Baikai/Models/Generated.hs
```

Rename-sweep verification (expected: only the deprecated alias definitions in the
defining modules, this plan, and CHANGELOG.md):

```bash
git grep -n "_Options\b\|_Context\b\|_Model\b\|_ModelCost\b\|_Usage\b\|_Cost\b\|_CostBreakdown\b\|_Response\b\|_Tool\b\|_TextContent\b\|_ThinkingContent\b\|_ToolCall\b\|_ImageContent\b\|_EmbeddingModel\b\|_InteractiveLaunchRequest\b\|_InteractiveLaunchResult\b" -- '*.hs' '*.md'
git grep -n "unModel" -- '*.hs' '*.md'
```

Export-surface repl check (Milestone 1; run in `cabal repl baikai`). Expected transcript
shape — the type and selectors appear, no `Options ::`-style data-constructor line does,
and the construction attempt fails:

```text
ghci> :browse Baikai.Options
type Options :: *
data Options
emptyOptions :: Options
maxTokens :: Options -> Maybe Natural
...
ghci> Options { maxTokens = Nothing }
<interactive>: error: [GHC-76037]
    Not in scope: data constructor 'Options'
ghci> emptyOptions { maxTokens = Just 1 } == emptyOptions
False
```

Repeat `:browse` for `Baikai.Context`, `Baikai.Model`, `Baikai.Compat`,
`Baikai.Interactive`, and (via `cabal repl baikai-claude` / `baikai-openai`) the four
config modules.

Internal-namespacing verification (Milestone 2; expected: first grep only hits
CHANGELOG/docs/plans, second confirms the new modules exist in the cabal files):

```bash
git grep -n "Claude.ErrorClass\|OpenAI.ErrorClass" -- '*.hs' '*.cabal'
grep -n "Internal" baikai-claude/baikai-claude.cabal baikai-openai/baikai-openai.cabal
```

Doc-drift verification (Milestone 4; expected: no hits outside CHANGELOG.md, this
plan's directory, and the review document):

```bash
git grep -n "OPENAI_KEY\|ANTHROPIC_KEY" -- README.md docs/user | grep -v "API_KEY"
git grep -n "ProviderError" -- README.md docs/user baikai-effectful/README.md
git grep -n "0\.1 API\|published on Hackage\|being published" -- README.md docs/user
```

Release bookkeeping check and haddock proof (Milestone 4; haddock is expected to end
with a line like `Documentation created: .../doc/html/baikai/index.html`):

```bash
grep -rn "\^>=0\.2\.0" --include="*.cabal" .        # expect: no hits
grep -n "^version" baikai/baikai.cabal baikai-claude/baikai-claude.cabal baikai-openai/baikai-openai.cabal baikai-effectful/baikai-effectful.cabal baikai-trace-otel/baikai-trace-otel.cabal baikai-kit/baikai-kit.cabal
cabal haddock baikai
```

Commit after each milestone with conventional-commit messages, for example:

```text
refactor(api)!: hide evolvable-record constructors and rename the _X bases
refactor(providers)!: move ErrorClass and mapRequest under .Internal
fix(core): total embedding access, JSON escaping, generator collision check
docs(release): sweep docs to post-hardening behavior; bump to 0.3.0.0
```


## Validation and Acceptance

The change is accepted when all of the following hold, in this order.

Behavioral proof of the export policy: in `cabal repl baikai`, `:browse Baikai.Options`
lists `emptyOptions` and every selector but no data constructor, and evaluating
`Options { maxTokens = Nothing }` fails with "Not in scope: data constructor 'Options'"
while `emptyOptions { maxTokens = Just 1 }` evaluates. The same holds for `Context`,
`Model`, the two compat records, `InteractiveLaunchRequest`, and the four vendor config
records. The compile-time surface probe (`baikai/test/SurfaceSpec.hs`) builds, proving
every intended-public name (including EP-9's helpers) is still exported.

Behavioral proof of the renames: `cabal test all` passes with all test suites using
`empty*`/`zero*` names; compiling a module that uses `_Options` produces a
`-Wdeprecations` warning naming `emptyOptions` (verify once in the repl with
`:set -Wdeprecations`).

Behavioral proof of the robustness fixes: `cabal test all` runs the new cases —
`firstEmbedding V.empty` yields `Left` with category `DecodeFailure`
(`baikai/test/EmbeddingSpec.hs`); `jsonString "a\"b\\c\nd\x01e"` round-trips through
`Aeson.decode` (`baikai/test/FetchModelsSpec.hs`); colliding sanitized identifiers yield
a `Left` naming both model ids (`baikai/test/GenModelsSpec.hs`). Each of these fails on
the pre-milestone code (the first crashes with a `V.head` empty-vector error, the second
produces unparseable JSON, the third returns two same-named entries) — run the new specs
once before applying the fix to observe the failure.

Documentation acceptance: `cabal haddock baikai` completes with a "Documentation
created" line; the three doc-drift greps in Concrete Steps come back clean; a reader
following `docs/user/getting-started.md` from scratch encounters only names that the
current `Baikai` umbrella exports (checked snippet-by-snippet in Milestone 4).

Release acceptance: `grep -rn "\^>=0\.2\.0" --include="*.cabal" .` returns nothing; the
six version lines read 0.3.0.0 / 0.3.0.0 / 0.3.0.0 / 0.3.0.0 / 0.3.0.0 / 0.1.0.1;
`CHANGELOG.md` has a dated section per bumped package; `cabal build all --enable-tests`
and `cabal test all` are green at the final commit.


## Idempotence and Recovery

Every step is a plain source edit under git; the recovery path for any misstep is
`git checkout -- <path>` (or `git revert` after a commit). Work milestone-by-milestone
with one commit per milestone so a bad state is never more than one `git reset --hard
HEAD~1` away — and since Milestone 1 is the big mechanical sweep, commit intermediate
checkpoints inside it (e.g. after the core-package sweep compiles) as you go.

The rename and constructor sweeps are idempotent: re-running the greps in Concrete Steps
after a partial pass shows exactly the remaining call sites, and the compiler enforces
completeness (a missed constructor use is a hard error; a missed rename is a deprecation
warning, and test-suite `-Wall` surfaces them). The catalog regeneration is idempotent
by construction — `cabal run baikai-gen-models` rewrites
`baikai/src/Baikai/Models/Generated.hs` from the JSON inputs, so running it twice
produces identical output; never hand-edit the generated file. The `git mv` module
renames are safe to redo; if a rename half-applied (file moved, cabal not updated), the
build error names the missing module directly. CHANGELOG and version edits are pure text
and can be re-applied any number of times.

If EP-9 (plan 42) turns out to have made a decision that contradicts a name or location
this plan assumes (e.g. it placed a helper in a module this plan restructures), do not
improvise silently: record the conflict and the resolution in both plans' Decision Logs,
then proceed.


## Interfaces and Dependencies

No new external dependencies are introduced; the plan relies on packages already in the
build plans: `aeson` (`Data.Aeson.Text.encodeToLazyText` for the fetcher fix), `vector`
(`Data.Vector.(!?)`), `lens`/`generic-lens` (unchanged re-exports), hspec (existing test
driver). Tooling: `cabal` (build/test/haddock/run), GHC ≥ 9.10 (GHC2024 is the
project-wide `default-language`).

At the end of Milestone 1 the following must exist with these exact types (all in the
`baikai` package unless noted):

- `Baikai.Options.emptyOptions :: Options`; `Baikai.Context.emptyContext :: Context`;
  `Baikai.Model.emptyModel :: Model`; `Baikai.Model.zeroModelCost :: ModelCost`;
  `Baikai.Response.emptyResponse :: Response`; `Baikai.Usage.zeroUsage :: Usage`;
  `Baikai.Cost.zeroCost :: Cost`; `Baikai.Cost.zeroCostBreakdown :: CostBreakdown`;
  `Baikai.Tool.emptyTool :: Tool`; `Baikai.Content.emptyTextContent :: TextContent`;
  `Baikai.Content.emptyThinkingContent :: ThinkingContent`;
  `Baikai.Content.emptyToolCall :: ToolCall`;
  `Baikai.Content.emptyImageContent :: ImageContent`;
  `Baikai.Embedding.emptyEmbeddingModel :: EmbeddingModel`;
  `Baikai.Interactive.interactiveLaunchRequest :: Text -> InteractiveLaunchRequest`;
  `Baikai.Interactive.interactiveLaunchResult :: InteractiveProvider -> ExitCode -> InteractiveLaunchResult`
  — each with a matching deprecated `_X` alias (except deleted `unModel`).
- `instance Semigroup Context` and `instance Monoid Context` in `Baikai.Context`
  (unless EP-9 provided them).
- `Baikai.Interactive.InteractiveLaunchRequest` has field
  `modelId :: Maybe Text` (renamed from `model`) and `extraArgs :: [Text]`;
  `ClaudeCliConfig`/`ClaudeInteractiveConfig` (package `baikai-claude`) and
  `CodexCliConfig`/`CodexInteractiveConfig` (package `baikai-openai`) have
  `extraArgs :: [Text]`.
- `Baikai.Response.Response.latencyMs :: Int` and
  `Baikai.Trace.Event.TraceEvent`'s `CallFinished`/`CallFailed` carry
  `latencyMs :: Int`.
- None of `Options`, `Context`, `Model`, `OpenAICompletionsCompat`,
  `AnthropicMessagesCompat`, `InteractiveLaunchRequest`, `ClaudeCliConfig`,
  `ClaudeInteractiveConfig`, `CodexCliConfig`, `CodexInteractiveConfig` export a data
  constructor from any exposed module.

At the end of Milestone 2:

- Modules `Baikai.Provider.Claude.Internal.ErrorClass` and
  `Baikai.Provider.Claude.Internal.Request` (package `baikai-claude`), and
  `Baikai.Provider.OpenAI.Internal.ErrorClass` and
  `Baikai.Provider.OpenAI.Internal.Request` (package `baikai-openai`), exposed, each
  with the no-guarantees haddock; `mapRequest` exported from the `Internal.Request`
  modules (its post-EP-7/EP-8 signature is preserved verbatim from the `Api` module it
  leaves) and absent from `Baikai.Provider.Claude.Api` / `Baikai.Provider.OpenAI.Api`.

At the end of Milestone 3:

- `Baikai.Embedding.firstEmbedding :: Vector Emb.Embedding -> Either BaikaiError (Vector Double)`
  exported from `baikai/src/Baikai/Embedding.hs`.
- `FetchModelsCore.jsonString :: Text -> Text` (unchanged signature, aeson-backed body).
- `GenModelsCore.checkIdentifierCollisions :: [(Text, GeneratedEntry)] -> Either Text [(Text, GeneratedEntry)]`
  in `baikai/gen/GenModelsCore.hs`, compiled into both the `baikai-gen-models`
  executable and the `baikai-test` suite.

At the end of Milestone 4: no code interfaces change; the deliverables are the doc
files, `CHANGELOG.md`, and the six `.cabal` version/bounds edits enumerated in the
milestone.
