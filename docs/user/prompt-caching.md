---
type: Guide
title: Prompt Caching
description: Configure cache retention and inspect cache token and cost accounting.
docId: DOC-8
tags: [prompt-caching, cache-retention, usage, cost, providers]
generated:
  by: human:nadeem
  at: 2026-08-27T16:45:37Z
---

# Prompt Caching

Prompt caching lets a provider store a stable prefix of your request —
a long system prompt, a fixed tool catalog, a big reference document —
and reuse it on later calls instead of re-processing it. You pay a
one-time *write* to seed the cache, then cheaper *reads* on every
subsequent call that reuses the same prefix.

Baikai exposes this as a single provider-agnostic preference and reports
the cache split back to you in `Usage` and `Cost`, so you can confirm
the cache is actually hitting.

## The preference: `CacheRetention`

Set `cacheRetention` on `Options`. It is a coarse *retention* bucket,
not a per-block control — you ask for caching and each provider maps the
bucket to its own wire primitive.

```haskell
data CacheRetention
  = CacheRetentionNone   -- Do not request caching (the default when unset).
  | CacheRetentionShort  -- Provider-default ephemeral retention (Anthropic: ~5 min).
  | CacheRetentionLong   -- Long bucket (Anthropic: ttl "1h").
```

Native OpenAI controls are catalog facts for each model and endpoint. Modern
bindings, including GPT-6 Luna on Responses and GPT-5.6 on Chat Completions,
map Short to `prompt_cache_options.ttl: "30m"`. With a non-empty `systemPrompt`,
Baikai marks that stable prefix with `prompt_cache_breakpoint: {mode: "explicit"}`.
Responses sends it once as the first developer `input_text` block and omits
`instructions`; Chat retains the initial instruction role and text. Implicit
conversation caching remains enabled. Fresh conversations can therefore reuse
identical system prefixes even when their first questions differ.

| Binding | Short | Long |
|---|---|---|
| GPT-6 Luna Responses | `30m`, stable-prefix breakpoint | `12h`, stable-prefix breakpoint |
| Other curated modern native bindings | `30m`, stable-prefix breakpoint | Locally refused |
| GPT-4.1 legacy native | `in_memory`, no breakpoint | `24h`, no breakpoint |
| GPT-5.5 legacy native | Locally refused | `24h`, no breakpoint |
| Anthropic / compatible Anthropic markers | ephemeral | `1h`, or short downgrade |
| Unknown compatible Chat host | Existing behavior; no native controls | Existing behavior; no native controls |

Absent and None preferences emit no explicit controls and do not disable
provider automatic caching. A declared modern policy still establishes the
provider's default Short duration for pricing. Unknown endpoints establish no
default duration. Native unsupported preferences fail before credential lookup;
Anthropic-style compatibility downgrades retain their existing behavior.
`NativeCachePolicy` overrides older native capability flags when present.
Older persisted compatibility JSON without it preserves the previous Responses
mapping and leaves native Chat controls disabled. No model name or host spelling
grants new native capabilities. Baikai does not expose cache keys, prewarming,
explicit-only mode, per-message placement or mixed TTLs.

