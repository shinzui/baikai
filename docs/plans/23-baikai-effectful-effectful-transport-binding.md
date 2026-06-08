---
id: 23
slug: baikai-effectful-effectful-transport-binding
title: "baikai-effectful: effectful transport binding"
kind: exec-plan
created_at: 2026-06-08T23:11:21Z
intention: "intention_01ktmqmrjre89r3c3qq6fj3j5h"
---

# baikai-effectful: effectful transport binding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

baikai (`/Users/shinzui/Keikaku/bokuno/baikai`) is a Haskell library that talks to AI
providers (Claude, OpenAI, DeepSeek, OpenRouter, Ollama, and the `claude -p` / `codex exec`
command-line tools) through one uniform interface. Every baikai call lives in plain `IO`:
you call `completeRequest model context options :: IO Response` for a blocking completion,
or `streamRequest model context options :: Stream IO AssistantMessageEvent` for a token
stream. That is exactly the right surface for an `IO` program.

A growing number of Haskell programs are not written in plain `IO` — they are written with
**`effectful`**, an effect-system library where a function's type lists the capabilities it
may use. In `effectful` the working monad is `Eff es a`: a computation that may use the
effects in the type-level list `es` and returns `a`. Each capability is an *effect*; code
that needs one carries it as a constraint, e.g. `(Baikai :> es) => ...` reads "the effect
list `es` contains `Baikai`", meaning "this code may make baikai calls". Today, such a
program can only reach baikai by sprinkling `liftIO` at every call site and giving up the
ability to swap baikai out for a stub, an interceptor, or a recorder.

This ExecPlan creates a new, small, **published sibling package `baikai-effectful`** inside
the baikai repository. It provides one thing: a faithful, *thin* `effectful` binding over
baikai's transport functions — a dynamic effect named `Baikai` with operations that mirror
`completeRequest`/`streamRequest`, plus interpreters that run those operations against a
real (or test) provider registry. It deliberately adds **no policy** — no retries, no
caching, no budgets, no error remapping. It is the seam, not the framework.

What you can do after this plan, concretely:

- Add `baikai-effectful` to your `build-depends` and write provider-neutral code such as

  ```haskell
  describe :: (Baikai :> es) => Model -> Eff es Text
  describe m = do
    r <- complete m ctx opts
    pure (flattenAssistantText (flattenAssistantBlocks r))
  ```

  then run it with `runEff . runBaikai $ describe model` (global provider registry) or
  `runEff . runBaikaiWith reg $ describe model` (an isolated registry).
- Run a **hermetic** test (no network, no API key) that registers a stub provider in an
  isolated registry and drives `complete` and the streaming operations end-to-end through
  the `Eff` stack, asserting the returned text and the observed event sequence — proving the
  effect, the interpreters, and the baikai bridge work together.
- Swap the interpreter to mock, record, or intercept every model call without touching call
  sites — the reason a dynamic effect exists.

Why this package exists as its own artifact: it lets any `effectful` program reuse the
baikai↔effectful binding, and it gives downstream frameworks a clean lowest layer. In
particular, the shikumi project (`/Users/shinzui/Keikaku/bokuno/shikumi`) plans to build its
higher-level `LLM` effect — the one that *does* carry retries, rate-limiting, budget, a
structured error type, caching hooks, and tracing — *in terms of* this `Baikai` effect, so
that shikumi's framework code never touches `IO`/`IOE` directly; only this bottom adapter
does. That relationship is recorded in shikumi's MasterPlan at
`/Users/shinzui/Keikaku/bokuno/shikumi/docs/masterplans/1-shikumi-typed-lm-programming-framework.md`
and its substrate plan `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`.
This plan does not depend on shikumi and is fully usable on its own; the shikumi note is
only context for *why* the binding stays policy-free.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-08): Scaffold the `baikai-effectful` package — `baikai-effectful/baikai-effectful.cabal`
      mirroring the repo's `common-options`, an empty-but-compiling
      `Baikai.Effectful` module, the package added to root `cabal.project`, and registered
      in `mori.dhall`. `cabal build baikai-effectful` succeeds (built
      `baikai-effectful-0.1.0.0`); `dhall lint mori.dhall` exits 0. NOTE: the `test-suite`
      stanza is deferred to M2 (its modules don't exist yet, and `tests: True` would force
      it to build) — see Decision Log.
- [x] M2 (2026-06-08): The `Baikai` effect + blocking `complete` + interpreters `runBaikai` /
      `runBaikaiWith`. Hermetic `CompleteSpec` drives `complete` against a stub provider in an
      isolated registry and asserts the returned text (`"hello from stub"`); proven to bite
      (changed stub text → FAIL, restored → OK). NOTE: chose the plan's "implement all three
      now" option — the effect declares and `runBaikaiWith` handles all of `Complete`/
      `StreamCollect`/`StreamEach` already (no `error "M3"` placeholders, so `env` is used and
      no `-Wunused-matches`). M3 adds only the streaming *tests*.
- [x] M3 (2026-06-08): Streaming operations — `streamCollect` (materialize the event list)
      and the higher-order `streamEach` (per-event callback run inside `Eff`). Interpreter
      cases were already implemented in M2; M3 added `StreamSpec`: (1) `streamCollect` returns
      a sequence whose first event is `EventStart`, last is `EventDone`, with `TextDelta`s
      concatenating to the stub text; (2) `streamEach` accumulates into an `IORef` exactly the
      ordered list `streamCollect` returns. Both pass. Required making the stub stream
      deterministic (hand-rolled fixed events) — see Surprises (EventStart timestamp).
