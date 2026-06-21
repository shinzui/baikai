---
id: 25
slug: enrich-baikai-error-taxonomy-and-add-usage-aggregation
title: "Enrich Baikai.Error taxonomy and add Usage aggregation"
kind: exec-plan
created_at: 2026-06-21T15:58:39Z
intention: "intention_01kvnefc3qe9ashtt30m8xszy9"
---

# Enrich Baikai.Error taxonomy and add Usage aggregation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

baikai is a Haskell library that lets a program call several AI providers
(Anthropic Claude, OpenAI, OpenAI-compatible hosts, and the `claude -p` /
`codex exec` command-line tools) through one pair of functions,
`completeRequest` and `streamRequest`. It deliberately does **not** implement
retry loops, rate-limit backoff, or conversation/session state. Its own README
states that retry policy "belongs one layer up" — in the application that uses
baikai.

There are two concrete gaps that make that division of labour harder than it
should be, and this plan closes both.

**Gap 1 — errors are opaque, so callers cannot implement the retry policy
baikai tells them to own.** Today every failure collapses into one of four
text-only shapes in `baikai/src/Baikai/Error.hs`:

```haskell
data BaikaiError
  = ProviderError !Text
  | RequestInvalid !Text
  | DecodeError !Text
  | ProcessError !Int !Text
```

A caller that catches a `BaikaiError` cannot tell an HTTP 429 "rate limited,
retry after 30 seconds" apart from an HTTP 400 "your request is malformed, never
retry" apart from an HTTP 401 "your API key is wrong." Both arrive as
`ProviderError "<some text>"`. So the application cannot make the one decision
baikai expects it to make: *should I retry this, and if so, after how long?*
After this change, a caller can pattern-match a **category** (authentication
failure, rate limited, context-window overflow, invalid request, transient
server/network error, response-decode failure, subprocess failure, no provider
registered, or other), read an optional HTTP status code, read an optional
"retry after N seconds" hint, and call a ready-made predicate `isRetryable`.

What you can do after this change that you could not before: write
`if isRetryable err then backoff (retryAfterSeconds err) >> again else giveUp`
in application code, and have it behave correctly across Anthropic, OpenAI, and
the CLI providers — because baikai now classifies provider failures into stable
categories instead of flattening them to prose.

