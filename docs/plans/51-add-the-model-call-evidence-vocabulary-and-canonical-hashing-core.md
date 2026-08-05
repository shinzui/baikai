---
id: 51
slug: add-the-model-call-evidence-vocabulary-and-canonical-hashing-core
title: "Add the model-call evidence vocabulary and canonical hashing core"
kind: exec-plan
created_at: 2026-08-05T20:23:57Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Add the model-call evidence vocabulary and canonical hashing core

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai is a Haskell library that lets an application talk to several AI providers — Anthropic's
API, any OpenAI-compatible API, and two coding-agent command-line tools — through one interface.
Today, when a Baikai application finishes a call to a model, it can record a small trace event
saying which provider it used, which model identifier it *configured*, how long the call took,
and roughly how many tokens were involved. That is enough for cost dashboards. It is not enough
for anyone who has to demonstrate, later, what actually crossed the boundary between the
application and the provider.

This plan adds the vocabulary for that stronger record, and nothing else. After this plan, the
`baikai` package exposes a new module `Baikai.Evidence` containing a single value type,
`ModelCallEvidence`, that can describe one completed provider call in full: who was asked, what
was asked for, what Baikai actually put on the wire after translating the request for that
specific provider, what the provider was observed to say back, and two cryptographic digests
that let a third party check the record later without Baikai handing over anyone's prompt.

Nothing constructs a `ModelCallEvidence` from a real call yet. That is deliberate — this plan is
pure, has no provider dependencies, and can be proved entirely with unit and golden tests. The
plans that follow it (listed in
[docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md](../masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md))
fill the record in from each transport.

Two user-visible things do change. First, a caller can now attach a **run identifier** to a call
through the existing per-call options record, so that several calls belonging to the same logical
piece of work can later be grouped. Second, the identifier Baikai generates for each call becomes
genuinely unique instead of merely unique-within-one-process; the current generator produces
identical identifier sequences in two processes that start in the same second, which is a real
collision hazard for anything that correlates records across processes.

You can see the whole thing working by running the new test suite section:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai --test-options='--pattern Evidence'
```

which proves that the same logical evidence value always produces the same digest regardless of
how its maps happened to be ordered in memory, and that no API key, prompt body, reasoning text,
or tool payload ever appears anywhere in the encoded envelope.


## Progress

- [x] Add the `cryptohash-sha256` and `base16-bytestring` dependencies to `baikai/baikai.cabal`
      and confirm the package still builds. (2026-08-05)
- [x] Create `baikai/src/Baikai/Evidence.hs` with the `Observed` type and its helpers.
      (2026-08-05)
- [x] Add `ThinkingTranslation`, `ThinkingMode`, and `ThinkingAdjustment`. (2026-08-05)
- [x] Add `EndpointIdentity`, `TransportKind`, `CallStatus`, and `EvidenceStrength`. (2026-08-05)
- [x] Add `EvidenceRequest` and `EvidenceStrictness` (the caller-facing request shape).
      (2026-08-05)
- [x] Add the `ModelCallEvidence` record itself and the `evidenceSchemaVersion` constant.
      (2026-08-05)
- [x] Implement canonical JSON encoding (`canonicalEncode`). (2026-08-05)
- [x] Implement `commitmentDigest` and `configurationDigest`. (2026-08-05)
- [x] Replace the call-identifier generator and expose `newCallId`. (2026-08-05)
- [x] Add the `evidence` field to `Baikai.Options`. (2026-08-05)
- [x] Export `Baikai.Evidence` from the umbrella `Baikai` module and add it to the cabal
      `exposed-modules` list. (2026-08-05)
- [x] Write `baikai/test/EvidenceSpec.hs` covering canonicality, redaction, and `Observed`
      semantics; wire it into `baikai/test/Main.hs`. (2026-08-05)
- [x] Add the identifier-uniqueness cases to `baikai/test/EvidenceSpec.hs`. (2026-08-05)
- [x] Update `baikai/test/TraceSpec.hs`'s identifier-width assertion from 16 to 32 characters and
      record why in the Decision Log. (2026-08-05)
- [x] Add the golden digest fixture at `baikai/test/fixtures/evidence-request.json`. One fixture
      serves both the golden-digest and the redaction tests. (2026-08-05)
- [x] Add a `CHANGELOG.md` entry under the existing `[Unreleased]` heading. (2026-08-05)


## Surprises & Discoveries

**`Baikai.Cost` cannot round-trip through JSON, which forces `ModelCallEvidence` to be
write-only.** The plan's Milestone 2 asked for both a `ToJSON` and a `FromJSON` instance on
`ModelCallEvidence`. That turns out not to be honestly implementable. The record embeds
`Baikai.Usage.Usage`, which embeds `Baikai.Cost.Cost`, whose `usd` and per-class breakdown fields
are exact `Rational` values encoded through `ratToSci = fst . fromRationalRepetendUnlimited`
(`baikai/src/Baikai/Cost.hs:84`). That conversion approximates any rational whose decimal
expansion repeats. Neither `Cost` nor `Usage` has a `FromJSON` instance today, and writing one
would produce a decoder that silently returns a different value than was encoded — precisely the
kind of quiet fidelity loss this initiative exists to eliminate. `ModelCallEvidence` therefore
gets `ToJSON` only, with the reason stated in its Haddock. See the Decision Log.

**`base16-bytestring` 1.0.2.0 does not export `encodeBase16`.** The plan names
`Data.ByteString.Base16.encodeBase16` as the hex renderer. That function existed in the 1.0.0 and
1.0.1 series; the 1.0.2.0 module in the local package store exports only `encode`, `decode`, and
`decodeLenient`, all `ByteString`-to-`ByteString`:

```text
src/Baikai/Evidence.hs:870:27: error: [GHC-76037]
    Not in scope: ‘Base16.encodeBase16’
    Note: The module ‘Data.ByteString.Base16’ does not export ‘encodeBase16’.
