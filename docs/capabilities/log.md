# Bundle Update Log

## 2026-08-27

* **Update**: CAP-5 (structured output) records that `ResponseFormat`'s schema
  fields moved onto a `JsonSchemaFormat` record inside the `JsonSchema`
  constructor, built with `jsonSchemaFormat`. As fields of a sum they were
  partial selectors that crashed on `JsonObject`; the JSON encoding is unchanged
  and pinned by a test.

* **Update**: CAP-8 (categorised error model) gains a tenth category,
  `ContentFiltered`. OpenAI's `finish_reason: "content_filter"` and Anthropic's
  `refusal` stop both landed in `OtherError`, so a caller wanting to branch on a
  filtered response had to match on the message text; both now carry their own
  category, and `isRetryable` is `False` for it because the content, not the
  transport, is the problem. `StopReason.Aborted` is gone in the same release:
  nothing produced it, and `responseError`, `eventsFor` and `runToolLoop` all
  treated it as success.

* **Update**: CAP-13 (Anthropic Messages backend), CAP-14 (OpenAI Chat
  Completions backend) and CAP-7 (usage and cost accounting) record the
  0.6 surface freeze. Each provider's streaming machinery — the `SseDriver`
  seam, the assembler, the event translator, and on the OpenAI side the chunk
  decoders, the reasoning-tag scanner and the usage mapping — moved from
  `Baikai.Provider.<P>.Api` to `Baikai.Provider.<P>.Internal.Stream`, which is
  exposed for the test suites and carries no stability guarantee; `Api` keeps
  exactly the three public entry points (`register`, the provider value and the
  live stream function). CAP-7's call-log example now starts from
  `callLogConfig`, because `CallLogConfig`'s constructor — like those of
  `ApiProvider`, `ModelCallEvidence`, `EvidenceRequest`, `Tool`,
  `EmbeddingModel`, `OtelSinkOptions` and the three `baikai-agent` records — is
  no longer exported: each is built from an exported base value and refined by
  record update, so a field added in a later release cannot break a call site,
  as `ApiProvider.describeThinking` did in 0.5.0.0.

* **Update**: CAP-9 (call tracing) and CAP-10 (OpenTelemetry span export) record
  the 2026-08 trace-sink hardening. A sink that *blocks* can no longer hold a
  call: `withTrace` waits at most one second for the worker, abandons it rather
  than killing it, reports the stall on stderr and fails the call under
  `EvidenceRequired`. `multiSink` runs each member on its own drain thread, so a
  member that throws or blocks cannot stop delivery to its siblings or skip their
  end-of-stream action — an OpenTelemetry span paired with an unwritable file
  sink used to be opened, never ended and never exported — and a failure names
  each failed member by zero-based index. The terminal event and its evidence
  record are committed as one unit against asynchronous exceptions. CAP-9 now
  states, where a reader meets it, that the synthetic abort terminal is delivered
  from a garbage-collection hook and is not guaranteed before process exit, with
  the drain-to-the-terminal pattern for callers who need the record
  (`docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md`).
  CAP-10 gains `OtelSinkOptions.parentContext`, which nests the call span under a
  span the caller supplies; it is fixed per sink because the fold runs on the
  trace worker thread, where the caller's thread-local context is invisible.

* **Update**: CAP-19 (model-call evidence) records one strength rule where there
  were three, and a provider-declared ceiling. An observed response id now
  counts as correlation, so a host naming its model and response id on every
  chunk but sending no header reaches `model_observed` rather than landing below
  a host that sent only a header. `ApiProvider` gains
  `strengthCeiling :: EvidenceStrength` and the pre-dispatch gate compares
  against it instead of a table keyed by the API tag, which had capped every
  caller-supplied transport at `requested_only`
  (`docs/adr/0003-the-adapter-owns-the-translation-description.md`, revised).

* **Update**: CAP-19 (model-call evidence) and CAP-10 (OpenTelemetry span export)
  record the 2026-08 evidence-truthfulness pass. Records are now
  `baikai.model-call-evidence/2.0`, because two digests cover different bytes:
  `response_commitment` no longer covers baikai's computed cost, which comes
  from the caller's catalog rather than the response, and
  `request_configuration` now summarises `output_config` and `response_format`
  as it already summarised `tools` — a structured-output JSON schema is
  author-written content wherever it appears. An evidence `endpoint` names the
  host the call actually went to rather than `null` when the model carried no
  base URL. On the span side, `gen_ai.response.model` is set only by the
  evidence branch: the terminal branch set it from the requested id and, because
  evidence is pushed first and `addAttributes` replaces a key, overwrote the
  value a provider really did report.

