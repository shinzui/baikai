---
id: 54
slug: emit-openai-compatible-api-call-evidence
title: "Emit OpenAI-compatible API call evidence"
kind: exec-plan
created_at: 2026-08-05T20:23:57Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Emit OpenAI-compatible API call evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai speaks to any host that implements OpenAI's Chat Completions API — OpenAI itself,
OpenRouter, DeepSeek, Together, Z.ai, Qwen, and anything else compatible. Those hosts agree on
almost everything except how to ask for reasoning effort, where they disagree completely: Baikai
knows **seven** distinct wire shapes for the same preference, selected per host by a
compatibility record. One host takes a top-level `reasoning_effort` string, another takes a
nested `reasoning: { effort: ... }` object, two take a bare `enable_thinking: true` boolean with
no depth at all, and one takes no reasoning control whatsoever and silently drops the caller's
request.

Nothing in Baikai currently records which of those seven happened, or what the caller's canonical
level became inside it. After
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md), an
OpenAI-compatible call emits an evidence record saying which model was configured and nothing else
was observed. This plan makes that record tell the truth about all seven shapes, and adds the two
things the host itself reports back: the model identifier it says it ran, and the correlation
identifier it issues in an `x-request-id` response header.

One thing this plan must get right, and which an earlier draft of it got wrong, is the difference
between the native shape and the six compatible ones. The native path forwards Baikai's canonical
level name verbatim, so a caller asking for `xhigh` or `max` puts exactly `"xhigh"` and `"max"`
into `reasoning_effort`. The other six route through a helper called `compatibleEffort` that
clamps both down to `"high"`. That asymmetry looks like an oversight and is not one: the helper's
own docstring scopes it to the "non-native OpenAI-compatible request shapes", and
`baikai-openai/test/ShapeSpec.hs` carries two named guards — "xhigh survives SDK staging" and
"max survives SDK staging" — asserting the native values reach the wire intact, sitting directly
beside a companion test asserting that DeepSeek clamps. Someone made this distinction deliberately
and defended it with tests. **Do not change it, and do not touch those tests.**

The only thing genuinely stale here is a comment: the `ThinkingFormatOpenAI` constructor's Haddock
in `baikai/src/Baikai/Compat.hs` still describes the native field as accepting
`minimal | low | medium | high`, which predates the higher levels. This plan corrects the comment
to match the tested behavior, and nothing else.

You can see everything working with no network connection and no API key:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-openai
```


## Progress

- [ ] Reify the thinking translation: make `injectThinkingShape` return a `ThinkingTranslation`
      alongside the shaped body, across all seven wire shapes.
- [ ] Record every OpenAI-compatible downgrade as a `ThinkingAdjustment` — and record *no*
      adjustment on the native path, which expresses every level exactly.
- [ ] Correct the stale `ThinkingFormatOpenAI` Haddock in `baikai/src/Baikai/Compat.hs`.
- [ ] Widen the SSE transport callback so response metadata reaches the adapter.
- [ ] Capture the correlation header and the HTTP status.
- [ ] Read the provider-reported model out of the streamed chunks.
- [ ] Populate the evidence record and derive the strength from what was observed.
- [ ] Add the response commitment digest.
- [ ] Write the forty-two-case translation table test (seven shapes by six levels).
- [ ] Write the header-capture and observed-model fixture tests.
- [ ] Write the end-to-end evidence tests, including the toggle-host indistinguishability case.
- [ ] Add `CHANGELOG.md` entries under `### Added`, plus a `### Fixed` line for the corrected
      `ThinkingFormatOpenAI` Haddock. Nothing here belongs under `### Changed`: this plan sends
      nothing new on the wire.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Leave the OpenAI-native effort mapping exactly as it is. It is correct.
  Rationale: An earlier draft of this plan called the native path's verbatim forwarding of `xhigh`
  and `max` a live bug, on the strength of the `ThinkingFormatOpenAI` Haddock in
  `baikai/src/Baikai/Compat.hs` listing only `minimal | low | medium | high`, and proposed clamping
  to match the other six shapes. That was wrong, and the code says so twice. `compatibleEffort`'s
  own docstring scopes it to the "non-native OpenAI-compatible request shapes", so the native
  path's exclusion is documented as intentional. And `baikai-openai/test/ShapeSpec.hs` contains a
  test group named "native OpenAI higher reasoning effort", whose two cases — "xhigh survives SDK
  staging" and "max survives SDK staging" — assert the values reach the wire unmodified against
  `Models.openai_gpt_5_6_terra`, immediately beside a companion test asserting that a DeepSeek
  model clamps `max` to `high`. That is a deliberate, tested, deliberately contrasted design: the
  native host gets the full vocabulary, compatible hosts get a lowest-common-denominator one.
  The stale artefact is the Haddock comment, which predates the higher levels. Correcting the
  comment is in scope; changing the behaviour is not. Had the clamp been implemented, it would
  have silently weakened every `xhigh` and `max` request against a current OpenAI model — the
  precise failure mode this whole initiative exists to eliminate.
  Date: 2026-08-05