**Gap 2 — usage/cost cannot be summed across calls.** Each successful call
returns a `Usage` record (input/output/cache/reasoning token counts plus a
computed `Cost` in USD) defined in `baikai/src/Baikai/Usage.hs`. A multi-turn
agent makes many calls and naturally wants a running total ("this conversation
cost $0.0123 and used 8,400 tokens"). Today the caller must hand-add seven
numeric fields plus a nested `Cost`/`CostBreakdown` by hand, getting the
`reasoningTokens :: Maybe Natural` combination subtly wrong (is `Nothing +
Just 5` equal to `Just 5` or `Nothing`?). After this change `Usage` and `Cost`
and `CostBreakdown` are `Semigroup`/`Monoid` instances that add field-by-field,
so a caller writes `foldMap responseUsage responses` or `mconcat usages` and
gets the correct total, including a sensible rule for `reasoningTokens`.

How to see both working: new unit tests in the `baikai` package's test suite
fail before the change and pass after, and a short transcript in this plan shows
`mconcat [u1, u2]` producing summed tokens and summed cost, plus a classifier
turning an HTTP-429 carrier exception into a `RateLimited` category with
`retryAfterSeconds = Just 30`.

Scope boundary, stated plainly so a future reader does not over-build: this plan
adds **typed errors and a retryability hint**, and **value-combining instances
for usage**. It does **not** add a retry loop, a backoff scheduler, rate-limit
queueing, caching, or session state. baikai still performs exactly one provider
attempt per call; the application decides what to do with a typed failure.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `Usage`/`Cost`/`CostBreakdown` gain `Semigroup` + `Monoid` instances; `sumUsage` helper added; unit tests added to `baikai` test suite. (2026-06-21 — `UsageSpec` green, all 63 baikai tests pass.)
- [x] M2: `Baikai.Error` redesigned into a record with an `ErrorCategory` sum type, smart constructors, and `isRetryable` / `retryAfterSeconds` accessors; pure `classifyHttpStatus` helper added; core construction sites (`Auth`, `Registry`) and existing tests updated; everything compiles and existing tests pass. (2026-06-21 — `ErrorSpec` added; `cabal test all` green: baikai 83, claude 4, openai 5, effectful 4, trace-otel 2, smoke pass.)
  - Note: the mechanical CLI-provider constructor renames originally slotted for M3 step 3 were folded into M2 so that every commit leaves the whole workspace compiling. M3 now only adds the substantive HTTP-exception classification.
- [x] M3a (core threading): added `ToJSON` to `ErrorCategory`/`BaikaiError`; added `errorInfo :: Maybe BaikaiError` to `Baikai.Stream.Event.TerminalPayload` and `Baikai.Response.Response`; threaded it through `Baikai.Stream` reassembly/`finalizeState`; added `doneTerminal`/`errorTerminal` helper constructors and converted all `TerminalPayload` construction sites; updated `Response{}`/`TerminalPayload` sites in CLI providers and tests. Bonus: `liftCompleteToStream`'s `errorEvent`/`noProviderEvent` now populate `errorInfo` from a thrown `BaikaiError` / `providerUnavailable`, so the CLI/Auth/Registry throw paths surface structured errors on `Response` too. (2026-06-21 — `cabal test all` green: baikai 83, others unchanged. Behaviour-neutral for the API path until M3b.)
- [x] M3b (provider classification): added `Baikai.Provider.{Claude,OpenAI}.ErrorClass` with `classifyException` (HTTP `ClientError` → `BaikaiError`, via the exposed-for-testing `responseToError`), Claude's `classifyErrorValue` (Anthropic streamed-error JSON) and OpenAI's `classifyErrorText` (OpenAI streamed-error text); wired worker-caught exceptions via an `IORef (Maybe BaikaiError)` into the end-of-stream terminal (`unexpectedEoS`/`closeOpenStream`), classified mid-stream error events in `translate`, and mapped request-prep failures to `invalidRequest`; added `http-types`/`case-insensitive` deps; added `ErrorClassSpec` to each provider (Claude 18, OpenAI 16 total) plus a core `ErrorInfoSpec` proving `completeRequest` surfaces `errorInfo` end-to-end. (2026-06-21 — `cabal test all` green: baikai 89, claude 18, openai 16, trace-otel 2, effectful 4, smoke pass.)
- [ ] M4: Version bumps and CHANGELOG entries for `baikai`, `baikai-claude`, `baikai-openai`; `nix flake check` / full `cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Pre-existing breakage in `baikai-smoke` (2026-06-21, during M2). The live smoke
  test `baikai-smoke/test/Smoke.hs` referenced `Models.anthropic_claude_haiku_4_5_20251001`
  at lines 89 and 295, but the generated catalog no longer exports that name —
  the model-catalog refresh in commit `a7edb18` renamed it to
  `anthropic_claude_haiku_4_5`. This is unrelated to the error/usage work (the
  old name is present in `git show HEAD:baikai-smoke/test/Smoke.hs`, and I had
  not touched `baikai-smoke`), but it blocked a clean `cabal build all` /
  `cabal test all`. Evidence:

  ```text
  test/Smoke.hs:89:11: error: [GHC-76037]
      Not in scope: 'Models.anthropic_claude_haiku_4_5_20251001'
      Note: The module 'Baikai.Models.Generated' does not export ...
      Suggested fix: Perhaps use 'Models.anthropic_claude_haiku_4_5'
  ```

  Resolved by the obvious rename to `Models.anthropic_claude_haiku_4_5` (the
  compiler's own suggested fix), keeping the workspace green. No behaviour
  change; the smoke test still skips when API keys are absent.


## Decision Log

Record every decision made while working on the plan.

- Decision: Redesign `BaikaiError` as a single record carrying an `ErrorCategory`
  enum plus optional `httpStatus`, `retryAfterSeconds`, and `exitCode`, rather
  than adding more flat constructors.
  Rationale: Callers need to switch on a small, stable set of *categories* and
  read structured hints (status, retry-after). A growing list of bare
  constructors cannot carry the retry-after hint without yet another breaking
  reshuffle later. A record with one category field is forward-compatible: new
  HTTP nuances map to existing categories without changing the type. We provide
  smart constructors (`providerError`, `decodeError`, `processError`,
  `invalidRequest`) so existing call sites change by a near-mechanical rename
  rather than a structural rewrite.
  Date: 2026-06-21

- Decision: Keep classification of HTTP status codes as a *pure* function
  `classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory` living in the core
  `baikai` package (`Baikai.Error`), while the *extraction* of status code and
  Retry-After header from a provider SDK exception lives in each provider
  package.
  Rationale: The core `baikai` package must not depend on `http-client` or
  `servant-client`. Status-range → category mapping is provider-neutral arithmetic
  and belongs in core where it can be unit-tested without a network. Only the
  glue that knows "this SDK throws `ClientError`" lives in the provider packages,
  which already depend on `servant-client`.
  Date: 2026-06-21

- Decision: `reasoningTokens :: Maybe Natural` combines as "presence wins": if
  either side is `Just`, the result is `Just` of the summed present values
  (treating an absent side as 0); `Nothing <> Nothing = Nothing`.
  Rationale: `reasoningTokens` is `Nothing` for providers that do not report
  reasoning tokens at all, and `Just n` for those that do. Summing a reasoning
  call (`Just 5`) with a non-reasoning call (`Nothing`) should yield `Just 5`,
  not lose the 5 and not fabricate a `Just 0` for a conversation that never used
  reasoning. This matches how the field is already produced by the providers.
  Date: 2026-06-21

- Decision: Deliver typed error categories on the API (`completeRequest`) path,
  not only on the thrown CLI/Auth/Registry path (the "Full" M3 option). The user
  chose this on 2026-06-21 after I surfaced that the API providers never throw on
  HTTP errors — they fold the failure in-band into an error-`Response`
  (`stopReason = ErrorReason`, `errorMessage :: Maybe Text`). Without this work a
  caller hitting a 429/5xx from Anthropic/OpenAI could not branch on category.
  Rationale: the user's core motivation is retry policy, which is most relevant
  precisely to the API path's rate-limit/transient failures.
  Date: 2026-06-21

- Decision: Carry the structured error as `errorInfo :: Maybe BaikaiError` on
  `TerminalPayload` and `Response`, rather than adding `errorCategory` /
  `retryAfterSeconds` fields to `AssistantPayload`.
  Rationale: `AssistantPayload` has ~20 full-record construction sites across the
  core, both providers, and every test; adding required fields there risks
  uninitialised-field landmines (a partial record literal compiles but the field
  is bottom). `TerminalPayload` has ~14 construction sites and is the
  semantically correct home for terminal/error metadata. A single
  `Maybe BaikaiError` is more expressive than two scalar fields (it carries
  category, message, httpStatus, and retryAfterSeconds together). To avoid the
  partial-record landmine entirely, `Baikai.Stream.Event` gains `doneTerminal`
  and `errorTerminal` helper constructors and all sites use them.
  Date: 2026-06-21

- Decision: Thread the worker-thread's caught `ClientError` to the stream via an
  `IORef (Maybe BaikaiError)` in the provider's producer state, consumed by the
  end-of-stream handler — rather than widening the producer `Chan`'s element type
  or JSON-encoding the error back through the SDK event type.
  Rationale: The API providers run the SDK call on a forked worker thread that
  writes SDK events to a `Chan`; the caught HTTP exception cannot otherwise cross
  back to the pure `translate` step. On exception the worker stores
  `classifyException e` in the ref and closes the channel; the existing
  "channel closed before a terminal event" recovery path reads the ref and emits
  an `EventError` carrying the structured error. This keeps the `Chan` type and
  all its uses unchanged and confines the change to each provider's producer.
  Mid-stream streamed error events (Anthropic `rate_limit_error` etc., which
  arrive as a normal SDK event with an error JSON `Value`) are classified purely
  inside `translate` via `classifyErrorValue`.
  Date: 2026-06-21

- Decision: `ErrorCategory` and `BaikaiError` gain `ToJSON` instances (snake_case
  fields) in `Baikai.Error`.
  Rationale: `TerminalPayload` derives `ToJSON` (anyclass) and now contains a
  `BaikaiError`; `Response` gains a serialized `errorInfo`. Both must serialize.
  `aeson` is already a dependency of core `baikai`.
  Date: 2026-06-21

- Decision: Fold M3's mechanical CLI-provider constructor renames into M2.
  Rationale: M2's stated acceptance is "the entire workspace compiles." Because
  the CLI providers (`baikai-claude`/`baikai-openai` `Cli.hs`) construct the old
  bare constructors, leaving their rename to M3 would make the M2 commit fail to
  build those packages. Doing the renames in M2 keeps every commit green; M3 is
  left with only the substantive HTTP-exception classification, which is the part
  that carries real behaviour.
  Date: 2026-06-21

- Decision: This is a pre-1.0 (0.1.x) library, so the breaking change to
  `BaikaiError`'s constructors is acceptable; we bump the minor version of each
  affected package and document the break in the CHANGELOG rather than
  preserving the old constructors.
  Rationale: The existing constructors (`ProviderError` etc.) are referenced in
  only a handful of internal sites and tests, all updated in this plan. A
  compatibility shim would ossify the very shape we are trying to improve.
  Date: 2026-06-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository.

**What baikai is.** A multi-package Haskell project (a "Cabal project": a set of
library packages built together) under `/Users/shinzui/Keikaku/bokuno/baikai`.
The packages relevant here are:

- `baikai` — the core, provider-neutral library. Source under
  `baikai/src/Baikai/`. Cabal file `baikai/baikai.cabal`. Depends on no provider
  SDK and (importantly) on no HTTP library.
- `baikai-claude` — the Anthropic provider. It wraps the third-party `claude`
  Haskell package (a `servant-client`-based SDK) for the HTTP API and shells out
  to the `claude -p` command for the CLI provider. Source under
  `baikai-claude/src/Baikai/Provider/Claude/`.
- `baikai-openai` — the OpenAI provider. It wraps the third-party `openai`
  Haskell package (also `servant-client`-based) and shells out to `codex exec`.
  Source under `baikai-openai/src/Baikai/Provider/OpenAI/`.
- `baikai-trace-otel` — an OpenTelemetry tracing adapter. Has a test that
  constructs a `BaikaiError`, so it is touched by the error redesign.

**Build and test toolchain.** The project uses Nix to pin the compiler (GHC
9.12.4) and Cabal. The everyday commands, run from the repository root
`/Users/shinzui/Keikaku/bokuno/baikai`, are:

```bash
nix develop        # enter the dev shell (or: direnv allow, once)
cabal build all    # compile every package
cabal test all     # run every package's test suite
nix fmt            # format Haskell (fourmolu), cabal, and nix files
```

If `nix develop` is unavailable in your environment, a contributor with a
matching GHC 9.12.4 + Cabal toolchain on `PATH` can run the `cabal` commands
directly; the Nix shell only guarantees the exact toolchain.

**Term definitions used in this plan.**

- *Provider*: a backend baikai can dispatch to (Anthropic API, OpenAI API, a CLI
  tool, or a user-registered custom handler). Each provider is registered into a
  *registry* (a lookup table from an API tag to a pair of `complete`/`stream`
  functions).
- *`servant-client`*: a Haskell library for calling HTTP APIs. When a call gets a
  non-2xx HTTP response, it throws (or returns) a value of type
  `Servant.Client.ClientError`. The constructor we care about is
  `FailureResponse`, which carries a `ResponseF` value containing the HTTP status
  code and response headers. Other constructors include `DecodeFailure` (the
  body did not parse), `ConnectionError` (the network call failed before any HTTP
  status), `UnsupportedContentType`, and `InvalidContentTypeHeader`.
- *Retry-After*: an HTTP response header (`Retry-After`) that a server may send
  with a 429 or 503 response, telling the client how many seconds to wait before
  retrying. Its value is either an integer number of seconds or an HTTP-date; we
  handle the integer-seconds form and ignore the date form (treating it as
  absent).
- *Semigroup / Monoid*: standard Haskell type classes. A `Semigroup` provides
  `(<>)` to combine two values of a type. A `Monoid` adds `mempty`, an identity
  element, so a list of values can be folded with `mconcat`. We use these so
  callers can total many `Usage` values.

**The exact current types (read these files to confirm before editing).**

`baikai/src/Baikai/Usage.hs` (lines 22–48) defines, with no record-field
prefixes (a project rule — record fields must never carry Hungarian prefixes):

```haskell
data Usage = Usage
  { inputTokens :: !Natural,
    outputTokens :: !Natural,
    cacheReadTokens :: !Natural,
    cacheWriteTokens :: !Natural,
    reasoningTokens :: !(Maybe Natural),
    totalTokens :: !Natural,
    cost :: !Cost
  }
  deriving stock (Eq, Show, Generic)

_Usage :: Usage   -- the all-zero base value
```

`baikai/src/Baikai/Cost.hs` (lines 14–38) defines:

```haskell
data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational,
    outputUsd :: !Rational,
    cachedInputUsd :: !Rational,
    cachedWriteUsd :: !Rational
  }
  deriving stock (Eq, Show, Generic)

