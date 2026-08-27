---
id: 39
slug: unify-the-error-contract-and-revive-error-classification
title: "Unify the error contract and revive error classification"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Unify the error contract and revive error classification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is EP-6 of the MasterPlan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`. It
hard-depends on EP-5 (`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`),
which reshapes `baikai/src/Baikai/Stream.hs` and the event payload types first. This plan
is written against the code as it exists today; every step that touches code EP-5 also
touches is explicitly flagged with "**Reconcile with EP-5**" so the implementer can adapt
to EP-5's landed shape instead of blindly applying stale instructions.


## Purpose / Big Picture

baikai advertises a load-bearing feature for anyone running "important tasks" through it:
when a call fails, the caller receives a typed `BaikaiError` whose `category` (for example
`RateLimited`, `AuthError`, `TransientError`) and `isRetryable` accessor let the
application decide retry policy without parsing error text. The 2026-07-01 review
(`docs/reviews/correctness-and-api-review.md`, Theme 1) found that this feature
is effectively dead: the classifiers that map HTTP failures onto categories are never
reached by real traffic, because the vendored SDKs deliver HTTP failures as plain text
strings and as `http-client` exceptions — shapes the classifiers do not match. A real
HTTP 429 from Anthropic today produces `errorInfo = Nothing`. On top of that, the library
speaks with two voices about *where* errors appear: API providers report failures in-band
(an error-shaped `Response`, a terminal `EventError`), while the CLI providers and
unregistered-tag dispatch throw exceptions, and one core function
(`liftCompleteToStream`) silently converts in-band errors into successes.

After this plan is implemented, the following holds and is demonstrated by tests:

- A real HTTP 429 (with a `Retry-After` header) from Anthropic or OpenAI yields, on both
  the streaming and blocking paths, a classified error with `category = RateLimited`,
  `httpStatus = Just 429`, a populated `retryAfterSeconds`, and `isRetryable = True`.
  Likewise 401/403 yield `AuthError`, 5xx/529 yield `TransientError`, and a 400 whose body
  indicates context overflow yields `ContextOverflow`.
- Every failure is reported through exactly one channel, everywhere: the blocking path
  returns a `Response` with `stopReason = ErrorReason` and `errorInfo = Just err`; the
  streaming path emits exactly one terminal `EventError` carrying the same `BaikaiError`.
  Nothing in the dispatch or provider paths throws for an in-protocol failure — not the
  CLI providers, not unregistered-tag dispatch, not a missing API-key environment
  variable.
- The invariant `stopReason == ErrorReason ⟹ errorInfo is present` is enforced
  structurally and by tests, and a new accessor
  `responseError :: Response -> Maybe BaikaiError` gives callers a single question to ask.
- A caller can see this working by running the updated test suites (commands in
  Validation and Acceptance), which feed the providers the *real* failure shapes the SDKs
  produce at runtime — not the fictional shapes the old tests used.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

Milestone 1 — core contract:

- [x] `responseError` and `errorResponse` added to `baikai/src/Baikai/Response.hs` and exported from the `Baikai` umbrella. (2026-07-03)
- [x] `httpError` and `parseRetryAfterSeconds` pure helpers added to `baikai/src/Baikai/Error.hs`. (2026-07-03)
- [x] `errorTerminal` in `baikai/src/Baikai/Stream/Event.hs` now requires a `BaikaiError` (non-Maybe); all core call sites updated. (2026-07-03)
- [x] `completeRequestWith` in `baikai/src/Baikai/Provider/Registry.hs` returns an error-shaped `Response` instead of throwing; haddock updated. (2026-07-03)
- [x] `liftCompleteToStream` in `baikai/src/Baikai/Stream.hs` emits `EventError` for error-shaped responses. (2026-07-03)
- [x] Reassembly (`finalizeState`) normalizes `ErrorReason`-without-`errorInfo` terminals. (2026-07-03)
- [x] `baikai-effectful/src/Baikai/Effectful.hs` haddock corrected to describe the in-band contract. (2026-07-03)
- [x] Core tests updated/added (`baikai/test/ErrorInfoSpec.hs`, `baikai/test/ErrorSpec.hs`); `cabal test baikai baikai-effectful` green. (2026-07-03)

Milestone 2 — Claude classification goes live:

- [x] `Baikai.Provider.Claude.Sse` local SSE transport added; non-2xx yields a classified `BaikaiError` with status, `Retry-After`, and body. (2026-07-03)
- [x] `classifyException` in `baikai-claude/src/Baikai/Provider/Claude/ErrorClass.hs` recognizes `HttpException`; `classifyErrorText` fallback parser for the SDK's `"HTTP error <code> ..."` text added. (2026-07-03)
- [x] `prepareCall` failures (missing key, bad base URL) caught and emitted as a classified terminal `EventError` — no mid-iteration throw. (2026-07-03)
- [x] `Message_Stop` with a refusal stop reason emits `EventError` with `errorInfo`, not `EventDone`. (2026-07-03)
- [x] `runClaudeCli` in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` reports in-band; no `throwIO` on the request path. (2026-07-03)
- [x] Claude tests feed the real shapes (raw HTTP responses, `HttpException` values, the exact SDK error text); `cabal test baikai-claude` green. (2026-07-03)

Milestone 3 — OpenAI classification goes live:

- [x] `Baikai.Provider.OpenAI.Sse` local SSE transport added (with `[DONE]` handling). (2026-07-03)
- [x] `classifyException` recognizes `HttpException`; `classifyErrorText` in `baikai-openai/src/Baikai/Provider/OpenAI/ErrorClass.hs` parses the SDK's `"HTTP error <code> ..."` text before phrase-sniffing. (2026-07-03)
- [x] `prepareCall` failures caught and emitted as classified terminal `EventError`. (2026-07-03)
- [x] `finish_reason = "content_filter"` terminates as `EventError` with `errorInfo`; unknown finish reasons carried as a diagnostic. (2026-07-03)
- [x] `runCodexCli` in `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` reports in-band; no `throwIO` on the request path. (2026-07-03)
- [x] OpenAI tests feed the real shapes; `cabal test baikai-openai` green. (2026-07-03)

Milestone 4 — conformance sweep, docs, and changelog:

- [x] Contract-assertion helper applied across provider tests: every error path yields exactly one terminal, `EventError ⟹ errorInfo` present, blocking `Response` satisfies `responseError`. (2026-07-03)
- [x] No-key stub tests (env var unset) assert one terminal `EventError` with category `AuthError` on both API providers. (2026-07-03)
- [x] Doc sweep: `Baikai.Provider.Registry`, `Baikai.Stream`, CLI provider haddocks, `baikai/CHANGELOG.md` breaking-change entry. (2026-07-03)
- [x] EP-5 plan (`docs/plans/38-...md`) and MasterPlan Decision Logs updated with the `errorTerminal` signature change. (2026-07-03)
- [x] `cabal build all --enable-tests` and all four test suites green; Outcomes & Retrospective written. (2026-07-03)


## Surprises & Discoveries

Pre-implementation research findings (2026-07-01), recorded here because they shaped the
whole plan; implementation-time discoveries should be appended below them.

- Both vendored SDKs short-circuit non-2xx streaming responses into a *text* error with an
  identical format. Claude SDK, `claude/src/Claude/V1.hs` lines 233–245 (source on disk at
  `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1.hs`):

  ```haskell
  let msg =
          "HTTP error "
          <> renderIntegral (Status.statusCode st)
          <> " "
          <> (Text.pack (S8.unpack (Status.statusMessage st)))
          <> (if SBS.null errBody then "" else ": " <> Text.pack (S8.unpack errBody))
  onEvent (Left msg)
  ```

  The OpenAI SDK (`openai/src/OpenAI/V1.hs` lines 482–494, on disk at
  `/Users/shinzui/Keikaku/hub/haskell/openai-project/openai/src/OpenAI/V1.hs`) is
  byte-for-byte the same format: `"HTTP error <code> <status message>"` with `": <body>"`
  appended only when the body is non-empty. Neither SDK ever produces a servant
  `FailureResponse` on the streaming path, which is why `responseToError` /
  `fromClientError` are dead code.
