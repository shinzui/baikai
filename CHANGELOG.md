# Changelog

All notable changes to baikai are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `baikai`: new exposed module `Baikai.Agent`, the provider-neutral vocabulary
  for an **unattended coding-agent run** — a run with no terminal and no human,
  which owns its own tool loop, may change files inside directories the caller
  authorized, and returns a process result rather than a `Response`. It defines
  `AgentRunRequest` (with a required `workingDir`), `AgentRunResult`, the
  `AgentCapability` profile (`read-only`, `edit-workspace`, `full-access`),
  `AgentSafety`, the `AgentOutputMode` and `AgentCapturedOutput` output
  discipline, the `AgentCommand` renderer/runner boundary with an explicit
  prompt transport, and the `AgentRenderError` / `AgentRunFailure` taxonomies.
- `baikai`: the operator policy ceiling — `AgentCeiling`,
  `defaultAgentCeiling`, `CeilingViolation`, and the pure `applyAgentCeiling`.
  It returns a request unchanged when it is within the ceiling and reports
  every violation when it is not; it never clamps an over-broad request to the
  permitted value. The default ceiling permits read-only and edit-workspace
  authority and refuses full access and raw provider arguments.

  `Baikai.Agent` itself is vocabulary and pure policy algebra only: it spawns no
  process and renders no command-line flags. Those live in the vendor packages
  and in `baikai-agent`, below. The module is deliberately not re-exported from
  the umbrella `Baikai` module, because its field accessors share names with
  `Baikai.Interactive`, so `import Baikai` continues to compile unchanged.
- `baikai-claude`: new exposed module `Baikai.Provider.Claude.Agent` with
  `ClaudeAgentConfig`, `defaultClaudeAgentConfig`, and `claudeAgentCommand`, a
  pure renderer from an unattended `AgentRunRequest` to the `claude` argument
  vector. It maps the capability profile onto `--permission-mode`
  (`plan` / `acceptEdits` / `bypassPermissions`), joins a tool allow-list into
  one `--allowedTools` argument, repeats `--add-dir` per extra directory, always
  emits `-p`, and emits `--no-session-persistence` unless `persistSession` is
  set. The prompt travels on standard input and appears nowhere in the argument
  vector. A request naming a different provider is refused with
  `ProviderMismatch`. Nothing is spawned.
- `baikai-openai`: new exposed module `Baikai.Provider.OpenAI.Agent` with
  `CodexAgentConfig`, `defaultCodexAgentConfig`, and `codexAgentCommand`, the
  same renderer for `codex exec`. It maps the capability profile onto
  `--sandbox` (`read-only` / `workspace-write` / `danger-full-access`), emits
  `--cd` for the working root, and defaults `--skip-git-repo-check` and
  `--ephemeral` on. A request carrying a tool allow-list is **refused** with
  `UnsupportedToolRestriction`, because `codex exec` has no such flag and running
  it with unrestricted tools would grant more authority than the caller asked
  for. Nothing is spawned.

- `baikai-agent`: **new package** (`0.1.0.0`) holding the unattended
  coding-agent runner. `Baikai.Agent.Run.runAgentCommand` takes an
  `AgentRunRequest` and an already-rendered `AgentCommand` and spawns the tool
  with no terminal and no human present. It delivers the prompt on standard
  input and closes the handle, drains standard output and standard error
  concurrently so a chatty agent cannot deadlock on a full pipe, retains at most
  `outputLimit` bytes per stream while reading and discarding the excess, and
  honors the three output disciplines. Preconditions run before any spawn: a
  missing working directory is `WorkingDirMissing` and unset or empty declared
  variables are `MissingEnvironment`, listing all of them at once. On timeout
  the child's whole process group is interrupted, given a grace period, and then
  terminated, so the agent's own child processes go with it; the failure reports
  the configured limit. A non-zero exit code is a successful run carrying that
  code, not a failure. The runner consumes an already-rendered `AgentCommand`
  and never imports a vendor renderer, so it is exercised entirely with
  hand-written argument vectors. Its POSIX-signal escalation is conditional on a
  non-Windows build.

