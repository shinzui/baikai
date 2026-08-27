---
type: Review
title: Correctness and API review of every package at 0.5
description: REV-1's findings are fixed and pinned bar the thinking-style table, but the transports, evidence surface, and baikai-agent added since carry a host parse that can misdirect an API key, error streams that break the event protocol, and a shipped binary whose timeout cannot fire, so changes are requested before the freeze.
generated:
  by: claude-code/fable-5
  at: "2026-08-27T02:55:00Z"
reviewId: REV-2
subject: mori://shinzui/baikai
subjectKind: project
reviewedSha: c3753c512d86208eac819398cd061012b4b4a97b
coverage: full
previousReview: REV-1
reviewedAt: "2026-08-27T02:55:00Z"
reviewerKind: model
reviewer: claude-code/fable-5
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - correctness
  - security
  - design
  - test-coverage
  - documentation
  - operability
context: >-
  Ten parallel readers at the reviewed commit: four re-verified every REV-1
  finding and recommendation against the current source and tests rather
  than the plans' completion claims; six read the current code fresh by area
  — core, baikai-claude, baikai-openai, trace/evidence/otel/effectful,
  agent/kit/CLI internals, and the public surface with its documentation —
  with dependency sources (the MercuryTechnologies SDKs, http-client,
  streamly, process, settei, hs-opentelemetry) resolved through mori.
  Single-source findings above minor were then re-verified by the
  orchestrating session against the source and against the installed
  claude 2.1.247 and codex 0.149.1 help output. Build and all eight offline
  suites were green at the reviewed commit (931 tests) under the release
  skill's keyless gate; the 24 live smoke cases were skipped by policy, so
  wire behaviour against real hosts — notably Anthropic's thinking and
  sampling parameters — rests on the current Anthropic API reference rather
  than on a live call.
---

# Correctness and API review of every package at 0.5

Scope: all eight packages at `c3753c5` — baikai, baikai-claude and
baikai-openai 0.5.0.0, baikai-trace-otel and baikai-effectful 0.3.0.3,
baikai-kit 0.1.0.4, baikai-agent 0.1.0.0, and the `baikai-smoke` suite — read
in full by area, plus an item-by-item re-verification of
[REV-1](correctness-and-api-review.md). Build and every offline suite pass;
live smoke was not run.

Verdict: REV-1's verdict is answered on its own terms. The three subsystems it
called broken — error classification, extended thinking, the compat-quirk
system — now work as documented and are pinned by tests that feed the shapes
the runtime produces; the API recommendations landed; the architecture is
still sound. What this review found is concentrated in code added or reshaped
since July: the baikai-owned SSE transports, which fixed July's classification
problem and introduced a host-parse defect and a missing-`EventStart` path of
their own; the evidence and tracing surface, never reviewed before, whose
records can misstate what the caller asked for; and `baikai-agent`, never
reviewed before, whose shipped binary lacks the `-threaded` RTS its timeout
depends on and whose policy ceiling gates less than its documentation claims.
Fix A.1, B.1–B.2, C.1, D.1–D.3 and F.1–F.4 before relying on the library for
unattended work. The public surface is close to freezable once Theme G's
constructor exports and deprecated shims are settled and Theme H's
documentation is brought back to the code.

---

## Disposition of REV-1

Every finding and recommendation in REV-1 was re-read against the source and
tests at `c3753c5`, not against the plans' completion claims. The remediation
landed in commits `b96304c..9d89233` (2026-07-03) under masterplan 7 and exec
plans 34–43; nothing in the 2026-07-20 reasoning-effort work or the 2026-08-05
evidence and `baikai-agent` work regressed it. Line references below are as of
`c3753c5`.

| Theme | Items | Fixed | Superseded / declined | Partial | Still open |
|---|---|---|---|---|---|
| 1 Error classification | 7 | 7 | — | — | 1.6 invariant is normalised, not enforced by type |
| 2 Extended thinking | 5 | 4 | — | 1 (2.2) | `claude-sonnet-5` routed to `budget_tokens` |
| 3 Usage / cost | 1 | 1 | — | — | — |
| 4 Compat quirks | 2 | 2 | — | — | — |
| 5 Options ignored | 3 | 3 | — | — | no stalled-socket test for `timeoutMs` |
| 6 CLI providers | 3 | 3 | — | — | — |
| 7 Trace workers | 3 | 2 | 7.2 superseded by 128-bit `newCallId` | — | abort terminal is GC-driven and undocumented |
| 8 baikai-kit | 7 | 7 | — | — | symlink read-through untested |
| 9 Tool-schema fidelity | 1 | 1 (by patching the encoded body) | — | — | `emptyTool` sends `input_schema: null` |
| 10 Smaller core items | 9 | 9 | — | — | embeddings bypass the per-host key table |
| API recommendations | 14 | 10 done | R14 partly declined, R12 altered | R5, R8, R10 | deprecated shims two majors past their stated removal |

### Theme 1 — error classification (all fixed)

The SDKs' lossy streaming paths are gone. Both providers drive a baikai-owned
SSE transport (`Baikai.Provider.Claude.Sse`, `Baikai.Provider.OpenAI.Sse`) over
raw `http-client`; a non-2xx becomes `httpError status retryAfter body`
(`baikai/src/Baikai/Error.hs:178-190`) classified by
`classifyHttpStatusWithBody`, and the worker turns it into one in-band
`EventError`. The `SseSpec` and `EvidenceSpec` replays feed a synthetic
`HTTP.Response BodyReader` through the same `sseFromResponse`, so — unlike in
July — the tests exercise the shape the runtime produces.

- 1.1, 1.2 — `Claude/Sse.hs:159-166`, `OpenAI/Sse.hs:157-164`; tests "non-2xx
  response preserves Retry-After and status" in both `SseSpec`s (429 →
  `RateLimited`, `retryAfterSeconds` populated, no phrase-sniffing).
- 1.3 — `HttpException` classified at `Claude/Internal/ErrorClass.hs:86-107`
  and the OpenAI twin; "http-client connection failures are transient".
- 1.4 — `prepareCall` runs under `trySync` inside `concatEffect`; a missing key
  is exactly `[EventStart, EventError]` (`immediateError`, `Claude/Api.hs:837-864`,
  `OpenAI/Api.hs:1277-1304`); "missing ANTHROPIC_API_KEY yields one terminal
  EventError".
- 1.5 — `Stream.hs:499-501` lifts an error-shaped `Response` to `EventError`;
  `ErrorInfoSpec` "liftCompleteToStream preserves error-shaped responses as
  EventError".
