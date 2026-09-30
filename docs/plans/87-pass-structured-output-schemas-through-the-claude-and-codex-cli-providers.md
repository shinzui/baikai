---
id: 87
slug: pass-structured-output-schemas-through-the-claude-and-codex-cli-providers
title: "Pass structured-output schemas through the Claude and Codex CLI providers"
kind: exec-plan
created_at: 2026-09-30T13:31:17Z
intention: "intention_01m3s80g1we2g838gqcyxsw4d1"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-30T13:31:17Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-30T13:40:44Z
      mode: "implement"
      note: "Milestones implemented: CLI schema passthrough and StructuredOutputSupport"
---


# Pass structured-output schemas through the Claude and Codex CLI providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai lets a program ask a model for output that matches a JSON Schema by setting
`Options.responseFormat` to `Just (JsonSchema …)`. On the metered HTTP APIs (Anthropic
Messages, OpenAI Chat Completions, OpenAI Responses) the schema is sent to the provider,
which enforces it. On the two subscription command-line providers — `claude -p`
(`Baikai.Provider.Claude.Cli`) and `codex exec` (`Baikai.Provider.OpenAI.Cli`) — the option
is silently ignored today, so the model free-writes its answer and a typed caller gets
shape errors. Mina's evaluation of 62 judge runs through `codex-cli` failed 43 of them this
way (`SchemaMismatch "concerns.[0]: expected object, got string"`). This plan closes
improvement request IR-11
([docs/improvement-requests/pass-structured-output-schemas-through-the-cli-providers.md](../improvement-requests/pass-structured-output-schemas-through-the-cli-providers.md)).
The Shikumi half, `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-4`, depends on
this plan's release.

After this change:

1. A request carrying `JsonSchema` through the Claude CLI provider runs
   `claude -p … --json-schema '<schema>' …` and returns the tool's validated structured
   output as the response text.
2. The same request through the Codex CLI provider writes the schema to a temporary file,
   runs `codex exec … --output-schema <file> …`, returns the final agent message (the JSON
   the tool enforced), and deletes the file afterwards whether the call succeeded, failed,
   or threw.
3. A caller can ask, without spawning anything, whether a transport natively enforces a
   JSON schema: the new `Baikai.ResponseFormat.StructuredOutputSupport` value is available
   both from the registered provider (`ApiProvider.structuredOutput`) and from a model's API
   tag (`declaredStructuredOutput (model ^. #api)`).
4. An installed CLI too old to know the flag produces an error-shaped `Response` whose
   `BaikaiError` has category `InvalidRequest` (not the generic `ProcessFailure`), keeps the
   exit code, and says which flag was rejected — never a silent fallback to unconstrained
   text.
5. A request with no response format (or with `JsonObject`) produces exactly the argument
   vector it produces today.

You can see it working by running the hermetic test suites (fake `claude` and `codex`
shell scripts record the argument vector and the schema they received) and, optionally, by
the live probe in Validation and Acceptance.


## Progress

- [x] Milestone 1: `StructuredOutputSupport`, `declaredStructuredOutput`, and
      `ApiProvider.structuredOutput` exist in `baikai`; every built-in provider declares its
      value; the shared CLI helpers parse Claude's `structured_output` and recognise an
      unsupported-flag failure. `cabal test baikai:baikai-test` passes with the new cases.
      (2026-09-30: `All 794 tests passed`; vendor providers declare their value in
      Milestones 2 and 3. No test built a `ClaudeCliReport` literal, so none needed editing.)
- [ ] Milestone 2: the Claude CLI provider passes `--json-schema`, returns the structured
      output, and reports an unsupported flag as `InvalidRequest`; hermetic fake-`claude`
      tests prove acceptance items 1, 2, 4 and 5 for Claude.
- [ ] Milestone 3: the Codex CLI provider writes, passes, and always deletes the schema file;
      evidence commits to the schema rather than the random path; hermetic fake-`codex`
      tests prove acceptance items 1, 2, 4 and 5 for Codex.