```

`digestOf` now calls `Base16.encode` and decodes the result with
`Data.Text.Encoding.decodeLatin1`, which is total and exact because base16 output is lowercase
ASCII by construction.

**Aeson's own string escaper was rejected in favour of a hand-written one.** The first sketch
reused `Data.Aeson.Encoding.text` for string escaping, which is correct and deterministic — but
only for a fixed aeson version. Since the commitment digest is a value that outlives the build
that produced it, an aeson upgrade quietly changing an escape rule would invalidate every
recorded digest with no code change in this repository. The escaper is now written out in
`Baikai.Evidence` (about fifteen lines), so the canonical encoding depends on nothing that can
change underneath it.

**Number canonicalisation needs `Scientific.normalize`, not just a format choice.** Rendering
through `formatScientific Fixed Nothing` alone is not canonical: aeson parses `1.1` into a
`Scientific` with coefficient 11 and exponent -1, and `1.100` into coefficient 1100 and exponent
-3, and `formatScientific` faithfully renders those as `1.1` and `1.100`. Two equal values, two
digests. `Scientific.normalize` strips the trailing zeros first. The test case
`normalises integral and fractional number spellings` pins nine spellings against their canonical
forms.

**`ModelCallEvidence` and `EvidenceRequest` share three field names, so bare selectors are
ambiguous.** Both records carry `runId`, `attempt`, and `supersedes` — deliberately, since they
are the same three facts travelling from the caller into the record, and the repository's
convention forbids prefixing a field with its record's name. Under `DuplicateRecordFields` that
makes `runId r` an ambiguous occurrence rather than a type-directed lookup, which GHC 9.12 no
longer resolves:

```text
test/EvidenceSpec.hs:242:9: error: [GHC-87543]
    Ambiguous occurrence ‘runId’.
    It could refer to
       either the field ‘runId’ of record ‘EvidenceRequest’,
           or the field ‘runId’ of record ‘ModelCallEvidence’,
```

This is not a problem for library code, which reaches fields through the `generic-lens` labels
(`r ^. #runId`) that the rest of the codebase already uses; it only bites code that reaches for a
bare selector. The test destructures with a record pattern instead, and says so in a comment.
Later plans in this initiative should use the label form.

**The plan's `/dev/urandom` seeding instruction would hang the process.** Milestone 4 specifies
reading the seed with `Data.ByteString.readFile`. `BS.readFile` asks for the file's size, gets
zero for a character device, and then reads in a loop until EOF — and `/dev/urandom` never
reaches EOF. The correct call is `withBinaryFile "/dev/urandom" ReadMode (\h -> BS.hGet h 8)`,
which reads exactly eight bytes. This was caught by reading the `bytestring` implementation
before writing the code rather than by observing a hang.


## Decision Log

- Decision: Use `cryptohash-sha256` plus `base16-bytestring` rather than `crypton`.
  Rationale: `crypton` is a full cryptographic framework and pulls in a large dependency tree;
  this plan needs exactly one hash function. `cryptohash-sha256` is a single-purpose package,
  already present in the local package store at version 0.11.102.1, and `base16-bytestring`
  (1.0.2.0) renders the digest. Neither adds a transitive burden to a library that many
  applications depend on.
  Date: 2026-08-05

- Decision: Compose the call identifier from a per-process random seed plus a counter, rather than
  drawing randomness per call.
  Rationale: `newCallId` replaces `newEventId`, which sits on the trace path for every call
  regardless of whether the caller wants evidence. A per-call read from `/dev/urandom` would be
  several syscalls on a path that currently costs one atomic increment, imposed on people who never
  asked for evidence. Seeding once fixes the actual defect — the old generator produced identical
  sequences in two processes started in the same second — at no per-call cost. These identifiers
  correlate records; they are not secrets and unguessability is not a requirement.
  Date: 2026-08-05

- Decision: Change `baikai/test/TraceSpec.hs`'s identifier-width assertion from 16 to 32
  characters, and keep the test pointed at the deprecated `newEventId`.
  Rationale: The plan's Validation section anticipated this. The assertion in question read
  `assertBool "every id is 16 chars" (all ((== 16) . Text.length) ids)`, and its test was named
  "newEventId yields 70000 distinct 16-char ids". Sixteen characters is exactly the property the
  replacement removes: the old generator's 64 bits were half process-start seconds, which is what
  made two processes collide. The uniqueness assertion — the part that carries the actual
  behavioural claim — is unchanged, and the count stays at 70000. The comment above the test now
  quotes the old assertion and says why it moved, so the change is legible as a decision rather
  than as drift. `TraceSpec` keeps importing `newEventId` under a file-scoped
  `-Wno-deprecations`, because the alias is still public surface and deleting its only test to
  silence a warning would trade real coverage for tidiness.
  Date: 2026-08-05

- Decision: Give `ModelCallEvidence` a `ToJSON` instance only, not the `FromJSON` instance
  Milestone 2 originally called for.
  Rationale: The record embeds `Usage`, which embeds `Cost`, whose `Rational` amounts encode
  through an approximating `Scientific` (see Surprises & Discoveries). A `FromJSON` would not
  round-trip and would assert a fidelity the encoding does not have. Evidence is an interchange
  format read out of process — that is what `evidenceSchemaVersion` is for — and a Haskell test or
  consumer that needs to inspect an emitted record can decode it as a plain `Aeson.Value` and
  match on fields, which tests the actual schema rather than a Haskell mirror of it. The
  `Observed` type keeps its `FromJSON`, because the plan's acceptance requires proving that
  `"unobserved"` round-trips, and `Observed` carries no lossy payload of its own.
  Date: 2026-08-05

- Decision: Spell evidence JSON field names in snake_case, matching the rest of the package.
  Rationale: The plan specified `defaultOptions` with `omitNothingFields = False` and said nothing
  about field naming. Leaving the default would render `requestedModel` beside `input_tokens` and
  `http_status`, because the embedded `Usage` and `BaikaiError` records already use
  `camelTo2 '_'`. One record with two naming conventions inside it is worse than either
  convention. `omitNothingFields = False` is kept and stated explicitly in the options value with
  a comment, because it is load-bearing rather than incidental.
  Date: 2026-08-05

- Decision: Model an unobserved value as a dedicated `Observed a` type rather than `Maybe a`.
  Rationale: The initiative's central rule is that a field the provider did not report must never
  be backfilled from the request. `Maybe` invites exactly that mistake, because `fromMaybe
  requestedModel observedModel` reads as reasonable code. A distinct type with no `Monoid`, no
  `fromMaybe`-shaped helper, and a name that says what it means makes the mistake visible at the
  call site and in review.
  Date: 2026-08-05


## Outcomes & Retrospective

This section was absent from the file as generated; it is required by the ExecPlan
specification and was added when the plan was completed.

