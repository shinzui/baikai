---
id: 42
slug: add-core-ergonomic-helpers-before-the-api-freeze
title: "Add core ergonomic helpers before the API freeze"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Add core ergonomic helpers before the API freeze

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-9 (wave 4) of the MasterPlan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`. It
implements API design recommendations 2, 3, 4, 6, 7, 9, 10, and 11 from
`docs/reviews/2026-07-01-correctness-and-api-review.md`. It soft-depends on
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (EP-6),
which defines the in-band error contract and the `responseError` accessor that the
new tool loop terminates on. `docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`
(EP-10) runs after this plan and may relocate or rename what it adds, so every
helper here goes into the existing module structure — no new modules unless a
cycle forces one (none does).


## Purpose / Big Picture

Today, every program that uses baikai for real work hand-writes the same five
pieces of scaffolding, and the repository's own examples prove it. The smoke test
`baikai-smoke/test/ToolsSmoke.hs` hand-rolls a two-turn tool round-trip in ~100
lines that a real agent would need to generalize to N turns; `baikai-smoke/test/Smoke.hs`
and `baikai-smoke/test/StructuredSmoke.hs` both re-implement a `flattenAssistantText`
helper the README already advertises as if it existed (`README.md:88`); every
example builds a `Context` with four lines of lens updates; the smoke tests
hand-roll "first environment variable that is set wins" API-key probing; and the
pure message constructors (`user`, `assistant`, `toolResult` in
`baikai/src/Baikai/Message.hs`) silently stamp every message with a fake
2000-01-01 timestamp that the docs then use for real calls.

After this plan, a caller can:

- run an N-turn tool conversation with one call — `runToolLoop 8 dispatcher model ctx opts`
  drives the complete→execute-tools→append→complete cycle until the model stops
  asking for tools, an error is reported, or the turn budget runs out;
- build conversations with pure combinators and a lawful `Monoid` —
  `contextOf`, `systemUser`, `addUser`, `addMessage`, `addResponse`, `<>`, `mempty`;
- get text out of a response with the exported `flattenAssistantText`, or skip the
  ceremony entirely with `completeText model "prompt"`;
- stream without depending on streamly, via `streamRequestEach` (callback per
  event, reassembled `Response` returned) and `streamRequestList`;
- register providers as first-class values (`newProviderRegistryFrom
  [claudeMessagesProvider, codexCliProvider cfg]`), preflight-check them with
  `assertRegistered`, chain key sources with `ApiKeyEnvChain`, and build a model
  with `mkModel api modelId baseUrl`;
- set `topP`, `stopSequences`, `seed`, `frequencyPenalty`, and `presencePenalty`
  on `Options`.

Message timestamps become `Maybe UTCTime`, so a pure `user "hi"` is honest
(`timestamp = Nothing`) instead of a lie. The proof of the ergonomic win is
visible: `baikai-smoke/test/ToolsSmoke.hs` shrinks to roughly a third of its size
when rewritten on `runToolLoop`, and the whole workspace builds and passes
`cabal test baikai baikai-claude baikai-openai baikai-effectful`.


## Progress

Use this checklist to record granular progress. Split partially completed items
into "done" and "remaining" at every stopping point.

- [x] M1: `timestamp` fields on `UserPayload`/`AssistantPayload`/`ToolResultPayload`
      changed to `Maybe UTCTime`; `defaultTimestamp` deleted; pure constructors
      produce `Nothing`; `*At`/`*Now` produce `Just`.
- [x] M1: compiler-driven sweep of timestamp use sites (`baikai/src/Baikai/Stream.hs`
      latency/skeleton handling, `baikai/src/Baikai/Response.hs` `_Response`,
      `baikai/src/Baikai/Cost/Pricing.hs`, both provider packages, all test suites).
- [x] M1: `Semigroup`/`Monoid` instances for `Context`; `contextOf`, `systemUser`,
      `addUser`, `addMessage`, `addResponse` added to `baikai/src/Baikai/Context.hs`.
- [x] M1: `flattenAssistantText` added and exported from `baikai/src/Baikai/Response.hs`.
- [x] M1: `baikai/test/ContextSpec.hs` created (Monoid laws + constructor behavior)
      and wired into `baikai/test/Main.hs` and `baikai/baikai.cabal`.
- [x] M2: `runToolLoop`/`runToolLoopWith` and `completeText` added to
      `baikai/src/Baikai/Provider/Registry.hs`, re-exported from
      `baikai/src/Baikai/Provider.hs`.
- [x] M2: `streamRequestEach`/`streamRequestEachWith`/`streamRequestList`/
      `streamRequestListWith` added to `baikai/src/Baikai/Stream.hs`.
- [x] M2: `baikai/test/HelpersSpec.hs` created with a scripted stub provider in an
      isolated `ProviderRegistry`; loop termination, budget-exhaustion, error-response,
      dispatcher-exception, `completeText`, and streaming-helper cases pass.
- [x] M3: `ApiKeyEnvChain` constructor added to `baikai/src/Baikai/Auth.hs` with
      first-set-wins resolution and redacting instances.
- [x] M3: `mkModel` added to `baikai/src/Baikai/Model.hs`; `unModel` deleted.
- [x] M3: five new `Maybe` fields on `Options` in `baikai/src/Baikai/Options.hs`,
      mapped in both API providers, documented drop policy.
- [x] M3: first-class provider values exported from all four provider modules;
      `newProviderRegistryFrom` and `assertRegistered` added to
      `baikai/src/Baikai/Provider/Registry.hs`; register naming ladder collapsed
      with deprecated aliases.
- [x] M3: unit tests — auth chain, `mkModel`, `assertRegistered`,
      `newProviderRegistryFrom` in `baikai/test/HelpersSpec.hs`; option-mapping
      assertions in `baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs`.
- [x] M4: `baikai-smoke/test/ToolsSmoke.hs` rewritten on `runToolLoop` +
      `ApiKeyEnvChain`; `baikai-smoke/test/Smoke.hs` and
      `baikai-smoke/test/StructuredSmoke.hs` local `flattenAssistantText` copies
      deleted in favor of the library export.
- [x] M4: `docs/user/tools.md` gains a short `runToolLoop` section;
      `docs/user/getting-started.md` shows `completeText` and the now-real
      `flattenAssistantText`.
- [ ] Final: `cabal build all --enable-tests` clean;
      `cabal test baikai baikai-claude baikai-openai baikai-effectful` green;
      Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, or insights discovered during implementation,
with concise evidence.

- 2026-07-03: Exporting `flattenAssistantText` immediately replaced four local
  copies in smoke/effectful tests and exposed the intended downstream collision
  shape; deleting those copies proved the helper is source-useful beyond the new
  `ContextSpec`.


## Decision Log

- Decision: Fix the timestamp lie by changing `timestamp` to `Maybe UTCTime` on all
  three message payload records, rather than renaming the pure constructors to
  `*Fixture` and promoting `userNow`.
  Rationale: this plan's flagship helpers (`contextOf`, `addUser`, `addResponse`,
  the `Context` `Monoid`, `completeText`, and the context-append step inside
  `runToolLoop`) all need honest *pure* message construction. Under the rename
  option, the only pure constructors would be fixture-stamped, so `addUser` would
  either perpetuate the fake timestamp under a new name or become `IO`, killing
  chainability and the Monoid story. The `Maybe` option is more churn (~30
  mechanical use sites across core, both providers, and tests — verified by grep)
  but all of it is compiler-driven, and it removes the lie at the type level:
  `Nothing` truthfully means "no local creation time recorded". Providers already
  stamp assistant payloads with `getCurrentTime` on receipt; those become `Just`.
  Timestamps never go over the wire (neither provider's `mapRequest` reads them),
  so no request behavior changes.
  Date: 2026-07-01
- Decision: `runToolLoop :: Int -> (ToolCall -> IO ToolResult) -> Model -> Context
  -> Options -> IO (Context, Response)`, exactly the review's sketch, with a
  registry variant `runToolLoopWith :: ProviderRegistry -> Int -> (ToolCall -> IO
  ToolResult) -> Model -> Context -> Options -> IO (Context, Response)`. The `Int`
  is the maximum number of model calls (values below 1 are clamped to 1, because a
  loop that never calls the model has no `Response` to return).
  Rationale: matches `completeRequest`/`completeRequestWith` argument order and the
  existing core convention that a `With` suffix means "explicit
  `ProviderRegistry`".
  Date: 2026-07-01
- Decision: the `Context` returned by `runToolLoop` contains the input context plus
  every *fully resolved* exchange (each intermediate assistant tool-call turn and
  its tool results), and never the final `Response`'s assistant message.
  Rationale: uniform across all termination causes. Appending the final turn only
  on success would make the returned shape depend on why the loop stopped;
  appending it on budget exhaustion would leave a dangling `tool_use` turn with no
  `tool_result`, which Anthropic rejects on replay. Callers who want the full
  transcript write `addResponse finalResp finalCtx` — one call, using this plan's
  own helper.
  Date: 2026-07-01
- Decision: `runToolLoop` termination conditions, in order of precedence after each
  `completeRequest`: (1) the response reports an error per the in-band contract
  (`responseError resp` is `Just`, equivalently `stopReason == ErrorReason`) —
  return; (2) `stopReason /= ToolUse` — return; (3) `stopReason == ToolUse` but the
  message contains zero `AssistantToolCall` blocks — return (defensive: appending
  nothing and re-sending the identical request would loop forever); (4) the turn
  budget is spent — return with the tool-wanting response un-executed (caller
  detects via `stopReason == ToolUse`); otherwise execute the tools, append, recur.
  Rationale: the in-band contract decided in the MasterPlan Decision Log
  (`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`)
  says failures arrive as error-shaped `Response`s, so the loop must inspect, not
  catch. Until EP-6 (`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`)
  lands `responseError :: Response -> Maybe BaikaiError`, the loop checks
  `stopReason == ErrorReason` and reads `errorInfo` directly — same semantics,
  and the switch to `responseError` is a one-line change when EP-6 merges.
  Date: 2026-07-01
- Decision: a synchronous exception thrown by the caller's dispatcher is caught by
  `runToolLoop` and converted to `toolResultErrorText` (the exception's
  `displayException` text) so one failing tool does not abort the conversation;
  asynchronous exceptions are rethrown. Unknown tool names are the dispatcher's
  concern by construction (dispatch is by function, not by name map); the haddock
  documents the recommended pattern — return `toolResultErrorText "unknown tool:
  <name>"` so the model can recover.
  Rationale: matches Anthropic/OpenAI guidance that tool failures should be
  reported to the model in-band; the async rethrow mirrors the sync-only-catch
  policy the review demands elsewhere (Theme 10.1).
  Date: 2026-07-01
