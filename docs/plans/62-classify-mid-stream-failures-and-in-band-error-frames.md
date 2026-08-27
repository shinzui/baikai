---
id: 62
slug: classify-mid-stream-failures-and-in-band-error-frames
title: "Classify mid-stream failures and in-band error frames"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Classify mid-stream failures and in-band error frames

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is EP-5 of the MasterPlan at
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`. It
soft-depends on EP-4 (`docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md`),
which owns both provider `Api.hs` modules: the worker, the assembler, and the shape of
every error stream. This plan owns `baikai/src/Baikai/Error.hs`, both
`Internal/ErrorClass.hs` modules, the timeout helper in both `Transport.hs` modules, the
non-2xx branch of `sseFromResponse` in both `Sse.hs` modules, and exactly one bounded
region of `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`: the `parseChunk` group of
functions (lines 343–397 at `c3753c5`) plus the single line in `worker` that calls it.
Land this plan after EP-4, or rebase onto it; every step that touches a file EP-4 also
touches is flagged "**Reconcile with EP-4**". It continues the work of
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`, which is
checked in and is incorporated by reference; everything a reader needs from it is
repeated here.


## Purpose / Big Picture

baikai promises that a failed call arrives as a typed `BaikaiError` whose `category` and
`isRetryable` let an application decide retry policy without reading error text.
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` fixes the boundary: baikai
classifies retryability and never retries. That promise is only as good as the
classification, and the 2026-08 review (`docs/reviews/correctness-and-api-review-follow-up.md`,
REV-2, findings A.2, A.3, A.7, A.9, A.10 and Theme I item 1) found that the failures
which matter most for unattended work are the ones classified worst. A TCP reset while
the response body is streaming, a server that closes the connection mid-chunk, and a TLS
session torn down after the handshake all reach the caller as `OtherError` with
`isRetryable = False`, while the very same reset at connect time is `TransientError`.
An OpenAI-compatible host that reports an upstream failure as an `{"error": …}` frame
on a `200` stream (OpenRouter, DeepSeek and Together all do this) has its message thrown
away and the call ends as `OtherError "openai stream ended without finish_reason"`. A
`413` whose body says `request_too_large` is `OtherError` rather than `ContextOverflow`.
A `Retry-After` given as an HTTP-date, which CDN-fronted hosts send on `429`, yields no
hint at all. `timeoutMs = Just 0` fails instantly as a retryable transient error, which
spins a retry loop. And the tests that appear to cover the classifiers feed shapes the
transport can no longer produce.

After this plan is implemented, the following holds and is demonstrated by tests. A fake
server that sends two chunks and then resets the connection yields a terminal
`EventError` whose `errorInfo` has `category = TransientError` and `isRetryable = True`,
with the two chunks' text still in the terminal message. A chunked-encoding end-of-file,
a TLS termination and a `ResponseBodyTooShort` classify the same way; a TLS handshake
that fails against a misconfigured host does not. An in-band error frame on a `2xx`
stream terminates with the frame's own classification: an OpenRouter upstream `502`
becomes `TransientError` with `httpStatus = Just 502`; an OpenAI `insufficient_quota`
frame becomes `AuthError`. A `413` is `ContextOverflow`. A `429` carrying
`Retry-After: Wed, 21 Oct 2026 07:28:00 GMT` and `Date: Wed, 21 Oct 2026 07:27:15 GMT`
yields `retryAfterSeconds = Just 45`. A stalled socket that never answers is cut off by
`timeoutMs = Just 200` as `TransientError`, and `timeoutMs = Just 0` is refused as
`InvalidRequest` before any connection is opened. Both provider packages classify
through one shared helper in core, so the two can no longer drift apart, and every
classifier test feeds a shape the runtime produces.


## Progress

Milestone 1 — mid-stream transport failures classified from the shapes http-client actually raises:

- [x] `baikai/src/Baikai/Provider/Transport/Classify.hs` created and exposed; `http-types` and `tls` added to the `baikai` library `build-depends` (`http-client` was already direct, added by EP-2). (2026-08-27)
- [x] `classifyException` in both `Internal/ErrorClass.hs` modules delegates to `classifyTransportException`; the servant `ClientError` branch, `fromClientError` and `responseToError` deleted; `Servant.Client` imports removed. (2026-08-27)
- [x] `baikai/test/TransportClassifySpec.hs` written and wired into `baikai/test/Main.hs` and `baikai/baikai.cabal` — 30 cases. (2026-08-27)
- [x] `MidStreamSpec.hs` created in both provider test trees with the throwing-body-reader fixtures; `cabal test baikai baikai-claude baikai-openai` green (615 / 272 / 180). (2026-08-27)
- [x] Pulled forward from Milestone 4 because the export removal made them uncompilable: `httpStatusTests` and `mkResp` deleted from both `ErrorClassSpec.hs`; "429 without Retry-After -> RateLimited, no hint" re-homed to `baikai/test/ErrorSpec.hs`; "non-ClientError exception" renamed to "non-transport exception"; the delegation case added to both. (2026-08-27)

Milestone 2 — in-band `{"error": …}` frames on 2xx streams classified:

- [x] `classifyErrorFrame :: Value -> Maybe BaikaiError` added to `baikai-openai/src/Baikai/Provider/OpenAI/Internal/ErrorClass.hs`; `classifyErrorText` and `classifySdkHttpText` deleted; `scientific` added to the package's `build-depends`. (2026-08-27)
- [x] `parseFrame` added beside `parseChunk` in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`; the worker's `Right val ->` arm calls it; `parseFrame` exported. (2026-08-27)
- [x] `classifyErrorText` deleted from `baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs`, along with the `sdkTextTests` group that was its only caller. (2026-08-27)
- [x] Error-frame tests in `ErrorClassSpec.hs` (13 cases), `SseSpec.hs` and `MidStreamSpec.hs` (OpenAI) green; `cabal test baikai baikai-claude baikai-openai` green (615 / 269 / 189). (2026-08-27)

Milestone 3 — 413 overflow, HTTP-date `Retry-After`, and `timeoutMs` edge semantics:

- [x] `classifyHttpStatus` maps 413 to `ContextOverflow`; `parseHttpDate` and `retryAfterSecondsAt` added to `baikai/src/Baikai/Error.hs`; `ErrorSpec` pin "HTTP-date Retry-After is ignored" rewritten as "parseRetryAfterSeconds is integer-only" plus six cases on the new helpers. (2026-08-27)
- [x] Both `sseFromResponse` non-2xx branches compute `retryAfterSeconds` from either form using the response `Date` header; `classifyHttpExceptionContent`'s `StatusCodeException` arm upgraded to match. (2026-08-27)
- [x] `runWithTimeout` in both `Transport.hs` refuses a non-positive bound as `InvalidRequest` without running the action. The misleading `EP-8` comment in both `Sse.hs` was already replaced by EP-2/EP-4; both now read "No per-response bound here: Options.timeoutMs is enforced around the whole call by Transport.runWithTimeout", which is what this plan asked for. (2026-08-27)
- [x] Stalled-socket and zero-timeout tests in both `MidStreamSpec.hs` green; `Options.timeoutMs` Haddock states the contract. (2026-08-27)

Milestone 4 — unreachable-shape tests retired; classifier module docs match the transport:

- [ ] `httpStatusTests` and `sdkTextTests` deleted from both `ErrorClassSpec.hs`; OpenAI `streamedErrorTests` re-fed through `classifyErrorFrame`; `ReasoningSpec` "whole message shape" re-fed through `sseFromResponse`; `servant-client` dropped from any test stanza that no longer imports it.
- [ ] Module Haddock of both `Internal/ErrorClass.hs`, `docs/capabilities/categorised-error-model.md`, `docs/capabilities/anthropic-messages-backend.md`, `docs/user/streaming.md` (one sentence) and `CHANGELOG.md` `[Unreleased]` updated.
- [ ] `docs/adr/0006-core-owns-transport-failure-classification.md` written and listed in `docs/adr/README.md`.
- [ ] Keyless gate from `agents/skills/release/SKILL.md` green; MasterPlan Progress boxes for EP-5 ticked; Outcomes & Retrospective written.


## Surprises & Discoveries

Pre-implementation research findings (2026-08-27), recorded because they fix the shape
of the plan. Implementation-time discoveries go below them.

- `http-client` 0.7.19 (the version in the current build plan; source on disk at
  `/Users/shinzui/Keikaku/hub/haskell/http-client-project/http-client/http-client/`,
  located with `mori registry show snoyberg/http-client --full`) wraps the *connection
  phase* with the manager's exception wrapper but wraps the *body reader* only with its
  own `wrapExc`, which converts the private `HttpExceptionContentWrapper` into a public
  `HttpExceptionRequest` and nothing else. `Network/HTTP/Client/Core.hs` lines 236–244:

  ```haskell
  wrapExc req0 $ mWrapException manager req0 $ do
    (req, res) <- go manager (redirectCount req0) req0
    checkResponse req req res
    mModifyResponse manager res
        { responseBody = wrapExc req0 (responseBody res)
        }
  where
    wrapExc :: Request -> IO a -> IO a
    wrapExc req0 = handle $ throwIO . toHttpException req0
  ```

  So a socket-level `IOException` or a `TLSException` raised inside `brRead` reaches
  the worker *raw*, while the same failure at connect time arrives as
  `HttpExceptionRequest _ (InternalException se)` or `ConnectionFailure se`. This is
  the mechanism behind REV-2 A.2 and the reason the classifier must accept three
  exception types, not one.
- `http-client-tls` 0.3.6.4 (the resolved version; the corpus checkout is 0.4.0 and
  the relevant code is identical) sets `managerWrapException` to wrap `IOException`,
  `TLSException`, and the connection package's `HostNotResolved`/`HostCannotConnect`
  into `InternalException` (`Network/HTTP/Client/TLS.hs` lines 100–114 in the 0.3.6.4
  tarball). Its `managerRetryableException` treats `TLS.PostHandshake TLS.Error_EOF` as
  retryable (line 96), which is upstream's own opinion that a TLS end-of-file after the
  handshake is a broken connection, not a configuration error.
- Every body-phase failure `http-client` raises itself goes through `throwHttp` and so
  arrives as `HttpExceptionRequest`: `InvalidChunkHeaders` (`Body.hs` lines 188, 206,
  211 — an empty read or a malformed chunk header mid-chunk, which is what a server
  closing the socket mid-chunk produces), `ResponseBodyTooShort` (`Body.hs` line 134,
  content-length bodies), `HttpZlibException` (`Body.hs` line 94), `ConnectionClosed`
  (`Connection.hs` lines 118–131), `IncompleteHeaders` (`Connection.hs` lines 37, 58),
  `NoResponseDataReceived` (`Headers.hs` line 68) and `ResponseTimeout` (`Headers.hs`
  line 38). `StatusCodeException` is raised only by `throwErrorStatusCodes`, which
  neither transport installs, so that branch is unreachable in baikai; the shared helper
  still maps it for third-party callers.