**What was achieved.** `baikai` exposes `Baikai.Evidence`, holding the whole vocabulary for
describing one completed provider call — `ModelCallEvidence` and `evidenceSchemaVersion`,
`Observed`, `ThinkingTranslation` with `ThinkingMode` and `ThinkingAdjustment`,
`EndpointIdentity`, `TransportKind`, `CallStatus`, the ascending `EvidenceStrength`,
`EvidenceRequest` with `EvidenceStrictness`, and the `baseEvidence` smart constructor — plus the
canonical hashing core (`canonicalEncode`, `commitmentDigest`, `configurationDigest`,
`configurationProjection`) and the replacement identifier generator `newCallId`. `Options` gained
its `evidence` field, `Baikai.Trace.newEventId` became a deprecated delegate, and the umbrella
`Baikai` module re-exports the new module.

**Proof.** `cabal test all` passes every suite: `baikai` 193 (168 before this plan, 25 new),
`baikai-claude` 174, `baikai-openai` 81, `baikai-agent` 65, `baikai-kit` 29, `baikai-effectful` 4,
`baikai-trace-otel` 3, and `baikai-smoke` skipping its live providers for want of credentials as
designed. `cabal build all` emits no warning. The interactive checks the Validation section calls
for were run in `cabal repl baikai`:

```text
digests equal across key order: True
rendered: "sha256:d3626ac30a87e6f7a6428233b3c68299976865fa5508e4267c5415c76af7a772"
configuration digests equal: True
commitment digests equal: False
1000 ids all distinct: True
run id round-trips: Just "run-42"
```

The third and fourth lines are the pair that matters: equal configuration digests prove the
projection removed the content, and unequal commitment digests prove the commitment did not.

**What remains for later plans.** Nothing constructs a `ModelCallEvidence` from a real call, by
design. Two things this plan deliberately left undone are worth naming so a later plan does not
rediscover them as gaps. `EndpointIdentity.baikaiVersion` has no source: this plan did not wire
up a `Paths_baikai` autogen module, so
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) owns
deciding where the version string comes from and must do it once, centrally, rather than letting
each adapter hardcode a literal. And `EvidenceStrictness` is inert: the field round-trips and
providers can read it, but nothing enforces it until
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md).

**Lessons.** Three of this plan's concrete instructions were wrong in ways that only reading the
dependency's source could catch — the `encodeBase16` export, the `readFile`-on-`/dev/urandom`
hang, and the missing `Scientific.normalize`. Each was cheap to fix at implementation time and
would have been expensive to discover later; the `/dev/urandom` one would have shipped as a hang.
The general lesson is the one already in this repository's habits: verify an API against the
installed source rather than against recollection of it, especially for a function whose output
becomes a durable recorded value.

The other lesson is about the `FromJSON` that could not be written. The plan asked for a
round-trip instance and the type system happily would have accepted one; only tracing `Usage`
down through `Cost` to `fromRationalRepetendUnlimited` showed that the round trip would silently
lie. An initiative whose whole premise is that a record must not claim more than it observed has
to hold its own serialisation to the same standard.


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository containing eight Cabal packages,
each in a directory named after it. The one this plan changes is `baikai/`, the core package that
owns every provider-neutral type. The others — `baikai-claude/`, `baikai-openai/`,
`baikai-effectful/`, `baikai-trace-otel/`, `baikai-kit/`, `baikai-agent/`, and `baikai-smoke/` —
depend on it. This plan changes only `baikai/` and must not require changes anywhere else.

The build is plain Cabal. From the repository root, `cabal build all` compiles everything and
`cabal test baikai` runs the core package's test suite. The test suite lives in `baikai/test/`,
uses the `tasty` framework with `tasty-hunit` assertions, and is assembled in
`baikai/test/Main.hs`, which imports each `*Spec.hs` module and lists its `tests :: TestTree`
value in one top-level group.

Every library module in `baikai/` is compiled with the warning set declared in the
`common-options` stanza of `baikai/baikai.cabal`, and warnings are worth knowing about in advance
because three of them will bite you: `-Wmissing-export-lists` means every module must have an
explicit export list; `-Wpartial-fields` means a record field selector defined across more than
one constructor of a sum type is an error you must design around (the existing
`baikai/src/Baikai/Trace/Event.hs` opts out with a file-level
`{-# OPTIONS_GHC -Wno-partial-fields #-}`, which is the escape hatch if you need it); and
`-Wmissing-deriving-strategies` means every `deriving` clause must say `deriving stock`,
`deriving anyclass`, or `deriving newtype` explicitly. The language is GHC2024 with
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings` enabled by
default.

`DuplicateRecordFields` matters for style here. Because it is on, several unrelated records in
this codebase legitimately share plain field names — `Baikai.Response.Response` and
`Baikai.Model.Model` both have a `provider` field, for instance. **Do not prefix record fields
with the record's name.** A field is called `runId`, not `evidenceRunId`. This applies to
internal and assembler records too, not only public ones.

Field access throughout the codebase goes through `generic-lens` overloaded labels: you write
`model ^. #modelId` rather than `modelId model`. The `Baikai.Prelude` module re-exports the lens
and `generic-lens` vocabulary plus `Text`, `Vector`, `Natural`, `Generic`, and the aeson
`ToJSON`/`FromJSON` classes; most modules in the package import it.

### The existing pieces this plan touches or must agree with

`baikai/src/Baikai/ThinkingLevel.hs` defines `ThinkingLevel`, the provider-neutral
reasoning-effort preference. It has six constructors in ascending order — `ThinkingMinimal`,
`ThinkingLow`, `ThinkingMedium`, `ThinkingHigh`, `ThinkingXHigh`, `ThinkingMax` — a
`renderThinkingLevel` function producing the canonical lowercase names (`"minimal"` through
`"max"`), and a `thinkingTokenBudget` function giving each level a recommended token count for
providers that take an explicit budget rather than an effort word. Read this file before
starting; the translation vocabulary this plan defines exists to describe what each provider does
to these six values.

`baikai/src/Baikai/Options.hs` defines `Options`, the record of per-call knobs. It currently has
fifteen fields, all either `Maybe`-wrapped or a container with an empty default, and a smart
constructor `emptyOptions` that sets them all to their empty value. This plan adds a sixteenth
field. Note the module's export list style: it exports the type name `Options` *without*
constructors, then exports each field selector individually. Follow that pattern.

`baikai/src/Baikai/Usage.hs` defines `Usage`, the normalized token accounting for one call. Its
prompt-side classes are deliberately disjoint: `inputTokens` counts only non-cached prompt tokens
and excludes both cache counters, `cacheReadTokens` counts prompt tokens served from a
provider-side cache, and `cacheWriteTokens` counts prompt tokens stored for future reads.
`totalTokens` is their sum plus `outputTokens`. `reasoningTokens` is a `Maybe Natural` that, when
present, is an informational *subset* of `outputTokens` and is not billed separately. The
evidence record reuses this type verbatim rather than re-deriving a token breakdown.