- [x] M4 (2026-06-08): Docs + a gated live demo. `LiveSpec` is gated on
      `BAIKAI_EFFECTFUL_LIVE`; with it unset the suite prints the skip line and all 4 cases
      stay green (hermetic). A package `README.md` documents the three operations, the two
      interpreters, and the policy-free contract. `mori show --full` lists `baikai-effectful`
      (path `baikai-effectful`, dep `shinzui/baikai:baikai`). REMAINING: capture an actual
      `LIVE:` transcript — a key (`OPENAI_API_KEY`) is present in the environment, but the
      live call is a real paid request, deferred to explicit user go-ahead. (Chose a package
      `README.md` over a `docs/user/effectful.md` + mori `docs` registration; see Decision Log.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- During authoring (2026-06-08): baikai's transport is registry-parameterized. The bare
  functions `completeRequest`/`streamRequest` use a process-global registry
  (`globalProviderRegistry`), and the `*With` variants take an explicit `ProviderRegistry`
  (`completeRequestWith`, `streamRequestWith`). Evidence, from
  `baikai/src/Baikai/Provider/Registry.hs`:

  ```haskell
  completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
  completeRequest     :: Model -> Context -> Options -> IO Response   -- uses globalProviderRegistry
  ```

  and from `baikai/src/Baikai/Stream.hs`:

  ```haskell
  streamRequest     :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  streamRequestWith :: ProviderRegistry -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
  ```

  This is why the *interpreter* (not the effect operations) chooses the registry:
  `runBaikai` binds the global registry, `runBaikaiWith reg` binds an explicit one. The
  effect operations stay registry-agnostic, exactly like baikai's own `*`/`*With` split.

- During authoring (2026-06-08): blocking failures and streaming failures behave
  differently in baikai, and this binding must preserve that faithfully. `completeRequest`
  **throws** a `Baikai.Error.BaikaiError` exception on failure. `streamRequest` **does not
  throw** — a failure arrives in-band as a terminal `EventError` event, and an unregistered
  `Api` tag yields a one-event error stream (see `streamRequestWith`'s `noProviderEvent`
  branch). The thin binding does not catch or remap either; it lifts baikai's behavior
  verbatim so a faithful consumer (e.g. shikumi) decides the policy.

- During M2 (2026-06-08): **`flattenAssistantText` is NOT a baikai library export** — the
  pre-implementation validation pass assumed it was. baikai exports only
  `flattenAssistantBlocks :: Response -> Vector AssistantContent` (from `Baikai.Response`).
  The `Vector AssistantContent -> Text` reduction is a *local* helper each consumer defines;
  baikai's own smoke tests define it (`baikai-smoke/test/Smoke.hs:319` as
  `flattenAssistantText`, `baikai-smoke/test/MultiHostSmoke.hs:169` as `flattenText`), both
  matching `AssistantText (TextContent t)`. Evidence:

  ```text
  test/CompleteSpec.hs:5: Module 'Baikai' does not export 'flattenAssistantText'.
  ```

  Resolution: this package's `StubProvider` test module defines and exports its own
  `flattenAssistantText :: Vector AssistantContent -> Text` (concatenating `AssistantText`
  block bodies, ignoring thinking/tool-call blocks). All plan call-sites that read
  `flattenAssistantText (flattenAssistantBlocks r)` now source it from `StubProvider`, not
  `Baikai`. The library `Baikai.Effectful` re-exports it from neither — text extraction is a
  caller concern, consistent with baikai itself.

- During M2→M3 (2026-06-08): the stub provider's `stream` was **first** synthesized from its
  `complete` via the exported `Baikai.liftCompleteToStream`, but M3 revealed this is
  **nondeterministic**: `liftCompleteToStream` calls `getCurrentTime` per invocation and
  stamps it into the `EventStart` payload's skeleton message (`StartPayload.partial`). The
  streamEach/streamCollect agreement test drives the stream *twice* (once per operation), so
  the two `EventStart` timestamps differed by microseconds and exact-equality failed —
  everything else in the event lists was byte-identical. Evidence (test output):

  ```text
  expected: …EventStart …timestamp = 2026-06-08 23:38:40.339959 UTC…
   but got: …EventStart …timestamp = 2026-06-08 23:38:40.339255 UTC…
  ```

  Resolution: the stub now emits a **fixed, hand-rolled** event list (`EventStart`, one
  text block, `EventDone`) whose skeleton/terminal messages reuse baikai's `_Response`
  fixture base (`_Response ^. #message`, a payload stamped at the `2000-01-01` epoch). Two
  runs are now byte-identical, so the agreement test passes and genuinely bites — it caught
  this very nondeterminism before the fix. Takeaway for consumers: baikai's real streams
  carry a live wall-clock `EventStart` timestamp; don't assume cross-run event equality.


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the binding as a **new sibling package `baikai-effectful`** inside the
  baikai repo, not as a module added to the core `baikai` package. Rationale: the core
  `baikai` package deliberately has no `effectful` dependency, and most baikai users do not
  use `effectful`. A separate package keeps the core dependency-light while making the
  binding a first-class, reusable artifact for `effectful` programs. Mirrors how
  `baikai-claude` / `baikai-openai` are separate packages layered on `baikai`.
  Date: 2026-06-08.

- Decision: Model baikai access as a **single dynamic effect `Baikai`** (dispatch resolved
  at interpretation time) with operations `Complete`, `StreamCollect`, and `StreamEach`,
  rather than a static effect or a typeclass. Rationale: a dynamic effect lets consumers
  *re-interpret* the same operations (stub in tests, record/replay, intercept, or — in
  shikumi — wrap with retries/caching/tracing) without changing call sites. That
  re-interpretability is the entire point of the binding. Date: 2026-06-08.

- Decision: The effect operations are **registry-agnostic**; the *interpreter* selects the
  provider registry (`runBaikai` = global, `runBaikaiWith reg` = explicit). Rationale:
  mirrors baikai's own `completeRequest` vs `completeRequestWith` split and lets tests pass
  an isolated registry without any change to call sites or operations. Date: 2026-06-08.

- Decision: Keep the binding **policy-free** — no retries, no backoff, no rate limiting, no
  budget, no caching, and no error remapping. `Complete` propagates baikai's `BaikaiError`
  exception as-is; streaming ops surface baikai's terminal `EventError` in-band as-is.
  Rationale: a transport binding must be faithful and unopinionated; every consumer wants a
  different policy, and (for shikumi specifically) those policies live one layer up in
  shikumi's `LLM` effect. Date: 2026-06-08.

- Decision: Depend on **`effectful-core`** for the library (not the umbrella `effectful`).
  Rationale: everything the binding needs — `Eff`, `IOE`, `runEff`, `liftIO`, `interpret`,
  `send`, `withRunInIO`/`localSeqUnliftIO`, `LocalEnv` — lives in `effectful-core`, which is
  the conventional, lighter dependency for a library. The test suite may additionally pull
  `effectful` if a concurrency helper is convenient, but the library itself stays on
  `effectful-core`. Date: 2026-06-08.