data Cost = Cost
  { usd :: !Rational,
    breakdown :: !CostBreakdown
  }
  deriving stock (Eq, Show, Generic)

_Cost :: Cost           -- zero cost
_CostBreakdown :: CostBreakdown   -- zero breakdown
```

`baikai/src/Baikai/Error.hs` is the full 14-line file quoted in Purpose above.
Note `RequestInvalid` is currently **unused** anywhere in the codebase (verified
by `grep`), so folding it into a new `InvalidRequest` category loses no caller.

**Where errors are currently thrown (every construction site, verified by
grep).** These are the sites the redesign must update:

- `baikai/src/Baikai/Auth.hs:59` — `throwIO (ProviderError ("env var " <> ... <> " is not set"))`
  when an API key environment variable is missing. This is a *configuration*
  problem; it will map to the new `AuthError` category.
- `baikai/src/Baikai/Provider/Registry.hs:99` — `ProviderError ("No provider registered for API: " <> ...)`
  when no handler is registered for a model's API tag. Maps to a new
  `ProviderUnavailable` category.
- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs:144,146,148,151,153` —
  `DecodeError` for failures parsing `claude -p` JSON output. Maps to
  `DecodeFailure` category.
- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs:182` — `ProcessError n (...)`
  on non-zero `claude` exit. Maps to `ProcessFailure` category, carrying the
  exit code.
- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs:186` — `ProviderError (result r)`
  when the CLI reports an error result. Maps to `OtherError`/`ProviderFailure`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs:155,156` — `ProviderError`
  for missing stdout/stderr handles. Maps to `OtherError`/`ProviderFailure`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs:162` — `ProcessError n (...)`
  on non-zero `codex` exit. Maps to `ProcessFailure`.

**Where the API providers catch exceptions today.** Both API providers wrap the
underlying SDK call in `try @SomeException` and, on `Left e`, build an
in-band error event by calling `displayException e` and stuffing the resulting
`String` into an `EventError`/terminal payload. The relevant code in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` is around lines 181–187:

```haskell
    try @SomeException $
      ...
    Left e -> writeChan ch (Just (errorEvent (Text.pack (displayException e))))