`baikai/src/Baikai/Error.hs` defines `BaikaiError`, the normalized error type, with a category
enumeration, an optional HTTP status, and an optional retry-after hint. The evidence record
reuses it for its normalized error field.

`baikai/src/Baikai/Api.hs` defines `Api`, a small sum tagging which wire protocol a model speaks
(`AnthropicMessages`, `AnthropicMessagesCli`, `OpenAIChatCompletions`, `OpenAICompletionsCli`,
and a `Custom Text` escape), with a `renderApi` function. The evidence record's transport
identity is derived from this.

`baikai/src/Baikai/Trace.hs` contains, at the very bottom under the heading `Event id`, the
function `newEventId` and the two `unsafePerformIO` top-level values it depends on,
`eventCounter` and `eventBase`. `newEventId` builds a 64-bit word whose high 32 bits are the
process's start time in POSIX seconds and whose low 32 bits are a monotonic counter, then renders
it as sixteen lowercase hexadecimal characters. Its own documentation says the result is unique
"within a process". This plan replaces it.

`baikai/src/Baikai.hs` is the umbrella module that re-exports the package's public modules so
that `import Baikai` brings the common surface into scope. It uses `module X` re-export syntax.
Note that `Baikai.Agent` is deliberately *not* re-exported there, because its field names
intentionally collide with `Baikai.Interactive`'s. `Baikai.Evidence` has no such collision and
should be re-exported.

### Terms used in this plan

An **envelope** is the JSON object Baikai would send to (or received from) a provider, considered
as data rather than as a network event. A **canonical encoding** is a rule for turning a value
into bytes such that two values that are equal always produce identical bytes — in particular,
object keys are emitted in a fixed order and numbers have exactly one spelling. A **digest** is
the SHA-256 hash of those bytes, rendered as lowercase hexadecimal. A **commitment** is a digest
published on its own: it reveals nothing about the input, but anyone who later obtains the input
can recompute the digest and confirm it matches. **Redaction** means removing or replacing
sensitive content before encoding.

### ADR context

This repository has no `docs/adr/` directory and no Architecture Decision Records. The
`mori.dhall` manifest declares one OKF bundle — `improvement-requests` at
`docs/improvement-requests` — and `mori show --full` reports zero ADR bundles, so there is no
local ADR convention to follow and no profile to validate against. A registry search for
cross-repository decisions about provider-boundary evidence or attestation envelopes returned
nothing applicable. Record decisions in this plan's Decision Log; the final plan in this
initiative
([docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md)) is
responsible for establishing `docs/adr/` and promoting the durable ones.


## Plan of Work

The work is four milestones. The first three build `Baikai.Evidence` bottom-up — the small types,
then the record that contains them, then the encoding and hashing that operate on it — and the
fourth wires the new vocabulary into the two existing modules that must know about it. Each
milestone leaves the package compiling and the existing test suite green.

### Milestone 1: the small types

At the end of this milestone `baikai/src/Baikai/Evidence.hs` exists and compiles, containing
every type that `ModelCallEvidence` will be built from, but not `ModelCallEvidence` itself. There
is no behavior to observe yet beyond compilation and the type-level tests described below.

Start by adding the two new dependencies to the `library` stanza's `build-depends` list in
`baikai/baikai.cabal`, in the alphabetically sorted position the existing list uses:

```cabal
    , base16-bytestring  ^>=1.0
    , cryptohash-sha256  ^>=0.11
```

Add `Baikai.Evidence` to the `exposed-modules` list in the same stanza, alphabetically between
`Baikai.Error` and `Baikai.Interactive`. Also add `base16-bytestring` and `cryptohash-sha256` to
the `baikai-test` test-suite stanza's `build-depends` if the tests need them directly; they
should not, because the tests exercise the digest functions through `Baikai.Evidence`.

Now create the module. Its header must carry an explicit export list because of
`-Wmissing-export-lists`.

The first type is `Observed`, which is the heart of the honesty rule this whole initiative
exists to enforce:

```haskell
-- | A value the provider either did or did not report back.
--
-- This is deliberately not 'Maybe'. A 'Maybe' invites @fromMaybe
-- requested observed@, which is precisely the error this type exists to
-- prevent: a field the provider never reported must never be filled in
-- from what was requested. There is intentionally no function here that
-- supplies a default.
data Observed a
  = -- | The provider reported this value.
    Observed !a
  | -- | The provider did not report this value, or the transport
    -- cannot carry it. This is a positive statement about the
    -- provider's silence, not a missing field.
    Unobserved
  deriving stock (Eq, Show, Generic, Functor)
```

Give it a `ToJSON` instance that encodes `Observed x` as `{"observed": <x>}` and `Unobserved` as
the JSON string `"unobserved"`, and a matching `FromJSON`. Write these by hand rather than
deriving generically, because the wire shape matters: IR-3 requires that a provider response
which does not echo the model records `unobserved`, and a reader of the JSON should be able to
see that word. Provide one accessor, `observedValue :: Observed a -> Maybe a`, for callers that
genuinely want to branch — and document in its Haddock that using it to supply a default defeats
the type's purpose.

The second group describes what happened to the caller's reasoning-effort request. `ThinkingMode`
says which shape the provider's thinking configuration took:

```haskell
data ThinkingMode
  = -- | The provider took an explicit token budget.
    ThinkingModeBudget
  | -- | The provider chose its own depth, steered by an effort word.
    ThinkingModeAdaptive
  | -- | The preference travelled as a command-line flag.
    ThinkingModeFlag
  | -- | The provider accepted a bare on/off toggle with no depth.
    ThinkingModeToggle
  | -- | The caller requested a level and this transport cannot express
    --   any part of it.
    ThinkingModeUnsupported
  | -- | The caller requested no level at all.
    ThinkingModeAbsent
```

`ThinkingAdjustment` records one thing that happened to the request on the way to the wire. This
is the type that makes silent downgrades visible, so its constructors must cover every real case
found in the codebase — see the Surprises & Discoveries section of the MasterPlan for the
enumeration:

```haskell
data ThinkingAdjustment
  = -- | The requested level was replaced by a weaker one the transport
    --   accepts. Carries the requested level and the wire text sent.
    EffortClamped !ThinkingLevel !Text
  | -- | The transport expresses no depth, so the level only turned
    --   thinking on. Carries the requested level.
    EffortCollapsedToToggle !ThinkingLevel
  | -- | The transport sends no effort field for this level, so the
    --   request is indistinguishable on the wire from the provider's
    --   own default. Carries the requested level.
    EffortOmitted !ThinkingLevel
  | -- | The chosen model does not advertise reasoning support, so the
    --   thinking configuration was dropped entirely.
    ThinkingDroppedUnsupportedModel !ThinkingLevel
  | -- | The host exposes no reasoning controls at all, so the
    --   configuration was dropped.
    ThinkingDroppedUnsupportedHost !ThinkingLevel
  | -- | A computed thinking budget was discarded because it did not fit
    --   inside the resolved output-token ceiling. Carries the requested
    --   level, the budget that was computed, and the ceiling.
    ThinkingDroppedBudgetExceeded !ThinkingLevel !Natural !Natural
```

`ThinkingTranslation` is the record that carries all of it, and is the value a provider adapter
must return rather than let anything downstream re-derive:

```haskell
data ThinkingTranslation = ThinkingTranslation
  { requested :: !(Maybe ThinkingLevel),
    mode :: !ThinkingMode,
    -- | The exact effort text placed on the wire, when the transport
    --   uses one.
    effortText :: !(Maybe Text),
    -- | The exact token budget placed on the wire, when the transport
    --   uses one.
    budgetTokens :: !(Maybe Natural),
    -- | The provider-specific field name the configuration travelled
    --   in, for example @"thinking"@, @"reasoning_effort"@, or
    --   @"--effort"@. Empty when nothing was sent.
    wireField :: !(Maybe Text),
    -- | Everything that happened to the request between the canonical
    --   level and the wire, in the order it was applied. Empty means
    --   the request was expressed exactly.
    adjustments :: ![ThinkingAdjustment]
  }
```

Provide `noThinkingRequested :: ThinkingTranslation`, the value for a call where the caller set no
level: `requested = Nothing`, `mode = ThinkingModeAbsent`, everything else empty.

The third group describes the transport and the outcome. `TransportKind` distinguishes an HTTP
API call from a subprocess call from an unattended agent run, because their evidence strengths
differ fundamentally:

```haskell
data TransportKind
  = TransportHttpApi
  | TransportSubprocess
  | TransportAgentRun
```

`EndpointIdentity` records where the call went without recording a credential:

```haskell
data EndpointIdentity = EndpointIdentity
  { -- | The provider name as Baikai knows it, e.g. @"anthropic"@.
    provider :: !Text,
    -- | The wire protocol tag, rendered from 'Baikai.Api.Api'.
    api :: !Text,
    transport :: !TransportKind,
    -- | Scheme, host, port, and path with every query parameter and
    --   userinfo component removed. A query string can carry an API key
    --   on some gateways, so it is dropped rather than filtered.
    endpoint :: !(Maybe Text),
    -- | The version of the Baikai package that produced this record.
    baikaiVersion :: !Text,
    -- | The provider implementation's own version, when it has one:
    --   the vendor package version for an API provider, or the
    --   executable's reported version for a subprocess.
    implementationVersion :: !(Maybe Text)
  }
```

`CallStatus` is the terminal outcome:

```haskell
data CallStatus
  = CallSucceeded
  | CallFailed
  | -- | The consumer stopped reading before the provider finished.
    CallAborted
```

`EvidenceStrength` is the honest self-assessment of how much a given record proves. Its
constructors ascend, and the derived `Ord` instance is what strict mode will compare against a
caller's requirement in
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md), so **do not
reorder them**:

```haskell
data EvidenceStrength
  = -- | Baikai recorded what it requested and translated. The provider
    --   reported nothing back that corroborates it. A successful process
    --   exit does not raise a record to a higher strength.
    EvidenceRequestedOnly
  | -- | The provider returned a correlation identifier, so this call can
    --   be located in the provider's own records, but it did not report
    --   the model or the effort it used.
    EvidenceCorrelated
  | -- | The provider reported the model it ran, in addition to a
    --   correlation identifier.
    EvidenceModelObserved
  | -- | The provider reported both the model and its effective thinking
    --   configuration.
    EvidenceFullyObserved
  deriving stock (Eq, Ord, Show, Generic)
```

Finally, the caller-facing request shape. `EvidenceStrictness` says whether a caller merely wants
evidence or requires it:

```haskell
data EvidenceStrictness
  = -- | Record whatever this transport can supply. Never fails a call
    --   for evidence reasons. This is the behaviour every existing
    --   caller gets.
    EvidenceBestEffort
  | -- | Refuse, before dispatch, to run this call on a transport that
    --   cannot reach the required strength or that would weaken the
    --   requested thinking level.
    EvidenceRequired !EvidenceStrength
  deriving stock (Eq, Show, Generic)

data EvidenceRequest = EvidenceRequest
  { -- | The caller's identifier for the logical unit of work this call
    --   belongs to. Baikai treats it as opaque text and never parses it.
    runId :: !Text,
    strictness :: !EvidenceStrictness,
    -- | Which attempt this is, when the caller is retrying. One-based.
    --   Baikai has no retry loop of its own, so this is provenance the
    --   caller supplies, not something Baikai observes.
    attempt :: !Natural,
    -- | The call id of the attempt this one supersedes, when the caller
    --   is retrying or falling back.
    supersedes :: !(Maybe Text)
  }

evidenceRequest :: Text -> EvidenceRequest
```

`evidenceRequest runId` is the smart constructor: best-effort strictness, attempt one, superseding
nothing.

Verify the milestone by building and confirming no warnings:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai
```

Expect a clean build. Any `-Wmissing-deriving-strategies` or `-Wmissing-export-lists` warning is a
failure of this milestone, not a nuisance.

### Milestone 2: the record

At the end of this milestone `ModelCallEvidence` exists, along with the schema version constant
that identifies its shape to downstream consumers.

The schema version is a plain constant, not a derived value, and it must be bumped by hand
whenever a field is added, removed, or given a different meaning:

```haskell
-- | The schema identifier for 'ModelCallEvidence'. Consumers pin
-- against this. Bump the minor component when a field is added in a way
-- that leaves existing readers working; bump the major component when a
-- field is removed or changes meaning.
evidenceSchemaVersion :: Text
evidenceSchemaVersion = "baikai.model-call-evidence/1.0"
```

The record itself is large. Group its fields with comments in the order below, because that order
is the story the record tells: who ran it, what was asked, what was sent, what came back, and
what it costs to believe.

```haskell
data ModelCallEvidence = ModelCallEvidence
  { -- Identity -------------------------------------------------------
    schemaVersion :: !Text,
    runId :: !Text,
    callId :: !Text,
    attempt :: !Natural,
    supersedes :: !(Maybe Text),

    -- Where it went --------------------------------------------------
    endpoint :: !EndpointIdentity,

    -- What was requested ---------------------------------------------
    requestedModel :: !Text,
    thinking :: !ThinkingTranslation,

    -- What came back -------------------------------------------------
    observedModel :: !(Observed Text),
    observedThinking :: !(Observed Text),
    responseId :: !(Observed Text),
    providerRequestId :: !(Observed Text),
    -- | The identifier Baikai put on the outgoing request, when it sent
    --   one. Unlike the two fields above, this is something Baikai knows
    --   by construction rather than observes.
    clientRequestId :: !(Maybe Text),

    -- How it went ----------------------------------------------------
    startedAt :: !UTCTime,
    endedAt :: !UTCTime,
    latencyMs :: !Int,
    status :: !CallStatus,
    errorInfo :: !(Maybe BaikaiError),
    usage :: !(Observed Usage),

    -- What it proves -------------------------------------------------
    strength :: !EvidenceStrength,
    requestCommitment :: !Text,
    requestConfiguration :: !Text,
    responseCommitment :: !(Observed Text)
  }
  deriving stock (Eq, Show, Generic)