- `baikai-agent`: new exposed module `Baikai.Agent.Config`, the layered
  configuration layer. `resolveAgentJob` resolves one named job across five
  layers — built-in defaults, the operator file, the repository file, the
  environment, then command-line overrides, later layers winning — and returns
  the resolved `AgentJob` together with a report attributing every value to the
  file, line, and column it came from. `agentJobRequest` converts a job into an
  `AgentRunRequest`, taking the prompt at call time. `listAgentJobs` enumerates
  configured job names, sorted, each attributed to the highest-precedence scope
  defining it. `defaultAgentConfigPaths` locates
  `$XDG_CONFIG_HOME/baikai/agents.kdl` (or `$HOME/.config/baikai/agents.kdl`)
  and `./.baikai/agents.kdl`, with no upward search through parent directories.

  The **policy ceiling** is loaded by a separate function, `loadAgentCeiling`,
  against a separate source list containing the operator file and nothing else:
  no repository file, environment variable, or command-line override can raise
  it. `applyCeilingToJob` refuses an over-broad request with `CeilingRejected`
  rather than clamping it. With no operator file the ceiling is
  `defaultAgentCeiling`. `safety.provider-args` is classified secret and renders
  as `<redacted>` in any report or structured error.

  New dependencies: `settei`, `settei-env`, `settei-kdl`, and
  `settei-optparse-applicative` (all `^>=0.2`, published on Hackage at
  `0.2.0.0`), plus `containers` and `filepath`. `settei-formats` is deliberately
  excluded, because it bundles Dhall loading and repository configuration is
  untrusted input here.

- `baikai-agent`: the **`baikai` executable**, with the `agent run`,
  `agent show`, and `agent list` commands, and the `Baikai.Agent.Cli` module
  that implements them. A shell script now invokes one stable command, supplies
  a prompt on standard input, and selects Claude Code or Codex entirely through
  configuration.

  `agent run` resolves the named job, caps it against the operator ceiling,
  renders it through the vendor renderer for its provider, and spawns it. The
  agent's own exit code passes through unchanged; Baikai's own failures use 64
  and above following the `sysexits` convention — 64 for a usage error or an
  empty prompt, 69 when the executable could not be started, 70 for malformed
  output, 75 for a timeout, 77 for a policy refusal, and 78 for a configuration
  problem. The prompt comes from `--prompt-stdin`, `--prompt-file`, or
  `--prompt`, which are mutually exclusive, and is decoded as UTF-8 explicitly
  rather than through the handle's locale encoding.

  `agent show` performs the whole pipeline except spawning and prints each
  resolved value with the file, line, and column it came from, the policy
  ceiling in force and where it was read, and the exact argument vector that
  would be spawned — with `<redacted>` in place of any raw provider argument. A
  job whose policy is refused prints its configuration first and then the
  refusal. `agent list` enumerates configured jobs and the scope each came from.

  Every Baikai diagnostic goes to standard error. The agent's own output follows
  the job's output mode, so `response=$(baikai agent run job)` yields the
  agent's answer alone for a capturing job. `--set KEY=VALUE` overrides one
  setting of the selected job through `settei`'s own command-line source, so an
  override is attributed with the same fidelity as a file. `--json` emits
  exactly one JSON object per command.

  New dependencies for `baikai-agent`: `baikai-claude`, `baikai-openai`, and
  `optparse-applicative`. The provider packages are needed only so that
  `renderJobCommand`, the single provider dispatch point in the codebase, can
  reach both renderers. This is the first dependency in the workspace from
  `baikai-agent` onto the provider packages, so `baikai-agent` now publishes
  after all three of `baikai`, `baikai-claude`, and `baikai-openai`.

  The user guide `docs/user/unattended-agent-runs.md` documents the whole
  surface: the three commands with their flags, exit codes, and stream
  discipline; the KDL job format and layer precedence; the operator ceiling and
  redaction; the capability mapping tables for both tools; and a before-and-after
  migration of a script that embeds provider flags today.
  `docs/user/cli-providers.md` and `docs/user/interactive-launches.md` link to
  it, and the capability mapping tables moved there from the latter.