The [OpenAI caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
and endpoint references disagree on `12h` availability. Bounded live checks on
2026-10-25 resolved the selected endpoints: GPT-6 Luna Responses accepted `12h`
and reported its writes under `ttl_12h_tokens`; GPT-5.6 Chat rejected `12h` with
HTTP 400, stating that only `30m` is accepted. Luna Responses therefore enables
Long; other unverified modern bindings retain their local refusal.

The [standard pricing table](https://developers.openai.com/api/docs/pricing)
lists Luna Long writes at $0.25/M through 272,000 input tokens and $0.50/M above
that threshold; Short writes cost $0.125/M and $0.25/M respectively. These are
total write prices, not surcharges. The selected context tier prices the full
request, and cache-read prices do not change with retention.

Funded live shared-prefix checks passed for Luna Responses Short and Long and
GPT-5.6 Chat Short. Each pair wrote 4,864 cache tokens initially and read 4,852
with a different first question; corresponding cache costs were positive.
Luna's Short write cost was $0.000608 and Long $0.001216; both read costs were
$0.00004852. These observations prove reuse and duration-aware local pricing,
not invoice reconciliation or the behavior of other model/endpoint bindings.
Claude Sonnet 4.6 separately passed live Short and Long checks on that date.

Anthropic tool-definition markers remain gated by `supportsCacheControlOnTools`.

## Making a cached call

Caching only helps when the prefix is large and stable. Providers
enforce a minimum cacheable prefix (Anthropic, for example, will not
cache a prefix below a per-model token floor), so a one-line prompt will
not produce a cache write — put the bulk in a reused `systemPrompt` (or
tool catalog) and keep it byte-for-byte identical across calls.

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as V

main :: IO ()
main = do
  ClaudeApi.register
  let ctx =
        emptyContext
          & #systemPrompt .~ Just bigStablePreamble   -- the reused prefix
          & #messages .~ V.singleton (user "Summarize the policy in one line.")
      opts =
        emptyOptions
          & #maxTokens .~ Just 64
          & #temperature .~ Just 0.0
          & #cacheRetention .~ Just CacheRetentionLong

  -- First call seeds the cache: expect cacheWriteTokens > 0.
  first <- completeRequest Models.anthropic_claude_sonnet_4_6 ctx opts
  reportCache "write" first

  -- Second identical call reuses it: expect cacheReadTokens > 0.
  second <- completeRequest Models.anthropic_claude_sonnet_4_6 ctx opts
  reportCache "read" second
```

## Reading the cache split back

Every successful `Response` carries a `Usage` on its assistant payload.
Prompt tokens are split three ways — `inputTokens` counts only the
*non-cached* remainder, and the two cache counters are reported
separately:

```haskell
reportCache :: String -> Response -> IO ()
reportCache label resp = do
  let u    = resp ^. #message ^. #usage
      cost = u ^. #cost
  putStrLn $ label
    <> ": input="       <> show (u ^. #inputTokens)
    <> " cacheWrite="   <> show (u ^. #cacheWriteTokens)
    <> " cacheRead="    <> show (u ^. #cacheReadTokens)
    <> " total="        <> show (u ^. #totalTokens)
    <> " usd="          <> show (usdAsScientific cost)
```

`totalTokens` is the sum of `inputTokens + outputTokens +
cacheReadTokens + cacheWriteTokens`, so cached tokens are never
double-counted against `inputTokens`.

`Cost` breaks the dollar figure down the same way, since cache reads and
cache writes are priced differently from fresh input:

```haskell
data CostBreakdown = CostBreakdown
  { inputUsd       :: !Rational  -- non-cached input
  , outputUsd      :: !Rational
  , cachedInputUsd :: !Rational  -- cache reads
  , cachedWriteUsd :: !Rational  -- cache writes
  }
```

The rates come from the model's per-million-token pricing
(`ModelCost.cacheReadCost`, `cacheWriteCost`). A healthy cache shows a
large `cacheWriteUsd` on the first call and mostly `cachedInputUsd` —
much cheaper — on the calls that follow.

API usage carries `availability`: missing billed categories are not reported
zeroes. `Cost.basis.estimateReasons` records what prevents an exact standard-rate
calculation, including missing cache counters or inconsistent totals. Chat and
Responses subtract reported reads and writes from their inclusive input total;
Claude's input count is already exclusive. Repeated cumulative usage snapshots
replace counts, and partial snapshots preserve earlier reported categories.

Model pricing policies also select whole-request context rates. Astra's base
rates apply through 272000 billable input tokens; above that threshold the full
request uses the higher tier. Cache reads and writes both contribute to that
input context. Fable's short and long write rates follow the shaped marker.

`computeCostForService` distinguishes a requested tier from observed billing
facts. Missing service information produces `ServiceTierNotReported`; uncurated
tiers or speed products retain a standard-rate estimate with a reason. Server
tool products are outside token pricing and are marked when reported. The
ordinary `computeCost` helper remains a standard-policy calculation, not an
invoice or an assertion that standard service ran.

## Notes and limits

- **Opt-in controls.** `cacheRetention` defaults to `Nothing`; Baikai sends
  no cache marker until you ask. This does not disable a provider's
  automatic caching.
- **Preference, not placement.** On Claude, baikai places the top-level
  `cache_control` marker, a marker on the last tool definition, and a
  marker on a non-empty system prompt (sent as one text block) for you —
  at most three of Anthropic's four breakpoints, all with the same TTL.
  Tool markers remain gated by `supportsCacheControlOnTools`. The
  system marker lets fresh conversations with different first questions
  reuse the same tools-and-system prefix, even when no earlier
  end-of-request entry matches. The prefix must still meet the model's
  minimum cacheable size and be identical, including tools. There is no
  API here for hand-placing cache breakpoints on individual messages.
  See [Anthropic's combined caching example](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#combining-with-block-level-caching).
- **CLI providers carry what the tool reports, which is no cache split.**
  Both tools do report token counts and baikai carries them, but neither
  breaks out cache reads or writes, so the cache counters stay zero
  through the CLI providers — measure caching on the API providers.
- **Write rates follow the shaped duration.** Fable 5.1 writes cost $12.50/M
  at five minutes and $20/M at one hour. Baikai uses the marker that actually
  reached the request body, so a host compatibility downgrade uses the short
  rate. For native OpenAI, reported writes with unknown duration and duration-sensitive
  rates add `CacheDurationNotReported`. A modern default establishes Short even
  when no controls were requested. Legacy `24h` has no modern write premium. Observed service and speed are
  recorded separately; uncurated products remain explicit estimates. Baikai
  selects one shaped write duration per call and does not price a mixed-duration
  breakdown. Reported duration details are consistency checks against the aggregate
  and selected TTL; contradictory details mark usage inconsistent without adding
  the same writes twice.
- **Verify with the smoke suite.** `baikai-smoke`'s `CacheSmoke` case
  makes a write-then-read pair against a live host and asserts the
  second call reports `cacheReadTokens > 0`. Run it with a real
  `ANTHROPIC_API_KEY` to see the numbers end-to-end. Focused OpenAI checks run
  only the named endpoint, with two calls per enabled duration and no retries:

```bash
nix develop --no-write-lock-file -c cabal test baikai-smoke:baikai-smoke --test-options='--case openai-cache-responses --require-keys'
nix develop --no-write-lock-file -c cabal test baikai-smoke:baikai-smoke --test-options='--case openai-cache-chat --require-keys'
```

These use `OPENAI_API_KEY` or `OPENAI_KEY`, a nonce at the beginning of a stable
prefix, and a different fresh question for the second call. Without keys they
skip unless `--require-keys` is set. A quota failure or a skip is not live proof.

## Where next

- [Models & Providers](models-and-providers.md) — the `Usage`/`Cost`
  records in full, and the compat flags that gate long retention.
- [Streaming](streaming.md) — the same `Usage` arrives on the terminal
  `EventDone` of a stream.
- [Tools](tools.md) — tool catalogs are a common thing to cache.
