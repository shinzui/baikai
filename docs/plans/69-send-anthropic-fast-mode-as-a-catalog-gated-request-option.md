---
id: 69
slug: send-anthropic-fast-mode-as-a-catalog-gated-request-option
title: "Send Anthropic fast mode as a catalog-gated request option"
kind: exec-plan
created_at: 2026-08-28T04:52:31Z
intention: "intention_01m13ba2w5enrrbdvg022b1mrn"
master_plan: "docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md"
---

# Send Anthropic fast mode as a catalog-gated request option

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Anthropic offers a setting called **fast mode**. It runs exactly the same
model, but the provider returns output tokens at up to two and a half
times the usual rate, and charges roughly twice as much per token for the
privilege. It exists on two models only — `claude-opus-5` and
`claude-opus-4-8` — and asking for it on a model that does not have it is
an error from the provider, not a silently ignored preference. On the
wire it is a top-level request field, `"speed": "fast"`, accompanied by a
request header `anthropic-beta: fast-mode-2026-02-01`.

baikai cannot ask for it today. A caller who wants a fast response has no
option to set, and no way to discover which models could serve one.

After this plan, a caller writes:

```haskell
opts = emptyOptions & #speed ?~ SpeedFast
```

and baikai sends `"speed": "fast"` with the beta header to a model whose
catalog entry says fast mode exists there. On a model where it does not
exist, baikai omits the field rather than sending a request it knows the
provider will reject, and records that it did so in the call's evidence,
so the caller learns from the record instead of from a 400. And because
fast mode roughly doubles the price, the catalog carries the fast-mode
rates alongside the standard ones and a new pricing helper uses them, so
a caller who prices a fast call gets the real number instead of half of
it.

The observable outcome, end to end: run the test suite, and a test named
"a fast-mode request on claude-opus-5 carries speed and the beta header"
passes where it did not exist before; another named "a fast-mode request
on claude-sonnet-5 omits speed and records the drop" proves the gate;
and a pricing test shows the same token counts costing twice as much at
fast speed as at standard.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `supportsFastMode` added to `Baikai.Compat.AnthropicMessagesCompat` with default `False`
- [ ] M1: `fastModeCost` added to `Baikai.Model.Model` as `Maybe ModelCost`
- [ ] M1: catalog fetcher carries both facts per curated Anthropic id
- [ ] M1: generator refuses an entry where the two facts disagree
- [ ] M1: `baikai/data/models/anthropic.json` and `Baikai/Models/Generated.hs` regenerated
- [ ] M1: the two pinned fact tables in the test suites widened and passing
- [ ] M2: `Baikai.Speed` module added and re-exported from `Baikai`
- [ ] M2: `Options.speed` added with a default of `Nothing`
- [ ] M2: `mapRequest` sends `Messages.speed` only when the compat record allows it
- [ ] M2: the beta header is sent exactly when `speed: fast` reaches the wire
- [ ] M2: a dropped fast-mode request is recorded in the evidence
- [ ] M3: `computeCostAtSpeed` added and tested against both rate sets
- [ ] M4: Haddock, `docs/user/models-and-providers.md`, and `CHANGELOG.md` updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

One discovery made during planning is recorded here because it shapes
Milestone 2's acceptance criteria. `Claude.V1.Messages.Usage` in the
`claude` package version this repository builds against has exactly five
fields:

```haskell
data Usage = Usage
    { input_tokens :: Natural
    , output_tokens :: Natural
    , cache_creation_input_tokens :: Maybe Natural
    , cache_read_input_tokens :: Maybe Natural
    , server_tool_use :: Maybe ServerToolUseUsage
    } deriving stock (Generic, Show)
```

None of them reports which speed the provider actually ran. So baikai can
request fast mode and can describe what it translated the request into,
but it can never confirm that fast mode took effect. That is not a
defect to work around; it is the situation
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
exists to describe, and Milestone 2 must record the request and the
translation without ever implying the observation.


## Decision Log