- `baikai`: new exposed module `Baikai.Evidence`, the vocabulary for
  **verifiable model-call evidence** — a record of what actually crossed the
  boundary to a provider, as opposed to what the process was configured to ask
  for. It defines `ModelCallEvidence` and the `evidenceSchemaVersion` string
  consumers pin against, `Observed` (a deliberate non-`Maybe` for a value the
  provider either did or did not report, with no function that supplies a
  default), `ThinkingTranslation` with its `ThinkingMode` and
  `ThinkingAdjustment` enumerations describing what a requested
  reasoning-effort level actually became on the wire and every clamp, collapse,
  or drop applied on the way, `EndpointIdentity` and `TransportKind`,
  `CallStatus`, and the ascending `EvidenceStrength` scale.

  It also provides the canonical hashing core: `canonicalEncode` gives a JSON
  value exactly one byte representation (object keys sorted, no insignificant
  whitespace, numbers normalised so `1`, `1.0`, `1.00`, and `1e0` all encode as
  `1`, and a hand-written string escaper so an aeson upgrade cannot silently
  invalidate a recorded digest); `commitmentDigest` hashes a full request
  envelope, and `configurationDigest` hashes an allow-list projection
  (`configurationProjection`) that keeps configuration and replaces content with
  structural summaries, so two calls that ask the same model the same way about
  different subjects agree. The two digests are separate on purpose: the first
  binds a record to a particular request, the second is safe to compare across
  runs that legitimately differ in content.

  Nothing constructs a `ModelCallEvidence` from a real call yet, and no existing
  behaviour changed. New dependencies: `cryptohash-sha256` and
  `base16-bytestring`, both single-purpose packages chosen over a full
  cryptographic framework.
- `baikai`: `Options` gains an `evidence` field carrying an optional
  `EvidenceRequest` — the caller's run identifier, retry provenance, and how
  strictly they need evidence. A call whose `evidence` is `Nothing`, which is
  every call that does not opt in, behaves exactly as it did before: no digest
  is computed and no evidence is emitted.

### Changed

- `baikai`: call identifiers on the trace path are now globally unique.
  `Baikai.Evidence.newCallId` produces 32 lowercase hexadecimal characters
  carrying 128 bits — 48 bits of Unix time in milliseconds, 48 bits of a
  per-process random seed drawn once from `/dev/urandom`, and a 32-bit counter.
  The previous generator combined the process-start *second* with a
  process-local counter into 16 characters, so two processes started within the
  same second emitted identical identifier sequences; its own documentation
  claimed only per-process uniqueness. Identifiers still sort chronologically
  and are still not secrets.

  `Baikai.Trace.newEventId` keeps its name and signature, delegates to
  `newCallId`, and is now deprecated. Anything that pinned the 16-character
  width — a log parser, a fixture, a column type — must widen to 32.
- `baikai`: `renderCeilingViolation` no longer prints the raw provider arguments
  a `ProviderArgsForbidden` violation carries. It reports how many were
  requested and states that their values are not shown. Raw provider arguments
  are the one part of a job description that can hold a credential — the
  configuration layer classifies the setting secret for that reason — and a
  refusal message that quoted them defeated the classification. The constructor
  keeps its `[Text]` payload so a programmatic caller can still inspect it.

- **Breaking:** `baikai-claude`: `claudeInteractiveCommand` now returns
  `Either AgentRenderError (FilePath, [String])` and `launchClaudeInteractive`
  returns `IO (Either AgentRenderError InteractiveLaunchResult)`. A request
  whose `safety` is a `CodexSandbox` policy — which Claude Code cannot express
  — is refused with `SafetyNotExpressible AgentClaude`, naming the rejected
  sandbox mode and approval policy and suggesting `ClaudeAllowedTools` or
  `DefaultSafety`. Previously the policy was silently discarded and an
  **unrestricted** Claude session was started and reported as a success. A
  `Left` means no process was started; a `Right` with a non-zero exit code
  means the session ran and exited non-zero. `DefaultSafety` and an empty
  `ClaudeAllowedTools` list still render no safety flag and are never refused,
  and no previously rendered argument vector changed. Callers must handle the
  refusal branch.
