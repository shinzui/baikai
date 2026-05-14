---
id: 3
slug: interactive-cli-providers-for-claude-and-codex
title: "Interactive CLI providers for Claude and Codex"
kind: exec-plan
created_at: 2026-05-13T23:39:25Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# Interactive CLI providers for Claude and Codex

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a developer using the `baikai` ecosystem can drive two locally installed
command-line assistants — Anthropic's `claude -p` (the Claude Code CLI in non-interactive
mode) and OpenAI's `codex exec` (the Codex CLI in non-interactive mode) — through the same
`Provider` typeclass that the core library exposes. Construction is a one-liner:
`provider <- claudeCli defaultClaudeCliConfig` (from `baikai-claude`) or
`provider <- codexCli defaultCodexCliConfig` (from `baikai-openai`). Sending a request is
`response <- runRequest provider req`. The mechanism is a subprocess invocation managed by
the `cradle` process-wrapper library: arguments are assembled, the CLI is spawned with
stdin closed, the exit code is checked, and the structured output is parsed into a
`Baikai.Response`. For Claude, stdout is captured as a single strict `ByteString` and
decoded with `aeson`. For Codex, stdout is consumed as a `streamly` byte stream, split into
lines, decoded as JSONL, and folded into the final assistant text — no temp file is used.

This ExecPlan **hard-depends on EP-2**. EP-2 creates the two vendor cabal packages
`baikai-claude` and `baikai-openai` (with their HTTP API modules `Baikai.Provider.Claude.Api`
and `Baikai.Provider.OpenAI.Api`); EP-3 adds the CLI provider module to each of those
already-existing packages. EP-3 must not land before EP-2.

A worked example, end-to-end:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
module Demo where

import qualified Data.Text.IO as Text
import qualified Data.Vector as Vector
import Control.Lens ((^.))
import Baikai
import Baikai.Provider.Claude.Cli (claudeCli, defaultClaudeCliConfig)