- Decision: whether a model has fast mode is a field of the model's
  compatibility record (`supportsFastMode`), and the fast-mode prices are
  a separate field of the model itself (`fastModeCost`); the generator
  refuses any catalog entry where one is present without the other.
  Rationale: `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
  requires that a fact about what the wire accepts live in the compat
  record and never in a table keyed by model id, and "does this model
  accept `speed: fast`" is such a fact — Anthropic removed fast mode from
  `claude-opus-4-7` after it had existed there, so no ordering of model
  ids predicts it. But a price is not a wire-shape fact, and every other
  price in baikai lives in `Baikai.Model.ModelCost`; putting fast-mode
  rates in the compat record would be the only price in the codebase
  hiding in a compatibility shim. Two fields risk disagreeing, so rather
  than trusting nobody to make them disagree, the generator rejects the
  combination at generation time, exactly as it already rejects an
  `anthropic-messages` entry with no `compat` block.
  Date: 2026-08-28

- Decision: baikai sends the `anthropic-beta: fast-mode-2026-02-01`
  header itself whenever `speed: fast` reaches the wire, rather than
  requiring the caller to add it through `Options.headers`.
  Rationale: the request fails without the header, so leaving it to the
  caller converts a supported option into a footgun that only fails at
  runtime against a real key. `requestHeaders` in
  `baikai-claude/src/Baikai/Provider/Claude/Transport.hs` applies caller
  headers last, so a caller who needs a different beta string can still
  override it.
  Date: 2026-08-28

- Decision: pricing gains a new function `computeCostAtSpeed` rather than
  changing the signature of the existing `computeCost`.
  Rationale: `Baikai.Cost.Pricing.computeCost :: Model -> Usage -> Cost`
  is exposed public API. Changing its arity would break every consumer
  for a feature most of them will not use, and
  `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md` makes
  a rename a two-release commitment. An additive function costs nothing
  and leaves the common spelling untouched.
  Date: 2026-08-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully
before editing anything.

**What baikai is.** baikai is a Haskell library that gives a caller one
way to talk to several large-language-model providers. The repository is
a multi-package Cabal project; `cabal.project` at the root lists the
packages. The two that matter here are `baikai`, the core library, and
`baikai-claude`, the backend that talks to Anthropic.

**How a request flows.** A caller builds a `Baikai.Options.Options`
record — the per-call preferences, such as temperature or reasoning
effort — and hands it, with a model and a conversation, to a provider.
For Anthropic, the function
`mapRequest` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` turns
those into a `Claude.V1.Messages.CreateMessage`, the request record of
the third-party `claude` package from Hackage, which is what actually
gets serialized to JSON and posted to
`https://api.anthropic.com/v1/messages`.

**The catalog.** baikai ships a list of known models. It is not written
by hand as Haskell. Three artifacts make it up. First,
`baikai/data/models/anthropic.json` and its siblings are hand-reviewable
JSON files holding one entry per model. Second,
`baikai/src/Baikai/Models/Generated.hs` is a Haskell module produced
mechanically from that JSON — you never edit it directly. Third, two
executables maintain them: `baikai-fetch-models` downloads
`https://models.dev/api.json` and rewrites the JSON files, and
`baikai-gen-models` renders the JSON into `Generated.hs`. Both are run
from the repository root:

```bash
cabal run baikai-fetch-models
cabal run baikai-gen-models
```

The fetcher's logic lives in `baikai/fetch/FetchModelsCore.hs` and the
generator's in `baikai/gen/GenModelsCore.hs`. The fetcher does not mirror
models.dev wholesale; it emits only ids listed in a curated include set.
For Anthropic that set is `anthropicInclude :: Map Text AnthropicGenerationFacts`,
where the map's value carries facts a human had to vet, each entry
required by convention to carry a dated comment naming its source.

**The compatibility record.** Two models can speak the same API and still
differ in what they accept. `Baikai.Compat.AnthropicMessagesCompat`, in
`baikai/src/Baikai/Compat.hs`, is the record of those differences for one
Anthropic model. It currently has five fields:
`supportsLongCacheRetention`, `supportsCacheControlOnTools`,
`sendSessionAffinityHeaders`, `thinkingStyle`, and
`supportsSamplingParameters`. Each generated Anthropic catalog entry
carries one explicitly.