- **Breaking:** `baikai-openai`: `codexInteractiveCommand` now returns
  `Either AgentRenderError (FilePath, [String])` and `launchCodexInteractive`
  returns `IO (Either AgentRenderError InteractiveLaunchResult)`. A request
  whose `safety` is a non-empty `ClaudeAllowedTools` list — which `codex` has
  no flag for — is refused with `SafetyNotExpressible AgentCodex`, quoting the
  rejected tools and suggesting `CodexSandbox` or `DefaultSafety`. Previously
  the allow-list was silently discarded and Codex was started with its default
  sandbox. The same `Left`/`Right` reading applies, `DefaultSafety` and an
  empty allow-list are never refused, and no previously rendered argument
  vector changed. Callers must handle the refusal branch.

  Both changes make the interactive surface honor the same contract as the new
  unattended surface: a safety policy the chosen provider cannot express fails
  visibly instead of silently becoming a weaker policy. Downstream consumers
  must adapt before upgrading; the known one is `shinzui/seihou`, whose
  `Seihou.CLI.AgentLaunchExec` module builds interactive launch requests.

## [baikai-claude 0.4.0.1] - 2026-07-30

### Fixed

- Widened the `crypton` bound from `^>=1.0` to `>=1.0 && <1.2` so consumers can
  build `baikai-claude` alongside packages that require `crypton` 1.1.x (for
  example `pg-migrate-1.1.0.0`), which previously had no solvable build plan.
  The only `crypton` use is `Crypto.Hash` (`Digest`, `SHA256`) in
  `Baikai.Provider.Claude.Transport`, whose API is identical across the 1.0/1.1
  boundary. No API change.

## [baikai 0.4.1.0] - 2026-07-20

### Changed

- Version bump only; no library API or code changes. Released so the umbrella
  release tag `baikai-0.4.1.0` names a fresh core version alongside the breaking
  `baikai-claude` / `baikai-openai` 0.4.0.0 releases, matching the tag
  convention downstream consumers pin against.

## [baikai-claude 0.4.0.0] - 2026-07-20

### Changed

- **Breaking:** `claudeCliCommand` now takes the `Options` record and forwards
  `Options.thinking` to batch `claude -p` as `--effort <level>` (`minimal`
  collapses to `low`, matching the interactive launcher and the claude CLI's
  lack of a `minimal` value). `thinking = Nothing` emits no effort flag, keeping
  existing argv byte-for-byte. The added parameter is a PVP-major signature
  change.

## [baikai-openai 0.4.0.0] - 2026-07-20

### Changed

- **Breaking:** `codexCliCommand` now takes the `Options` record and forwards
  `Options.thinking` to `codex exec` as `-c model_reasoning_effort=<level>` for
  all six effort levels. `thinking = Nothing` emits no override, keeping
  existing argv byte-for-byte. The added parameter is a PVP-major signature
  change.

## [baikai 0.4.0.0] - 2026-07-20

### Added

- Added `ThinkingXHigh` and `ThinkingMax` to the exported `ThinkingLevel`
  vocabulary and added a defaulted `InteractiveLaunchRequest.effort` field.
  Extending the closed sum type is a PVP-major API change for downstream
  exhaustive matches.

## [baikai-claude 0.3.0.2] - 2026-07-20

### Added

- Added `--effort` rendering to interactive Claude Code launches and preserved
  `xhigh` / `max` on native adaptive Anthropic API requests, with larger fixed
  budgets for manual-thinking models.

### Changed

- Bumped the internal `baikai` dependency bound to `^>=0.4.0` for the
  baikai 0.4.0.0 release.