- Decision: Provide three streaming-related surfaces: blocking `complete` (drains to a
  `Response`), `streamCollect` (materializes the full `[AssistantMessageEvent]`), and the
  higher-order `streamEach` (runs a caller-supplied `AssistantMessageEvent -> Eff es ()`
  callback per event, preserving incremental streaming inside `Eff`). Rationale:
  `streamCollect` is the convenient common case; `streamEach` preserves true incrementality
  for consumers that need deltas, and is the operation that justifies handling a
  higher-order effect (running an `Eff` action from inside the interpreter via `LocalEnv`
  and `localSeqUnliftIO`). Date: 2026-06-08.


- Decision (2026-06-08, during M1): The `baikai-effectful.cabal` written in M1 contains only
  the `library` stanza; the `test-suite baikai-effectful-test` stanza is added in M2 when its
  source modules (`StubProvider`/`CompleteSpec`/`Main`) first exist. Rationale: the root
  `cabal.project` sets `tests: True`, so `cabal build baikai-effectful` builds enabled
  test-suites too; declaring a test suite whose `other-modules` don't yet exist would break
  M1's "build succeeds" acceptance. Deferring the stanza keeps every milestone's build green.

- Decision (2026-06-08, during M1): `baikai-effectful/LICENSE` is a symlink to `../LICENSE`
  (the repo-root BSD-3-Clause file), matching `baikai-claude/LICENSE` exactly, rather than a
  copied file. Rationale: consistency with the existing sibling packages; one source of truth.

- Decision (2026-06-08, during M4): the usage doc is a package-local `baikai-effectful/README.md`
  (referenced via `extra-doc-files`), not a `docs/user/effectful.md` registered in `mori.dhall`'s
  `docs` list. Rationale: the binding is a developer-facing library artifact, so its docs live
  with the package and travel with it on Hackage; the `docs/user/` set is baikai's end-user
  guide corpus and pulling the effectful binding into it would conflate audiences. The plan
  explicitly allowed either; README was chosen for locality.

- Decision (2026-06-08, during M4): the live `LiveSpec` exercises the **OpenAI** provider
  (`Baikai.Provider.OpenAI.Api.register`, model `openai_gpt_4o_mini`) via `runBaikai` (global
  registry), with the key sourced from `OPENAI_API_KEY`. Rationale: `register` targets the
  global registry that `runBaikai` binds, and OpenAI's key was the one likely to be present;
  the choice is cosmetic (any registered provider works) and confined to the test suite, which
  is the only component that depends on `baikai-openai`.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**At M1–M4 completion (2026-06-08).** The package `baikai-effectful-0.1.0.0` exists, builds,
and ships exactly what the Purpose described: a thin, policy-free `effectful` binding over
baikai's transport — the dynamic `Baikai` effect (`Complete`/`StreamCollect`/`StreamEach`),
the operations `complete`/`streamCollect`/`streamEach`, and the interpreters
`runBaikai`/`runBaikaiWith`. It adds no retries, caching, budgets, or error remapping; the
blocking path propagates `BaikaiError` and the streaming paths surface a terminal `EventError`
in-band, verbatim from baikai.

Observable result against the original purpose:

- `cabal build baikai-effectful` → builds `baikai-effectful-0.1.0.0`. ✓
- `cabal test baikai-effectful-test` → 4/4 green with no network: `CompleteSpec` returns
  `"hello from stub"`; `StreamSpec` proves `streamEach` delivers the same ordered events as
  `streamCollect`; `LiveSpec` prints its skip line. ✓
- `mori show --full` lists `baikai-effectful` (dep `shinzui/baikai:baikai`). ✓
- Live demo wired and gated on `BAIKAI_EFFECTFUL_LIVE`. ✓ (transcript pending a user-approved run)

Gaps / lessons:

- The pre-implementation validation missed that `flattenAssistantText` is **not** a baikai
  export (only `flattenAssistantBlocks` is); the `Vector AssistantContent -> Text` reduction
  is a per-consumer helper. Caught at first compile, resolved in `StubProvider`. Lesson:
  "grep the one module" under-validates a name that *looks* like a library helper but isn't.
- baikai's real streams carry a **live wall-clock `EventStart` timestamp**; naive cross-run
  event equality is therefore unstable. The stub was made deterministic (fixed events) so the
  `streamEach`/`streamCollect` agreement test is exact. This is also useful guidance for any
  downstream consumer asserting on streamed events.
- The interpreter signatures and operation shapes match what shikumi's substrate plan expects
  to build its `LLM` effect on top of; nothing here changed that contract.


## Context and Orientation

Read this in full before editing. It assumes no prior knowledge of this repository.

### The baikai repository layout

`/Users/shinzui/Keikaku/bokuno/baikai` is a multi-package cabal project. The root
`cabal.project` lists the packages:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-smoke
  baikai-trace-otel
```

Each package is a subdirectory with its own `<name>.cabal`. The core package is `baikai`
(directory `baikai/`, module prefix `Baikai.*`). The provider packages `baikai-claude` and
`baikai-openai` are thin layers that register provider handlers. You will add a sixth
package directory, `baikai-effectful/`, alongside these.

All packages share the same style, defined as a `common-options` stanza copied into each
`.cabal`. From `baikai/baikai.cabal`:

```cabal
common common-options
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-uni-patterns
    -Wincomplete-record-updates -Wredundant-constraints
    -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
    -Wmissing-deriving-strategies
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings
```

Note `default-language: GHC2024` and `-Wmissing-export-lists` (every module must have an
explicit export list). The compiler is provided by the repo's Nix devShell (currently
ghc912); all Haskell dependencies resolve from Hackage, including `effectful` /
`effectful-core` and the `streamly` / `streamly-core` pair already used by baikai.

### The baikai transport surface this binding wraps

The top module `Baikai` re-exports the public surface. The names this package touches, with
the exact signatures (confirmed against `baikai/src/Baikai/Provider/Registry.hs` and
`baikai/src/Baikai/Stream.hs`):

```haskell
-- Blocking dispatch. The bare form uses the process-global registry; the "With"
-- form takes an explicit registry. completeRequest THROWS BaikaiError on failure.
completeRequest     :: Model -> Context -> Options -> IO Response
completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response