**Evidence.** baikai can emit a record describing what happened on a
call. The vocabulary lives in `baikai/src/Baikai/Evidence.hs`. The type
that matters to this plan is `ThinkingAdjustment`, a sum type whose
constructors each name one way a caller's request was weakened, dropped,
or made indistinguishable from a provider default — for example
`ThinkingDroppedUnsupportedModel`. Its Haddock states its purpose
directly: "This is the type that makes an otherwise silent downgrade
visible." Two of its constructors are already not about thinking at all;
they record that sampling parameters were removed because the model
rejects them. That precedent matters, because this plan adds a third
non-thinking constructor.

**Pricing.** `Baikai.Model.ModelCost` holds four rates per model, all in
US dollars per million tokens: `inputCost`, `outputCost`,
`cacheReadCost`, `cacheWriteCost`. `Baikai.Cost.Pricing.computeCost ::
Model -> Usage -> Cost` multiplies a token count by those rates. Note
that no provider in this repository calls it; providers leave
`Usage.cost` at zero and `computeCost` is a helper the caller applies.
That makes it safe to extend without touching any request path.

**Relevant ADRs.** Read these three; they are short.

`docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
is the one that dictates this plan's shape. It records that a fact about
what a model generation accepts on the wire belongs in the compat record
carried by the generated catalog entry, and never in a hand-maintained
table keyed by model id. It exists because such a table did ship, keyed
on model-id prefixes, and it did not know about `claude-sonnet-5`, so
baikai sent that model the wrong extended-thinking shape and earned an
HTTP 400 on every reasoning request. Fast mode has the identical failure
mode available to it.

`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
records that baikai keeps three distinct facts about a call — what was
requested, what baikai translated it into, and what the provider
reported — and never merges them. Fast mode cannot be observed at all
with the current dependency, which this plan must state rather than
paper over.

`docs/adr/0003-the-adapter-owns-the-translation-description.md` records
that the provider adapter, not a later layer, describes what it
translated, because only the adapter knows all the inputs to that
decision. The fast-mode drop must therefore be described inside
`mapRequest`, not reconstructed by a trace sink.

`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md`
requires any example added to documentation to compile as part of the
test suite. Milestone 4 honours it.

**Sibling plans.** This plan is one of four under
`docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md`.
It has no dependencies on the others and can be implemented first. Be
aware that
`docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md`
will later add a second field to the same compat record and a second fact
to the same fetcher table, following the pattern this plan establishes.


## Plan of Work

The work is four milestones. Milestone 1 teaches the catalog that fast
mode exists on some models and not others. Milestone 2 lets a caller ask
for it and makes the request honest about what happened. Milestone 3
makes the price truthful. Milestone 4 writes it down.

### Milestone 1 — the catalog knows which models have fast mode

At the end of this milestone nothing user-visible has changed, but
`Baikai.Models.Generated.anthropic_claude_opus_5` carries a compat record
whose `supportsFastMode` is `True` and a `fastModeCost` holding
Anthropic's fast-mode rates, while `anthropic_claude_sonnet_5` carries
`False` and `Nothing`. Nothing outside the catalog reads these yet.

Add `supportsFastMode :: !Bool` to `AnthropicMessagesCompat` in
`baikai/src/Baikai/Compat.hs`, defaulting to `False` in
`defaultAnthropicMessagesCompat`, and export the field selector from the
module's export list alongside the existing five. `False` is the correct
default because a hand-rolled model built from `emptyModel` should not
claim a capability that exists on two models in the world.

Add `fastModeCost :: !(Maybe ModelCost)` to `Baikai.Model.Model` in
`baikai/src/Baikai/Model.hs`, immediately after the existing `cost`
field, and set it to `Nothing` in `emptyModel`. `Model` derives `Eq`,
`Generic` and `FromJSON`, and renders its `Show` instance field by field
in a hand-written instance a little below the record — find that instance
and add the new field to it, or the module will not compile.