- `tls` 2.2.2 (`Network/TLS/Error.hs` lines 45–64; source from
  `~/.cabal/packages/hackage.haskell.org/tls/2.2.2/tls-2.2.2.tar.gz`, since the package
  is not in the Mori corpus) defines `TLSException` as `Terminated Bool String TLSError`,
  `HandshakeFailed TLSError`, `PostHandshake TLSError`, `Uncontextualized TLSError`,
  `ConnectionNotEstablished` and `MissingHandshake`, with `Error_EOF` and
  `Error_Misc String` among the `TLSError` constructors. The constructor names encode
  *when* the failure happened, which is exactly the fact the retryability rule needs.
- `System.Timeout.timeout n` returns `Nothing` immediately when `n == 0` and runs the
  action unbounded when `n < 0`. Both `Transport.runWithTimeout` implementations pass
  `max 0 ms * 1000`, so `timeoutMs = Just 0` and any negative value both "fail
  instantly" with `TransientError "provider stream exceeded timeoutMs=0"` — a
  retryable classification for a caller-side mistake.
- Core `baikai` already depends on the `openai` SDK, which depends on `http-client`,
  `http-client-tls` and `servant-client` (`dist-newstyle/cache/plan.json`), so adding
  `http-client`, `http-types` and `tls` as *direct* dependencies of the core library
  adds no package to any consumer's build plan. This is what makes the shared helper
  in core cheap.
- The socket errno that a Haskell `IOException` carries does not always land in the
  `ioe_type` one would expect: base maps `ECONNRESET`, `ENETRESET` and `EPIPE` to
  `ResourceVanished` and `ETIMEDOUT` to `TimeExpired`, but `ECONNABORTED` to the
  `IOErrorType` constructor named `OtherError`. The `IOException` rule therefore checks
  both the type and the errno.
- OpenAI-compatible hosts do not agree on the shape of an in-band error frame. OpenAI's
  own is `{"error":{"message":…,"type":…,"code":"context_length_exceeded"}}` with a
  string `code`; OpenRouter forwards the upstream HTTP status as a *number* in `code`
  and, on a mid-stream failure, also includes a `choices` array whose element has
  `finish_reason: "error"`. Detection must therefore key on the `error` key alone and
  not on the absence of `choices`. No recorded frame exists in the repository; the
  fixtures in this plan are written from the documented shapes and the classifier is
  written to tolerate either.
- Neither provider package runs a servant client anywhere on the chat path (both
  `Sse.hs` modules use `Servant.Client` only for the parsed `BaseUrl` and the
  `Manager` inside `ClientEnv`). `Baikai.Embedding` in core does run the `openai` SDK's
  servant client, but it never calls either `Internal/ErrorClass.hs`, so deleting the
  servant branches there removes no reachable behaviour.


### Implementation-time discoveries

- __`case-insensitive` is not needed to look up a response header.__ The plan's
  `classifyHttpExceptionContent` sketch used `lookup (CI.mk "Retry-After") hdrs`, which
  would have added a fourth direct dependency to core. `http-types` — which the module
  already needs for `statusCode` — exports the folded header names as constants
  (`hRetryAfter`, `hDate`), so the lookup is `lookup hRetryAfter hdrs` and the dependency
  list is the three the plan named. Milestone 3's `Date` lookup uses `hDate` for the same
  reason. (2026-08-27, M1)
- __`http-client` was already a direct dependency of core.__ EP-2 added `http-client` and
  `http-client-tls` for `baikai/src/Baikai/Http.hs`, so this milestone added only
  `http-types ^>=0.12` and `tls >=2.2 && <2.5`. The MasterPlan's "whichever lands second
  reuses the stanza the first added" commitment was met by EP-2 landing first. (2026-08-27, M1)
- __A test that builds an `HTTP.Response` must import `Network.HTTP.Client.Internal`.__
  The record's constructor is not exported from `Network.HTTP.Client`; both existing
  provider `EvidenceSpec.hs` files already import the `.Internal` module for exactly this,
  and both new `MidStreamSpec.hs` files follow. Building the response through
  `Network.HTTP.Client` alone fails with "Illegal term-level use of the type constructor",
  which reads like a shadowing problem and is not one. (2026-08-27, M1)
- __Deleting `responseToError` forced part of Milestone 4 forward.__ The plan scheduled the
  `httpStatusTests` deletion for M4, but M1 removes the export those tests call, so the
  provider suites stop compiling the moment the export list changes. The deletion, the
  re-homing of "429 without Retry-After", and the `fallbackTests` rename all landed in M1
  instead. `sdkTextTests` still compiles (both `classifyErrorText` functions survive until
  M2) and stays where the plan put it. (2026-08-27, M1)
- __An OpenRouter-shaped error frame did not fail the call at all — it /succeeded/.__ The
  plan predicted that such a frame would end as
  `OtherError "openai stream ended without finish_reason"`. Disabling `classifyErrorFrame`
  and re-running the two end-to-end cases shows that prediction holds only for a frame
  with no `choices` beside the error (the `insufficient_quota` case does end as
  `OtherError`). OpenRouter's frame carries `choices[0].finish_reason = "error"`, and
  `mapFinishReason` sends an unrecognised reason to `(Stop, Just "unrecognized
  finish_reason: …")` — so the observed pre-fix terminal was
  `EventDone {reason = Stop, errorInfo = Nothing}` carrying the partial text and a note in
  `errorMessage`. A consumer switching on the terminal saw a completed call. That makes
  REV-2 A.3 more severe than the review recorded, and it is the reason the fix keys on the
  `error` key rather than on `finish_reason`. (2026-08-27, M2)
- __`classifyHttpExceptionContent` is pure, so it cannot fall back to the local clock.__
  The transports call `getCurrentTime` when a 429 carries a `Retry-After` date and no
  `Date` header. The shared classifier has no `IO`, and inventing a reference (the epoch,
  say) would turn every date into `Just 0` — a worse answer than none. Its
  `StatusCodeException` arm therefore converts the date form only when a parseable `Date`
  is present and falls back to the integer form otherwise. That arm is unreachable from
  baikai's own transports anyway; the difference is documented in the code where a
  third-party provider will meet it. (2026-08-27, M3)
- __The `EP-8` comment in both `Sse.hs` was already gone.__ This plan's M3 scheduled
  replacing `-- EP-8 wires Options.timeoutMs through this local transport.` on the
  `responseTimeoutNone` line; EP-2 or EP-4 had already replaced it with the correct
  sentence. No edit was needed. (2026-08-27, M3)
- __EP-4's block closing already carries the partial text.__ The plan flagged the OpenAI
  "carrying the partial text" assertion as needing a fallback to `TextDelta` events if EP-4
  had not landed. EP-4 has landed, and both providers' terminals carry `"Hel"` in the
  closed text block, so both cases assert on the terminal as written. (2026-08-27, M1)


## Decision Log

- Decision: One transport classifier for both providers, in a new core module
  `Baikai.Provider.Transport.Classify` (file
  `baikai/src/Baikai/Provider/Transport/Classify.hs`), exporting
  `classifyTransportException :: SomeException -> Maybe BaikaiError` and the per-type
  functions it composes. The `baikai` library gains direct `build-depends` on
  `http-client`, `http-types` and `tls`. The module is *not* re-exported from the
  `Baikai` umbrella. `Baikai.Error` stays free of network types.
  Rationale: REV-2 A.2 is two identical copies of the same table drifting identically
  wrong; one implementation with one test suite is the fix, and a third-party `Custom`
  provider written over `http-client` (the path `docs/user/models-and-providers.md`
  teaches) gets the same classification for free. Plan 39 decided (2026-07-01) that
  core should not grow `http-client` "for two consumers"; that reasoning assumed a
  cost that no longer exists — the `openai` SDK already brings every one of these
  packages into core's build plan — and did not foresee that the table itself would need
  `tls` types to be complete. Putting the helper in `Baikai.Error` was rejected because
  that module is re-exported by the umbrella and its callers should never see
  `http-client` types. A third package was rejected as freeze-time churn for EP-10.
  Recognising `TLSException` by its type name through `Data.Typeable` instead of a
  `tls` dependency was rejected as a string match on a library internal.
  Date: 2026-08-27
- Decision: The classification rule for a failure raised while a stream is being driven
  is "where did it happen, not what type is it". Anything that breaks or ends the
  connection after the request went out is `TransientError`; anything that says the
  caller's request or the process's configuration is wrong is not retryable; a
  programming error stays `OtherError`. Concretely, in `classifyHttpExceptionContent`:
  `ConnectionFailure`, `ConnectionTimeout`, `ResponseTimeout`, `ConnectionClosed`,
  `NoResponseDataReceived`, `IncompleteHeaders`, `InvalidChunkHeaders`,
  `ResponseBodyTooShort`, `HttpZlibException` → `TransientError`;
  `InternalException se` → recurse into `se` (a `TLSException` by the TLS rule below,
  an `IOException` always `TransientError` because http-client only wraps socket
  failures there, anything else `TransientError` because http-client documents the
  constructor as "a failing socket action or a TLS exception"); `StatusCodeException` →
  `httpError` on its status, with `Retry-After` read in either form against the carried
  `Date` header; `InvalidRequestHeader`, `InvalidDestinationHost`,
  `WrongRequestBodyStreamSize` → `InvalidRequest`; `TooManyRedirects`,
  `OverlongHeaders`, `TooManyHeaderFields`, `InvalidStatusLine`, `InvalidHeader`,
  `ProxyConnectException`, `TlsNotSupported`, `InvalidProxyEnvironmentVariable`,
  `InvalidProxySettings` → `OtherError` (a server that does not speak HTTP, or a proxy
  or TLS configuration that cannot work, will not change on retry).
  `InvalidUrlException` → `InvalidRequest`. For a raw `IOException`
  (`classifyIOException`): `TransientError` when `ioe_type` is `ResourceVanished`,
  `EOF` or `TimeExpired`, or when `ioe_errno` is one of `ECONNABORTED`, `ECONNRESET`,
  `ENETRESET`, `ENETDOWN`, `ENETUNREACH`, `EHOSTDOWN`, `EHOSTUNREACH`, `ETIMEDOUT`,
  `EPIPE`; otherwise `Nothing`, so a `userError` from a buggy callback or a
  `NoSuchThing` from a file path stays `OtherError`. For a `TLSException`
  (`classifyTlsException`): `Terminated`, `PostHandshake` and `Uncontextualized` →
  `TransientError` (the session existed and broke); `HandshakeFailed`,
  `ConnectionNotEstablished`, `MissingHandshake` → `OtherError` (the session never
  existed: certificate, protocol or library-misuse problems).
  Rationale: the same reset is today retryable or not depending on which byte of the
  chunk framing it landed on (REV-2 A.2). Keying on the phase makes the answer
  independent of framing. The errno list exists because base maps `ECONNABORTED` to the
  `OtherError` error type, so a type-only rule would miss it. `HandshakeFailed` is not
  transient because against a well-known API host a handshake failure is a trust-store
  or protocol mismatch far more often than a blip, and a socket reset during connect is
  already delivered as `ConnectionFailure`, which is transient.
  Date: 2026-08-27