- Decision: The native path records no `ThinkingAdjustment` for any level.
  Rationale: Following from the above. `EffortClamped` means the wire could not express what the
  caller asked for; the native path expresses all six levels exactly, so recording an adjustment
  there would be a false statement in the evidence. The contrast with the six compatible shapes,
  which do record adjustments, is exactly the information a reader of an evidence record needs.
  Date: 2026-08-05


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. This plan
changes `baikai-openai/`, the package implementing the OpenAI-compatible Chat Completions API and
the `codex exec` subprocess provider, and touches nothing else except its changelog. From the
repository root, `cabal build baikai-openai` compiles it and `cabal test baikai-openai` runs its
test suite, which lives in `baikai-openai/test/` and uses `tasty` with `tasty-hunit`, assembled in
`baikai-openai/test/Main.hs`.

Record fields in this codebase never carry the record's name as a prefix — a field is
`effortText`, not `translationEffortText` — and `DuplicateRecordFields` is on so unrelated records
legitimately share plain names. Field access goes through `generic-lens` overloaded labels
(`opts ^. #thinking`). The language is GHC2024, every `deriving` clause must name its strategy
explicitly, and every module needs an explicit export list.

### The compatibility model, which is the thing to understand first

`baikai/src/Baikai/Compat.hs` in the core package holds a record called `OpenAICompletionsCompat`
describing what a particular OpenAI-compatible host accepts. One of its fields is
`thinkingFormat :: ThinkingFormat`, and `ThinkingFormat` is a seven-constructor sum:

```haskell
data ThinkingFormat
  = ThinkingFormatOpenAI      -- top-level reasoning_effort string
  | ThinkingFormatOpenRouter  -- nested reasoning: { effort: "..." }
  | ThinkingFormatDeepseek    -- thinking: {type: enabled} plus reasoning_effort
  | ThinkingFormatTogether    -- reasoning: {enabled: true} plus reasoning_effort
  | ThinkingFormatZai         -- enable_thinking: true
  | ThinkingFormatQwen        -- enable_thinking: true
  | ThinkingFormatNone        -- host has no reasoning control; option dropped silently
```

The compat record is selected per model by `openaiCompletionsCompatFor` in `Baikai.Model`. Every
one of the seven shapes must be covered by this plan's translation and by its tests.

### The request path, file by file

`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` reshapes the JSON request body for the target
host. Its entry point composes four transformations:

```haskell
shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
shapeRequestBody compat opts =
  injectCacheControl compat opts
    . injectThinkingShape compat opts
    . dropUnsupportedStrict compat
    . renameMaxTokens compat
```

`injectThinkingShape` is the function this plan reifies. It currently returns only the modified
body, so the description of what it did exists nowhere:

```haskell
injectThinkingShape :: OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
injectThinkingShape compat opts body =
  case thinking opts of
    Nothing -> body
    Just lvl -> case thinkingFormat compat of
      ThinkingFormatOpenAI ->
        insertTop "reasoning_effort" (String (renderThinkingLevel lvl)) body
      ThinkingFormatNone -> body
      ThinkingFormatOpenRouter ->
        insertTop "reasoning" (Aeson.object ["effort" .= compatibleEffort lvl]) body
      ThinkingFormatDeepseek ->
        insertTop "reasoning_effort" (String (compatibleEffort lvl)) $
          insertTop "thinking" (Aeson.object ["type" .= ("enabled" :: Text)]) body
      ThinkingFormatTogether ->
        insertTop "reasoning_effort" (String (compatibleEffort lvl)) $
          insertTop "reasoning" (Aeson.object ["enabled" .= True]) body
      ThinkingFormatZai ->
        insertTop "enable_thinking" (Bool True) body
      ThinkingFormatQwen ->
        insertTop "enable_thinking" (Bool True) body
```