Teach the fetcher both facts. In `baikai/fetch/FetchModelsCore.hs`, the
record `AnthropicGenerationFacts` currently carries the thinking style
and the sampling flag, and `anthropicInclude` maps each curated Anthropic
id to one. Widen that record with the fast-mode facts, and widen the
three helper values at the bottom of `anthropicInclude`'s `where` clause
(`adaptiveNoSampling`, `adaptiveWithSampling`, `budgetWithSampling`) so
existing rows keep compiling. Then set the fast-mode facts on the two ids
that have it. As of Anthropic's API reference cached 2026-06-24, fast
mode exists on `claude-opus-5` and `claude-opus-4-8`, is not available on
any other current generation, and was removed from `claude-opus-4-7`
after having existed there. Fast mode on `claude-opus-5` is priced at ten
dollars per million input tokens and fifty per million output tokens,
against five and twenty-five at standard speed. Follow the file's
existing convention: every entry carries a dated comment naming its
source.

Teach the generator to emit both and to refuse a contradiction. In
`baikai/gen/GenModelsCore.hs`, follow how the `compat` block is rendered
today and add the new field; add the optional `fastModeCost` beside
`cost`. Then add the invariant: an entry whose `supportsFastMode` is true
but which carries no `fastModeCost`, or the reverse, is rejected with a
message naming the model id. The generator already refuses an
`anthropic-messages` entry that arrives without a `compat` block, so
there is an existing refusal to copy.

Regenerate and update the pinned tables. The two hand-written tables that
pin every Anthropic model's facts are `expectedAnthropicFacts` in
`baikai/test/CatalogSpec.hs` and `anthropicModels` in
`baikai-claude/test/ThinkingSpec.hs`. Both hold tuples that must widen.
Both exist deliberately so that a catalog refresh cannot change a
per-model fact without a human editing a row, and their comments say so;
widen them rather than making them read the values off the record.

### Milestone 2 — a caller can ask, and the record says what happened

At the end of this milestone a caller can set `Options.speed` and see
`"speed":"fast"` in the request body baikai builds, with the beta header
attached; on a model without fast mode the field is absent and the
evidence record explains why.

Create `baikai/src/Baikai/Speed.hs`, modelled closely on the existing
`baikai/src/Baikai/CacheRetention.hs`, which is the same shape of
problem — a small provider-agnostic preference enum with a Haddock
paragraph saying how each provider maps it. Define:

```haskell
data Speed
  = SpeedStandard
  | SpeedFast
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Do not re-export the `claude` package's own `Speed` type. baikai's
`Options` deliberately names no third-party type; `ThinkingLevel` and
`CacheRetention` are both baikai's own. Add the module to the
`exposed-modules` list in `baikai/baikai.cabal` and re-export it from
`baikai/src/Baikai/Baikai.hs` beside the other option types.

Add `speed :: !(Maybe Speed)` to `Options` in
`baikai/src/Baikai/Options.hs`, defaulting to `Nothing` in
`emptyOptions`. `Nothing` means "say nothing about speed", which is not
the same as `Just SpeedStandard`, which explicitly asks the provider for
standard speed; keep both spellings, because collapsing them would make
the request body depend on a distinction the caller cannot see.

Wire it through `mapRequest` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`. That
function already computes a `compat` value near the top and already
returns a translation description alongside the request. Add a
`speedField` binding that resolves to `Just Messages.SpeedFast` only when
the caller asked for fast and `supportsFastMode compat` is `True`, and
set `Messages.speed = speedField` in the `Messages._CreateMessage` record
literal beside the existing `Messages.thinking` and
`Messages.output_config` fields. A caller asking for `SpeedStandard`
passes through unconditionally; standard speed is not gated because it is
the default everywhere.

Record the drop. Add a constructor to `ThinkingAdjustment` in
`baikai/src/Baikai/Evidence.hs` for a fast-mode request removed because
the model does not offer it, following the two sampling-drop constructors
that are already in that type and already documented as not being about
thinking. Give it a wire spelling in the renderer and parser beside the
others, and make `weakensThinking` return `False` for it, exactly as the
sampling drops do — a caller who asked for speed and did not get it has
not had their reasoning weakened, and strict evidence mode should not
refuse the call over it.