- [ ] Milestone 4: user guide, capability records CAP-5 and CAP-15, their bundle log,
      CHANGELOG, and IR-11 status describe the new behaviour; `cabal test all` passes
      (including `baikai-smoke:doc-shapes`).
- [ ] Milestone 5: release preparation — package versions and bounds bumped and CHANGELOG
      sections cut; tagging and Hackage upload happen only after the user confirms.


## Surprises & Discoveries

- Observation: with `--json-schema`, `claude -p --output-format json` (Claude Code 2.1.285)
  answers through an internal `StructuredOutput` tool and adds a `structured_output` field to
  the terminal `result` event, alongside a compact JSON copy in `result`. The run takes
  several internal turns and its `stop_reason` is `tool_use`.
  Evidence: live probe on 2026-09-30 with `claude-haiku-4-5-20251001`; the result event
  contained
  `'result': '{"items":[{"label":"Strawberry","level":"low"},{"label":"Mango","level":"high"}]}'`
  and `'structured_output': {'items': [...]}` with `'is_error': False`.
- Observation: with `--output-schema`, `codex exec --json` (codex-cli 0.159.0) emits the
  structured reply as the text of its ordinary final `agent_message` item, so the existing
  JSONL parser already extracts it.
  Evidence: live probe on 2026-09-30:
  `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"items\":[…]}"}}`.
- Observation: the two CLIs reject unknown flags with different wording, both on stderr with
  a non-zero exit. `claude` (commander): `error: unknown option '--bogus-flag'`, exit 1.
  `codex` (clap): `error: unexpected argument '--no-such-flag' found`. A missing schema file
  makes codex print `Failed to read output schema file …` — a different failure that must not
  be classified as "unsupported flag".


## Decision Log

- Decision: expose the capability as a new sum type `StructuredOutputSupport`
  (`NativeJsonSchema | NoStructuredOutput`) in `Baikai.ResponseFormat`, carried as a new
  `ApiProvider` field `structuredOutput` (default `NoStructuredOutput` in `apiProviderWith`)
  and mirrored by a pure `declaredStructuredOutput :: Api -> StructuredOutputSupport` table.
  Rationale: this copies the existing `strengthCeiling` / `Evidence.declaredStrength` pair,
  which callers already understand. The provider value is authoritative for a
  caller-registered `Custom` transport; the pure table answers from a `Model` alone without a
  registry. ADR 0009 (capability facts live in the generated catalog) governs per-model
  generation facts; this is a per-transport fact that does not vary by model id, so a table
  keyed by `Api` tag does not violate it. A `Bool` was rejected because a third state (for
  example "prompt-only JSON mode") may be needed later and a sum can grow within a major.
  Date: 2026-09-30