* **Update**: CAP-19 (model-call evidence) records two rules strict mode did not
  have. A caller's thinking level is now recorded on every evidence path — the
  consumer abort, an unregistered provider, a `complete` handler that threw, and
  each provider's `immediateError` — with the abort path asking the registered
  adapter's own describer and the rest spelling the new `not_translated` mode;
  all four used to record the request as `absent`, which
  `docs/adr/0002-requested-translated-observed-are-never-collapsed.md` forbids.
  And a strict call whose provider attaches no record now fails, rather than
  returning a silent success with zero `call_evidence` lines
  (`docs/adr/0014-strict-evidence-means-a-record-exists.md`). The `proves`
  sentences for `StrictEvidenceSpec` and `TraceSpec` are rewritten to what the
  suite actually pins, and the Limits list no longer says `onSinkFailure` awaits
  a replacement — it shipped in 0.5.0.0 — and states the two strict-mode failure
  rules instead.

* **Update**: CAP-21 (kit installer) records the 2026-08 hardening pass. The
  manifest is now checked physically as well as lexically: a source path that
  crosses a symbolic link, or whose canonical form lies outside the kit
  checkout, is refused at install, at the content hash and at status, which
  gains a `refused` state — `git` recreates committed symbolic links, and a kit
  is meant to be plain files. Every library function returns
  `Either KitError a` and only `runKit` exits, so a tool embedding the library
  is no longer terminated by a missing manifest or an offline first clone
  (`docs/adr/0013-library-code-never-calls-exitfailure.md`). Install fidelity is
  fixed in four places: an agent that lists several files installs all of them,
  a failure while renaming files into place restores what was there, temporary
  files carry unique names, and an unsupported manifest `version` is refused.
  `kit update` skips an item whose installed files were edited locally unless
  `--force` is given, using two new sidecar fields. The `interface` list gains
  the four modules the guide tells consumers to use, and Limits gains the honest
  residuals: the check-then-read window, `readSidecar`'s stderr warning, and the
  race between two concurrent installs of one item.

* **Update**: CAP-8 (categorised error model) records that a transport failure
  is classified by *where* it happened rather than what type it is, and that the
  rule is core's — `Baikai.Provider.Transport.Classify`, shared by both HTTP
  providers and available to a third-party one. The Limits list gains three
  entries and loses one: a mid-body reset, a mid-chunk close and a TLS
  termination are `TransientError` while a failed handshake is not; HTTP 413 is
  `ContextOverflow` from the status alone; and an HTTP-date `Retry-After` is now
  converted against the response's `Date` header rather than ignored. Three test
  files are added as evidence — `baikai/test/TransportClassifySpec.hs` and both
  `MidStreamSpec.hs` — and the two provider `ErrorClassSpec` `proves` sentences
  no longer describe a `servant-client` entry point neither package has on the
  chat path.
  `docs/adr/0011-core-owns-transport-failure-classification.md` records why the
  table moved to core and why the phase, not the type, is the key.

* **Update**: CAP-13 (Anthropic Messages backend) no longer says transport
  classification comes from a `servant-client` `ClientError`. It comes from a
  baikai-owned `http-client` SSE transport: a non-2xx from status, `Retry-After`
  and body, and a mid-stream failure from the shared core classifier.

* **Update**: CAP-2 (typed incremental streaming) records what stopping early
  does to the connection, which was previously stated as one guarantee and is
  really three. Abandoning a stream stops the socket read within a bounded
  number of further frames — the hand-off between the provider's worker and the
  consumer is now a bounded queue rather than an unbounded channel — and
  releases the connection at the next major garbage collection; cancelling the
  draining thread, or draining to the terminal, releases it immediately.
  `baikai-claude/test/LifecycleSpec.hs` is added as evidence: it proves each
  strength separately, including the no-GC case.
  `docs/adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md`
  records why they differ and why a liveness flag or a stall deadline cannot
  replace them.

* **Update**: CAP-4 (typed tool calling) records that a tool call cut off by the
  output cap is never dispatched. `ToolCall.arguments` keeps the raw text as a
  JSON string rather than being replaced by an empty object, `isCutOffToolCall`
  names that state, `runToolLoop` stops with the response intact, and
  `appendToolResult` appends an `isError` result. The three layers that close a
  tool call — both provider assemblers and the stream reassembler — now share one
  rule, `Baikai.Content.toolArgumentsFromText`.