Send the beta header. In
`baikai-claude/src/Baikai/Provider/Claude/Transport.hs`, `requestHeaders`
assembles the provider's own headers and then applies the model's and the
caller's overrides on top. Add `anthropic-beta: fast-mode-2026-02-01` to
the provider headers exactly when the request being built carries
`speed: fast`. Note that `requestHeaders` does not currently see the
request body; the cleanest available seam is to pass the resolved speed
in, since `requestHeaders` already takes both the compat record and the
`Options`. Keep the caller-override behaviour intact so a caller can
still replace the header value.

### Milestone 3 — the price is the real price

At the end of this milestone a caller can price a fast-mode call and get
roughly twice the standard number rather than exactly the standard one.

In `baikai/src/Baikai/Cost/Pricing.hs`, add:

```haskell
computeCostAtSpeed :: Model -> Speed -> Usage -> Cost
```

At `SpeedStandard` it must be identical to `computeCost`. At `SpeedFast`
it uses the model's `fastModeCost` rates when present. When a caller asks
for fast pricing on a model with no fast-mode rates, return the standard
cost rather than zero: zero is the truthful signal for a model with no
published pricing at all, and reusing it here would make an ordinary
model look free. Leave `computeCost` exactly as it is, and give it a
Haddock line pointing at the new function.

### Milestone 4 — write it down

Add Haddock to `Baikai.Speed` and to the new `Options` field explaining
that fast mode exists on two models, costs about twice as much, and is
dropped with an evidence note elsewhere. Update
`docs/user/models-and-providers.md`, which already carries a section
listing which `Options` fields each provider forwards and which it drops
— add `speed` to it, in the same voice. Add a `### Added` entry to
`CHANGELOG.md` under the `## [Unreleased]` heading. If you add a code
example to any of these, it must compile in the test suite per
`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md`; the
suite `baikai-smoke:doc-shapes` is where documented shapes are compiled.


## Concrete Steps

All commands are run from the repository root,
`/Users/shinzui/Keikaku/bokuno/baikai`, unless stated otherwise.

Confirm the starting state builds and passes:

```bash
cabal build all
cabal test all
```

Expect every suite to report `PASS`. The `baikai-agent` suite contains
two process-timing tests that occasionally fail under parallel load; if
`baikai-agent-test` alone fails, re-run just that suite with
`cabal test baikai-agent` before treating it as a real failure.

After the Milestone 1 edits, regenerate the catalog and inspect the
diff:

```bash
cabal run baikai-gen-models
git diff --stat baikai/src/Baikai/Models/Generated.hs
```

Note that you run only the generator here, not `baikai-fetch-models`.
The fetcher re-downloads models.dev and would mix an unrelated upstream
refresh into this plan's diff. The curated facts you are adding live in
`baikai/fetch/FetchModelsCore.hs` and reach the JSON only through the
fetcher, so for this milestone edit `baikai/data/models/anthropic.json`
by hand to add the new `compat` key and the fast-mode rates on the two
models that have them, keeping the fetcher's curation in step so that a
later refresh reproduces what you wrote. Verify they agree by running the
fetcher last and confirming it produces no diff:

```bash
cabal run baikai-fetch-models
git diff --stat baikai/data/models/anthropic.json
```

An empty diff means the hand edit and the curated table agree. A
non-empty diff means they do not; fix the fetcher table until the diff is
empty.

Then verify the generator's new refusal actually refuses. Temporarily
remove the `fastModeCost` entry from `claude-opus-5` in the JSON and run:

```bash
cabal run baikai-gen-models
```

Expect a non-zero exit and a message naming `claude-opus-5`. Restore the
entry afterwards.

After Milestone 2 and Milestone 3, run the full suite again:

```bash
cabal test all
```


## Validation and Acceptance

Acceptance is four behaviours a person can check, not four diffs.

First, the catalog states the fact. In a `cabal repl baikai` session:

```haskell
import Baikai.Models.Generated (anthropic_claude_opus_5, anthropic_claude_sonnet_5)
import Baikai.Model (compat, fastModeCost)
```

Printing the two models shows `supportsFastMode = True` and a populated
`fastModeCost` on `claude-opus-5`, and `supportsFastMode = False` with
`fastModeCost = Nothing` on `claude-sonnet-5`.