- Response *headers* are unreachable through both SDKs' streaming entry points. The claude
  SDK's `ssePostJSON` never looks at `responseHeaders`. The openai SDK's `ssePostJSON`
  actually has an `onMetadata` callback that receives the headers (V1.hs lines 476–481),
  but `createChatCompletionStream` discards it (`ssePostJSON ... (\_ -> pure ()) onEvent`,
  V1.hs line 391) and no metadata-carrying chat-completions variant is exported. So
  `Retry-After` cannot be recovered without owning the HTTP call — this forces the
  local-transport decision below.
- Network failures on both SDKs surface as `Network.HTTP.Client.HttpException`, never as
  servant `ClientError`. Claude: the request is made with `HTTP.Client.withResponse`
  directly (V1.hs line 232). OpenAI: the custom `app` runs `withResponse` inside
  `liftIO`, so an `HttpException` propagates straight out of `Client.runClientM` as a
  thrown IO exception (V1.hs lines 474–475 and 555–561) — servant's
  `ConnectionError` wrapping only happens in its own `performRequest`, which this path
  bypasses. This is why `classifyException`'s `ConnectionError → TransientError` branch is
  unreachable.
- Both SDKs hard-code `responseTimeoutNone` on the streaming request (claude V1.hs line
  229; openai V1.hs lines 469–473). Not this plan's problem (EP-8 owns `timeoutMs`), but
  the local SSE transport this plan introduces is exactly the seam EP-8 needs; noted in
  the MasterPlan integration points.
- Genuine *mid-stream* Anthropic error events (SSE frames whose JSON decodes to
  `{"type":"error","error":{...}}`) do reach `classifyErrorValue` as objects and classify
  correctly today. Only the far more common HTTP-level failures arrive as `String` values
  and defeat it.


## Decision Log

- Decision: Adopt the MasterPlan's in-band error contract everywhere. `completeRequestWith`
  stops throwing and returns an error-shaped `Response` outright — no deprecated throwing
  alias is kept.
  Rationale: fixed by the MasterPlan Decision Log (2026-07-01). A deprecated alias would
  preserve the split-brain contract this plan exists to kill; the package is pre-freeze
  (0.2, not on Hackage) so a breaking semantic change with a changelog entry is cheaper
  than carrying two dispatch functions. Callers who want exceptions get a convenience
  wrapper in EP-9.
  Date: 2026-07-01
- Decision: Recover HTTP status, `Retry-After`, and error body by **bypassing each SDK's
  SSE error handling with a small local transport wrapper** (one module per provider
  package: `Baikai.Provider.Claude.Sse`, `Baikai.Provider.OpenAI.Sse`), rather than
  parsing the SDK's `"HTTP error <code> ..."` text as the primary mechanism.
  Rationale: the SDKs discard response headers before the caller can see them (evidence in
  Surprises & Discoveries), so `Retry-After` — an explicit user-visible promise in the
  MasterPlan's Vision — is unrecoverable by text parsing. The MasterPlan explicitly
  permits wrapping/bypassing the SDK locally. The wrapper is ~120 lines of
  well-understood code copied in shape from the SDK's own `ssePostJSON`, reuses the SDK's
  `ClientEnv` (manager + parsed base URL) and typed event decoding, and creates the seam
  EP-8 needs for `timeoutMs`/header wiring. A text-format parser is *also* added as a
  defense-in-depth fallback classifier (it is ~10 lines and covers any residual SDK Left
  path, e.g. mid-stream aeson decode errors), and it is what the "real Left-text shape"
  unit tests exercise.
  Date: 2026-07-01
- Decision: Duplicate the small SSE line-parser in each provider package instead of
  hoisting a shared copy into the `baikai` core package.
  Rationale: core `baikai` has no `http-client`/`http-types` dependency today and should
  not grow one for two consumers; both provider packages already depend on `http-client`,
  `http-client-tls`, and `http-types` (see `baikai-claude/baikai-claude.cabal` lines
  51–53). The pure classification helpers that *can* be shared (`httpError`,
  `parseRetryAfterSeconds`) go in `Baikai.Error`, which is dependency-free.
  Date: 2026-07-01
- Decision: `responseError :: Response -> Maybe BaikaiError` lives in
  `baikai/src/Baikai/Response.hs` (re-exported by the `Baikai` umbrella), not in
  `Baikai.Error`.
  Rationale: it needs the `Response` type; `Baikai.Response` already imports
  `Baikai.Error` (the `errorInfo` field), so no new module or import cycle is needed.
  Putting it in `Baikai.Error` would invert the dependency.
  Date: 2026-07-01
- Decision: `responseError` returns `Just` for **every** `Response` with
  `stopReason == ErrorReason`, synthesizing a `providerError` from `errorMessage` when
  `errorInfo` is absent; and reassembly (`finalizeState`) performs the same normalization
  so the blocking path upholds the invariant even against a nonconforming third-party
  provider.
  Rationale: the MasterPlan asks for "smart constructors for terminals + a debug assertion
  in reassembly". Haskell has no cheap debug-only assert that survives review; a
  *normalizing* reassembly is strictly stronger (the invariant holds unconditionally for
  every drained response) and costs one `case`. Structural enforcement at construction
  time comes from the `errorTerminal` signature change below; the contract tests assert
  providers do not rely on the normalization.
  Date: 2026-07-01
- Decision: change `errorTerminal` in `baikai/src/Baikai/Stream/Event.hs` from
  `Maybe Text -> StopReason -> Message -> Maybe BaikaiError -> TerminalPayload` to
  `Maybe Text -> StopReason -> Message -> BaikaiError -> TerminalPayload` (the first
  argument is the response id added by EP-5; the payload field stays `Maybe BaikaiError`
  because it is shared with `EventDone`).
  Rationale: every construction site of an error terminal is forced to supply a
  classified error — the compiler enforces half the invariant. Call sites that today pass
  `Nothing` all have error text in hand and synthesize `providerError text`. This is an
  event-algebra-adjacent change in EP-5's territory: it MUST be recorded in
  `docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`'s Decision
  Log and the MasterPlan's Integration Points when implemented, per the MasterPlan rule
  against silent algebra changes.
  Date: 2026-07-01