* **Update**: CAP-17 (unattended coding-agent runs) and CAP-18 (the `baikai
  agent` command) now describe the timeout as an escalation — interrupt, then
  terminate, then kill, each stage bounded by a grace period and ended early
  once the leader is reaped and no group member remains — and record that the
  output drained before the kill travels back with the failure rather than being
  discarded. Both gain `baikai-agent/test/BinaryTests.hs` as evidence: the first
  cases in this repository that spawn the __built__ executable, which is the
  only way to prove what runtime it ships with. Behind them,
  `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md`
  records why a suite's own `ghc-options` are never evidence about a binary.

* **Update**: CAP-16 (interactive launches) records that the refusal now also
  covers an approval policy the installed `codex` generation rejects.
  `codex --help` at 0.149.1 accepts only `on-request` and `never` for
  `--ask-for-approval`; the older `untrusted` and `on-failure` spellings made the
  CLI exit with a usage error, which reached a caller as a session that ran and
  failed rather than as a refusal.

* **Update**: CAP-22 (agent asset layouts) records that a Codex custom agent's
  instructions body is now rendered as a TOML *literal* multi-line string, so a
  backslash in the body is a backslash. Rendered as a basic string, a body
  containing `\d+` made Codex refuse to load the file with an unknown-escape
  error; `tomllib` rejects the old output the same way. A body a literal string
  cannot hold falls back to a fully escaped basic string.

* **Update**: CAP-6 (text embeddings) records that `EmbeddingModel.apiKey` is now
  `Maybe ApiKeySource`, resolved through the same per-host table as chat calls,
  and that an unknown host refuses rather than sending `OPENAI_API_KEY` to
  whichever host the base URL named. The client also shares the process-global
  connection cache with the chat providers instead of allocating a TLS manager
  per call. The key-resolution and cache-sharing cases in
  `baikai/test/EmbeddingSpec.hs` are added to the record's evidence, which
  narrows — though does not close — the gap the 2026-08-10 entry recorded.

* **Update**: CAP-2 (OpenAI Chat Completions backend) and CAP-3 (Anthropic
  Messages backend) record three transport changes. The base URL is the API
  root, without the version segment: baikai appends the endpoint path itself and
  removes one trailing `/v1` rather than doubling it, and the shapes it will not
  send to — no scheme, a foreign scheme, credentials in the URL, a query string,
  a fragment, or a full endpoint path — are refused as an `InvalidRequest`
  before any key is read from the environment. A redirect is never followed: a
  3xx is the terminal error, because following one would re-send the credential
  to whatever host the `Location` names. And the `ClientEnv` cache is now one
  process-global cache in `Baikai.Http`, shared by both backends and the
  embeddings client and keyed per normalised base URL.

* **Change**: every `## Shape` block is now compiled. `baikai-smoke` gained a
  second test-suite, `doc-shapes`, whose twenty `Shape.CapN` modules hold each
  record's fenced `haskell` block between `-- BEGIN CAP-N` / `-- END CAP-N`
  markers, and whose checker compares the two and fails naming the record, the
  module and the first differing line. The review found twelve blocks that did
  not compile; all twelve were rewritten against the current exports — CAP-4's
  `#tools` on `Context` and `runToolLoop`'s budget-first argument order, CAP-9's
  and CAP-19's missing `Baikai.Trace` / `Baikai.Trace.Sink` imports and
  `fileSink`'s `IO`, CAP-12's usage under `#message`, CAP-13's unexported
  `registerWith`, CAP-14's `mkModel` and host-root base URL, CAP-16's and
  CAP-17's refusal branches (neither `AgentRenderError` nor `AgentRunFailure` has
  an `Exception` instance), CAP-20's `Eff es Response`, CAP-22's
  `InteractiveProjectScope`, and CAP-18's KDL, which the same suite resolves
  through `Baikai.Agent.Config` because configuration is data. CAP-3's Shape is a
  `console` transcript and is skipped. Every block was then regenerated from its
  formatted module, so no record shows Haskell the repository's formatter would
  rewrite. The convention is stated in `index.md` under "Shape blocks".

* **Update**: CAP-17 (unattended coding-agent runs) records that the shipped
  `baikai` executable links the threaded runtime — without it a job's `timeout`
  never fired and a chatty agent could deadlock the run on a full pipe — and that
  the command writes UTF-8 bytes rather than encoding through the locale. CAP-17
  and CAP-18 both move to `baikai-agent 0.2.0.0`.