Second, a fast request reaches the wire. Add a test to
`baikai-claude/test/ShapeSpec.hs` — the suite that asserts on the request
body baikai builds — named "a fast-mode request on claude-opus-5 carries
speed and the beta header". Build a request with
`emptyOptions & #speed ?~ SpeedFast` against `anthropic_claude_opus_5`
and assert that the encoded JSON body contains `"speed":"fast"` and that
`requestHeaders` returns a header pair
`("anthropic-beta", "fast-mode-2026-02-01")`.

Third, the gate holds and explains itself. Add a test named "a fast-mode
request on claude-sonnet-5 omits speed and records the drop". Build the
same options against `anthropic_claude_sonnet_5`, assert the body has no
`speed` key at all, assert no beta header is present, and assert that the
translation returned by `mapRequest` carries the new fast-mode-dropped
adjustment. This is the test that proves the feature is not a footgun: a
caller learns from the record rather than from a provider error.

Fourth, the price doubles. Add a test to `baikai/test/CostSpec.hs`
asserting that for one identical `Usage`, `computeCostAtSpeed` at
`SpeedFast` against `anthropic_claude_opus_5` returns exactly twice the
`usd` that `computeCost` returns, and that at `SpeedStandard` the two
functions agree exactly.

The whole suite must pass:

```bash
cabal test all
```

Every suite should report `PASS`. In particular `baikai-test` and
`baikai-claude-test` must pass, since both contain the pinned fact tables
Milestone 1 widens; a failure there means a catalog entry changed without
its row being updated, which is exactly what those tables are for.


## Idempotence and Recovery

Every step is safe to repeat. `cabal run baikai-gen-models` is a pure
function of the JSON files and rewrites `Generated.hs` from scratch, so
running it twice produces the same file; a test in `baikai/test/CatalogSpec.hs`
asserts that property. `cabal run baikai-fetch-models` rewrites the JSON
files from the network and from the curated tables, so running it will
also pull in any unrelated upstream price change — if that happens
mid-plan, either commit it separately or `git checkout` the JSON and
re-apply just your curated edits.

If the Milestone 1 edits leave the tree not compiling because a record
gained a field that some construction site does not set, the compiler
names every site: `Model` and `AnthropicMessagesCompat` are both built
with explicit record syntax in several places, and
`-Werror=incomplete-record-updates` is on for `baikai-claude`. Work
through the errors; there is no hidden dynamic construction to miss.

Nothing in this plan is destructive. There is no migration, no data
format anyone else has written, and no removal of an existing name, so
there is no rollback beyond `git checkout`.


## Interfaces and Dependencies

No new third-party dependency is added. The `claude` package stays at
`^>=1.4`; everything this plan needs is already in 1.4.0, specifically
the field `speed :: Maybe Speed` on `Claude.V1.Messages.CreateMessage`
and the type `Claude.V1.Messages.Speed` with constructors `SpeedStandard`
and `SpeedFast`.

The following must exist at the end of the milestones named.

At the end of Milestone 1:

```haskell
-- baikai/src/Baikai/Compat.hs
supportsFastMode :: AnthropicMessagesCompat -> Bool

-- baikai/src/Baikai/Model.hs
fastModeCost :: Model -> Maybe ModelCost
```

At the end of Milestone 2:

```haskell
-- baikai/src/Baikai/Speed.hs
data Speed = SpeedStandard | SpeedFast

-- baikai/src/Baikai/Options.hs
speed :: Options -> Maybe Speed
```

plus one new constructor on `Baikai.Evidence.ThinkingAdjustment`
recording a fast-mode request dropped for an unsupporting model, with a
wire spelling in `renderThinkingAdjustment` and its parser, and
`weakensThinking` returning `False` for it.

At the end of Milestone 3:

```haskell
-- baikai/src/Baikai/Cost/Pricing.hs
computeCostAtSpeed :: Model -> Speed -> Usage -> Cost
```

Note on module boundaries: `Baikai.Cost.Pricing` will need to import
`Baikai.Speed`. Check for an import cycle before writing it —
`Baikai.Speed` should import nothing from baikai beyond what
`Baikai.CacheRetention` imports, which is only `Data.Aeson` and
`GHC.Generics`, so no cycle should arise.