-- Streaming dispatch (streamly stream). Does NOT throw; failures arrive as a terminal
-- EventError; an unregistered Api tag yields a one-event error stream.
streamRequest       :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequestWith   :: ProviderRegistry -> Model -> Context -> Options -> Stream IO AssistantMessageEvent

-- The process-global registry and the constructor for an isolated one (tests use this).
globalProviderRegistry :: ProviderRegistry
newProviderRegistry    :: IO ProviderRegistry          -- Baikai.Provider.Registry

-- A per-Api handler. Tests build one of these by hand and register it.
data ApiProvider = ApiProvider
  { apiTag   :: !Api
  , stream   :: !(Model -> Context -> Options -> Stream IO AssistantMessageEvent)
  , complete :: !(Model -> Context -> Options -> IO Response) }
registerApiProviderWith :: ProviderRegistry -> ApiProvider -> IO ()   -- Baikai.Provider.Registry
registerApiProvider     :: ApiProvider -> IO ()                       -- into the global registry

-- The Api tag the registry keys on.
data Api = OpenAIChatCompletions | AnthropicMessages | OpenAICompletionsCli
         | AnthropicMessagesCli | Custom !Text

-- Core records (fields abbreviated). Build values from the empty bases _Context / _Options
-- using generic-lens labels, e.g. `_Options & #maxTokens .~ Just 32`.
data Context  = Context  { systemPrompt :: Maybe Text, messages :: Vector Message, tools :: Vector Tool }
data Options  = Options  { maxTokens :: Maybe Natural, temperature :: Maybe Double, ... }
data Response = Response { message :: AssistantPayload, model :: Model, api :: Api
                         , provider :: Text, responseId :: Maybe Text, latencyMs :: Integer }
data Model    = Model    { modelId :: Text, name :: Text, api :: Api, provider :: Text, ... }

-- Streaming events. Exactly one EventStart first; exactly one EventDone (success) or
-- EventError (failure) last; the terminal payload carries the assembled message + Usage.
data AssistantMessageEvent
  = EventStart StartPayload | TextStart .. | TextDelta .. | TextEnd ..
  | ThinkingStart .. | ThinkingDelta .. | ThinkingEnd ..
  | ToolCallStart .. | ToolCallDelta .. | ToolCallEnd ..
  | EventDone TerminalPayload | EventError TerminalPayload

-- Error thrown by the blocking path (module Baikai.Error):
data BaikaiError = ProviderError !Text | RequestInvalid !Text | DecodeError !Text
                 | ProcessError !Int !Text

-- Text extraction helpers (module Baikai.Response):
flattenAssistantBlocks :: Response -> Vector AssistantContent
flattenAssistantText   :: Vector AssistantContent -> Text
```

The streamly stream type comes from `Streamly.Data.Stream` (`import Streamly.Data.Stream
(Stream)`, `import Streamly.Data.Stream qualified as Stream`). To materialize a stream into
a list use `Stream.toList :: Monad m => Stream m a -> m [a]` (here `m ~ IO`). baikai already
depends on `streamly >=0.11 && <0.13` and `streamly-core >=0.3 && <0.5`; the new package
declares the same bounds.

### What `effectful` gives us

`effectful` (library packages `effectful-core` and the umbrella `effectful`) is an
effect-system library. The working monad is `Eff es a`. A **dynamic** effect declares its
operations as a GADT of kind `Effect` (`(Type -> Type) -> Type -> Type`); an *interpreter*
turns each operation into real work and peels the effect off the stack. The functions used
here, with signatures (all from `effectful-core`):

```haskell
-- Effectful (entry points)
runEff  :: Eff '[IOE] a -> IO a
liftIO  :: IOE :> es => IO a -> Eff es a        -- via MonadIO (Eff es)

