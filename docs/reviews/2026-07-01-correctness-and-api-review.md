# Correctness & API review — 2026-07-01

Scope: all five packages plus `baikai-kit` / `baikai-trace-otel`, reviewed by five
parallel reviewers (core, claude, openai, satellites, API design); the
highest-severity findings were then independently re-verified against the source
(and, for the CLI argument-parsing items, against the actual `claude` binary).
Build and all test suites pass, including live smoke tests against OpenAI and both
CLIs — the issues below are in paths the tests don't exercise.

Verdict: the architecture is sound (one vocabulary, models-as-data, in-band
streaming errors), but the error-classification layer, thinking support, and the
compat-quirk system do not currently work as documented. Fix themes 1–4 before
relying on it for important tasks.

---

## Theme 1 — Error classification / retry policy is effectively dead (fix first)

For a library used in "important tasks", retryability is the load-bearing feature,
and today no real failure ever gets a useful category.

1. **[critical]** `baikai-claude/src/Baikai/Provider/Claude/Api.hs:187-200` +
   `ErrorClass.hs:96-110` — the claude SDK's `ssePostJSON` converts every non-2xx
   into `Left "HTTP error <code>: <body>"` *text*; the worker wraps it as
   `Messages.Error {error = Aeson.String txt}` and `classifyErrorValue` returns
   `Nothing` for non-object values. `responseToError` / `fromClientError` are dead
   code outside the tests. **A real 429/500/529/401 yields `errorInfo = Nothing`**
   — no `RateLimited`, no `retryAfterSeconds`, `isRetryable` unusable. The unit
   tests pass because they feed the classifier shapes the runtime never produces.
2. **[major]** `baikai-openai/src/Baikai/Provider/OpenAI/ErrorClass.hs:57-79` —
   same disease: the SDK's SSE path never produces a `FailureResponse`, so the
   HTTP-status/Retry-After mapping is dead code; a 429 whose body lacks the
   sniffed phrases classifies as `OtherError`, `isRetryable = False`.
3. **[major]** `baikai-claude/src/Baikai/Provider/Claude/Api.hs:186-196` — network
   failures from the streaming path are `HttpException` (http-client), but
   `classifyException` only matches servant `ClientError`; the
   `ConnectionError → TransientError` branch is unreachable. Connection resets are
   classified permanent.
4. **[major]** both providers, e.g. `baikai-openai/.../Api.hs:136,176-179` and the
   claude twin — `resolveKey` (throws `BaikaiError` when the env var is unset) and
   `parseBaseUrl` run inside `Stream.concatEffect` with no catch. With no API key,
   `streamRequest` **throws mid-iteration and emits zero events**, violating the
   documented "exactly one terminal event" contract.
5. **[major]** `baikai/src/Baikai/Stream.hs:313-335` — `liftCompleteToStream`
   always emits `EventDone` and drops `Response.errorInfo`, so an error-shaped
   `Response` from a `complete` handler streams as a *success* terminal;
   `Baikai.Trace` then logs `CallFinished` instead of `CallFailed`.
6. **[design, high]** Split-brain error channel: API providers report failures
   in-band (`stopReason = ErrorReason` + `errorInfo`, never thrown), while
   unregistered-tag dispatch and both CLI providers `throwIO`. `baikai-effectful`'s
   haddock ("the blocking path throws BaikaiError") is wrong for API providers.
   Pick one contract — either `IO (Either BaikaiError Response)` or always-in-band
   — enforce `stopReason == ErrorReason ⟹ isJust errorInfo`, and add
   `responseError :: Response -> Maybe BaikaiError`.
7. **[minor]** `baikai-openai/.../Api.hs:946` — `finish_reason "content_filter"`
   maps to `ErrorReason` but is emitted as `EventDone` with no error info; unknown
   finish reasons collapse silently to `Stop`.

## Theme 2 — Extended thinking is broken end-to-end

1. **[major]** `baikai-claude/.../Api.hs:559-567` — `baseTokens` defaults to
   `model.maxOutputTokens` (the *hard cap* in the generated catalog) and the
   thinking budget is added on top, so **any thinking request with default
   `maxTokens` sends `max_tokens` above the model maximum → HTTP 400**.
2. **[major]** `baikai-claude/.../Api.hs:650-655` — thinking always maps to
   `ThinkingEnabled {budget_tokens}`; `budget_tokens` is rejected on
   claude-opus-4-7/4-8-era models (SDK offers `ThinkingAdaptive`, never used),
   while the catalog registers those models `reasoning = True`.