- Decision: `Context` `Semigroup` is field-wise: `systemPrompt` is left-biased via
  `<|>`, `messages` and `tools` append. `mempty` is the existing `_Context`
  (all-empty). Lawful because `<|>` on `Maybe` and `<>` on `Vector` are associative
  with those identities.
  Rationale: left-bias on `systemPrompt` makes `base <> perRequest` keep the
  application's system prompt, the common composition direction. Duplicate tool
  names after `<>` are the caller's responsibility (documented; providers forward
  the vector as-is).
  Date: 2026-07-01
- Decision: `flattenAssistantText :: Vector AssistantContent -> Text` lives in
  `baikai/src/Baikai/Response.hs` next to `flattenAssistantBlocks`, concatenating
  the text of `AssistantText` blocks (ignoring thinking and tool calls) with
  `Text.concat`.
  Rationale: this exact signature and semantics is what `README.md:88`,
  `baikai-smoke/test/Smoke.hs:331`, `baikai-smoke/test/StructuredSmoke.hs:135`, and
  `baikai-effectful/test/StubProvider.hs:30` all already assume — export what the
  ecosystem already wrote, four times, verbatim.
  Date: 2026-07-01
- Decision: `completeText :: Model -> Text -> IO Text` lives in
  `baikai/src/Baikai/Provider/Registry.hs`: it dispatches
  `contextOf [user prompt]` with `_Options` through the global registry and
  returns `flattenAssistantText (flattenAssistantBlocks resp)`; when
  the response is error-shaped it throws the `BaikaiError` (falling back to
  `providerError` built from `errorMessage` when `errorInfo` is `Nothing`).
  Rationale: the MasterPlan Decision Log explicitly reserves "a throwing
  convenience wrapper can be added in EP-9" — this is that wrapper; a one-shot
  helper that silently returns `""` on failure would be a trap. Home is the
  registry module because it is a dispatch wrapper (it needs `completeRequest`,
  and `Baikai.Context` cannot import the registry without a cycle).
  Date: 2026-07-01
- Decision: streamly-free streaming ships as four functions in
  `baikai/src/Baikai/Stream.hs`: `streamRequestEach :: (AssistantMessageEvent ->
  IO ()) -> Model -> Context -> Options -> IO Response` (callback per event, then
  the reassembled `Response`), `streamRequestList :: Model -> Context -> Options ->
  IO [AssistantMessageEvent]`, plus `...With` variants taking a `ProviderRegistry`
  first. The `Stream` forms stay untouched. Callback exceptions propagate to the
  caller (it is their code).
  Rationale: the review's rec 7 verbatim; implementation is a thin
  `Stream.fold (reassembleResponse m) . Stream.trace callback` /
  `Stream.toList`, so casual consumers stop importing streamly while power users
  lose nothing.
  Date: 2026-07-01