-- Effectful.Dispatch.Dynamic (declaring / using / interpreting dynamic effects)
send      :: (DispatchOf e ~ 'Dynamic, e :> es) => e (Eff es) a -> Eff es a
interpret :: DispatchOf e ~ 'Dynamic
          => (forall r localEs. (HasCallStack, e :> localEs)
                => LocalEnv localEs es -> e (Eff localEs) r -> Eff es r)
          -> Eff (e : es) a -> Eff es a
-- `interpret` peels effect `e` off the front by giving each operation a handler. The
-- handler runs in `Eff es` (the remaining effects). `LocalEnv localEs es` carries the
-- environment needed to run higher-order arguments (an `Eff` action that the *caller*
-- supplied) back inside the handler.

-- Running a caller-supplied Eff action inside a handler (needed by StreamEach):
localSeqUnliftIO
  :: IOE :> es
  => LocalEnv localEs es
  -> ((forall r. Eff localEs r -> IO r) -> IO a)
  -> Eff es a
-- Gives you a function that turns the caller's `Eff localEs` action into plain `IO`, so you
-- can call it from inside an `IO` context (here, from within a streamly fold/iteration).
```

For a **first-order** operation (no `Eff` arguments), like `Complete`, the handler ignores
the `LocalEnv` and just does `liftIO` of the baikai call. For a **higher-order** operation,
like `StreamEach` (whose argument is itself an `Eff` action — the per-event callback), the
handler uses `localSeqUnliftIO` to run that callback as `IO` while iterating the stream.

### Where this package fits

`baikai-effectful` depends only on `baikai` (for the transport functions and types),
`effectful-core` (for the effect machinery), `streamly`/`streamly-core` (for `Stream` and
`Stream.toList`), and the usual `base`, `text`, `vector`. It introduces no provider code and
no policy. It is buildable and testable on its own with a hand-rolled stub provider; no
network or API key is required for the default test run.


## Plan of Work

Four milestones. Each ends in a `cabal build` or `cabal test` you can run, with the output
you should see. All paths are repository-relative to `/Users/shinzui/Keikaku/bokuno/baikai`.

### Milestone 1 — Scaffold the `baikai-effectful` package

Scope: create a new package that compiles and is wired into the build and into `mori.dhall`.
At the end, `cabal build baikai-effectful` succeeds with an (almost empty) `Baikai.Effectful`
module, proving the `effectful-core` dependency resolves and the package is part of the
project.

Create the directory `baikai-effectful/` and within it `baikai-effectful.cabal`. Mirror the
repo's `common-options` verbatim so style and warnings match the other packages:

```cabal
cabal-version: 3.4
name:          baikai-effectful
version:       0.1.0.0
synopsis:      effectful binding for the baikai AI-provider transport
description:
  A thin, policy-free effectful binding over baikai's transport. Provides the dynamic
  `Baikai` effect (Complete / StreamCollect / StreamEach) and interpreters over a real or
  isolated provider registry. Adds no retries, caching, budgets, or error remapping.
category:      AI
license:       BSD-3-Clause
license-file:  LICENSE
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
copyright:     (c) 2026 Nadeem Bitar
build-type:    Simple

common common-options
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-uni-patterns
    -Wincomplete-record-updates -Wredundant-constraints
    -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
    -Wmissing-deriving-strategies
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

library
  import:          common-options
  hs-source-dirs:  src
  exposed-modules:
    Baikai.Effectful
  build-depends:
    , baikai          ^>=0.1.0
    , base            >=4.20   && <5
    , effectful-core
    , streamly        >=0.11   && <0.13
    , streamly-core   >=0.3    && <0.5
    , text            ^>=2.1
    , vector

test-suite baikai-effectful-test
  import:         common-options
  type:           exitcode-stdio-1.0
  hs-source-dirs: test
  main-is:        Main.hs
  ghc-options:    -threaded -with-rtsopts=-N
  other-modules:
    StubProvider
    CompleteSpec
    StreamSpec
  build-depends:
    , baikai
    , baikai-effectful
    , base            >=4.20   && <5
    , effectful-core
    , streamly
    , streamly-core
    , tasty
    , tasty-hunit
    , text
    , vector
```

Copy a `LICENSE` file into `baikai-effectful/` (copy `baikai-claude/LICENSE`, which is
BSD-3-Clause, so the `license-file:` resolves). 

Create `baikai-effectful/src/Baikai/Effectful.hs` with a minimal but real module so the
library compiles. For M1 it can re-export the baikai vocabulary callers will use; the effect
itself arrives in M2:

```haskell
-- | An effectful binding for baikai's transport. (Effect + interpreters land in M2/M3.)
module Baikai.Effectful
  ( -- * Re-exports of the baikai request/response vocabulary
    Model
  , Context
  , Options
  , Response
  , AssistantMessageEvent
  ) where

import Baikai (AssistantMessageEvent, Context, Model, Options, Response)
```

Add the package to the root `cabal.project` `packages:` list (append `baikai-effectful`):

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-smoke
  baikai-trace-otel
  baikai-effectful
```

Register the package in `mori.dhall` so `mori` discovers it. Add a `Schema.Package`
entry to the `packages = [ ... ]` list, in the same shape as `baikai-claude`, declaring its
dependency on the core package:

```dhall
, Schema.Package::{
  , name = "baikai-effectful"
  , type = Schema.PackageType.Library
  , language = Schema.Language.Haskell
  , path = Some "baikai-effectful"
  , description = Some
      "effectful binding for the baikai transport: the Baikai effect and interpreters"
  , dependencies =
    [ Schema.Dependency.ByName "shinzui/baikai:baikai" ]
  }
```

Acceptance: from `/Users/shinzui/Keikaku/bokuno/baikai`, `cabal build baikai-effectful`
exits 0 and builds `baikai-effectful-0.1.0.0`. `dhall lint mori.dhall` (or `mori show
--full`) accepts the updated descriptor and lists `baikai-effectful` among the packages.

### Milestone 2 — The `Baikai` effect, blocking `complete`, and interpreters

Scope: define the dynamic effect and the blocking operation, with interpreters over the
global and an explicit registry. Prove it end-to-end through `Eff` with a hand-rolled stub
provider in an isolated registry — no network.

Extend `baikai-effectful/src/Baikai/Effectful.hs`. Declare the effect and the first
operation, the smart constructor, and the two interpreters:

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}

module Baikai.Effectful
  ( -- * The effect
    Baikai (..)
  , complete
    -- * Interpreters
  , runBaikai
  , runBaikaiWith
    -- * Re-exports of the baikai request/response vocabulary
  , Model
  , Context
  , Options
  , Response
  , AssistantMessageEvent
  ) where

import Baikai (AssistantMessageEvent, Context, Model, Options, Response)
import Baikai qualified
import Baikai.Provider.Registry (ProviderRegistry)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Streamly.Data.Stream qualified as Stream

-- | The provider-neutral baikai transport effect. Operations mirror baikai's transport
-- functions. This effect carries NO policy: failures propagate exactly as baikai produces
-- them (the blocking path throws BaikaiError; streaming surfaces a terminal EventError).
data Baikai :: Effect where
  -- | A blocking completion. Mirrors 'Baikai.completeRequest'.
  Complete    :: Model -> Context -> Options -> Baikai m Response
  -- | A streaming completion materialized into the full event list (M3).
  StreamCollect :: Model -> Context -> Options -> Baikai m [AssistantMessageEvent]
  -- | A streaming completion where each event is handed to a caller callback (M3).
  StreamEach  :: Model -> Context -> Options -> (AssistantMessageEvent -> m ()) -> Baikai m ()

type instance DispatchOf Baikai = 'Dynamic

-- | Issue a blocking completion. Throws baikai's 'Baikai.Error.BaikaiError' on failure,
-- just like 'Baikai.completeRequest' — this binding does not catch it.
complete :: (Baikai :> es) => Model -> Context -> Options -> Eff es Response
complete m c o = send (Complete m c o)
```

Now the interpreters. The first-order `Complete` operation is handled by `liftIO` of
baikai's registry-scoped call. `runBaikaiWith` binds an explicit registry; `runBaikai` binds
the global one. (The `StreamCollect`/`StreamEach` cases are added in M3; for M2 you may
implement only `Complete` and leave the streaming cases as a clearly-marked `error
"M3"` placeholder so the module still type-checks — or implement all three now and skip the
streaming tests until M3. Note which you chose in Progress.)

```haskell
-- | Interpret 'Baikai' against an explicit provider registry. Requires 'IOE' because the
-- operations are ultimately baikai 'IO' calls. No retries, caching, or error remapping.
runBaikaiWith :: (IOE :> es) => ProviderRegistry -> Eff (Baikai : es) a -> Eff es a
runBaikaiWith reg = interpret $ \env -> \case
  Complete m c o ->
    liftIO (Baikai.completeRequestWith reg m c o)
  StreamCollect m c o ->
    liftIO (Stream.toList (Baikai.streamRequestWith reg m c o))
  StreamEach m c o k ->
    -- higher-order: run the caller's `k` (an Eff action) as IO while iterating. See M3.
    localSeqUnliftIO env $ \unlift ->
      Stream.fold (Fold.drainMapM (unlift . k)) (Baikai.streamRequestWith reg m c o)