```

Several field choices need justifying in the Haddock you write, because a later reader will
otherwise assume they are accidents.

`usage` is `Observed Usage` rather than a bare `Usage`. The existing code substitutes
`zeroUsage` when a provider reports nothing — see `mkResponse` in
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`, which sets `usage = zeroUsage` for every
subprocess call. In a cost log that substitution is harmless; in evidence it is a false statement
that the call used zero tokens. Making the field `Observed` forces the distinction.

`observedThinking` is `Observed Text`, holding the provider's own description of the thinking
configuration it applied, when the provider reports one. Reasoning-token counts do **not** belong
here: they live in `usage` and they are corroborating evidence about output, not a statement of
what effort setting was applied. Say so in the Haddock.

`errorInfo` is `Maybe BaikaiError` and is `Nothing` exactly when `status` is `CallSucceeded`.

`responseCommitment` is `Observed Text` because a call that failed before any response body
arrived has no response to commit to, and recording an empty-string digest there would be a
fabrication.

Provide one smart constructor so that later plans cannot leave a field uninitialised when the
record grows:

```haskell
-- | The evidence a transport can always produce: identity, endpoint,
-- requested model, thinking translation, timing, status, and the two
-- request digests. Every observed field starts 'Unobserved' and the
-- strength starts at 'EvidenceRequestedOnly'. A transport that learns
-- more overwrites those fields and raises the strength.
baseEvidence ::
  EvidenceRequest ->
  Text ->              -- ^ call id
  EndpointIdentity ->
  Text ->              -- ^ requested model id
  ThinkingTranslation ->
  UTCTime ->           -- ^ started at
  UTCTime ->           -- ^ ended at
  CallStatus ->
  Text ->              -- ^ request commitment digest
  Text ->              -- ^ request configuration digest
  ModelCallEvidence
```

Give `ModelCallEvidence` a `ToJSON` instance and a `FromJSON` instance. Use `Data.Aeson`'s
`defaultOptions` with `omitNothingFields = False` — an evidence record must render an absent
field as `null` rather than dropping it, because a reader must be able to tell "Baikai recorded
nothing here" apart from "this record predates the field". This is the opposite of the choice
`baikai/src/Baikai/Trace/Event.hs` makes for trace events, and the difference is intentional;
note it in the Haddock so nobody harmonises them later.

### Milestone 3: canonical encoding and the two digests

At the end of this milestone the module can turn a JSON value into stable bytes and both digest
functions work. This is the milestone with real, observable behavior, and it carries the golden
tests.

Canonical encoding needs a fixed rule. Implement `canonicalEncode :: Aeson.Value -> ByteString`
with these properties, and state them all in the function's Haddock because a later maintainer
will need to preserve them:

Object keys are emitted in ascending order by their UTF-8 byte sequence, recursively. Aeson's
`Object` is a `KeyMap` whose iteration order is unspecified and in practice depends on insertion
history, so you must sort explicitly — `Data.Aeson.KeyMap.toAscList` gives you the sorted
association list. Arrays keep their order, since array order is semantically meaningful. There is
no insignificant whitespace: no spaces after colons or commas, no trailing newline. Strings are
encoded as UTF-8 with the minimal escaping JSON requires and `\uXXXX` escapes only where
mandatory, so that two equal strings never differ in their bytes. Numbers are the one genuine
hazard: aeson stores them as `Scientific`, and the same mathematical value can have several
`Scientific` spellings. Normalise by rendering integral values as a plain integer with no decimal
point and no exponent, and non-integral values through `Data.Scientific`'s
`formatScientific Fixed Nothing`, which produces a fixed-point rendering with no exponent. Reject
nothing; a value that cannot be canonicalised is a bug in the caller, not a runtime condition.

The digest itself:

```haskell
-- | SHA-256 of the canonical encoding, rendered as 64 lowercase
-- hexadecimal characters, prefixed with the algorithm so the string is
-- self-describing: @"sha256:1b4f0e98..."@.
digestOf :: Aeson.Value -> Text
```

Implement it with `Crypto.Hash.SHA256.hash` from `cryptohash-sha256` and
`Data.ByteString.Base16.encodeBase16` from `base16-bytestring`.

Then the two digests the initiative actually needs, which differ in what they hash rather than in
how:

```haskell
-- | A commitment to the exact request body Baikai sent, including
-- prompt content. The digest itself reveals nothing: publishing it does
-- not disclose the prompt. Anyone who independently holds the request
-- can recompute this value and confirm that a given evidence record
-- describes that request. Credentials never appear in a request body,
-- so nothing is redacted here; header values are not part of the input.
commitmentDigest :: Aeson.Value -> Text

-- | A digest over the request's configuration only, with all content
-- removed. Two calls that ask the same model the same way about
-- different subjects produce the same value here. This proves how a
-- call was configured; it deliberately proves nothing about what was
-- asked, and must not be presented as binding a run to any particular
-- input.
configurationDigest :: Aeson.Value -> Text
```