- Decision: `finish_reason = "content_filter"` (and Anthropic's `Refusal`) keep mapping to
  `StopReason.ErrorReason` — no new `StopReason` constructor — and the terminal becomes an
  `EventError` carrying `errorInfo = Just err` with `category = OtherError`,
  `isRetryable = False`, and a message naming the raw reason.
  Rationale: `Baikai.StopReason` is documented as a small closed stable sum; the Claude
  provider already maps `Refusal → ErrorReason`, establishing "provider declined to
  finish" as an error-shaped outcome. `OtherError` over `InvalidRequest` because the
  request was well-formed; the caller cannot fix it by reshaping the request, and it must
  not be auto-retried. Adding a `ContentFilter` constructor was rejected as pre-freeze
  surface churn that EP-10 would have to re-review; revisit there if callers need to
  distinguish it (the category+message make it distinguishable meanwhile).
  Date: 2026-07-01
- Decision: unknown OpenAI finish reasons still terminate as a successful `EventDone` with
  `StopReason.Stop`, but the terminal message's `errorMessage` carries
  `"unrecognized finish_reason: <raw>"` as a diagnostic.
  Rationale: an unknown reason from an OpenAI-compatible host is almost always a benign
  vendor extension; failing the call would be worse than the current silent collapse. The
  in-band diagnostic makes the collapse observable without a logging dependency.
  `errorMessage` is documented as optional informational text; the failure contract is
  keyed on `stopReason`/`errorInfo`, not on `errorMessage` presence, and the haddock is
  updated to say so.
  Date: 2026-07-01
- Decision: CLI providers convert *all* request-path failures to error-shaped `Response`s
  — including unexpected synchronous exceptions (e.g. executable not found) via a
  sync-exception catch — instead of `throwIO`.
  Rationale: "in-band everywhere" is only true if the CLI `complete` handlers cannot
  throw. Exit-code failures map to `processError`; JSON-decode failures to `decodeError`;
  a missing binary or other `IOException` degrades to `providerError` text (category
  `OtherError`). Async exceptions are re-thrown so cancellation still works.
  Date: 2026-07-01


## Outcomes & Retrospective

Completed on 2026-07-03. The final result is one in-band error contract across core,
Claude, OpenAI, and the CLI providers: blocking failures are error-shaped `Response`s
discoverable through `responseError`, streaming failures are exactly one terminal
`EventError`, and provider HTTP failures retain status, `Retry-After`, retryability, and
the provider body through the new local SSE transports. The plan also repaired
`liftCompleteToStream`, unregistered-provider dispatch, `content_filter` / Anthropic
refusal handling, and the public documentation/changelog that described the old split
contract.

The work landed incrementally in the following commits: `98ee04a` introduced the core
contract, `d07d21f` made Claude classification live, `8a6dffa` made OpenAI
classification live, and the final conformance sweep records the provider contract
assertions and documentation updates. Validation on 2026-07-03 was:

```text
cabal build all --enable-tests
PASS

cabal test baikai baikai-claude baikai-openai baikai-effectful --test-show-details=direct
baikai: 115 tests passed
baikai-claude: 29 tests passed
baikai-openai: 33 tests passed
baikai-effectful: 4 tests passed
```

The main follow-on constraint for later plans is now explicit: EP-8 must extend the
`Baikai.Provider.Claude.Sse` and `Baikai.Provider.OpenAI.Sse` modules for
`Options.timeoutMs`, request headers, and host-specific transport behavior instead of
returning to the SDK streaming helpers that drop response headers.


## Context and Orientation

baikai is a multi-package Haskell workspace (`cabal.project` at the repository root
`/Users/shinzui/Keikaku/bokuno/baikai`). The packages this plan touches:

- `baikai/` — the core vocabulary and dispatch. Key modules:
  `baikai/src/Baikai/Error.hs` (the `BaikaiError` record: `category :: ErrorCategory`,
  `message`, `httpStatus`, `retryAfterSeconds`, `exitCode`; smart constructors
  `providerError`, `authError`, `rateLimited`, …; pure helpers `classifyHttpStatus`,
  `classifyHttpStatusWithBody`, `bodyIndicatesOverflow`),
  `baikai/src/Baikai/Response.hs` (the `Response` envelope with an
  `errorInfo :: Maybe BaikaiError` field),
  `baikai/src/Baikai/StopReason.hs` (closed sum `Stop | Length | ToolUse | ErrorReason |
  Aborted`),
  `baikai/src/Baikai/Stream/Event.hs` (the streaming event algebra
  `AssistantMessageEvent`; terminal payload builders `doneTerminal` / `errorTerminal`),
  `baikai/src/Baikai/Stream.hs` (dispatch `streamRequest`, the reassembly fold
  `reassembleResponse`, and `liftCompleteToStream`),
  `baikai/src/Baikai/Provider/Registry.hs` (the `ApiProvider` record with `stream` and
  `complete` handlers; `completeRequestWith` dispatch), and
  `baikai/src/Baikai/Auth.hs` (`resolveApiKey`, which **throws** an `AuthError`-category
  `BaikaiError` when an env var is unset).
- `baikai-claude/` — the Anthropic providers.
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (streaming producer over the vendored
  `claude` SDK), `.../ErrorClass.hs` (the classifiers), `.../Cli.hs` (the `claude -p`
  subprocess provider).
- `baikai-openai/` — the OpenAI providers, mirror structure:
  `baikai-openai/src/Baikai/Provider/OpenAI/{Api,ErrorClass,Cli}.hs`.
- `baikai-effectful/` — `baikai-effectful/src/Baikai/Effectful.hs`, a thin effect wrapper
  whose haddock currently claims the blocking path throws `BaikaiError`.

Terms used below. "In-band" means a failure is reported inside the normal return value —
a `Response` whose `stopReason` is `ErrorReason` and whose `errorInfo` carries the typed
error — rather than by throwing a Haskell exception. A "terminal event" is the exactly-one
`EventDone` (success) or `EventError` (failure) event that ends every event stream; both
wrap a `TerminalPayload {reason, message, errorInfo}`. "SSE" is Server-Sent Events, the
`data: <json>` line protocol both vendors stream responses over. A "classifier" is a
function mapping a vendor failure onto a `BaikaiError`.

How a streaming call works today, and where it breaks (all line numbers refer to the
working tree at the time of writing):

1. `streamRequestWith` (`baikai/src/Baikai/Stream.hs:89-100`) looks up the handler and
   returns its stream; unregistered tags get a one-event `EventError` stream — this path
   is already in-band and stays.
2. The provider's producer (e.g. `claudeMessagesStream`,
   `baikai-claude/src/Baikai/Provider/Claude/Api.hs:122-144`) runs `prepareCall` inside
   `Stream.concatEffect`. `prepareCall` (Api.hs:155-171) calls `mapRequest` (a pure
   `Either Text`), then `resolveKey` (Api.hs:168-171, which calls
   `Baikai.Auth.resolveApiKey` — **throws** on a missing env var), then
   `Claude.getClientEnv` (which calls servant's `parseBaseUrl` — **throws** on a malformed
   base URL). Neither throw is caught, so with no API key the stream throws mid-iteration
   having emitted **zero events**, violating the exactly-one-terminal contract. The OpenAI
   twin is `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:135-155` with `prepareCall` at
   175-199 (`resolveKey` at 196-199).
3. A forked worker drives the SDK's streaming callback. The claude worker
   (Api.hs:183-200) receives `Left errText` for every HTTP-level failure — the SDK
   converts non-2xx into text (see Surprises & Discoveries) — and wraps it as
   `Messages.Error {error = Aeson.String txt}`. The translator (Api.hs:349-353) then calls
   `classifyErrorValue` (`baikai-claude/src/Baikai/Provider/Claude/ErrorClass.hs:96-110`),
   which returns `Nothing` for any non-object value. **Result: a real 429/500/529/401
   produces `errorInfo = Nothing`.** The HTTP-status mapping in `responseToError` and
   `fromClientError` (ErrorClass.hs:49-90) is unreachable, and the existing unit tests in
   `baikai-claude/test/ErrorClassSpec.hs` pass only because they feed servant `ResponseF`
   values the runtime never constructs.
4. When the worker's `try @SomeException` catches an exception (claude Api.hs:186-196), it
   stashes `classifyException e`. But network failures are `HttpException` (http-client),
   not servant `ClientError`, so `classifyException` (ErrorClass.hs:44-47) falls through
   to `providerError` — category `OtherError`, `isRetryable = False`. **A connection reset
   is classified permanent.** Same disease in
   `baikai-openai/src/Baikai/Provider/OpenAI/ErrorClass.hs:41-55`, whose
   HTTP-status/`Retry-After` mapping (lines 57-79) is likewise dead; a 429 whose body
   happens to lack the sniffed phrases in `classifyErrorText` (lines 88-104) classifies as
   `OtherError`.
5. The blocking path is `complete = streamingComplete stream` for both API providers, so
   everything above applies to `completeRequest` too.

The other half of the problem is the split-brain contract:

- `completeRequestWith` (`baikai/src/Baikai/Provider/Registry.hs:93-100`) **throws**
  `providerUnavailable` for an unregistered tag, while the streaming twin reports the same
  condition in-band (`noProviderEvent`, `baikai/src/Baikai/Stream.hs:381-395`).
- Both CLI providers **throw**: `runClaudeCli`
  (`baikai-claude/src/Baikai/Provider/Claude/Cli.hs:163-187`) throws `processError` on
  non-zero exit, `decodeError` from `decodeResult` (Cli.hs:142-153), and `providerError`
  when the CLI reports `is_error`; `runCodexCli` / `consume`
  (`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs:119-162`) throws the same way.