- 1.6 — in-band everywhere: `responseError`/`errorResponse`
  (`Response.hs:116-142`), unregistered dispatch returns `errorResponse`
  (`Registry.hs:172-181`) or `noProviderEvents` (`Stream.hs:623-651`), both CLI
  providers return `errorResponse`. `errorTerminal` demands a `BaikaiError`;
  reassembly synthesises `errorInfo` for an `ErrorReason` terminal without one.
  Residual: `Response(..)` and `TerminalPayload(..)` constructors are exported
  and `doneTerminal` accepts `ErrorReason`, so the invariant is normalised on
  read rather than unrepresentable — a pinned decision ("reassembly normalizes
  ErrorReason terminals without errorInfo").
- 1.7 — `content_filter` → `EventError` (`OpenAI/Api.hs:1306-1313`); an unknown
  finish reason is `Stop` with a diagnostic `errorMessage`, pinned by "unknown
  finish_reason is a successful diagnostic". Its category is the closed
  `OtherError`, so a consumer cannot tell a filter from any other failure
  without text matching.

### Theme 2 — extended thinking (2.2 partial)

- 2.1 — `max_tokens` clamped to the catalog cap and thinking dropped with
  `ThinkingDroppedBudgetExceeded` when the budget cannot fit
  (`Claude/Internal/Request.hs:69-75,122-136`); `ThinkingSpec` proves eight
  models × six levels never exceed the cap.
- 2.2 — **partial.** `AnthropicThinkingStyle` exists and adaptive requests send
  `{"type":"adaptive"}` plus `output_config.effort`
  (`Request.hs:239-272`), but the style comes from a hand-written prefix table
  (`Compat.hs:232-240`: opus-4-6/4-7/4-8 and fable-5 → adaptive, everything else
  → budget). `claude-sonnet-5` (`Models/Generated.hs:227-245`, `reasoning =
  True`, `compat = CompatNone`) is not in the table and is therefore sent
  `budget_tokens`, which the current Anthropic reference rejects with a 400 on
  that generation; `claude-sonnet-4-6` is likewise routed to the deprecated
  form. `ThinkingSpec.anthropicModels` pins every Anthropic catalog entry except
  `sonnet-5`. This is the July 400 reproduced for the newest model. See A.1.
- 2.3 — `ThinkingEndPayload` carries the full `ThinkingContent`; the terminal
  message's content is authoritative; `responseId` rides `StartPayload` and
  `TerminalPayload` and both providers set it ("responseId flows from events to
  Response").
- 2.4 — redacted payloads are kept and replayed verbatim
  (`Claude/Api.hs:665-668,727-754`, `Request.hs:417-427`); unsigned thinking is
  omitted on replay by decision.
- 2.5 — `reasoning_content`/`reasoning` parsed, `requiresThinkingAsText` gates
  the `<think>` scanner (`OpenAI/Api.hs:399-401,976-984`); eight `ReasoningSpec`
  cases plus a live DeepSeek smoke. Residual: reasoning that arrives *after*
  visible text opens a new block without closing the text block — see B.4.

### Theme 3 — usage (fixed)

`inputTokens = prompt_tokens − cached_tokens`, clamped, with `totalTokens`
recomputed (`OpenAI/Api.hs:1092-1106`); the invariant is documented on `Usage`
(`Usage.hs:1-24,41-64`); the Claude mapping already agrees; "computeCost bills
each token class exactly once". Residual: no test asserts the Claude mapping
against the invariant with non-zero cache counts.

### Theme 4 — compat quirks (fixed)

Every retained flag has a consumer on the wire path — `maxTokensField`
(`OpenAI/Shape.hs:85-94`), `requiresThinkingAsText`, `cacheControlFormat`
(`Shape.hs:219-242`), `supportsUsageInStreaming` (`Shape.hs:74-82`),
`sendSessionAffinityHeaders` (`Claude/Transport.hs:73-107`), plus
`supportsStrictMode`, `supportsCacheControlOnTools`, `thinkingFormat`;
`supportsDeveloperRole` and `supportsEagerToolInputStreaming` were deleted.
Host detection is suffix-bounded at a label boundary (`Compat.hs:306-324`,
"host auto-detection is suffix-bounded"). The hostname extractor has a new
defect of its own — see A.2.

### Theme 5 — options (fixed)

`timeoutMs` is a whole-call wall-clock bound (`Transport.runWithTimeout`) that
surfaces as an in-band `TransientError`; `Model.headers` then `Options.headers`
override provider defaults case-insensitively; `ToolChoiceNone` keeps `tools`
and injects `tool_choice: {"type":"none"}` (`Claude/Shape.hs:57-61`); a zero cap
omits `max_completion_tokens`. Residuals: plan 41 specified a stalling-socket
test for the timeout path and none was written, so the worker → channel →
`EventError` path for a real stall is verified by reading only; the Claude
sibling of 5.3 still sends `max_tokens: 0` for a hand-rolled model (C.2);
`docs/user/tools.md:70,231-237` still describes the pre-fix `ToolChoiceNone`
and says tool-side `cache_control` is not wired (H.3).

### Theme 6 — CLI providers (fixed)

`--` precedes the prompt at all four launch sites, pinned by "argv terminates
options before a dash-leading prompt" in both packages; the codex provider
drains stderr on a forked reader under `withCreateProcess` ("survives a 1MiB
stderr flood without deadlock", both packages); the system prompt reaches
`codex exec` through `wrapSystemPrompt`. The installed binaries (`claude
2.1.247`, `codex-cli 0.149.1`) still accept every rendered flag. IR-4 and IR-5
record the two launcher gaps that remain by design.

### Theme 7 — trace workers (fixed; 7.2 superseded)

Worker bodies run under `try` and always `putMVar` (`Trace.hs:132-141`,
`Cost/Log.hs:205-211`; "a throwing sink cannot hang withTrace"); ids are
128-bit `newCallId` values (70 000 distinct in test); consumer abort pushes a
synthetic `CallFailed` plus an `aborted` evidence record from a `finallyIO`
finaliser rooted by a `StablePtr`. Residual: that finaliser runs from a GC
hook, so the abort terminal is *eventual* — a short-lived process that aborts
and exits never records it — and neither `docs/capabilities/call-tracing.md:50-51`
nor `docs/user/model-call-evidence.md` says so (only plan 34 and the test
comments do). Under `EvidenceRequired` a sink failure now rewrites a successful
terminal into `EventError` by design (`Trace.hs:399-404`).

### Theme 8 — baikai-kit (fixed)

`safeRelativePath`/`safeItemName` (`Kit/Path.hs:12-37`) reject absolute paths,
`..`, backslashes and NUL on install, uninstall and hash input; dirty+outdated,
delisted-with-sidecar, staged writes with rollback, sidecars keyed by kind, a
failing `git pull` exits non-zero on `update`, CRLF frontmatter stripped. All
pinned by named tests. Residuals: the invariant is lexical — a kit repository
that commits a symlink pointing outside the checkout and lists a file under it
gets that file copied into an agent-readable directory (E.4); `kit update`
reinstalls over local edits without consulting dirtiness; a phase-2 rename
failure prints "no changes were made" while earlier renames stand.

### Theme 9 — tool schemas (fixed, different mechanism)

The SDK's typed `InputSchema` cannot carry `$defs`, top-level `enum` or
`additionalProperties`, so `replaceToolSchemas` (`Claude/Shape.hs:47-84`)
overwrites `tools[i].input_schema` in the encoded body with the caller's JSON
verbatim, index-aligned; "tool input_schema is the caller's verbatim JSON
Schema". Residual: `emptyTool.parameters = Null` now reaches the wire as
`"input_schema": null`, where the old path sent `{"type":"object"}`; no test.

### Theme 10 — smaller core items (fixed)

`trySync` rethrows `SomeAsyncException`; every error-only stream begins with
`EventStart` in core and on the `prepareCall` path (the Claude *wire-failure*
path does not — B.1); dangling buffers recover in `contentIndex` order;
`latencyMs` is clamped; `firstEmbedding` is total; `ClientEnv` is cached per
base URL; tool deltas resolve by index, then id; the API key comes from a
per-host table and unknown hosts refuse the fallback; catalog escaping goes
through aeson and the generator rejects identifier collisions. Residuals:
`Baikai.Embedding` still allocates a TLS manager per call and still defaults
to `OPENAI_API_KEY` regardless of `baseUrl` (E.3); the `ClientEnv` cache is
keyed on raw URL text and never evicted.

### API design recommendations

R1 `responseError` and one channel; R2 `runToolLoop` with the recommended
signature; R3 `contextOf`/`addUser`/`addResponse`/`completeText` and an exported
`flattenAssistantText`; R4 `timestamp :: Maybe UTCTime`; R6
`newProviderRegistryFrom`, first-class `*Provider` values, `assertRegistered`;
R7 `streamRequestEach`/`streamRequestList`; R9 `ApiKeyEnvChain`; R11 `topP`,
`stopSequences`, `seed`, penalties; R13 every named drift item — all done and
tested. R12 is done for `.Internal` and the umbrella statement, and altered for
`Baikai.Prelude`, which still re-exports `Control.Lens` but is documented as
outside PVP. R14 was partly declined (lists for caller-side config, `Vector` for
provider-bound sequences — `stopSequences` then breaks that rule).

Three are partial and matter for the freeze:

- R5 — the decided set is selector-only, but `Tool(..)`, `EmbeddingModel(..)`,
  `ModelCallEvidence(..)` (whose Haddock says "construct through
  `baseEvidence`"), `EvidenceRequest(..)`, `OtelSinkOptions(..)`, and every
  `baikai-agent` record still export constructors, and `ApiProvider(..)` has no
  base value at all — adding `describeThinking` in 0.5.0.0 broke every
  third-party provider (G.1).
- R8 — the `empty*`/`zero*` family and a lawful `Monoid Context` exist, but the
  sixteen `_X` aliases the 0.3.0.0 changelog said would "remain for this
  release" are still exported at 0.5.0.0, two majors later, with no removal
  version anywhere; `_TagScanState` is a new un-deprecated `_X` name (G.3).
- R10 — `mkModel` exists and `unModel` is gone, but `emptyModel.api = Custom ""`
  still dispatches to a message that ends in an empty string, and `mkModel`
  appears in no user guide.

Two documentation gaps cut across the done items: `README.md:131-134`,
`docs/user/cli-providers.md:113-162` and `models-and-providers.md:232` still
teach the deprecated `registerWith*` ladder as the registration path, and
`responseError`, `streamRequestEach`, `ApiKeyEnvChain`, `mkModel` and the
sampling options appear in no guide and (except `mkModel`) in no changelog
entry (H.2).

## New findings

Line references are as of `c3753c5`. Severity follows REV-1's scale; a finding
marked *pinned* is asserted by a named test and is therefore a decision to
revisit rather than an accident.

### Theme A — Transport and error classification (fix first)

The July fix moved both providers onto a baikai-owned SSE transport, which is
the right seam; the gaps left are all in that seam.

1. **[major, security]** `baikai/src/Baikai/Compat.hs:311` — `urlHost` strips
   userinfo with `last (Text.splitOn "@" …)` over the whole URL remainder, so
   the host is taken from after the *last* `@` anywhere, path and query
   included. `Model{baseUrl = "https://proxy.example.com/v1?u=@api.openai.com"}`
   with no explicit `apiKey` resolves `api.openai.com` in
   `defaultApiKeyEnvForBaseUrl` (`Auth.hs:56-72`) and in
   `autoDetectOpenAICompletions` (`Compat.hs:246-282`), so both providers'
   `resolveKey` (`OpenAI/Transport.hs:53-57`, `Claude/Transport.hs:79-83`) read
   `OPENAI_API_KEY` and send it as `Authorization: Bearer` to
   `proxy.example.com`, under the OpenAI compat record. The benign form,
   `https://api.openai.com/v1/@x`, yields host `x` and a spurious
   `AuthError`. `Evidence/Build.hs:227-235` (`dropUserInfo`) already implements
   the correct rule — last `@` before the first `/` — and documents why; the
   two parsers disagree. Precondition: caller-controlled `baseUrl` (a `Model`
   decoded through its derived `FromJSON`, or the proxy override
   `docs/user/models-and-providers.md:37-42` recommends). Tests
   `baikai/test/Main.hs:191-223` cover `user@host` only. Found independently by
   three readers.
2. **[major]** `baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs:92-105`
   and `baikai-openai/…/OpenAI/Internal/ErrorClass.hs:83-98` — mid-body
   transport failures are non-retryable. `http-client` wraps only its own
   `HttpExceptionContentWrapper` around the body reader (`Core.hs:240-244`), so
   a TCP reset or TLS termination during `brRead` reaches the worker as a raw
   `IOException`, falls to `providerError (displayException ex)` and classifies
   `OtherError`; a server FIN mid-chunk throws `InvalidChunkHeaders`, a TLS
   fault `InternalException`, and `ResponseBodyTooShort` — all land in the
   `other ->` arm. Only `ConnectionFailure`/`ConnectionTimeout`/`ResponseTimeout`/
   `ConnectionClosed`/`NoResponseDataReceived`/`IncompleteHeaders`, which
   http-client raises at connect time, become `TransientError`. The same reset
   is therefore retryable or not depending on where in the chunk framing it
   lands. Both `ErrorClassSpec`s feed only `ConnectionFailure` and
   `ResponseTimeout`.
3. **[major]** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:343-385` +
   `Sse.hs:176-178` — an in-band `{"error":{…}}` data frame on a 2xx stream
   (OpenRouter upstream failures, DeepSeek and Together mid-stream errors) is
   parsed as a chunk with no `choices`, dropped, and the call ends at EOF as
   `OtherError "openai stream ended without finish_reason"`,
   `isRetryable = False`, message discarded. `parseChunk` never looks up
   `error`; `classifyErrorText` (`Internal/ErrorClass.hs:112-129`) exists for
   exactly this and has no production caller — `ErrorClassSpec.streamedErrorTests`
   feeds it directly, a shape the transport never produces.
4. **[major]** `baikai-claude/src/Baikai/Provider/Claude/Api.hs:201-210,590-592,326-335`
   — every failure before `message_start` (an HTTP 4xx/5xx from the worker, a
   timeout, an in-band `error` event, EOF) emits a lone `EventError` with no
   `EventStart`, violating the protocol `Stream/Event.hs:5-11` states and
   `docs/user/streaming.md:27-33` promises ("exactly once, first"), and leaving
   `reassembleResponse` with no skeleton and `latencyMs = 0`. `Event.hs:14-17`
   still calls this "a temporary gap until the EP-7 Claude streaming rewrite
   pre-seeds its skeleton"; plan 38 delegated it to plan 40, which closed
   without doing it. The OpenAI provider pre-seeds (`OpenAI/Api.hs:223`).
   `assertErrorContract` is applied only to `prepareCall` failures and the 429
   replay in `EvidenceSpec` inspects evidence only, so neither shape is pinned.
   A consumer whose fold matches `EventStart` at the head of the list crashes
   on an Anthropic 401.
5. **[minor, security]** `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs:128-138`
   (and the Claude twin) — `HTTP.defaultRequest` keeps `redirectCount = 10` and
   `shouldStripHeaderOnRedirect = const False`, so a 3xx from the configured
   host forwards the bearer token (and, for 301/302, converts the POST to a GET)
   to whatever `Location` names, cross-host included; the response then fails
   as "ended without finish_reason". A chat-completions POST has no legitimate
   redirect: set `redirectCount = 0`.
6. **[minor]** `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs:133,214-218` and
   `baikai-claude/…/Claude/Sse.hs:136` — the transport appends a hard-coded
   `/v1/chat/completions` (`/v1/messages`) to `baseUrlPath` with no dedupe, so
   the base URL every OpenAI SDK teaches (`https://api.deepseek.com/v1`) requests
   `/v1/v1/chat/completions` → 404 → `InvalidRequest`; a query string
   (Azure's `?api-version=`) is rejected by `parseBaseUrl` as `OtherError
   "Invalid base URL"` in `prepareCall`. The catalog is consistent (every entry
   is suffix-less; OpenRouter's `/api` composes correctly) but the convention is
   stated nowhere, and `baikai/test/Main.hs:214` and
   `baikai-openai/test/Main.hs:542,547` use `/v1`-suffixed URLs as if they were
   legitimate. No test asserts the composed path.
7. **[minor]** `baikai/src/Baikai/Error.hs:212-216` — `classifyHttpStatusWithBody`
   consults `bodyIndicatesOverflow` only for 400/422, so an HTTP 413 whose body
   carries `request_too_large` (a marker the list itself contains, `:233`)
   classifies `OtherError`, not `ContextOverflow`. `ErrorSpec` has no 413 case.
8. **[minor]** `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs:173-178,187` —
   `[DONE]` is compared exactly after stripping leading spaces only; `data:
   [DONE] ` with a trailing space, or an empty `data:` heartbeat, becomes a
   `decodeError` terminal *after* a completed response.
9. **[design]** `baikai/src/Baikai/Error.hs:171-174` — an HTTP-date
   `Retry-After` yields `Nothing`; *pinned* by `ErrorSpec` "HTTP-date
   Retry-After is ignored". CDN-fronted hosts commonly send dates on 429.
10. **[design]** `baikai-claude/src/Baikai/Provider/Claude/Transport.hs:90-91`
    — `timeoutMs = Just 0` (or negative) means "fail instantly" (`timeout 0`),
    not "no timeout"; no test. Also `Claude/Sse.hs:139-140` and
    `OpenAI/Sse.hs:136` carry the comment "EP-8 wires Options.timeoutMs through
    this local transport" on a `responseTimeoutNone` line; the bound lives in
    `Transport.runWithTimeout`.

### Theme B — Streaming lifecycle

1. **[major]** `baikai-claude/src/Baikai/Provider/Claude/Api.hs:186` and
   `baikai-openai/…/OpenAI/Api.hs:206` — the SSE worker is `forkIO`'d and its
   `ThreadId` discarded, so nothing cancels an in-flight request when the
   consumer stops pulling. `Stream.take 3 (streamRequest …)`, a consumer that
   dies, or the trace finaliser firing all leave the worker `brRead`-ing the
   whole generation into an unreachable `Chan`; the provider bills the full
   response and the pooled connection stays busy until the last frame. Only
   `Options.timeoutMs` bounds it. `TraceSpec` "an abandoned stream emits one
   evidence record" uses a stub provider, so the leak is untested.
2. **[major]** `baikai-claude/src/Baikai/Provider/Claude/Api.hs:761-768` and
   `baikai-openai/…/OpenAI/Api.hs:1194-1197` — a tool call whose argument
   stream was cut off (`stop_reason: max_tokens`, `finish_reason: length`)
   fails to decode and is closed as a *well-formed* `ToolCallEnd` with
   `arguments = {}`; `runToolLoop` then executes the tool with empty
   arguments. The Claude comment conflates "no deltas" (`""`) with malformed
   JSON; core's own recovery path keeps the raw text (`Stream.hs:346-351`), so
   the two layers disagree. No test covers a partial `partial_json` at block
   stop in either provider.
3. **[minor]** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:911-913` — the
   mid-stream `Left be` path (timeout, transport failure) emits `EventError`
   without closing open blocks, unlike `closeOpenStream` (`:1235-1246`); after
   thirty text deltas and a timeout the terminal's `content` lacks the partial
   text and no `TextEnd` is emitted, so raw-event consumers and
   `streamingComplete` callers (which recover via `danglingBlocks`) see
   different content.
4. **[minor]** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:955-972,998-1017`
   — reasoning that arrives *after* visible text opens a new thinking block
   while the text block stays open (`TextStart 0, TextDelta 0, ThinkingStart 1,
   …, TextDelta 0`), violating the index invariant at `Event.hs:57-61`.
   OpenRouter routes with interleaved thinking produce this; `ReasoningSpec`
   covers reasoning-before-text only.
5. **[design]** `baikai-claude/src/Baikai/Provider/Claude/Sse.hs:176-180` — any
   SSE frame whose event or delta `type` the SDK does not know becomes a
   terminal `EventError`, aborting a healthy stream; the SDK's
   `MessageStreamEvent`/`ContentBlockDelta` decoders have no unknown-tag
   fallback (only `ContentBlock` does). The next event type Anthropic adds ends
   every stream early.
6. **[design]** `baikai/src/Baikai/Response.hs:116-119`,
   `Stream.hs:295-297,499-501`, `Stream/Event.hs:110-115` — `Aborted` is
   documented as a legal failure stop reason (`streaming.md:130,182`: "caller
   cancelled via signal/timeout") but nothing produces it and core keys
   failure solely on `ErrorReason`: `responseError` returns `Nothing` for
   `stopReason = Aborted` even with `errorInfo = Just`, `eventsFor` lifts such
   a `Response` as `EventDone` and drops the error, and `runToolLoop` treats it
   as success. Timeouts are `ErrorReason`/`TransientError`; consumer abort is
   recorded only as evidence `CallAborted`. Either produce `Aborted` and treat
   it as failure, or retire it.
7. **[minor]** `baikai/src/Baikai/Stream.hs:186,217,228-229` — `wallStart` is
   captured and never read, so `latencyMs` depends on the provider stamping
   `timestamp` on both the skeleton and the terminal (a third-party provider
   that leaves them `Nothing` gets `latencyMs = 0`); a duplicate `EventStart`
   overwrites `responseId` with `.~ rid` while terminals use `rid <|> old`.

### Theme C — Thinking and request shaping

1. **[major]** `baikai/src/Baikai/Compat.hs:232-240` +
   `baikai-claude/…/Claude/Internal/Request.hs:93-94,239-272` —
   `defaultAnthropicThinkingStyle` is a prefix table (opus-4-6/4-7/4-8,
   fable-5 → adaptive; everything else → budget) and `claude-sonnet-5` is not in
   it. A thinking request on `anthropic_claude_sonnet_5` therefore sends
   `thinking: {type: "enabled", budget_tokens}`, which the current Anthropic
   reference rejects with a 400 on Sonnet 5 (and on Opus 4.7/4.8/5 and Fable 5;
   deprecated on the 4.6 pair, which the table also routes to budget). The same
   reference removes `temperature`/`top_p`/`top_k` on those generations, and
   `Request.hs:93-94` forwards `Options.temperature` and `topP` unconditionally,
   so a caller who sets either gets a 400 on every adaptive-era model. Neither
   is pinned: `ThinkingSpec.anthropicModels` lists every Anthropic catalog entry
   except `sonnet-5`, `CatalogSpec` has no thinking-style assertions, and
   `ThinkingSmoke.hs:52-56` sends `temperature = 0.0` with thinking on
   `sonnet-4-5`/`opus-4-6` only. The catalog carries no thinking-style or
   sampling-support field, so the table drifts every time the catalog is
   regenerated; the style belongs in the generated record. Not verified
   live — no Anthropic key was available to this review.
2. **[minor]** `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs:69-75`
   — a hand-rolled model with `maxOutputTokens = 0` (`emptyModel`) and no
   `Options.maxTokens` sends `max_tokens: 0` (overwriting the SDK's 1024) →
   400, and with `thinking` set also drops thinking because
   `resolvedCeiling <= budget`. The OpenAI side omits the field for a zero cap
   (REV-1 5.3); `handRolledUnclampedTest` sets `maxTokens = Just 100`, so the
   Claude case is unpinned.
3. **[minor]** `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs:368-374,414-416`
   — replay can send content Anthropic rejects: a text block that closed with
   no deltas becomes `{"type":"text","text":""}`, and a turn whose only blocks
   are signature-less thinking (core's recovery blocks) maps to `content: []`.
4. **[design]** `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs:121-167`,
   `Internal/Request.hs:115-122` — reasoning controls are emitted regardless of
   `Model.reasoning`, so `openai_gpt_4o_mini` + `thinking = Just _` sends
   `reasoning_effort` → 400. *Pinned* by `ShapeSpec.deepseekShapeTest` and
   `EvidenceSpec.toggleHostIndistinguishabilityTest`. It contradicts
   `docs/user/model-call-evidence.md:101`, which lists
   `thinking_dropped_unsupported_model` as a baikai-wide adjustment; only the
   Claude adapter emits it.
5. **[design]** `Claude/Internal/Request.hs:88-101` — `Options.metadata`
   (Anthropic's `metadata.user_id`), `seed`, `frequencyPenalty`,
   `presencePenalty` are silently dropped with no adjustment recorded;
   `optionsMappingTest` asserts only `top_p` and `stop_sequences`.
6. **[minor]** `Claude/Api.hs:800-803` — every cache write is priced at the
   single catalog `cacheWriteCost`; 1h-TTL writes (`CacheRetentionLong`) are
   billed higher, and the SDK's `Usage` does not parse the per-TTL
   `cache_creation` breakdown. `CacheSmoke` asserts token counts, never cost.
7. **[minor]** `Claude/Internal/Request.hs:350-357` — `normalizeToolCallId` is
   lossy (`a.b` and `a_b` collide, as do ids differing after character 64), so
   replaying a conversation whose tool calls came from another provider can
   produce duplicate `tool_use` ids.
8. **[minor]** `Claude/Api.hs:851-856` — `immediateError` records
   `noThinkingRequested` regardless of `opts.thinking`; `describeThinkingFor m
   opts` is pure and in scope (see D.2 for the core-side twin).

### Theme D — Evidence and tracing

The evidence surface (2026-08-05) had never been reviewed. Its core is sound —
digests cover exactly the bytes sent, the ordering fix holds on all three
terminal paths, opt-out allocates nothing — and the defects are at its edges.

1. **[major]** `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs:122` —
   the `CallFinished` branch inserts `gen_ai.response.model` from the trace
   event's `model`, which `Trace.hs:370` fills with the *requested* `modelId`.
   Because `CallEvidence` now arrives first (`:198` sets the observed value) and
   hs-opentelemetry's `addAttributes` replaces existing keys, the terminal
   overwrites the observed model with the requested one on every evidence
   call, and labels the requested id as the response model on every other
   call. `docs/capabilities/opentelemetry-span-export.md:38-40,62-64` promises
   the attribute is set only when the provider reported a model. Two named
   tests pin opposite semantics: `successSpanTest` asserts presence on a stub
   that observes nothing; `evidenceSpanTest` asserts absence for the same
   situation hand-fed. `liveEvidenceSpanTest` checks key presence, never the
   value.
2. **[major]** `baikai/src/Baikai/Trace.hs:270`, `Stream.hs:559,642`,
   `Registry.hs:173`, both providers' `immediateError` — every adapter-less
   path (consumer abort, unregistered provider, lifted completion, missing
   key) passes `noThinkingRequested`, so the evidence record states
   `thinking.requested = null, mode = "absent"` even when the caller set
   `#thinking .~ Just ThinkingMax`. `Evidence.hs:367-370` defines that value as
   "the caller set no level at all" and ADR 0002 makes `requested` the
   caller's fact; `refusedEvents` (`Stream.hs:588-621`) shows the right
   pattern. `abortEvidenceTest` and `noProviderEvidenceTest` use options with
   no thinking level, so nothing covers it.
3. **[major, design]** `baikai/src/Baikai/Trace.hs:304-316,330-341` — strict
   mode fails a call only when the sink *threw*; a terminal carrying
   `evidence = Nothing` under `EvidenceRequired` pushes no record and succeeds.
   A `Custom` provider that never attaches evidence passes the pre-dispatch
   gate (`declaredStrength (Custom _) = RequestedOnly`), returns `Stop`, and
   writes zero `call_evidence` lines with no error — exactly the "evidence
   that can vanish without the caller noticing" that
   `docs/user/model-call-evidence.md:219-225` and `Build.hs:402-415` say strict
   mode exists to prevent. `strictSinkFailureTest` uses this very no-evidence
   fixture and proves only the throwing-sink half.
4. **[minor]** `Trace.hs:396-398,420-422` — `terminalSent` is written *after*
   the terminal is pushed; an async exception between `writeChan` and
   `writeIORef` makes `finalizeTrace` see `sent = False` and push a second
   `CallEvidence` plus an `aborted` `CallFailed` after the `CallFinished`.
   Nothing masks the three writes.
5. **[minor]** `Trace.hs:284` — `finalizeTrace` blocks on `takeMVar done` on the
   consumer thread at every terminal and, on abort, inside streamly's
   finaliser under `mask_`, so a sink that *blocks* (an exporter with a full
   queue, a stuck file lock) hangs the call and swallows the first
   cancellation. `throwingSinkTest` covers a throwing sink only;
   `docs/capabilities/call-tracing.md:48` says tracing "cannot damage the call
   it observes".
6. **[minor]** `Trace/Sink.hs:60-64` — `multiSink` is `Fold.tee`, whose
   exception propagates out of both folds, so one throwing sink drops delivery
   to every sibling for that call and skips their `final`: an `otelSink`
   paired with an unwritable `fileSink` leaves its span un-ended.
7. **[minor, design]** `Evidence.hs:1019,1023` — the configuration allow-list
   passes `output_config` and `response_format` through verbatim, so a
   structured-output JSON schema with its `description` strings lands in the
   "content-free" digest, while `tools[].input_schema` is stripped as
   author-written content (`:984-989`, ADR 0004). The redaction fixture plants
   no marker inside either key.
8. **[minor]** `Evidence/Build.hs:212-216` — `sanitizeEndpoint ""` yields
   `Nothing` ("baikai recorded no endpoint") although both adapters substitute
   a definite default host for an empty `baseUrl`, so `emptyModel & #api .~
   AnthropicMessages` records `endpoint: null` for a call that went to
   `api.anthropic.com`.
9. **[design]** `OpenTelemetry.hs:108` — `createSpan tracer Context.empty` makes
   every baikai span a root; `OtelSinkOptions` has no parent-context knob and
   the fold runs on the trace worker thread, so a consumer cannot nest a model
   call under its own request span.
10. **[design]** `Evidence.hs:572-578` + `Registry.hs:66-84` —
    `declaredStrength` is keyed on the `Api` tag and `ApiProvider` cannot
    declare a ceiling, so a custom transport that observes a model can never
    satisfy `EvidenceRequired EvidenceCorrelated`; the strength rule is also
    copied three times (`Claude/Api.hs:430-435`, `OpenAI/Api.hs:661-666`,
    `Cli/Internal.hs:725-735`) and ignores an observed response `id`, and
    `ModelCallEvidence.strength` is freely settable because the constructor
    is exported.
11. **[design]** `OpenAI/Api.hs:697-703,1252-1255` — `responseCommitment`
    digests `finalUsage`, whose `cost` comes from the caller's catalog rates,
    so the digest changes when pricing is edited and a verifier holding only
    the response cannot recompute it; the codex envelope digests `zeroCost`.

### Theme E — Secrets and credentials

1. **[major, security]** — A.1 above: the last-`@` host parse can route a
   known host's key to an arbitrary host.
2. **[minor, security]** `baikai/src/Baikai/Options.hs:23-27,85,98-99`,
   `Model.hs:125,128-129`, `Response.hs:45,69` — `Options.headers` and
   `Model.headers` are printed verbatim by derived `Show` and `ToJSON`, while
   the `Options` Haddock explicitly invites gateway `Authorization` overrides
   there and `Response` embeds the `Model`; `docs/user/getting-started.md:132`
   tells users to `print resp`. `ApiKeySource` is redacted (`Auth.hs:32-49`,
   "Options Show/JSON redacts literal API keys"); a header-carried credential
   is not.
3. **[minor, security]** `baikai/src/Baikai/Embedding.hs:55-72,104` —
   `emptyEmbeddingModel`/`openAIEmbeddingModel` hard-wire `apiKey = ApiKeyEnv
   "OPENAI_API_KEY"` regardless of `baseUrl`, bypassing the per-host table that
   REV-1 10.8 introduced for the chat providers, so an embedding model pointed
   at a third-party host with the default key sends the OpenAI secret there;
   the module also still allocates a TLS manager per call through the SDK's
   `getClientEnv` and derives neither `Generic` nor `Eq`, so the `#field`
   idiom every other record supports does not compile for it.
4. **[minor, security]** — A.5 above: redirects forward the bearer token.
5. **[minor, security]** `baikai-kit/src/Baikai/Kit/Install.hs:286-289,310` —
   the path sanitiser is lexical (`safeRelativePath` rejects `..` and absolute
   paths) and plan 35 accepted that on the grounds that "the manifest cannot
   create symlinks"; git checks out committed symlinks. A kit repository that
   commits `skills/x/sub -> ../../../../..` and lists `files: ["sub/.ssh/id_ed25519"]`
   has that file read through the link (`doesFileExist`/`readFile` follow it)
   and copied into `~/.claude/skills/x/sub/.ssh/id_ed25519` — writes stay
   inside the target root, so this is a read-side disclosure into a directory
   the agent reads. Untested; needs `pathIsSymbolicLink`/canonical-path checks
   on the source side.
6. **[minor]** `baikai/src/Baikai/Auth.hs:88-102` — an environment variable set
   to the empty string is accepted as a key (and short-circuits an
   `ApiKeyEnvChain`), so the request goes out with `Authorization: Bearer ` and
   fails as a provider 401 instead of the descriptive `AuthError`.

### Theme F — baikai-kit and baikai-agent

`baikai-agent` (0.1.0.0) and the unattended-run core had never been reviewed;
`baikai-kit` was hardened in July. The runner's design — policy ceiling, layered
KDL, process groups, evidence on stdin-delivered prompts — is right; its
shipped form is not.

1. **[critical]** `baikai-agent/baikai-agent.cabal` (`executable baikai`
   stanza) — the shipped binary is built without `-threaded`. Only the
   test-suite carries `-threaded -with-rtsopts=-N`, under a comment saying it
   "is not optional here"; neither `common-options` nor `cabal.project` adds
   it. `Baikai.Agent.Run` depends on it: `waitWithTimeout` (`Run.hs:691-692`)
   wraps `P.waitForProcess` in `System.Timeout.timeout`, and `process`
   documents that without `-threaded` `waitForProcess` blocks every other
   Haskell thread. In the binary as shipped, the timeout thread, both
   `forkDrain` threads (`Run.hs:552-553`) and `writePromptAsync`
   (`:539,592-600`) cannot run while the main thread waits: `timeout "45m"`
   never fires — no `RunTimedOut`, no exit 75, no process-group kill; in
   `capture`/`tee` mode a child that writes more than the pipe buffer before
   exiting blocks on write while the parent blocks in `waitpid` — a deadlock;
   a prompt larger than the pipe buffer deadlocks the same way. Every runner
   test runs in-process under the test-suite's RTS; nothing spawns the built
   binary and `baikai-smoke` has no agent case, so the guarantees CAP-17 and
   CAP-18 state are proven only under an RTS the binary does not ship with.
2. **[major, security]** `baikai/src/Baikai/Agent.hs:145-149,387-409` +
   `baikai-claude/…/Claude/Agent.hs:188-194` — `allowedTools` is modelled as
   a *narrowing* ("do not restrict tools beyond what the capability implies")
   and is therefore not ceiling-gated, but on Claude Code `--allowedTools` is
   a permission *grant* ("list of tool names to allow" in `claude --help`; the
   narrowing flags are `--tools` and `--disallowedTools`). An untrusted
   `.baikai/agents.kdl` with `capability "edit-workspace"` and `allowed-tools
   "Bash"` passes `applyAgentCeiling`, which checks only provider, capability
   and provider-args, and renders `-p --permission-mode acceptEdits
   --allowedTools Bash`: Bash auto-approved in an unattended run, more
   authority than `AgentEditWorkspace` promises. `CliTests.syncKeiroDslRunsTest`
   pins the pass-through (a decision); `AgentSpec.ceilingAcceptanceTest` never
   includes `allowedTools`.
3. **[major, security]** `baikai-agent/src/Baikai/Agent/Config.hs:150,391-396,410-422`
   — the ceiling forgets `executable`, `working-dir`, `extra-dirs`,
   `output-limit` and `timeout`, all settable from the repository scope:
   `executable "./scripts/run.sh"` with `working-dir "."` execs a
   repository-controlled program with the operator's full environment
   (`Run.hs:502`, `P.env = Nothing`) and the prompt on stdin; `extra-dirs
   "/Users/op/.ssh"` on codex is write access; `output-limit "unlimited"`
   removes the bound `Config.hs:241-249` exists for. `BAIKAI_AGENT_EXECUTABLE`
   is also env-bound (`Config.hs:575`) despite the "no ambient influence"
   rationale at `:554-561`. `CliTests.honorsExecutableOverrideTest` resolves
   `executable` from a repository-only document (a decision);
   `docs/user/unattended-agent-runs.md:507-510` says the ceiling "is what
   stops" an untrusted repository.
4. **[major]** `Cli.hs:417-423,554-565` + `Config.hs:593-603` — `--user-config
   PATH`, `XDG_CONFIG_HOME` and `HOME` select the file the ceiling is read
   from, so `baikai agent run job --user-config .baikai/policy.kdl` (or
   `XDG_CONFIG_HOME=$PWD/.baikai`) makes a repository-controlled `policy {
   max-capability "full-access" allow-provider-args #true }` the ceiling.
   `docs/user/unattended-agent-runs.md:511-513` and
   `docs/capabilities/baikai-agent-command.md:53-56` say no environment
   variable or flag can raise it; `commandLineCannotRaiseTheCeilingTest`
   covers `--set` only.
5. **[major]** `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs:156-162`
   + `baikai/src/Baikai/Interactive.hs:81-86,136-140` — `CodexApprovalUntrusted`
   → `untrusted` and `CodexApprovalOnFailure` → `on-failure` are values `codex
   0.149.1` rejects (`--ask-for-approval` accepts `on-request` and `never`), so
   two of the four constructors launch, fail with a usage error and return
   `Right (ExitFailure n)` instead of `Left SafetyNotExpressible` — past the
   refusal contract commit `ab877cd` established.
   `InteractiveSpec.codexSafetyRenderingTest` pins the spellings;
   `docs/user/interactive-launches.md:225-232` says `Right` for every
   `CodexSandbox`.
6. **[major]** `baikai-agent/src/Baikai/Agent/Run.hs:723-737` — timeout
   escalation is SIGINT → SIGTERM → `terminateProcess` → an *unbounded*
   `waitForProcess`; there is no SIGKILL, so a leader that handles SIGTERM, or
   a `setsid`'d grandchild holding the stdout pipe, hangs the runner after
   the timeout (then `withCreateProcess`'s cleanup `hClose`s handles the drain
   threads still hold). The output drained before the timeout is discarded on
   the `Nothing` branch (`:556-562`), contradicting the comment at `:686-689`.
   `processGroupTest` uses `sh`/`sleep`, which die on TERM.
7. **[major]** `baikai/src/Baikai/Provider/Cli/Internal.hs:246-254` —
   `parseCodexJsonlStream` assembles each line with `Fold.foldl' BS.snoc
   BS.empty`, copying the accumulator per byte: O(L²) per line. One
   `agent_message` event of a few hundred KB — a long codex answer or diff —
   costs on the order of 10¹⁰ byte copies; reached on every `codex exec
   --json` batch call (`OpenAI/Cli.hs:281`) and every evidence-bearing codex
   agent run (`Run.hs:432`). `CliInternalSpec` uses tiny inputs.
8. **[major]** `baikai/src/Baikai/AgentAssets.hs:143-145` —
   `tomlMultilineString` emits a TOML basic multi-line string and escapes only
   `"""`, so any backslash in an agent body (`\d`, `\.`, a literal `\n` in
   markdown, a trailing `\`) is an escape sequence and an unknown one is a TOML
   error: Codex fails to load the custom agent. `tomlString` (`:132-141`)
   leaves C0 controls other than `\n\r\t` unescaped.
   `AgentAssetsSpec.codexTomlTest` covers `"""` only.
9. **[major]** `baikai-agent/app/Main.hs:41-44` — `TextIO.hPutStr` encodes with
   the locale; under `LANG=C` or no locale (cron, systemd, containers — the
   documented targets) a captured answer or `--json` payload containing a
   non-ASCII character throws `hPutChar: invalid argument` after the run
   finished → exit 1, the agent's exit code and JSON lost. The read side
   deliberately avoids this (`Cli.hs:1152-1158`); no test spawns the binary.
10. **[major, security]** — E.5: a committed symlink in a kit repository is
    read through by `requireSourceFile`, `computeKitHash` and the copy
    (`Install.hs:216-240,286-289,310`, `Sidecar.hs:51`); found independently by
    two readers; `docs/capabilities/kit-installer.md:49-52` claims every path
    is checked.
11. **[major]** `baikai-kit/src/Baikai/Kit/Install.hs:78-85,114-125,178,277,323`
    and `Repo.hs:54` — library functions (`loadManifest`, `installItem`,
    `listAvailable`, `updateKit`, `requireSafe`, `ensureKitRepo`) call
    `exitFailure` after printing to stderr; `docs/user/kit.md:136-145` tells
    consumers with their own CLI to call exactly these. An application
    embedding `Baikai.Kit` exits the whole process on a missing or
    unparseable `kit.json`, an unsafe name, or a first clone that fails
    offline (`kit status` on a fresh machine exits 1 instead of reporting
    nothing installed), with no `Either` or exception to catch.
12. **[minor]** `Install.hs:241-266` — an agent with `files: [a, b, …]` installs
    only the first file (`primarySource`); the rest are hashed only, while
    `docs/user/kit.md:102-105` says each listed file is copied.
    `Install.hs:291-294,124` — phase two of `executePlan` is not rolled back
    and the temp name `<dest>.baikai-kit-tmp` is fixed, so two concurrent
    installs of one item clobber each other. `Kit/Manifest.hs:21` decodes
    `version` and never checks it. (Commit `837584d`'s "manifest v6" is
    seihou's `.seihou/manifest.json`, not `kit.json`.)
13. **[minor]** `Config.hs:651-663` + `Cli.hs:646,1010,1021` — settei's default
    `WarnUnknownKeys` against a per-job schema prints `jobs.B.*: unknown key`
    for every other job and `policy.*: unknown key` for the operator's own
    policy block on every `run`/`show`, while the guide says a repository
    `policy` node is "ignored" (`:519-521`). `Cli.hs:1044-1058,1126-1146` —
    `--run-id` or `--require-evidence` alone builds evidence that is neither
    written nor in `--json`. `Agent.hs:587` + `Cli.hs:1103` — `OutputMalformed`
    has no producer, so exit 70 (`unattended-agent-runs.md:277`) is
    unreachable. `Run.hs:380-389` — evidence `endpoint` resolves a relative
    `executable` against the parent's cwd while the child execs it relative
    to `working-dir`. `Run.hs:361-367` — `errorInfo` embeds the entire
    captured stderr (up to 4 MiB) in the evidence record. `Cli.hs:1074-1081`
    — the evidence staging path `PATH.partial` is predictable and `writeFile`
    follows a pre-planted symlink.
14. **[design]** before `baikai-agent` 0.2: `envPassthrough`
    (`Agent.hs:251-261`) names a precondition list, not a pass-through (the
    config calls it `env-requires`); `AgentCommand` has no structured-output
    field, so evidence above `requested_only` requires opening the whole
    `provider-args` channel — a privileged escape hatch as the only route to
    an unprivileged feature; `working-dir "."` resolves against the process
    cwd, not the declaring file (`Config.hs:602`), undocumented; `show --json`
    emits a bare resolution report on failure but an envelope on success;
    `Cli.hs:1188-1190` justifies hand-rolled JSON by an aeson dependency the
    package already has.

### Theme G — Public surface and PVP (pre-freeze)

1. **[design, high]** `baikai/src/Baikai/Provider/Registry.hs:66-84` —
   `ApiProvider(..)` is exported with no base value, contrary to the policy at
   `Baikai.hs:11-16`; adding `describeThinking` in 0.5.0.0 broke every
   third-party provider (`docs/user/models-and-providers.md:327-335`
   acknowledges it) and the next field will again. Other records outside the
   decided set that still export constructors: `Tool(..)`,
   `EmbeddingModel(..)`, `ModelCallEvidence(..)` (Haddock: "construct through
   `baseEvidence`"), `EvidenceRequest(..)`, `CallLogConfig(..)`,
   `OtelSinkOptions(..)`, and in `baikai-agent` `AgentCliOptions(..)` (eight
   consumer-set fields, no base), `AgentJob(..)`, `AgentConfigPaths(..)`,
   `AgentCliRun(..)`. The streaming-state seams `Assembler(..)` (both
   providers), `RawChunk(..)`, `RawUsage(..)`, `TagScanState(..)` and
   `_TagScanState` are exported from the public `Api` modules with no PVP note
   (`OpenAI/Api.hs:51` says they "may move behind an .Internal namespace"), and
   `RawChunk` already forced a documented breaking change.
2. **[design]** `baikai/src/Baikai/ResponseFormat.hs:1,26-30` —
   `-Wno-partial-fields` and `ResponseFormat(..)` export partial selectors
   `name`/`schema`/`strict` that crash on `JsonObject`, contradicting the
   project's own rationale at `Stream/Event.hs:62-66` and `Message.hs:22-32`.
3. **[design]** deprecated shims with no removal version, two majors after the
   0.3.0.0 changelog said they would "remain for this release": sixteen `_X`
   aliases, eight `registerWith*` names (still the registration path the
   README and two guides teach — H.2), `newEventId`, and three construction
   paths for `InteractiveLaunchResult`.
4. **[design]** `baikai/src/Baikai/Api.hs:28-34` + `Registry.hs:89,117,144` —
   the registry is keyed on derived `Eq`/`Ord Api`, so `Custom
   "anthropic-messages"` and `AnthropicMessages` are distinct keys although
   `renderApi` is identical and `parseApi` collapses them on the JSON path; a
   handler registered under one is invisible to a `Model` tagged with the
   other and `assertRegistered` disagrees with dispatch. `emptyModel.api =
   Custom ""` still dispatches to a message that ends in an empty string.
5. **[design]** naming and type consistency on public records: `Options.seed ::
   Maybe Integer` beside `maxTokens :: Maybe Natural` and `timeoutMs :: Maybe
   Int`; `executable :: FilePath` beside `extraArgs :: [Text]` in every CLI
   config; `ApiKeyEnv !String` in a `Text` API; `Vector` for `Context.messages`,
   `tools` and `stopSequences` but lists for `Model.input`, `extraDirs`,
   `allModels`; `Response.model :: Model` beside `TraceEvent.model :: Text`;
   redundant "none" spellings (`cacheRetention :: Maybe CacheRetention` with
   `CacheRetentionNone`, `toolChoice :: Maybe ToolChoice` with
   `ToolChoiceAuto`); duplicate names a consumer imports together
   (`CallFailed` in both `Evidence.CallStatus` and `Trace.Event`;
   `runId`/`attempt`/`supersedes` on both `EvidenceRequest` and
   `ModelCallEvidence` so sinks pattern-match instead of select; three
   `UserScope`-shaped constructors in three modules); `headers :: Map Text Text`
   is case-sensitive while the provider override fold is case-insensitive, so
   two keys differing only in case pick a winner by `Map` order.
6. **[design]** `baikai/src/Baikai/Agent.hs:70,455-456` — `AgentRunResult`
   exports neither selectors nor accessors; without `generic-lens` a consumer
   cannot read `exitCode` or `duration`, while its sibling `AgentRunRequest`
   exports selectors. `OtelSinkOptions` derives nothing, so `#spanName` does
   not work on it. No `parseThinkingLevel` is exported although the six-name
   table is copied in `Evidence.hs:305-313`, `Agent/Config.hs:341-353` (whose
   comment says "has a renderer but no parser") and `Agent/Cli.hs:470-474`.
7. **[minor]** `baikai/src/Baikai/Context.hs:106-131` — `appendToolResult`
   appends the assistant message even when the response is error-shaped,
   producing an empty assistant turn in a replayed context (`runToolLoop`
   guards this; the documented direct round-trip in `tools.md:151-158` does
   not), and its Haddock claims "multi-call concurrency lives in the
   dispatcher" although the dispatcher is invoked sequentially via `traverse`.
8. **[minor]** release metadata: no `tested-with` in any cabal file
   (`README.md:235` claims GHC 9.12.4); only `baikai` ships a changelog to
   Hackage — `baikai-claude`, `-openai`, `-trace-otel`, `-kit`, `-agent` have
   no `extra-doc-files`, so six Hackage pages have none although the release
   skill makes the root changelog the record; the `baikai-claude`/`-openai`
   descriptions omit the CLI, interactive and agent surfaces;
   `baikai-trace-otel.cabal:59` pins `streamly-core ^>=0.3` while every sibling
   allows `<0.5`; `baikai-effectful.cabal:56` depends on `streamly` but imports
   only `streamly-core`. `CHANGELOG.md` 0.5.0.0 has no entry for strict evidence
   mode, pre-dispatch refusal, sink-failure semantics, or the breaking
   `ApiProvider.describeThinking` field, and `:86-89` ("every record has
   strength requested_only") is contradicted by later entries.

### Theme H — Documentation drift

The user guides and capability catalog were swept in July and have drifted
again, mostly where August code changed behaviour they describe.

1. **[major]** twelve of the twenty-two capability records' `## Shape` blocks
   do not type-check or name things that do not exist: CAP-4
   (`tool-calling.md:64-67`: `#tools` is on `Context`, not `Options`, and
   `runToolLoop dispatcher 8 …` reverses the first two arguments), CAP-5
   (`structured-output.md:55`: `JsonSchema` has three fields), CAP-9 and CAP-19
   (`call-tracing.md:59`, `model-call-evidence.md:101`: `fileSink :: FilePath ->
   IO TraceSink` passed as a pure value, after `import Baikai`, which omits
   `withTrace`), CAP-12 (`resp ^. #usage`; usage lives at `#message . #usage`),
   CAP-13 (`registerWith` is not exported by `Baikai.Provider.Claude.Api`),
   CAP-16 (`interactiveLaunchRequest` takes the prompt first and `modelId` is
   `Maybe`), CAP-17 (`either throwIO pure` on `AgentRenderError`, which has no
   `Exception` instance), CAP-18 (KDL keys and the required `working-dir` are
   wrong), CAP-20 (`complete` returns `Eff es Response`, not `Text`), CAP-22
   (`ProjectScope` is `baikai-kit`'s `KitScope`; the asset API takes
   `InteractiveProjectScope`). A consumer who copies the catalog's shape gets a
   compile error.
2. **[major]** `README.md:131-134`, `docs/user/cli-providers.md:113-162`,
   `models-and-providers.md:232`, `docs/capabilities/anthropic-messages-backend.md:37,68`
   — the documented registration path is the deprecated `registerWith`,
   `registerWithRegistry`, `registerWithRegistryAndConfig` family; no test or
   smoke uses them; under `-Werror=deprecations` the guide's code does not
   build. Only `getting-started.md:82-87` shows `newProviderRegistryFrom` with
   the `*Provider` values. `responseError`, `streamRequestEach`,
   `streamRequestList`, `ApiKeyEnvChain`, `mkModel` and the sampling options
   appear in no guide; `streaming.md:15-19` still says everything assumes
   streamly imports.
3. **[minor]** claims the code no longer honours: `README.md:149-150`,
   `models-and-providers.md:356-357`, `prompt-caching.md:126-128` say CLI
   providers report zero usage (they report tool counts and cost since
   0.5.0.0; `cli-providers.md:174-193` is right); `tools.md:70,231-233` says
   `ToolChoiceNone` suppresses `tools` and `:234-237` says tool-side
   `cache_control` is not wired (both fixed in July); `prompt-caching.md:23-30`
   and `CacheRetention.hs:22-24` promise an OpenAI "24h" retention that no code
   emits — `api.openai.com` gets no marker at all, only OpenRouter does;
   `streaming.md:47` names `BlockEndPayload` for `ThinkingEnd`; `streaming.md:174`
   and `getting-started.md:174` use `assistantContent` for the `content`
   field; `streaming.md:159-164` and `models-and-providers.md:323-325` show a
   lifted stream without `TextStart`; `unattended-agent-runs.md:550` quotes a
   refusal that prints raw provider arguments, the exact leak commit `ab877cd`
   removed, and `:580-594` describes settei's resolution format instead of
   `renderEffectiveConfig`'s; `cli-providers.md:283-293` says only
   `Options.thinking` is honoured by the CLI providers (so is
   `Options.evidence`); `model-call-evidence.md:101` lists
   `thinking_dropped_unsupported_model` as baikai-wide; `generated-model-catalog.md:42,71-74`
   names `Models.claude_sonnet_5` and says DeepSeek/OpenRouter are not in the
   generated surface (both are); `getting-started.md:11-18` omits two packages;
   `models-and-providers.md:83` and `tools.md:236-237` cite "EP-5" in a user
   guide.
4. **[minor]** Haddock that describes the pre-July or pre-August code:
   `Trace/Event.hs:87-90` says `CallEvidence` is emitted *after* the terminal
   (before, since `1717694`); `Trace/Event.hs:42-43` says the CLIs do not
   report tokens; `Trace.hs:22-24` says sink exceptions never propagate into
   the call (they do under `EvidenceRequired`); `Stream/Event.hs:14-17`
   ("temporary gap until EP-7"), `Stream.hs:97,578` ("one-event error stream"),
   `Stream.hs:426-427`, `Event.hs:6-8,73-75` (an `EventStart` "skeleton" whose
   `Message` carries no api/provider fields); `Compat.hs:140-156,197,213`
   point at functions that moved to `Internal.Request` and one that does not
   exist (`translateTextLikeDelta`); `Compat.hs:83-84` says six hosts route
   through `compatibleEffort` (three do); `OpenAI/Internal/Request.hs:110-114`
   says non-OpenAI thinking formats are "silently dropped on this revision";
   `OpenAI/Api.hs:155-163` says the worker drives
   `OpenAI.createChatCompletionStream`; `Claude/Api.hs:139-140` says the
   channel is bounded; both `ErrorClass.hs` module headers describe a servant
   entry point the streaming path no longer has; `Message.hs:18-19` links the
   removed `Baikai.Request.Request`; `Model.hs:6-7` calls `Compat` "a
   placeholder until EP-5"; `Response.hs:82` says `emptyResponse` is stamped
   "at epoch start"; `Context.hs:106-108` (concurrency claim);
   `docs/capabilities/call-tracing.md:50-51` and `model-call-evidence.md:35`
   claim guarantees (immediate abort terminal; a `TraceSpec` ordering
   assertion) that do not exist; `model-call-evidence.md:129` and
   `CHANGELOG.md:83-85` call `onSinkFailure` a hook "a future release
   replaces" although the replacement shipped in the same release.

### Theme I — Test-coverage gaps

The offline suites are extensive (931 tests) and the July complaint — tests
feeding shapes the runtime never produces — is largely answered by the
`SseSpec`/`EvidenceSpec` replays. What remains:

1. Tests that still assert unreachable shapes and therefore prove nothing about
   the runtime: both `ErrorClassSpec.responseToError`/`fromClientError` cases
   (no servant client runs in either package), `ErrorClassSpec.sdkTextTests`
   ("HTTP error 429 …" was the old SDK's text), `ReasoningSpec` "whole message
   shape yields reasoning then text" (a non-`data:` JSON body is dropped by the
   transport before `parseMessageObject` can see it).
2. No test drives a stalled socket through `runWithTimeout` (plan 41 specified
   one); no test pins the shape of a Claude HTTP-level failure stream (B.1);
   no `TraceSpec` assertion checks that `CallEvidence` precedes the terminal
   (only the OTel suite proves it indirectly, and the capability record claims
   otherwise); no test for a partial `partial_json`/`arguments` at block stop
   (B.2), an in-band `error` frame on a 2xx stream (A.3), an `@` after the
   authority (A.1), a 413 (A.7), an empty-string key (E.6), the Claude
   `max_tokens: 0` case (C.2), a blocking sink (D.5), or the Claude usage
   mapping with non-zero cache counts.
3. `ThinkingSpec.anthropicModels` omits `claude-sonnet-5`, and `CatalogSpec`
   asserts nothing about thinking style, so the one catalog entry the table
   mishandles is the one without a pin (C.1).
4. `baikai-smoke`'s `apiCases` are Claude Haiku and `gpt-4o-mini` only, so the
   tools and structured-output smokes never run against DeepSeek or OpenRouter;
   `CompatSmoke` asserts non-empty text, not that `maxTokens` was honoured;
   `CacheSmoke` never asserts cost. The 24 live cases were skipped in this
   review's test run.
5. Duplicate-`EventStart`, events-after-terminal, and the failed-terminal
   branch of `reassembleResponse` (`Stream.hs:301`, where dangling blocks are
   appended after the terminal's content rather than merged by index) have no
   `StreamSpec` case.

---

## Recommended order of work

1. **F.1** — add `-threaded` to the `baikai` executable, and add one test that
   spawns the built binary against a child that outlives its timeout.
2. **A.1** — replace `urlHost`'s userinfo strip with `dropUserInfo`'s rule and
   make the two parsers one function; add the `@`-after-authority cases to
   `baikai/test/Main.hs`.
3. **C.1** — move the Anthropic thinking style (and sampling support) into the
   generated catalog record so the table cannot drift, route `claude-sonnet-5`
   to adaptive, gate `temperature`/`top_p` on adaptive-era models, and pin
   every catalog entry in `ThinkingSpec`; verify live once a key is available.
4. **B.1 and A.4** — hold the worker's `ThreadId` and kill it from a
   `finallyIO`/`bracket` around the consumer; pre-seed `EventStart` on the
   Claude wire-failure path and assert `EventStart`-first on every error
   stream in both `SseSpec`s.
5. **A.2 and A.3** — classify body-reader `IOException`s and
   `InvalidChunkHeaders` as `TransientError`; detect `{"error":…}` frames in
   `parseChunk` and classify them (`classifyErrorText` already exists).
6. **B.2** — surface a cut-off tool call as an error or keep the raw text, as
   core's recovery path does; never a well-formed `{}`.
7. **D.1–D.3** — read the observed model from the evidence event only in the
   OTel sink; thread `describeThinkingFor` through every adapter-less
   evidence path; fail a strict call whose terminal carries no evidence.
8. **F.2–F.4** — treat `allowedTools` as a grant and gate it; add
   `executable`, `working-dir`, `extra-dirs`, `output-limit`, `timeout` to the
   ceiling or refuse them from the repository scope; document (or close) the
   `--user-config`/`XDG_CONFIG_HOME` path to the ceiling file.
9. **F.5–F.9** — refuse `CodexApprovalUntrusted`/`OnFailure` as
   `SafetyNotExpressible`; escalate to SIGKILL and keep drained output on
   timeout; assemble JSONL lines with a builder; escape TOML bodies properly
   (or use literal strings); write the binary's output as UTF-8 bytes.
10. **E.2, E.3, E.5, A.5** — redact `headers` in `Show`/`ToJSON`; route
    embeddings through the per-host key table; reject symlinked kit sources;
    set `redirectCount = 0`.
11. **G and H** — decide and date the removal of the `_X` and `registerWith*`
    shims; give `ApiProvider` a base value and hide the assembler seams;
    rewrite the twelve capability `Shape` blocks and the registration path in
    the README and guides; sweep the Haddock listed in H.4.
12. **I** — retire the unreachable-shape tests and add the stalled-socket,
    partial-arguments, in-band-error and `sonnet-5` pins.

## What was checked and found clean

- `Baikai.Provider.Claude.Sse` and `Baikai.Provider.OpenAI.Sse`: line
  buffering across chunk boundaries, CRLF, `ping`/comment lines, `data:` with
  and without a space, EOF with a pending partial line, non-2xx with an empty
  or non-JSON body, case-insensitive `Retry-After`, `[DONE]` halting
  consumption, `onMetadata` exactly once, header capture as an allow-list that
  never records `x-api-key`/`authorization`.
- Exactly one terminal on every path in both assemblers (`terminalRef`,
  `finished`, pending drain, a late `Left` after the terminal never delivered);
  `trySync` rethrows async exceptions everywhere it is used;
  `runWithTimeout` is in-band; `HTTP.withResponse` closes the connection on
  timeout; `immediateError` is `EventStart`-first.
- Stream-to-event mapping: `IntMap` block indices, `input_json_delta` and
  `signature_delta` accumulation, redacted thinking carried and replayed
  verbatim, unopened-index deltas ignored, `message_delta` usage and stop
  reason, `max_tokens` → `Length`, `refusal` → `ErrorReason` with content;
  OpenAI tool deltas by index then id, parallel calls, `finish_reason` null
  and usage-after-finish chunks, `<think>` tag splitting across deltas.
- Usage and cost: both mappings honour the disjoint token classes;
  `computeCost` bills each class once and is zero for unpriced hosts;
  `Usage`/`Cost`/`Context` monoid laws.
- Request shaping: verbatim `input_schema` by index, `tool_choice` variants
  including `none` with `tools` kept, tool cache marker gated by compat, TTL
  downgrade, `max_tokens` never above the cap for all pinned models × levels,
  budget dropped and recorded when it cannot fit, adaptive `output_config`
  merged with `responseFormat`, `renameMaxTokens`, zero-cap omission,
  `stream_options` gate, strict gating, all 42 level × format rows.
- Evidence core: both commitment digests hash exactly the `Value` the driver
  serialises; credentials never enter the body; `canonicalEncode` is
  deterministic and golden-pinned; `newCallId` is 128 bits; evidence precedes
  the terminal on all three terminal paths; `failTerminal` keeps one terminal;
  the strict gate is lazy for best-effort and applied on both dispatch paths;
  opt-out allocates nothing; `Observed` has no default-supplying function;
  `declaredStrength` never yields `fully_observed`.
- Trace worker protocol: `try` around the drain, unconditional `putMVar`,
  idempotent `finalizeTrace`, the `StablePtr` root matching streamly's
  GC-driven `finallyIO`; the OTel sink holds at most one span per fold and
  drops unknown ids; the effectful interpreters preserve the terminal
  guarantee and propagate callback exceptions.
- Registry: last-wins registration, `assertRegistered`, `runToolLoop`
  termination and budget, `completeText`; `ApiKeySource` redaction; the
  per-host key table covers every shipped catalog host; JSON round-trips for
  every sum and payload record; `hostMatchesSuffix` at a label boundary.
- CLI providers: every rendered flag exists in `claude 2.1.247` and `codex
  0.149.1`; `--` before the prompt; stderr drained concurrently; missing
  binary in-band; version probe bounded and cached on the evidence path only.
- Unattended runner: `applyAgentCeiling` collects every violation and never
  clamps; precedence user < repo < env < cli; settei decodes only the
  rightmost candidate; job names never touch the filesystem; prompt on stdin
  under both providers; `create_group` and `setpgid`; bounded `drain`
  retention; prompt committed by value in evidence and excluded from the
  configuration envelope; `EvidenceRefused` → 77.
- `baikai-kit`: lexical path sanitisation on every write path;
  `removeDirectoryRecursive` refuses a symlinked top-level directory on
  uninstall; `computeKitHash` order-independent and length-delimited; staged
  writes with phase-one rollback; CRLF frontmatter.
- Catalog and generators: every identifier the guides name exists;
  `since` fields agree with the tags; the generator is deterministic and
  rejects identifier collisions; JSON escaping goes through aeson.
- Release metadata: README Hackage column matches the cabal versions;
  inter-package bounds admit the released versions; `[Unreleased]` is
  accurately empty.