and the helper the six non-native shapes use:

```haskell
compatibleEffort :: ThinkingLevel -> Text
compatibleEffort = \case
  ThinkingMinimal -> "low"
  ThinkingLow     -> "low"
  ThinkingMedium  -> "medium"
  ThinkingHigh    -> "high"
  ThinkingXHigh   -> "high"
  ThinkingMax     -> "high"
```

Reading the two together shows the bug plainly: `ThinkingFormatOpenAI` is the one branch that does
not call `compatibleEffort`.

`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` is the streaming adapter, structurally parallel
to the Anthropic one. It holds an `Assembler` record carrying translation state across a call —
the model, buffers for open content blocks, accumulated usage — and a fold that turns each decoded
chunk into Baikai's own `AssistantMessageEvent` values. Like the Anthropic adapter, it builds its
assistant skeleton from the caller's `Model` (`ass ^. #model`) and never reads the model the host
reports.

`baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` is Baikai's own SSE transport, again not the
vendor SDK's HTTP path. `openaiSseStreamValueWithHeaders` builds an `http-client` request by hand,
calls `HTTP.withResponse`, and hands the response to `sseFromResponse`, whose callback has type
`Either BaikaiError Aeson.Value -> IO ()`. On a non-2xx status it consumes the body, reads
`Retry-After` out of `HTTP.responseHeaders response`, and delivers one `Left`. As on the Anthropic
side, the full response header list is in scope at that exact point and nothing but `Retry-After`
is read from it.

### What the host reports back

Every OpenAI-compatible streaming chunk carries a top-level `model` field naming the model that
produced it, and a top-level `id`. Baikai already reads `id` for the response identifier. Because
this adapter decodes chunks as raw `Aeson.Value` rather than a typed SDK record, reading `model`
is a `KeyMap` lookup yielding a `Maybe` rather than a field access — and because compatible hosts
vary, treat a missing field as a genuine absence rather than an error.

The correlation header is `x-request-id` on OpenAI and on most compatible hosts. Some gateways use
`x-amzn-requestid`, `cf-ray`, or `x-ms-request-id` instead. Capture an allow-list of names rather
than a single one.

### Terms used in this plan

The **wire shape** is which of the seven `ThinkingFormat` layouts a host expects. The
**correlation identifier** is a value the host issues that lets the host itself locate this call in
its own records. The **observed model** is the model identifier the host reports having run, as
distinct from the one the caller configured. A **downgrade** is any case where what went on the
wire expresses less than what the caller asked for. A **fixture** is a recorded response body or
chunk sequence stored under `baikai-openai/test/` and replayed by a test so no network call is
needed.

### What this plan depends on

Hard dependencies:
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) for the
vocabulary and
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) for the
channel. From plan 51 this plan uses `ThinkingTranslation`, `ThinkingMode`, `ThinkingAdjustment`,
`Observed`, `EvidenceStrength`, and `commitmentDigest`; from plan 52 it uses `minimalEvidence` and
the evidence slot on `TerminalPayload`.

Soft dependency:
[docs/plans/53](53-emit-anthropic-messages-api-call-evidence.md) populates the same
`ThinkingTranslation` record for Anthropic. Whichever of the two lands first sets the practical
convention for how a translation spells its `wireField` and its adjustments; if plan 53 is already
complete when you start, read the values it records and match their style. Neither plan blocks the
other, and neither owns the type — plan 51 does.

### ADR context

This repository has no `docs/adr/` directory and `mori.dhall` declares no ADR bundle, so there is
no local ADR convention to follow and no relevant record to read. Record decisions in this plan's
Decision Log;
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) establishes
`docs/adr/` and promotes the durable ones at the end of the initiative.


## Plan of Work

Three milestones. The first is pure; the second widens the transport; the third assembles the
evidence. No milestone changes what any host receives on the wire — this plan is additive
throughout.

### Milestone 1: reify the translation