```

`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` has the same shape (it imports
`Control.Exception (SomeException, displayException, try)` at line 75). These are
the two spots Milestone 3 enriches: instead of only `displayException`, the
handler first tries to recognise the exception as a `servant-client`
`ClientError`, extract a status code and Retry-After header, and build a
categorised `BaikaiError` whose `Show`/message text is then used for the event.

**Where the existing tests reference `BaikaiError`.** These must keep compiling:

- `baikai/test/TraceSpec.hs:6,85,113,145` — uses `ProviderError "boom"` /
  `ProviderError "stub-failure"` and a `registerFail :: Api -> BaikaiError -> IO ()`.
- `baikai-trace-otel/test/Main.hs:8,93,155` — uses `ProviderError "stub-otel-boom"`.

Both will switch from the bare `ProviderError "x"` constructor to the smart
constructor `providerError "x"` (see Milestone 2).

**Test framework.** Each `baikai` test module (e.g. `baikai/test/CostSpec.hs`)
exports `tests :: TestTree` built from `tasty` + `tasty-hunit` (`testGroup`,
`testCase`, `(@?=)`, `assertBool`). The aggregator `baikai/test/Main.hs` imports
each spec module qualified and lists its `tests` in a top-level `testGroup`. New
test modules follow the same pattern and must be added both to
`baikai/test/Main.hs` and to the `other-modules:` list of the `baikai-test`
suite in `baikai/baikai.cabal` (around lines 129–159).


## Plan of Work

The work is four milestones. M1 (usage aggregation) is independent and lands
first as a low-risk warm-up. M2 redesigns the error type in the core package and
keeps everything compiling via smart constructors. M3 wires the providers to
produce rich errors — this is where the user-visible retry classification
actually arrives. M4 does version/CHANGELOG hygiene and a full green build.

Each milestone ends in a committed, compiling, test-passing state.


### Milestone 1 — Usage and Cost become combinable

Scope: add `Semigroup` and `Monoid` instances to `Cost`, `CostBreakdown`, and
`Usage`, plus a convenience `sumUsage :: Foldable f => f Usage -> Usage`. At the
end, a caller can write `mconcat usages` or `foldMap responseUsage responses` and
get a correct total; new unit tests prove the field-by-field addition and the
`reasoningTokens` presence rule.

Edits:

1. In `baikai/src/Baikai/Cost.hs`, add instances after the `_Cost` definition:

   ```haskell
   instance Semigroup CostBreakdown where
     a <> b =
       CostBreakdown
         { inputUsd = inputUsd a + inputUsd b,
           outputUsd = outputUsd a + outputUsd b,
           cachedInputUsd = cachedInputUsd a + cachedInputUsd b,
           cachedWriteUsd = cachedWriteUsd a + cachedWriteUsd b
         }

   instance Monoid CostBreakdown where
     mempty = _CostBreakdown

   instance Semigroup Cost where
     a <> b = Cost {usd = usd a + usd b, breakdown = breakdown a <> breakdown b}

   instance Monoid Cost where
     mempty = _Cost
   ```

   Note: `mempty = _Cost` reuses the existing zero value, so the identity law
   `mempty <> x == x` holds by construction (adding zero rationals).

2. In `baikai/src/Baikai/Usage.hs`, add the reasoning-token combiner and the
   instances after `_Usage`:

   ```haskell
   -- | Combine two optional reasoning-token counts. Presence wins: an
   -- absent side counts as zero, but the result is only 'Nothing' when
   -- both sides are 'Nothing', so a non-reasoning call summed with a
   -- reasoning call keeps the reasoning total.
   combineReasoning :: Maybe Natural -> Maybe Natural -> Maybe Natural
   combineReasoning Nothing Nothing = Nothing
   combineReasoning a b = Just (fromMaybe 0 a + fromMaybe 0 b)

   instance Semigroup Usage where
     a <> b =
       Usage
         { inputTokens = inputTokens a + inputTokens b,
           outputTokens = outputTokens a + outputTokens b,
           cacheReadTokens = cacheReadTokens a + cacheReadTokens b,
           cacheWriteTokens = cacheWriteTokens a + cacheWriteTokens b,
           reasoningTokens = combineReasoning (reasoningTokens a) (reasoningTokens b),
           totalTokens = totalTokens a + totalTokens b,
           cost = cost a <> cost b
         }

   instance Monoid Usage where
     mempty = _Usage

   -- | Total a collection of per-call usages into one.
   sumUsage :: Foldable f => f Usage -> Usage
   sumUsage = foldl' (<>) mempty
   ```

   This requires importing `fromMaybe` from `Data.Maybe` and `foldl'` (available
   from `Data.Foldable` or `Data.List`; prefer `Data.Foldable (foldl')`). Add
   these imports to the existing import block of `Baikai/Usage.hs`.

3. Export the new helper: change the module export header of
   `baikai/src/Baikai/Usage.hs` from `module Baikai.Usage (Usage (..), _Usage)`
   to `module Baikai.Usage (Usage (..), _Usage, sumUsage)`. The instances are
   exported automatically. `combineReasoning` stays unexported (internal).

4. Add a new test module `baikai/test/UsageSpec.hs` exporting `tests :: TestTree`
   that asserts:
   - `mempty <> u == u` and `u <> mempty == u` for a non-trivial `u` (identity).
   - `u1 <> u2` adds each numeric field (construct two `Usage` values with
     distinct field values and assert the sum).
   - `combineReasoning` behaviour via the public instance:
     `reasoningTokens (rJust5 <> rNothing) == Just 5`,
     `reasoningTokens (rNothing <> rNothing) == Nothing`,
     `reasoningTokens (rJust2 <> rJust3) == Just 5`.
   - `cost` totals: build two `Usage` whose `cost.usd` are `1 % 100` and
     `2 % 100`; assert `usd (cost (u1 <> u2)) == 3 % 100` and that the
     `breakdown` fields likewise add.
   - `sumUsage [u1, u2, u3]` equals `u1 <> u2 <> u3`.

5. Register the new module: add `import UsageSpec qualified` and
   `UsageSpec.tests` to `baikai/test/Main.hs`, and add `UsageSpec` to the
   `other-modules:` of the `baikai-test` suite in `baikai/baikai.cabal`.

Acceptance: `cabal test baikai:baikai-test` passes, including the new
`UsageSpec` group. A reader can also open a `cabal repl baikai` and evaluate the
transcript in Validation below.


### Milestone 2 — Redesign Baikai.Error into a categorised, retry-aware type

Scope: replace the four flat constructors with a single record carrying an
`ErrorCategory`, optional HTTP status, optional retry-after-seconds, and optional
process exit code; add smart constructors that preserve old ergonomics; add
`isRetryable` and `retryAfterSeconds` accessors; add the pure
`classifyHttpStatus` helper. Update the two core construction sites (`Auth`,
`Registry`) and every test that referenced the old constructors. At the end the
entire workspace compiles and all pre-existing tests pass; no provider behaviour
has changed yet (that is M3), but the type is ready.

Rewrite `baikai/src/Baikai/Error.hs` to:

```haskell
module Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    -- smart constructors
    providerError,
    invalidRequest,
    decodeError,
    processError,
    rateLimited,
    -- accessors
    isRetryable,
    retryAfterSeconds,
    -- pure classification helper for provider packages
    classifyHttpStatus,
  )
where

import Control.Exception (Exception (displayException))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | A provider-neutral category for a failed call. Callers switch on
-- this to decide policy (retry, surface to user, abort). The set is
-- closed and stable; new HTTP nuances map onto an existing member
-- rather than growing this type.
data ErrorCategory
  = -- | Authentication/authorization failure: missing or rejected
    -- credentials (HTTP 401/403, or a missing API-key env var).
    AuthError
  | -- | The provider rate-limited the request (HTTP 429). Usually
    -- retryable after a delay; see 'retryAfterSeconds'.
    RateLimited
  | -- | The request exceeded the model's context window or a related
    -- size limit. Not retryable as-is; the caller must shrink input.
    ContextOverflow
  | -- | The request was malformed or otherwise rejected as invalid
    -- (HTTP 400/404/422). Not retryable without changes.
    InvalidRequest
  | -- | A transient server-side or network failure (HTTP 408/5xx, or a
    -- connection error). Safe to retry, ideally with backoff.
    TransientError
  | -- | The response could not be decoded/parsed into the expected
    -- shape.
    DecodeFailure
  | -- | A subprocess (the @claude -p@ or @codex exec@ CLI provider)
    -- exited non-zero. The exit code is in 'exitCode'.
    ProcessFailure
  | -- | No provider handler was registered for the model's API tag.
    ProviderUnavailable
  | -- | Anything not covered above.
    OtherError
  deriving stock (Eq, Show, Generic)

-- | A failed baikai call. The 'category' drives caller policy; the
-- remaining fields carry optional structured hints. No record-field
-- prefixes (project convention): fields are plain names.
data BaikaiError = BaikaiError
  { category :: !ErrorCategory,
    -- | Human-readable detail, safe to log.
    message :: !Text,
    -- | The HTTP status code, when the failure came from an HTTP call.
    httpStatus :: !(Maybe Int),
    -- | Seconds to wait before retrying, parsed from a @Retry-After@
    -- header when present and integer-valued.
    retryAfterSeconds :: !(Maybe Int),
    -- | The subprocess exit code, for 'ProcessFailure'.
    exitCode :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

instance Exception BaikaiError where
  displayException e =
    "BaikaiError(" <> show (category e) <> "): " <> Text.unpack (message e)

-- | Base value with everything absent; used by smart constructors.
baseError :: ErrorCategory -> Text -> BaikaiError
baseError c m =
  BaikaiError
    { category = c,
      message = m,
      httpStatus = Nothing,
      retryAfterSeconds = Nothing,
      exitCode = Nothing
    }

-- Smart constructors. These keep call sites close to the old API: an
-- old @ProviderError "x"@ becomes @providerError "x"@, etc.

-- | A generic provider failure with no further classification.
providerError :: Text -> BaikaiError
providerError = baseError OtherError

-- | A request rejected as invalid.
invalidRequest :: Text -> BaikaiError
invalidRequest = baseError InvalidRequest

-- | A response that failed to decode.
decodeError :: Text -> BaikaiError
decodeError = baseError DecodeFailure

-- | A subprocess that exited non-zero. First argument is the exit code.
processError :: Int -> Text -> BaikaiError
processError code m = (baseError ProcessFailure m) {exitCode = Just code}

-- | A rate-limit failure with an optional retry-after hint (seconds).
rateLimited :: Maybe Int -> Text -> BaikaiError
rateLimited secs m = (baseError RateLimited m) {retryAfterSeconds = secs, httpStatus = Just 429}

-- | Whether the application may sensibly retry this error. True for
-- rate limits and transient server/network failures; False otherwise.
-- (Note: 'retryAfterSeconds' may still be 'Nothing' even when this is
-- True, meaning "retryable but no server-suggested delay".)
isRetryable :: BaikaiError -> Bool
isRetryable e = case category e of
  RateLimited -> True
  TransientError -> True
  _ -> False

-- | Map an HTTP status code (and an optional already-parsed
-- retry-after-seconds value) to a category. Pure and network-free so it
-- can be unit-tested in the core package; provider packages call it
-- after extracting the status from their SDK's exception type.
--
-- The body of a 400 may indicate a context-window overflow, but this
-- helper only sees the status code; callers that can inspect the body
-- should special-case overflow before falling back here.
classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory
classifyHttpStatus status _retryAfter
  | status == 401 || status == 403 = AuthError
  | status == 429 = RateLimited
  | status == 408 = TransientError
  | status == 400 || status == 404 || status == 422 = InvalidRequest
  | status >= 500 = TransientError
  | otherwise = OtherError
```