- Decision: auth grows a third `ApiKeySource` constructor, `ApiKeyEnvChain
  ![String]` (first set variable wins), rather than a separate
  `resolveApiKeyFirst` helper.
  Rationale: the key source is *data* carried on `Options.apiKey` — as a
  constructor it stays lazy (resolved by the provider at call time, like
  `ApiKeyEnv`), serializes redacted into traces via the existing `ToJSON`
  instance, and providers get it for free through `resolveApiKey`. A standalone
  `IO` helper would force eager resolution at the call site and put a raw secret
  in a `Text`. Adding a constructor is a major-version pattern-match break, which
  is acceptable pre-freeze and is exactly the window EP-10's export-policy work
  assumes. Empty chain or all-unset resolves to an `AuthError` listing every
  probed name.
  Date: 2026-07-01
- Decision: `mkModel :: Api -> Text -> Text -> Model` takes the three
  discriminators in dispatch order — `api`, `modelId`, `baseUrl` — and defaults
  everything else from `_Model`, except `name = modelId` and
  `provider = renderApi api` (a truthful default label for traces and
  `Response.provider`). `unModel` is deleted outright: its haddock calls it a
  migration convenience, and grep shows zero live code users (only historical
  plan documents mention it).
  Rationale: rec 10 verbatim; `_Model` stays for tests. Deleting rather than
  deprecating because there is nothing to migrate.
  Date: 2026-07-01
- Decision: register-function naming — the rule after this plan is: bare
  `register` in a provider package always means "global registry, default
  config"; a `With` suffix in the *core* registry vocabulary always means
  "explicit `ProviderRegistry`"; and every other cell of the (registry × config)
  matrix is expressed by applying core functions to the new first-class provider
  values (`registerApiProviderWith reg (claudeCliProvider cfg)`,
  `newProviderRegistryFrom [...]`, `registerApiProvider (codexCliProvider cfg)`).
  The now-redundant provider-package names — `registerWithRegistry` in all four
  modules, and `registerWith`/`registerWithRegistryAndConfig` in the two CLI
  modules — become one-line `DEPRECATED` aliases (cheap; EP-10 decides deletion).
  Rationale: "With" currently means config in `Baikai.Provider.Claude.Cli` but
  registry in `Baikai.Provider.Claude.Api` and in core — an unlearnable ladder.
  First-class values collapse the matrix instead of growing it to eight names per
  package.
  Date: 2026-07-01
- Decision: `Options` gains `topP :: Maybe Double`, `stopSequences :: Maybe
  (Vector Text)`, `seed :: Maybe Integer`, `frequencyPenalty :: Maybe Double`,
  `presencePenalty :: Maybe Double`. Mapping: the Anthropic provider maps `topP →
  top_p` and `stopSequences → stop_sequences` and silently drops the other three
  (the Messages API has no such parameters); the OpenAI provider maps all five
  (`top_p`, `stop`, `seed`, `frequency_penalty`, `presence_penalty`); the CLI
  providers drop all five (they already drop `temperature`). Silent-drop is
  per-provider, not per-compat — kept simple and documented field-by-field on the
  `Options` haddock.
  Rationale: field names and types match the MercuryTechnologies SDK records
  exactly (`CreateMessage.top_p/stop_sequences` in
  `claude/src/Claude/V1/Messages.hs`; `CreateChatCompletion.top_p/stop/seed/
  frequency_penalty/presence_penalty` in `openai/src/OpenAI/V1/Chat/Completions.hs`
  — verified in the SDK sources), so mapping is direct. `Vector Text` matches
  both SDKs and `Context.tools`; the list-vs-vector consistency sweep is EP-10's.
  A per-compat "warn on drop" mechanism was rejected as scope creep — EP-8 owns
  compat semantics.
  Date: 2026-07-01
- Decision: module homes — `contextOf`/`systemUser`/`addUser`/`addMessage`/
  `addResponse`/`Semigroup`/`Monoid` in `Baikai.Context`; `flattenAssistantText`
  in `Baikai.Response`; `runToolLoop`/`runToolLoopWith`/`completeText`/
  `newProviderRegistryFrom`/`assertRegistered` in `Baikai.Provider.Registry`
  (re-exported through `Baikai.Provider`, hence the `Baikai` umbrella);
  streaming helpers in `Baikai.Stream`; `ApiKeyEnvChain` in `Baikai.Auth`;
  `mkModel` in `Baikai.Model`; provider values in their respective
  `Baikai.Provider.{Claude,OpenAI}.{Api,Cli}` modules.
  Rationale: the MasterPlan's integration-points section directs EP-9 to "add new
  helpers to the existing module structure and let EP-10 relocate them if needed".
  Date: 2026-07-01
- Decision: this plan is written against the *current* shape of
  `baikai/src/Baikai/Stream.hs`. EP-5 (`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`)
  reshapes reassembly and the event payloads in wave 1; if it has landed first
  (the intended order), the timestamp sweep and the streaming helpers adapt
  mechanically to the new shapes — the helpers only *wrap* `streamRequestWith`
  and `reassembleResponse`, they do not re-implement them. Any needed change to
  the event algebra itself would have to be recorded in EP-5's Decision Log per
  the MasterPlan; none is anticipated.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at
completion, comparing the result against the Purpose section.

- 2026-07-03 M1: Message payload timestamps are now honest (`Maybe UTCTime`),
  pure constructors produce `Nothing`, provider/IO paths produce `Just`, and
  stream reassembly computes latency only when both start and end timestamps are
  present. `Context` now has lawful `Semigroup`/`Monoid` instances plus
  `contextOf`, `systemUser`, `addUser`, `addMessage`, and `addResponse`.
  `flattenAssistantText` is exported from `Baikai.Response`, replacing local
  smoke/effectful copies. Validation passed with `cabal build all --enable-tests`
  and `cabal test baikai baikai-claude baikai-openai baikai-effectful
  --test-show-details=direct`.
- 2026-07-03 M2: `runToolLoop`/`runToolLoopWith`, `completeText`, and
  streamly-free stream callback/list helpers are implemented and re-exported.
  `HelpersSpec` covers tool-loop success, replay-valid budget exhaustion,
  error termination, synchronous dispatcher exception conversion, zero-tool-call
  defense, `completeText` success/error behavior, and stream wrapper behavior.
  Validation passed with `cabal build all --enable-tests` and `cabal test baikai
  baikai-claude baikai-openai baikai-effectful --test-show-details=direct`.