- `liftCompleteToStream` (`baikai/src/Baikai/Stream.hs:291-335`) lifts a `complete`
  handler into a synthetic event stream, but `eventsFor` (Stream.hs:313-335)
  unconditionally ends with `EventDone` and drops `Response.errorInfo` — an error-shaped
  `Response` streams as a *success*, and `Baikai.Trace` (which switches on the terminal
  constructor, `baikai/src/Baikai/Trace.hs:211-239`) logs `CallFinished` instead of
  `CallFailed`.
- `baikai-effectful/src/Baikai/Effectful.hs` (module haddock lines 10-13, and the
  `Complete` operation docs at lines 49-50 and 62-63) documents "the blocking path throws
  `BaikaiError`" — already wrong for API providers, and wrong for everything once this
  plan lands.
- Finally, `mapFinishReason` (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:940-947`)
  maps `"content_filter"` to `ErrorReason`, but the clean-close path
  (`closeOpenStream`, Api.hs:657-679, `finishSeen` branch) emits `EventDone` with that
  reason and no `errorInfo` — an invariant violation; unknown finish reasons collapse
  silently to `Stop`. The Claude provider has the mirror bug: `mapStopReason` maps
  `Refusal → ErrorReason` (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:791-799`) and
  `Message_Stop` (Api.hs:346-348) emits it as `EventDone`.

EP-5 context the implementer must check before starting: EP-5
(`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`) lands first
and rewrites `reassembleResponse`, the `ThinkingEnd`/terminal payloads (response-id
carriage), `liftCompleteToStream`'s emitted sequence, introduces a sync-only exception
catch (replacing `tryAny` at Stream.hs:305-307), and decides whether lone-`EventError`
streams must be preceded by `EventStart`. Read its Decision Log and the landed code; the
"Reconcile with EP-5" flags below say what to adapt.


## Plan of Work

The work is four milestones: fix the contract in core (M1), revive classification in the
Claude package (M2), the same for OpenAI plus the `content_filter` finding (M3), then a
cross-provider conformance sweep with documentation and changelog (M4). Each milestone
builds and tests green on its own.


### Milestone 1 — one error contract in core

Scope: everything in the `baikai` and `baikai-effectful` packages. At the end of this
milestone, no core dispatch path throws for an in-protocol failure, error-shaped responses
survive `liftCompleteToStream` as `EventError`, the `ErrorReason ⟹ errorInfo` invariant is
enforced at construction (via `errorTerminal`) and at reassembly (via normalization), and
`responseError` exists. Verify with `cabal test baikai baikai-effectful`.

First, add the pure helpers to `baikai/src/Baikai/Error.hs` and export them:

```haskell
-- | Build a fully classified error from an HTTP failure's parts:
-- status code, optional Retry-After seconds, and the response body
-- (a snippet of which becomes the message; the body also feeds
-- context-overflow detection).
httpError :: Int -> Maybe Int -> Text -> BaikaiError

-- | Parse an integer-valued Retry-After header value ("12" -> Just 12).
-- The HTTP-date form yields Nothing.
parseRetryAfterSeconds :: Text -> Maybe Int
```

`httpError status retryAfter body` is the body of today's `responseToError`
(`baikai-claude/src/Baikai/Provider/Claude/ErrorClass.hs:63-81`) with the servant
`ResponseF` unpacking removed: category from `classifyHttpStatusWithBody`, message
`"HTTP <status>: <300-char body snippet>"`, `httpStatus = Just status`. Both provider
packages will call it directly (their `responseToError` becomes a thin adapter, kept so
the existing unit tests keep compiling). `parseRetryAfterSeconds` is the existing
`readMaybe`-based logic hoisted so it is written once.

Second, add to `baikai/src/Baikai/Response.hs`:

```haskell
-- | The single question a caller asks about failure. Returns 'Just'
-- exactly when the response is error-shaped (stopReason == ErrorReason):
-- the provider's classified 'errorInfo' when present, otherwise a
-- synthesized OtherError carrying the response's errorMessage text, so
-- the ErrorReason implies-error invariant holds for every Response.
responseError :: Response -> Maybe BaikaiError

-- | Build a conformant error-shaped Response for a failed call: empty
-- content, stopReason = ErrorReason, errorMessage = Just (message err),
-- errorInfo = Just err; model/api/provider copied from the Model.
errorResponse :: Model -> UTCTime -> Integer -> BaikaiError -> Response
```

(`UTCTime` is the response timestamp, `Integer` the measured `latencyMs`; pass `0` where
no meaningful latency exists, as the registry does.) Export both from the module and from
the `Baikai` umbrella in `baikai/src/Baikai.hs` (the umbrella re-exports
`module Baikai.Response`; confirm the new names appear in `:browse Baikai` or haddock).

Third, tighten `errorTerminal` in `baikai/src/Baikai/Stream/Event.hs`:

```haskell
errorTerminal :: Maybe Text -> StopReason -> Message -> BaikaiError -> TerminalPayload
errorTerminal rid r m e =
  TerminalPayload {reason = r, message = m, responseId = rid, errorInfo = Just e}
```