Notes for the implementer:

- The `displayException` override gives downstream tracing/logging a stable,
  category-tagged string. The existing OTel adapter and `TraceSpec` only need a
  `Show`/`Exception` instance; both remain satisfied.
- After this rewrite, update the two **core** construction sites:
  - `baikai/src/Baikai/Auth.hs:59` — change `throwIO (ProviderError ("env var "
    <> Text.pack name <> " is not set"))` to use a new smart constructor for an
    auth/config failure. Add `authError :: Text -> BaikaiError` (= `baseError
    AuthError`) to the export list and use `throwIO (authError ("env var " <>
    Text.pack name <> " is not set"))`. (Add `authError` to the export list and
    smart-constructor block above.)
  - `baikai/src/Baikai/Provider/Registry.hs:99` — change `ProviderError ("No
    provider registered for API: " <> ...)` to a new `providerUnavailable :: Text
    -> BaikaiError` (= `baseError ProviderUnavailable`). Add it to the exports
    and smart-constructor block, and use it here.
- Update tests that referenced the old constructors:
  - `baikai/test/TraceSpec.hs` — replace `ProviderError "boom"` →
    `providerError "boom"`, `ProviderError "stub-failure"` →
    `providerError "stub-failure"`, and import the smart constructor instead of
    the constructor. If `registerFail` pattern-matches on the error shape,
    confirm it only passes the value through (it does: it stores the error to be
    thrown), so the rename suffices.
  - `baikai-trace-otel/test/Main.hs` — replace `ProviderError "stub-otel-boom"`
    → `providerError "stub-otel-boom"` and adjust the import.
- The top-level `Baikai` module (`baikai/src/Baikai.hs:20,46`) re-exports
  `module Baikai.Error`. Because we export the new names, the public surface
  picks them up automatically. Confirm the re-export still compiles (no hidden
  name it relied on was removed besides the bare constructors; `RequestInvalid`
  was unused).

Acceptance: `cabal build all` compiles; `cabal test all` passes with no
behavioural change to providers yet. Add a focused `baikai/test/ErrorSpec.hs`
(exporting `tests :: TestTree`, registered in `Main.hs` and the cabal
`other-modules`) asserting:
- `classifyHttpStatus 401 Nothing == AuthError`
- `classifyHttpStatus 429 Nothing == RateLimited`
- `classifyHttpStatus 400 Nothing == InvalidRequest`
- `classifyHttpStatus 503 Nothing == TransientError`
- `classifyHttpStatus 502 Nothing == TransientError`
- `isRetryable (rateLimited (Just 30) "slow down") == True`
- `retryAfterSeconds (rateLimited (Just 30) "slow down") == Just 30`
- `isRetryable (invalidRequest "bad") == False`
- `exitCode (processError 2 "boom") == Just 2`


### Milestone 3 — Providers classify real failures

IMPORTANT (revised 2026-06-21): the original draft of this milestone assumed the
API providers throw a `BaikaiError` from `completeRequest`. They do not — they
surface HTTP failures *in-band*, folding them into an error-`Response`
(`stopReason = ErrorReason`, `errorMessage :: Maybe Text`) via
`Baikai.Stream.streamingComplete`. The CLI/`Auth`/`Registry` paths (already
handled in M2) are the only ones that throw. To deliver typed categories on the
API path we therefore carry a structured `errorInfo :: Maybe BaikaiError` along
the in-band channel. See the four 2026-06-21 entries in the Decision Log for the
full design rationale. This milestone is split into M3a (core threading,
behaviour-neutral) and M3b (provider classification); the Progress section lists
both.

Scope (M3a): in core `baikai`, add `ToJSON` to `ErrorCategory`/`BaikaiError`; add
`errorInfo :: !(Maybe BaikaiError)` to `Baikai.Stream.Event.TerminalPayload` and
`Baikai.Response.Response`; thread it through the `Baikai.Stream` reassembly
(`ReassemblyState.terminal` and `finalizeState`); add `doneTerminal` /
`errorTerminal` helper constructors to `Baikai.Stream.Event` and convert every
`TerminalPayload` construction site (≈14, across `Baikai.Stream`, both providers'
`Api.hs`, and the effectful stub test) to use them so no partial-record literal
can leave `errorInfo` uninitialised; update tests that pattern-match or build
these. After M3a, `errorInfo` is always `Nothing` and all tests pass — a pure
plumbing change.

