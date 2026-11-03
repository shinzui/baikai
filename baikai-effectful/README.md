# baikai-effectful

A thin, **policy-free** [`effectful`](https://hackage.haskell.org/package/effectful)
binding over [baikai](../baikai)'s transport. It exposes one dynamic effect, `Baikai`,
whose operations mirror baikai's transport functions, plus interpreters that run those
operations against a real or isolated provider registry.

It is the *seam*, not the framework: it adds **no** retries, backoff, rate limiting,
budgets, caching, or error remapping. Failures propagate exactly as baikai produces them:
blocking completions return the same error-shaped `Response` as `completeRequest`, and
streaming paths surface baikai's terminal `EventError` event in-band. Policy belongs one
layer up, written *in terms of* this effect.

## The effect

```haskell
data Baikai :: Effect where
  Complete      :: Model -> Context -> Options -> Baikai m Response
  StreamCollect :: Model -> Context -> Options -> Baikai m [AssistantMessageEvent]
  StreamCollectTraced :: TraceSink -> Model -> Context -> Options -> Baikai m [AssistantMessageEvent]
  StreamEach    :: Model -> Context -> Options -> (AssistantMessageEvent -> m ()) -> Baikai m ()
```

## Operations

| Operation                         | Meaning                                                        |
| --------------------------------- | ------------------------------------------------------------- |
| `complete m c o`                  | Blocking completion → `Response`, including error-shaped responses. |
| `streamCollect m c o`             | Drain the stream into the full `[AssistantMessageEvent]`.     |
| `streamCollectTraced sink m c o` | Collect events with tracing and bounded cleanup on cancellation. |
| `streamEach m c o k`              | Run callback `k` once per event, in order, inside `Eff`.      |

`streamEach` preserves incrementality (the callback sees events as they arrive); a terminal
`EventError` appears in-band rather than as a thrown exception, matching baikai.

## Evidence on cancellation

`streamCollectTraced` delegates to core's `withTraceListWith`, which owns the
whole fold lifetime. Supply a `TraceSink` and opt in through `Options.evidence`.
On success or provider failure the sink's single `CallEvidence` carries exactly
the terminal's evidence record, including its `callId`. A strict pre-dispatch
refusal retains core's failed evidence and never invokes the provider. Opt-out
produces no evidence; providers that omit successful evidence retain core's
strict missing-record failure.

For cancellation before terminal commitment, use a short, nonblocking sink that stores the complete
`ModelCallEvidence` in a caller-owned cell before acknowledging it. Read that
cell immediately in the caller's exception handler. With a healthy sink the
`CallAborted` record is already present and the original exception is unchanged.
The sink fold's end action also completes before propagation. Cancellation after
terminal commitment retains that terminal's evidence and adds no abort.

The sink drain budget is one second in total. A blocked or throwing sink still
allows cancellation to unwind and reports its failure on stderr; an empty cell
means delivery was unconfirmed. A worker abandoned at the bound can deliver
later. Exactly-once means Baikai submits one evidence event, not that a failing
external destination durably stores it. Keep slow export behind a nonblocking
queue.

Core's `withTraceFold`, `withTraceList`, `withTrace`, and their `With` variants
own the same lifetime. Arbitrary abandonment of `withTraceStream` between stream
steps still relies on garbage collection. The existing `streamCollect` and
`streamEach` operations keep their behavior.

## Interpreters

```haskell
runBaikai     :: (IOE :> es) => Eff (Baikai : es) a -> Eff es a                       -- global registry
runBaikaiWith :: (IOE :> es) => ProviderRegistry -> Eff (Baikai : es) a -> Eff es a   -- explicit registry
```

The *operations* are registry-agnostic; the *interpreter* picks the registry, mirroring
baikai's own `completeRequest` vs `completeRequestWith` split. Because `Baikai` is a dynamic
effect, you can re-interpret the same operations — stub them in tests, record/replay,
intercept, or (one layer up) wrap them with retries/caching/tracing — without touching any
call site.

## Example

```haskell
import Baikai.Effectful
import Effectful (Eff, runEff)

describe :: (Baikai :> es) => Model -> Context -> Options -> Eff es Response
describe = complete

main :: IO ()
main = do
  -- against baikai's process-global registry (providers registered elsewhere):
  r <- runEff . runBaikai $ describe model ctx opts
  print r
```

For a hermetic test, register a stub provider in an isolated registry with
`Baikai.Provider.Registry.newProviderRegistry` / `registerApiProviderWith` and drive the
operations through `runEff . runBaikaiWith reg`. See `test/` in this package.

## Live demo

The test suite includes a live, network-touching demo gated on an environment variable, so
the default run stays hermetic:

```bash
# hermetic (default): no network, no key — the live case prints a skip line and passes
cabal test baikai-effectful-test

# live: registers the OpenAI provider and makes one real call
BAIKAI_EFFECTFUL_LIVE=1 OPENAI_API_KEY=sk-... cabal test baikai-effectful-test
```

## Why a separate package

The core `baikai` package deliberately carries no `effectful` dependency, and most baikai
users do not use `effectful`. Shipping the binding as its own artifact keeps the core
dependency-light while giving any `effectful` program a reusable baikai↔effectful seam — the
same way `baikai-claude` / `baikai-openai` layer on `baikai`.