Fix every call site in core: `noProviderEvent` and `errorEvent` in
`baikai/src/Baikai/Stream.hs` already have a `BaikaiError` (or synthesize
`providerError errText` in `errorEvent`'s `Nothing` branch). Call sites in the provider
packages are fixed in M2/M3 (they will not compile until then if you build `all`, so
build/test per-package during the transition, or fix the mechanical
`Maybe`-to-definite changes in the same commit — preferred). Update `errorTerminal`'s
haddock, and the `TerminalPayload.errorInfo` haddock to state the invariant: "always
`Just` on an `EventError` terminal; always `Nothing` on `EventDone`". **Reconcile with
EP-5**: EP-5 may have added fields to `TerminalPayload` (response id) — keep them; and
this signature change must be recorded in EP-5's Decision Log and the MasterPlan
Integration Points section (do it now, as part of this milestone's commit).

Fourth, make `completeRequestWith` in `baikai/src/Baikai/Provider/Registry.hs` in-band.
Replace the `throwIO` branch (lines 98-100) with:

```haskell
Nothing -> do
  now <- getCurrentTime
  pure
    ( errorResponse
        m
        now
        0
        (providerUnavailable ("No provider registered for API: " <> renderApi (api m)))
    )
```

(import `Baikai.Response (errorResponse)` and `Data.Time (getCurrentTime)`; drop the
`Control.Exception (throwIO)` import). Rewrite the module haddock (lines 10-14) and the
function haddock (lines 90-92): dispatch **returns** an error-shaped `Response` with
`errorInfo` in the `ProviderUnavailable` category; it no longer throws. This is a
breaking behavior change — record it in `baikai/CHANGELOG.md` (see M4).

Fifth, fix `liftCompleteToStream` in `baikai/src/Baikai/Stream.hs`. In `eventsFor`
(lines 313-335), the terminal must reflect the response:

```haskell
terminalEvent = case responseError resp of
  Just be -> EventError (errorTerminal rid reason msg be)
  Nothing -> EventDone (doneTerminal rid reason msg)
```

where `reason = payload ^. #stopReason` as today and `rid = resp ^. #responseId`.
Because `responseError` synthesizes an error for `ErrorReason`-without-`errorInfo`, an
error-shaped response from any `complete` handler now always lifts to `EventError`, and
`Baikai.Trace` (which pattern-matches the terminal constructor at
`baikai/src/Baikai/Trace.hs:211-239`) logs `CallFailed` with no further change. Also
update `liftCompleteToStream`'s haddock (the bullet list at lines 277-290) to document
the `EventError` case. Keep emitting the block events before the
terminal — partial content on an error-shaped response remains recoverable. **Reconcile
with EP-5**: EP-5 rewrites this function's emitted sequence (EventStart-first invariant,
sync-only catch replacing `tryAny`); apply this terminal-selection logic to EP-5's landed
version, and use EP-5's sync-only catch helper instead of `tryAny` for the exception
branch.

Sixth, normalize in reassembly. In `finalizeState`
(`baikai/src/Baikai/Stream.hs:194-217`), after computing `(terminalMsg, terminalReason,
terminalError)`, add:

```haskell
normalizedError = case (terminalReason, terminalError) of
  (ErrorReason, Nothing) ->
    Just (providerError (fromMaybe "call failed with no error detail" errText))
  _ -> terminalError
```

where `errText` is the terminal message's `errorMessage` when it is an
`AssistantMessage`. Set `errorInfo = normalizedError` on the built `Response`. This makes
the blocking-path invariant unconditional even for a third-party provider that emits
`EventDone` with `ErrorReason`. **Reconcile with EP-5**: EP-5 owns
`reassembleResponse`'s new shape (terminal-authoritative content, response id); insert
the normalization into whatever its `finalizeState` equivalent looks like.

Seventh, fix the `baikai-effectful` haddock
(`baikai-effectful/src/Baikai/Effectful.hs`, module header lines 10-15, `Complete`
constructor docs lines 49-50, `complete` function docs lines 62-63): the blocking path
does **not** throw; it returns the `Response` as-is, and failures appear as
`stopReason == ErrorReason` with `errorInfo` populated — point readers at
`Baikai.responseError`. No code change is needed in that package.

Tests for this milestone (all in `baikai/test/`):

- `ErrorInfoSpec.hs` — keep the existing structured-threading test; add: (a)
  `completeRequestWith` on a fresh empty registry (use `newProviderRegistry`) returns —
  does not throw — a `Response` with `responseError` yielding category
  `ProviderUnavailable`; (b) register a provider whose `complete` returns an error-shaped
  `Response` built with `errorResponse` and whose `stream` is
  `liftCompleteToStream complete`; drain the stream with `Stream.toList` and assert the
  last event is `EventError` with the carried `errorInfo` (this is the regression test
  for Stream.hs:313-335) and that it is the only terminal; (c) a stream that emits
  `EventDone` with `reason = ErrorReason` (build the `TerminalPayload` record directly,
  since `doneTerminal` is honest) drains to a `Response` whose `responseError` is `Just`
  (the normalization test).
- `ErrorSpec.hs` — add unit tests for `httpError` (429 + retry-after → `RateLimited` with
  the hint; 400 + overflow body → `ContextOverflow`) and `parseRetryAfterSeconds`
  (`"12"` → `Just 12`; `"Wed, 21 Oct 2026 07:28:00 GMT"` → `Nothing`), plus
  `responseError` on a success response (`Nothing`) and on `_Response` with
  `stopReason` forced to `ErrorReason` (`Just`, synthesized).

Acceptance: `cabal test baikai baikai-effectful` passes; `cabal repl baikai` shows
`responseError` exported from `Baikai`.


### Milestone 2 — Claude: live classification via a local SSE transport

Scope: the `baikai-claude` package. At the end, a non-2xx from an Anthropic-compatible
host produces a terminal `EventError` whose `errorInfo` has the correct category, HTTP
status, `Retry-After`, and body-derived overflow detection; network failures classify
`TransientError`; a missing API key or bad base URL produces one classified terminal
`EventError` instead of a mid-iteration throw; the CLI provider is in-band. Verify with
`cabal test baikai-claude`.

Create `baikai-claude/src/Baikai/Provider/Claude/Sse.hs` (add to `exposed-modules` in
`baikai-claude/baikai-claude.cabal`; `http-client`, `http-client-tls`, `http-types`,
`servant-client` are already dependencies of the library — lines 51-55 of the cabal file).
Its job is exactly what the SDK's `ssePostJSON` does
(`/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1.hs:194-309`),
minus the header-discarding error path. Public surface:

```haskell
module Baikai.Provider.Claude.Sse
  ( claudeSseStream,
    sseFromResponse, -- exposed for tests
  )
where

-- | POST the request to /v1/messages with stream=true and feed each
-- decoded SSE event to the callback. A non-2xx response is classified
-- (status + Retry-After + body) and delivered as one Left; the
-- callback never sees raw servant or http-client failures from the
-- status path. HttpException from the transport still propagates to
-- the caller (the worker classifies it).
claudeSseStream ::
  Servant.ClientEnv ->        -- from Claude.getClientEnv (manager + parsed BaseUrl)
  Text ->                     -- api key (x-api-key header)
  Maybe Text ->               -- anthropic-version header
  Messages.CreateMessage ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()

-- | The response-consuming half, split out so tests can feed a
-- hand-built http-client Response without a server.
sseFromResponse ::
  HTTP.Client.Response HTTP.Client.BodyReader ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
```

Implementation notes, mirroring the SDK source you should keep open while writing this:

- Build the `http-client` `Request` from the `ClientEnv`'s `baseUrl` exactly as the SDK
  does (V1.hs:199-230): scheme→`secure`, host, port, `basePath <> "/v1/messages"`
  (normalize a missing leading slash), method POST, headers `x-api-key`,
  `anthropic-version` (when given), `Accept: text/event-stream`,
  `Content-Type: application/json`, body `RequestBodyLBS (Aeson.encode req')` where
  `req' = req { Messages.stream = Just True }`. Keep `responseTimeoutNone` for now (EP-8
  wires `timeoutMs` here; leave a comment saying so).
- `claudeSseStream` = `HTTP.Client.withResponse request (Client.manager env)
  (\resp -> sseFromResponse resp onEvent)`.
- In `sseFromResponse`: if the status is not 2xx, `brConsume` the body and call
  `onEvent (Left (httpError status retryAfter bodyText))` where `retryAfter =
  parseRetryAfterSeconds =<< (decoded "Retry-After" header from
  HTTP.Client.responseHeaders)` — this is the moment the review's dead
  status/`Retry-After` mapping comes alive. Otherwise run the SSE loop copied in shape
  from V1.hs:246-304: buffer partial lines across chunks, strip `\r`, accumulate
  `data:`-prefixed payloads, flush on blank line and at EOF, `Aeson.eitherDecodeStrict`
  each payload then `Aeson.fromJSON` to `Messages.MessageStreamEvent`; a decode failure
  becomes `onEvent (Left (decodeError (Text.pack err)))`. (Claude ends streams with a
  `message_stop` event, not `[DONE]` — no sentinel handling.)

Rewire `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:

- `prepareCall` (lines 155-171) returns `Either BaikaiError ClaudeCall` instead of
  `Either Text`, and `ClaudeCall` carries what `claudeSseStream` needs (`ClientEnv`, key,
  version, request) instead of the SDK `Methods` record. Map a `mapRequest` `Left e` to
  `invalidRequest e`. Do **not** let `resolveKey` / `getClientEnv` throw out of
  `concatEffect`: in `claudeMessagesStream` (lines 124-144), wrap the `prepareCall m ctx
  opts` call in a sync-exception `try`; on `Left ex`, produce the classified error —
  `fromException ex :: Maybe BaikaiError` (the `resolveApiKey` throw, already
  `AuthError`) or else `classifyException ex` — and return the one-event error stream.
  Replace `immediateError` (lines 511-523) with a variant that takes the `BaikaiError`
  (it already builds the error message; have it call the now-strict
  `errorTerminal Nothing Stop.ErrorReason msg err`).
  **Reconcile with EP-5**: if EP-5 decided lone error streams must open with
  `EventStart`, emit `EventStart` + `EventError` here (and in the OpenAI twin) to match;
  use EP-5's sync-only catch helper rather than a bare `try @SomeException`.
- `worker` (lines 183-200) drives `claudeSseStream` instead of
  `createMessageStreamTyped`. The callback's `Left be` is now a classified `BaikaiError`:
  forward it on the channel as a new raw-event alternative — change the channel element
  type from `Maybe Messages.MessageStreamEvent` to
  `Maybe (Either BaikaiError Messages.MessageStreamEvent)` and delete the
  `errorEvent :: Text -> Messages.MessageStreamEvent` String-wrapping hack (the exact
  hack that killed classification). The worker's exception handler stays but
  `classifyException` now understands `HttpException` (below).
- `translate` (lines 318-353): the `Left be` channel element emits
  `EventError (errorTerminal rid Stop.ErrorReason msg be)` with
  `msg = finalMessageOnError ass now (be ^. #message)`. The `Messages.Error` branch
  (lines 349-353) — now only reachable for genuine mid-stream Anthropic error events,
  which are JSON objects — keeps `classifyErrorValue` but falls back to
  `providerError errText` when it returns `Nothing`, satisfying the strict
  `errorTerminal`. `Messages.Message_Stop` (lines 346-348) checks the accumulated stop
  reason: when it is `Stop.ErrorReason` (Anthropic's `Refusal`), emit
  `EventError (errorTerminal rid Stop.ErrorReason msg (providerError "Anthropic refused to
  generate a response (stop_reason=refusal)"))` with the message built by
  `finalMessageOnError`; otherwise `EventDone` as today.
- `unexpectedEoS` (lines 277-284): `mErr` still comes from the worker ref; synthesize
  `providerError "claude stream ended without message_stop"` when it is `Nothing` so the
  strict `errorTerminal` is satisfied.

Extend `baikai-claude/src/Baikai/Provider/Claude/ErrorClass.hs`:

- `classifyException` (lines 44-47) gains an `HttpException` branch before the generic
  fallback:

  ```haskell
  classifyException ex
    | Just clientErr <- fromException ex = fromClientError clientErr
    | Just httpEx <- fromException ex = fromHttpException httpEx
    | otherwise = providerError (Text.pack (displayException ex))

  fromHttpException :: HTTP.Client.HttpException -> BaikaiError
  fromHttpException = \case
    HTTP.Client.InvalidUrlException url reason ->
      invalidRequest (Text.pack (url <> ": " <> reason))
    HTTP.Client.HttpExceptionRequest _ content ->
      let txt = Text.pack (show content)
       in case content of
            HTTP.Client.ConnectionFailure _ -> transient txt
            HTTP.Client.ConnectionTimeout -> transient txt
            HTTP.Client.ResponseTimeout -> transient txt
            HTTP.Client.ConnectionClosed -> transient txt
            HTTP.Client.NoResponseDataReceived -> transient txt
            HTTP.Client.IncompleteHeaders -> transient txt
            _ -> providerError txt
    where
      transient t = (providerError ("connection error: " <> t)) {category = TransientError}
  ```

  This is the fix for review finding 1.3 (connection resets classified permanent).
- Add `classifyErrorText :: Text -> Maybe BaikaiError` (new for claude), the
  defense-in-depth fallback: if the text matches the SDK format
  `"HTTP error " <> code <> " " <> statusMessage` optionally followed by `": " <> body`
  (evidence: V1.hs:239-244), parse the code with `Text.decimal`/`readMaybe`, take
  everything after the first `": "` as the body, and return
  `Just (httpError code Nothing body)` (no header, so no retry-after — exactly why the
  transport wrapper is primary); otherwise `Nothing`. Keep `responseToError` exported,
  reimplemented as `httpError` + servant unpacking, so
  `baikai-claude/test/ErrorClassSpec.hs`'s existing mapping tests keep passing (they test
  logic that is now live via `httpError`).

Make `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` in-band: `decodeResult`
(lines 142-153) returns `Either BaikaiError ClaudeCliResult` instead of throwing;
`runClaudeCli` (lines 163-187) builds `errorResponse m end (millisBetween start end) err`
for the `ExitFailure` (→ `processError n stderrText`), decode-failure, and
`is_error` (→ `providerError (result r)`) cases; and the whole body is wrapped in a
sync-exception catch (re-throw asyncs) that degrades to
`errorResponse m now 0 (providerError (Text.pack (displayException ex)))` — this covers a
missing `claude` binary. Update the module haddock (the error behavior sentence) and drop
the now-unused `throwIO` import. With M1's `liftCompleteToStream` fix, the CLI's `stream`
field automatically emits `EventError` for these responses.

Tests (`baikai-claude/test/`; add `http-client` to the test-suite `build-depends` in
`baikai-claude/baikai-claude.cabal`, and import `Network.HTTP.Client.Internal` where a
hand-built `Response` is needed):

- `ErrorClassSpec.hs` — keep every existing test (the mapping is now live). Add
  real-shape tests: (a) `classifyErrorText` fed the **exact** runtime text
  `"HTTP error 429 Too Many Requests: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"...\"}}"`
  → `RateLimited`, `httpStatus = Just 429`; `"HTTP error 529 "` → `TransientError`;
  non-matching text → `Nothing`. (b) `classifyException` fed
  `toException (HTTP.Client.HttpExceptionRequest HTTP.Client.defaultRequest
  (HTTP.Client.ConnectionFailure (toException (userError "reset"))))` → `TransientError`
  with `isRetryable = True`, and `ResponseTimeout` likewise.
- New `SseSpec.hs` (wire into `test/Main.hs`): build an
  `HTTP.Client.Internal.Response` whose `responseStatus` is 429, headers include
  `("Retry-After", "7")`, and whose `BodyReader` yields the Anthropic error JSON then
  `""`; run `sseFromResponse` and assert one `Left` with category `RateLimited`,
  `retryAfterSeconds = Just 7`, `httpStatus = Just 429`. A second case: status 200 with a
  body of `data: {...message_start...}\n\n` chunks split at awkward boundaries
  (mid-line, mid-`\r\n`) asserting the decoded `MessageStreamEvent`s arrive in order — the
  SSE-parser test.
- In `test/Main.hs`: the no-key path. `unsetEnv "ANTHROPIC_API_KEY"` (restore it after;
  note the test manipulates global process state — keep it in a `testCase` that sets and
  restores with `bracket`, and if the suite runs tasty in parallel, guard with
  `Test.Tasty.Runners`' sequential group or simply document that no other test reads that
  variable), drain `claudeMessagesStream` on a model with `api = AnthropicMessages`, and
  assert the event list contains **exactly one terminal**, it is `EventError`, and its
  `errorInfo` category is `AuthError` — this is the regression test for the
  zero-events-then-throw bug. Also a CLI in-band test: `runClaudeCli` with
  `executable = "/nonexistent/claude-binary"` returns (does not throw) a `Response` with
  `responseError` `Just` (category `OtherError`).

Acceptance: `cabal test baikai-claude` passes; the no-key test fails before this
milestone's code changes (it throws) and passes after.


### Milestone 3 — OpenAI: live classification, `content_filter`, and the codex CLI

Scope: the `baikai-openai` package, mirroring M2 plus the Theme-10 `content_filter`
finding. Verify with `cabal test baikai-openai`.

Create `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` exactly like the claude one, with
three differences taken from the openai SDK source
(`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai/src/OpenAI/V1.hs:432-566`):
the path is `/v1/chat/completions`; the auth header is
`Authorization: Bearer <key>` (plus optional `OpenAI-Organization` / `OpenAI-Project`,
which baikai does not currently set — omit); and the SSE flush loop must treat a payload
equal to `[DONE]` as end-of-stream (V1.hs:505-506) rather than a JSON event. The callback
type is `Either BaikaiError Aeson.Value -> IO ()` (the provider parses raw chunks itself
— keep that, it exists to tolerate partial tool-call deltas, see the module haddock of
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`). Expose the same `sseFromResponse`
seam for tests. Non-2xx handling is identical: `httpError status retryAfter body` with
`Retry-After` read from the real response headers — recovering exactly what the SDK
discards (it *receives* the headers in its `onMetadata` callback at V1.hs:476-481 but
`createChatCompletionStream` throws them away at V1.hs:391).

Rewire `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`:

- `prepareCall` (lines 175-199) → `Either BaikaiError OpenAICall`, carrying
  `ClientEnv` + key + the stream-enabled request (keep setting
  `stream_options.include_usage = true` by encoding it into the request value the
  wrapper posts — simplest is to keep building `Chat.CreateChatCompletion` with
  `Chat.stream = Just True` and `Chat.stream_options` as today, lines 185-193, and have
  the wrapper post it verbatim). Catch sync exceptions from `resolveKey` /
  `OpenAI.getClientEnv` in `openaiChatStream` (lines 135-155) exactly as in M2; emit one
  classified terminal `EventError` (AuthError for the missing `OPENAI_API_KEY`).
- `worker` (lines 230-247): drive the wrapper; channel type becomes
  `Maybe (Either BaikaiError RawChunk)`; a wrapper `Left be` is forwarded as
  `Left be`; a chunk-parse failure (`parseChunk` `Left err`) forwards
  `Left (decodeError (Text.pack err))`. Delete `errorChunk` and the
  `RawChunk.error` field (its only producer was the Left-text path); `translate`'s
  error branch (lines 502-507) moves to the channel-`Left` case in `step`, emitting
  `EventError (errorTerminal rid Stop.ErrorReason msg be)` — no more
  `classifyErrorText` sniffing of already-classified errors. Keep `classifyErrorText`
  (extended below) for any host that returns 200 and then streams a textual error.
- `content_filter` and refusal-shaped finishes: add a field
  `pendingError :: Maybe BaikaiError` to `Assembler` (lines 450-476). In
  `closeOnFinish` (lines 605-612), when `mapFinishReason fr == Stop.ErrorReason`, set
  `pendingError = Just (providerError ("provider stopped the response: finish_reason="
  <> fr))` (category `OtherError` per the Decision Log). In `closeOpenStream`'s
  `finishSeen` branch (lines 659-665), when the stashed `stopReason` is
  `Stop.ErrorReason`, emit `EventError (errorTerminal rid reason msg err)` (with `err` from
  `pendingError`, synthesizing if absent) instead of `EventDone` — this fixes review
  finding 1.7 / openai `Api.hs:946`. In `mapFinishReason` (lines 940-947), replace the
  silent `_ -> Stop.Stop` collapse: return the reason plus a diagnostic — change the
  signature to `mapFinishReason :: Text -> (Stop.StopReason, Maybe Text)` where the
  second component is `Just ("unrecognized finish_reason: " <> r)` for unknown reasons;
  `closeOnFinish` stashes the diagnostic (new `Assembler` field `finishNote ::
  Maybe Text`) and `finalMessage` (lines 681-696) puts it in `errorMessage` when the
  terminal is otherwise successful. Update the `errorMessage` haddock in
  `baikai/src/Baikai/Message.hs` to say it may carry a non-fatal diagnostic and that
  failure detection must use `stopReason`/`errorInfo` (one sentence; if that field's
  haddock lives elsewhere, adjust in place).
- `closeOpenStream`'s non-`finishSeen` branch (lines 666-679): synthesize
  `providerError "openai stream ended without finish_reason"` when the worker ref is
  empty, for the strict `errorTerminal`.

Extend `baikai-openai/src/Baikai/Provider/OpenAI/ErrorClass.hs`: add the same
`fromHttpException` branch to `classifyException` as in M2 (identical code; the two
ErrorClass modules are deliberately parallel), and prepend the SDK-text parse to
`classifyErrorText` (lines 88-104): first try the `"HTTP error <code> ..."` format →
`httpError code Nothing body`; only then fall back to today's phrase sniffing. Keep
`responseToError` as the thin servant adapter for the existing tests.

Make `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` in-band exactly as the claude CLI
in M2: `consume` (lines 149-162) returns error-shaped `Response`s (via `errorResponse`)
for the missing-handle and `ExitFailure` cases; wrap `runCodexCli` in the sync-exception
catch for the missing-binary case; update the haddocks.

Tests (`baikai-openai/test/`):

- `ErrorClassSpec.hs` — keep all existing tests; add the real-shape cases: the exact
  runtime text
  `"HTTP error 429 Too Many Requests: {\"error\":{\"message\":\"Rate limit reached...\",\"type\":\"tokens\"}}"`
  → `RateLimited` with `httpStatus = Just 429` (this same input classified `OtherError`
  before — a test that fails on the old code); `"HTTP error 401 Unauthorized: ..."` →
  `AuthError`; `HttpException` cases as in M2.
- New `SseSpec.hs`: the fake-`Response` tests as in M2, plus a `[DONE]`-terminates case
  and a 429-with-`Retry-After` case asserting `retryAfterSeconds = Just n`.
- In `test/Main.hs`: `content_filter` — drive `translate`/the assembler with a chunk
  sequence ending in `finish_reason = "content_filter"` then channel close (structure the
  test against whatever internal function is cleanest to export for testing; exporting
  `translate` and `closeOpenStream` from the Api module for tests is acceptable — EP-10
  will namespace internals) and assert the terminal is `EventError` with `errorInfo`
  `Just` (category `OtherError`) and message containing `content_filter`. An
  unknown-finish-reason case asserting `EventDone`/`Stop` with the diagnostic in
  `errorMessage`. The no-key stub test (unset `OPENAI_API_KEY`) asserting exactly one
  terminal `EventError` with category `AuthError`. The codex-CLI missing-binary in-band
  test.

Acceptance: `cabal test baikai-openai` passes; the new 429-text test demonstrably fails
against the pre-milestone classifier.


### Milestone 4 — conformance sweep, documentation, and changelog

Scope: cross-cutting assertions and the paper trail. At the end, every provider error path
is covered by one shared contract assertion, all haddocks tell the same story, and the
breaking changes are recorded. Verify with the full build/test matrix.

Add a contract-assertion helper to each package's test tree (a small copied function is
fine; there is no shared test library):

```haskell
-- | Assert the streaming error contract on a drained event list:
-- exactly one terminal; if it is EventError, errorInfo is present.
assertErrorContract :: [AssistantMessageEvent] -> Assertion
```

Apply it to every error-path test added in M2/M3 (no-key, non-2xx, mid-stream error,
unexpected EOS, CLI failure, mapRequest failure, unregistered tag) and to the blocking
twins via `responseError` (drain with `streamingComplete` where cheap). Sweep the two
packages for any remaining `errorTerminal`/`EventError` construction site and confirm
none can carry a missing classification (the strict signature makes the compiler do most
of this).

Documentation sweep, all of which must now agree: `baikai/src/Baikai/Provider/Registry.hs`
(done in M1 — re-read it), `baikai/src/Baikai/Stream.hs` module haddock (the
`liftCompleteToStream` bullets), both CLI provider module haddocks ("throws" language
removed), `baikai-effectful/src/Baikai/Effectful.hs` (done in M1 — re-read),
`baikai/src/Baikai/Response.hs` (`errorInfo` field haddock now states the enforced
invariant and points at `responseError`). Check `README.md` and any
`docs/guides`/getting-started prose for "throws" claims about `completeRequest` (the
review's doc-drift item 13 notes unregistered dispatch wording): fix only
error-contract sentences; the rest of the doc sweep belongs to EP-10.

Changelog: add to `baikai/CHANGELOG.md` under the unreleased 0.2 heading entries for (a)
BREAKING: `completeRequest`/`completeRequestWith` no longer throw `BaikaiError` for
unregistered tags — they return an error-shaped `Response`; (b) BREAKING: CLI providers
report failures in-band; (c) BREAKING: `errorTerminal` requires a `BaikaiError`; (d)
Added: `responseError`, `errorResponse`, `httpError`, `parseRetryAfterSeconds`; (e)
Fixed: live HTTP-status/`Retry-After`/network-failure classification on both API
providers; `content_filter` and refusals terminate as classified errors;
`liftCompleteToStream` preserves error-shaped responses. Mirror one-line entries in the
root `CHANGELOG.md` if it aggregates per-package entries (inspect its format and follow
it).

Cross-plan bookkeeping (required, not optional): append to
`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`'s Decision Log
the `errorTerminal` signature change and any lone-error-stream shape this plan followed;
update the MasterPlan's Integration Points paragraph on the error contract to note the
new `Baikai.Provider.Claude.Sse` / `Baikai.Provider.OpenAI.Sse` transport modules as the
seam EP-8 must use for `timeoutMs`/headers; tick the two EP-6 boxes in the MasterPlan's
Progress section when done.

Acceptance: the full matrix in Validation and Acceptance below is green, and a manual
smoke check (optional, requires a key): run one of the `baikai-smoke` tests with a
deliberately wrong `ANTHROPIC_API_KEY` value and observe a `Response` with
`responseError` category `AuthError`, `httpStatus = Just 401`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`.

Before writing code, confirm EP-5 has landed and read what it changed:

```bash
git log --oneline -15
sed -n '1,80p' docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md
```

Keep the two SDK sources open while writing the transports (locate them with `mori` if
the paths have moved):

```bash
mori registry show MercuryTechnologies/claude --full
mori registry show MercuryTechnologies/openai --full
sed -n '194,310p' /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1.hs
sed -n '432,566p' /Users/shinzui/Keikaku/hub/haskell/openai-project/openai/src/OpenAI/V1.hs
```

Per-milestone build/test loop (M1 shown; substitute the package for M2/M3):

```bash
cabal build baikai baikai-effectful --enable-tests
cabal test baikai baikai-effectful
```

Expected tail of a passing core run (test counts will differ once new cases are added):

```text
Test suite baikai-test: RUNNING...
All ... tests passed
Test suite baikai-test: PASS
```

Note the transition ordering inside M1: the `errorTerminal` signature change breaks the
provider packages until their call sites are updated. Either land the mechanical call-site
fixes for `baikai-claude`/`baikai-openai` in the same commit as the signature change
(preferred; they are small), or build only `baikai baikai-effectful` until M2/M3.

Final sweep (M4):

```bash
cabal build all --enable-tests
cabal test baikai baikai-claude baikai-openai baikai-effectful
```

Expected: four `PASS` lines, one per suite (`baikai-test`, `baikai-claude-test`,
`baikai-openai-test`, `baikai-effectful-test`).

Commit per milestone with conventional-commit messages, for example:

```text
fix(core)!: make the error contract in-band everywhere

completeRequestWith returns an error-shaped Response; liftCompleteToStream
preserves errorInfo as a terminal EventError; errorTerminal requires a
classified BaikaiError; add responseError/errorResponse/httpError.
```

Update this plan's Progress section (and Surprises & Discoveries / Decision Log as
warranted) at every stopping point.


## Validation and Acceptance

Compilation is not acceptance. The behaviors to demonstrate, each backed by a named test:

1. Real 429 classification (both providers). Feed `sseFromResponse` a hand-built
   `http-client` response: status 429, header `Retry-After: 7`, vendor error-JSON body.
   Observe exactly one `Left be` with `category be == RateLimited`,
   `httpStatus be == Just 429`, `retryAfterSeconds be == Just 7`,
   `isRetryable be == True`. (`SseSpec.hs` in each provider package.)
2. Real SDK error text classification. `classifyErrorText "HTTP error 429 Too Many
   Requests: {...}"` yields `RateLimited` — this exact input yields `OtherError` (openai)
   or is unclassifiable (claude) before the change, so the new tests fail on the old code.
3. Network blips are retryable. `classifyException` on an
   `HttpExceptionRequest _ (ConnectionFailure _)` value yields `TransientError`,
   `isRetryable = True`.
4. No-key path emits one terminal. With the provider's key env var unset, draining the
   provider stream yields a list whose only terminal is `EventError` with `errorInfo`
   category `AuthError` — before the fix this test dies with an uncaught `BaikaiError`
   after zero events.
5. Error-shaped responses stream as errors. A `complete` handler returning
   `errorResponse ...` lifted via `liftCompleteToStream` drains to a terminal
   `EventError` carrying the same `BaikaiError`; `streamingComplete` over it returns a
   `Response` where `responseError` is `Just` that error.
6. Unregistered dispatch does not throw. `completeRequestWith` on an empty registry
   returns a `Response` with `responseError` category `ProviderUnavailable`.
7. CLI failures are in-band. `runClaudeCli` / `runCodexCli` with a nonexistent executable
   return an error-shaped `Response` (no exception).
8. `content_filter` is an error terminal. The OpenAI assembler fed
   `finish_reason = "content_filter"` produces `EventError` with populated `errorInfo`;
   an unknown finish reason produces `EventDone`/`Stop` with the diagnostic in
   `errorMessage`.
9. Invariant holds universally. The contract helper passes on every provider error path,
   and the reassembly-normalization test shows even a nonconforming `EventDone`+
   `ErrorReason` terminal yields `responseError = Just _`.

Commands and expected results:

```bash
cabal build all --enable-tests   # zero errors, zero new warnings in touched modules
cabal test baikai baikai-claude baikai-openai baikai-effectful   # 4x PASS
```

Optional live check (requires network; not CI): export a syntactically valid but wrong
`ANTHROPIC_API_KEY`, run the relevant `baikai-smoke` scenario, and observe a typed
`AuthError` with `httpStatus = Just 401` instead of an opaque failure.


## Idempotence and Recovery

Every step is an ordinary source edit under git; re-running a step is re-applying an edit
that is already there (a no-op) and the recovery path for any mis-step is
`git checkout -- <file>` or reverting the milestone commit. Commit at each milestone
boundary so `git revert` granularity matches the verification granularity. No migrations,
no generated files, no destructive operations are involved. The only global-state hazard
is the env-var-unsetting tests: always set/restore with `bracket` so an interrupted test
run cannot leave the developer's shell-launched process with a clobbered key (child
process state does not persist anyway, but other tests in the same run could be
affected). If M2/M3 are interrupted mid-way with the strict `errorTerminal` landed, the
provider packages may not compile; either finish the mechanical call-site fixes or revert
the M1 commit — both restore a buildable tree.


## Interfaces and Dependencies

No new external dependencies for the libraries: `http-client`, `http-client-tls`,
`http-types`, `servant-client`, and `aeson` are already in both provider packages'
`build-depends`. The `baikai-claude`/`baikai-openai` **test suites** gain `http-client`
(for `HttpException` values and `Network.HTTP.Client.Internal.Response` fixtures); add it
to the `test-suite` stanzas in the respective cabal files. Core `baikai` gains nothing.

Signatures that must exist at the end of each milestone (full module paths):

Milestone 1:

```haskell
Baikai.Error.httpError :: Int -> Maybe Int -> Text -> BaikaiError
Baikai.Error.parseRetryAfterSeconds :: Text -> Maybe Int
Baikai.Response.responseError :: Response -> Maybe BaikaiError
Baikai.Response.errorResponse :: Model -> UTCTime -> Integer -> BaikaiError -> Response
Baikai.Stream.Event.errorTerminal :: Maybe Text -> StopReason -> Message -> BaikaiError -> TerminalPayload
-- unchanged but re-documented:
Baikai.Provider.Registry.completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
```

Milestone 2:

```haskell
Baikai.Provider.Claude.Sse.claudeSseStream ::
  Servant.Client.ClientEnv -> Text -> Maybe Text -> Claude.V1.Messages.CreateMessage ->
  (Either BaikaiError Claude.V1.Messages.MessageStreamEvent -> IO ()) -> IO ()
Baikai.Provider.Claude.Sse.sseFromResponse ::
  Network.HTTP.Client.Response Network.HTTP.Client.BodyReader ->
  (Either BaikaiError Claude.V1.Messages.MessageStreamEvent -> IO ()) -> IO ()
Baikai.Provider.Claude.ErrorClass.classifyErrorText :: Text -> Maybe BaikaiError
-- classifyException unchanged in type, extended to recognize HttpException
```

Milestone 3 mirrors Milestone 2 under `Baikai.Provider.OpenAI.Sse` (callback carries
`Data.Aeson.Value` instead of the typed claude event) with the extended
`Baikai.Provider.OpenAI.ErrorClass.classifyErrorText`.

Downstream plans consuming these interfaces: EP-7 and EP-8 write acceptance tests against
`responseError`; EP-8 wires `Options.timeoutMs` and `Options.headers`/`Model.headers`
into the two `Sse` transport modules (the `responseTimeoutNone` comment marks the spot);
EP-9's `runToolLoop` terminates on `responseError`; EP-10 may move the `Sse` and
`ErrorClass` modules behind an `.Internal` namespace — they are written as
plain exposed modules here and relocation is EP-10's call.


---

Revision note (2026-07-03): after completing Milestone 4, the Progress section was
updated with final validation, the Outcomes & Retrospective section was filled with the
implemented contract and test evidence, and the EP-8 SSE-transport handoff was restated
so later transport-option work extends the local modules introduced here.