## [baikai-openai 0.3.0.2] - 2026-07-20

### Added

- Added `model_reasoning_effort` overrides to interactive Codex launches and
  preserved `xhigh` / `max` in native OpenAI request JSON; non-native
  OpenAI-compatible request shapes continue to clamp them to `high`.

### Changed

- Bumped the internal `baikai` dependency bound to `^>=0.4.0` for the
  baikai 0.4.0.0 release.

## [baikai-trace-otel 0.3.0.2] - 2026-07-20

### Changed

- Bumped the internal `baikai` dependency bound to `^>=0.4.0` for the
  baikai 0.4.0.0 release. No API changes.

## [baikai-effectful 0.3.0.2] - 2026-07-20

### Changed

- Bumped the internal `baikai` dependency bound to `^>=0.4.0` for the
  baikai 0.4.0.0 release. No API changes.

## [baikai-kit 0.1.0.3] - 2026-07-20

### Changed

- Bumped the internal `baikai` dependency bound to `^>=0.4.0` for the
  baikai 0.4.0.0 release. No API changes.

## [baikai 0.3.1.0] - 2026-07-15

### Added

- Added `claude-sonnet-5` to the Anthropic model catalog (1M context window,
  128k max output, `tool_call` + reasoning).
- Added the `gpt-5.6` family — `gpt-5.6`, `gpt-5.6-luna`, `gpt-5.6-sol`, and
  `gpt-5.6-terra` — to the OpenAI model catalog (chat-completions with
  `tool_call` support).

### Changed

- Corrected `claude-sonnet-4-5` context window to 1M tokens and
  `claude-sonnet-4-6` max output to 128k tokens in the catalog.
- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-claude 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-openai 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-trace-otel 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-effectful 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-kit 0.1.0.2] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai 0.3.0.0] - 2026-07-03

### Added

- Added the documented record-update bases `emptyOptions`, `emptyContext`,
  `emptyModel`, `emptyResponse`, `emptyTool`, `emptyTextContent`,
  `emptyThinkingContent`, `emptyToolCall`, `emptyImageContent`,
  `emptyEmbeddingModel`, plus zero-valued bases `zeroUsage`, `zeroCost`,
  `zeroCostBreakdown`, and `zeroModelCost`.
- Added `firstEmbedding`, a total accessor for OpenAI-compatible embedding
  responses.
- Added `responseError`, `errorResponse`, `httpError`, and
  `parseRetryAfterSeconds` for the in-band error contract.

### Changed

- **Breaking:** Constructors for evolvable records are no longer exported:
  `Options`, `Context`, `Model`, `OpenAICompletionsCompat`,
  `AnthropicMessagesCompat`, and `InteractiveLaunchRequest` are built from
  exported base values plus record updates.
- **Breaking:** The `_X` base values are deprecated in favor of the new
  `empty*` and `zero*` names; the aliases remain for this release.
- **Breaking:** Removed `unModel`; use `mkModel` or `emptyModel` record
  updates.
- **Breaking:** Renamed `InteractiveLaunchRequest.model` to `modelId`.
- **Breaking:** `Response.latencyMs` and trace event `latencyMs` fields are
  now `Int`.
- **Breaking:** `completeRequest` / `completeRequestWith` no longer throw
  `BaikaiError` for unregistered API tags; they return an error-shaped
  `Response`.
- **Breaking:** CLI providers now report subprocess/decode/provider failures
  in-band as error-shaped `Response`s.
- **Breaking:** `errorTerminal` now requires a `BaikaiError`, enforcing
  structured error details for `EventError` construction sites.
- Documented that `Baikai.Prelude` is a convenience module outside the PVP
  stability contract and that `.Internal` modules have no compatibility
  guarantees.

### Fixed

- Empty embedding `data` arrays now produce a typed `decodeError` instead of
  crashing on an empty vector.
- The model-fetch JSON renderer now delegates string escaping to aeson.
- The model generator now fails on sanitized Haskell identifier collisions
  instead of rendering duplicate bindings.