`configurationDigest` needs a projection function that reduces a request envelope to its
configuration. Implement `configurationProjection :: Aeson.Value -> Aeson.Value` as an explicit
**allow-list**, never a denylist, and say why in the Haddock: a denylist over a JSON body from
seven different OpenAI-compatible hosts will miss a field the first time a host adds one, and the
failure mode is leaking prompt content into a digest that callers were told was content-free.
The projection keeps the top-level scalar and object parameters that describe configuration —
`model`, `max_tokens`, `max_completion_tokens`, `temperature`, `top_p`, `stop_sequences`, `seed`,
`frequency_penalty`, `presence_penalty`, `reasoning_effort`, `reasoning`, `thinking`,
`enable_thinking`, `output_config`, `cache_control`, `response_format`, `tool_choice`, `stream` —
and replaces the content-bearing fields with structural summaries. For `messages`, keep an array
of objects carrying each message's `role` and the number of content blocks and the total
character length of its text, and nothing else. For `system`, keep only its character length. For
`tools`, keep each tool's `name` only, and not its description or schema.

Now the golden tests, in `baikai/test/EvidenceSpec.hs`. Three of them matter most.

The **map-ordering test** builds the same logical JSON object twice, inserting keys in two
different orders, and asserts the two `canonicalEncode` results are byte-identical and the two
digests are equal. Because aeson's `KeyMap` may or may not preserve insertion order depending on
size and build flags, construct the two values by folding inserts over two shuffled key lists so
the test is meaningful regardless.

The **golden digest test** reads a fixed request envelope from
`baikai/test/fixtures/evidence-request.json`, computes both digests, and compares them against
two literal strings recorded in the test. This is what catches an accidental change to the
canonicalisation rule: if someone later changes number formatting or key ordering, this test
fails loudly rather than silently invalidating every previously recorded digest. When you first
write the test, run it once, read the actual digests out of the failure output, and paste them
in — then confirm a second run passes.

The **redaction test** takes a request envelope fixture that deliberately contains an API key in
a header-shaped field, a long prompt string, a block of reasoning text, and a tool-call argument
payload, computes the `configurationProjection`, encodes it, and asserts that the resulting
`ByteString` contains none of those four literal substrings. Assert on the encoded bytes, not on
the structure, because the point is that nothing survives into the output no matter how it got
there.

Also test the `Observed` JSON round-trip in both directions, and assert that `Unobserved` encodes
to the string `"unobserved"` — a downstream consumer will pattern-match on that literal.

Run them:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai --test-options='--pattern Evidence'
```

Expect output resembling:

```text
evidence
  canonical encoding
    is stable across map insertion order:        OK
    normalises integral and fractional numbers:  OK
  digests
    request commitment matches the golden value: OK
    configuration digest matches the golden:     OK
    configuration projection drops all content:  OK
  observed
    encodes Unobserved as "unobserved":          OK
    round-trips through JSON:                    OK

All 7 tests passed
```

### Milestone 4: wiring the vocabulary into the existing surface

At the end of this milestone a caller can attach a run identifier to a call, and Baikai's
per-call identifiers are genuinely unique. Nothing consumes the run identifier yet — that is
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) — but the
field exists and round-trips.

Add one field to the `Options` record in `baikai/src/Baikai/Options.hs`:

```haskell
    evidence :: !(Maybe EvidenceRequest),