At the end of this milestone `shapeRequestBody` returns a `ThinkingTranslation` describing exactly
what it did, all seven wire shapes are covered, and a forty-two row table test proves every
combination. **Every one of those forty-two rows must assert the same request body the code
produces today.** This milestone adds a description of existing behaviour; it does not alter the
behaviour. If a row disagrees with what the code produces, the row is wrong until you have proved
otherwise, and proving otherwise means reading the code and the tests that guard it — not
reasoning from a doc comment. An earlier draft of this plan got exactly that wrong; see the first
Decision Log entry.

Change `injectThinkingShape` to return a pair:

```haskell
injectThinkingShape ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)
```

and thread it through `shapeRequestBody`, which becomes:

```haskell
shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)
```

The composition in `shapeRequestBody` is currently point-free; rewrite it as an explicit pipeline
so the translation can escape, rather than contorting the composition to preserve its style.

Fill the translation per shape. When the caller requested nothing, return `noThinkingRequested`.
Otherwise:

For `ThinkingFormatOpenAI`, set `mode = ThinkingModeAdaptive` (the host chooses depth from a
word), `wireField = Just "reasoning_effort"`, `effortText` to `renderThinkingLevel lvl` — the
value the code already sends — and record **no adjustment at all**, for any of the six levels.
This path expresses every canonical level exactly, which is precisely what an empty `adjustments`
list means. Do not call `compatibleEffort` here; it is scoped by its own docstring to the
non-native shapes, and two named tests in `baikai-openai/test/ShapeSpec.hs` guard the native
values reaching the wire intact.

For `ThinkingFormatOpenRouter`, set `mode = ThinkingModeAdaptive`, `wireField = Just "reasoning"`,
`effortText` to the `compatibleEffort` value, and record `EffortClamped` for the three levels
`compatibleEffort` actually changes — `minimal` becomes `low`, and both `xhigh` and `max` become
`high`.

For `ThinkingFormatDeepseek` and `ThinkingFormatTogether`, the same as OpenRouter but with
`wireField = Just "reasoning_effort"`. Both send an extra enabling object alongside the effort,
which does not change what the translation records, because the effort field is what carries the
depth.

For `ThinkingFormatZai` and `ThinkingFormatQwen`, set `mode = ThinkingModeToggle`,
`wireField = Just "enable_thinking"`, no effort text, and record `EffortCollapsedToToggle lvl` for
**every** level — these hosts express no depth at all, so a caller asking for `max` and a caller
asking for `low` produce byte-identical requests. That is exactly the kind of silent equivalence
IR-3 exists to surface.

For `ThinkingFormatNone`, set `mode = ThinkingModeUnsupported`, no wire field, and record
`ThinkingDroppedUnsupportedHost lvl`. `Baikai.Compat`'s own Haddock describes this drop as silent;
after this plan it is recorded.

The test belongs wherever the existing thinking assertions live —
`baikai-openai/test/ReasoningSpec.hs` and `baikai-openai/test/ShapeSpec.hs` both already exist and
both already touch this area. Build a table of forty-two rows, one per (shape, level) pair:

```haskell
translationTable :: [(ThinkingFormat, ThinkingLevel, Maybe Text, [ThinkingAdjustment])]
```

and for each row assert both the produced `ThinkingTranslation` and the shaped JSON body. Assert
the body too, not only the translation: the whole premise of this plan is that the translation
describes what was actually sent, and a test checking only the description would happily pass
while the two drifted apart.

The most informative rows are the four that pair off: `ThinkingFormatOpenAI` and
`ThinkingFormatDeepseek`, each at `ThinkingXHigh` and `ThinkingMax`. The native rows expect
`"reasoning_effort":"xhigh"` and `"max"` with an empty adjustment list; the DeepSeek rows expect
`"high"` for both, with `EffortClamped`. Written side by side they make the design legible to the
next reader, which is more than the existing pair of guard tests manages on its own.

Finally, correct the stale comment. In `baikai/src/Baikai/Compat.hs`, the `ThinkingFormatOpenAI`
constructor's Haddock reads:

```haskell
  = -- | OpenAI-native: top-level @reasoning_effort: "minimal" | "low"
    --   | "medium" | "high"@.
    ThinkingFormatOpenAI
```