main :: IO ()
main = do
  provider <- claudeCli defaultClaudeCliConfig
  let req = Request
        { model = Model "sonnet"
        , messages = Vector.fromList
            [Message { role = User, content = "What is 2 + 2?" }]
        , maxTokens = 256, temperature = Nothing, systemPrompt = Nothing
        }
  resp <- runRequest provider req
  Text.putStrLn (resp ^. #content)
  print (resp ^. #latencyMs)
```

Both CLI providers always return `usage = Nothing` and `cost = Nothing` on the resulting
`Response`. The reason is simple: these CLIs are funded by a flat subscription (Claude Pro
or Claude Max for `claude`, ChatGPT Plus/Pro for `codex`), and the underlying tools either
do not report per-call token usage at all or report a zero cost figure that would be
misleading to surface. Token-accounting clients should use the HTTP providers introduced in
later ExecPlans (EP-4 onward). What the CLI providers do report is `content` (the assistant
text), `model` (echoed from the request), `provider` (a stable string identifier), and
`latencyMs` (a real wall-clock measurement around the subprocess call). Model selection is
respected: the `Model` text on the request is forwarded verbatim to `--model` / `-m`, and
unknown model aliases produce a non-zero CLI exit code that is surfaced as
`ProcessError`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-05-13 Confirm EP-2 has landed: `baikai-claude/baikai-claude.cabal` and `baikai-openai/baikai-openai.cabal` both expose their `*.Api` modules.
- [x] 2026-05-13 `cradle`, `streamly`, `streamly-core` are not in the Nix `ghc912` set; added as local `packages:` entries in `cabal.project` (pointing at the hub paths from `mori registry show`). `tests: False` stanzas added for all three so their bundled live suites stay out of `cabal test all`.
- [x] 2026-05-13 Added `aeson`, `bytestring`, `streamly`, `streamly-core` to `baikai/baikai.cabal`. Other listed deps (`cradle`, `directory`, `time`) live in the vendor packages instead — core only carries the streamly JSONL helper, not the cradle invocation.
- [x] 2026-05-13 Created `baikai/src/Baikai/Provider/Cli/Internal.hs` with `renderPrompt`, `maybeApply`, `decodeUtf8Lenient`, `extractAgentMessage`, and `parseCodexJsonlStream`. `cabal build baikai` clean.
- [x] 2026-05-13 Added `aeson`, `bytestring`, `cradle` to `baikai-claude/baikai-claude.cabal` library deps; `baikai`, `time`, `vector`, `text` were already there.
- [x] 2026-05-13 Created `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` exporting `ClaudeCli`, `ClaudeCliConfig`, `defaultClaudeCliConfig`, `claudeCli`; registered in `baikai-claude.cabal` `exposed-modules`.
- [x] 2026-05-13 `ClaudeCliResult` has `FromJSON`; the decoder accepts both the current `[event]` JSON-array shape (codex-cli 2.x) and the legacy single-object shape, throwing `DecodeError` if neither matches.
- [x] 2026-05-13 Added `bytestring`, `process`, `streamly`, `streamly-core` to `baikai-openai/baikai-openai.cabal` library deps.
- [x] 2026-05-13 Created `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` exporting `CodexCli`, `CodexCliConfig`, `defaultCodexCliConfig`, `codexCli`; registered in `baikai-openai.cabal` `exposed-modules`.
- [x] 2026-05-13 Streamly JSONL parser implemented in `Baikai.Provider.Cli.Internal.parseCodexJsonlStream`. Extractor matches the **current** codex-cli `0.130` schema (`item.completed` envelope with `item.type == "agent_message"`) and three legacy schemas.
- [x] 2026-05-13 `cabal build all` clean under GHC 9.12.2.
- [x] 2026-05-13 Smoke tests added to the existing sibling package `baikai-smoke` (per master-plan Surprises note about EP-2's cyclic-deps trap) — vendor packages don't carry their own test stanzas. `findExecutable` gates each CLI case.
- [x] 2026-05-13 `cabal test all`: `baikai-test` 3/3 OK, `baikai-smoke` 4/4 OK (OpenAI API + Claude CLI + Codex CLI live; Claude API skipped — no `ANTHROPIC_KEY`). Observed latencies: claude `sonnet` ≈ 3.5–6.0s, codex default model ≈ 2.8–4.3s.
- [x] 2026-05-13 Master plan EP-3 milestones checked off and the registry row marked Complete.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-13: **`claude -p --output-format json` returns a JSON array, not a single
  object.** The plan's prediction of a top-level object with `result`/`is_error` fields
  was wrong for `claude-code` 2.1.x. The actual stdout is a JSON array of typed events
  (`{"type":"system",...}`, `{"type":"assistant",...}`, `{"type":"rate_limit_event",...}`,
  `{"type":"result",...}`) and the terminal `"type":"result"` event is where `result`
  and `is_error` live. Fixed by extending `decodeResult` in `Baikai.Provider.Claude.Cli`
  to walk the array and pick the `"result"` event; the legacy single-object shape is
  still accepted. Evidence: live invocation of `claude -p --model sonnet --output-format
  json --no-session-persistence 'Reply: pong.'` against `claude-code` 2.1.141.

- 2026-05-13: **Current `codex exec --json` schema uses an `item.completed` envelope.**
  The plan predicted `{"msg":{"type":"agent_message", ... }}`. Reality for `codex-cli`
  0.130 is `{"type":"item.completed","item":{"id":"item_0","type":"agent_message",
  "text":"..."}}` (plus `thread.started`, `turn.started`, `turn.completed`, `error`,
  `turn.failed` envelopes). `extractAgentMessage` now tries the `item.*` shape first
  and falls back through the four legacy shapes the plan documented. Evidence: live
  invocation of `codex exec --json --skip-git-repo-check --ephemeral 'Reply: pong.'`.

- 2026-05-13: **`cradle` requires `-threaded`.** The runtime check inside
  `Cradle.ProcessConfiguration` throws "Cradle needs the ghc's threaded runtime
  system to work correctly. Use the ghc option '-threaded'." Plain `ghc-options:
  -Wall` is not enough; the test-suite needs `-threaded -with-rtsopts=-N`. Added
  those flags to `baikai-smoke/baikai-smoke.cabal`'s test-suite stanza. Any
  downstream consumer that links a binary against `baikai-claude` must do the same.

- 2026-05-13: **The ChatGPT-account variant of `codex` does not expose `gpt-5`,
  `gpt-5-codex`, or `gpt-5.1-codex` as model names.** Passing any of those returns
  exit code 1 with `{"type":"error","status":400,"error":{"type":"invalid_request_error",
  "message":"The 'X' model is not supported when using Codex with a ChatGPT account."}}`
  in stdout JSONL events. The CLI's *built-in default* (when `--model` is omitted)
  works. Implication for the unified `Request`: a CLI provider with a hard-coded
  model name is not portable across user accounts. Resolved by making **the empty
  model string a sentinel** that omits `--model` from both CLI providers and lets
  the binary use its own default. Same change applied to `claudeCli` for symmetry.

- 2026-05-13: **`codex` always writes `"Reading additional input from stdin...\n"` to
  stderr,** even when stdin is closed (we set `std_in = NoStream`). Treat this as
  informational; the process still exits 0 on success. `ProcessError` is only thrown
  on actual non-zero exit, so this doesn't cause false failures, but anyone tailing
  stderr should expect this line.

- 2026-05-13: **Vendor versions in the local hub are newer than the plan's pins.**
  `cradle-0.0.0.0`, `streamly-0.12.0`, `streamly-core-0.4.0`. Updated cabal upper
  bounds to `streamly ^>=0.12` and `streamly-core ^>=0.4`. The streamly API surface
  the plan describes (Stream.unfoldEach, Stream.foldMany, Fold.takeEndBy_,
  Fold.foldl', Unfold.fromList, Stream.mapMaybe) is unchanged across the bump.

- 2026-05-13: **Tasty, not Hspec, in the smoke tests.** The plan's example smoke
  tests use `hspec`, but the Nix `ghc912` set ships `tasty`/`tasty-hunit` (no
  hspec). EP-1 already uses tasty, and the existing `baikai-smoke` test driver
  is a plain `Main` that loops through cases — that is what EP-3 extended. No
  behavioral compromise; the validation criteria (non-empty content, usage
  Nothing, cost Nothing, latency > 0) are checked identically.

- 2026-05-13: **CLI tests live in `baikai-smoke`, not in per-vendor test stanzas.**
  Following the master-plan Surprises note about the cyclic-deps trap. `baikai-smoke`
  already imported both vendor libraries; adding two more cases there was strictly
  additive and reused the existing skip-on-missing-env-var pattern (extended with
  skip-on-missing-binary for the CLI cases).


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the `cradle` process wrapper instead of `process` directly.
  Rationale: `cradle` already provides the exact combinator vocabulary we need (`cmd`, `addArgs`, `setNoStdin`, `setWorkingDir`, `StdoutRaw`, `StderrRaw`) and ensures we capture exit codes, stdout, and stderr in a single call without bespoke pipe plumbing. It is registered in the user's local `mori` hub and used elsewhere in their projects, so consistency is a real benefit.
  Date: 2026-05-13

- Decision: Use `--output-format json` for `claude -p`, and parse `codex exec --json` stdout as a streamly JSONL stream (no temp file).
  Rationale: The Claude Code CLI returns a single, stable JSON object on stdout when `--output-format json` is passed; this is easy to decode with a small `FromJSON` record. For Codex, we previously planned to rely on `-o <FILE>`; that path has been retired in favour of consuming `--json` as a streamly byte stream. The parser splits stdout on newlines, decodes each line with `aeson`, keeps events whose `msg.type` is `"agent_message"`, and folds out the assistant text. The Codex JSONL schema has varied across releases (sometimes the payload is `msg.message`, sometimes `msg.text`), so the parser is written as best-effort: it tries `msg.message` first, then `msg.text`, then a top-level `message`/`text` field, and ultimately returns the last non-empty candidate it saw. Streaming over the handle keeps memory flat on long runs.
  Date: 2026-05-13 (updated 2026-05-13 to drop the temp-file workaround)

- Decision: Switch the Codex parser from a temp-file workaround to a streamly JSONL parser.
  Rationale: The earlier plan used `-o <tmpfile>` to side-step JSONL schema churn, but doing so couples us to a CLI flag that may be removed and forces a synchronous-disk round trip even for short prompts. The streamly approach (a) matches how Codex itself was designed to be consumed, (b) is streaming so memory does not grow with response length, (c) reuses streamly which is already in our stack and is needed by EP-6 (`baikai-trace-otel`), and (d) gives us a single non-blocking pipeline from stdout bytes to `Text`. The trade-off is best-effort schema handling, documented above.
  Date: 2026-05-13

- Decision: Place CLI provider modules inside their respective vendor packages (`baikai-claude`, `baikai-openai`), not in `baikai` core.
  Rationale: EP-2 already established the multi-package layout that splits vendor-specific code out of the core library so that downstream users can depend on only the providers they need. Putting `Baikai.Provider.Claude.Cli` in `baikai-claude` and `Baikai.Provider.OpenAI.Cli` in `baikai-openai` keeps that boundary clean, prevents the core from gaining vendor-specific dependencies (notably `streamly` is only needed for the Codex parser), and keeps each vendor package self-contained. The shared helper module `Baikai.Provider.Cli.Internal` lives in `baikai` so both vendor packages can import it; this is consistent with how each vendor package already depends on `baikai`. See the master plan's Decision Log for the broader layout decision.
  Date: 2026-05-13

- Decision: EP-3 hard-depends on EP-2.
  Rationale: EP-2 owns the creation of the `baikai-claude` and `baikai-openai` cabal packages. EP-3 only adds new modules and `build-depends` entries to those existing packages. Attempting to land EP-3 first would force it to create the vendor packages, duplicating EP-2's scope and making merge order brittle.
  Date: 2026-05-13

- Decision: Flatten multi-turn `req.messages` into a single prompt block in EP-3.
  Rationale: Both CLIs accept a single positional `prompt` argument in non-interactive mode. Full multi-turn conversation support would require either repeated invocations with `--resume <session-id>` (Claude) or interactive event streams (both), both of which are larger surface areas. For EP-3, if `messages` has exactly one `User` message, we send its content verbatim; otherwise we concatenate with `[user]:` / `[assistant]:` markers. Multi-turn first-class support is out of scope and will be reconsidered in a later ExecPlan.
  Date: 2026-05-13

- Decision: Always return `usage = Nothing` and `cost = Nothing` from CLI providers.
  Rationale: These CLIs are funded by flat subscriptions. `claude -p`'s JSON output includes a `total_cost_usd` field, but it is `0` or a misleading approximation when running under a subscription, and `codex exec` does not report tokens at all in `--json` mode reliably. Returning `Nothing` honors the type-level contract that "we do not know the cost for this call" rather than reporting a false zero.
  Date: 2026-05-13

- Decision: Pass `req.model` through verbatim with no validation.
  Rationale: Both CLIs accept short aliases (`sonnet`, `opus`, `haiku`, `o3`, `o4-mini`) and full model names, and the accepted set evolves with each CLI release. Maintaining a parallel allowlist in `baikai` would lag reality. If the user passes an unknown alias, the CLI exits non-zero with a helpful stderr message, which propagates as `ProcessError`.
  Date: 2026-05-13

- Decision: Default `executable` to `"claude"` and `"codex"` (resolved from `PATH`).
  Rationale: Both tools install themselves onto `PATH` by default. An absolute path would be brittle across machines, Nix profiles, and user installations. The `executable` field on each config is a `FilePath` so users with non-standard layouts can override it explicitly.
  Date: 2026-05-13

- Decision: `claudeCli`, `codexCli`, and the `Provider` instance method bodies for both CLI providers are written with `MonadIO m =>` constraints; the IO-typed cradle invocation and streamly fold are wrapped in a single `liftIO` at the top of each instance method.
  Rationale: Match the EP-1 typeclass signature. Forward-compat with a future `baikai-effectful` package. The streamly fold stays in `Fold IO ...` because `streamly`'s fold and the spawned worker live in `IO`; only the outer `runRequest` boundary changes.
  Date: 2026-05-13

- Decision: Empty `req.model` is a sentinel meaning "omit `--model` and let the CLI use its built-in default."
  Rationale: Real CLI installations differ in which model names they accept (the user's ChatGPT-account `codex` refused `gpt-5`, `gpt-5-codex`, and `gpt-5.1-codex` but works fine without `--model`). Hard-coding a model in a portable test or example is a footgun. `Model ""` (empty `Text`) is a natural opt-out that costs the unified type system nothing — `Model` already wraps `Text` per the EP-1 design. Both `claudeCli` and `codexCli` honor the sentinel for symmetry.
  Date: 2026-05-13

- Decision: Took option 3 from the Codex CLI surface section (System.Process + a streamly-driven `Handle`-to-`Stream IO ByteString` adapter) instead of any cradle-handle path.
  Rationale: `cradle 0.0.0.0` exposes only the strict `StdoutRaw` / `StderrRaw` outputs (no streaming `Handle` sink), and `streamly-process` is not registered in `mori`. Option 3 was the cleanest match: `System.Process.createProcess` returns the stdout `Handle`, `handleStream` wraps it with a `BS.hGetSome` loop, and `parseCodexJsonlStream` consumes that stream lazily. `bracket` around the process handle guarantees cleanup on any exception. `Baikai.Provider.Claude.Cli` keeps cradle because it only needs the strict `StdoutRaw`.
  Date: 2026-05-13

- Decision: `claude -p --output-format json` is decoded by walking the top-level JSON array for the `"type":"result"` event, with a fallback to decoding the top-level Object when present.
  Rationale: The current `claude-code` CLI (2.1.x) emits an array of typed events; older builds emitted a single bare object. Both contain the same `result`/`is_error` fields. Accepting both shapes keeps the provider compatible across CLI versions without re-pinning. Evidence is in Surprises & Discoveries.
  Date: 2026-05-13

- Decision: Smoke tests live in `baikai-smoke`, not in per-vendor `test/` directories.
  Rationale: The master plan's Surprises section (EP-2 entry) notes that any test crossing both vendor packages must live in the dedicated `baikai-smoke` package to avoid a back-edge cabal cycle. While the EP-3 plan body still describes vendor-side `test/` stanzas, the master plan supersedes — the cycle would re-emerge if `baikai/baikai.cabal` ever added a test that depends on vendor packages. Extending `baikai-smoke` is additive and reuses its existing skip-on-missing-env-var pattern.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-05-13).** EP-3 shipped: a Haskell program depending on
`baikai-claude` can run `provider <- claudeCli defaultClaudeCliConfig`,
`response <- runRequest provider req`, and receive an assistant text plus a
real wall-clock latency. The analogous program against `baikai-openai` and
`codexCli` works the same way. Both providers honour the `Provider` typeclass
verbatim — they are interchangeable with the API providers introduced in EP-2.

Live evidence (`cabal test all`, no API keys for Anthropic, OPENAI_API_KEY set):

```text
baikai EP-1
  _Request defaults are zero-y:            OK
  TestProvider returns the canned content: OK
  SomeProvider wraps and dispatches:       OK

All 3 tests passed (0.00s)

[baikai-smoke] none of ["ANTHROPIC_KEY","ANTHROPIC_API_KEY"] set; skipping claude-haiku-4-5-20251001.
[baikai-smoke] gpt-4o-mini ok via OPENAI_API_KEY; usage present = True
[baikai-smoke] sonnet ok via /Users/shinzui/.local/bin/claude; latency_ms = 5983
[baikai-smoke] <codex-default> ok via /opt/homebrew/bin/codex; latency_ms = 2825
```

**Lessons.** The plan's biggest miss was both CLIs' JSON schemas: `claude -p
--output-format json` emits an array, not an object; `codex exec --json`
uses an `item.completed` envelope, not the `msg` envelope that older builds
used. Both were caught by running the binaries during M3 validation. Lesson
for future provider-plans: probe the CLI's actual output shape with a one-shot
shell invocation *before* writing the decoder.

The second lesson is the model-portability one. CLI providers can't assume any
specific model name will work across user accounts; `Model ""` as a "use CLI
default" sentinel is a small but load-bearing concession that keeps the smoke
tests portable.

**Gaps.** No dedicated Codex JSONL unit test that feeds canned bytes through
`parseCodexJsonlStream`. The live smoke covers the happy path but would not
catch schema regressions offline. A future ExecPlan that adds golden-test
fixtures for both CLI JSON schemas would close that gap.


## Context and Orientation

This ExecPlan builds on the core types and `Provider` typeclass that the `baikai` core
library defines (created by EP-1), and on the two vendor packages `baikai-claude` and
`baikai-openai` (created by EP-2). For self-containment, the types this plan consumes are
reproduced verbatim here. They live in module `Baikai` (file `baikai/src/Baikai.hs`):

```haskell
newtype Model = Model { unModel :: Text }

data Role = User | Assistant | System

data Message = Message { role :: !Role, content :: !Text }

data Request = Request
  { model :: !Model
  , messages :: !(Vector Message)
  , maxTokens :: !Natural
  , temperature :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  }

data Response = Response
  { content :: !Text
  , model :: !Model
  , usage :: !(Maybe Usage)
  , cost :: !(Maybe Cost)
  , provider :: !Text
  , latencyMs :: !Integer
  }

data BaikaiError
  = ProviderError !Text
  | RequestInvalid !Text
  | DecodeError !Text
  | ProcessError !Int !Text
  deriving (Show)
instance Exception BaikaiError

class Provider p where
  providerName :: p -> Text
  runRequest :: MonadIO m => p -> Request -> m Response
```

The project is now a **multi-package** Cabal workspace rooted at
`/Users/shinzui/Keikaku/bokuno/baikai`. The relevant cabal packages for this plan are:

- `baikai` — the core library (cabal file `baikai/baikai.cabal`, sources under `baikai/src/`).
- `baikai-claude` — Anthropic provider package, created by EP-2 (cabal file
  `baikai-claude/baikai-claude.cabal`, sources under `baikai-claude/src/`). Already exposes
  `Baikai.Provider.Claude.Api`.
- `baikai-openai` — OpenAI provider package, created by EP-2 (cabal file
  `baikai-openai/baikai-openai.cabal`, sources under `baikai-openai/src/`). Already exposes
  `Baikai.Provider.OpenAI.Api`.

Target compiler is `ghc912`; default language is `GHC2024` with project-wide extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`. New
library modules added by this plan are:

- `Baikai.Provider.Cli.Internal` at `baikai/src/Baikai/Provider/Cli/Internal.hs` — shared
  helpers (including the streamly JSONL parser) living in **core** so both vendor packages
  can import them. Each vendor package already declares `baikai` as a `build-depends`
  entry, so the import is free.
- `Baikai.Provider.Claude.Cli` at `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` —
  Anthropic CLI provider, added to the `baikai-claude` package alongside the existing
  `Baikai.Provider.Claude.Api` module.
- `Baikai.Provider.OpenAI.Cli` at `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` —
  OpenAI/Codex CLI provider, added to the `baikai-openai` package alongside the existing
  `Baikai.Provider.OpenAI.Api` module.

New external dependencies are `cradle` (a thin process-wrapper) and `streamly` /
`streamly-core` (used by the Codex JSONL parser). `cradle` is registered in the user's
`mori` hub at `/Users/shinzui/Keikaku/hub/haskell/cradle-project`. The streamly packages
are normally provided by the Nix `ghc912` package set; if either is missing, a
`source-repository-package` stanza (or `cabal.project` `packages:` entry) is added.

The Claude CLI provider does not itself need `streamly` — it parses a single JSON object
on stdout — so `baikai-claude` only picks up `cradle`, `aeson`, `time`, and `directory`.
The Codex CLI provider does need `streamly` and `streamly-core` directly (for line-splitting
the process output stream), and so does `baikai` core (because the shared helper
`parseCodexJsonlStream` is defined in `Baikai.Provider.Cli.Internal`). `baikai-openai`
re-exports the dependency transitively via `baikai`, but declares `streamly` and
`streamly-core` explicitly for clarity.

### Claude CLI surface

The `claude -p` non-interactive mode is invoked like this for a single-turn call:

```bash
claude -p --model sonnet --output-format json --no-session-persistence "What is 2+2?"
```

Flags this plan uses:

- `-p, --print`: print response and exit (non-interactive mode).
- `--model <model>`: model alias (`sonnet`, `opus`, `haiku`) or full name (e.g. `claude-sonnet-4-6`).
- `--output-format <format>`: `text` (default), `json`, or `stream-json`. We choose `json`.
- `--system-prompt <prompt>`: replace the default system prompt.
- `--append-system-prompt <prompt>`: append to the default system prompt (unused by us).
- `--no-session-persistence`: do not save the session to disk (we always pass this).
- positional `prompt`: the user message text.

With `--output-format json`, stdout contains a single JSON object roughly shaped like:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "the assistant's response text",
  "session_id": "abc-123",
  "duration_ms": 1234,
  "num_turns": 1,
  "total_cost_usd": 0
}
```

The only fields we depend on are `result` (the assistant text) and `is_error` (a boolean
indicating CLI-level failure even when the exit code is `0`). `session_id` is decoded
opportunistically for future log enrichment but never required. `total_cost_usd` is read
but discarded: per the contract above, subscription-mode CLI providers always report
`cost = Nothing`.

### Codex CLI surface

The `codex exec` non-interactive mode is invoked like this:

```bash
codex exec --model o3 --json --skip-git-repo-check --ephemeral "What is 2+2?"
```

Flags this plan uses:

- `-m, --model <MODEL>`: model name.
- `--json`: print events as JSONL on stdout, one JSON object per line.
- `--skip-git-repo-check`: allow running outside a Git repository (defaulted to `True`).
- `--ephemeral`: do not persist the session (defaulted to `True`).
- positional `[PROMPT]`: the initial prompt.

We consume the `--json` stdout stream directly with `streamly`. Each newline-delimited JSON
object has approximately the shape:

```json
{"id":"...","msg":{"type":"agent_message","message":"the assistant's text"}}
{"id":"...","msg":{"type":"token_count","total_tokens":123}}
```

The Codex JSONL schema has varied across releases. Some versions place the assistant text
in `msg.message`; older versions used `msg.text`; very early versions placed `type` at the
top level instead of nesting it under `msg`. The parser is therefore **best-effort**: it
keeps any line where `msg.type` (or `type`) is `"agent_message"` and pulls the assistant
text from `msg.message`, then `msg.text`, then the top-level `message` or `text` field,
falling back to the last non-empty candidate seen. The fold concatenates all such payloads
in arrival order; for single-turn requests the concatenation typically contains exactly
one element.

The parser is **streaming**: it does not buffer the entire output. A long `codex exec` run
that produces many JSONL events can be processed with flat memory. The shape of the parser:

```haskell
import qualified Streamly.Data.Stream as Stream
import qualified Streamly.Data.Fold as Fold
import qualified Streamly.External.ByteString.Lazy as StreamlyBL
import qualified Data.Aeson as Aeson

parseCodexJsonl :: Stream IO ByteString -> IO Text
parseCodexJsonl bytes = do
  msgs <- bytes
    & splitLines              -- helper: split ByteString stream on newlines
    & Stream.mapMaybe Aeson.decodeStrict
    & Stream.mapMaybe extractAgentMessage
    & Stream.fold Fold.toList
  pure (Text.concat msgs)
```

**Open implementation decision (process-to-stream bridge).** `cradle`'s `StdoutRaw` is a
strict `ByteString` — it does not yield a stream by itself. There are three viable ways
to feed bytes from the subprocess into the streamly pipeline; the plan recommends the
first that compiles cleanly under our Nix set:

1. If `cradle` exposes a `Handle`-based output sink (any constructor or option that gives
   us a `System.IO.Handle` on the process's stdout), wrap it with
   `Streamly.FileSystem.Handle.read` (from `streamly-core`).
2. If `streamly-process` is registered in `mori` (`mori registry search streamly-process`),
   use it for this one provider and keep `cradle` for `claudeCli`.
3. Otherwise, drop down to `System.Process` (or `typed-process`) for `codexCli`
   specifically, capture the stdout `Handle`, and feed it through
   `Stream.unfoldM (BS.hGetSome h chunkSize)` (or `Streamly.External.Handle.toStream` if
   available). The Claude provider can continue to use `cradle` unchanged.

The implementer should record which path was taken under Surprises & Discoveries. The
recommendation is option 1 if it exists; option 3 is the documented fallback.

### Binary locations

On a developer machine following the user's setup, `claude` and `codex` both live on
`PATH`. The cabal package resolves them at runtime via the `executable` field on each
config, which defaults to the bare string `"claude"` or `"codex"`. The OS (or the `cradle`
runner, via `posix-spawn`/`execvp`) performs `PATH` lookup.


## Plan of Work

The work splits into three milestones. Each ends with a clean `cabal build all` and (for
Milestones 2 and 3) a manual smoke test driving a real subprocess.

### Milestone 1: Cabal wiring and shared helpers in `baikai` core

Scope: make `cradle`, `streamly`, `streamly-core`, `aeson`, `bytestring`, `time`, and
`directory` available to `baikai` core, and introduce a small internal helpers module
(including the streamly JSONL parser) so that `ClaudeCli` and `CodexCli` do not duplicate
prompt-rendering, `Maybe`-application, and JSONL-decoding logic.

First, confirm whether `cradle`, `streamly`, and `streamly-core` are in the Nix `ghc912`
package set:

```bash
nix develop --command ghc-pkg list cradle streamly streamly-core
```

If all three are listed, no `cabal.project` edits are needed. If `cradle` is missing,
append a `source-repository-package` stanza to `cabal.project` at the workspace root
`/Users/shinzui/Keikaku/bokuno/baikai/cabal.project`:

```text
packages:
  baikai
  baikai-claude
  baikai-openai

source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/hub/haskell/cradle-project
  tag: HEAD
```

If `streamly` or `streamly-core` are missing, locate their sources with
`mori registry search streamly` and add analogous `source-repository-package` stanzas (or
local `packages:` entries) pointing at the on-disk paths returned by
`mori registry show streamly --full`. The implementer should remind themselves to verify
the available version against what the Nix set provides; the plan targets
`streamly ^>=0.10` and `streamly-core ^>=0.2` (current as of 2026).

Then update `baikai/baikai.cabal`. The relevant diff against the library stanza:

```diff
 library
   import:           common-settings
   hs-source-dirs:   src
   exposed-modules:
     Baikai
+    Baikai.Provider.Cli.Internal
   build-depends:
       base
     , text
     , vector
+    , aeson
+    , bytestring
+    , cradle
+    , directory
+    , streamly        ^>=0.10
+    , streamly-core   ^>=0.2
+    , time
+    , lens
```

Create `baikai/src/Baikai/Provider/Cli/Internal.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Provider.Cli.Internal
  ( renderPrompt
  , maybeApply
  , decodeUtf8Lenient
  , parseCodexJsonlStream
  , extractAgentMessage
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Function ((&))
import Data.Maybe (fromMaybe)
import Data.Text (Text); import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import qualified Data.Vector as Vector
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseMaybe, (.:), (.:?))
import qualified Streamly.Data.Stream as Stream
import qualified Streamly.Data.Fold as Fold
import Streamly.Data.Stream (Stream)
import Baikai (Message (..), Request (..), Role (..))

-- | Collapse multi-turn messages into a single prompt string. A solitary User
-- message is returned verbatim; otherwise messages are formatted with role tags.
renderPrompt :: Request -> Text
renderPrompt req =
  let msgs = Vector.toList (messages req)
      tag m = case role m of
        User -> "[user]: " <> content m
        Assistant -> "[assistant]: " <> content m
        System -> "[system]: " <> content m
   in case msgs of
        [Message { role = User, content = c }] -> c
        _ -> Text.intercalate "\n" (fmap tag msgs)

-- | Apply a function-of-a-value when the value is Just; used to thread
-- `setWorkingDir` through a cradle pipeline.
maybeApply :: Maybe a -> (a -> b -> b) -> b -> b
maybeApply Nothing _ b = b
maybeApply (Just a) f b = f a b

decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = Text.decodeUtf8With Text.lenientDecode

-- | Best-effort extraction of agent text from one Codex JSONL line. Tries
-- @msg.message@, @msg.text@, top-level @message@, then top-level @text@.
extractAgentMessage :: Aeson.Value -> Maybe Text
extractAgentMessage v = parseMaybe go v
  where
    go = Aeson.withObject "codex-event" $ \o -> do
      mMsg <- o .:? "msg"
      let inner = fromMaybe (Aeson.Object mempty) mMsg
      ty <- case inner of
        Aeson.Object io -> io .:? "type"
        _               -> o   .:? "type"
      case (ty :: Maybe Text) of
        Just "agent_message" -> do
          let pick = case inner of
                Aeson.Object io ->
                  parseMaybe (.: "message") io
                    <> parseMaybe (.: "text")    io
                _ -> Nothing
              top = parseMaybe (.: "message") (asObj v)
                  <> parseMaybe (.: "text")    (asObj v)
          maybe (fail "no payload") pure (pick <> top)
        _ -> fail "not an agent_message"
    asObj (Aeson.Object o) = o
    asObj _                = mempty

-- | Consume a stream of stdout bytes from `codex exec --json`, split on
-- newlines, decode each line as JSON, filter to @agent_message@ events, and
-- return the concatenation of their payloads. Streaming: memory usage is flat
-- in response length.
parseCodexJsonlStream :: Stream IO ByteString -> IO Text
parseCodexJsonlStream bytes = do
  msgs <- bytes
    & splitLines
    & Stream.mapMaybe Aeson.decodeStrict
    & Stream.mapMaybe extractAgentMessage
    & Stream.fold Fold.toList
  pure (Text.concat msgs)

-- | Split a stream of arbitrary chunks on newline boundaries. Implemented as
-- a left fold that buffers a tail. Exposed as a helper here so that vendor
-- packages can substitute a different splitter if their stdout source has
-- already been line-buffered.
splitLines :: Stream IO ByteString -> Stream IO ByteString
splitLines = Stream.foldMany splitLineFold
  where
    -- A streamly fold that consumes bytes until a newline, returning the
    -- complete line (without the newline). See streamly-core docs for the
    -- exact combinator; this is the place to adapt if streamly's API has
    -- shifted between minor versions.
    splitLineFold = Fold.takeEndBy_ (== 0x0a) (Fold.foldl' BS.append BS.empty)
```

Note that the `splitLines` helper above is illustrative — the exact streamly combinator
names have churned across `0.9` and `0.10`, so the implementer should consult the streamly
docs (via `mori registry docs streamly`) to confirm the right `Fold.takeEndBy_` / chunked
splitter for the installed version. The semantic contract is unchanged: emit one
`ByteString` per newline-terminated line.

Acceptance for Milestone 1: `cabal build baikai` succeeds and `Baikai.Provider.Cli.Internal`
appears in `cabal repl baikai` via `:browse`.

### Milestone 2: ClaudeCli provider in `baikai-claude`

Scope: extend the pre-existing `baikai-claude` package (created by EP-2) with the
`Baikai.Provider.Claude.Cli` module and its `Provider` instance. Once this milestone is
done, a Haskell program depending on `baikai-claude` can call `claude -p` through the
abstraction and receive a populated `Response`.

First, update `baikai-claude/baikai-claude.cabal` to expose the new module and pick up the
new dependencies. The diff against the library stanza:

```diff
 library
   import:           common-settings
   hs-source-dirs:   src
   exposed-modules:
     Baikai.Provider.Claude.Api
+    Baikai.Provider.Claude.Cli
   build-depends:
       base
     , baikai
     , text
     , vector
+    , aeson
+    , bytestring
+    , cradle
+    , directory
+    , time
+    , lens
```

Then create `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`:

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Provider.Claude.Cli
  ( ClaudeCli
  , ClaudeCliConfig (..)
  , defaultClaudeCliConfig
  , claudeCli
  ) where

import Control.Exception (throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.Text (Text); import qualified Data.Text as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Vector (Vector); import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import Cradle (StderrRaw (..), StdoutRaw (..), addArgs, cmd, run, setNoStdin, setWorkingDir)
import Baikai (BaikaiError (..), Model (..), Provider (..), Request (..), Response (..))
import Baikai.Provider.Cli.Internal (decodeUtf8Lenient, maybeApply, renderPrompt)

data ClaudeCliConfig = ClaudeCliConfig
  { executable :: !FilePath, extraArgs :: !(Vector Text), workingDir :: !(Maybe FilePath) }
  deriving stock (Generic, Show)

defaultClaudeCliConfig :: ClaudeCliConfig
defaultClaudeCliConfig = ClaudeCliConfig
  { executable = "claude", extraArgs = mempty, workingDir = Nothing }

newtype ClaudeCli = ClaudeCli { config :: ClaudeCliConfig } deriving stock (Generic)

claudeCli :: MonadIO m => ClaudeCliConfig -> m ClaudeCli
claudeCli = pure . ClaudeCli

data ClaudeCliResult = ClaudeCliResult
  { result :: !Text, is_error :: !Bool, session_id :: !(Maybe Text) }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON)

systemPromptArgs :: Request -> [String]
systemPromptArgs req = case systemPrompt req of
  Nothing -> []
  Just sp -> ["--system-prompt", Text.unpack sp]

decodeResult :: ByteString -> IO ClaudeCliResult
decodeResult bs = case eitherDecodeStrict bs of
  Left err -> throwIO (DecodeError (Text.pack err))
  Right r -> pure r

instance Provider ClaudeCli where
  providerName _ = "anthropic.claude.cli"
  runRequest (ClaudeCli cfg) req = liftIO $ do
    let prompt = renderPrompt req
        args = [ "-p", "--model", Text.unpack (unModel (req ^. #model))
               , "--output-format", "json", "--no-session-persistence" ]
            <> systemPromptArgs req
            <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
            <> [Text.unpack prompt]
    start <- getCurrentTime
    (exitCode, StdoutRaw out, StderrRaw err) <-
      run $ cmd (cfg ^. #executable) & addArgs args & setNoStdin
              & maybeApply (cfg ^. #workingDir) setWorkingDir
    end <- getCurrentTime
    case exitCode of
      ExitFailure n ->
        throwIO (ProcessError n (decodeUtf8Lenient err))
      ExitSuccess -> do
        r <- decodeResult out
        if is_error r
          then throwIO (ProviderError (result r))
          else
            let latency = round (1000 * diffUTCTime end start :: Double)
             in pure Response
                  { content = result r, model = req ^. #model
                  , usage = Nothing, cost = Nothing
                  , provider = "anthropic.claude.cli", latencyMs = latency }
```

Acceptance for Milestone 2: the REPL session shown in Concrete Steps below runs against
this provider and prints a non-empty `Text` value for `content r`.

### Milestone 3: CodexCli provider in `baikai-openai`

Scope: extend the pre-existing `baikai-openai` package (created by EP-2) with the
`Baikai.Provider.OpenAI.Cli` module and its `Provider` instance, using the streamly JSONL
parser from `Baikai.Provider.Cli.Internal`. After this milestone, the same kind of smoke
test works against `codex exec`.

First, update `baikai-openai/baikai-openai.cabal` to expose the new module and pick up the
new dependencies. The diff against the library stanza:

```diff
 library
   import:           common-settings
   hs-source-dirs:   src
   exposed-modules:
     Baikai.Provider.OpenAI.Api
+    Baikai.Provider.OpenAI.Cli
   build-depends:
       base
     , baikai
     , text
     , vector
+    , aeson
+    , bytestring
+    , cradle
+    , directory
+    , process
+    , streamly        ^>=0.10
+    , streamly-core   ^>=0.2
+    , time
+    , lens
```

`process` is included so that the implementer can take option 3 from the open
implementation decision documented in the Codex CLI surface section (using
`System.Process.createProcess` to obtain a stdout `Handle`). If `cradle` exposes a
`Handle`-based sink (option 1), `process` is unused and can be dropped from the final
diff.

Then create `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`:

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Provider.OpenAI.Cli
  ( CodexCli
  , CodexCliConfig (..)
  , defaultCodexCliConfig
  , codexCli
  ) where

import Control.Exception (throwIO, bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS
import Data.Function ((&))
import Data.Text (Text); import qualified Data.Text as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Vector (Vector); import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose)
import qualified System.Process as P
import qualified Streamly.Data.Stream as Stream
import Baikai (BaikaiError (..), Model (..), Provider (..), Request (..), Response (..))
import Baikai.Provider.Cli.Internal
  ( decodeUtf8Lenient, maybeApply, parseCodexJsonlStream, renderPrompt )

data CodexCliConfig = CodexCliConfig
  { executable :: !FilePath, extraArgs :: !(Vector Text), workingDir :: !(Maybe FilePath)
  , skipGitRepoCheck :: !Bool, ephemeral :: !Bool }
  deriving stock (Generic, Show)

defaultCodexCliConfig :: CodexCliConfig
defaultCodexCliConfig = CodexCliConfig
  { executable = "codex", extraArgs = mempty, workingDir = Nothing
  , skipGitRepoCheck = True, ephemeral = True }

newtype CodexCli = CodexCli { config :: CodexCliConfig } deriving stock (Generic)

codexCli :: MonadIO m => CodexCliConfig -> m CodexCli
codexCli = pure . CodexCli

-- | Read a handle as a streamly stream of small ByteString chunks. This is
-- the "option 3" fallback from the Codex CLI surface section: drop down to
-- System.Process to obtain a Handle that streamly can drive.
handleStream :: Handle -> Stream.Stream IO BS.ByteString
handleStream h = Stream.unfoldrM step ()
  where
    step _ = do
      chunk <- BS.hGetSome h 4096
      if BS.null chunk then pure Nothing else pure (Just (chunk, ()))

instance Provider CodexCli where
  providerName _ = "openai.codex.cli"
  runRequest (CodexCli cfg) req = liftIO $ do
    let prompt = renderPrompt req
        baseArgs = [ "exec", "--model", Text.unpack (unModel (req ^. #model))
                   , "--json" ]
            <> (if cfg ^. #skipGitRepoCheck then ["--skip-git-repo-check"] else [])
            <> (if cfg ^. #ephemeral then ["--ephemeral"] else [])
            <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
            <> [Text.unpack prompt]
        procSpec = (P.proc (cfg ^. #executable) baseArgs)
          { P.std_in  = P.NoStream
          , P.std_out = P.CreatePipe
          , P.std_err = P.CreatePipe
          , P.cwd     = cfg ^. #workingDir
          }
    start <- getCurrentTime
    bracket
      (P.createProcess procSpec)
      (\(_, _, _, ph) -> P.terminateProcess ph)
      $ \(_, Just hOut, Just hErr, ph) -> do
        body <- parseCodexJsonlStream (handleStream hOut)
        errBytes <- BS.hGetContents hErr
        hClose hOut
        exitCode <- P.waitForProcess ph
        end <- getCurrentTime
        case exitCode of
          ExitFailure n ->
            throwIO (ProcessError n (decodeUtf8Lenient errBytes))
          ExitSuccess ->
            let latency = round (1000 * diffUTCTime end start :: Double)
             in pure Response
                  { content = Text.strip body, model = req ^. #model
                  , usage = Nothing, cost = Nothing
                  , provider = "openai.codex.cli", latencyMs = latency }
```

If at implementation time `cradle` is found to expose a `Handle` sink (option 1), the
`System.Process` plumbing above can be replaced with a `cradle` pipeline that hands
`hOut` to `parseCodexJsonlStream`. The public surface (`codexCli`, `CodexCliConfig`,
`defaultCodexCliConfig`) does not change.

Acceptance for Milestone 3: an analogous `cabal repl baikai-openai` session using
`codexCli` returns a `Response` with non-empty `content`, and the smoke test in
`baikai-openai/test/CodexCliSpec.hs` passes.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai` unless otherwise noted.

Enter the Nix development shell:

```bash
nix develop
```

Verify the compiler and check whether `cradle`, `streamly`, and `streamly-core` are
already available:

```bash
ghc --version
ghc-pkg list cradle streamly streamly-core
```

Expected (the exact patch versions may differ):

```text
The Glorious Glasgow Haskell Compilation System, version 9.12.x
cradle-0.x.y.z
streamly-0.10.x
streamly-core-0.2.x
```

If any are not listed, add the `source-repository-package` (or local `packages:` entry)
shown in Milestone 1 to `/Users/shinzui/Keikaku/bokuno/baikai/cabal.project`.

Build all three packages (`baikai`, `baikai-claude`, `baikai-openai`) and run their test
suites (which skip CLI smoke tests when the binaries are not on `PATH`):

```bash
cabal build all
cabal test all
```

`cabal build all` should compile `baikai` first (because both vendor packages depend on
it), then build `baikai-claude` and `baikai-openai` in either order.

Expected test transcript:

```text
Test suite baikai-claude-test: RUNNING...
  ClaudeCliSpec
    ClaudeCli  returns non-empty content for a one-shot prompt: OK (1.42s)
Test suite baikai-claude-test: PASS

Test suite baikai-openai-test: RUNNING...
  CodexCliSpec
    CodexCli   returns non-empty content for a one-shot prompt: OK (2.13s)
Test suite baikai-openai-test: PASS

All tests passed.
```

(Exact response text and timing vary; each test verifies non-empty `content`, `usage ==
Nothing`, `cost == Nothing`, and `latencyMs > 0`.)

Drive the providers interactively. Because they now live in separate packages, choose the
right `cabal repl` target for each (or use `cabal repl all` if you want both loaded at
once):

```haskell
:set -XOverloadedStrings -XOverloadedLabels
import qualified Data.Vector as Vector
import Baikai
import Baikai.Provider.Claude.Cli
import Baikai.Provider.OpenAI.Cli

let req name = Request
      { model = Model name
      , messages = Vector.singleton (Message User "Say hello in one short sentence.")
      , maxTokens = 64, temperature = Nothing, systemPrompt = Nothing }

pc <- claudeCli defaultClaudeCliConfig
rc <- runRequest pc (req "sonnet")
putStrLn ("claude latency_ms = " <> show (latencyMs rc)) >> print (content rc)

px <- codexCli defaultCodexCliConfig
rx <- runRequest px (req "o3")
putStrLn ("codex latency_ms = " <> show (latencyMs rx)) >> print (content rx)
```

Expected transcript (exact assistant wording will differ; the load-bearing parts are that
both `runRequest` calls return without throwing and that `content` is non-empty):

```text
claude latency_ms = 1842
"Hello! Nice to meet you."
codex latency_ms = 2310
"Hi there!"
```

If either CLI is missing, GHCi will throw a `ProcessError` with the underlying shell's
"command not found" message.


## Validation and Acceptance

Acceptance is defined behaviorally: running a small one-shot prompt through each provider
must return a `Response` value `r` satisfying all four:

1. `Data.Text.null (content r) == False`
2. `usage r == Nothing`
3. `cost r == Nothing`
4. `latencyMs r > 0`

Each smoke test lives next to the provider it exercises. `baikai-claude/test/ClaudeCliSpec.hs`
gates the Claude test on `findExecutable "claude"`, and `baikai-openai/test/CodexCliSpec.hs`
gates the Codex test on `findExecutable "codex"`. The two files share the structure shown
here (split for clarity), and the small helpers (`oneShot`, `checkResp`) can either be
duplicated or factored into a tiny `baikai-testlib` if a later ExecPlan introduces such a
package.

`baikai-claude/test/ClaudeCliSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module ClaudeCliSpec where

import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.Directory (findExecutable)
import Test.Hspec
import Baikai
import Baikai.Provider.Claude.Cli

oneShot :: Model -> Request
oneShot m = Request
  { model = m
  , messages = Vector.singleton (Message { role = User, content = "Reply: ready." })
  , maxTokens = 16, temperature = Nothing, systemPrompt = Nothing
  }

checkResp :: Response -> Expectation
checkResp r = do
  Text.null (content r) `shouldBe` False
  usage r `shouldBe` Nothing
  cost r `shouldBe` Nothing
  (latencyMs r > 0) `shouldBe` True

spec :: Spec
spec =
  describe "ClaudeCli" $
    it "returns non-empty content for a one-shot prompt" $
      findExecutable "claude" >>= \case
        Nothing -> pendingWith "claude not on PATH"
        Just _  -> claudeCli defaultClaudeCliConfig
                     >>= flip runRequest (oneShot (Model "sonnet"))
                     >>= checkResp
```

`baikai-openai/test/CodexCliSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module CodexCliSpec where

import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.Directory (findExecutable)
import Test.Hspec
import Baikai
import Baikai.Provider.OpenAI.Cli

oneShot :: Model -> Request
oneShot m = Request
  { model = m
  , messages = Vector.singleton (Message { role = User, content = "Reply: ready." })
  , maxTokens = 16, temperature = Nothing, systemPrompt = Nothing
  }

checkResp :: Response -> Expectation
checkResp r = do
  Text.null (content r) `shouldBe` False
  usage r `shouldBe` Nothing
  cost r `shouldBe` Nothing
  (latencyMs r > 0) `shouldBe` True

spec :: Spec
spec =
  describe "CodexCli" $
    it "returns non-empty content for a one-shot prompt" $
      findExecutable "codex" >>= \case
        Nothing -> pendingWith "codex not on PATH"
        Just _  -> codexCli defaultCodexCliConfig
                     >>= flip runRequest (oneShot (Model "o3"))
                     >>= checkResp
```

Run the test targets together or individually:

```bash
cabal test all
cabal test baikai-claude-test
cabal test baikai-openai-test
```

Successful output (with both CLIs installed) is the transcript shown in the Concrete Steps
section. When a CLI is missing, the corresponding test becomes a pending result rather than
a failure — this keeps CI green on machines without the binaries while still proving
behavior on developer machines.

Beyond test-suite confirmation, the REPL transcript in Concrete Steps demonstrates effect
beyond compilation: real subprocesses are spawned, latency is measured by a wall clock,
and the assistant text returned by the CLI is surfaced unchanged.


## Idempotence and Recovery

Every step in this plan is safe to re-run. The subprocess invocations are themselves
idempotent by construction: `claude -p` is always passed `--no-session-persistence` so no
session file is written, and `codex exec` is always passed `--ephemeral`. No temp files
are created — the Codex stdout stream is consumed in-memory via streamly — so there is no
on-disk state to clean up between runs. The `System.Process` handle for `codex exec` is
guarded by `bracket`, ensuring `terminateProcess` runs on any exception path. Cabal build
steps reach a fixed point on a clean tree.

Failure modes and recovery:

- **CLI not installed.** `cradle` surfaces the OS-level `ENOENT` as an exception when
  invoking `cmd`. `System.Process` does likewise. Catch sites in user code should treat
  this the same as `ProcessError`.
- **No network connectivity.** Both CLIs require network access to reach their backends.
  Without it, they exit non-zero with a descriptive stderr ("connection refused", "DNS
  lookup failed"). Our wrapper propagates this as `ProcessError exitCode stderrText` and
  re-running once connectivity returns succeeds with no cleanup required.
- **Unknown model alias.** Both CLIs validate the `--model` / `-m` argument and exit
  non-zero with stderr naming the unrecognized model. This bubbles up as `ProcessError`.
  The fix is to retry with a known alias; no on-disk state needs to be cleared.
- **Malformed JSON from `claude -p`.** If `--output-format json` ever returns something
  that fails `eitherDecodeStrict`, our code throws `DecodeError` carrying the parse error.
  This is recoverable by re-running, and is also a signal that the upstream CLI's output
  schema has shifted (which should be tracked under Surprises & Discoveries).
- **Schema drift in `codex exec --json`.** The streamly JSONL parser is best-effort: it
  silently skips lines it does not recognize. If the assistant text moves to a JSON path
  the parser does not try, the result is an empty `content` field rather than a thrown
  exception. Re-running with `--json` redirected to a file (`codex exec --json … > out.jsonl`)
  reveals the new schema and lets `extractAgentMessage` be extended. This drift is
  expected over time and should be recorded under Surprises & Discoveries.
- **Process leak.** The `bracket (createProcess …) (terminateProcess …)` pattern in
  `codexCli` guarantees that the subprocess is reaped on any exception, including from
  within the streamly fold.


## Interfaces and Dependencies

### Per-package external library dependencies

`baikai` core picks up the dependencies needed by the shared helper
`Baikai.Provider.Cli.Internal`:

- `cradle` — typed process-wrapper, used opportunistically when a helper combinator wants
  to construct a `cmd` pipeline.
- `aeson` — JSON decoding; used by `extractAgentMessage` for Codex JSONL events.
- `streamly ^>=0.10` — the streaming combinator library that drives `parseCodexJsonlStream`.
  Modules used: `Streamly.Data.Stream` (the `Stream` type, `mapMaybe`, `unfoldrM`,
  `foldMany`, `fold`).
- `streamly-core ^>=0.2` — companion package providing `Streamly.Data.Fold` (`toList`,
  `takeEndBy_`, `foldl'`) and, optionally, the `Streamly.External.*` adapters that bridge
  `Handle`s and `ByteString` streams into the streamly world. The implementer should verify
  the exact module path for the chunk-to-line splitter against the installed version.
- `bytestring` — chunk type for the stdout byte stream.
- `directory` — provides `findExecutable`, used by smoke tests.
- `text` — `Data.Text`, `Data.Text.Encoding`. Pulled in transitively but declared
  explicitly for clarity.
- `vector` — `Data.Vector`, used for iterating `Request.messages` and `extraArgs`.
- `time` — `Data.Time.Clock.getCurrentTime`, `diffUTCTime` for latency measurement.
- `lens` — for the `^.` / `#field` overloaded-labels accessor sugar used in the bodies.

`baikai-claude` picks up only what the Claude CLI provider needs (no streamly):

- `baikai` (the core library, which re-exports the shared helpers).
- `cradle`, `aeson`, `bytestring`, `directory`, `text`, `vector`, `time`, `lens`.

`baikai-openai` picks up everything `baikai-claude` does, plus the streamly stack and
`process` (the latter only if option 3 from the Codex CLI surface section is used):

- `baikai`.
- `cradle`, `aeson`, `bytestring`, `directory`, `text`, `vector`, `time`, `lens`.
- `streamly ^>=0.10`, `streamly-core ^>=0.2`.
- `process` (only if `cradle` does not expose a `Handle`-based sink — see the open
  implementation decision in the Codex CLI surface section).

Streamly version pinning is current as of 2026; the implementer should verify the actual
versions in the Nix `ghc912` package set via `ghc-pkg list streamly streamly-core` and
adjust the `^>=` bounds if the set ships a newer minor release.

### Streamly modules used

- `Streamly.Data.Stream` — `Stream`, `mapMaybe`, `unfoldrM`, `foldMany`, `fold`.
- `Streamly.Data.Fold` — `Fold`, `toList`, `takeEndBy_`, `foldl'`.
- `Streamly.External.ByteString.Lazy` (or `Streamly.External.ByteString`) — adapters from
  `ByteString` to a stream of `ByteString` chunks, used if the implementer takes option 1
  or 2 from the Codex CLI surface section. Optional under option 3 because we go through
  `BS.hGetSome` directly.
- `Streamly.FileSystem.Handle` — `read`, used if option 1 is available (turns a stdout
  `Handle` into a streamly stream directly).

### Module exports introduced by this plan

`Baikai.Provider.Cli.Internal` (internal helper module in `baikai` core — not re-exported
from `Baikai`, imported by both vendor packages):

```haskell
renderPrompt          :: Request -> Text
maybeApply            :: Maybe a -> (a -> b -> b) -> b -> b
decodeUtf8Lenient     :: ByteString -> Text
extractAgentMessage   :: Aeson.Value -> Maybe Text
parseCodexJsonlStream :: Stream IO ByteString -> IO Text
```

`Baikai.Provider.Claude.Cli` (in `baikai-claude`):

```haskell
data ClaudeCli                            -- abstract
data ClaudeCliConfig = ClaudeCliConfig
  { executable :: FilePath
  , extraArgs  :: Vector Text
  , workingDir :: Maybe FilePath
  }
defaultClaudeCliConfig :: ClaudeCliConfig
claudeCli              :: MonadIO m => ClaudeCliConfig -> m ClaudeCli
instance Provider ClaudeCli
```

`Baikai.Provider.OpenAI.Cli` (in `baikai-openai`):

```haskell
data CodexCli                             -- abstract
data CodexCliConfig = CodexCliConfig
  { executable       :: FilePath
  , extraArgs        :: Vector Text
  , workingDir       :: Maybe FilePath
  , skipGitRepoCheck :: Bool
  , ephemeral        :: Bool
  }
defaultCodexCliConfig :: CodexCliConfig
codexCli              :: MonadIO m => CodexCliConfig -> m CodexCli
instance Provider CodexCli
```

### Cabal file diffs

Three cabal files change in this plan: `baikai/baikai.cabal` (Milestone 1 diff),
`baikai-claude/baikai-claude.cabal` (Milestone 2 diff), and
`baikai-openai/baikai-openai.cabal` (Milestone 3 diff). Each diff is shown inline in its
milestone. If a test suite stanza in either vendor package needs to depend on the same
modules, mirror the same `build-depends` additions there (notably `directory`, `text`,
`vector`, the `baikai` library itself, and `hspec`).

### Cross-plan dependencies

EP-3 hard-depends on EP-2. EP-2 creates the `baikai-claude` and `baikai-openai` cabal
packages; EP-3 only adds new modules and `build-depends` to packages that already exist.
The master plan's Decision Log records the multi-package layout and the streamly choice;
both are referenced from EP-3's Decision Log on the same date.

### External services

The "services" are the Anthropic and OpenAI backends reached transitively by the CLIs.
This plan does not call those HTTP APIs directly — that is the purview of later ExecPlans.
The only contract this plan depends on is the stability of the CLI flags and the
**best-effort** parse of `codex exec --json` JSONL events documented in the Context section.


## Revisions

2026-05-13: Restructured EP-3 to add CLI providers to the pre-existing `baikai-claude` and
`baikai-openai` packages (created by EP-2) rather than to `baikai` itself. Switched the
Codex JSONL parser from a temp-file workaround to a streamly-based streaming parser of
stdout. Added a hard dependency on EP-2. Driver: the multi-package and streamly decisions
recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the
same date.

- 2026-05-13: Generalised `claudeCli`, `codexCli`, and the `runRequest` instance method bodies from concrete `IO` to `MonadIO m =>`. Wrapped existing IO bodies in a single `liftIO`. Streamly folds and cradle invocations stay in `IO`. Driver: the MonadIO decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.