-- | Interpret 'Baikai' against baikai's process-global provider registry.
runBaikai :: (IOE :> es) => Eff (Baikai : es) a -> Eff es a
runBaikai = runBaikaiWith Baikai.globalProviderRegistry
```

(For M2, if you defer streaming, the two streaming cases can be
`error "Baikai.Effectful: streaming arrives in M3"`. The imports `localSeqUnliftIO`,
`Fold`/`Fold.drainMapM` then move in with M3.)

Create the test stub `baikai-effectful/test/StubProvider.hs`. It builds an isolated registry
with `newProviderRegistry`, registers an `ApiProvider` whose `apiTag` matches the `Api` of a
hand-rolled `Model`, whose `complete` returns a fixed `Response` carrying known text, and
whose `stream` yields a minimal valid event sequence (`EventStart`, a `TextDelta`/`TextEnd`,
`EventDone`). Expose:

```haskell
module StubProvider
  ( stubRegistry      -- :: Text -> IO ProviderRegistry  (complete returns the given text)
  , stubModel         -- :: Model                         (its `api` tag the stub serves)
  , stubContext       -- :: Context
  , stubOptions       -- :: Options
  ) where
```

Build `stubModel` by hand (a `Model` whose `api` is a known tag such as `Custom "stub"` and
with dummy `modelId`/`provider`/cost fields) so it needs no real catalog entry, and register
an `ApiProvider` with the matching `apiTag`. Build `stubContext`/`stubOptions` from baikai's
empty bases `_Context`/`_Options` via generic-lens labels. The `stream` field of the stub can
produce its events with `Stream.fromList [EventStart .., TextDelta .., TextEnd .., EventDone ..]`.

Create `baikai-effectful/test/CompleteSpec.hs`. The headline test runs the whole stack:

```haskell
-- inside a tasty testCase:
reg <- stubRegistry "hello from stub"
out <- runEff . runBaikaiWith reg $ do
         r <- complete stubModel stubContext stubOptions
         pure (flattenAssistantText (flattenAssistantBlocks r))