Scope (M3b): make the API providers populate `errorInfo`. A 429 from Anthropic or
OpenAI now surfaces (on the returned `Response` and on the streamed `EventError`)
as `category = RateLimited` with `retryAfterSeconds`, a 401 as `AuthError`, a 400
as `InvalidRequest` (or `ContextOverflow` when the body says so), and a
5xx/connection failure as `TransientError`. Two classification entry points per
provider: `classifyException` for the worker-thread's caught `ClientError` (HTTP
status based), carried to the end-of-stream handler through an
`IORef (Maybe BaikaiError)`; and `classifyErrorValue` for mid-stream streamed
error events (the provider's native error JSON `Value`), applied inside
`translate`.

First, confirm the exact exception type by reading the SDKs on disk (located via
`mori`):

```bash
mori registry show MercuryTechnologies/openai --full
mori registry show MercuryTechnologies/claude --full
```

The OpenAI SDK source is at `/Users/shinzui/Keikaku/hub/haskell/openai-project`
and the Claude SDK at `/Users/shinzui/Keikaku/hub/haskell/claude-project`. Read
how each performs requests and what it throws/returns. Both depend on
`servant-client`; the expected carrier is `Servant.Client.ClientError`. Confirm
whether the SDK throws the `ClientError` as an exception (so it lands in the
existing `try @SomeException`) or returns it in an `Either` that baikai then
turns into an exception. The existing `try @SomeException` already catches
whatever is thrown; the new code's job is to *recognise* it.

Add a small classification helper in **each** provider package (not core,
because it touches `servant-client` and `http-client` types). Suggested location:
a new internal module `Baikai.Provider.Claude.ErrorClass` (and the OpenAI
analogue `Baikai.Provider.OpenAI.ErrorClass`), each exporting:

```haskell
-- | Convert any caught exception from the SDK into a categorised
-- 'BaikaiError'. Recognises servant-client 'ClientError'; otherwise
-- falls back to a generic provider error carrying the displayed text.
classifyException :: SomeException -> BaikaiError
```

Implementation outline (same in both packages; the only difference is the module
prefix and the package's existing imports):

1. `fromException @ClientError ex` (from `Control.Exception` +
   `Servant.Client (ClientError(..))`). On `Just (FailureResponse _req resp)`:
   - Extract the status: `responseStatusCode resp :: Network.HTTP.Types.Status`,
     then `statusCode :: Status -> Int` from `Network.HTTP.Types.Status`.
   - Extract Retry-After: scan `responseHeaders resp :: Seq (HeaderName,
     ByteString)` for the `Retry-After` header (`hRetryAfter` is not in
     http-types; match the header name `"Retry-After"` case-insensitively via
     `mk`/`CI`), parse its value as an integer number of seconds with
     `readMaybe`; non-integer (date form) → `Nothing`.
   - Inspect the response body for an overflow signal: if the status is 400/422
     and the body text contains a known marker (case-insensitive match on
     substrings like `"context length"`, `"context_length_exceeded"`,
     `"maximum context"`, `"prompt is too long"`, `"too many tokens"`), set the
     category to `ContextOverflow` instead of the status-derived category.
     Otherwise use `classifyHttpStatus status retryAfter`.
   - Build the `BaikaiError` with `category`, `message` = a short string
     including status and a snippet of the body, `httpStatus = Just status`,
     `retryAfterSeconds`, `exitCode = Nothing`. Use the record update on a
     `providerError`/`baseError`-style value, or expose a `mkHttpError`
     smart-ish constructor; simplest is to start from `providerError msg` and set
     `category`/`httpStatus`/`retryAfterSeconds` via record update (all fields
     are exported, so record-update syntax works).
   - On `Just (ConnectionError _)` → `TransientError` (network failed before any
     HTTP status; `httpStatus = Nothing`).
   - On `Just (DecodeFailure t _)` / `Just UnsupportedContentType{}` /
     `Just InvalidContentTypeHeader{}` → `decodeError` with the detail text.
   - On `Nothing` (not a `ClientError`): also try `fromException @HttpException`
     (from `Network.HTTP.Client`) in case the SDK surfaces a raw http-client
     exception; map a `HttpExceptionRequest _ (StatusCodeException resp _)` the
     same way via its `responseStatus`. If that also fails, return
     `providerError (Text.pack (displayException ex))`.

2. Wire it into the API handlers (in-band, do NOT throw — see the Decision Log).
   In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:
   - Add an `IORef (Maybe BaikaiError)` to the producer state (`ProducerState`)
     and create it alongside the channel.
   - In the forked `worker`, change the exception arm from
     `Left e -> writeChan ch (Just (errorEvent (Text.pack (displayException e))))`
     to `Left e -> writeIORef errInfoRef (Just (classifyException e))` (still
     followed by the existing `writeChan ch Nothing` that closes the channel).
     Because the worker now writes no terminal event on exception, control reaches
     `step`'s "channel closed before a terminal event" arm.
   - Make that recovery arm (currently `unexpectedEoS`) read `errInfoRef`: when it
     holds `Just be`, emit `EventError (errorTerminal Stop.ErrorReason
     (finalMessageOnError ass now (message be)) (Just be))`; when `Nothing`, keep
     the existing "stream ended without message_stop" error (via `errorTerminal
     ... Nothing`).
   - In `translate`, classify mid-stream streamed errors: the
     `Messages.Error {error = errVal}` arm computes
     `let be = classifyErrorValue errVal` and emits
     `EventError (errorTerminal Stop.ErrorReason (finalMessageOnError ass now
     (renderAnthropicError errVal)) be)`.
   Do the symmetric edits in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`
   (same producer/worker/translate shape; its streamed-error arm is around line
   494). The blocking `completeRequest` path needs no special handling: it is
   `streamingComplete stream`, so the `errorInfo` set on the terminal flows
   through reassembly onto `Response.errorInfo` automatically (M3a wired that).

3. Point the **CLI** providers at the new constructors (pure renames, no new
   classification needed):
   - `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`: `DecodeError x` →
     `decodeError x`; `ProcessError n x` → `processError n x`; `ProviderError x`
     → `providerError x`. Update the import from
     `import Baikai.Error (BaikaiError (..))` to import the smart constructors:
     `import Baikai.Error (BaikaiError, decodeError, processError, providerError)`.
   - `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`: `ProviderError x` →
     `providerError x`; `ProcessError n x` → `processError n x`; same import
     adjustment.

4. Add the new modules to each provider package's `exposed-modules:` (or
   `other-modules:` if they should stay private — prefer `other-modules:` since
   `classifyException` is internal glue) in `baikai-claude/baikai-claude.cabal`
   and `baikai-openai/baikai-openai.cabal`. Ensure each package's
   `build-depends` already lists `servant-client`, `http-client`, `http-types`
   (add `http-types` if missing — it provides `Network.HTTP.Types.Status`), and
   `case-insensitive` (for header-name matching; add if missing).

5. Tests. Provider tests cannot hit the network, so test the **pure** classifier
   against synthetic `ClientError` values:
   - Add `baikai-claude/test/ErrorClassSpec.hs` (and the OpenAI analogue) that
     constructs a `FailureResponse` with a fabricated `ResponseF` carrying status
     429 and a `Retry-After: 30` header, passes it through `classifyException`
     (wrapped in `toException`), and asserts the result is
     `category == RateLimited`, `httpStatus == Just 429`,
     `retryAfterSeconds == Just 30`. Add a 401 → `AuthError` case, a 400 with an
     overflow-marker body → `ContextOverflow`, a 400 with an ordinary body →
     `InvalidRequest`, a 503 → `TransientError`, and a non-`ClientError`
     exception (e.g. `toException (userError "weird")`) → `OtherError` with the
     displayed text.
   - Constructing a `ResponseF`/`ClientError` by hand requires reading the
     `servant-client` types; the SDK source on disk (via `mori`) and
     `servant-client-core`'s `Servant.Client.Core.Response` show the field
     names. Record the exact constructor shape used in the Decision Log so a
     future reader need not rediscover it.
   - Register each new test module in that package's test suite (`main-is`
     aggregator and `other-modules` in the package's `.cabal`), mirroring how
     `baikai/test/Main.hs` aggregates.

Acceptance: `cabal test all` passes including the new provider classification
specs. The classification specs demonstrate, without a network, that a 429
carrier becomes `RateLimited` + `Just 30`, a 401 becomes `AuthError`, an
overflow 400 becomes `ContextOverflow`, and an unknown exception degrades to
`OtherError` carrying the original text.


### Milestone 4 — Versioning, changelog, and full green build

Scope: bump versions and document the changes; run the full check.

1. Bump `version:` in each changed package's cabal file by one minor step:
   `baikai/baikai.cabal` `0.1.1.0` → `0.1.2.0`; `baikai-claude` and
   `baikai-openai` likewise from their current `0.1.1.0` → `0.1.2.0`. (Read each
   cabal's current `version:` line first; do not assume.) `baikai-trace-otel`
   only had a test touched, not its library; bump it only if its library code
   changed — it did not, so leave its version unless the test change requires it.
2. Update `CHANGELOG.md` under `## [Unreleased]`, adding an `### Added` entry for
   `Usage`/`Cost` `Semigroup`/`Monoid` instances + `sumUsage`, an `### Added`
   entry for the `ErrorCategory`, `isRetryable`, `retryAfterSeconds`, and
   `classifyHttpStatus` surface, and a `### Changed`/`### Breaking` entry noting
   that `BaikaiError`'s bare constructors were replaced by a record + smart
   constructors (migration: `ProviderError "x"` → `providerError "x"`, etc.).
   Follow the existing Keep-a-Changelog headings already used in the file.
3. Run `nix fmt` to format, then `nix flake check` (which builds and tests all
   packages) — or, if Nix is unavailable, `cabal build all && cabal test all`.

Acceptance: formatting clean, all packages build, all tests pass.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`,
inside the dev shell (`nix develop`, or `direnv allow` once so it auto-enters).

Milestone 1:

```bash
# edit baikai/src/Baikai/Cost.hs, baikai/src/Baikai/Usage.hs
# add baikai/test/UsageSpec.hs; register it in baikai/test/Main.hs and baikai.cabal
cabal build baikai
cabal test baikai:baikai-test
```

Expected tail of a passing run (names illustrative):

```text
Usage
  identity: mempty <> u == u:      OK
  adds numeric fields:             OK
  reasoning presence rule:         OK
  cost totals add:                 OK
  sumUsage equals fold:            OK
All N tests passed
```

Quick REPL proof of the aggregation (optional but convincing):

```bash
cabal repl baikai
```

```haskell
ghci> import Baikai.Usage
ghci> import Baikai.Cost
ghci> let u1 = _Usage { inputTokens = 10, outputTokens = 5, totalTokens = 15, reasoningTokens = Just 2 }
ghci> let u2 = _Usage { inputTokens = 3,  outputTokens = 1, totalTokens = 4,  reasoningTokens = Nothing }
ghci> let s = u1 <> u2
ghci> (inputTokens s, outputTokens s, totalTokens s, reasoningTokens s)
(13,6,19,Just 2)
```

Commit:

```bash
git add -A
git commit -m "feat(baikai): combinable Usage/Cost (Semigroup/Monoid) + sumUsage

Add field-wise Semigroup/Monoid instances to Cost, CostBreakdown, and
Usage, plus sumUsage, so callers can total per-call usage and cost.
reasoningTokens combines as presence-wins.

ExecPlan: docs/plans/25-enrich-baikai-error-taxonomy-and-add-usage-aggregation.md
Intention: intention_01kvnefc3qe9ashtt30m8xszy9"
```

Milestone 2:

```bash
# rewrite baikai/src/Baikai/Error.hs; update Auth.hs, Registry.hs
# update baikai/test/TraceSpec.hs and baikai-trace-otel/test/Main.hs
# add baikai/test/ErrorSpec.hs; register it in Main.hs and baikai.cabal
cabal build all
cabal test all
```

Commit (after green):

```bash
git add -A
git commit -m "feat(baikai)!: categorised BaikaiError with retry hints

Replace the four flat BaikaiError constructors with a record carrying an
ErrorCategory, optional httpStatus, retryAfterSeconds, and exitCode. Add
smart constructors (providerError/invalidRequest/decodeError/processError/
rateLimited/authError/providerUnavailable), isRetryable, retryAfterSeconds,
and the pure classifyHttpStatus helper. Update core throw sites and tests.

BREAKING CHANGE: BaikaiError constructors changed; use the smart
constructors (e.g. providerError \"x\" for the old ProviderError \"x\").

ExecPlan: docs/plans/25-enrich-baikai-error-taxonomy-and-add-usage-aggregation.md
Intention: intention_01kvnefc3qe9ashtt30m8xszy9"
```

Milestone 3:

```bash
mori registry show MercuryTechnologies/openai --full
mori registry show MercuryTechnologies/claude --full
# read the SDK sources; add Baikai.Provider.{Claude,OpenAI}.ErrorClass
# wire into the two Api.hs handlers; rename CLI throws to smart constructors
# add provider ErrorClassSpec tests; register in each package's test suite/cabal
cabal build all
cabal test all
```

Commit:

```bash
git add -A
git commit -m "feat(baikai-claude,baikai-openai): classify provider failures

Map caught servant-client ClientErrors to BaikaiError categories: 401/403
-> AuthError, 429 -> RateLimited (+Retry-After seconds), 400 overflow body
-> ContextOverflow, 400/404/422 -> InvalidRequest, 5xx/connection ->
TransientError, decode failures -> DecodeFailure. Point CLI providers at
the new smart constructors. Add network-free classifier tests.

ExecPlan: docs/plans/25-enrich-baikai-error-taxonomy-and-add-usage-aggregation.md
Intention: intention_01kvnefc3qe9ashtt30m8xszy9"
```

Milestone 4:

```bash
# bump versions in the three changed cabal files; update CHANGELOG.md
nix fmt
nix flake check     # or: cabal build all && cabal test all
git add -A
git commit -m "chore(release): baikai 0.1.2.0, providers 0.1.2.0

Version bumps and CHANGELOG for the BaikaiError taxonomy and Usage
aggregation work.

ExecPlan: docs/plans/25-enrich-baikai-error-taxonomy-and-add-usage-aggregation.md
Intention: intention_01kvnefc3qe9ashtt30m8xszy9"
```


## Validation and Acceptance

The change is internal (a library API), so acceptance is expressed as tests that
fail before and pass after, plus REPL transcripts a human can reproduce.

1. **Usage aggregation (M1).** `cabal test baikai:baikai-test` runs `UsageSpec`.
   Before M1 the module does not exist; after, the group passes. The REPL
   transcript above shows `u1 <> u2` summing tokens to `(13,6,19)` and
   `reasoningTokens` to `Just 2` (presence wins over the `Nothing` operand).

2. **Error type (M2).** `ErrorSpec` asserts the `classifyHttpStatus` mapping and
   the accessor behaviour exactly as listed in the Milestone 2 acceptance block.
   A reader can reproduce in `cabal repl baikai`:

   ```haskell
   ghci> import Baikai.Error
   ghci> classifyHttpStatus 429 Nothing
   RateLimited
   ghci> isRetryable (rateLimited (Just 30) "slow down")
   True
   ghci> retryAfterSeconds (rateLimited (Just 30) "slow down")
   Just 30
   ghci> isRetryable (invalidRequest "bad shape")
   False
   ```

3. **Provider classification (M3).** The provider `ErrorClassSpec` constructs
   synthetic `ClientError`s (no network) and asserts:
   - 429 + `Retry-After: 30` → `category == RateLimited`, `httpStatus == Just
     429`, `retryAfterSeconds == Just 30`.
   - 401 → `category == AuthError`.
   - 400 with body containing `"context length"` → `category == ContextOverflow`.
   - 400 with an ordinary body → `category == InvalidRequest`.
   - 503 → `category == TransientError`.
   - `toException (userError "weird")` → `category == OtherError` with the
     displayed text preserved in `message`.

4. **Whole-workspace green (M4).** `nix flake check` (or `cabal build all &&
   cabal test all`) completes with every package's suite passing, and `nix fmt`
   leaves no diff.

End-to-end behaviour a caller now gets (the point of the whole plan): catching a
`BaikaiError` from `completeRequest`, a caller can write

```haskell
case category err of
  RateLimited     -> delayThenRetry (retryAfterSeconds err)
  TransientError  -> backoffRetry
  ContextOverflow -> shrinkAndRetry
  _               -> abort err
```

and have it route correctly regardless of whether the failure came from
Anthropic or OpenAI — which was impossible before, because every failure was a
`ProviderError` carrying only prose.


## Idempotence and Recovery

Every milestone is additive and re-runnable. The edits are deterministic source
changes; re-running `cabal build`/`cabal test` after a partial edit simply
recompiles. If a milestone's build breaks, the prior milestone's commit is a
known-good checkpoint to reset to (`git reset --hard` to the last milestone
commit, or `git checkout -- <file>` to discard a single file's changes).

The only behaviour-changing edit is M2's rewrite of `Baikai.Error`. Because the
smart constructors deliberately mirror the old constructor names (lowercased),
the migration across call sites is a mechanical rename; if a site is missed, the
compiler flags it as an out-of-scope constructor (`ProviderError` no longer in
scope), which is a safe, loud failure rather than silent drift. No data is
migrated and nothing is deleted on disk, so there is no destructive step and no
backup is required.

Recovery for M3 if the synthetic-`ClientError` test proves hard to construct:
fall back to testing the pure `classifyHttpStatus`/overflow-substring logic
directly (factor the body-marker check into a pure
`classifyHttpStatusWithBody :: Int -> Maybe Int -> Text -> ErrorCategory` in
core and test that), and keep the `ClientError`-extraction glue thin and covered
by the live smoke tests in `baikai-smoke` (which already skip when API keys are
absent). Record this fallback in the Decision Log if taken.


## Interfaces and Dependencies

Libraries and modules involved, and why:

- `baikai` (core) — owns the pure types and helpers. After this plan its public
  surface (re-exported through the top-level `Baikai` module) additionally
  exports, from `Baikai.Usage`: `sumUsage :: Foldable f => f Usage -> Usage`, and
  the `Semigroup`/`Monoid Usage` instances; from `Baikai.Cost`: the
  `Semigroup`/`Monoid` instances for `Cost` and `CostBreakdown`; from
  `Baikai.Error`: `ErrorCategory(..)`, the redesigned `BaikaiError(..)` record,
  smart constructors `providerError`, `invalidRequest`, `decodeError`,
  `processError`, `rateLimited`, `authError`, `providerUnavailable`, the
  accessors `isRetryable :: BaikaiError -> Bool` and `retryAfterSeconds ::
  BaikaiError -> Maybe Int` (the latter is also the record field), and the pure
  `classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory`. The core package
  gains **no** new external dependency (it must remain HTTP-library-free); the
  only new imports are `Data.Maybe (fromMaybe)` and `Data.Foldable (foldl')` in
  `Baikai.Usage`, and `Data.Text`/`Control.Exception` already available.

- `baikai-claude`, `baikai-openai` — own the impure classification glue
  `classifyException :: SomeException -> BaikaiError` in new internal modules
  `Baikai.Provider.Claude.ErrorClass` / `Baikai.Provider.OpenAI.ErrorClass`.
  These depend on `servant-client` (`Servant.Client (ClientError(..))` and
  `servant-client-core`'s `Response`/`ResponseF` for `responseStatusCode`,
  `responseHeaders`, `responseBody`), `http-types`
  (`Network.HTTP.Types.Status (statusCode)` and header-name handling),
  `http-client` (`Network.HTTP.Client (HttpException(..),
  HttpExceptionContent(..))` for the raw-exception fallback), and
  `case-insensitive` (matching the `Retry-After` header name). `servant-client`,
  `http-client`, and `http-client-tls` are already declared in both packages'
  cabal files; add `http-types` and `case-insensitive` if `cabal build` reports
  them missing.

- `baikai-trace-otel` — only its test references `BaikaiError`; it needs the
  smart-constructor import change, no library/dependency change.

Function/instance signatures that must exist at the end of each milestone:

- End of M1: `instance Semigroup Cost`, `instance Monoid Cost`,
  `instance Semigroup CostBreakdown`, `instance Monoid CostBreakdown`,
  `instance Semigroup Usage`, `instance Monoid Usage`,
  `sumUsage :: Foldable f => f Usage -> Usage`.
- End of M2: the `Baikai.Error` surface listed above, compiling, with all
  pre-existing tests green and `ErrorSpec` added.
- End of M3: `classifyException :: SomeException -> BaikaiError` in each provider
  package, wired into both `Api.hs` handlers and exercised by `ErrorClassSpec` in
  each provider's test suite; CLI providers using the smart constructors.
- End of M3a: `ToJSON ErrorCategory`/`ToJSON BaikaiError`; `errorInfo ::
  !(Maybe BaikaiError)` on `Baikai.Stream.Event.TerminalPayload` and
  `Baikai.Response.Response`; `doneTerminal :: StopReason -> Message ->
  TerminalPayload` and `errorTerminal :: StopReason -> Message -> Maybe
  BaikaiError -> TerminalPayload` exported from `Baikai.Stream.Event`; reassembly
  threads `errorInfo` onto `Response`. Behaviour-neutral; all tests green.
- End of M3b: `classifyException :: SomeException -> BaikaiError` and
  `classifyErrorValue :: Aeson.Value -> Maybe BaikaiError` in each provider's
  `ErrorClass` module, wired into the producers so `Response.errorInfo` and the
  streamed `EventError`'s `errorInfo` are populated; `ErrorClassSpec` in each
  provider's test suite. CLI providers already use the smart constructors (M2).
- End of M4: bumped versions, CHANGELOG entries, fully green `nix flake check`.


## Revision Notes

- 2026-06-21 — Expanded Milestone 3 from "providers throw typed errors" to the
  in-band design after discovering (during implementation) that the API providers
  never throw on HTTP failures; they fold them into an error-`Response` via
  `streamingComplete`. The user chose the "Full" option: deliver typed categories
  on the `completeRequest`/streaming path by carrying `errorInfo :: Maybe
  BaikaiError` on `TerminalPayload` and `Response`. M3 is now split into M3a
  (core threading, behaviour-neutral) and M3b (provider classification). The
  mechanical CLI-provider constructor renames that the old Milestone 3 step 3
  described were already completed under M2 (to keep every commit compiling);
  that step is retained above only as historical context. See the 2026-06-21
  Decision Log entries for the design and its rationale.