Extend the listed vocabulary to include `xhigh` and `max`, and add a sentence saying that this
shape sends the canonical Baikai level verbatim while the other six clamp through
`compatibleEffort`. That one sentence is what would have prevented this plan's original error, so
it earns its place.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-openai --test-options='--pattern Reasoning'
cabal test baikai-openai --test-options='--pattern Shape'
```

### Milestone 2: observation

At the end of this milestone the adapter knows the correlation identifier the host issued and the
model it reported running. Both are visible in a test replaying a recorded chunk sequence; neither
reaches the evidence record yet.

In `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs`, add a once-per-response metadata callback to
`sseFromResponse` and to the functions that wrap it, exactly as
[docs/plans/53](53-emit-anthropic-messages-api-call-evidence.md) does for Anthropic. If plan 53 is
already complete, read its `ResponseMetadata` record and mirror its shape and its allow-list
discipline; the two transports are separate modules in separate packages and will not share code,
but they must not disagree about what a captured header record looks like. Define:

```haskell
-- | Response-level metadata captured once, before the first chunk.
--
-- Header capture is an allow-list: a header is recorded only if its
-- name appears in 'capturedHeaderNames'. A denylist would leak whatever
-- header a future gateway decides to add.
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }

-- | Correlation headers worth recording across the compatible-host
-- ecosystem: OpenAI's @x-request-id@ and the equivalents common on
-- gateways in front of it. None can carry a credential: they are values
-- the server chose, not values baikai sent.
capturedHeaderNames :: [CI ByteString]
```

Invoke the callback exactly once on both the success and the non-2xx path — a failed call's
correlation identifier is if anything more valuable than a successful one's, since it is what a
provider support request needs. Leave the existing `Retry-After` parsing exactly where it is; the
error-classification path in `baikai-openai/src/Baikai/Provider/OpenAI/Internal/ErrorClass.hs`
depends on it and this plan should not touch that.

Then in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, add three fields to the `Assembler`:
`providerRequestId :: !(Observed Text)`, `observedModel :: !(Observed Text)`, and
`httpStatus :: !(Maybe Int)`. Initialise them to `Unobserved`, `Unobserved`, and `Nothing`.
Populate the first and third from the metadata callback, and the second from the first chunk
carrying a top-level `model` field. A missing field means the host did not report one, so leave the
value `Unobserved`. Never substitute the configured model — that is the specific mistake the
`Observed` type exists to prevent.

Record the model from the *first* chunk that carries one and do not overwrite it from later
chunks. Compatible hosts repeat the field on every chunk and they should agree; if you find a host
where they disagree, that is a genuine discovery and belongs in this plan's Surprises &
Discoveries rather than being silently resolved by last-write-wins.

The test goes in `baikai-openai/test/SseSpec.hs`, which already replays recorded SSE byte
sequences. Feed a response carrying an `x-request-id` header and chunks whose `model` value
**differs from** the configured model, and assert both values are captured and that the observed
model is the one from the chunks. Making them differ is the point of the fixture: if they were
equal, a bug reading the wrong one would pass.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-openai --test-options='--pattern Sse'
```

### Milestone 3: assemble the evidence

At the end of this milestone an OpenAI-compatible call emits a complete evidence record whose
strength reflects what was actually observed.