- Decision: In-band error frames on the OpenAI path are detected in the `parseChunk`
  region by a new `parseFrame :: Value -> Either String (Either BaikaiError RawChunk)`
  that first consults a new value classifier
  `classifyErrorFrame :: Value -> Maybe BaikaiError` in
  `Baikai.Provider.OpenAI.Internal.ErrorClass` and only then runs `parseChunk`. A frame
  is an object with an `error` key whose value is an object or a string, regardless of
  whether `choices` is present. Classification precedence inside the frame: a numeric
  `code` or `status` of 400 or more is treated as the upstream HTTP status and
  classified through `classifyHttpStatusWithBody` (recorded in `httpStatus`); else a
  string `code`, then a string `type`, is looked up in a fixed table; else the message
  is phrase-sniffed with the table that lives in today's `classifyErrorText`; else
  `OtherError`. The message always becomes `BaikaiError.message`. `classifyErrorText`
  and its `classifySdkHttpText` half are deleted from the OpenAI package, and the
  unreferenced `classifyErrorText` is deleted from the Claude package. The worker's
  `Right val -> case parseChunk val of` line becomes `parseFrame`; this is the one edit
  outside the `parseChunk` region and is flagged for EP-4.
  Rationale: the frame is JSON, so classifying its fields is strictly better than
  flattening it to text and sniffing; the SDK-text half of `classifyErrorText` parses a
  string the transport stopped producing in July and has no caller. Keying on `error`
  alone is the only rule that covers both OpenAI's and OpenRouter's documented shapes.
  Returning the classified error through the existing `Either BaikaiError RawChunk`
  channel element means the assembler's `Left` path (and EP-4's block-closing fix for
  it) applies unchanged.
  Date: 2026-08-27
- Decision (implementation): `classifyErrorFrame` treats a blank `message` as absent and
  substitutes the placeholder, rather than letting the empty string through.
  Rationale: the plan's `fromMaybe` only fired when the key was missing, but a host that
  sends `"message": ""` produces an error whose text says nothing at all; the frame's
  existence is the fact worth reporting. `ErrorClassSpec` "a frame whose message is blank
  still classifies" pins it.
  Date: 2026-08-27
- Decision (implementation): the header lookups use `http-types`' folded header constants
  (`hRetryAfter`, `hDate`) rather than `Data.CaseInsensitive.mk`.
  Rationale: the plan's sketch would have added `case-insensitive` as a fourth direct
  dependency of core for a value `http-types` — already needed for `statusCode` — exports
  as a constant.
  Date: 2026-08-27
- Decision: HTTP 413 classifies as `ContextOverflow` from the status alone, in
  `classifyHttpStatus`, whether or not the body carries an overflow marker.
  Rationale: `ContextOverflow`'s own Haddock reads "exceeded the model's context window
  or a related size limit", and 413 *is* the size-limit status; the caller's remedy
  (shrink the input) is identical either way. Making the category depend on body
  wording would recreate for 413 exactly the inconsistency A.2 describes for resets.
  The brief's alternative — `InvalidRequest` when no marker is present — was rejected
  for that reason.
  Date: 2026-08-27
- Decision: An HTTP-date `Retry-After` is converted to seconds. `Baikai.Error` gains
  `parseHttpDate :: Text -> Maybe UTCTime` (IMF-fixdate, plus the obsolete RFC 850 and
  asctime forms a recipient must accept) and
  `retryAfterSecondsAt :: UTCTime -> Text -> Maybe Int`, which accepts either form and
  clamps a past date to `0`. The reference instant is the response's `Date` header when
  it parses, else `getCurrentTime`. `parseRetryAfterSeconds` keeps its integer-only
  contract. The pinned `ErrorSpec` test "HTTP-date Retry-After is ignored" is rewritten
  as tests of the new functions, and the capability record's Limits bullet is rewritten.
  Rationale: in July the transports could not see headers at all, so the integer-only
  parser was a stopgap and the pin recorded that limitation, not a preference.
  CDN-fronted hosts send dates on `429`; a `RateLimited` with no hint makes the caller
  guess. Using the server's `Date` as the reference removes clock skew from the
  computation and keeps the transport-side call pure apart from one `getCurrentTime`
  fallback.
  Date: 2026-08-27
- Decision: `Options.timeoutMs = Just n` with `n <= 0` is rejected as
  `InvalidRequest` by `runWithTimeout` in both `Transport.hs`, before the action runs
  and therefore before any connection is opened; `Nothing` remains the only spelling of
  "no bound". The `max 0` clamp is removed.
  Rationale: today both values fail instantly as a *retryable* `TransientError`, which a
  caller's retry loop will re-issue forever. Reinterpreting `0` as "no bound" was
  rejected because a bound that underflowed to zero in the caller's arithmetic would
  then silently become unbounded, the opposite of what was asked for, and because
  `Nothing` already expresses "no bound" unambiguously. The check lives in
  `runWithTimeout` rather than `prepareCall` because `prepareCall` is EP-4's and the
  transport helper is this plan's; the observable result is the same — an
  `[EventStart, EventError]` stream and no bytes on the wire — and it is pinned by a
  test that counts accepted connections.
  Date: 2026-08-27