out @?= "hello from stub"
```

This proves: the effect dispatches via `send`, the interpreter calls baikai through the
isolated registry, and the `Response` flows back through `Eff`.

Create `baikai-effectful/test/Main.hs` that imports the `CompleteSpec` (and later
`StreamSpec`) trees into one `tasty` `defaultMain`.

Acceptance: `cabal test baikai-effectful-test` runs `CompleteSpec` and the end-to-end stub
case returns `"hello from stub"`. To prove the test bites, temporarily change the stub's
fixed text and confirm the assertion fails, then restore.

### Milestone 3 — Streaming: `streamCollect` and the higher-order `streamEach`

Scope: implement and test the two streaming operations. `streamCollect` materializes the
event list; `streamEach` runs a caller-supplied `Eff` callback once per event, preserving
incremental consumption inside `Eff`. The `streamEach` handler is the one that demonstrates
running a caller's `Eff` action from inside an interpreter via `localSeqUnliftIO`.

Add the smart constructors to `Baikai.Effectful`'s export list and definitions:

```haskell
-- | Materialize a streaming completion into the full event list. Convenient when you do
-- not need incremental deltas. Does not throw on provider failure; a terminal 'EventError'
-- appears as the last element (baikai semantics).
streamCollect :: (Baikai :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
streamCollect m c o = send (StreamCollect m c o)

-- | Stream a completion, invoking the callback on each event in order, inside 'Eff'.
-- Preserves incrementality: the callback sees events as they arrive. The callback runs in
-- the same effect context as the caller.
streamEach
  :: (Baikai :> es)
  => Model -> Context -> Options
  -> (AssistantMessageEvent -> Eff es ())
  -> Eff es ()
streamEach m c o k = send (StreamEach m c o k)
```

Complete the interpreter cases in `runBaikaiWith` (replacing any M2 placeholders). Add the
imports `import Effectful.Dispatch.Dynamic (localSeqUnliftIO)` and
`import Streamly.Data.Fold qualified as Fold`:

```haskell
  StreamCollect m c o ->
    liftIO (Stream.toList (Baikai.streamRequestWith reg m c o))

  StreamEach m c o k ->
    -- `k` is the caller's Eff action (a higher-order argument). `localSeqUnliftIO` gives a
    -- function `unlift :: forall r. Eff localEs r -> IO r` valid for the duration of the
    -- block, so we can run `k event` as IO inside a streamly fold that drains the stream.
    localSeqUnliftIO env $ \unlift ->
      Stream.fold
        (Fold.drainMapM (\event -> unlift (k event)))
        (Baikai.streamRequestWith reg m c o)
```

Here `Fold.drainMapM :: Monad m => (a -> m b) -> Fold m a ()` (from `Streamly.Data.Fold`)
runs an effectful action per element and discards results; `Stream.fold` drives the stream
through that fold in `IO`. `localSeqUnliftIO` (from `Effectful.Dispatch.Dynamic`) is what
lets the per-event `Eff` callback run inside that `IO` context. The `env :: LocalEnv localEs
es` is the first argument the `interpret` handler already receives.

Create `baikai-effectful/test/StreamSpec.hs` with two tests:

1. **streamCollect returns the stub event sequence.** Drive `streamCollect` through
   `runBaikaiWith reg`; assert the returned list has the expected shape — first element is an
   `EventStart`, last is an `EventDone`, and a `TextDelta` carrying the stub text appears in
   between. (Match on constructors / extract the delta text rather than deriving `Eq` on the
   whole event if that is awkward.)

2. **streamEach observes each event in order.** Allocate an `IORef [AssistantMessageEvent]`
   (or a `TVar`), run `streamEach stubModel stubContext stubOptions (\e -> liftIO (modifyIORef' ref (e:)))`
   through `runEff . runBaikaiWith reg`, then read the ref, reverse it, and assert it equals
   the list `streamCollect` returns for the same inputs. This proves the higher-order
   callback runs inside `Eff` once per event, in order.

Acceptance: `cabal test baikai-effectful-test` runs `StreamSpec` and both cases pass. The
`streamEach`/`streamCollect` agreement test proves the higher-order interpreter is correct.

### Milestone 4 — Docs and a gated live demo

Scope: add a short usage note and a live, gated end-to-end demo so the package is
demonstrably real against an actual provider, without making the default test run depend on
network or credentials.

Add a `LiveSpec` test (list it in `other-modules`, import its tree into `Main.hs`) guarded
at runtime by the environment variable `BAIKAI_EFFECTFUL_LIVE`:

```haskell
-- pseudo-Haskell sketch:
live <- lookupEnv "BAIKAI_EFFECTFUL_LIVE"
case live of
  Just "1" -> do
    Baikai.Provider.OpenAI.Api.register     -- or Claude; pick by available key
    out <- runEff . runBaikai $ do
             r <- complete Baikai.Models.Generated.openai_gpt_4o_mini termCtx terseOpts
             pure (flattenAssistantText (flattenAssistantBlocks r))
    putStrLn ("LIVE: " <> unpack out)
    assertBool "non-empty" (not (T.null out))
  _ -> putStrLn "BAIKAI_EFFECTFUL_LIVE not set; skipping live test"
```

This test depends on a provider package (`baikai-openai` or `baikai-claude`) only in the
test suite, not in the library — add it to the test `build-depends` if you include this
milestone. Use a real catalog model from `Baikai.Models.Generated` (e.g. `openai_gpt_4o_mini`
or `anthropic_claude_haiku_4_5`), a terse system prompt, and a small `maxTokens`; rely on the
provider reading its key from the environment (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`).

Add a short usage doc `baikai-effectful/README.md` (or a `docs/user/effectful.md` entry, and
register it in `mori.dhall`'s `docs` list if you choose the latter). The doc shows the three
operations and the two interpreters, and states the policy-free contract explicitly: this
binding faithfully mirrors baikai and adds no retries/caching/budgets/error-remapping — those
belong one layer up.

Acceptance: with no env var, `cabal test baikai-effectful-test` prints the skip line and
stays green (hermetic CI). With `BAIKAI_EFFECTFUL_LIVE=1` and a valid key,
`BAIKAI_EFFECTFUL_LIVE=1 cabal test baikai-effectful-test` prints a non-empty `LIVE:` line
and passes. `mori show --full` lists `baikai-effectful`. Capture the live transcript here
when first run.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai` unless
noted.

Build the new package (Milestone 1):

```bash
cabal build baikai-effectful
```

Expected (abridged):

```text
Resolving dependencies...
Building library for baikai-effectful-0.1.0.0...
```

Validate the mori descriptor after editing it (Milestone 1):

```bash
dhall lint mori.dhall
mori show --full | grep -A1 baikai-effectful
```

Run the hermetic test suite (Milestones 2–3; no network):

```bash
cabal test baikai-effectful-test
```

Expected (abridged):

```text
baikai-effectful
  CompleteSpec
    complete returns stub text:            OK
  StreamSpec
    streamCollect returns event sequence:  OK
    streamEach observes each event:        OK

All N tests passed
```

Run the live demo (Milestone 4; needs network + key):

```bash
BAIKAI_EFFECTFUL_LIVE=1 OPENAI_API_KEY=sk-... cabal test baikai-effectful-test
```

Expected:

```text
LIVE: Hi.
  live provider call returns text: OK
```

Without the env var:

```bash
cabal test baikai-effectful-test
```

```text
BAIKAI_EFFECTFUL_LIVE not set; skipping live test
  live provider call returns text: OK
```


## Validation and Acceptance

The plan is complete when all of the following are observably true from the repo root:

- `cabal build baikai-effectful` exits 0 and builds `baikai-effectful-0.1.0.0`, proving the
  package, its `effectful-core` dependency, and the wiring into `cabal.project` resolve
  (Milestone 1).
- `mori show --full` lists `baikai-effectful` with a dependency on `shinzui/baikai:baikai`
  (Milestone 1).
- `cabal test baikai-effectful-test` exits 0 with `CompleteSpec` and `StreamSpec` green and
  no network access. The decisive cases are behavioral:
  - `CompleteSpec` returns exactly `"hello from stub"`, proving a value flows `call site ->
    send -> interpret -> baikai (isolated registry) -> Response -> Eff -> caller`.
  - `StreamSpec` "streamEach observes each event" yields the same ordered event list that
    `streamCollect` returns, proving the higher-order callback runs inside `Eff` per event.
- With `BAIKAI_EFFECTFUL_LIVE=1` and a valid key, `cabal test baikai-effectful-test` prints
  a non-empty `LIVE:` line and passes; without it, the suite skips that case and stays green
  (Milestone 4).

To convince yourself a test genuinely bites: temporarily change the stub's fixed text and
re-run — `CompleteSpec` must fail — then restore. Temporarily make the `streamEach` callback
record only every other event and re-run — the agreement test must fail — then restore.


## Idempotence and Recovery

All steps are safe to repeat. `cabal build` and `cabal test` are idempotent. Writing the
scaffold files is idempotent — re-running a milestone overwrites the same files with the same
content. baikai provider registration is idempotent per `Api` tag, and the tests use
isolated registries via `newProviderRegistry`, so repeated runs never accumulate global
state. Editing `cabal.project` and `mori.dhall` is additive; if `dhall lint` rejects the
descriptor, the most common cause is a trailing comma or a field name mismatch against the
pinned schema — compare the new `Schema.Package` entry field-by-field against the existing
`baikai-claude` entry, which is known-good.

If `cabal build baikai-effectful` cannot resolve `effectful-core`, confirm it is available
from Hackage in the active package index (`cabal update` if the index is stale); baikai's
`cabal.project` already states all dependencies resolve from Hackage, so no
`source-repository-package` stanza is needed for this package.


## Interfaces and Dependencies

Libraries used and why:

- **baikai** — the transport being wrapped. The binding calls
  `Baikai.completeRequestWith` / `Baikai.streamRequestWith`, reads `globalProviderRegistry`,
  and re-exports `Model`/`Context`/`Options`/`Response`/`AssistantMessageEvent`. Tests build
  providers with `Baikai.Provider.Registry.{newProviderRegistry, ApiProvider,
  registerApiProviderWith}` and extract text with `flattenAssistantBlocks` /
  `flattenAssistantText`.
- **effectful-core** — the effect machinery. Modules: `Effectful` (`Eff`, `Effect`, `IOE`,
  `(:>)`, `runEff`, `liftIO`, and crucially `DispatchOf` + `Dispatch (Dynamic)` — these two
  live in `Effectful`, **not** in `Effectful.Dispatch.Dynamic`, so the `type instance
  DispatchOf Baikai = 'Dynamic` declaration must import them from `Effectful`),
  `Effectful.Dispatch.Dynamic` (`send`, `interpret`, `localSeqUnliftIO`, `LocalEnv`).
- **streamly / streamly-core** — `Streamly.Data.Stream` (`Stream`, `Stream.toList`,
  `Stream.fold`, `Stream.fromList`) and `Streamly.Data.Fold` (`Fold`, `Fold.drainMapM`) for
  materializing and draining baikai's event streams. Same version bounds baikai uses.
- **text, vector** — text/vector handling for events and helpers.
- **tasty, tasty-hunit** — the test runner (test suite only). The live milestone adds
  `baikai-openai` (or `baikai-claude`) to the test `build-depends` only.

Types and signatures that must exist at the end of each milestone (full module paths):

- End of M1: package `baikai-effectful` builds; `Baikai.Effectful` exists, compiles, and
  re-exports the baikai request/response vocabulary. `mori.dhall` lists the package.
- End of M2: in `Baikai.Effectful` —
  `data Baikai :: Effect` with at least `Complete :: Model -> Context -> Options -> Baikai m
  Response`; `type instance DispatchOf Baikai = 'Dynamic`;
  `complete :: (Baikai :> es) => Model -> Context -> Options -> Eff es Response`;
  `runBaikai     :: (IOE :> es) => Eff (Baikai : es) a -> Eff es a`;
  `runBaikaiWith :: (IOE :> es) => ProviderRegistry -> Eff (Baikai : es) a -> Eff es a`.
- End of M3: in `Baikai.Effectful` — the `StreamCollect` and `StreamEach` constructors plus
  `streamCollect :: (Baikai :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]`
  and
  `streamEach :: (Baikai :> es) => Model -> Context -> Options -> (AssistantMessageEvent -> Eff es ()) -> Eff es ()`,
  with all three operations handled in `runBaikaiWith`.
- End of M4: a `LiveSpec` gated on `BAIKAI_EFFECTFUL_LIVE`, and a usage doc.

**Consumer note (shikumi).** shikumi's substrate plan
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`)
intends to implement its higher-level `LLM` effect (which adds the shikumi error type,
retries/backoff, rate limiting, and budget) *in terms of* this `Baikai` effect, so that
shikumi's `LLM` interpreter requires `Baikai :> es` rather than touching `IOE`/baikai
directly. To keep that layering clean, the operation shapes here (`Complete`,
`StreamCollect`, `StreamEach`) and the interpreter signatures (`runBaikai`,
`runBaikaiWith`) must not change without updating that shikumi plan. This binding itself,
however, has no dependency on shikumi and ships independently.


## Revision Notes

- 2026-06-08 — Pre-implementation validation pass against the live source tree (baikai,
  effectful-core, streamly-core located via `mori`). All transport signatures, record fields,
  constructors, helper names, model names, and effectful/streamly export names in the plan
  were confirmed accurate, with one exception that was fixed:
  - **M2 import gap (compile-blocking).** The M2 module body declares
    `type instance DispatchOf Baikai = 'Dynamic`, but the import list imported neither
    `DispatchOf` nor the `Dynamic` constructor. Verified against
    `effectful/effectful-core/src/Effectful.hs` (exports `Effect`, `Dispatch(..)`,
    `DispatchOf`, `(:>)`, `IOE`, `runEff`, `MonadIO(..)` ⇒ `liftIO`) and
    `Effectful/Dispatch/Dynamic.hs` (exports `send`, `interpret`, `localSeqUnliftIO`,
    `LocalEnv`; **does not** re-export `DispatchOf`). Fixed the M2 import to
    `import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))` and
    corrected the Interfaces & Dependencies note that had misplaced `DispatchOf` under the
    Dynamic module.
  - Non-blocking note for implementation: in the optional M2-only state where the streaming
    cases are `error "M3"` placeholders, the `\env -> \case` handler leaves `env` unused,
    which trips `-Wunused-matches` under `-Wall` (a warning, not an error, since `-Werror`
    is not set). Either bind it as `\_env -> \case` in that interim state or implement all
    three operations in M2 (the plan already offers the latter as an option).

- 2026-06-08 — Implemented M1–M4. Highlights and deviations from the as-written plan (all
  recorded in Progress / Surprises / Decision Log above):
  - **Test-suite stanza deferred from M1 to M2.** With `tests: True` in `cabal.project`,
    `cabal build baikai-effectful` builds enabled test suites; declaring one whose modules
    don't yet exist would have broken M1's green build. The M1 cabal ships the `library`
    stanza only.
  - **`flattenAssistantText` is not a baikai export.** `StubProvider` now defines and exports
    the `Vector AssistantContent -> Text` reduction locally (baikai's own smoke tests do the
    same); all call-sites source it from there, not `Baikai`.
  - **All three operations implemented in M2** (not just `Complete`), so `runBaikaiWith`
    handles `Complete`/`StreamCollect`/`StreamEach` with no placeholders and `env` is used.
    M3 added only `StreamSpec`.
  - **Stub stream made deterministic** (hand-rolled fixed events) after `liftCompleteToStream`
    proved nondeterministic via its live `EventStart` timestamp, which broke the
    `streamEach`/`streamCollect` exact-equality test.
  - **Live demo uses OpenAI** and is gated on `BAIKAI_EFFECTFUL_LIVE`; usage doc shipped as a
    package `README.md` (via `extra-doc-files`) rather than a `mori`-registered `docs/user`
    entry.
