---
id: 1
slug: ai-provider-abstraction-library
title: "AI Provider Abstraction Library"
kind: master-plan
created_at: 2026-05-13T23:39:13Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
---

# AI Provider Abstraction Library

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, the `baikai` Haskell library exposes a single unified entry point
for issuing chat-style requests to multiple AI providers. A consumer writes a request once
against the library's `Provider` typeclass and selects, at call time, whether the request
is routed to:

1. The **Anthropic Claude API** via the `claude` Haskell package.
2. The **OpenAI API** via the `openai` Haskell package.
3. The **Claude Code CLI** (`claude -p ...`) running under the user's subscription.
4. The **Codex CLI** (`codex exec ...`) running under the user's subscription.

For every API call the library captures token usage, computes a USD cost from a per-model
pricing table, emits structured trace events (start, finish, error) with latency, and
optionally appends a JSONL record to a per-call log so callers can audit what was spent.
For every CLI invocation the library captures latency and trace events, but explicitly
reports no cost — interactive providers are funded by a subscription rather than
per-token billing.

The user can select a specific model for any provider in either mode by setting a
`model` field on the request (e.g. `claude-opus-4-7`, `gpt-5`, `claude-sonnet-4-6` for the
CLI's `--model sonnet` alias, `o3` for `codex --model`). The library validates models
against the same table that drives pricing for API providers; for CLI providers any string
is accepted because the CLIs themselves do the validation.

After the initiative someone can write:

```haskell
import Baikai
import Baikai.Provider.Claude (claudeApi)

main :: IO ()
main = do
  provider <- claudeApi (ApiKeyEnv "ANTHROPIC_KEY")
  result <- runRequest provider _Request
    { model = "claude-sonnet-4-6"
    , messages = [user "What is 2 + 2?"]
    , maxTokens = 256
    }
  print (result ^. #content)
  print (result ^. #usage)
  print (result ^. #cost)
```

…and see the equivalent response from any of the four providers by swapping the
constructor, with the same `Response` shape, the same `Cost`, and the same trace events
emitted to whichever sink was wired in.

**In scope:** the four providers named above, single-turn and multi-turn message
requests, token-usage capture, per-model USD cost computation, JSONL call log, structured
trace events to pluggable sinks (stdout, file, OpenTelemetry).

**Out of scope:** streaming responses, tool use / function calling, structured outputs
beyond plain text content, image inputs, batch APIs, fine-tuning, embeddings, audio,
prompt caching reporting beyond raw counts. These are all available in the underlying
`claude` and `openai` packages and can be layered on later without redesigning the
abstraction — but they are not part of this initiative.

**Package layout.** The initiative ships **four** cabal packages, kept as siblings under
the repository root and listed in `cabal.project`:

- `baikai` — the core library. Houses the `Provider` typeclass, all shared types
  (`Request`, `Response`, `Usage`, `Cost`, `Model`, `Message`, `BaikaiError`), the
  pricing table and cost computation, the JSONL call log, and the trace-event
  abstraction with stdout / file / silent sinks. This is the only package most consumers
  need to depend on.
- `baikai-claude` — Anthropic-specific providers. Houses `Baikai.Provider.Claude.Api`
  (wrapping the `claude` Haskell package) and `Baikai.Provider.Claude.Cli` (wrapping the
  `claude -p` binary). Depends on `baikai` and `claude`.
- `baikai-openai` — OpenAI-specific providers. Houses `Baikai.Provider.OpenAI.Api`
  (wrapping the `openai` Haskell package) and `Baikai.Provider.OpenAI.Cli` (wrapping the
  `codex exec` binary). Depends on `baikai` and `openai`.
- `baikai-trace-otel` — OpenTelemetry sink. Provides
  `Baikai.Trace.Sink.OpenTelemetry.otelSink :: Tracer -> TraceSink` that turns each
  `TraceEvent` into a span with attributes for model, provider, token counts, latency,
  and cost. Kept as a separate package so the heavy OTel transitive closure does not
  leak into `baikai` itself; consumers opt in by adding this package as a build
  dependency.

**Streamly.** The initiative uses `streamly` in three specific places where stream
shapes are natural and the alternative is clumsier:

- **EP-3, codex CLI provider.** Parses the JSONL event stream from `codex exec --json`
  by running stdout through a `Stream IO ByteString` line splitter and folding it to the
  last `agent_message` payload. Replaces the earlier temp-file workaround.
- **EP-4, call log.** Buffers `CallLogEntry` writes through a `Stream IO CallLogEntry`
  and flushes via a streamly fold to disk. Allows a future "in-memory replay" sink
  without changing call sites.
- **EP-5, trace events.** The `TraceSink` becomes a streamly `Fold IO TraceEvent ()`
  rather than a function-in-record. Sinks compose with the `Fold` combinators (tee,
  filter, transform) and the same `Fold` plugs into the OTel sink in EP-6.

Streamly is **not** used in EP-1, EP-2, or the file/stdout sinks where a function in IO
is already the right shape.


## Decomposition Strategy

The work decomposes into six child plans organised by functional concern, distributed
across four cabal packages. The driving principle is that each plan produces an
independently verifiable behavior: every child plan after EP-1 must end in something a
contributor can run from a `cabal repl` or a small example program and observe working.

The principles applied:

- **Foundations first.** EP-1 defines all shared types (`Model`, `Request`, `Response`,
  `Usage`, `Cost`, `Provider`, error types) and the `Provider` typeclass in the `baikai`
  package. Every later plan consumes EP-1's interfaces, so EP-1 is a hard dependency of
  all others.
- **Per-vendor package boundary.** Anthropic and OpenAI artifacts live in their own
  cabal packages (`baikai-claude`, `baikai-openai`) so that a consumer who only needs
  one vendor pays no compile cost for the other. EP-2 creates both packages and adds
  the API providers; EP-3 extends them with the CLI providers.
- **Cross-cutting concerns are their own plans.** EP-4 (cost) and EP-5 (observability)
  cut across every provider. They live in the core `baikai` package so they remain
  available regardless of which vendor packages a consumer pulls in.
- **OTel is a separate package, not a separate sink in `baikai`.** OpenTelemetry's
  transitive closure (`hs-opentelemetry-api`, `hs-opentelemetry-sdk`, propagators,
  exporters) is substantial and would balloon the `baikai` core. EP-6 isolates the
  dependency by shipping `baikai-trace-otel`, which depends on `baikai` and exposes a
  single function adapting a `Tracer` to a `TraceSink`.
- **Two API providers in one plan, not two.** Claude and OpenAI API providers share the
  same Servant-bindings shape (one record of functions, one `ClientEnv`, one auth
  header) and the same request/response mapping logic. Doing them in one plan makes the
  parallels explicit. The same reasoning applies to EP-3 for the two CLIs.

Alternatives considered and rejected:

- **Single mega-package.** Rejected: pulls Anthropic, OpenAI, and OTel transitive
  closures into every consumer of the abstraction, even consumers using only one
  vendor.
- **Per-provider packages without a shared core (`baikai-claude` containing its own
  copy of the typeclass).** Rejected: defeats the purpose of an abstraction — consumers
  would have to pin both `baikai-claude` and `baikai-openai` to compatible versions of
  the duplicated typeclass.
- **One plan per provider (Claude API, OpenAI API, Claude CLI, Codex CLI).** Rejected:
  the parallels between Claude and OpenAI are more valuable when written side-by-side,
  and four plans plus four cross-cutting plans is over the seven-plan ceiling.
- **OTel folded into EP-5.** Rejected: forces every `baikai` user to take the OTel
  dependency even if they only want stdout tracing.


## Exec-Plan Registry

| #    | Title                                                | Path                                                          | Hard Deps   | Soft Deps   | Status      |
|------|------------------------------------------------------|---------------------------------------------------------------|-------------|-------------|-------------|
| EP-1 | Core abstraction types and Provider class            | docs/plans/1-core-abstraction-types-and-provider-class.md     | None        | None        | Complete    |
| EP-2 | Claude and OpenAI API providers                      | docs/plans/2-claude-and-openai-api-providers.md               | EP-1        | None        | Not Started |
| EP-3 | Interactive CLI providers for Claude and Codex       | docs/plans/3-interactive-cli-providers-for-claude-and-codex.md | EP-1, EP-2 | None        | Not Started |
| EP-4 | Cost tracking with per-model pricing                 | docs/plans/4-cost-tracking-with-per-model-pricing.md          | EP-1        | EP-2        | Not Started |
| EP-5 | Observability and call tracing                       | docs/plans/5-observability-and-call-tracing.md                | EP-1        | EP-2, EP-3, EP-4 | Not Started |
| EP-6 | OpenTelemetry trace sink package                     | docs/plans/6-opentelemetry-trace-sink-package.md              | EP-1, EP-5 | EP-4        | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-1 is the foundation. It defines `Baikai.Model`, `Baikai.Request`, `Baikai.Response`,
`Baikai.Usage`, `Baikai.Cost`, `Baikai.Error`, the `Baikai.Provider.Provider` typeclass,
and an updated `Baikai.Prelude` — all in the `baikai` cabal package. Every other plan
imports from these modules. EP-1 stands alone and can start immediately.

EP-2 creates two new cabal packages (`baikai-claude`, `baikai-openai`) and adds the API
providers (`Baikai.Provider.Claude.Api`, `Baikai.Provider.OpenAI.Api`) into them. It
hard-depends on EP-1 because the providers implement the `Provider` typeclass and
populate `Response` and `Usage` from EP-1.

EP-3 adds the CLI providers (`Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Cli`)
into the existing `baikai-claude` and `baikai-openai` packages. It now hard-depends on
EP-2 because EP-2 creates those packages; this is a change from earlier drafts of the
decomposition that had EP-3 standing alongside EP-2. The dependency is small in scope —
EP-3 only needs the package skeletons EP-2 produces — but it must not be skipped.

EP-4 depends hard on EP-1 (it consumes `Usage` and produces a `Cost`). It is
**soft-dependent** on EP-2: implementing EP-4 is possible against synthetic `Usage`
values, but real validation of the pricing tables requires Claude or OpenAI API
responses, so finishing EP-2 first makes the verification more meaningful. EP-4 does not
depend on EP-3 because CLI providers explicitly produce no usage and no cost. EP-4's
new modules live in `baikai` itself.

EP-5 depends hard on EP-1 (it emits events shaped by EP-1's types) and is
soft-dependent on EP-2, EP-3, and EP-4. The trace events naturally describe what each
provider did, including cost when present, so finishing those plans first produces more
realistic example output. EP-5's new modules also live in `baikai`. The `TraceSink` shape
EP-5 defines (a streamly `Fold IO TraceEvent ()`) is the single most important contract
for EP-6.

EP-6 creates the fourth cabal package, `baikai-trace-otel`. It hard-depends on EP-1 and
EP-5: on EP-1 for the event types, and on EP-5 for the `TraceSink`/`Fold` shape it
adapts to. It is soft-dependent on EP-4 because cost is an attribute on the span when
present, but the OTel sink works whether or not cost is populated. EP-6 does not modify
any module in `baikai`; it consumes EP-5's public surface only.

Implementable in parallel after EP-1: EP-2, (with stubbed `Usage`) EP-4, (with stubbed
provider) EP-5. EP-3 must wait for EP-2. EP-6 must wait for EP-5. The recommended
waterfall, if a single contributor is implementing sequentially, is
**EP-1 → EP-2 → EP-3 → EP-4 → EP-5 → EP-6**.


## Integration Points

Several types and modules are shared across multiple child plans. EP-1 owns the
definitions; later plans consume them and must not redefine them.

**`Baikai.Provider` (typeclass + a `SomeProvider` existential)** — defined by EP-1.
Consumed by EP-2 and EP-3 as the type each new provider implements. EP-5 dispatches
trace events keyed off `providerName :: p -> Text` from this class. The typeclass shape
is the single most important integration point: changes to it cascade through every
other plan.

**`Baikai.Request`** — defined by EP-1. Contains a `model :: Text` field that EP-2 and
EP-3 must thread through to their respective provider calls. The field is intentionally
a `Text` (not a closed sum) so that CLI providers can pass through any model alias the
user types and API providers can pass through model strings that may not yet appear in
EP-4's pricing table.

**`Baikai.Response`** — defined by EP-1. Contains `usage :: Maybe Usage` (Nothing for
CLI providers, Just for API providers) and `cost :: Maybe Cost` (Nothing for CLI
providers and for API responses whose model is absent from EP-4's pricing table).
EP-2 and EP-3 populate the response; EP-4 fills in `cost` based on `usage`; EP-5 reads
both for trace events.

**`Baikai.Usage`** — defined by EP-1, populated by EP-2, consumed by EP-4 and EP-5. The
representation must accommodate both Anthropic's `input_tokens` / `output_tokens` /
`cache_creation_input_tokens` / `cache_read_input_tokens` shape and OpenAI's
`prompt_tokens` / `completion_tokens` / `total_tokens` shape. EP-1 normalizes these to
a single record with `inputTokens`, `outputTokens`, `cachedInputTokens` (Maybe), and
`reasoningTokens` (Maybe).

**`Baikai.Cost`** — defined by EP-1 as an opaque record holding `usd :: Rational` and
`breakdown :: CostBreakdown` (input cost, output cost, cache cost). EP-4 populates it
via the pricing table. EP-5 prints it.

**`Baikai.Trace.Event`** — defined by EP-5. Not consumed by any other plan directly:
every provider invokes a single `withTrace` wrapper that EP-5 provides, so providers do
not need to know the event schema. EP-2 and EP-3 receive an `IO ()` cleanup callback from
EP-5; if EP-5 is not yet implemented, the providers pass `pure ()` and trace emission is
a no-op. This decoupling lets EP-2/EP-3 finish without EP-5 in place.

**`cabal.project`** — the project-level file at the repository root lists all sibling
packages. EP-1 leaves it as `packages: baikai` (only one package exists at that point).
EP-2 adds two entries (`baikai-claude`, `baikai-openai`). EP-6 adds one more
(`baikai-trace-otel`). The plan introducing each new cabal package must also create the
corresponding directory (e.g. `baikai-claude/baikai-claude.cabal` plus `baikai-claude/src/`).

**Per-package `build-depends`** — every plan documents the build-depends additions for
each package it touches. EP-1 adds `aeson`, `bytestring`, `containers`, `time`,
`scientific`, `vector` to `baikai`. EP-2 creates `baikai-claude` (depending on `baikai`,
`claude`, `http-client`, `http-client-tls`, `servant-client`) and `baikai-openai`
(depending on `baikai`, `openai`, `http-client`, `http-client-tls`, `servant-client`).
EP-3 adds `cradle`, `streamly`, `streamly-core`, `temp-file` to both vendor packages.
EP-4 adds nothing new (everything lives in `baikai`). EP-5 adds `streamly`,
`streamly-core`, `stm` to `baikai`. EP-6 creates `baikai-trace-otel` depending on
`baikai`, `hs-opentelemetry-api`, `hs-opentelemetry-sdk`.

**The `TraceSink` shape** — defined by EP-5 as a `streamly` `Fold IO TraceEvent ()`.
EP-6 consumes this contract directly, adapting it to OpenTelemetry spans. If EP-5
revises the `TraceSink` shape, EP-6 must cascade the change. Document any revision in
both plans and in this section's Decision Log.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] 2026-05-13 EP-1: Define `Baikai.Model`, `Baikai.Request`, `Baikai.Response`, `Baikai.Usage`, `Baikai.Cost`, `Baikai.Error` modules in the `baikai` package
- [x] 2026-05-13 EP-1: Define `Baikai.Provider` typeclass and `SomeProvider` existential
- [x] 2026-05-13 EP-1: Update `Baikai.Prelude` and re-export the public surface from `Baikai`
- [x] 2026-05-13 EP-1: Add unit tests that construct a `Request` and pattern-match a `Response` (`cabal test all` — `All 3 tests passed`)
- [ ] EP-2: Create `baikai-claude` and `baikai-openai` packages with cabal files and `cabal.project` entries
- [ ] EP-2: Implement `Baikai.Provider.Claude.Api` (in `baikai-claude`) mapping unified Request to `Claude.V1.Messages.CreateMessage`
- [ ] EP-2: Implement `Baikai.Provider.OpenAI.Api` (in `baikai-openai`) mapping unified Request to `OpenAI.V1.Chat.Completions.CreateChatCompletion`
- [ ] EP-2: Integration smoke test against both APIs (skipped if API key env var is unset)
- [ ] EP-3: Add `cradle`, `streamly`, `streamly-core`, `temp-file` to `baikai-claude` and `baikai-openai`
- [ ] EP-3: Implement `Baikai.Provider.Claude.Cli` invoking `claude -p --output-format json --model ...`
- [ ] EP-3: Implement `Baikai.Provider.OpenAI.Cli` invoking `codex exec --json --model ...`, parsing JSONL via streamly
- [ ] EP-3: Smoke test that invokes a small prompt and parses the JSON response
- [ ] EP-4: Define `Baikai.Cost.Pricing` with a model→rate map seeded for the current Claude and OpenAI lineup
- [ ] EP-4: Implement `Baikai.Cost.compute :: Model -> Usage -> Maybe Cost`
- [ ] EP-4: Wire cost computation into API providers' response construction
- [ ] EP-4: Implement optional JSONL call log via `Baikai.Cost.Log`, buffered through a streamly fold
- [ ] EP-5: Define `Baikai.Trace.Event` and `Baikai.Trace.Sink` (as a streamly `Fold IO TraceEvent ()`)
- [ ] EP-5: Implement stdout, file, silent, and multi sinks
- [ ] EP-5: Wrap provider calls with `withTrace` that emits start/finish/error events with latency
- [ ] EP-6: Create `baikai-trace-otel` package with cabal file and `cabal.project` entry
- [ ] EP-6: Implement `Baikai.Trace.Sink.OpenTelemetry.otelSink :: Tracer -> TraceSink` mapping events to spans with attributes for model, provider, tokens, latency, cost
- [ ] EP-6: Provide an in-memory exporter test that asserts a call produces one span with the expected attributes


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-05-13: EP-1's `Baikai.Prelude` shipped without a standalone `liftIO` export. GHC 9.12.2 emits `-Wduplicate-exports` because `liftIO` is already a class method of `MonadIO (..)`. Mentioning this here because every later plan that imports `Baikai.Prelude` and writes a `Provider` instance still gets `liftIO` in scope — no consumer-side change is needed. Evidence: `cabal build all` clean output and EP-1 plan Surprises & Discoveries entry.


## Decision Log

- Decision: Adopt a single `Baikai.Provider` typeclass with `runRequest :: p -> Request -> IO Response`, rather than a closed sum of providers.
  Rationale: A typeclass keeps each provider implementation isolated to its own module, lets users define third-party providers later (e.g. local models, Vertex), and supports the `SomeProvider` existential for storing heterogeneous providers in config. A closed sum would force every new provider to touch a central file.
  Date: 2026-05-13

- Decision: Model selection is a `Text` field on the unified `Request`, not a closed enum.
  Rationale: New models ship every few weeks; an enum guarantees the library lags. EP-4's pricing table is keyed by `Text`, so an unknown model simply produces `Nothing` for `cost`. CLI providers pass the string through verbatim — `claude --model` and `codex --model` already accept aliases like `sonnet` and `o3`.
  Date: 2026-05-13

- Decision: Cost is `Maybe Cost` on `Response`, always `Nothing` for CLI providers.
  Rationale: CLI providers run under a flat subscription with no per-token billing surface. Emitting a zero or sentinel value would mislead consumers reading the cost log. `Nothing` is the truthful signal.
  Date: 2026-05-13

- Decision: Two API providers and two CLI providers share their own plan rather than each plan being per-provider.
  Rationale: Within each mode the work is parallel and the integration point is a single typeclass instance. Splitting four ways would produce four nearly-identical small plans whose only differences are the package name and the field-mapping table.
  Date: 2026-05-13

- Decision: Streaming, tool use, image inputs, batch APIs, embeddings, audio, and structured outputs are out of scope for this initiative.
  Rationale: Each is a substantial feature that the underlying `claude` and `openai` packages already support; folding them in now would balloon the plan and obscure the core abstraction. They can be added later by extending `Baikai.Request` and adding methods to `Baikai.Provider` without breaking existing call sites.
  Date: 2026-05-13

- Decision: Trace events live behind a sink abstraction with stdout and file sinks shipped in EP-5, while OpenTelemetry support ships in a separate `baikai-trace-otel` package.
  Rationale: OpenTelemetry is a heavy dependency for a library whose primary observability need is "what did this call cost and how long did it take". Isolating it in its own package means consumers can pick it up by adding a single build-dep without paying the compile cost everywhere else.
  Date: 2026-05-13

- Decision: Ship four cabal packages — `baikai`, `baikai-claude`, `baikai-openai`, `baikai-trace-otel` — instead of a single library.
  Rationale: Anthropic, OpenAI, and OTel transitive closures are each substantial. A consumer who only needs Claude pays no compile cost for OpenAI's Servant bindings, and OTel users opt in explicitly. The core `baikai` package keeps the abstraction, cost math, and the file/stdout trace sinks, so most consumers depend on `baikai` plus one vendor package.
  Date: 2026-05-13

- Decision: Adopt `streamly` in three targeted places: parsing the codex `--json` stream (EP-3), buffering the call log (EP-4), and shaping the trace-event pipeline as a `Fold IO TraceEvent ()` (EP-5/EP-6).
  Rationale: `streamly` is already a dependency we use elsewhere in our stack, and the trace sink is a natural fold. Sinks compose via the `Fold` combinators and the same fold plugs into the OTel sink. Streamly is intentionally NOT used in EP-1 or EP-2 where a function in `IO` is already the right shape.
  Date: 2026-05-13

- Decision: EP-3 hard-depends on EP-2 (a change from the initial decomposition that had them as parallel siblings).
  Rationale: EP-2 creates the `baikai-claude` and `baikai-openai` packages; EP-3 only adds modules to them. Having EP-3 create the packages would be a coordination hazard if both plans run in parallel.
  Date: 2026-05-13

- Decision: Parameterize one-shot provider operations with `MonadIO m =>` rather than `IO`; keep bracket/fork functions in concrete `IO`.
  Rationale: A future `baikai-effectful` package should be able to lift `runRequest`, `claudeApi`, `openaiApi`, `claudeCli`, `codexCli`, `appendEntry`, and similar one-shot operations into `Eff es` without writing adapters, and `Eff es` is a `MonadIO` instance whenever `IOE :> es`. Bracket-style functions like `withTrace` and `withCallLog` fork a worker thread and rely on `bracket` over `IO`; the `effectful` library does not provide `MonadUnliftIO` for `Eff es`, so a polymorphic `MonadUnliftIO m =>` signature would be a false promise. Keeping those in `IO` is honest and the caller writes one `liftIO` (or the future `baikai-effectful` package provides native `Eff es` wrappers).
  Date: 2026-05-13

- Decision: The `TraceSink` is parameterized as `streamly` `Fold IO TraceEvent ()` (concrete `IO`), not `Fold m TraceEvent ()`.
  Rationale: The sink runs inside the bracket worker that `withTrace` forks. The worker lives in `IO`. Making the fold polymorphic would force every sink author to thread `MonadIO m` constraints through their fold logic for no payoff — there is no caller of the fold outside the worker. The future `baikai-effectful` package can provide an `Eff es`-flavoured `withTraceEff` wrapper without changing the sink contract.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revisions

- 2026-05-13: Initial draft assumed a single `baikai` library and a 5-plan decomposition with stdout/file trace sinks only. After feedback during decomposition, the architecture was restructured to four sibling cabal packages (`baikai`, `baikai-claude`, `baikai-openai`, `baikai-trace-otel`); the `TraceSink` shape was switched to a `streamly` `Fold IO TraceEvent ()` so that the OTel sink can be a drop-in fold; and a sixth child plan (EP-6) was added to design and implement `baikai-trace-otel`. The dependency graph was updated to make EP-3 hard-depend on EP-2 (because EP-2 now creates the vendor packages EP-3 extends). Child plans EP-2, EP-3, EP-4, EP-5 were re-written to reflect the new layout; EP-1 was kept as-is because its scope (the `baikai` core package) was unchanged.

- 2026-05-13 (later same day): Generalised one-shot provider operations from concrete `IO` to `MonadIO m =>`. Affects: `Provider.runRequest`, `claudeApi`, `openaiApi`, `claudeCli`, `codexCli`, `resolveApiKey`, `appendEntry`, `openCallLog`, `closeCallLog`, and the constructor-style `IO` actions in each provider's instance. Bracket/fork entry points (`withTrace`, `withCallLog`) keep concrete `IO` because `effectful`'s `Eff es` is not a `MonadUnliftIO`; a future `baikai-effectful` package will provide native `Eff es` wrappers for those entry points. The `TraceSink` shape (`Fold IO TraceEvent ()`) is unchanged for the same reason — the sink lives inside the worker that `withTrace` forks. Child plans EP-1 through EP-6 revised in cascade.