```

Place it after `responseFormat` to keep the record's grouping sensible, add `evidence` to the
module's export list beside the other field selectors, set it to `Nothing` in `emptyOptions`, and
extend the module's header documentation the way the existing text does for `toolChoice`,
`cacheRetention`, and `thinking` — one sentence saying what it is and that a call with `Nothing`
behaves exactly as it does today.

`Options` derives `ToJSON` anyclass. `EvidenceRequest` and everything it contains therefore needs
`ToJSON` too, which Milestone 1 already provides. Confirm this compiles rather than assuming it;
`EvidenceStrictness` carries an `EvidenceStrength` payload and a generically derived instance for
a sum type needs the encoding to be decided, so give `EvidenceStrictness` a hand-written instance
encoding `EvidenceBestEffort` as `{"mode":"best_effort"}` and `EvidenceRequired s` as
`{"mode":"required","strength":<s>}`.

Now the identifier generator. Add to `Baikai.Evidence`:

```haskell
-- | A globally unique call identifier: 32 lowercase hexadecimal
-- characters carrying 128 bits, composed of the current Unix time in
-- milliseconds, a per-process random seed drawn once at startup, and a
-- process-local counter. The time prefix makes identifiers sort
-- chronologically; the seed is what distinguishes two processes; the
-- counter is what distinguishes two calls within one.
--
-- This replaces the previous generator, which combined the process
-- start /second/ with a process-local counter and therefore produced
-- identical identifier sequences in two processes started in the same
-- second.
--
-- Generating an identifier costs one atomic counter increment and one
-- clock read. It performs no syscall for randomness, because this
-- function is on the trace path for every call whether or not the
-- caller wants evidence, and a per-call read from the system random
-- source would put a cost on people who never asked for one.
newCallId :: IO Text
```

The seed is the part that needs care. Draw 64 bits once, at first use, from `/dev/urandom` via
`Data.ByteString.readFile`, held in a top-level `IORef` created with the same
`unsafePerformIO`-plus-`NOINLINE` idiom that `baikai/src/Baikai/Provider/Registry.hs` already uses
for its global registry and that `Baikai.Trace` already uses for `eventBase`. Reading eight bytes
from `/dev/urandom` is portable across the platforms this library targets — the repository's
`flake.nix` and CI matrix cover Linux and macOS — and needs no new dependency. If the read fails,
fall back to a seed derived from the process start time in nanoseconds and the process id rather
than throwing, and document that the fallback is weaker but still process-distinguishing.

Do not reach for a per-call random draw even though it is the more obvious construction. It would
be marginally stronger and measurably more expensive on a path every traced call takes; a
128-bit space with a process seed and a counter has no realistic collision risk for correlating
calls, which is all these identifiers are for. They are not secrets, not capabilities, and not
unguessable by design — say so in the Haddock so nobody later mistakes one for a token.

Then in `baikai/src/Baikai/Trace.hs`, replace the body of `newEventId` so it delegates to
`newCallId`, keep the name exported for source compatibility, and mark it deprecated:

```haskell
{-# DEPRECATED newEventId "Use Baikai.Evidence.newCallId; newEventId's ids were only unique within one process." #-}
```

Delete `eventCounter` and `eventBase` if nothing else uses them — grep first — and remove the now
unused imports that `-Wall` will flag.

Finally, add `module Baikai.Evidence,` to the export list in `baikai/src/Baikai.hs` and the
matching `import Baikai.Evidence` below, both in the alphabetical position the existing lists use.

Add a `CHANGELOG.md` entry under the existing `[Unreleased]` heading's `### Added` subsection,
following the style of the entries already there: name the package, name the module, say what it
is in a sentence, and say explicitly that no existing behavior changed.

Verify the whole thing:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build all && cabal test baikai
```


## Concrete Steps

Work from the repository root at `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm the starting state is clean and the tests pass before touching anything, so that any
later failure is unambiguously yours:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai
```

Read the three files whose conventions this plan follows most closely, in this order:
`baikai/src/Baikai/ThinkingLevel.hs` (small, shows the module and Haddock style),
`baikai/src/Baikai/Options.hs` (shows the selective-export and smart-constructor pattern), and
`baikai/src/Baikai/Usage.hs` (shows how a record with a hand-written aeson instance is
documented).

Then work through the four milestones above. Commit after each one. Every commit needs both
trailers, and the intention trailer:

```text
Add the Observed and thinking-translation evidence vocabulary

Introduce Baikai.Evidence with the Observed type, the thinking
translation record, and the endpoint and strength enumerations. No
provider constructs these yet.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

After the final milestone, confirm nothing downstream broke. This plan is additive and should not
touch the other seven packages at all, so a failure here means something was changed that should
not have been:

```bash
cabal build all
cabal test all
```

`cabal test all` includes `baikai-smoke`, which exercises live providers when credentials or CLI
binaries are present and skips them otherwise; a skip is not a failure.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

Building the whole repository succeeds with no new warnings: `cabal build all` produces no
output mentioning `Baikai/Evidence.hs`.

The evidence test group passes: `cabal test baikai --test-options='--pattern Evidence'` reports
every case in the group as OK, including the three golden tests described in Milestone 3.

Canonicality is real, not asserted. Prove it interactively:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal repl baikai
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import Baikai.Evidence
ghci> import Data.Aeson
ghci> let a = object ["b" .= (1::Int), "a" .= (2::Int)]
ghci> let b = object ["a" .= (2::Int), "b" .= (1::Int)]
ghci> commitmentDigest a == commitmentDigest b
True
ghci> commitmentDigest a
"sha256:..."
```

The two digests must be equal and the rendered value must start with `sha256:` followed by
exactly 64 hexadecimal characters.

Redaction is real. In the same session, confirm that a configuration digest ignores content:

```haskell
ghci> let q1 = object ["model" .= ("m"::String), "messages" .= [object ["role" .= ("user"::String), "content" .= ("hello"::String)]]]
ghci> let q2 = object ["model" .= ("m"::String), "messages" .= [object ["role" .= ("user"::String), "content" .= ("world"::String)]]]
ghci> configurationDigest q1 == configurationDigest q2
True
ghci> commitmentDigest q1 == commitmentDigest q2
False
```

Both results matter. Equal configuration digests prove the projection removed the content; unequal
commitment digests prove the commitment did not.

Identifier uniqueness is real. Two identifiers generated in the same millisecond must differ:

```haskell
ghci> ids <- mapM (const newCallId) [1..1000::Int]
ghci> length ids == length (Data.List.nub ids)
True
```

A caller can set a run identifier and read it back:

```haskell
ghci> import Baikai
ghci> let o = emptyOptions & #evidence .~ Just (evidenceRequest "run-42")
ghci> fmap (^. #runId) (o ^. #evidence)
Just "run-42"
```

Nothing else changed. `cabal test all` passes exactly the cases it passed before this plan, plus
the new evidence group. In particular `baikai/test/TraceSpec.hs` must still pass unchanged; if it
asserts anything about the *format* of an event identifier, that assertion needs updating and the
change must be recorded in this plan's Decision Log with the reason.


## Idempotence and Recovery

Every step here is additive and safe to repeat. Re-running `cabal build` or `cabal test` has no
side effects. The only file whose existing content is modified rather than extended is
`baikai/src/Baikai/Trace.hs`, where `newEventId`'s body is replaced; if that change causes a
problem, restore it with `git checkout -- baikai/src/Baikai/Trace.hs` and the package returns to
its previous behavior, because nothing else in this plan depends on the new generator.

The golden digest values are the one thing that cannot be recovered by re-running a command: if
you change the canonicalisation rule after recording them, every previously written evidence
record's digest becomes unverifiable. Treat a change to `canonicalEncode` after this plan lands
as a schema-version bump, not a bug fix, and say so in the function's Haddock.


## Interfaces and Dependencies

New dependencies for the `baikai` library: `cryptohash-sha256 ^>=0.11` for SHA-256 (a
single-purpose package, chosen over `crypton` to avoid pulling a cryptographic framework into a
widely depended-on library) and `base16-bytestring ^>=1.0` for hexadecimal rendering. Both are
present in the local package store at 0.11.102.1 and 1.0.2.0 respectively. Confirm the current
released versions against Hackage before pinning the bounds, since the local store may lag
upstream.

Existing modules this plan depends on: `Baikai.ThinkingLevel` for `ThinkingLevel`, `Baikai.Usage`
for `Usage`, `Baikai.Error` for `BaikaiError`, and `Baikai.Prelude` for the shared vocabulary.
`Baikai.Evidence` must not import `Baikai.Options`, `Baikai.Response`, `Baikai.Trace`, or
`Baikai.Provider.Registry` — the dependency runs the other way, and a cycle here would force an
`hs-boot` file.

The module surface that must exist when this plan is complete, in
`baikai/src/Baikai/Evidence.hs`:

```haskell
module Baikai.Evidence
  ( -- * Schema identity
    evidenceSchemaVersion,

    -- * The evidence record
    ModelCallEvidence (..),
    baseEvidence,

    -- * Observation
    Observed (..),
    observedValue,

    -- * Reasoning-effort translation
    ThinkingTranslation (..),
    ThinkingMode (..),
    ThinkingAdjustment (..),
    noThinkingRequested,

    -- * Endpoint and transport
    EndpointIdentity (..),
    TransportKind (..),

    -- * Outcome and strength
    CallStatus (..),
    EvidenceStrength (..),

    -- * The caller's request
    EvidenceRequest (..),
    EvidenceStrictness (..),
    evidenceRequest,

    -- * Canonical encoding and digests
    canonicalEncode,
    commitmentDigest,
    configurationDigest,
    configurationProjection,

    -- * Identifiers
    newCallId,
  )
where
```

In `baikai/src/Baikai/Options.hs`, `Options` gains `evidence :: !(Maybe EvidenceRequest)` and the
module exports the `evidence` selector.

In `baikai/src/Baikai/Trace.hs`, `newEventId :: IO Text` keeps its signature, delegates to
`newCallId`, and is deprecated.

In `baikai/src/Baikai.hs`, `Baikai.Evidence` is re-exported.