3. **[major]** `baikai/src/Baikai/Stream.hs:172-179` + `:199-202` — stream
   reassembly rebuilds thinking blocks with `signature = Nothing, redacted =
   False` and discards the terminal message's (correct) content. Since API
   providers derive `complete = streamingComplete stream`, **every blocking call
   loses thinking signatures**; replaying the turn sends `signature = ""` → 400.
   `responseId` is likewise hardcoded `Nothing` at `Stream.hs:214` (the event
   algebra can't carry it), so no caller ever sees a provider message id.
4. **[major]** `baikai-claude/.../Api.hs:369-371,419-433,759-767` — redacted
   thinking blocks lose their `data_` payload on receipt, close as
   `redacted = False` with empty text, and `assistantContentToBlock` never emits
   `Content_Redacted_Thinking` on replay → corrupt multi-turn conversations.
5. **[major]** `baikai-openai/.../Api.hs:271-295` — `delta.reasoning_content`
   (DeepSeek) / `delta.reasoning` (OpenRouter) are never parsed; the
   `requiresThinkingAsText` transformer the compat flag documents does not exist.
   deepseek-reasoner streams discard all reasoning output.

## Theme 3 — Usage/cost accounting

1. **[major]** `baikai-openai/.../Api.hs:588-601` — OpenAI's `prompt_tokens`
   *includes* `cached_tokens`, but the mapping sets `inputTokens = prompt_tokens`
   **and** `cacheReadTokens = cached_tokens`, and sums all three into
   `totalTokens`. `computeCost` then bills cached tokens twice (full input rate +
   cache-read rate). The claude provider treats the fields as disjoint — the two
   providers disagree about what `Usage.inputTokens` means. Fix the OpenAI mapping
   (subtract cached from input) and document the invariant on `Usage`.

## Theme 4 — The compat-quirk system is decorative

1. **[major]** Verified by grep: `maxTokensField`, `supportsDeveloperRole`,
   `requiresThinkingAsText`, `cacheControlFormat`, `supportsUsageInStreaming`,
   `sendSessionAffinityHeaders` are defined in `Compat.hs`, populated by the
   generator, asserted in tests — and **consumed by no provider code**. Either
   implement them or delete them before freezing; a documented flag that does
   nothing is worse than no flag (DeepSeek's `MaxTokensField`, e.g., is silently
   ignored — the SDK only has `max_completion_tokens`).
2. **[minor]** `baikai/src/Baikai/Compat.hs:206` — host auto-detection uses bare
   substring matching: `"z.ai" isInfixOf "https://api.xyz.ai"` is True, so
   unrelated hosts silently inherit Zai/Qwen quirks. Match on the parsed hostname
   suffix instead.

## Theme 5 — Options silently ignored

1. **[major]** Both API providers ignore `Options.timeoutMs`, `Options.headers`,
   and `Model.headers` entirely (`baikai-claude/.../Api.hs:555-598,154-171`;
   `baikai-openai/.../Api.hs:184,744-753`), and the SDKs set `responseTimeoutNone`
   — a stalled host hangs a stream forever with no caller-side bound, and
   gateway/attribution headers never reach the wire.
2. **[major]** `baikai-claude/.../Api.hs:573-584` — `ToolChoiceNone` omits the
   `tools` field, but Anthropic 400s when the conversation already contains
   `tool_use`/`tool_result` blocks and `tools` is absent — the natural "now answer
   without tools" call at the end of a tool loop fails.
3. **[minor]** `baikai-openai/.../Api.hs:734,748` — a hand-rolled `_Model`
   (`maxOutputTokens = 0`) with no `opts.maxTokens` sends
   `max_completion_tokens: 0` → 400. Omit the field when the resolved value is 0.

## Theme 6 — CLI provider robustness

1. **[major]** No `--` separator before the positional prompt anywhere
   (`baikai-claude/.../Cli.hs:164-172`, `Interactive.hs:48-57`,
   `baikai-openai/.../Cli.hs:129`, `Interactive.hs:60`). Empirically verified: a
   prompt starting with `-` errors (`unknown option`), and claude's **variadic**
   flags (`--allowedTools`, `--add-dir`) swallow the following positional — with
   `ClaudeAllowedTools`, the user's prompt is consumed as an allowed-tool name.
2. **[major]** `baikai-openai/.../Cli.hs:157-159` — stdout is drained to EOF
   before stderr is read, with no concurrent reader; if `codex exec` writes >64KB
   to stderr first, parent and child deadlock permanently.
3. **[major]** `baikai-openai/.../Cli.hs:120` — the codex CLI provider renders
   only `ctx.messages`; **`ctx.systemPrompt` is silently dropped** (the
   interactive launcher handles it; the batch provider doesn't).

## Theme 7 — Trace / call-log workers

1. **[major]** `baikai/src/Baikai/Trace.hs:117-124` + `:194-200` (found
   independently by two reviewers) — the forked sink-drain worker has no exception
   handling; a throwing sink (unwritable `fileSink` path, OTel exporter error)
   kills the worker before `putMVar done`, and `cleanupTrace`'s `takeMVar` **hangs
   the caller's request path** (or dies as `BlockedIndefinitelyOnMVar`). Same
   pattern in `Baikai/Cost/Log.hs:188-200` (`closeCallLog` hangs, entries silently
   dropped). Wrap the worker body in `try` and always `putMVar`.
2. **[minor]** `Trace.hs:336-341` — event ids mask the counter to 16 bits;
   after 65,536 traced calls ids repeat, and the OTel sink's `Map Text Span` will
   clobber/close the wrong live span.
3. **[minor]** `Trace.hs:138-140` — on consumer early-abort no
   `CallFailed`/`CallFinished` is emitted, leaving permanently open spans.

## Theme 8 — baikai-kit

1. **[major, security]** `baikai-kit/src/Baikai/Kit/Install.hs:162,185-196` —
   manifest-supplied `path` / `files` / `name` are joined with `</>` with no
   `..`/absolute-path sanitization (`</>` discards the base when the right side is
   absolute). A malicious or compromised kit repo gets zip-slip write
   (`files: ["../../../../.zshenv"]`) and `uninstallItem`'s
   `removeDirectoryRecursive` can be steered outside the install root. Reject
   absolute paths and any component that escapes the target after normalization.
2. **[major]** `Kit/Status.hs:56-65` — an item that is both outdated and locally
   modified reports only `outdated`; a re-install silently overwrites local edits.
3. **[minor]** `Kit/Status.hs:124-145` — installed-but-delisted items classify
   `KitUnknown` even when a valid sidecar exists on disk (sidecar lookup is keyed
   off the manifest, not the scan).
4. **[minor]** `Kit/Install.hs:160-189` — multi-provider install has no failure
   isolation/rollback: a mid-loop failure leaves a half-installed item.
5. **[minor]** `Kit/Sidecar.hs:58-67` — agent sidecar path built by suffix-
   chopping + `<>` concatenation; works for the current two providers by luck.
6. **[minor]** `Kit/Repo.hs:46-56` — failed `git pull` is a warning; `update`
   prints success while serving stale content.
7. **[minor]** `Kit/Install.hs:294-301` — frontmatter stripping breaks on CRLF
   files; YAML leaks into the Codex TOML `developer_instructions`.

## Theme 9 — Tool-schema fidelity (Claude)

1. **[major]** `baikai-claude/.../Api.hs:667-674` — despite the "passed through
   verbatim" doc, the SDK's `functionTool` keeps only `properties`/`required`:
   `additionalProperties`, `$defs`/`$ref`, top-level `enum` are dropped, and a
   schema with no `"properties"` key (e.g. a no-arg tool `{"type":"object"}`)
   becomes a phantom parameter named `type`. Build the `Tool` value directly
   instead of going through `functionTool`.

## Theme 10 — Smaller core items

1. **[minor]** `Stream.hs:305-307` — `tryAny = try @SomeException` catches
   *async* exceptions; `timeout`/`cancel`/Ctrl-C during a lifted `complete` call
   is swallowed into an `EventError` and cancellation is defeated. Use a
   sync-only catch (rethrow `SomeAsyncException`).
2. **[minor]** `Stream.hs:100,303` and `baikai-openai/.../Api.hs:703-715` — the
   no-provider and request-mapping-failure streams emit a lone `EventError` with
   no preceding `EventStart`, contradicting the documented protocol (one package
   test asserts the deviant shape).
3. **[minor]** `Stream.hs:222-236` — the missing-`End` recovery path appends
   dangling buffers after all closed blocks (index order lost) and silently drops
   unclosed tool-call argument buffers.
4. **[minor]** `Stream.hs:203-207` — `latencyMs` trusts provider timestamps,
   unclamped; can go hugely negative.
5. **[minor]** `Baikai/Embedding.hs:95` — `V.head` on the embeddings vector is
   partial; an empty `data` array crashes instead of returning a typed error.
6. **[minor]** `baikai-openai/.../Api.hs:183` — a fresh TLS `Manager` per request:
   no connection reuse, fd churn under load. Cache per base URL.
7. **[minor]** `baikai-openai/.../Api.hs:313` — tool-call deltas missing `index`
   default to 0, merging parallel tool calls from hosts that omit it into one
   corrupt call.
8. **[minor]** `baikai-openai/.../Api.hs:196-199` — `resolveKey` falls back to
   `OPENAI_API_KEY` for *every* host, including DeepSeek/OpenRouter/Together
   catalog models → your OpenAI secret is sent to a third-party host and you get a
   confusing 401. Per-host env mapping (or refuse to fall back for non-OpenAI base
   URLs) would prevent the credential leak.
9. **[minor]** `baikai/fetch/FetchModelsCore.hs:522-524` — hand-rolled JSON string
   escaping misses control characters; `gen/GenModels.hs:336-360` — no identifier-
   collision check after sanitization.

---

## API design recommendations (pre-freeze)

Ordered by impact; items 1–5 are the ones worth doing before building on the
library.

1. **Unify the error contract** (Theme 1.6 above) — one channel, one invariant,
   `responseError` accessor.
2. **Add the tool round-trip loop helper** — every example hand-writes the
   two-turn dance; real agents need N turns:
   `runToolLoop :: Int -> (ToolCall -> IO ToolResult) -> Model -> Context -> Options -> IO (Context, Response)`.
3. **Smart constructors for the 90% case** — `contextOf :: [Message] -> Context`,
   `addUser`, `addResponse :: Response -> Context -> Context`, a one-shot
   `completeText :: Model -> Text -> IO Text`. And **export
   `flattenAssistantText`** — README and getting-started already advertise it, it
   is not exported, and two test modules reimplement it.
4. **Fix the timestamp lie** — the pure `user`/`assistant`/`toolResult` helpers
   stamp `2000-01-01` and the docs use them for real calls. Either make
   `timestamp :: Maybe UTCTime` (providers stamp on send) or rename the pure trio
   `*Fixture` and promote `userNow` in docs.
5. **Stop exporting constructors for evolvable records** (`Options`, `Context`,
   `Model`, compat records, CLI configs) — the empty-base pattern already assumes
   construction-by-update; exporting constructors makes every field addition a
   silent downstream break and a PVP major bump.
6. **Registry ergonomics** — export first-class `ApiProvider` values
   (`claudeMessagesProvider`, …) + `newProviderRegistryFrom :: [ApiProvider] -> IO
   ProviderRegistry`; standardize the `register`/`registerWith`/
   `registerWithRegistry` naming ladder ("With" currently means two different
   things); add `assertRegistered :: ProviderRegistry -> [Api] -> IO ()` for
   startup preflight.
7. **Offer streamly-free streaming conveniences** —
   `streamRequestEach :: (AssistantMessageEvent -> IO ()) -> ... -> IO Response`
   so casual consumers don't inherit the streamly dependency; keep the Stream form
   for power users.
8. **Rename `_Context`/`_Options`/`_Model`** — `Baikai.Prelude` re-exports all of
   lens, where `_X` means *prism*; `emptyContext`/`defaultOptions` (or a `Default`
   class) reads correctly. Give `Context` its lawful Monoid while at it.
9. **Auth**: add `ApiKeyEnvChain [String]` (smoke tests already hand-roll env
   fallback chains — evidence the surface is too narrow).
10. **Model construction**: `mkModel :: Api -> Text -> Text -> Model` demanding
    the discriminators; `_Model`'s blank `api = Custom ""` dispatches to a
    never-registered tag with a confusing error. Delete the `unModel` migration
    shim before freeze.
11. **Options gaps**: add `topP`, `stopSequences`, `seed`, penalties now (all
    `Maybe`), or fix item 5 first so adding them later is cheap.
12. **Export hygiene**: move `Baikai.Provider.Cli.Internal`, provider
    `ErrorClass` modules, and `mapRequest` behind an `.Internal` namespace with a
    no-PVP-guarantees note; decide whether the `Baikai` umbrella intentionally
    omits `Baikai.Trace`/`Baikai.Embedding` and say so; trim or internalize
    `Baikai.Prelude` (re-exporting all of Control.Lens is a PVP time bomb).
13. **Doc drift sweep**: unregistered dispatch throws `BaikaiError`
    (`ProviderUnavailable`), not "`ProviderError`"; env fallbacks are
    `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`, not `OPENAI_KEY`/`ANTHROPIC_KEY`;
    `latencyMs` is `Integer`, not `Int`; "published on Hackage" vs "not yet on
    Hackage" disagree between README and getting-started; docs say "0.1 API",
    cabal says 0.2.
14. **Consistency nits**: `Vector` vs list (`Model.input`, `extraArgs`,
    `extraDirs`), `Interactive.model` should be `modelId`, `timeoutMs :: Maybe
    Int` vs `latencyMs :: Integer`.

## What was checked and found clean

`computeCost` arithmetic and Rational handling; `Cost`/`Usage` monoid laws;
registry atomicity; delta-append ordering in reassembly; Api/StopReason/ToolChoice
JSON round-trips; base64 image round-trip; generated catalog values vs generator
logic; CLI JSONL parsing; Auth env-var fallback error typing; the effectful
interpreters (terminal-event guarantee preserved; one latent note:
`StreamEach` uses `localSeqUnliftIO`, coupling it to sequential draining);
`computeKitHash` (order-independent, length-delimited).
