# Bundle Update Log

## 2026-08-27

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
