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
  | CacheRetentionLong   -- Long bucket (Anthropic: ttl "1h"; OpenAI Responses: 24h).
```

| Value | Anthropic | OpenAI-compatible |
|---|---|---|
| `CacheRetentionNone` (or unset) | no `cache_control` | no marker |
| `CacheRetentionShort` | `cache_control: {type: ephemeral}` | `{type: ephemeral}` |
| `CacheRetentionLong` | `cache_control.ttl: "1h"` | 24h |

`CacheRetentionLong` **downgrades to short automatically** on hosts that
don't advertise long retention (`supportsLongCacheRetention = False` in
the host's compat record), so the same call is safe to run against
Anthropic, OpenAI, and third-party OpenAI-compatible endpoints without
special-casing. Anthropic tool-definition markers are applied only when
the host advertises `supportsCacheControlOnTools`.

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

## Notes and limits

- **Opt-in.** `cacheRetention` defaults to `Nothing`; no marker is sent
  until you ask.
- **Preference, not placement.** On Claude, baikai places the top-level
  `cache_control` marker and per-tool markers for you. There is no API
  here for hand-placing cache breakpoints on individual messages.
- **CLI providers report zeros.** `claude -p` and `codex exec` don't
  expose token usage, so every `Usage` counter (cache included) is zero
  through the CLI providers — use the API providers to measure caching.
- **A one-hour cache write is priced at the five-minute rate.** Anthropic
  bills a `CacheRetentionLong` write at roughly twice the short-retention
  rate, but its API reports one `cache_creation_input_tokens` count with
  no per-TTL split, and the catalog carries one `cacheWriteCost` — the
  five-minute one. baikai therefore *under-states* the dollar cost of a
  long-retention write. The token counts are right; only `cachedWriteUsd`
  is low. Nothing baikai can read off the wire distinguishes the two, so
  measure a long-TTL run against your provider bill rather than against
  `Cost`.
- **Verify with the smoke suite.** `baikai-smoke`'s `CacheSmoke` case
  makes a write-then-read pair against a live host and asserts the
  second call reports `cacheReadTokens > 0`. Run it with a real
  `ANTHROPIC_API_KEY` to see the numbers end-to-end.

## Where next

- [Models & Providers](models-and-providers.md) — the `Usage`/`Cost`
  records in full, and the compat flags that gate long retention.
- [Streaming](streaming.md) — the same `Usage` arrives on the terminal
  `EventDone` of a stream.
- [Tools](tools.md) — tool catalogs are a common thing to cache.