- Live HTTP status, `Retry-After`, and network-failure classification now
  works on both API providers.
- `content_filter` / Anthropic refusals terminate as classified `EventError`
  terminals, and `liftCompleteToStream` preserves error-shaped responses.

## [baikai-claude 0.3.0.0] - 2026-07-03

### Changed

- **Breaking:** `Baikai.Provider.Claude.ErrorClass` moved to
  `Baikai.Provider.Claude.Internal.ErrorClass`.
- **Breaking:** `mapRequest` and pure request-shaping helpers moved from
  `Baikai.Provider.Claude.Api` to
  `Baikai.Provider.Claude.Internal.Request`.
- **Breaking:** `ClaudeCliConfig` and `ClaudeInteractiveConfig` constructors
  are no longer exported; start from their default config values and update
  fields.
- **Breaking:** CLI and interactive `extraArgs` fields are now `[Text]`.

## [baikai-openai 0.3.0.0] - 2026-07-03

### Changed

- **Breaking:** `Baikai.Provider.OpenAI.ErrorClass` moved to
  `Baikai.Provider.OpenAI.Internal.ErrorClass`.
- **Breaking:** `mapRequest` and pure request-shaping helpers moved from
  `Baikai.Provider.OpenAI.Api` to
  `Baikai.Provider.OpenAI.Internal.Request`.
- **Breaking:** `CodexCliConfig` and `CodexInteractiveConfig` constructors are
  no longer exported; start from their default config values and update fields.
- **Breaking:** CLI and interactive `extraArgs` fields are now `[Text]`.

## [baikai-trace-otel 0.3.0.0] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.
- Adjusted to the core trace event `latencyMs :: Int` type.

## [baikai-effectful 0.3.0.0] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.

## [baikai-kit 0.1.0.1] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.

## [baikai 0.2.0.0] - 2026-06-21

### Added

- `Usage`, `Cost`, and `CostBreakdown` now have `Semigroup`/`Monoid`
  instances that add field-by-field, plus `sumUsage :: Foldable f => f
  Usage -> Usage`, so callers can total per-call usage and cost.
  `reasoningTokens` combines as presence-wins (`Nothing` only when both
  operands are `Nothing`).
- A categorised error model: `BaikaiError` is now a record carrying an
  `ErrorCategory` (`AuthError`, `RateLimited`, `ContextOverflow`,
  `InvalidRequest`, `TransientError`, `DecodeFailure`, `ProcessFailure`,
  `ProviderUnavailable`, `OtherError`), an optional HTTP `httpStatus`, a
  `retryAfterSeconds` hint, and a subprocess `exitCode`. New smart
  constructors (`providerError`, `invalidRequest`, `decodeError`,
  `processError`, `rateLimited`, `authError`, `providerUnavailable`),
  the `isRetryable` predicate, and the pure `classifyHttpStatus` /
  `classifyHttpStatusWithBody` helpers let callers implement retry
  policy without parsing error text. `ErrorCategory` and `BaikaiError`
  serialize to JSON.
- `Response` and the streaming `EventError`'s `TerminalPayload` now
  carry `errorInfo :: Maybe BaikaiError`, so a failed `completeRequest`
  (or a drained stream) exposes the structured category/retry hint
  in-band. `Baikai.Stream.Event` gains `doneTerminal` / `errorTerminal`
  constructors.

### Changed

- **Breaking:** `BaikaiError`'s four flat constructors
  (`ProviderError`, `RequestInvalid`, `DecodeError`, `ProcessError`)
  were replaced by the record above. Migrate by lowercasing to the
  smart constructors — `ProviderError "x"` becomes `providerError "x"`,
  `ProcessError n "x"` becomes `processError n "x"`, etc.
- **Breaking:** `Baikai.Stream.Event.TerminalPayload` and
  `Baikai.Response.Response` gained an `errorInfo` field; build
  `TerminalPayload` via `doneTerminal` / `errorTerminal`.

### Fixed