In `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, replace the `minimalEvidence` call that plan
52 added with one passing the real `ThinkingTranslation` from Milestone 1, then overwrite the
observed fields from the `Assembler` and set the strength through a named function.

That call returns `Maybe ModelCallEvidence` and is `Nothing` when the caller did not opt into
evidence, so this milestone's enrichment happens inside a `traverse` or an explicit `case` and
never unconditionally. Keep that shape: the request digests hash the whole prompt body and the
response commitment hashes the whole completion, and a caller who never asked for evidence must not
pay for either. Milestone 2's observations are different and stay unconditional — one `KeyMap`
lookup per stream and one allow-list filter per response — because they improve `Response` for
every caller regardless. The test to decide by is whether the work exists solely to serve evidence.

The named strength function:

```haskell
-- | How much this record proves, derived only from what was observed.
-- No OpenAI-compatible host echoes the reasoning configuration it
-- applied, so 'EvidenceFullyObserved' is unreachable on this transport.
-- Reasoning-token counts in the usage block corroborate output volume;
-- they are not a statement of what effort setting was in force and must
-- not raise the strength.
openaiStrength :: Observed Text -> Observed Text -> EvidenceStrength
```

It returns `EvidenceModelObserved` when both the model and a correlation identifier were observed,
`EvidenceCorrelated` when only the identifier was, and `EvidenceRequestedOnly` otherwise. A 200
status must not raise the strength on its own.

Add the response commitment digest over the assembled response — content blocks, finish reason,
and usage — stored as `Observed` on success and left `Unobserved` when the call failed before any
response arrived.

Populate the `EndpointIdentity`'s `implementationVersion` with the `baikai-openai` package version
from the generated `Paths_baikai_openai` module, adding it to the library stanza's `other-modules`
in `baikai-openai/baikai-openai.cabal` if needed. Confirm the endpoint value has its query string
stripped: the multi-host support means a caller's base URL can be anything, and some gateways
accept an API key as a query parameter.

The test is an end-to-end one in a new `baikai-openai/test/EvidenceSpec.hs`, wired into
`baikai-openai/test/Main.hs`. Replay a recorded successful call, collect trace events with a
capturing sink, and assert the single `CallEvidence` record has: `requestedModel` equal to the
configured model; `observedModel` of `Observed` carrying the fixture's different value;
`providerRequestId` of `Observed`; `strength` of `EvidenceModelObserved`; a `thinking` translation
matching the fixture host's shape; and non-empty `requestCommitment`, `requestConfiguration`, and
`responseCommitment` values each beginning with `sha256:`. Add a second case replaying a 429,
asserting `status = CallFailed`, a populated `errorInfo`, an `Observed` `providerRequestId`, and an
`Unobserved` `observedModel` and `responseCommitment`.

Add a third case specific to this transport and worth its own test: shape the same call against a
`ThinkingFormatZai` compat record at `ThinkingMax` and at `ThinkingLow`, and assert the two
request bodies are byte-identical while the two translations differ in `requested` and both carry
`EffortCollapsedToToggle`. That is the clearest possible demonstration of what this evidence is
for — two requests the provider cannot tell apart, which Baikai's record can.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm the two prerequisite plans are complete and the tree is green:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai --test-options='--pattern Evidence'
cabal test baikai-openai
```

Read these files completely before editing, in this order:
`baikai/src/Baikai/Compat.hs` (the seven shapes and their documentation),
`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` (the translation),
`baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` (the transport),
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` (the assembler), and
`baikai-openai/test/ReasoningSpec.hs` together with `baikai-openai/test/ShapeSpec.hs` (the test
patterns you will extend).

Understand the native-versus-compatible split before you write a single table row, because it is
the one thing in this plan that looks like a bug and is not:

```bash
rg -n 'ThinkingFormatOpenAI' -A 2 baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs
rg -n 'compatibleEffort' -B 2 -A 8 baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs
rg -n 'nativeHigherEffortTests|compatibleHigherEffortClampTest' -A 18 baikai-openai/test/ShapeSpec.hs
```

The first shows the native path sending `renderThinkingLevel` verbatim. The second shows
`compatibleEffort` and, above it, the docstring scoping it to the **non-native** shapes. The third
shows the two test groups that assert exactly this contrast.

**Those tests are correct. Do not modify or delete them.** Your forty-two row table must agree
with them; where it does not, the table is wrong. If you become convinced the native behaviour is
actually wrong, stop and record the argument in Surprises & Discoveries rather than changing it —
a behaviour guarded by two named tests and a scoping docstring is a decision, and reversing it is
a change to this plan and to the MasterPlan, not an implementation detail.

Work through the three milestones, committing after each with all three trailers:

```text
Reify the OpenAI-compatible thinking translation across all seven shapes

Return a ThinkingTranslation from shapeRequestBody describing exactly
what went on the wire: an empty adjustment list on the native path,
which expresses every canonical level exactly, and the corresponding
EffortClamped or EffortCollapsedToToggle on the six compatible shapes
that cannot. No request body changes.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/54-emit-openai-compatible-api-call-evidence.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

This plan sends nothing new on the wire, so its changelog entries all belong under `### Added`.
The `Baikai.Compat` Haddock correction is worth its own line under `### Fixed`, since a reader
consulting that comment to decide whether a level is safe to use has until now been told something
untrue.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and `cabal test all` passes.

The translation table covers all forty-two shape-by-level combinations, and every row asserts both
the produced translation and the shaped JSON body. This is IR-3's acceptance criterion 2 for the
OpenAI-compatible transport.