- 2026-07-03 M3: `ApiKeyEnvChain`, `mkModel`, `newProviderRegistryFrom`,
  `assertRegistered`, first-class provider values, and the five new `Options`
  knobs are implemented. `unModel` is gone from Haskell sources. Claude maps
  `topP`/`stopSequences`; OpenAI maps those plus `seed`, `frequencyPenalty`, and
  `presencePenalty`. Validation passed with `cabal build all --enable-tests` and
  `cabal test baikai baikai-claude baikai-openai baikai-effectful
  --test-show-details=direct`.
- 2026-07-03 M4: `ToolsSmoke` now uses `runToolLoop` and `ApiKeyEnvChain`, and
  user docs show `runToolLoop`, `addResponse`, `completeText`, and the exported
  `flattenAssistantText`. Validation passed with `cabal build all
  --enable-tests` and `cabal test baikai-smoke --test-show-details=direct`; the
  OpenAI live tool round-trip ran and succeeded, while Anthropic-dependent cases
  skipped due missing keys.


## Context and Orientation

baikai is a multi-package Haskell workspace (a `cabal.project` at the repository
root) that gives Haskell programs one vocabulary for talking to LLM providers.
The packages that matter here:

- `baikai/` — the core: `Model` (which model to call, `baikai/src/Baikai/Model.hs`),
  `Context` (the conversation: system prompt, message vector, declared tools,
  `baikai/src/Baikai/Context.hs`), `Options` (per-call knobs,
  `baikai/src/Baikai/Options.hs`), `Message` (the user/assistant/tool-result ADT,
  `baikai/src/Baikai/Message.hs`), `Response` (the provider reply envelope,
  `baikai/src/Baikai/Response.hs`), the provider registry
  (`baikai/src/Baikai/Provider/Registry.hs`, re-exported by
  `baikai/src/Baikai/Provider.hs`), the streaming layer
  (`baikai/src/Baikai/Stream.hs` and `baikai/src/Baikai/Stream/Event.hs`), auth
  (`baikai/src/Baikai/Auth.hs`), and errors (`baikai/src/Baikai/Error.hs`). The
  public umbrella is `baikai/src/Baikai.hs`, which re-exports whole modules, so
  new exports in those modules surface automatically.
- `baikai-claude/` — the Anthropic Messages API provider
  (`baikai-claude/src/Baikai/Provider/Claude/Api.hs`) and the `claude -p` CLI
  provider (`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`).