- Restored JSON decoding for `BaikaiError` values with omitted optional
  metadata fields.

## [baikai-claude 0.2.0.0] - 2026-06-21

### Added

- The Anthropic API and `claude -p` CLI providers now classify failures
  into the typed `BaikaiError` categories: HTTP errors (via the caught
  `servant-client` `ClientError`) map status/`Retry-After`/body onto
  `AuthError` / `RateLimited` / `ContextOverflow` / `InvalidRequest` /
  `TransientError`, and mid-stream Anthropic `error` events are
  classified by their error type. The result is surfaced on
  `Response.errorInfo`.

## [baikai-openai 0.2.0.0] - 2026-06-21

### Added

- The OpenAI/OpenAI-compatible API and `codex exec` CLI providers now
  classify failures into the typed `BaikaiError` categories the same way
  as `baikai-claude` (HTTP `ClientError` for status-based errors,
  streamed error text for mid-stream errors), surfaced on
  `Response.errorInfo`.

## [baikai-trace-otel 0.2.0.0] - 2026-06-21

### Changed

- Updated the `baikai` dependency bound to `^>=0.2.0` for compatibility with
  the `baikai 0.2.0.0` breaking API release.

## [baikai-effectful 0.2.0.0] - 2026-06-21

### Changed

- Updated the `baikai` dependency bound to `^>=0.2.0` for compatibility with
  the `baikai 0.2.0.0` breaking API release.

## [baikai 0.1.1.0] - 2026-06-12

### Added

- Added provider-agnostic `ResponseFormat` support on `Options`, including
  plain JSON-object mode and named JSON-schema mode.
- Added `Baikai.Embedding`, an OpenAI `/v1/embeddings` client for text
  embeddings.

## [baikai-claude 0.1.1.0] - 2026-06-12

### Added

- Mapped baikai `ResponseFormat` options onto Anthropic `output_config` for
  Claude API requests.
- Exported `mapRequest` for request-mapping tests and downstream inspection.

## [baikai-openai 0.1.1.0] - 2026-06-12

### Added

- Mapped baikai `ResponseFormat` options onto OpenAI Chat Completions
  `response_format`.
- Exported `mapRequest` for request-mapping tests and downstream inspection.

## [baikai-effectful 0.1.0.0] - 2026-06-12

### Added

- Initial release: effectful binding for baikai with the `Baikai` dynamic
  effect, `complete`, `streamCollect`, `streamEach`, and registry-backed
  interpreters.

## [baikai 0.1.0.0] - 2026-06-04

### Added

- Initial release: unified Haskell interface for working with multiple AI
  providers. Core modules including `Baikai`, `Baikai.Prelude`, `Baikai.Api`,
  `Baikai.Provider`, `Baikai.Provider.Registry`, `Baikai.Response`,
  `Baikai.Stream`, `Baikai.Tool`, `Baikai.Trace`, and the cost/usage modules.
- Depends on released `streamly` (`>=0.11 && <0.13`) and `streamly-core`
  (`>=0.3 && <0.5`) from Hackage, so all dependencies resolve from Hackage.

## [baikai-claude 0.1.0.0] - 2026-06-04

### Added

- Initial release: Anthropic Claude providers for the baikai abstraction,
  wrapping the `claude` package for both the Anthropic API and the `claude -p`
  CLI (`Baikai.Provider.Claude.Api`, `.Cli`, `.Interactive`).

## [baikai-openai 0.1.0.0] - 2026-06-04

### Added

- Initial release: OpenAI providers for the baikai abstraction, wrapping the
  `openai` package for OpenAI's Chat Completions API
  (`Baikai.Provider.OpenAI.Api`, `.Cli`, `.Interactive`).

## [baikai-trace-otel 0.1.0.0] - 2026-06-04

### Added

- Initial release: OpenTelemetry `TraceSink` adapter for baikai
  (`Baikai.Trace.Sink.OpenTelemetry`), emitting one OTel span per provider call
  with GenAI semantic-convention attributes plus baikai cost and latency.