* **Update**: CAP-2 (typed incremental streaming) records that `EventStart` is
  first without exception: both HTTP providers pre-seed the skeleton before their
  first wire read, so a 401, a rate limit, an in-band error frame and an EOF
  before the first frame each produce `EventStart` then `EventError`.

* **Update**: CAP-3 (generated model catalog) no longer says DeepSeek,
  OpenRouter and Together have JSON but no generated bindings. Every file under
  `baikai/data/models/` is generated; the curation is which models each file
  carries. Its prose also named `Models.claude_sonnet_5`, which is
  `Models.anthropic_claude_sonnet_5`.

* **Update**: CAP-12 (prompt-cache retention) and CAP-14 (OpenAI Chat
  Completions backend) drop the OpenAI Responses 24-hour bucket, which no code
  emits. The OpenAI-compatible provider marks a request only where the host's
  compat record sets `cacheControlFormat` — OpenRouter in the shipped table —
  and `api.openai.com` gets no marker, because Chat Completions caches
  automatically and offers no retention control.

* **Update**: CAP-15 (subscription CLI backends) corrects the `--version` probe
  bound from two seconds to five, which is what `versionProbeMicros` has always
  been. CAP-4 (typed tool calling) adds `Baikai.Context` and
  `Baikai.Provider.Registry` to its `interface` list, without which the Shape
  block names modules the record does not declare. CAP-19 (model-call evidence)
  names `assertEvidencePrecedesTerminal` as the ordering assertion its evidence
  line claimed, and records that the surface freeze reviewed `ErrorCategory` and
  added no evidence case.

## 2026-08-10

* **Add**: Adopt the shared OKF capability profile (okf-profiles
  `coordination/capabilities`, pinned at v0.9.0) and author the initial baikai
  capability catalog: 22 capabilities (CAP-1 … CAP-22) derived from the eight
  packages in `cabal.project`, their exposed modules, the offline test suites,
  the `baikai-smoke` live cases, the ten user guides, and the release history in
  `CHANGELOG.md` and the git tags.

* **Note**: `since` names the version of the **first package listed** in each
  record, because the eight packages version independently and the profile's
  `since` is a single scalar. The convention is stated in `index.md`.

* **Note**: `stability` is mixed rather than uniform. Eighteen records are
  `stable` under the profile's definition — baikai carries every breaking change
  on a PVP-major bump, which the changelog documents release by release. Four are
  `experimental` because their surface sits outside that promise: CAP-17 and
  CAP-18 (`baikai-agent` at 0.1.0.0), CAP-21 (`baikai-kit` at 0.1.0.x), and
  CAP-19, which rests substantially on `Baikai.Provider.Cli.Internal`. `index.md`
  spells out that `stable` here means "breaks come with a major bump", not
  "settled".

* **Note**: gaps the evidence requirement exposed, recorded in the records that
  own them —
  * **CAP-6 (text embeddings)** is the weakest record in the catalog: one
    hermetic request-mapping test, a live test gated behind
    `BAIKAI_EMBEDDING_LIVE=1` that no default run executes, no smoke case, and no
    user guide. `Baikai.Embedding` also sits outside the registry entirely, so
    tracing, cost accounting, and evidence do not cover it.
  * **`fully_observed` is unreachable on every shipped transport** (CAP-19). No
    Anthropic or OpenAI-compatible host echoes the reasoning configuration it
    applied, so the top of the evidence strength scale is currently aspirational
    rather than achievable.
  * **Live behaviour is under-proven by construction.** Everything requiring a
    real provider is in `baikai-smoke`, which skips without credentials. A
    default `cabal test all` proves mappings and mechanics, not round trips.
  * **`baikai-kit 0.1.0.0` was never released** — confirmed against Hackage,
    which lists exactly `0.1.0.1` … `0.1.0.4` for the package; no git tag exists
    either, and the version was bumped to `0.1.0.1` during the first release
    sweep that included it. CAP-21 records `0.1.0.1` as the earliest depend-able
    version and explains why. Every other record's `since` was checked against
    the same registry listing.

* **Note**: two repository-hygiene gaps found while inventorying, since fixed in
  `mori.dhall`: it listed five of the eight packages in `cabal.project`
  (`baikai-trace-otel`, `baikai-kit`, and `baikai-agent` were absent) and nine of
  the eleven files in `docs/user/` (`model-call-evidence.md` and
  `unattended-agent-runs.md` were absent). The capability records cited the real
  paths throughout, so no record changed.