- Decision: Tests are retired as follows. Both `ErrorClassSpec.httpStatusTests`
  (`responseToError` over a hand-built servant `ResponseF`) are deleted; their
  assertions already exist against `httpError` in `baikai/test/ErrorSpec.hs` and
  against `sseFromResponse` in both `SseSpec.hs`, and the one that does not ("429
  without Retry-After -> no hint") is re-homed to `ErrorSpec`. `fromClientError` and
  `responseToError` are deleted from both packages. Both `sdkTextTests` are deleted.
  OpenAI `streamedErrorTests` is rewritten to feed `classifyErrorFrame` with
  `{"error":{"message":…}}` objects, so the phrase table stays pinned through the entry
  point the runtime uses. `ReasoningSpec` "whole message shape yields reasoning then
  text" is rewritten to push its object through `sseFromResponse` as a `data:` frame
  and `parseFrame`, which is the only way that object can reach the assembler; a
  companion test pins that a bare JSON body with no `data:` prefix is *not* decoded
  (that limitation belongs to EP-4's transport work and is recorded there). The Claude
  `ErrorClassSpec` case "non-integer Retry-After is ignored" is superseded by the
  HTTP-date tests.
  Rationale: a test that feeds a shape the runtime cannot produce proves nothing and
  costs review time (REV-2 Theme I item 1). Nothing in either provider package
  constructs a servant response; `Baikai.Embedding` uses the SDK's servant client but
  never touches these classifiers.
  Date: 2026-08-27
- Decision: The stalled-socket test opens a real TCP listener on `127.0.0.1` with port
  `0` (the kernel assigns a free port, read back with `Network.Socket.socketPort`),
  accepts one connection on a forked thread and holds it without reading or writing,
  points a `Model` at `http://127.0.0.1:<port>` with `ApiKeyLiteral "test-key"` and
  `timeoutMs = Just 200`, drains the live stream (`openaiChatStream` /
  `claudeMessagesStream`) under a ten-second guard, and expects
  `[EventStart, EventError]` with `TransientError`, `isRetryable = True` and a message
  containing `timeoutMs=200`. The zero-timeout test reuses the listener and asserts the
  accept counter is still `0` after the stream drains. The test-suite stanzas gain
  `network` (already in the build plan through `http-client`).
  Rationale: REV-1 5.1's residual is that the worker → channel → `EventError` path for
  a real stall was verified by reading only; only a socket that never answers exercises
  `HTTP.withResponse`'s bracket under `System.Timeout`. Port `0` avoids collisions
  with anything else on the machine and with a parallel test run.
  Date: 2026-08-27
- Decision: `finish_reason = "content_filter"` keeps `category = OtherError`. This plan
  does not widen the closed `ErrorCategory` sum. Question recorded for EP-10's Decision
  Log (`docs/plans/67-freeze-the-public-surface.md`): should the freeze add a
  `ContentFiltered` (or similar) constructor so a consumer can distinguish a filter from
  any other non-retryable failure without matching on message text? Until EP-10
  answers, the message `provider stopped the response: finish_reason=content_filter`
  remains the distinguishing signal.
  Rationale: `ErrorCategory` is documented as closed and stable; widening it is a
  surface decision that belongs to the plan freezing the surface.
  Date: 2026-08-27
- Decision: A new ADR is warranted and is written in Milestone 4:
  `docs/adr/0006-core-owns-transport-failure-classification.md`, recording that
  transport-failure classification is owned by core and keyed on the phase in which the
  failure occurred, and that this supersedes plan 39's "core stays free of
  `http-client`" rationale. `docs/adr/README.md` gains the row.
  Rationale: this is a shared-interface-ownership decision that reverses a recorded one,
  which is exactly what `agents/skills/exec-plan/ADR.md` says an ADR is for. The local
  corpus is the plain-file convention of `docs/adr/0001-…`, so no handle allocation or
  profile validation applies.
  Date: 2026-08-27
- Decision: Out of scope, left to the owning plans and named here so nobody looks for
  them: closing open blocks on the OpenAI mid-stream `Left` path (REV-2 B.3, EP-4);
  `[DONE]` with trailing whitespace and empty `data:` heartbeats (A.8, EP-4); unknown
  Anthropic event types aborting a stream (B.5, EP-4); the missing `EventStart` on the
  Claude wire-failure path (A.4, EP-4); `redirectCount = 0` and base-path composition
  (A.5, A.6, EP-2); evidence content for a call that failed inside the worker before
  any byte was sent (EP-8, which already treats `ConnectionFailure` this way).
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

baikai is a multi-package Haskell workspace (`cabal.project` at the repository root
`/Users/shinzui/Keikaku/bokuno/baikai`; GHC comes from the Nix dev shell). The packages
this plan touches:

- `baikai/` — the core vocabulary. `baikai/src/Baikai/Error.hs` holds the `BaikaiError`
  record (`category :: ErrorCategory`, `message`, `httpStatus`, `retryAfterSeconds`,
  `exitCode`), the closed `ErrorCategory` sum, `isRetryable` (true for `RateLimited`
  and `TransientError` only), and the pure helpers `httpError`,
  `parseRetryAfterSeconds`, `classifyHttpStatus`, `classifyHttpStatusWithBody` and
  `bodyIndicatesOverflow`. It is re-exported by the `Baikai` umbrella
  (`baikai/src/Baikai.hs`). `baikai/src/Baikai/Options.hs` documents `timeoutMs` as a
  wall-clock bound on the whole API call. The core test suite is `baikai/test/Main.hs`
  with one module per area (`ErrorSpec.hs` is the one this plan edits).
- `baikai-claude/` — the Anthropic provider. `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
  holds the streaming producer (EP-4's file); `.../Sse.hs` the local SSE transport;
  `.../Transport.hs` the client cache, header builder, key resolver and `runWithTimeout`;
  `.../Internal/ErrorClass.hs` the classifiers. Tests live in `baikai-claude/test/`
  (`Main.hs`, `ErrorClassSpec.hs`, `SseSpec.hs`, `TransportSpec.hs`, `EvidenceSpec.hs`,
  and others).
- `baikai-openai/` — the OpenAI-compatible provider, mirror structure under
  `baikai-openai/src/Baikai/Provider/OpenAI/` and `baikai-openai/test/`, plus
  `ReasoningSpec.hs`.

Terms used below, defined once here. "SSE" is Server-Sent Events, the line protocol
both vendors stream over: frames of `data: <json>` lines separated by a blank line. The
"transport" is the baikai-owned code that POSTs the request with `http-client` and
turns the response bytes into decoded frames (`sseFromResponse` in each `Sse.hs`). The
"body reader" is `http-client`'s `BodyReader`, an `IO ByteString` action (`brRead`) that
returns the next piece of the response body and an empty string at the end; the
transport calls it in a loop. "Chunked transfer encoding" is the HTTP framing streams
use: the body is a sequence of length-prefixed chunks, so a server that closes the
socket in the middle leaves the reader with a half chunk — that is what
`InvalidChunkHeaders` means. The "worker" is the thread each provider forks per call
(`worker` in each `Api.hs`); it runs the transport under `Transport.runWithTimeout`
inside `trySync`, forwards each decoded frame onto a `Chan`, converts any exception
into a `BaikaiError` with `exceptionToError` (which tries `fromException` for a thrown
`BaikaiError`, then `classifyException`), and closes the channel with `Nothing`. A
"classifier" is a function from a failure shape to a `BaikaiError`. A "retryable
category" is one for which `isRetryable` is true: `RateLimited` or `TransientError`.
An "in-band error frame" is an SSE `data:` frame on a successful (`2xx`) response
whose JSON is an error report rather than a completion chunk, for example
`{"error":{"message":"Provider returned error","code":502}}`. An "HTTP-date" is the
date form HTTP headers use, `Wed, 21 Oct 2026 07:28:00 GMT` (RFC 7231's IMF-fixdate);
`Retry-After` may carry either that or a plain number of seconds. A "driver" is the
seam both providers expose for tests (`SseDriver` in each `Api.hs`): production passes
`liveSseDriver`, tests pass a function that feeds a hand-built `HTTP.Response
BodyReader` through the real `sseFromResponse`.

How a streaming call fails today, and where each finding bites (line numbers as of
`c3753c5`, the reviewed commit; the working tree is one documentation commit later):

1. `openaiChatStreamWith` (`OpenAI/Api.hs:196-236`) runs `prepareCall` under
   `trySync`; a failure there becomes `immediateError` = `[EventStart, EventError]`.
   Otherwise it forks `worker` (`:316-341`), which runs the driver under
   `runWithTimeout (call ^. #timeoutMs)`. The driver is `openaiSseStreamValueWithHeaders`
   (`OpenAI/Sse.hs:115-140`): `HTTP.withResponse` then `sseFromResponse`
   (`:149-212`), which on a non-2xx consumes the body and emits one
   `Left (httpError status retryAfter body)` (`:157-164`) and otherwise loops on
   `brRead` (`:193`) decoding `data:` frames into `Right value`. The Claude twin is
   `claudeMessagesStreamWith` (`Claude/Api.hs:175-214`), `worker` (`:259-278`), and
   `Claude/Sse.hs:118-214`, with typed `MessageStreamEvent` values instead of raw JSON.
2. **A.2.** When `brRead` throws, the exception propagates out of the driver, through
   `runWithTimeout`, to `trySync` in the worker, which writes
   `Left (exceptionToError e)`. `exceptionToError` calls `classifyException`
   (`OpenAI/Internal/ErrorClass.hs:48-52`; Claude `:52-56`), whose
   `fromHttpExceptionContent` (`:83-98`; Claude `:92-107`) maps only the six
   connect-time constructors to `TransientError` and everything else — including
   `InvalidChunkHeaders`, `ResponseBodyTooShort`, `InternalException` — to
   `providerError (show other)`, category `OtherError`. A raw `IOException` or
   `TLSException` (see Surprises & Discoveries for why they arrive raw) misses the
   `HttpException` branch entirely and falls to the `otherwise` arm: `OtherError`. The
   worker's `Left be` reaches `translate` (`OpenAI/Api.hs:905-913`) and becomes the
   terminal `EventError`.
3. **A.3.** On the OpenAI path, every `Right value` is parsed by `parseChunk`
   (`OpenAI/Api.hs:343-385`), which reads `choices`, `usage`, `model` and `id` and never
   looks at `error`. An error frame therefore parses as an empty `RawChunk`; the
   assembler emits nothing; the host closes the stream; `closeOpenStream`
   (`:1214-1246`) takes the "no finish_reason" branch and emits
   `providerError "openai stream ended without finish_reason"`. `classifyErrorText`
   (`Internal/ErrorClass.hs:112-129`) exists for this case and has no production caller
   (residual 1.2 of REV-1); its first half parses the *old* SDK's `"HTTP error <code>"`
   text, which the local transport has not produced since July. On the Claude path an
   in-band error is a typed `Messages.Error` event and is already classified by
   `classifyErrorValue` (`Claude/Api.hs:644-649`); that path stays.
4. **A.7.** `classifyHttpStatusWithBody` (`Error.hs:212-216`) consults
   `bodyIndicatesOverflow` only for 400 and 422, and `classifyHttpStatus`
   (`:199-206`) has no 413 arm, so a 413 lands in `OtherError` even when its body says
   `request_too_large`, a marker the list itself contains (`:233`).
5. **A.9.** `parseRetryAfterSeconds` (`Error.hs:171-174`) is `readMaybe`; a date yields
   `Nothing`, and `sseFromResponse` (`OpenAI/Sse.hs:161-163`, Claude `:163-165`) uses
   nothing else. `ErrorSpec` line 44 pins the behaviour.
6. **A.10.** `runWithTimeout` (`Claude/Transport.hs:88-94`, OpenAI `:62-68`) clamps with
   `max 0 ms`, so zero and negative bounds fail instantly as `TransientError`. Both
   `Sse.hs` request builders carry the comment "EP-8 wires Options.timeoutMs through
   this local transport" on the `responseTimeoutNone` line (`Claude/Sse.hs:139`,
   `OpenAI/Sse.hs:136`), which is wrong: the bound is `runWithTimeout`, and the
   `http-client` response timeout is deliberately none.
7. **Theme I item 1 and REV-1 residuals 1.2, 1.3, 1.7.** Both `ErrorClassSpec.hs`
   files build servant `ResponseF` values for `responseToError` (Claude `:34-70`, OpenAI
   `:32-59`) and feed `"HTTP error 429 …"` strings to `classifyErrorText`
   (`sdkTextTests`); `ReasoningSpec.hs:86-110` feeds `parseChunk` a whole-message object
   that the transport drops before `parseMessageObject` (`OpenAI/Api.hs:387-397`) could
   see it. Both module Haddocks (`Claude/Internal/ErrorClass.hs:7-10`,
   `OpenAI/Internal/ErrorClass.hs:7-9`) describe a servant entry point the streaming path
   no longer has, and `docs/capabilities/anthropic-messages-backend.md:48-51` says
   classification comes from a servant `ClientError`. Residual 1.7 (`content_filter` is
   the closed `OtherError`) is handed to EP-10 by the Decision Log.
8. **REV-1 5.1 residual.** `TransportSpec` in both packages tests `runWithTimeout`
   with `threadDelay` only; no test drives a socket that never answers through the
   worker.

ADR context. `docs/adr/` is the plain-file convention described in
`docs/adr/0001-architecture-decision-record-convention.md` (frontmatter `title`,
`status`, `date`; body Context, Decision, Consequences; no OKF profile, no handle
allocation). `docs/adr/0005-what-baikai-deliberately-does-not-do.md` bounds this plan:
"Baikai does not own retries. It has no retry or fallback loop: `Baikai.Error`
classifies whether an error is retryable and nothing acts on it." Every change below
improves the classification and adds no retry, backoff or fallback behaviour anywhere.
`docs/adr/0002-…`, `0003-…` and `0004-…` concern evidence and are not touched. No
cross-repository ADR applies. This plan creates `docs/adr/0006-…` (Decision Log).


## Plan of Work

The work is four milestones fixed by the MasterPlan: classify the shapes `http-client`
actually raises mid-body through one shared helper (M1); detect and classify in-band
error frames on the OpenAI path (M2); fix 413, HTTP-date `Retry-After` and the
`timeoutMs` edges, and prove the timeout path against a real socket (M3); retire the
unreachable-shape tests and bring the classifier documentation back to the transport
(M4). Each milestone builds and tests green on its own. Before starting, read EP-4's
landed Decision Log and `git log --oneline -20`; the "Reconcile with EP-4" flags say
what to adapt.


### Milestone 1 — mid-stream transport failures classified from the shapes http-client actually raises

Scope: a new core module, both `Internal/ErrorClass.hs` modules, three cabal stanzas
and two new test modules. At the end, every exception the worker can catch from the
transport — an `HttpException` of any constructor, a raw `IOException` from the socket,
a raw or wrapped `TLSException` — classifies through one function with one test suite,
and a fake server that resets the connection after two chunks yields a retryable
terminal on both providers. Verify with `cabal test baikai baikai-claude baikai-openai`.

First, add the dependencies. In `baikai/baikai.cabal`, in the `library` stanza's
`build-depends` (the alphabetical list at lines 96–117), add `http-client ^>=0.7`,
`http-types ^>=0.12` and `tls`. Set the `tls` bound after checking what the build plan
resolves and what Hackage currently ships (`cabal build all --dry-run` after the edit;
the local index at the time of writing lists 2.4.3 as newest and the plan resolves
2.2.2): `tls >=2.2 && <2.5` is the expected answer, and the six `TLSException`
constructors used below exist across that range. Add the new module to
`exposed-modules` as `Baikai.Provider.Transport.Classify`. In the `test-suite
baikai-test` stanza add `http-client`, `http-types`, `tls` to `build-depends` and
`TransportClassifySpec` to `other-modules`.

Second, create `baikai/src/Baikai/Provider/Transport/Classify.hs`. Its module Haddock
states the rule from the Decision Log in one paragraph ("a failure after the request
went out that breaks or ends the connection is transient; a failure that says the
request or the configuration is wrong is not; a programming error is neither and stays
`OtherError`") and names the three exception types it understands and why they arrive
raw. Its surface:

```haskell
module Baikai.Provider.Transport.Classify
  ( classifyTransportException,
    classifyHttpException,
    classifyHttpExceptionContent,
    classifyIOException,
    classifyTlsException,
  )
where

-- | Classify any exception the transport can raise. 'Nothing' means
-- "not a transport failure"; the caller keeps its own fallback.
classifyTransportException :: SomeException -> Maybe BaikaiError
classifyTransportException ex
  | Just httpEx <- fromException ex = Just (classifyHttpException httpEx)
  | Just tlsEx <- fromException ex = Just (classifyTlsException tlsEx)
  | Just ioEx <- fromException ex = classifyIOException ioEx
  | otherwise = Nothing

classifyHttpException :: HTTP.HttpException -> BaikaiError
classifyHttpException = \case
  HTTP.InvalidUrlException url reason -> invalidRequest (Text.pack (url <> ": " <> reason))
  HTTP.HttpExceptionRequest _ content -> classifyHttpExceptionContent content

classifyHttpExceptionContent :: HTTP.HttpExceptionContent -> BaikaiError
classifyHttpExceptionContent = \case
  -- A response arrived and carried a failing status.
  HTTP.StatusCodeException resp body ->
    let hdrs = HTTP.responseHeaders resp
        headerText name = decodeLenient <$> lookup (CI.mk name) hdrs
        reference = parseHttpDate =<< headerText "Date"
        retryAfter = headerText "Retry-After" >>= \raw ->
          maybe (parseRetryAfterSeconds raw) (`retryAfterSecondsAt` raw) reference
     in httpError (statusCode (HTTP.responseStatus resp)) retryAfter (decodeLenient body)
  -- The connection could not be made, or went quiet or away.
  HTTP.ConnectionFailure e -> transient ("connection failure: " <> Text.pack (displayException e))
  HTTP.ConnectionTimeout -> transient "connection timeout"
  HTTP.ResponseTimeout -> transient "response timeout"
  HTTP.ConnectionClosed -> transient "connection closed"
  HTTP.NoResponseDataReceived -> transient "no response data received"
  HTTP.IncompleteHeaders -> transient "incomplete response headers"
  -- The body broke after the status line: framing, length, or inflation.
  HTTP.InvalidChunkHeaders -> transient "chunked response body ended or broke mid-chunk"
  HTTP.ResponseBodyTooShort expected actual ->
    transient ("response body too short: expected " <> tshow expected <> " bytes, got " <> tshow actual)
  HTTP.HttpZlibException e -> transient ("compressed response body could not be inflated: " <> tshow e)
  -- http-client's own wrapper for socket and TLS failures at connect time.
  HTTP.InternalException inner
    | Just tlsEx <- fromException inner -> classifyTlsException tlsEx
    | Just ioEx <- fromException inner -> transient (Text.pack (displayException (ioEx :: IOException)))
    | otherwise -> transient (Text.pack (displayException inner))
  -- The caller's request cannot be sent as written.
  HTTP.InvalidRequestHeader h -> invalidRequest ("invalid request header: " <> decodeLenient h)
  HTTP.InvalidDestinationHost h -> invalidRequest ("invalid destination host: " <> decodeLenient h)
  HTTP.WrongRequestBodyStreamSize expected actual ->
    invalidRequest ("request body size mismatch: declared " <> tshow expected <> ", sent " <> tshow actual)
  -- Everything else is a server that does not speak HTTP or an
  -- environment that cannot work; retrying changes nothing.
  other -> providerError (Text.take 300 (tshow other))
  where
    transient t = (providerError ("connection error: " <> t)) {category = TransientError}
    tshow :: (Show a) => a -> Text
    tshow = Text.pack . show

classifyIOException :: IOException -> Maybe BaikaiError
classifyIOException ioe
  | IOE.ioe_type ioe `elem` [IOE.ResourceVanished, IOE.EOF, IOE.TimeExpired] = Just (transient detail)
  | Just n <- IOE.ioe_errno ioe, Errno n `elem` socketErrnos = Just (transient detail)
  | otherwise = Nothing
  where
    detail = Text.pack (displayException ioe)
    transient t = (providerError ("connection error: " <> t)) {category = TransientError}
    socketErrnos =
      [eCONNABORTED, eCONNRESET, eNETRESET, eNETDOWN, eNETUNREACH, eHOSTDOWN, eHOSTUNREACH, eTIMEDOUT, ePIPE]

classifyTlsException :: TLS.TLSException -> BaikaiError
classifyTlsException = \case
  TLS.Terminated _ why err -> transient ("TLS session terminated: " <> Text.pack why <> " (" <> tshow err <> ")")
  TLS.PostHandshake err -> transient ("TLS failure after handshake: " <> tshow err)
  TLS.Uncontextualized err -> transient ("TLS failure: " <> tshow err)
  TLS.HandshakeFailed err -> providerError ("TLS handshake failed: " <> tshow err)
  TLS.ConnectionNotEstablished -> providerError "TLS connection not established"
  TLS.MissingHandshake -> providerError "TLS handshake missing"
  where
    transient t = (providerError ("connection error: " <> t)) {category = TransientError}
    tshow :: (Show a) => a -> Text
    tshow = Text.pack . show
```

Imports: `Network.HTTP.Client qualified as HTTP`, `Network.HTTP.Types.Status (statusCode)`,
`Network.TLS qualified as TLS`, `GHC.IO.Exception qualified as IOE` (qualified because its
`IOErrorType` has a constructor named `OtherError` that collides with `ErrorCategory`'s),
`Foreign.C.Error (Errno (..), eCONNABORTED, …)`, `Data.CaseInsensitive qualified as CI`,
and from `Baikai.Error` the constructors and `httpError`, `invalidRequest`,
`providerError`, `parseRetryAfterSeconds`, `parseHttpDate`, `retryAfterSecondsAt`. The
last two do not exist until Milestone 3; either write the `StatusCodeException` arm with
`parseRetryAfterSeconds` only in this milestone and upgrade it in M3, or land M3's
`Error.hs` additions first — the order does not matter for correctness, and the
`StatusCodeException` arm is unreachable in baikai anyway. `decodeLenient` is
`Text.decodeUtf8With Text.lenientDecode`, copied from the `Sse.hs` modules.

Third, rewire both classifiers. In
`baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs`, delete
`fromClientError`, `responseToError`, `parseRetryAfter`, `fromHttpException`,
`fromHttpExceptionContent`, `parseRetryAfterHttp` and the `Servant.Client`,
`Network.HTTP.Client`, `Data.Sequence`, `Data.ByteString.Lazy` and `Data.CaseInsensitive`
imports they needed; keep `classifyErrorValue`, `anthropicTypeToCategory` and (until
Milestone 2 deletes it) `classifyErrorText`. `classifyException` becomes:

```haskell
classifyException :: SomeException -> BaikaiError
classifyException ex =
  fromMaybe
    (providerError (Text.pack (displayException ex)))
    (classifyTransportException ex)
```

Do the same in `baikai-openai/src/Baikai/Provider/OpenAI/Internal/ErrorClass.hs`. Both
export lists drop `responseToError`. `Api.hs` in both packages imports only
`classifyException` (and `classifyErrorValue` on Claude) and needs no change. Rewrite
the module Haddock of each now rather than in M4, because the servant sentence is wrong
the moment the branch is deleted: "Two entry points: `classifyException` for any
exception the worker catches from the transport — `http-client`, TLS and socket
failures, delegated to `Baikai.Provider.Transport.Classify` — and `classifyErrorValue`
for an Anthropic `error` event" (Claude), and the equivalent naming `classifyErrorFrame`
on the OpenAI side once M2 adds it.

Fourth, the tests. Create `baikai/test/TransportClassifySpec.hs` and add `tests` to the
`testGroup` in `baikai/test/Main.hs`. Each case builds the exception value the runtime
produces and asserts on `category` and `isRetryable`:

- "a connection reset during the body read is transient": an `IOError` with
  `ioe_type = ResourceVanished`, `ioe_location = "Network.Socket.recvBuf"`,
  `ioe_description = "Connection reset by peer"`, `ioe_errno = Just n` where
  `Errno n = eCONNRESET` → `Just` with `TransientError`, retryable.
- "ECONNABORTED is recognised by errno when the error type is OtherError": same record
  with `ioe_type = IOE.OtherError` and `eCONNABORTED` → `TransientError`.
- "a userError is not a transport failure": `classifyIOException (userError "bug")`
  → `Nothing`, and `classifyTransportException (toException (userError "bug"))` →
  `Nothing`.
- "InvalidChunkHeaders is transient", "ResponseBodyTooShort is transient",
  "ConnectionClosed is transient", "IncompleteHeaders is transient",
  "NoResponseDataReceived is transient", "ConnectionTimeout and ResponseTimeout are
  transient", "ConnectionFailure is transient": each via
  `classifyHttpExceptionContent`.
- "a TLS end-of-file after the handshake is transient":
  `TLS.PostHandshake TLS.Error_EOF`; "a terminated TLS session is transient":
  `TLS.Terminated True "peer closed" TLS.Error_EOF`.
- "a failed TLS handshake is not retryable":
  `TLS.HandshakeFailed (TLS.Error_Misc "certificate rejected")` → `OtherError`,
  `isRetryable = False`; also through `HTTP.InternalException (toException …)`.
- "InternalException unwraps to the inner rule": `InternalException` around a
  `ResourceVanished` `IOError` → `TransientError`; around a `HandshakeFailed` →
  `OtherError`.
- "InvalidUrlException is InvalidRequest"; "InvalidRequestHeader is InvalidRequest";
  "InvalidStatusLine, TooManyHeaderFields and TlsNotSupported are not retryable".
- "StatusCodeException classifies by status and reads an HTTP-date Retry-After against
  the Date header" (written in M3 when the helpers exist; list it here so it is not
  forgotten).

Then create `baikai-openai/test/MidStreamSpec.hs` and `baikai-claude/test/MidStreamSpec.hs`
(add to `other-modules` and to each `Main.hs` `testGroup`). Their fixture is the
`mkResponse` from `EvidenceSpec.hs` with one difference: the body reader throws after
the recorded chunks run out.

Copy `mkResponse` from `EvidenceSpec.hs` as `mkFailingResponse :: [ByteString] ->
SomeException -> IO (HTTP.Response HTTP.BodyReader)` and change the exhausted branch
of its body reader from `[] -> pure ""` to `[] -> throwIO ex`: the reader yields the
recorded chunks in order and then raises from `brRead`, which is exactly what a socket
reset, a mid-chunk close or a TLS termination looks like to the transport. Wrap it as a
driver:

```haskell
failingDriver :: [ByteString] -> SomeException -> SseDriver
failingDriver chunks ex _env _headers _body onMetadata onEvent = do
  resp <- mkFailingResponse chunks ex
  sseFromResponse resp onMetadata onEvent
```

(The Claude `SseDriver` takes a `ClaudeCall` instead of `_env _headers _body`; adapt the
first three parameters.) Drive `openaiChatStreamWith (failingDriver chunks ex) model
ctx opts` with `Stream.toList` and a `Model` built like `openaiTestModel` in
`baikai-openai/test/Main.hs` plus `#apiKey .~ Just (ApiKeyLiteral "test-key")` on the
options so no environment variable is consulted. The OpenAI chunks are two
`data: {"id":"chatcmpl-1","model":"m","choices":[{"index":0,"delta":{"content":"Hel"}}]}\n\n`
style frames (`"Hel"` then `"lo"`); the Claude chunks are a `message_start`, a
`content_block_start` of type `text` at index 0, and one `content_block_delta` with
`text_delta` `"Hel"` (copy the `message_start` body from `SseSpec.hs`'s `successBody`).
Cases, each asserting with a copy of `assertErrorContract` from `Main.hs` (exactly one
terminal, `EventError` carries `errorInfo`) and then on the terminal's `errorInfo`:

- "a connection reset after two chunks ends with a retryable EventError carrying the
  partial text": the `ResourceVanished` `IOError` above → `TransientError`,
  `isRetryable`, and the terminal message's content contains `"Hel"`. **Reconcile with
  EP-4**: on OpenAI the partial text reaches the terminal only after EP-4 closes open
  blocks on the `Left` path (REV-2 B.3); before EP-4, assert on the `TextDelta` events
  in the list instead.
- "a chunked-encoding EOF classifies as TransientError":
  `toException (HTTP.HttpExceptionRequest HTTP.defaultRequest HTTP.InvalidChunkHeaders)`.
- "a TLS termination mid-body classifies as TransientError":
  `toException (TLS.PostHandshake TLS.Error_EOF)` raised raw, as it is from `brRead`.
- "a programming error in the body path stays OtherError":
  `toException (userError "bug in callback")` → `OtherError`, not retryable.

Acceptance: `cabal test baikai baikai-claude baikai-openai` passes; the "connection
reset" and "chunked-encoding EOF" cases fail against the pre-milestone classifier with
`OtherError` (run them once before rewiring `classifyException` to see the failure).


### Milestone 2 — in-band `{"error": …}` frames on 2xx streams classified

Scope: the OpenAI `Internal/ErrorClass.hs`, the `parseChunk` region of the OpenAI
`Api.hs`, one line in its worker, and the Claude `Internal/ErrorClass.hs` deletion. At
the end, an error frame on a `200` stream terminates the call with the frame's own
classification and message. Verify with `cabal test baikai-openai baikai-claude`.

First, in `baikai-openai/src/Baikai/Provider/OpenAI/Internal/ErrorClass.hs` delete
`classifyErrorText` and `classifySdkHttpText` and add the value classifier. Keep the
phrase table from the old `classifyErrorText` as the private `categoryFromMessage`.

```haskell
-- | Classify an in-band error frame: a decoded SSE payload on a 2xx
-- stream whose JSON reports a failure instead of a completion chunk.
-- Returns 'Nothing' for anything without an @error@ key, so ordinary
-- chunks pass through untouched.
classifyErrorFrame :: Value -> Maybe BaikaiError
classifyErrorFrame (Object o) = do
  errVal <- KeyMap.lookup "error" o
  inner <- case errVal of
    Object e -> Just e
    String s -> Just (KeyMap.singleton "message" (String s))
    _ -> Nothing
  let msg = fromMaybe "provider sent an error frame without a message" (stringField "message" inner)
      status = numberField "code" inner <|> numberField "status" inner
      byName = (stringField "code" inner >>= codeToCategory msg) <|> (stringField "type" inner >>= codeToCategory msg)
      cat = case status of
        Just n | n >= 400 -> classifyHttpStatusWithBody n Nothing msg
        _ -> fromMaybe (categoryFromMessage msg) byName
  Just (providerError msg) {category = cat, httpStatus = status}
classifyErrorFrame _ = Nothing
```

`stringField` and `numberField` are the obvious `KeyMap.lookup` helpers (`numberField`
accepts an integral `Number` only). `codeToCategory :: Text -> Text -> Maybe ErrorCategory`
maps, case-insensitively: `rate_limit_error`, `rate_limit_exceeded`, `tokens`,
`requests`, `too_many_requests` → `RateLimited`; `authentication_error`,
`permission_error`, `invalid_api_key`, `insufficient_quota`, `billing_not_active`,
`account_deactivated` → `AuthError`; `context_length_exceeded`, `request_too_large` →
`ContextOverflow`; `server_error`, `overloaded_error`, `engine_overloaded`,
`service_unavailable`, `timeout`, `upstream_error`, `provider_error` →
`TransientError`; `invalid_request_error`, `model_not_found`, `invalid_value`,
`unsupported_value`, `missing_required_parameter` → `ContextOverflow` when
`bodyIndicatesOverflow msg`, else `InvalidRequest`; anything else → `Nothing`.
`categoryFromMessage` is today's table verbatim: overflow marker → `ContextOverflow`;
"rate limit"/"rate_limit" → `RateLimited`; "overloaded"/"server_error"/"service
unavailable" → `TransientError`; "insufficient_quota"/"invalid api key"/"incorrect api
key"/"invalid_api_key" → `AuthError`; else `OtherError`. Export `classifyErrorFrame`.

Second, in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, directly above
`parseChunk`, add and export:

```haskell
-- | Sort one decoded SSE frame into what it is: a classified in-band
-- error, or a completion chunk. Compatible hosts report an upstream
-- failure on a 2xx stream as a frame carrying an @error@ object, with
-- or without a @choices@ array beside it; such a frame ends the call
-- with the failure's own classification instead of being dropped.
parseFrame :: Value -> Either String (Either BaikaiError RawChunk)
parseFrame v = case classifyErrorFrame v of
  Just be -> Right (Left be)
  Nothing -> Right <$> parseChunk v
```

and change the worker's `Right val ->` arm (`Api.hs:333-336` at `c3753c5`) to:

```haskell
Right val -> case parseFrame val of
  Left err -> writeChan ch (Just (Left (providerError (Text.pack err))))
  Right frame -> writeChan ch (Just frame)
```

**Reconcile with EP-4**: this is the one edit outside the `parseChunk` region. EP-4
rewrites `worker` to hold its `ThreadId`; apply the arm change to EP-4's landed
`worker` and record the edit in EP-4's Decision Log as the MasterPlan's Integration
Points require. Import `classifyErrorFrame` next to `classifyException`. Nothing in
`translate` changes: the `Left be` element takes the existing error path.

Third, delete `classifyErrorText` from
`baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs` (and its `readMaybe`
import). It has no caller.

Tests. In `baikai-openai/test/ErrorClassSpec.hs`, add `errorFrameTests` on
`classifyErrorFrame`: "an OpenRouter upstream 502 frame is TransientError with
httpStatus 502" (`{"error":{"message":"Provider returned error","code":502,"metadata":{"provider_name":"x"}},"choices":[{"index":0,"finish_reason":"error","delta":{}}]}`);
"an OpenAI insufficient_quota frame is AuthError and not retryable"
(`{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}`);
"a rate_limit_exceeded code is RateLimited"; "a context_length_exceeded code is
ContextOverflow"; "a string-valued error is a frame"; "a chunk without an error key is
not a frame" (`{"choices":[]}` → `Nothing`); and the rewritten `streamedErrorTests`,
each feeding `{"error":{"message": <phrase>}}` with the four phrases the old test used
and expecting the same categories, plus "a frame whose message is blank still
classifies" (`OtherError`, message is the placeholder). In `baikai-openai/test/SseSpec.hs`
switch the `parsed` helper to `parseFrame` and add "an in-band error frame on a 2xx
stream reaches the assembler as a classified Left" (replay a 200 body of one content
chunk, the 502 frame, then `[DONE]`; fold with `translate`; assert the last event list
element is `EventError` with `TransientError`, `httpStatus = Just 502`). In
`baikai-openai/test/MidStreamSpec.hs` add the end-to-end twins through
`openaiChatStreamWith` with a plain `mkResponse` replay driver (copy `replayDriver`
from `EvidenceSpec.hs`): "an in-band error frame on a 2xx stream terminates with the
frame's classification" (502 → `TransientError`, message `Provider returned error`,
`isRetryable`) and "an in-band insufficient_quota frame is AuthError and not
retryable". Both assert `assertErrorContract` and that the first event is `EventStart`.

Acceptance: `cabal test baikai-openai baikai-claude` passes; the 502-frame end-to-end
test fails before this milestone with message `openai stream ended without
finish_reason` and category `OtherError`.


### Milestone 3 — 413 overflow, HTTP-date `Retry-After`, and `timeoutMs` edge semantics

Scope: `baikai/src/Baikai/Error.hs`, the non-2xx branch of both `sseFromResponse`, both
`runWithTimeout`, the `timeoutMs` Haddock in `baikai/src/Baikai/Options.hs`, and the
stalled-socket tests. Verify with `cabal test baikai baikai-claude baikai-openai`.

First, `Error.hs`. In `classifyHttpStatus` insert `| status == 413 = ContextOverflow`
before the `400 || 404 || 422` guard, and update its Haddock and the `ContextOverflow`
constructor's Haddock ("HTTP 413, or a 400/422 whose body names the context window").
Add, importing `Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, parseTimeM)`,
`Control.Applicative ((<|>))`, `Data.Maybe (listToMaybe, mapMaybe)`:

```haskell
-- | Parse an HTTP-date (RFC 7231 section 7.1.1.1). Accepts the
-- IMF-fixdate form servers must send plus the obsolete RFC 850 and
-- asctime forms a recipient must still accept.
parseHttpDate :: Text -> Maybe UTCTime
parseHttpDate raw = listToMaybe (mapMaybe attempt formats)
  where
    s = Text.unpack (Text.strip raw)
    attempt fmt = parseTimeM True defaultTimeLocale fmt s
    formats =
      [ "%a, %d %b %Y %H:%M:%S GMT", -- Sun, 06 Nov 1994 08:49:37 GMT
        "%A, %d-%b-%y %H:%M:%S GMT", -- Sunday, 06-Nov-94 08:49:37 GMT
        "%a %b %e %H:%M:%S %Y" -- Sun Nov  6 08:49:37 1994
      ]

-- | Seconds to wait, from a @Retry-After@ value in either form, relative
-- to a reference instant (the response's @Date@ when known, else now).
-- A date already in the past yields @Just 0@; unparseable text yields
-- 'Nothing'.
retryAfterSecondsAt :: UTCTime -> Text -> Maybe Int
retryAfterSecondsAt reference raw =
  parseRetryAfterSeconds raw <|> (secondsUntil <$> parseHttpDate raw)
  where
    secondsUntil t = max 0 (ceiling (diffUTCTime t reference))
```

Export both. Update the Haddock of `parseRetryAfterSeconds` ("integer form only; see
`retryAfterSecondsAt` for the HTTP-date form") and of the `retryAfterSeconds` field
("parsed from a `Retry-After` header in either its integer or HTTP-date form").

Second, both `sseFromResponse` non-2xx branches (`OpenAI/Sse.hs:157-164`,
`Claude/Sse.hs:159-166`):

```haskell
then do
  bodyChunks <- HTTP.brConsume (HTTP.responseBody response)
  now <- getCurrentTime
  let bodyText = decodeLenient (SBS.concat bodyChunks)
      headerText name = decodeLenient <$> lookup (CI.mk name) (HTTP.responseHeaders response)
      reference = fromMaybe now (parseHttpDate =<< headerText "Date")
      retryAfter = retryAfterSecondsAt reference =<< headerText "Retry-After"
  onEvent (Left (httpError (Status.statusCode st) retryAfter bodyText))
```

Import `getCurrentTime` from `Data.Time.Clock` and `fromMaybe` from `Data.Maybe`. The
`Sse.hs` request builders are EP-2's region; this branch is not, but while in the file
replace the comment `-- EP-8 wires Options.timeoutMs through this local transport.`
(`OpenAI/Sse.hs:136`, `Claude/Sse.hs:139`) with `-- The whole-call bound is
Transport.runWithTimeout; http-client's own response timeout is deliberately none.`
That is a comment-only edit and rebases trivially either way.

Third, both `runWithTimeout` (`Claude/Transport.hs:88-94`, `OpenAI/Transport.hs:62-68`):

```haskell
-- | Run the transport action under 'Options.timeoutMs'. 'Nothing' is no
-- bound. A non-positive bound is a caller error and is refused as
-- 'InvalidRequest' without running the action, so no connection is
-- opened and no retry loop is fed a retryable classification for a
-- configuration mistake.
runWithTimeout :: Maybe Int -> IO () -> IO (Maybe BaikaiError)
runWithTimeout Nothing action = action >> pure Nothing
runWithTimeout (Just ms) action
  | ms <= 0 =
      pure . Just . invalidRequest $
        "Options.timeoutMs must be positive, got " <> Text.pack (show ms) <> "; use Nothing for no bound"
  | ms > maxBound `div` 1000 = action >> pure Nothing
  | otherwise = do
      result <- Timeout.timeout (ms * 1000) action
      pure $ case result of
        Just () -> Nothing
        Nothing -> Just (timeoutError ms)
```

Import `invalidRequest` from `Baikai.Error`. The `maxBound` guard exists because
`ms * 1000` would otherwise wrap negative and `System.Timeout.timeout` would treat a
negative interval as "no bound" silently; making that explicit costs one line. Update
the `timeoutMs` paragraph of the `Options` Haddock (`baikai/src/Baikai/Options.hs:18-21`)
to add: "`Just n` with `n <= 0` is refused as `InvalidRequest`; `Nothing` is the only
spelling of no bound."

Tests. In `baikai/test/ErrorSpec.hs`, delete the case "HTTP-date Retry-After is ignored"
(line 44–45) and add to `httpHelperTests`: "HTTP-date Retry-After yields seconds from
the reference instant" (`retryAfterSecondsAt (read "2026-10-21 07:27:30 UTC") "Wed, 21
Oct 2026 07:28:00 GMT" @?= Just 30`); "HTTP-date Retry-After in the past yields zero";
"integer Retry-After ignores the reference instant" (`… "12" @?= Just 12`); "malformed
Retry-After yields Nothing"; "parseHttpDate accepts IMF-fixdate, RFC 850 and asctime"
(all three spellings of `Sun, 06 Nov 1994 08:49:37 GMT` parse to the same `UTCTime`);
"parseRetryAfterSeconds is integer-only" (`parseRetryAfterSeconds "Wed, 21 Oct 2026
07:28:00 GMT" @?= Nothing`, kept because that contract is now deliberate); "429 without
Retry-After -> RateLimited with no hint" (re-homed from the Claude servant tests). In
`classifyTests` add "413 -> ContextOverflow"; in `bodyClassifyTests` add "413 + ordinary
body -> ContextOverflow" and "413 + request_too_large body -> ContextOverflow". In
`baikai/test/TransportClassifySpec.hs` add the deferred `StatusCodeException` case: a
`Response ()` with status 429, `Retry-After: Wed, 21 Oct 2026 07:28:00 GMT` and `Date:
Wed, 21 Oct 2026 07:27:15 GMT` → `RateLimited`, `retryAfterSeconds = Just 45`.

In both `SseSpec.hs` add "HTTP-date Retry-After is converted using the response Date
header": a 429 with those two headers → `retryAfterSeconds = Just 45`; and "HTTP-date
Retry-After without a Date header uses the current time": a date in 2099 →
`retryAfterSeconds` is `Just n` with `n > 0`.

In both `TransportSpec.hs` add "runWithTimeout rejects a non-positive bound without
running the action": an `IORef Bool` set by the action; `runWithTimeout (Just 0)` and
`runWithTimeout (Just (-5))` each return `Just be` with `category = InvalidRequest`,
`isRetryable = False`, and the ref is still `False`.

In both `MidStreamSpec.hs` add the socket tests. The helper:

```haskell
-- | A TCP listener on 127.0.0.1 that accepts one connection and holds
-- it open without ever reading or writing: an HTTP server that has
-- stalled. Port 0 asks the kernel for a free port, so the test never
-- collides with anything else on the machine.
withStalledServer :: (Int -> IO a) -> IO (a, Int)
withStalledServer body = bracket open Socket.close $ \listener -> do
  port <- Socket.socketPort listener
  accepted <- newIORef (0 :: Int)
  release <- newEmptyMVar
  acceptor <- forkIO . handle (\(_ :: SomeException) -> pure ()) $ do
    (conn, _) <- Socket.accept listener
    modifyIORef' accepted (+ 1)
    takeMVar release
    Socket.close conn
  result <- body (fromIntegral port) `finally` (putMVar release () >> killThread acceptor)
  count <- readIORef accepted
  pure (result, count)
  where
    open = do
      s <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
      Socket.setSocketOption s Socket.ReuseAddr 1
      Socket.bind s (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.listen s 1
      pure s
```

Add `network` to both test-suite `build-depends`. The model for these tests is
`emptyModel & #modelId .~ "stall-test" & #provider .~ "test" & #api .~
OpenAIChatCompletions & #baseUrl .~ Text.pack ("http://127.0.0.1:" <> show port)` (Claude:
`AnthropicMessages`), options `emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")
& #timeoutMs .~ Just 200`. Cases:

- "a stalled socket is cut off by timeoutMs as TransientError": drain
  `openaiChatStream model ctx opts` (the *live* driver) under `System.Timeout.timeout
  10_000_000`; `Nothing` is a failure ("timeoutMs did not fire"); otherwise expect
  `[EventStart _, EventError TerminalPayload {errorInfo = Just be}]` with
  `category = TransientError`, `isRetryable`, and `"timeoutMs=200"` in the message.
  **Reconcile with EP-4**: on Claude the `EventStart` is present only after EP-4
  pre-seeds it (REV-2 A.4); before EP-4 assert on the terminal alone.
- "timeoutMs of zero is rejected as InvalidRequest before any connection": same
  listener, `timeoutMs = Just 0`; expect the terminal `InvalidRequest`, not retryable,
  and the returned accept count `0`.
- "a negative timeoutMs is rejected as InvalidRequest": `Just (-1)`, same assertions.

Acceptance: all three suites pass; the stalled-socket test finishes in well under a
second; before this milestone the zero-timeout test observes `TransientError`.


### Milestone 4 — unreachable-shape tests retired; classifier module docs match the transport

Scope: the remaining test deletions and rewrites, documentation, changelog, the ADR, and
the full keyless gate. Verify with the gate command in Validation and Acceptance.

Tests. In both `ErrorClassSpec.hs` delete `httpStatusTests`, `mkResp`, `sdkTextTests`
and the `Servant.Client`, `Data.Sequence`, `Network.HTTP.Types.Version`,
`Data.ByteString.Lazy` imports they needed; rename "non-ClientError exception ->
OtherError, text preserved" to "non-transport exception -> OtherError, text preserved";
add "a body-read reset is transient through classifyException" (the `ResourceVanished`
`IOError` through the provider's `classifyException`, proving the delegation). Run
`grep -rn "Servant" baikai-claude/test baikai-openai/test`; if nothing imports it, drop
`servant-client` from both test-suite `build-depends`. In
`baikai-openai/test/ReasoningSpec.hs` replace "whole message shape yields reasoning then
text" with "a data frame carrying a whole message object yields reasoning then text":
encode the same object, wrap it as `"data: " <> encoded <> "\n\n"` followed by `data:
[DONE]\n\n`, push it through `sseFromResponse` (import `mkResponse` by copying it, as
`SseSpec.hs` does) and `parseFrame`, and assert the same `terminalContent`; add "a bare
JSON body with no data prefix is not decoded" asserting `sseFromResponse` on the raw
encoded object yields no events at all. That second test documents the transport
limitation honestly rather than pretending `parseMessageObject` is reachable for it;
EP-4 owns the transport's frame handling and may change the assertion.

Documentation, all of which must agree after this milestone. Both
`Internal/ErrorClass.hs` module Haddocks were rewritten in M1/M2; re-read them.
`docs/capabilities/categorised-error-model.md`: in the `evidence` list replace the two
provider `proves` sentences ("maps servant-client ClientErrors …") with "The Anthropic
provider delegates transport failures to the shared classifier and maps mid-stream
Anthropic error events onto the shared categories" and "The OpenAI-compatible provider
does the same and classifies in-band error frames on 2xx streams by status, code, type,
then message"; add an evidence entry for `baikai/test/TransportClassifySpec.hs` ("A
reset, a mid-chunk close, a short body and a post-handshake TLS failure are
TransientError; a failed handshake and a programming error are not") and one for each
`MidStreamSpec.hs`; in Limits replace the HTTP-date bullet with "An HTTP-date
`Retry-After` is converted to seconds against the response's `Date` header (or the
local clock when absent); a date already in the past yields `0`"; add "A failure while
the body is streaming is `TransientError` whether it surfaces as a reset, a mid-chunk
close, or a TLS termination; a TLS handshake that fails is not retryable" and "HTTP 413
is `ContextOverflow` from the status alone"; bump `generated.at`. Then run the bundle
check the release skill runs (`okf validate docs/capabilities --profile
docs/capabilities/profile.dhall --profile-enforce --log-enforce` and `okf graph
docs/capabilities`) and add a dated entry to `docs/capabilities/log.md` describing the
edit. `docs/capabilities/anthropic-messages-backend.md:48-51`: replace the servant
sentence with "It is built on the `MercuryTechnologies/claude` SDK for the wire types
and a baikai-owned `http-client` SSE transport; a non-2xx is classified from status,
`Retry-After` and body, and a transport failure mid-stream through
`Baikai.Provider.Transport.Classify`". `docs/user/streaming.md`, the "Recover partial
output on failure" paragraph (lines 113–116): append one sentence, "The terminal's
`errorInfo` classifies such a drop as `TransientError`, so `isRetryable` is true."
`docs/user/getting-started.md` and `docs/user/models-and-providers.md` make no claim
this plan changes; leave them to EP-11.

Changelog. Under `## [Unreleased]` in `CHANGELOG.md` (the root file; `baikai/CHANGELOG.md`
is a symlink to it), following the existing per-package `### Added` / `### Changed` /
`### Fixed` / `### Removed` layout: Added — `Baikai.Provider.Transport.Classify`,
`parseHttpDate`, `retryAfterSecondsAt`, `classifyErrorFrame`, `parseFrame`; Changed —
HTTP 413 is `ContextOverflow`; an HTTP-date `Retry-After` is converted; `timeoutMs <= 0`
is `InvalidRequest`; the `baikai` library now depends directly on `http-client`,
`http-types` and `tls`; Fixed — mid-stream resets, chunked EOFs and TLS terminations are
`TransientError` on both providers; in-band error frames on 2xx streams are classified;
Removed — `responseToError` and `classifyErrorText` from both `.Internal.ErrorClass`
modules (documented as outside the PVP-stable surface, so not a major bump; EP-10 owns
versions). Each entry names the package it belongs to.

ADR. Create `docs/adr/0006-core-owns-transport-failure-classification.md` in the
convention of `0005-…` (frontmatter `title`, `status: accepted`, `date`; sections
Context, Decision, Consequences). Context: two provider copies of the classification
table drifted identically wrong because `http-client` delivers the same failure in
three shapes depending on phase. Decision: transport-failure classification is owned by
core in `Baikai.Provider.Transport.Classify` and keyed on the phase in which the failure
occurred, with the rule stated in one paragraph; every HTTP provider, including
third-party `Custom` ones, is expected to delegate to it; this supersedes the
2026-07-01 rationale in `docs/plans/39-…` that core stays free of `http-client`.
Consequences: core depends directly on `http-client`, `http-types` and `tls` (no new
transitive package); the provider `ErrorClass` modules shrink to the vendor-specific
JSON classifiers. Add the row to the table in `docs/adr/README.md`.

Cross-plan bookkeeping: tick the four EP-5 boxes in the MasterPlan's Progress section;
record the `worker` one-line edit in EP-4's Decision Log; record the `content_filter`
question in EP-10's Decision Log (`docs/plans/67-freeze-the-public-surface.md`).

Acceptance: the keyless gate below is green; `git grep -n "responseToError\|classifyErrorText\|servant-client ClientError"`
returns hits only under `docs/plans/` and `docs/reviews/`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`
inside the Nix dev shell.

Before writing code, confirm EP-4's state and keep the dependency sources open:

```bash
git log --oneline -20
sed -n '1,120p' docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md
mori registry show snoyberg/http-client --full
sed -n '133,252p' /Users/shinzui/Keikaku/hub/haskell/http-client-project/http-client/http-client/Network/HTTP/Client/Types.hs
sed -n '230,245p' /Users/shinzui/Keikaku/hub/haskell/http-client-project/http-client/http-client/Network/HTTP/Client/Core.hs
tlsdir=$(mktemp -d) && tar -xzf ~/.cabal/packages/hackage.haskell.org/tls/2.2.2/tls-2.2.2.tar.gz -C "$tlsdir"
sed -n '18,66p' "$tlsdir/tls-2.2.2/Network/TLS/Error.hs"
```

(`tls` is not in the Mori corpus, hence the tarball; never look under `/nix/store`.)

Per-milestone build and test loop:

```bash
cabal build baikai baikai-claude baikai-openai --enable-tests
cabal test baikai baikai-claude baikai-openai
```

Expected tail of a passing run (counts will grow as cases are added; at `c3753c5` the
three suites report 115-plus, 29-plus and 33-plus tests respectively):

```text
Test suite baikai-test: PASS
Test suite baikai-claude-test: PASS
Test suite baikai-openai-test: PASS
```

To watch a new case fail before its fix, run it by name, for example:

```bash
cabal test baikai-openai --test-options='-p "/chunked-encoding EOF/"'
```

Expected before Milestone 1:

```text
  a chunked-encoding EOF classifies as TransientError: FAIL
    expected: TransientError
     but got: OtherError
```

Formatting is a release gate, so run it before every commit and confirm the tree is
clean:

```bash
nix fmt
git diff --exit-code
```

Commit per milestone with Conventional Commits and the three trailers, for example:

```text
fix(error): classify mid-stream transport failures as transient

Add Baikai.Provider.Transport.Classify, one classifier for http-client,
TLS and socket failures keyed on the phase in which they occurred, and
delegate both providers' classifyException to it. A reset, a mid-chunk
close, a short body and a post-handshake TLS failure are TransientError;
a failed handshake and a programming error are not.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/62-classify-mid-stream-failures-and-in-band-error-frames.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(openai): classify in-band error frames on 2xx streams

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/62-classify-mid-stream-failures-and-in-band-error-frames.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

Milestone 3 and 4 commits follow the same form, with subjects such as `fix(error): 413
is ContextOverflow, HTTP-date Retry-After converts, timeoutMs<=0 refused` and
`test(providers): retire unreachable classifier shapes; docs and ADR 0006`, and always
the same three trailers.

Update this plan's Progress section (and Surprises & Discoveries / Decision Log as
warranted) at every stopping point, and commit the plan with the code it describes.


## Validation and Acceptance

Compilation is not acceptance. The behaviours to demonstrate, each backed by a named
test and the shape it feeds:

1. Mid-body resets are retryable. `MidStreamSpec` "a connection reset after two chunks
   ends with a retryable EventError carrying the partial text" (both packages) feeds a
   body reader that returns two frames and then raises an `IOError` with
   `ioe_type = ResourceVanished` and `errno = ECONNRESET`; observe one `EventError`
   with `category = TransientError`, `isRetryable = True`, and the partial text.
2. Framing failures classify the same way. `MidStreamSpec` "a chunked-encoding EOF
   classifies as TransientError" feeds `HttpExceptionRequest _ InvalidChunkHeaders`;
   "a TLS termination mid-body classifies as TransientError" feeds a raw
   `PostHandshake Error_EOF`. `TransportClassifySpec` pins every constructor in the
   Decision Log table, including "a failed TLS handshake is not retryable" and "a
   userError is not a transport failure".
3. In-band error frames terminate with their own classification. `MidStreamSpec`
   (OpenAI) "an in-band error frame on a 2xx stream terminates with the frame's
   classification" replays a `200` body of one content chunk, the OpenRouter-shaped
   `502` frame, then `[DONE]`; observe `EventError` with `TransientError`,
   `httpStatus = Just 502`, message `Provider returned error`. "an in-band
   insufficient_quota frame is AuthError and not retryable" replays the OpenAI-shaped
   frame. `ErrorClassSpec.errorFrameTests` and `SseSpec` "an in-band error frame on a
   2xx stream reaches the assembler as a classified Left" pin the parts.
4. 413 is overflow. `ErrorSpec` "413 -> ContextOverflow", "413 + ordinary body ->
   ContextOverflow", "413 + request_too_large body -> ContextOverflow".
5. HTTP-date `Retry-After` is a hint. `ErrorSpec` "HTTP-date Retry-After yields seconds
   from the reference instant" (30 seconds), "HTTP-date Retry-After in the past yields
   zero", "parseHttpDate accepts IMF-fixdate, RFC 850 and asctime"; both `SseSpec`
   "HTTP-date Retry-After is converted using the response Date header" (a 429 with
   `Retry-After: Wed, 21 Oct 2026 07:28:00 GMT` and `Date: Wed, 21 Oct 2026 07:27:15
   GMT` yields `retryAfterSeconds = Just 45`).
6. A stalled socket is bounded. `MidStreamSpec` "a stalled socket is cut off by
   timeoutMs as TransientError" (both packages) opens a real listener that never
   answers and drains the live provider stream with `timeoutMs = Just 200`; observe
   `[EventStart, EventError]` with `TransientError`, `isRetryable = True`, message
   containing `timeoutMs=200`, within the ten-second guard.
7. A non-positive bound is refused before the wire. `MidStreamSpec` "timeoutMs of zero
   is rejected as InvalidRequest before any connection" and "a negative timeoutMs is
   rejected as InvalidRequest" observe `InvalidRequest`, `isRetryable = False`, and an
   accept count of `0`; `TransportSpec` "runWithTimeout rejects a non-positive bound
   without running the action" proves the action never ran.
8. Unreachable shapes are gone. `ErrorClassSpec` in both packages no longer contains
   `responseToError` or `"HTTP error "`; `ReasoningSpec` "a data frame carrying a whole
   message object yields reasoning then text" pushes its object through
   `sseFromResponse` and `parseFrame`.

The keyless gate from `agents/skills/release/SKILL.md`, quoted exactly; it strips the
directories that hold real keys and unsets every provider variable so the 24 live smoke
cases skip and every offline suite runs:

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

Expected: every suite prints `PASS` and none reports zero tests run (the skill's rule:
"Every suite must pass, not merely skip"). Then the documentation gates:

```bash
cabal build all
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
```

Optional live check (requires a key; not a gate): point an OpenAI-compatible `Model` at
OpenRouter with a deliberately unavailable upstream model and observe a terminal
`EventError` whose `errorInfo` carries the upstream status and message rather than
`openai stream ended without finish_reason`.


## Idempotence and Recovery

Every step is an ordinary source edit under git; re-applying an edit that is already
there is a no-op, and the recovery path for any mis-step is `git checkout -- <file>` or
reverting the milestone commit. No migrations, generated files or destructive operations
are involved. Commit at each milestone boundary so `git revert` granularity matches
verification granularity. Two hazards deserve care. The dependency edit in
`baikai/baikai.cabal` changes the build plan; if `cabal build` reports an unsatisfiable
`tls` bound, widen it to what `cabal build all --dry-run` resolves rather than pinning
to a version the plan does not contain. The socket tests bind an ephemeral port on
`127.0.0.1`; they hold no fixed port, release the listener in `bracket`, and kill the
acceptor thread in `finally`, so an interrupted run leaves nothing behind. If the
stalled-socket test ever hangs, the ten-second guard turns it into a failure rather than
a stuck suite; investigate `runWithTimeout` before touching the guard. If EP-4 has not
landed when this plan starts, the Claude assertions that expect `EventStart` first
will fail for EP-4's reason, not this plan's; assert on the terminal alone and note it
in Progress.


## Interfaces and Dependencies

Library dependencies: the `baikai` library gains direct `build-depends` on
`http-client ^>=0.7`, `http-types ^>=0.12` and `tls` (bound per Milestone 1); all three
are already in its transitive closure through the `openai` SDK, so no consumer's plan
changes. The `baikai` test suite gains the same three. Both provider test suites gain
`network` and `tls`, and lose `servant-client` if nothing imports it after Milestone 4.
Neither provider library's dependencies change.

Signatures that must exist at the end of each milestone (full module paths):

Milestone 1:

```haskell
Baikai.Provider.Transport.Classify.classifyTransportException :: SomeException -> Maybe BaikaiError
Baikai.Provider.Transport.Classify.classifyHttpException :: Network.HTTP.Client.HttpException -> BaikaiError
Baikai.Provider.Transport.Classify.classifyHttpExceptionContent :: Network.HTTP.Client.HttpExceptionContent -> BaikaiError
Baikai.Provider.Transport.Classify.classifyIOException :: GHC.IO.Exception.IOException -> Maybe BaikaiError
Baikai.Provider.Transport.Classify.classifyTlsException :: Network.TLS.TLSException -> BaikaiError
-- unchanged in type, now delegating:
Baikai.Provider.Claude.Internal.ErrorClass.classifyException :: SomeException -> BaikaiError
Baikai.Provider.OpenAI.Internal.ErrorClass.classifyException :: SomeException -> BaikaiError
-- removed: responseToError (both), fromClientError (both, was private)
```

Milestone 2:

```haskell
Baikai.Provider.OpenAI.Internal.ErrorClass.classifyErrorFrame :: Data.Aeson.Value -> Maybe BaikaiError
Baikai.Provider.OpenAI.Api.parseFrame :: Data.Aeson.Value -> Either String (Either BaikaiError RawChunk)
-- unchanged: Baikai.Provider.OpenAI.Api.parseChunk :: Value -> Either String RawChunk
-- removed: classifyErrorText (both packages)
```

Milestone 3:

```haskell
Baikai.Error.parseHttpDate :: Text -> Maybe Data.Time.UTCTime
Baikai.Error.retryAfterSecondsAt :: Data.Time.UTCTime -> Text -> Maybe Int
-- unchanged in type, 413 added: Baikai.Error.classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory
-- unchanged in type, non-positive refused: Baikai.Provider.Claude.Transport.runWithTimeout :: Maybe Int -> IO () -> IO (Maybe BaikaiError)
-- unchanged in type, non-positive refused: Baikai.Provider.OpenAI.Transport.runWithTimeout :: Maybe Int -> IO () -> IO (Maybe BaikaiError)
```

Milestone 4 adds no signatures. Downstream: EP-4 keeps the `parseFrame` call when it
reshapes `worker`; EP-8 may read `httpStatus` from an in-band frame's error when it
records evidence for a failed call; EP-10 decides whether
`Baikai.Provider.Transport.Classify` moves behind `.Internal` (it is written as a plain
exposed module here, and its Haddock says it is intended for third-party providers, so
the recommendation to EP-10 is to keep it public) and answers the `content_filter`
category question; EP-11 describes the new behaviour in the user guides.