No request body changes anywhere. The existing `baikai-openai` test suite passes **completely
unmodified** — in particular `nativeHigherEffortTests` and `compatibleHigherEffortClampTest` in
`baikai-openai/test/ShapeSpec.hs` still pass untouched. If either needed editing, the
implementation went wrong. This is the sharpest acceptance criterion in the plan precisely because
an earlier draft proposed changing them.

A request against an OpenAI-native host at `ThinkingXHigh` produces a body containing
`"reasoning_effort":"xhigh"` and a translation whose `adjustments` list is **empty**; the same
request against a DeepSeek model produces `"reasoning_effort":"high"` and a translation recording
`EffortClamped ThinkingXHigh "high"`. Prove the pair in adjacent test cases, since the contrast is
the point.

A request against a `ThinkingFormatZai` host at `ThinkingLow` and at `ThinkingMax` produces two
byte-identical request bodies and two translations that differ in `requested` and both carry
`EffortCollapsedToToggle`. A request against a `ThinkingFormatNone` host records
`ThinkingDroppedUnsupportedHost` where before the option vanished with no trace.

A replayed successful call produces exactly one `CallEvidence` record in which `observedModel` is
`Observed` carrying a value *different from* `requestedModel`. This is IR-3's acceptance
criterion 3.

A replayed 429 produces exactly one `CallEvidence` record with `status = CallFailed`, a populated
`errorInfo`, an `Observed` `providerRequestId`, and an `Unobserved` `observedModel`.

Nothing else regressed: the existing `baikai-openai` test suite passes unchanged except for the
assertions this plan deliberately changes, and each such change is recorded in the Decision Log
with its reason.


## Idempotence and Recovery

Every step is safe to repeat; `cabal build` and `cabal test` have no side effects and no test
writes a fixture.

This plan is purely additive on the wire: no host receives anything different after it than
before. That is a deliberate property and it is what makes the whole plan cheap to abandon — if
Milestone 1 goes wrong, `git checkout -- baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`
restores the previous behaviour and nothing downstream of Baikai ever noticed.

The single largest hazard is a well-meaning implementer "fixing" the native effort mapping to
match the six compatible shapes. That would silently downgrade every `xhigh` and `max` request
against a current OpenAI model — the exact failure this initiative exists to eliminate, introduced
by the plan meant to expose it. The two guard tests in `baikai-openai/test/ShapeSpec.hs` are what
catch it; a green run of `cabal test baikai-openai` with those tests unmodified is the proof.

Widening the SSE callback in `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` touches the path
every OpenAI-compatible call goes through, including error classification. Run the error tests
after every edit to that file, not just at the end of the milestone:

```bash
cabal test baikai-openai --test-options='--pattern Error'
```

If it goes wrong, `git checkout -- baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` restores the
previous transport and only Milestone 2 is lost.

The live smoke suite spends real money when credentials are present. It is optional; the fixture
tests are the authority.


## Interfaces and Dependencies

No new package dependencies. This plan uses `Baikai.Evidence` and `Baikai.Evidence.Build` from the
core, plus the `openai`, `http-client`, and `case-insensitive` dependencies `baikai-openai`
already declares.

The surface that must exist when this plan is complete:

In `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`:

```haskell
shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)

injectThinkingShape ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)
```

`compatibleEffort` keeps its current signature and gains one new caller: the
`ThinkingFormatOpenAI` branch.

In `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs`:

```haskell
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }

capturedHeaderNames :: [CI ByteString]

sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
```

with `openaiSseStreamValueWithHeaders` and its siblings widened to match.

In `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, the internal `Assembler` gains
`providerRequestId :: !(Observed Text)`, `observedModel :: !(Observed Text)`, and
`httpStatus :: !(Maybe Int)`, and the module gains:

```haskell
openaiStrength :: Observed Text -> Observed Text -> EvidenceStrength
```

`baikai-openai/baikai-openai.cabal` gains `Paths_baikai_openai` in the library's `other-modules`
and an `EvidenceSpec` module in the test suite's `other-modules`.

The `ThinkingTranslation`, `ThinkingMode`, and `ThinkingAdjustment` types are owned by
`Baikai.Evidence` in the core package and must not be extended here. The seven-shape ecosystem is
the most likely place to discover that a needed adjustment case is missing; if that happens, it is
a change to
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) and to the
MasterPlan's Integration Points section, and both must be updated before the code is written.