- Decision: an unsupported-flag failure is an error-shaped `Response` whose `BaikaiError`
  has category `InvalidRequest`, `exitCode = Just n`, and a message beginning
  `"<tool> does not accept <flag>"` followed by the tool's stderr.
  Rationale: `ErrorCategory` is documented as closed and stable ("new HTTP nuances map
  onto an existing member rather than growing this type"), and adding a constructor would be
  a major bump of `baikai`. `InvalidRequest` is truthful — the request asked for something
  this installation cannot do, and retrying as-is will not help — and it is distinct from
  the `ProcessFailure` every other non-zero exit gets, which is what a caller switches on.
  Date: 2026-09-30
- Decision: keep `codexCliCommand`'s signature and add
  `codexCliCommandWith :: CodexCliConfig -> Maybe FilePath -> Model -> Context -> Options -> (FilePath, [String])`,
  whose second argument is the schema file. `codexCliCommand cfg = codexCliCommandWith cfg Nothing`.
  Rationale: the schema file path only exists while a call runs, so the pure renderer
  cannot invent it. Changing the existing signature would be a major bump of
  `baikai-openai` for a preview function. The Haddock of `codexCliCommand` must say it
  renders no `--output-schema` even when `Options.responseFormat` carries a schema.
  Date: 2026-09-30
- Decision: the Codex evidence envelope (the argument vector hashed into
  `requestCommitment`) is rendered with the schema's compact JSON text in the position of
  the temporary file path, by calling `codexCliCommandWith cfg (Just schemaText)` a second
  time.
  Rationale: the random path would make the commitment unreproducible and would not commit
  to the schema, which is the thing that actually crossed the boundary. The configuration
  digest is unaffected: an argv envelope is a JSON array and projects to `null` (see
  `argvEnvelope` in `baikai/src/Baikai/Provider/Cli/Internal.hs`).
  Date: 2026-09-30
- Decision: for Claude, the response text is the `result` string verbatim when it decodes
  to a JSON value equal to `structured_output`; otherwise it is the compact aeson encoding of
  `structured_output`. A successful run with a schema but no `structured_output` field is a
  `DecodeFailure` error.
  Rationale: preferring `result` keeps the tool's bytes unmodified (acceptance item 2) in
  the normal case; falling back to `structured_output` means the enforced value wins if a
  future version puts prose in `result`. Returning prose when the caller demanded a schema
  would be the silent fallback IR-11 forbids.
  Date: 2026-09-30
- Decision: only `JsonSchema` is passed through. `JsonObject` and `Nothing` render nothing
  new; the `strict` flag and the schema `name` have no CLI analogue and are dropped.
  Rationale: IR-11 asks for schema passthrough and byte-for-byte stability otherwise.
  Mapping `JsonObject` to a permissive `{"type":"object"}` (as the Anthropic API adapter
  does) would be rejected by Codex, which submits the schema in strict mode and requires
  `additionalProperties: false`. `NativeJsonSchema` therefore promises schema enforcement,
  not JSON-object mode, and the Haddock says so.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository is a Cabal multi-package project (see `cabal.project`). The packages that
matter here:

- `baikai` — the provider-neutral core. `baikai/src/Baikai/ResponseFormat.hs` defines
  `ResponseFormat` (`JsonSchema JsonSchemaFormat | JsonObject`) and `JsonSchemaFormat`
  (fields `name`, `schema :: Aeson.Value`, `strict`; build with `jsonSchemaFormat name schema`).
  `baikai/src/Baikai/Options.hs` carries it as `responseFormat :: Maybe ResponseFormat`.
  `baikai/src/Baikai/Api.hs` defines the transport tag `Api` with constructors
  `OpenAIChatCompletions`, `OpenAIResponses`, `AnthropicMessages`, `OpenAICompletionsCli`
  (the Codex CLI), `AnthropicMessagesCli` (the Claude CLI) and `Custom Text`.
  `baikai/src/Baikai/Provider/Registry.hs` defines `ApiProvider`, the per-transport handler
  record. Its constructor is not exported; providers start from `apiProviderWith tag stream
  complete` and override fields by lens (`& #strengthCeiling .~ …`). Field selectors are
  exported by name in the module header (`ApiProvider (apiTag, stream, complete,
  describeThinking, strengthCeiling)`). `baikai/src/Baikai/Evidence.hs` defines
  `declaredStrength :: Api -> EvidenceStrength` (around line 784), the pattern this plan
  copies. `baikai/src/Baikai/Error.hs` defines `BaikaiError` (fields `category`, `message`,
  `httpStatus`, `retryAfterSeconds`, `exitCode`, `refusalCategory`) and smart constructors
  `processError :: Int -> Text -> BaikaiError`, `invalidRequest`, `decodeError`.
- `baikai/src/Baikai/Provider/Cli/Internal.hs` — helpers shared by both CLI providers,
  explicitly outside PVP guarantees. Relevant pieces: `ClaudeCliReport` (fields `result`,
  `isError`, `sessionId`, `reportedModel`, `usage`) and `decodeClaudeCliResult`, which finds
  the `"type":"result"` event in `claude -p --output-format json` stdout; `CodexRunReport` and
  `parseCodexJsonlStream`, which folds `codex exec --json` events and concatenates
  `agent_message` text into `message`; `argvEnvelope`, `cliResponseEnvelope`,
  `decodeUtf8Lenient`, `trySync`.
- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` — the Claude CLI provider.
  `claudeCliCommand :: ClaudeCliConfig -> Model -> Context -> Options -> (FilePath, [String])`
  is the pure argv renderer; today it produces
  `["-p"] <> modelArgs <> ["--output-format","json","--no-session-persistence"] <> systemPromptArgs <> effortArgs <> extraArgs <> ["--", prompt]`.
  `runClaudeCli` runs it with the `cradle` library, decodes stdout, and builds the
  `Response` in `mkResponse`. `claudeCliProvider` registers it with
  `& #strengthCeiling .~ Ev.declaredStrength AnthropicMessagesCli`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` — the Codex CLI provider.
  `codexCliCommand` renders
  `["exec"] <> modelArgs <> ["--json"] <> skipGitRepoCheck <> ephemeral <> effortArgs <> extraArgs <> ["--", prompt]`.
  `runCodexCli` spawns it with `System.Process.withCreateProcess`, streams stdout through
  `parseCodexJsonlStream`, drains stderr on a forked thread, and builds the `Response` in
  `consume`. The library's build-depends (in `baikai-openai/baikai-openai.cabal`) do not yet
  include `directory`.
- The HTTP providers that already enforce schemas and must declare `NativeJsonSchema`:
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs`,
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`,
  `baikai-openai/src/Baikai/Provider/OpenAI/Responses.hs` (each sets `#strengthCeiling`
  near line 30–61; set `#structuredOutput` beside it).
- Tests. `baikai/test/CliInternalSpec.hs` pins the shared parsers against recorded tool
  output. `baikai-claude/test/Main.hs` has `batchCommandRenderingTest` and
  `batchEffortRenderingTests` asserting exact `claudeCliCommand` vectors;
  `baikai-openai/test/Main.hs` has the Codex equivalents near lines 800–860.
  `baikai-claude/test/CliEvidenceSpec.hs` (`withFakeClaude`, around line 247) and
  `baikai-openai/test/CliEvidenceSpec.hs` (around line 231) already write a fake executable
  into a temporary directory whose script records its argv with
  `printf '%s\n' "$@" > '<argvPath>'` and prints canned output. New tests reuse that
  technique.
- Docs. `docs/user/cli-providers.md` (section "Limitations", item 3, lists which `Options`
  fields the CLIs honour). Capability records `docs/capabilities/structured-output.md`
  (CAP-5; its "Limits" says "API providers only") and
  `docs/capabilities/subscription-cli-backends.md` (CAP-15), with the bundle log
  `docs/capabilities/log.md`. A fenced `haskell` block in a capability record is compiled by
  `baikai-smoke:test:doc-shapes` against a twin in `baikai-smoke/doc-shapes/Shape/CapN.hs`;
  if you add or change such a block you must change the twin identically.
- The installed tools on the author's machine at planning time: `codex-cli 0.159.0` and
  Claude Code `2.1.285`. `codex exec --help` lists `--output-schema <FILE>`; `claude --help`
  lists `--json-schema <schema>`.

Relevant ADRs (all in `docs/adr/`):

- [0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) and
  [0003](../adr/0003-the-adapter-owns-the-translation-description.md): the adapter that
  builds a request owns the description of what it sent. Here that means the CLI provider
  itself decides and records what the schema became; nothing else re-derives it.
- [0004](../adr/0004-two-digests-commitment-and-configuration.md): `requestCommitment`
  hashes the full request envelope (for a subprocess, the argv) and must be recomputable by
  someone holding the request. This drives the Codex envelope decision above.
- [0005](../adr/0005-what-baikai-deliberately-does-not-do.md): baikai reports what it sent
  and observed; it does not validate schemas and does not own retries or fallbacks. The
  unsupported-flag case therefore returns an error rather than retrying without the flag.
- [0007](../adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md): text
  crossing a process boundary is encoded explicitly as UTF-8. The Codex schema file is
  written as bytes from `Data.Aeson.encode`, never through `Data.Text.IO`.
- [0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md):
  per-model wire facts live in the generated catalog. Read the Decision Log for why a
  per-transport table is still appropriate here.
- [0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md): every capability
  `haskell` block compiles in `doc-shapes`.


## Plan of Work

### Milestone 1 — core vocabulary and shared helpers

In `baikai/src/Baikai/ResponseFormat.hs` add and export:

```haskell
-- | Whether a transport forwards 'JsonSchema' to a mechanism the host enforces.
data StructuredOutputSupport
  = -- | 'JsonSchema' reaches the provider and the provider enforces it.
    NativeJsonSchema
  | -- | 'Baikai.Options.responseFormat' is ignored by this transport.
    NoStructuredOutput
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

declaredStructuredOutput :: Api -> StructuredOutputSupport
```

`declaredStructuredOutput` returns `NativeJsonSchema` for all five built-in constructors
and `NoStructuredOutput` for `Custom _`. Its Haddock must say that `NativeJsonSchema`
covers `JsonSchema` only, that an old CLI may still reject the flag at run time (see the
error below), and that a `Custom` transport's own `ApiProvider.structuredOutput` is the
authoritative answer. Confirm `Baikai.Api` does not import `Baikai.ResponseFormat` (no
cycle). The umbrella `Baikai` module already re-exports `module Baikai.ResponseFormat`.

In `baikai/src/Baikai/Provider/Registry.hs` add the field
`structuredOutput :: !StructuredOutputSupport` to `ApiProvider`, add it to the export list,
default it to `NoStructuredOutput` in `apiProviderWith`, and document it next to
`strengthCeiling` (declare only what the provider delivers).

In `baikai/src/Baikai/Provider/Cli/Internal.hs`:

- Add `structuredOutput :: !(Maybe Value)` to `ClaudeCliReport`, parsed with
  `o .:? "structured_output"` in `parseResultEvent`. Update the recorded-output cases in
  `baikai/test/CliInternalSpec.hs` that construct a `ClaudeCliReport` literal.
- Add `unsupportedFlagError :: Text -> String -> Int -> Text -> Maybe BaikaiError`
  taking the tool name, the flag, the exit code and the decoded stderr. It returns
  `Just ((processError code msg) {category = InvalidRequest})` with
  `msg = tool <> " does not accept " <> flag <> "; upgrade it or unset Options.responseFormat: " <> stderr`
  exactly when stderr contains `unknown option '<flag>'` or `unexpected argument '<flag>'`,
  and `Nothing` otherwise. Export it.

Tests in `baikai/test`: `declaredStructuredOutput` over `[minBound..]`-style enumeration of
the built-in tags plus `Custom "x"`; `apiProviderWith`'s default is `NoStructuredOutput`;
a recorded result event with `structured_output` decodes into `Just` the value and one
without decodes into `Nothing`; `unsupportedFlagError` recognises both stderr spellings
(recorded above in Surprises), rejects `Failed to read output schema file …`, and rejects a
message naming a different flag.

### Milestone 2 — Claude CLI passthrough

In `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`:

- Add `schemaArgs :: Options -> [String]`: for `Just (JsonSchema f)` it is
  `["--json-schema", compact]` where `compact` is the UTF-8 decoding of
  `Data.Aeson.encode f.schema`; otherwise `[]`. Insert it in `claudeCliCommand` after
  `effortArgs opts` and before `extraArgs`.
- In `runClaudeCli`, on `ExitFailure n` when `schemaArgs opts` is non-empty, try
  `Internal.unsupportedFlagError "claude" "--json-schema" n stderr` before falling back to
  `processError`.
- On success with a schema requested, compute the text body with a new function
  `structuredBody :: ClaudeCliReport -> Either BaikaiError Text` implementing the Decision
  Log rule (prefer `result` when it decodes to a value equal to `structured_output`; else
  encode `structured_output`; `Nothing` is `decodeError "claude -p: --json-schema was sent but the result has no structured_output"`).
  Use that body both in `mkResponse` and in the `cliResponseEnvelope` passed to
  `observeClaudeCli`, so the response commitment covers what the caller received. Without a
  schema the existing `r ^. #result` path is unchanged.
- In `claudeCliProvider` set `& #structuredOutput .~ declaredStructuredOutput AnthropicMessagesCli`.
- Update the module Haddock: the provider honours `JsonSchema`, and names the error.

Set `#structuredOutput` on `baikai-claude/src/Baikai/Provider/Claude/Api.hs` too.

Tests in `baikai-claude/test` (a new `StructuredCliSpec.hs` registered in the cabal
`other-modules` and in `Main.hs`, or new cases in `CliEvidenceSpec.hs` — whichever reuses
`withFakeClaude` more cleanly):

- Pure: `claudeCliCommand` with `emptyOptions` and with `responseFormat = Just JsonObject`
  both equal the vector already asserted by `batchCommandRenderingTest`; with a
  `JsonSchema` it contains `"--json-schema"` followed by an argument that
  `Aeson.decode`s to the request's schema, positioned before `extraArgs`.
- Fake process: a nested schema (object with an `items` array of objects whose `level` is
  an enum of `"low"`/`"high"`). The fake prints a result event whose `result` is the
  conforming compact JSON and whose `structured_output` is the same value; the response
  text equals `result` byte for byte and the recorded argv carries the schema.
- Fake process with `structured_output` absent → `DecodeFailure`.
- Fake process that writes `error: unknown option '--json-schema'` to stderr and exits 1 →
  `category = InvalidRequest`, `exitCode = Just 1`.
- The same stderr with no schema requested → `ProcessFailure` (the classification is only
  applied when we sent the flag).
- `claudeCliProvider defaultClaudeCliConfig ^. #structuredOutput == NativeJsonSchema`.

### Milestone 3 — Codex CLI passthrough

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`:

- Add and export `codexCliCommandWith :: CodexCliConfig -> Maybe FilePath -> Model -> Context -> Options -> (FilePath, [String])`,
  rendering `["--output-schema", path]` after `effortArgs opts` and before `extraArgs`
  when given `Just path`. Redefine `codexCliCommand cfg = codexCliCommandWith cfg Nothing`
  and document that it never renders the schema flag.
- In `runCodexCli`, when `opts ^. #responseFormat` is `Just (JsonSchema f)`, wrap the
  existing body in a bracket that creates the file with
  `System.IO.openBinaryTempFile` in `System.Directory.getTemporaryDirectory` (template
  `"baikai-codex-schema.json"`), writes `Data.ByteString.Lazy.hPut h (Aeson.encode f.schema)`,
  closes the handle, runs the call with `codexCliCommandWith cfg (Just path)`, and in the
  release action removes the file, ignoring an `IOException` from `removeFile`. Creating or
  writing the file can itself fail; that must become an error-shaped `Response` through the
  same `exceptionToError` path, not an exception escaping the provider. Add
  `directory ^>=1.3` to the library's build-depends.
- The evidence envelope uses `codexCliCommandWith cfg (Just schemaText)` where `schemaText`
  is the compact schema JSON (Decision Log). The spawned process always uses the real path.
- In `consume`, on `ExitFailure n` when a schema was sent, try
  `Internal.unsupportedFlagError "codex" "--output-schema" n stderr` first. `consume` needs
  a `Bool` (or the schema `Maybe`) argument to know that.
- On success the response text stays `Text.strip (report ^. #message)`; no change.
- Set `& #structuredOutput .~ declaredStructuredOutput OpenAICompletionsCli` in
  `codexCliProvider`, and `NativeJsonSchema` via the table on `Api.hs` and `Responses.hs`.

Tests in `baikai-openai/test` mirroring Milestone 2. The fake `codex` script must capture
the schema before the provider deletes it: loop over `"$@"`, and after `--output-schema`
record the path to one file and `cp` the path's contents to another. Assertions:

- `codexCliCommand` with `emptyOptions` and with `JsonObject` equal today's vectors
  (existing tests near `baikai-openai/test/Main.hs:811` must pass unmodified);
  `codexCliCommandWith cfg (Just "/tmp/s.json")` places the flag before `extraArgs`.
- The copied schema file decodes to the request's nested schema; the response text is the
  fake's `agent_message` JSON unchanged; after `completeRequest` returns,
  `doesFileExist capturedPath` is `False`. Repeat with a fake that exits 3 and check the
  file is still gone.
- Stderr `error: unexpected argument '--output-schema' found` with exit 2 →
  `InvalidRequest`, `exitCode = Just 2`; the same exit without a schema → `ProcessFailure`.
- With evidence requested, the argv envelope digest is identical across two runs of the
  same request (random temp path excluded) — assert via the encoded `request_commitment`
  field that `CliEvidenceSpec` already reads.
- `codexCliProvider defaultCodexCliConfig ^. #structuredOutput == NativeJsonSchema`.

### Milestone 4 — documentation

- `docs/user/cli-providers.md`: add a "Structured output" section before "Limitations"
  showing a `JsonSchema` request through a CLI model, what each tool receives, where the
  text comes from, the `InvalidRequest` unsupported-flag error, that `JsonObject`/`strict`/
  `name` are not forwarded, and how to check `declaredStructuredOutput`. Update Limitations
  item 3 to list `responseFormat` (JSON schema only) among the honoured fields. Code blocks
  in `docs/user` are not compiled by `doc-shapes`, but keep them compilable in form.
- `docs/capabilities/structured-output.md` (CAP-5): replace the "API providers only" limit
  with the CLI behaviour and the capability signal; add `baikai-claude`/`baikai-openai`
  CLI test files to `evidence`. `docs/capabilities/subscription-cli-backends.md` (CAP-15):
  mention schema passthrough. Do not change either record's `haskell` Shape block unless you
  change its `baikai-smoke/doc-shapes/Shape/CapN.hs` twin identically.
- `docs/capabilities/log.md`: append a dated entry by hand (the `okf log add` tool reflows
  every existing entry).
- `CHANGELOG.md` `[Unreleased]` → `### Added`: the passthrough, `StructuredOutputSupport`,
  `declaredStructuredOutput`, `ApiProvider.structuredOutput`, `codexCliCommandWith`.
- `docs/improvement-requests/pass-structured-output-schemas-through-the-cli-providers.md`:
  in its Status section, name this plan
  (`docs/plans/87-pass-structured-output-schemas-through-the-claude-and-codex-cli-providers.md`)
  as the implementing plan. Leave the frontmatter `targetPlan` unchanged: in this request it
  names the originating Mina plan, not a Baikai plan. Set `status: completed` (the value the
  other completed requests in that directory use) only in Milestone 5, once the release
  exists, and append a dated entry to `docs/improvement-requests/log.md` by hand at that
  point.

### Milestone 5 — release preparation

Bump versions per PVP: every change is an addition, so `baikai` 0.7.1.0 → 0.7.2.0,
`baikai-claude` 0.7.0.0 → 0.7.1.0, `baikai-openai` 0.7.0.0 → 0.7.1.0, and raise both
vendors' `baikai` lower bound to `>=0.7.2` (they need the new field). Check whether
`baikai-agent`, `baikai-effectful`, `baikai-kit`, `baikai-trace-otel` need only a
compatible-bound check. Cut the `[Unreleased]` CHANGELOG entries into per-package sections
following the existing headings (e.g. `## [baikai 0.7.1.0] - 2026-09-23`). Stop and ask
the user before tagging (`baikai-0.7.2.0` etc.) or uploading to Hackage; after each upload
poll the Hackage `01-index.tar` for the package before uploading its dependents. Once the
release exists, mark IR-11 `status: completed` and log it as described in Milestone 4.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, inside
the Nix dev shell the project already uses.

Milestone 1:

```bash
cabal build baikai
cabal test baikai:baikai-test --test-show-details=direct
```

Expected: the build succeeds; the new cases (grep for `StructuredOutput` and
`unsupportedFlagError` in the output) pass, and the summary line reads `All N tests passed`.

Milestone 2:

```bash
cabal test baikai-claude:baikai-claude-test --test-show-details=direct
```

Milestone 3:

```bash
cabal test baikai-openai:baikai-openai-test --test-show-details=direct
```

Milestone 4 and final gate:

```bash
cabal test all
```

Expected: every suite passes, including `baikai-smoke:doc-shapes`, whose output ends with
no `doc-shapes: … differ` line.

Commit at each milestone boundary, Conventional Commits style, with both trailers:

```text
feat(cli): pass JSON schemas to claude -p via --json-schema

ExecPlan: docs/plans/87-pass-structured-output-schemas-through-the-claude-and-codex-cli-providers.md
Intention: intention_01m3s80g1we2g838gqcyxsw4d1
```

Staging a `.cabal` file triggers the treefmt pre-commit hook, which may reflow it; accept
the reflow and re-stage.


## Validation and Acceptance

The IR-11 acceptance items map to observable checks:

1. Schema flag present exactly when requested: the fake-process tests in Milestones 2 and
   3 record argv; with `JsonSchema` the Claude argv contains `--json-schema <schema>` and
   the Codex capture file equals the schema; with `emptyOptions` neither flag appears.
2. Nested schema round-trip: the fake returns conforming JSON for the `items`/enum schema
   and the `Response`'s text (use `Baikai.Response.flattenAssistantText`) equals it byte for
   byte.
3. Capability without calling the CLI:
   `declaredStructuredOutput AnthropicMessagesCli == NativeJsonSchema`, and the same from
   `claudeCliProvider … ^. #structuredOutput` and `codexCliProvider … ^. #structuredOutput`;
   a `Custom` provider built with `apiProviderWith` reports `NoStructuredOutput`.
4. Unsupported flag: `InvalidRequest` with the exit code, distinct from `ProcessFailure`.
5. Unchanged without a response format: the pre-existing exact-vector tests in
   `baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs` pass without edits.

Optional live probe (uses the user's subscriptions; small cost). From a scratch directory:

```bash
S='{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"level":{"type":"string","enum":["low","high"]}},"required":["label","level"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}'
claude -p --model claude-haiku-4-5-20251001 --output-format json --no-session-persistence --json-schema "$S" -- "List two fruits, one low one high."
```

Expect a `result` event with `"is_error":false` and a `structured_output` object. To
exercise baikai itself end to end, write a short `cabal repl baikai-claude` session that
registers `Baikai.Provider.Claude.Cli.register`, builds a model with
`#api .~ AnthropicMessagesCli`, sets the schema above on `Options.responseFormat`, and
calls `completeText`; the returned text must decode to that shape. The same with
`Baikai.Provider.OpenAI.Cli.register` and `OpenAICompletionsCli`.


## Idempotence and Recovery

All code and test steps are safe to repeat. The Codex temporary file lives in the system
temporary directory under a unique name from `openBinaryTempFile` and is removed in the
bracket's release action, so an interrupted test leaves at most a stray
`baikai-codex-schema*.json` there, which is harmless. Milestone 5's version bumps are plain
edits and can be reverted with git until a tag is pushed; tagging and Hackage upload are not
reversible and are gated on the user's confirmation.


## Interfaces and Dependencies

New or changed public interface at the end of this plan:

```haskell
-- baikai: Baikai.ResponseFormat (re-exported from Baikai)
data StructuredOutputSupport = NativeJsonSchema | NoStructuredOutput
declaredStructuredOutput :: Api -> StructuredOutputSupport

-- baikai: Baikai.Provider.Registry
-- new field on ApiProvider, exported as a selector and reachable as #structuredOutput
structuredOutput :: ApiProvider -> StructuredOutputSupport

-- baikai: Baikai.Provider.Cli.Internal (non-PVP)
-- ClaudeCliReport gains: structuredOutput :: Maybe Value
unsupportedFlagError :: Text -> String -> Int -> Text -> Maybe BaikaiError

-- baikai-openai: Baikai.Provider.OpenAI.Cli
codexCliCommandWith :: CodexCliConfig -> Maybe FilePath -> Model -> Context -> Options -> (FilePath, [String])
```

`claudeCliCommand` and `codexCliCommand` keep their signatures. New library dependency:
`directory ^>=1.3` in `baikai-openai`. No new external services. The consumer that waits on
this release is Shikumi, via `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-4`;
the originating evaluation is
`mori://shinzui/mina/plans/240-evaluate-plan-judgment-quality-and-verify-the-complete-workflow`.