- `baikai-openai/` — the OpenAI Chat Completions provider
  (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`) and the `codex exec` CLI
  provider (`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`).
- `baikai-effectful/` — effectful-effect wrappers; its test suite has the
  scripted-stub-provider pattern this plan copies
  (`baikai-effectful/test/StubProvider.hs`).
- `baikai-smoke/` — live worked examples that skip when API keys are absent
  (`baikai-smoke/test/*.hs`).

Terms used below, in plain language:

- **Provider registry** — a mutable map from an `Api` tag (a closed sum in
  `baikai/src/Baikai/Api.hs`: `AnthropicMessages`, `OpenAIChatCompletions`, the
  two CLI tags, and `Custom Text`) to an `ApiProvider` record holding a `stream`
  and a `complete` handler. `completeRequest` looks the handler up by
  `Model.api` and dispatches. There is a process-global registry
  (`globalProviderRegistry`) and explicit handles (`newProviderRegistry`).
- **In-band error contract** — the failure-reporting rule decided in the
  MasterPlan and implemented by EP-6
  (`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`):
  a failed call does not throw; it returns a `Response` whose
  `message.stopReason` is `ErrorReason` and whose `errorInfo` field carries a
  structured `BaikaiError` (category, HTTP status, retry-after). EP-6 exports
  `responseError :: Response -> Maybe BaikaiError` as the one accessor. Until
  EP-6 lands, `completeRequest` on an *unregistered* tag still throws a
  `BaikaiError` (see `baikai/src/Baikai/Provider/Registry.hs:99`) — the helpers
  this plan adds inherit whatever `completeRequest` does and need no change when
  EP-6 makes that path conform.
- **Tool round-trip** — the model replies with `stopReason = ToolUse` and one or
  more `AssistantToolCall` blocks; the caller executes each call, appends the
  assistant turn plus one `ToolResultMessage` per call to the `Context` (the
  existing `appendToolResult` in `baikai/src/Baikai/Context.hs` does one such
  step), and re-sends. Real agents need this iterated N times with termination
  handling — that is `runToolLoop`.

Current pain points this plan removes, with exact locations:

1. No loop: `baikai-smoke/test/ToolsSmoke.hs` hand-writes the two-turn dance;
   `docs/user/tools.md` teaches the same manual pattern.
2. No pure context construction: every example writes
   `_Context & #messages .~ V.singleton (user …) & #tools .~ …`; `Context` has no
   `Semigroup`/`Monoid` (review rec 8 asks for the lawful Monoid; the `_X`
   renames themselves are EP-10's).
3. `flattenAssistantText` is advertised (`README.md:88`,
   `docs/user/getting-started.md:120`) but not exported; `Baikai.Response` only
   has `flattenAssistantBlocks`. Three test modules re-implement it.
4. The pure constructors `user`/`assistant`/`toolResult` in
   `baikai/src/Baikai/Message.hs:137-144` stamp `defaultTimestamp = 2000-01-01`.
5. Registry ergonomics: the only way to get a Claude handler into an isolated
   registry is `Baikai.Provider.Claude.Api.registerWithRegistry reg`; provider
   packages disagree on what `With` means (`registerWith` takes a *config* in
   `baikai-claude/src/Baikai/Provider/Claude/Cli.hs:103` but the core's
   `registerApiProviderWith` takes a *registry*); there is no preflight check.
6. Streaming requires importing streamly even to just collect events.
7. The smoke tests hand-roll env chains (`firstSetEnv` in
   `baikai-smoke/test/Smoke.hs` and duplicated in `ToolsSmoke.hs`) because
   `ApiKeySource` has only `ApiKeyLiteral` and single-variable `ApiKeyEnv`.
8. Hand-rolling a `Model` from `_Model` leaves `api = Custom ""`, which
   dispatches to a never-registered tag; `unModel` is a dead migration shim.
9. `Options` lacks `topP`, `stopSequences`, `seed`, and the two penalties.

Test infrastructure: every package uses tasty + tasty-hunit with a single
`test/Main.hs` aggregating per-topic modules (see `baikai/baikai.cabal`
`test-suite baikai-test`, `other-modules`). New test modules must be added to
both the aggregator and the cabal `other-modules` list.

A user-level rule that binds all new code in this plan: record fields must never
carry Hungarian-style prefixes (no `optTopP`, no `tlMaxTurns`) — plain names,
`DuplicateRecordFields` handles clashes, matching the whole codebase.


## Plan of Work

The work is four milestones. Milestone 1 changes a core type (timestamps) and
gives `Context` its algebra — it goes first because milestones 2 and 4 build on
pure message construction. Milestone 2 adds the dispatch-layer helpers (the tool
loop, one-shot completion, streamly-free streaming) against a hermetic stub.
Milestone 3 is the surface ergonomics across auth, model, options, and the
provider packages. Milestone 4 rewrites the worked examples as living proof.
Each milestone leaves the whole workspace compiling and green.


### Milestone 1 — Honest message timestamps and a lawful Context

Scope: after this milestone, `user "hi"` produces a message whose `timestamp` is
`Nothing` (truthful: no creation time recorded), `Context` is a lawful `Monoid`
with pure construction helpers, and `flattenAssistantText` is a real export. This
is the only milestone that changes an existing type; everything downstream is a
mechanical, compiler-driven sweep.

In `baikai/src/Baikai/Message.hs`: change the `timestamp` field on `UserPayload`,
`AssistantPayload`, and `ToolResultPayload` from `!UTCTime` to
`!(Maybe UTCTime)`. Delete `defaultTimestamp`. The pure constructors (`user`,
`userImage`, `assistant`, `toolResultMessage`, `toolResultFromCall`,
`toolResult`) set `timestamp = Nothing`; the `*At` variants set `Just ts`; the
`*Now` variants keep sampling `getCurrentTime` and now produce `Just now`. Update
every haddock that mentions the "deterministic fixture timestamp" to say the pure
constructors record no timestamp and that providers stamp assistant payloads on
receipt. The module haddock's description of the trio changes accordingly.

Sweep the use sites (the compiler finds them all; this list is from grep so the
implementer knows the blast radius): `baikai/src/Baikai/Response.hs` (`_Response`
fixture timestamp becomes `Nothing`), `baikai/src/Baikai/Stream.hs` (the
`EventStart` skeleton timestamp is now `Maybe`, so `startTime` capture in `step`
passes it through; `finalizeState` computes `latencyMs` only when both start and
end are `Just`, else `0`; `synthesizeTerminal`, `overrideBlocksAndReason`,
`eventsFor`, and `errorEvent` wrap their sampled times in `Just`),
`baikai/src/Baikai/Cost/Pricing.hs`, `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
and `Cli.hs`, `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `Cli.hs` (all
provider stamps become `Just now`), `baikai-effectful/test/StubProvider.hs` (it
builds payloads from `_Response`, so it mostly just keeps compiling), and every
test suite that constructs payload records literally. Neither provider's
`mapRequest` reads message timestamps (verified), so no wire behavior changes.

In `baikai/src/Baikai/Context.hs`: add

```haskell
instance Semigroup Context where
  a <> b =
    Context
      { systemPrompt = systemPrompt (a :: Context) <|> systemPrompt (b :: Context),
        messages = messages (a :: Context) <> messages (b :: Context),
        tools = tools (a :: Context) <> tools (b :: Context)
      }

instance Monoid Context where
  mempty = _Context

-- | A context holding the given messages, no system prompt, no tools.
contextOf :: [Message] -> Context

-- | A context with a system prompt and a single user text message.
systemUser :: Text -> Text -> Context

-- | Append one user text message (no timestamp recorded).
addUser :: Text -> Context -> Context

-- | Append one message.
addMessage :: Message -> Context -> Context

-- | Append a response's assistant turn — the multi-turn continuation step.
addResponse :: Response -> Context -> Context
```

`addResponse r = addMessage (responseMessage r)`. Export all of them plus the
instances from the module header. Document the left-biased `systemPrompt` and
the append semantics on the instances' haddocks, including the note that `<>`
does not deduplicate tools by name.

In `baikai/src/Baikai/Response.hs`: add and export

```haskell
-- | Concatenate the text of every 'AssistantText' block, ignoring
-- thinking and tool-call blocks.
flattenAssistantText :: Vector AssistantContent -> Text
```

implemented with `Text.concat` over a `mapMaybe`, exactly matching the three
existing local reimplementations so their deletion in milestone 4 is a no-op
behaviorally.

Tests: create `baikai/test/ContextSpec.hs` (tasty-hunit) covering: `mempty <> c
== c` and `c <> mempty == c` and `(a <> b) <> c == a <> (b <> c)` on contexts
that differ in all three fields; left bias of `systemPrompt`; `contextOf`,
`systemUser`, `addUser`, `addMessage`, `addResponse` producing the expected
message vectors; `user "x"` having `timestamp = Nothing` and `userAt ts "x"`
having `Just ts`; `flattenAssistantText` on a mixed block vector. Wire the module
into `baikai/test/Main.hs` and the `other-modules` of `test-suite baikai-test` in
`baikai/baikai.cabal`.

Acceptance: from the repository root, `cabal build all --enable-tests` succeeds
and `cabal test baikai baikai-claude baikai-openai baikai-effectful` is green,
including the new `ContextSpec` group.


### Milestone 2 — The tool loop, one-shot completion, and streamly-free streaming

Scope: after this milestone a caller can drive an N-turn tool conversation, make
a one-line text call, and stream via callback or list without importing
streamly — all proven hermetically against a scripted stub provider in an
isolated registry.

In `baikai/src/Baikai/Provider/Registry.hs`: add (and export; also re-export from
`baikai/src/Baikai/Provider.hs`)

```haskell
runToolLoop ::
  Int ->
  (ToolCall -> IO ToolResult) ->
  Model ->
  Context ->
  Options ->
  IO (Context, Response)
runToolLoop = runToolLoopWith globalProviderRegistry

runToolLoopWith ::
  ProviderRegistry ->
  Int ->
  (ToolCall -> IO ToolResult) ->
  Model ->
  Context ->
  Options ->
  IO (Context, Response)
```

Semantics (all fixed in the Decision Log; restated here so the implementation is
unambiguous): clamp the budget to at least 1. Loop: `resp <- completeRequestWith
reg model ctx opts`. If the response is error-shaped (`stopReason ==
ErrorReason`; switch to `responseError resp` once EP-6 exports it), or
`stopReason /= ToolUse`, or the message has no `AssistantToolCall` blocks, or
this was the last budgeted call — return `(ctx, resp)` with the final assistant
turn *not* appended. Otherwise wrap the dispatcher so synchronous exceptions
become `toolResultErrorText (Text.pack (displayException e))` (rethrow
`SomeAsyncException`), call the existing `appendToolResult ctx resp
wrappedDispatcher` from `baikai/src/Baikai/Context.hs`, and recur with the
budget decremented. The haddock must state: the returned `Context` contains only
fully resolved exchanges and is always replay-valid; use `addResponse` to append
the final turn; `Options` is passed unchanged every turn, so
`ToolChoiceRequired` forces a tool call on *every* turn and will exhaust the
budget — use `ToolChoiceAuto`/`Nothing` in loops; a dispatcher receiving a tool
name it does not know should return `toolResultErrorText` so the model can
recover. This requires importing `appendToolResult`, `ToolResult` helpers, and
`ToolCall` into the registry module — `Baikai.Provider.Registry` already imports
`Baikai.Context`, and no cycle arises (`Baikai.Context` does not import the
registry).

Also in `baikai/src/Baikai/Provider/Registry.hs`, add

```haskell
-- | One-shot text completion through the global registry. Throws the
-- 'BaikaiError' when the response is error-shaped.
completeText :: Model -> Text -> IO Text
```

built as `completeRequest m (contextOf [user prompt]) _Options`, returning
`flattenAssistantText (flattenAssistantBlocks resp)`, throwing `errorInfo`'s
error (or `providerError` from `errorMessage` text when `errorInfo` is absent)
when `stopReason == ErrorReason`.

In `baikai/src/Baikai/Stream.hs`: add and export

```haskell
streamRequestEach ::
  (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response
streamRequestEachWith ::
  ProviderRegistry ->
  (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response
streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]
streamRequestListWith ::
  ProviderRegistry -> Model -> Context -> Options -> IO [AssistantMessageEvent]
```

`streamRequestEachWith reg cb m ctx opts = Stream.fold (reassembleResponse m)
(Stream.trace cb (streamRequestWith reg m ctx opts))`; the list forms are
`Stream.toList`. Haddocks say: same event protocol as `streamRequest` (exactly
one terminal event), callback exceptions propagate, and the returned `Response`
is the same reassembly `streamingComplete` performs.

Tests: create `baikai/test/HelpersSpec.hs` following the pattern of
`baikai-effectful/test/StubProvider.hs` — build an isolated registry via
`newProviderRegistry` whose single `ApiProvider` serves `Custom "helpers-test"`.
Unlike the effectful stub, this one is *scripted*: its `complete` pops responses
from an `IORef [Response]` so a test can enqueue, say, two tool-call responses
followed by a text response. Cover at least: (1) happy path — script
[tool-use("get_time"), tool-use("get_time"), stop("done")], budget 5, dispatcher
returns a fixed timestamp; assert three model calls happened, the returned
context is the input plus two (assistant, tool-result) pairs in order, the final
response has `stopReason = Stop`, and the final turn is not in the context;
(2) budget exhaustion — same script, budget 2; assert two calls, returned
response has `stopReason = ToolUse`, context holds exactly one resolved
exchange; (3) error termination — script [error-shaped response]; assert
immediate return with the error response and unchanged context; (4) dispatcher
throws — assert the loop continues and the appended `ToolResultMessage` has
`isError = True` carrying the exception text; (5) zero-tool-call `ToolUse`
response terminates; (6) `completeText` returns the stub text, and throws
`BaikaiError` on an error-shaped script (use a stub registered in the *global*
registry under a dedicated `Custom` tag, mirroring how `baikai/test/Main.hs`
already registers its test provider); (7) `streamRequestEachWith` invokes the
callback once per event in order and returns a `Response` equal to
`streamingComplete`'s; `streamRequestListWith` returns the exact scripted event
list. Wire into `baikai/test/Main.hs` and `baikai/baikai.cabal`.

Acceptance: `cabal test baikai` green with the new groups; nothing outside the
core package changed in this milestone.


### Milestone 3 — Registry, auth, model-construction, and Options ergonomics

Scope: after this milestone, providers are first-class values, startup preflight
exists, key chains exist, `mkModel` exists, `unModel` is gone, and the five
missing sampling knobs reach the wire on the providers that support them.

In `baikai/src/Baikai/Auth.hs`: add the constructor `ApiKeyEnvChain ![String]`
to `ApiKeySource`. `resolveApiKey` tries each variable in order and returns the
first that is set; when none is set (or the list is empty) it throws
`authError` naming every probed variable, e.g. `"none of the env vars
ANTHROPIC_KEY, ANTHROPIC_API_KEY are set"`. Extend
`renderApiKeySourceForDebug` (`"ApiKeyEnvChain [\"A\",\"B\"]"`) and the `ToJSON`
instance (`{"source":"env-chain","names":[...]}`) — names are not secrets, only
literal keys are redacted.

In `baikai/src/Baikai/Model.hs`: add

```haskell
-- | Build a dispatchable 'Model' from its three discriminators: the
-- 'Api' tag (handler lookup), the model id (sent to the provider),
-- and the base URL. 'name' defaults to the model id, 'provider' to
-- 'renderApi' of the tag; everything else comes from '_Model'.
mkModel :: Api -> Text -> Text -> Model
```

and delete `unModel` (export list, definition, and the module-haddock sentence
that promises to preserve it). `_Model` stays, documented as a test/fixture base.
`Baikai.Model` gains an import of `renderApi` from `Baikai.Api` (already a
dependency direction that exists — `Baikai.Model` imports `Baikai.Api`).

In `baikai/src/Baikai/Options.hs`: add to `Options`, all defaulted to `Nothing`
in `_Options`:

```haskell
topP :: !(Maybe Double),
stopSequences :: !(Maybe (Vector Text)),
seed :: !(Maybe Integer),
frequencyPenalty :: !(Maybe Double),
presencePenalty :: !(Maybe Double)
```

(import `Data.Vector`). Document on each field which providers honor it —
`topP`/`stopSequences`: Anthropic + OpenAI-compatible; `seed`/
`frequencyPenalty`/`presencePenalty`: OpenAI-compatible only — and add a module
haddock paragraph stating the drop policy: a provider that has no corresponding
upstream parameter silently omits the field (same policy as the existing
`temperature` on the CLI providers).

Wire the mappings. In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
`mapRequest` (around line 588's record build): `Messages.top_p = opts ^. #topP`,
`Messages.stop_sequences = opts ^. #stopSequences`. In
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` `mapRequest` (around line
744): `Chat.top_p = opts ^. #topP`, `Chat.stop = opts ^. #stopSequences`,
`Chat.seed = opts ^. #seed`, `Chat.frequency_penalty = opts ^. #frequencyPenalty`,
`Chat.presence_penalty = opts ^. #presencePenalty`. The SDK field names above
were verified against the SDK sources
(`Claude/V1/Messages.hs` `CreateMessage`, `OpenAI/V1/Chat/Completions.hs`
`CreateChatCompletion`).

First-class providers. In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:
extract the `ApiProvider` record currently built inline in `registerWithRegistry`
into an exported value `claudeMessagesProvider :: ApiProvider`; redefine
`register = registerApiProvider claudeMessagesProvider` and mark
`registerWithRegistry` `DEPRECATED` ("use `registerApiProviderWith reg
claudeMessagesProvider`"), keeping it as the one-liner. Same shape in
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` with
`openaiChatProvider :: ApiProvider`. In
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`: export
`claudeCliProvider :: ClaudeCliConfig -> ApiProvider` (the record currently built
in `registerWithRegistryAndConfig`); redefine `register = registerApiProvider
(claudeCliProvider defaultClaudeCliConfig)`; keep `registerWith`,
`registerWithRegistry`, `registerWithRegistryAndConfig` as `DEPRECATED`
one-liners over the value. Same shape in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` with
`codexCliProvider :: CodexCliConfig -> ApiProvider`. Update each module's header
haddock to teach the new vocabulary (`register` for scripts; provider values plus
core registry functions for everything else).

In `baikai/src/Baikai/Provider/Registry.hs` (re-exported from
`baikai/src/Baikai/Provider.hs`):

```haskell
-- | A registry pre-populated with the given providers (later entries
-- win on tag collisions, matching register semantics).
newProviderRegistryFrom :: [ApiProvider] -> IO ProviderRegistry

-- | Startup preflight: throw 'ProviderUnavailable' listing every tag
-- in the list that has no registered handler; return unit when all
-- are present.
assertRegistered :: ProviderRegistry -> [Api] -> IO ()
```

`assertRegistered`'s error message joins the missing tags with `renderApi`, e.g.
`"no provider registered for: anthropic-messages, openai-completions-cli"`.

Tests: extend `baikai/test/HelpersSpec.hs` — `ApiKeyEnvChain` resolution order,
skip-unset, and all-unset error text (use `Environment.setEnv`/`unsetEnv` with
test-unique names); `mkModel` field defaults (`api`, `modelId`, `baseUrl`,
`name == modelId`, `provider == renderApi api`); `newProviderRegistryFrom`
last-wins and lookup; `assertRegistered` passing and failing (assert the missing
tags appear in the thrown error's `message` and `category ==
ProviderUnavailable`). In `baikai-claude/test/Main.hs` and
`baikai-openai/test/Main.hs`, add a `mapRequest` options case each: build
`_Options` with all five new fields set, call the exported `mapRequest`, and
assert the SDK record fields — Anthropic gets `top_p`/`stop_sequences` and (by
construction) has nowhere for the other three; OpenAI gets all five. Also assert
both packages still compile with the deprecated aliases (the deprecation is a
warning, not an error; the workspace builds with warnings allowed — check
`fourmolu`/`ghc-options` in the cabal files and, if `-Werror` is set anywhere,
add `-Wno-deprecations` to the *test* components only, never to the library).

Acceptance: `cabal build all --enable-tests` clean;
`cabal test baikai baikai-claude baikai-openai baikai-effectful` green, with the
new mapping assertions demonstrating the five knobs reach the SDK request
records.


### Milestone 4 — Living proof: rewrite the tool smoke and refresh the worked examples

Scope: this milestone is the plan's acceptance demo — the repository's own
examples shrink visibly, proving the helpers pay for themselves.

Rewrite `baikai-smoke/test/ToolsSmoke.hs` on the new surface: build the context
as `contextOf [user "What time is it? …"] & #tools .~ V.singleton getTime`
(the shortest readable form; the `<>`-composition style is exercised by
`ContextSpec`, not here); replace the manual
turn-1/append/turn-2 dance with one `runToolLoop 4 dispatcher caseModel ctx0
opts` where the dispatcher answers `"get_time"` with the fixed timestamp and
anything else with `toolResultErrorText`; assert the final response's
`stopReason` is not `ToolUse`, that the returned context contains at least one
`ToolResultMessage` for `get_time`, and that `flattenAssistantText
(flattenAssistantBlocks finalResp)` mentions the timestamp fragments (same
tolerant matching as today). Replace the `ApiKeyLiteral`+`firstSetEnv` plumbing
with `#apiKey .~ Just (ApiKeyEnvChain caseEnvVars)` — keep the existing
`firstSetEnv` *only* for the skip-when-absent decision and the log line, and
note in a comment that key resolution itself now goes through the chain. Delete
the local `flattenAssistantText` definitions from `baikai-smoke/test/Smoke.hs`
and `baikai-smoke/test/StructuredSmoke.hs` (the library export is identical);
`baikai-effectful/test/StubProvider.hs` likewise drops its copy and re-exports
or imports the library one. Expect `ToolsSmoke.hs` to land around 50 lines,
from 145.

Docs (minimal — EP-10 owns the sweep): add a short "The tool loop" section to
`docs/user/tools.md` showing `runToolLoop` and `addResponse`, replacing the
"every example hand-writes the two-turn dance" framing; in
`docs/user/getting-started.md`, show `completeText` as the very first example
and fix the `flattenAssistantText` snippet to note it is now exported (the
snippet at `docs/user/getting-started.md:119-121` becomes truthful without
edits, but say so). Do not touch `README.md` (EP-10's sweep covers it;
`README.md:88` simply becomes correct).

Acceptance: `cabal build all --enable-tests` clean and the four test suites
green with no API keys in the environment (the smoke suite compiles; its live
cases skip). With a real `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` exported,
`cabal test baikai-smoke` runs the rewritten tool round-trip live and logs
`tool round-trip <label> ok`.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/baikai`). Repeat the build/test pair after each
milestone; the listed edits per milestone are in Plan of Work.

```bash
cabal build all --enable-tests
cabal test baikai baikai-claude baikai-openai baikai-effectful
```

Expected tail of a green run (module counts will differ as specs are added):

```text
Test suite baikai-test: RUNNING...
All N tests passed
Test suite baikai-test: PASS
...
Test suite baikai-effectful-test: PASS
```

To run only the new core groups while iterating:

```bash
cabal test baikai --test-options='--pattern "Context"'
cabal test baikai --test-options='--pattern "Helpers"'
```

Optional live proof for milestone 4 (skips harmlessly when no keys are set):

```bash
cabal test baikai-smoke
```

Expected with a key present:

```text
[baikai-smoke] tool round-trip claude-haiku-4-5-20251001 ok via ANTHROPIC_API_KEY; ...
```

Expected without keys:

```text
[baikai-smoke] none of ["ANTHROPIC_KEY","ANTHROPIC_API_KEY"] set; skipping tool round-trip ...
```

Format everything with the repo's formatter before committing
(`fourmolu.yaml` is at the root):

```bash
fourmolu -i baikai/src baikai/test baikai-claude/src baikai-claude/test \
  baikai-openai/src baikai-openai/test baikai-effectful/test baikai-smoke/test
```

Commit per milestone with conventional-commit messages, e.g.:

```text
feat(core): make message timestamps Maybe and give Context its Monoid
feat(core): add runToolLoop, completeText, and streamly-free streaming
feat(api): first-class providers, ApiKeyEnvChain, mkModel, Options knobs
refactor(smoke): rewrite tool round-trip on runToolLoop
```


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold.

1. Hermetic tool loop: `cabal test baikai --test-options='--pattern "Helpers"'`
   passes, covering the seven scripted-stub scenarios in Milestone 2 (happy
   path, budget exhaustion, error termination, dispatcher exception,
   zero-tool-call defense, `completeText` success and throw, streaming-helper
   agreement). These tests fail before the plan (the symbols do not exist) and
   pass after — the "fails before, passes after" demonstration.
2. Lawful `Context`: the `ContextSpec` group asserts identity and associativity
   on value triples plus the left-biased `systemPrompt`, and asserts
   `user "x" ^. timestamp == Nothing` (via pattern match) — the timestamp lie is
   gone at the type level.
3. Wire-level options: the `mapRequest` cases in `baikai-claude/test/Main.hs`
   and `baikai-openai/test/Main.hs` show `top_p`/`stop_sequences` (Anthropic)
   and `top_p`/`stop`/`seed`/`frequency_penalty`/`presence_penalty` (OpenAI)
   populated in the SDK request records from `Options` — effective beyond
   compilation.
4. Ergonomic shrink: `git diff --stat` for Milestone 4 shows
   `baikai-smoke/test/ToolsSmoke.hs` losing well over half its lines, and the
   three duplicated `flattenAssistantText` definitions deleted.
5. Advertised surface is real: `ghci` proof —

```bash
cabal repl baikai
```

```text
ghci> :t flattenAssistantText
flattenAssistantText :: Vector AssistantContent -> Text
ghci> :t runToolLoop
runToolLoop
  :: Int
     -> (ToolCall -> IO ToolResult)
     -> Model -> Context -> Options -> IO (Context, Response)
ghci> :t mkModel
mkModel :: Api -> Text -> Text -> Model
```

   and `:t unModel` reports "Variable not in scope".
6. Full suites: `cabal build all --enable-tests` emits no errors and
   `cabal test baikai baikai-claude baikai-openai baikai-effectful` reports
   PASS for all four suites.
7. (Optional, live) with `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` set,
   `cabal test baikai-smoke` logs the rewritten tool round-trip succeeding via
   the `ApiKeyEnvChain`-resolved key.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build — safe to repeat; re-running
`cabal build`/`cabal test` is always harmless. Work in milestone order and
commit each milestone separately so a failed step recovers with
`git restore`/`git revert` of one commit, never a partial type migration.
Milestone 1 is the only risky one (a field type change): the compiler enumerates
every breakage, so drive it to zero errors before touching anything else; if it
must be abandoned midway, `git restore` the working tree — no generated files or
state are involved. Milestones 2–4 are purely additive except the `unModel`
deletion and the smoke rewrite, both trivially revertible. The deprecated
register aliases mean no downstream caller breaks mid-migration. If EP-5/EP-6
land while this plan is in flight, rebase mechanically: the timestamp sweep
re-applies to the reshaped `baikai/src/Baikai/Stream.hs`, and the loop's
error check switches from a local `stopReason` test to `responseError` (record
the switch in this Decision Log).


## Interfaces and Dependencies

No new external dependencies anywhere: everything uses packages already in the
respective cabal files (`streamly-core` for `Stream.trace`/`Stream.toList`/
`Stream.fold`, `vector`, `text`, `time`, `containers`, tasty/tasty-hunit in the
test suites). `baikai/baikai.cabal` gains only test `other-modules`
(`ContextSpec`, `HelpersSpec`).

Signatures that must exist at the end of each milestone, with full module paths.

After Milestone 1 (module `Baikai.Context` in `baikai/src/Baikai/Context.hs`,
module `Baikai.Response` in `baikai/src/Baikai/Response.hs`, module
`Baikai.Message` in `baikai/src/Baikai/Message.hs`):

```haskell
instance Semigroup Context
instance Monoid Context
contextOf :: [Message] -> Context
systemUser :: Text -> Text -> Context
addUser :: Text -> Context -> Context
addMessage :: Message -> Context -> Context
addResponse :: Response -> Context -> Context
flattenAssistantText :: Vector AssistantContent -> Text
-- and on all three payload records:
timestamp :: Maybe UTCTime
```

After Milestone 2 (module `Baikai.Provider.Registry` in
`baikai/src/Baikai/Provider/Registry.hs`, re-exported by `Baikai.Provider`;
module `Baikai.Stream` in `baikai/src/Baikai/Stream.hs`):

```haskell
runToolLoop :: Int -> (ToolCall -> IO ToolResult) -> Model -> Context -> Options -> IO (Context, Response)
runToolLoopWith :: ProviderRegistry -> Int -> (ToolCall -> IO ToolResult) -> Model -> Context -> Options -> IO (Context, Response)
completeText :: Model -> Text -> IO Text
streamRequestEach :: (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response
streamRequestEachWith :: ProviderRegistry -> (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response
streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]
streamRequestListWith :: ProviderRegistry -> Model -> Context -> Options -> IO [AssistantMessageEvent]
```

After Milestone 3 (modules `Baikai.Auth`, `Baikai.Model`, `Baikai.Options`,
`Baikai.Provider.Registry` in the core; `Baikai.Provider.Claude.Api`,
`Baikai.Provider.Claude.Cli` in `baikai-claude/src`;
`Baikai.Provider.OpenAI.Api`, `Baikai.Provider.OpenAI.Cli` in
`baikai-openai/src`):

```haskell
data ApiKeySource = ApiKeyLiteral !Text | ApiKeyEnv !String | ApiKeyEnvChain ![String]
mkModel :: Api -> Text -> Text -> Model
-- unModel no longer exists
-- new Options fields, all Maybe/Nothing-defaulted:
topP :: Maybe Double
stopSequences :: Maybe (Vector Text)
seed :: Maybe Integer
frequencyPenalty :: Maybe Double
presencePenalty :: Maybe Double
newProviderRegistryFrom :: [ApiProvider] -> IO ProviderRegistry
assertRegistered :: ProviderRegistry -> [Api] -> IO ()
claudeMessagesProvider :: ApiProvider
claudeCliProvider :: ClaudeCliConfig -> ApiProvider
openaiChatProvider :: ApiProvider
codexCliProvider :: CodexCliConfig -> ApiProvider
```

Cross-plan interfaces this plan consumes or coordinates with:
`responseError :: Response -> Maybe BaikaiError` is owned by EP-6
(`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`);
until it exists the loop and `completeText` read `stopReason`/`errorInfo`
directly with identical semantics. The event algebra and reassembly in
`baikai/src/Baikai/Stream.hs` are owned by EP-5
(`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`);
this plan only wraps them. The final export policy, `_X` renames, and any
relocation of the helpers added here are owned by EP-10
(`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`), which is why
the deprecated register aliases are kept as one-liners rather than deleted.
