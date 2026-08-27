---
id: 67
slug: freeze-the-public-surface
title: "Freeze the public surface"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Freeze the public surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This is EP-10 of the master plan at
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`, the
only plan in its third wave. It is the freeze boundary: it makes the baikai library's
public surface safe to hold stable across minor releases, removes the compatibility
shims that were promised gone two major versions ago, and settles every naming and
typing question the review at `docs/reviews/correctness-and-api-review-follow-up.md`
(REV-2) left open. It continues the work of
`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`, which established the
constructor-export policy and the `.Internal` convention in July; several decisions
below revisit that plan's Decision Log and say why. The review items it implements are
Theme G items G.1 through G.8, B.6 (the `Aborted` stop reason), the REV-1 residuals R5,
R8, R10, R12 and R14 recorded under "API design recommendations", the `ErrorCategory`
question EP-5 leaves open, and the Theme I test gaps only as far as they concern
`Aborted`.

After this change a downstream user gets six things they did not have before. First,
every record that can grow a field — including `ApiProvider`, whose fourth field broke
every third-party provider in 0.5.0.0 — is built from an exported base value, so the
next field addition is a minor release. Second, the sixteen `_X` aliases, the eight
`registerWith*` names and `newEventId` are gone, and an ADR says exactly when any
future deprecated name dies. Third, the providers' streaming internals live under
`.Internal` module names, so changing them is no longer a documented break. Fourth, a
handler registered under `Custom "anthropic-messages"` is found by a model tagged
`AnthropicMessages`, a blank `emptyModel` dispatch says so in words, a content filter is
its own error category, and `Aborted` no longer describes a failure nothing produces.
Fifth, `headers` cannot hold two spellings of one name, `stopSequences` and `seed` use
the types the rest of `Options` uses, `ResponseFormat` has no partial selectors, and
`appendToolResult` never replays an empty assistant turn. Sixth, every published package
ships its changelog and tested GHC to Hackage.

This plan is deliberately a breaking release boundary. It ships baikai, baikai-claude
and baikai-openai at 0.6.0.0, baikai-trace-otel at 0.4.0.0, baikai-kit and baikai-agent
at 0.2.0.0, and baikai-effectful at whatever PVP requires once its own exports are
known (see the Decision Log). You can see it working by building and testing everything
under the keyless gate quoted in Concrete Steps, building the haddocks
(`cabal haddock baikai`), and observing in a `cabal repl baikai-test` transcript that
`ApiProvider { … }` fails with "Not in scope: data constructor" while
`apiProvider (Custom "x") myStream` evaluates.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining").

Milestone 1 — constructor policy applied to every evolvable record; assembler seams
behind `.Internal`:

- [x] Read the Decision Logs and Interfaces sections of `docs/plans/58-…` through `66-…` (EP-1..EP-9) and record here every field, name or module they added that changes an export list below.
- [x] Add `apiProviderWith` (`Registry.hs`) and `apiProvider` (`Provider.hs`); export `ApiProvider` selector-only from both; sweep every in-repo construction site (list in Plan of Work).
- [x] Export `ModelCallEvidence` and `EvidenceRequest` selector-only; switch `Trace/Sink.hs` and the OTel sink to `OverloadedRecordDot` reads.
- [x] Export `Tool` (with `mkTool`), `EmbeddingModel`, `CallLogConfig` (`callLogConfig`), `OtelSinkOptions`, `AgentCliOptions` (`agentCliOptions`), `AgentCliRun` (`agentCliRun`), `AgentJob` (`agentJob`), `AgentConfigPaths` (`emptyAgentConfigPaths`) selector-only.
- [x] `git mv` each provider's `Api.hs` to `Internal/Stream.hs`, recreate `Api.hs` as a façade, rename `_TagScanState`, update both `.cabal` files and every test import; add the no-guarantees header to `Shape.hs`, `Sse.hs`, `Transport.hs` in both providers.
- [x] Extend `baikai/test/SurfaceSpec.hs` to build every newly hidden record from its base; build and keyless gate green.

Milestone 2 — deprecated shims removed; versions bumped; changelog states removals:

- [x] Delete the sixteen `_X` aliases, the eight `registerWith*` functions and `newEventId`; rewrite the `TraceSpec` case that exercises `newEventId` (quoted in Plan of Work).
- [x] Mechanical edits at every in-repo site that names a removed identifier (README.md, two user guides, CAP-9, CAP-13); prose rewrites stay with EP-11.
- [x] Create `docs/adr/0006-deprecated-names-are-removed-at-the-next-major.md` and add it to `docs/adr/README.md`.
- [x] Bump versions and internal bounds in all seven publishable `.cabal` files; open the 0.6.0.0 / 0.4.0.0 / 0.2.0.0 sections in `CHANGELOG.md` with every removal named.
- [x] `cabal build all --enable-tests` and the keyless `cabal test all` green.

Milestone 3 — `Api` key normalisation, `Aborted` decision, naming and type consistency
decisions recorded and applied:

- [x] Add `normaliseApi` to `baikai/src/Baikai/Api.hs`, apply it in `registerApiProviderWith` and `lookupApiProviderWith`, and make the blank-tag dispatch message name `emptyModel`; tests in `baikai/test/HelpersSpec.hs`.
- [x] Check EP-4's Decision Log for a producer of `Aborted`; apply the retire branch (default) or the first-class-failure branch, as recorded in this plan's Decision Log.
- [x] Add `ContentFiltered` to `ErrorCategory` with `contentFiltered`, route OpenAI `content_filter` and Anthropic `refusal` through it, update CAP-8's category count.
- [x] Apply the G.5 decisions: `seed :: Maybe Int`, `stopSequences :: [Text]`, `headers :: Map HeaderName Text` via the new `baikai/src/Baikai/Header.hs`, `AgentConfigScope` constructors renamed; document every "keep" on the field it concerns.
- [x] `cabal build all --enable-tests` and the keyless `cabal test all` green.

Milestone 4 — accessors, parsers and deriving gaps closed; release metadata complete:

- [ ] Export the `AgentRunResult` selectors; derive `Generic` (and `Eq`/`Show` where the fields allow) on `OtelSinkOptions` and `Eq`/`Generic` on `EmbeddingModel`.
- [ ] Export `parseThinkingLevel` and `parseEvidenceStrength`; delete the copies in `Evidence.hs`, `Agent/Config.hs` and `Agent/Cli.hs`.
- [ ] Replace `ResponseFormat`'s partial fields with `JsonSchema !JsonSchemaFormat`, drop `-Wno-partial-fields`, pin the unchanged JSON shape.
- [ ] Guard `appendToolResult` against error-shaped responses and correct its Haddock.
- [ ] Release metadata: `tested-with`, changelog symlinks, corrected descriptions, aligned `streamly-core` bounds, `streamly` dropped from baikai-effectful, retroactive 0.5.0.0 changelog entries.
- [ ] Add the `PublicSurface*` compile modules; `cabal check` per package; `cabal haddock baikai`; capability log entry; update the master plan's EP-10 boxes and registry row.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- At drafting time (2026-08-27, HEAD `5411947`) every sibling plan `docs/plans/58-…`
  through `66-…` and `68-…` is a 104-line generated skeleton, so the reconciliation
  against their Decision Logs is the first task of Milestone 1.
- `kanmon/kanmon-core/src/Kanmon/Enrich/Stub.hs:61-66` constructs `ApiProvider` with
  three fields and no `describeThinking`, so it already fails to compile against baikai
  0.5.0.0 — the concrete instance of G.1 and the reason `apiProvider` exists.
- `rei-core/src/Rei/Modules/Agent/Infrastructure/BaikaiBatchBackend.hs:104-117`
  matches every `ErrorCategory` constructor with no wildcard, so `ContentFiltered` is a
  compile error for rei rather than a silent runtime gap.

- Milestone 1: `ApiProvider` had no `Generic` instance, so
  `apiProvider … & #describeThinking .~ …` did not compile. The record now
  derives `Generic` (stock), which is what makes the label-based record update
  the CLI providers and the sibling plans assume work at all. Plain record
  update also works and needs no instance; the deriving is added so the
  documented path in the Haddock is the one that compiles.

- Milestone 1: the sibling plans landed six changes this plan's field lists had
  to absorb before any export list was edited. `ApiProvider` has five fields,
  not four (EP-8's `strengthCeiling`). `OtelSinkOptions` has three (EP-9's
  `parentContext`). `AgentConfigPaths` has three, and the third,
  EP-6's `repositoryRoot :: FilePath`, is not a `Maybe` — so
  `emptyAgentConfigPaths` sets it to `"."` rather than leaving "both `Nothing`"
  as this plan's Decision Log said when the record had two fields. `AgentJob`
  gained EP-6's `outputFormat` and its `envPassthrough` → `envRequires` rename,
  both folded into `agentJob`. `Baikai.Compat.defaultAnthropicThinkingStyle` is
  a twenty-sixth deprecated name, added by EP-3 and removed by Milestone 2.
  Neither `anthropicStrength` nor `openaiStrength` exists any more (EP-8
  replaced both with `deriveStrength`), so neither appears in the
  `.Internal.Stream` export lists this plan's Plan of Work named.

- Milestone 1: `git grep "ApiProvider$\|ApiProvider {" -- '*.hs'` is empty, not
  "hits only `Registry.hs`" as the acceptance criterion predicted: `Registry.hs`
  builds the record inside `apiProviderWith`, whose layout puts the constructor
  on the line after `ApiProvider` with a trailing `\n` rather than a brace, so
  neither pattern matches it. The stronger reading holds — nothing outside the
  defining module names the constructor.

- Milestone 2: on the first fully parallel run after the version bump forced a
  whole-workspace rebuild, one subprocess-spawning case — "a zero exit with no
  identifier and no model stays at requested_only", which exists in
  `baikai-claude/test/CliEvidenceSpec.hs`, `baikai-openai/test/CliEvidenceSpec.hs`
  and `baikai-agent/test/EvidenceTests.hs` — failed after 5.01 s and passed on
  every run since, alone and in the full gate. It is deadline-sensitive under
  load, like the cases EP-1's revision note widened from one second to three and
  five; nothing this plan changed touches it. Recorded rather than fixed: the
  deadline belongs to the plan that wrote it.

- Milestone 3: the acceptance grep `git grep -n "CI.mk" -- 'baikai-*/src'` cannot
  be empty and was not: `applyHeaderOverrides` still calls `CI.mk` in both
  `Transport.hs` files, because `http-types`' `RequestHeaders` is
  @[(CI ByteString, ByteString)]@ and a baikai `HeaderName` has to be encoded
  into it. (Both `Sse.hs` modules also call it to read a response header, which
  predates this plan.) What the criterion was after does hold: no code compares
  or folds header names case-insensitively any more — the key type does it —
  and the remaining calls are type conversions at the http-types boundary.


## Decision Log

- Note (recorded by EP-9, 2026-08-27): `baikai-trace-otel`'s `OtelSinkOptions` gains a
  third field, `parentContext :: !(Maybe OpenTelemetry.Context.Context)`, default
  `Nothing`. The constructor is exported, so the addition breaks positional
  construction; EP-9 documented the record-update-on-`defaultOtelSinkOptions` path
  rather than adding a base value, on the same reasoning EP-8 used for
  `ApiProvider.strengthCeiling` — a base value added by a code plan and renamed at the
  freeze would break third parties twice. The base value this plan defines for every
  evolvable record must cover all three fields. EP-9 also adds three internal names
  that stay unexported by design and must not be frozen:
  `Baikai.Trace.TraceSinkStalled`, `Baikai.Trace.Sink.TraceSinkFailure` and
  `Baikai.Trace.Sink.Member`; both exception types render as text through
  `displayException` on every path a caller sees, so exporting either would freeze a
  name for no reader. `Baikai.Cost.Log.CallLogHandle` gains a `closed :: IORef Bool`
  field; the type is exported opaquely and stays that way.
- Question (recorded by EP-5, 2026-08-27): should `ErrorCategory` gain a `ContentFiltered`
  constructor? EP-5 left `finish_reason = "content_filter"` as `OtherError` and did not
  widen the closed sum, because widening it is a surface decision that belongs with the
  other freeze-time type changes and the major bump that carries them — which the
  MasterPlan's Integration Points confirms is EP-10's. Until then the message
  `provider stopped the response: finish_reason=content_filter` is the only signal
  distinguishing a filter from any other non-retryable failure, and a consumer wanting to
  branch on it must match on message text.
  Names EP-5 adds that this plan must cover: `Baikai.Provider.Transport.Classify` (a plain
  exposed module with five exports; EP-5's recommendation is to keep it public, because its
  Haddock offers it to third-party `Custom` providers built on `http-client`),
  `Baikai.Error.parseHttpDate`, `Baikai.Error.retryAfterSecondsAt`,
  `Baikai.Provider.OpenAI.Internal.ErrorClass.classifyErrorFrame`, and
  `Baikai.Provider.OpenAI.Api.parseFrame`. Names EP-5 removes, so this plan need not:
  `responseToError` and `classifyErrorText` from both `.Internal.ErrorClass` modules.
  Date: 2026-08-27

Record every decision made while working on the plan.

- Decision: Sibling plans EP-1..EP-9 are inputs, not assumptions. Before any export
  list is edited, read `sed -n '/## Decision Log/,/## Outcomes/p'` and the Interfaces
  section of each of `docs/plans/58-…` through `66-…` and append one entry here per
  field, name or module they added. Names this plan relocates or hides are held to the
  policy it establishes regardless of which plan added them.
  Rationale: the master plan makes EP-10 soft-depend on every code plan for exactly this
  reason, and at drafting time all nine are skeletons (see Surprises & Discoveries).
  Date: 2026-08-27
- Decision: Constructor-export policy per record. Selector-only with a base value:
  `ApiProvider` (`apiProvider`), `ModelCallEvidence` (`baseEvidence`), `EvidenceRequest`
  (`evidenceRequest`), `Tool` (`mkTool`, with `emptyTool` kept for fixtures),
  `EmbeddingModel` (`emptyEmbeddingModel`), `OtelSinkOptions` (`defaultOtelSinkOptions`),
  `CallLogConfig` (`callLogConfig`), `AgentCliOptions` (`agentCliOptions`), `AgentCliRun`
  (`agentCliRun`), `AgentJob` (`agentJob`), `AgentConfigPaths` (`emptyAgentConfigPaths`);
  signatures in Interfaces and Dependencies. Kept exported by decision: `Response`,
  `Usage`, `Cost`, `CostBreakdown`, `ModelCost`, `BaikaiError`, the four content
  records, `InteractiveLaunchResult`, every `Baikai.Stream.Event` payload, `TraceEvent`,
  `CallLogEntry`, `AgentCommand`, `AgentJobEntry`, `CodexCustomAgent`, every sum type,
  and (EP-7's) the `baikai-kit` records.
  Rationale: the first group is caller-constructed configuration that has grown or will
  grow (`ApiProvider` and `RawChunk` each already forced a documented break); the second
  is provider-produced and consumer-matched (shiki matches `InteractiveLaunchResult
  { exitCode }`, shikigami `CallSucceeded`, fixtures build `Response`) or a closed
  payload whose fields are the contract. `mkTool` exists because `emptyTool.parameters
  = Null` reaches the wire as `input_schema: null` (REV-2 Theme 9 residual). Note that
  selector-only export does not make a field unsettable — generic-lens labels reach any
  `Generic` field — so `ModelCallEvidence.strength` is guarded by EP-8's single
  derivation, not by this export list (REV-2 D.10 conflates the two).
  Date: 2026-08-27
- Decision: `Baikai.Provider.Registry` exports `apiProviderWith` (tag, stream and
  complete all explicit) and `baikai/src/Baikai/Provider.hs` exports `apiProvider`,
  which supplies `complete = streamingComplete stream`. Both default `describeThinking`
  to `\_ _ -> noThinkingRequested`; if EP-8 added a strength ceiling, its default is
  `EvidenceRequestedOnly`, matching `declaredStrength (Custom _)`.
  Rationale: `Baikai.Stream` imports the registry for dispatch, so `Registry.hs` cannot
  import `streamingComplete` without a cycle; `Baikai.Provider` is the façade every
  guide imports and the umbrella re-exports it.
  Date: 2026-08-27
- Decision: The `.Internal` relocation moves the whole of each provider's `Api.hs` to
  `Baikai.Provider.Claude.Internal.Stream` / `Baikai.Provider.OpenAI.Internal.Stream`
  by `git mv`, then recreates `Api.hs` as a façade exporting only `register`, the
  provider value and the live stream function; the seams (listed in Milestone 1) are
  exported from the `.Internal` module only, and `_TagScanState` becomes
  `emptyTagScanState`. `Shape`, `Sse` and `Transport` keep their names and gain the
  no-guarantees header.
  Rationale: a rename plus a small new file is what EP-4, EP-5 and EP-8 — which all edit
  these files first — can rebase under. `claudeMessagesStreamWith` moves because its
  type mentions `SseDriver`; no consumer imports it. `Shape`/`Sse`/`Transport` stay
  because CAP-13 and CAP-14 list them as interface; a header is enough, as plan 43
  decided for `Baikai.Prelude`.
  Date: 2026-08-27
- Decision: Deprecation schedule. This major removes the sixteen `_X` aliases, the
  eight `registerWith*` functions and `Baikai.Trace.newEventId` (all enumerated in
  Milestone 2). The policy — a deprecated name is removed at the next major release
  after the one that deprecates it, and the changelog names that version — becomes
  `docs/adr/0006-deprecated-names-are-removed-at-the-next-major.md`, and every future
  `DEPRECATED` pragma ends with "Removed in <package> <version>."
  Rationale: plan 43 said "remove them in the next major"; 0.4.0.0 and 0.5.0.0 both
  shipped without doing so because nothing recorded the version.
  Date: 2026-08-27
- Decision: `Api` key normalisation is `normaliseApi :: Api -> Api` (`parseApi .
  renderApi`), applied by `registerApiProviderWith` to the stored key and by
  `lookupApiProviderWith` to the query; derived `Eq`/`Ord` are unchanged. The "No
  provider registered for API:" messages render `Custom ""` as `<blank Custom tag —
  emptyModel.api was never set>`.
  Rationale: `Custom` must stay public (ten consumer sites build or match it), so
  `Custom ""` cannot be made unrepresentable; normalising at the registry boundaries
  makes registration and dispatch agree with the JSON path, and changing `Eq` would
  silently alter every `Map Api` a consumer holds.
  Date: 2026-08-27
- Decision: `Aborted` is retired — removed from `StopReason` — unless EP-4's Decision
  Log records a producer (check: `grep -n "Aborted" docs/plans/61-*.md`, read in
  context). A recorded producer selects the alternative branch in Milestone 3, in which
  `responseError` treats `Aborted` like `ErrorReason`, `finalizeState` normalises
  `(Aborted, Nothing)`, and `eventsFor` lifts it as `EventError`.
  Rationale: nothing produces it, timeouts are `ErrorReason`/`TransientError`, consumer
  abort is recorded only as evidence `CallAborted`, and `responseError`, `eventsFor` and
  `runToolLoop` all treat it as success (REV-2 B.6). EP-4 cancels the worker when the
  consumer stops, so no consumer is left to receive such a terminal.
  Date: 2026-08-27
- Decision: `ErrorCategory` gains `ContentFiltered` (wire tag `content_filtered`,
  `isRetryable = False`) with `contentFiltered :: Text -> BaikaiError`; OpenAI's
  `content_filter` finish reason and Anthropic's `refusal` stop produce it. If EP-5
  already added an equivalent, its name wins and this entry is amended.
  Rationale: REV-1 1.7's residual (a filter is indistinguishable from any other failure
  without text matching), and this is the last major before the freeze. The content, not
  the transport, is the problem, so it is not retryable.
  Date: 2026-08-27
- Decision: `Options.headers` and `Model.headers` become `Map HeaderName Text`, where
  `HeaderName` is a newtype over `Data.CaseInsensitive.CI Text` in the new module
  `baikai/src/Baikai/Header.hs` with `IsString`, case-insensitive `Eq`/`Ord`, `Show`,
  `ToJSON`/`FromJSON`, `ToJSONKey`/`FromJSONKey` (original spelling preserved),
  `headerName :: Text -> HeaderName` and `renderHeaderName :: HeaderName -> Text`.
  `case-insensitive ^>=1.2` joins baikai's `build-depends`.
  Rationale: the provider fold is already case-insensitive, so two keys differing only
  by case pick a winner by `Map` order (G.5); the key type should carry the rule. A
  baikai-owned newtype avoids orphan aeson instances for `CI Text`, and `IsString` keeps
  `Map.singleton "x-test" "1"` compiling (SurfaceSpec and shikumi-cache write exactly
  that). Both providers already depend on `case-insensitive`. EP-2 owns the redacting
  `Show`/`ToJSON` instances of `Options` and `Model`: if it hand-wrote them, render keys
  with `renderHeaderName`; if not, the derived instances work through `ToJSONKey`.
  Date: 2026-08-27
- Decision: `Options.stopSequences` becomes `![Text]` (empty means "send nothing") and
  `Options.seed` becomes `!(Maybe Int)`.
  Rationale: plan 43's rule is lists for caller-side configuration, `Vector` for
  provider-bound sequences, and `stopSequences` is the one field breaking it (R14
  residual); `Nothing` and `Just []` were indistinguishable on the wire. A seed is a
  machine integer at every provider that accepts one, beside `timeoutMs :: Maybe Int`.
  Date: 2026-08-27
- Decision: Keep `ApiKeyEnv !String`, `executable :: FilePath`,
  `AgentCommand.arguments :: [String]`, `Response.model :: Model` beside
  `TraceEvent.model :: Text`, `CacheRetentionNone` beside `cacheRetention :: Maybe
  CacheRetention`, `ToolChoiceAuto` beside `toolChoice :: Maybe ToolChoice`, and the
  duplicate `CallFailed` / `runId` / `attempt` / `supersedes` names. Rename only
  `AgentConfigScope`'s constructors to `AgentUserScope` / `AgentRepositoryScope`.
  Rationale: `System.Environment.lookupEnv` and `System.Process` take `String` and
  `FilePath`. `Response` echoes the full input `Model`; `TraceEvent`'s `model` is a JSONL
  key consumed by `jq` and the OTel sink, and renaming the field while keeping the key
  would make the code lie. `Nothing` and `CacheRetentionNone` / `ToolChoiceAuto` are
  equivalent on the wire and now say so in their Haddock; deleting the constructors
  breaks shikumi (`shikumi-tools/src/Shikumi/Agent/ReAct.hs:419`) for no behaviour
  change. `CallFailed` in `Baikai.Evidence` is JSON vocabulary and `Baikai.Trace.Event`
  is outside the umbrella, so a qualified import resolves it; the evidence record carries
  the request's `runId`/`attempt`/`supersedes` verbatim by design (ADR 0005), read by the
  sinks with `OverloadedRecordDot`. `AgentConfigScope` is the one clash between two
  baikai-family packages (`baikai-kit`'s `KitScope`) and `baikai-agent` takes a major
  anyway.
  Date: 2026-08-27
- Decision: `ResponseFormat` becomes `JsonSchema !JsonSchemaFormat | JsonObject`, with
  `JsonSchemaFormat (name, schema, strict)` exported selector-only and a base
  `jsonSchemaFormat :: Text -> Value -> JsonSchemaFormat` (`strict = False`). The
  `ToJSON`/`FromJSON` instances are hand-written to keep the current flat encoding
  (`{"tag":"JsonSchema","name":…,"schema":…,"strict":…}`), pinned by a test.
  `-Wno-partial-fields` is dropped from the module. Pattern synonyms were rejected.
  Rationale: the partial selectors crash on `JsonObject`, contradicting
  `Stream/Event.hs:62-66` (G.2); a record pattern synonym would regenerate them. The
  JSON shape is kept because `Options` derives `ToJSON` and shikumi-cache keys on it.
  Date: 2026-08-27
- Decision: `appendToolResult` returns the context unchanged, running no dispatcher,
  when `responseError resp` is `Just`; its Haddock stops claiming multi-call concurrency
  lives in the dispatcher (the calls are sequential via `traverse`).
  Rationale: G.7 — `runToolLoop` already guards this, and the documented direct round
  trip in `docs/user/tools.md` does not, so a replayed context could contain an empty
  assistant turn.
  Date: 2026-08-27
- Decision: `parseThinkingLevel :: Text -> Maybe ThinkingLevel` is exported from
  `Baikai.ThinkingLevel` and `parseEvidenceStrength :: Text -> Maybe EvidenceStrength`
  from `Baikai.Evidence`; the copies at `Evidence.hs` (`parseThinkingLevelText`),
  `Agent/Config.hs` (`effortDecoder`'s six-pair list) and `Agent/Cli.hs` (the
  `--require-evidence` parser's four-way case, which is the strength table, not the
  level table as REV-2 G.6 says) are rewritten in terms of them.
  Rationale: three hand-copied tables drift the first time a level or strength is
  added; one function beside its renderer cannot.
  Date: 2026-08-27
- Decision: `AgentRunResult` exports its selectors (`provider`, `exitCode`, `stdout`,
  `stderr`, `duration`); its constructor stays hidden and `agentRunResult` stays the
  base. `OtelSinkOptions` derives `Generic`, and `Eq`/`Show` if every field admits them
  after EP-9; `EmbeddingModel` derives `Eq`, `Show`, `Generic`.
  Rationale: G.6 — without selectors a consumer without generic-lens cannot read
  `exitCode`; without `Generic`, `#spanName` does not compile on `OtelSinkOptions`; kioku
  compares embedding models in tests.
  Date: 2026-08-27
- Decision: Version plan. baikai 0.5.0.0 → 0.6.0.0; baikai-claude and baikai-openai
  0.5.0.0 → 0.6.0.0; baikai-trace-otel 0.3.0.3 → 0.4.0.0 (hidden constructor, new
  deriving); baikai-kit 0.1.0.4 → 0.2.0.0 (EP-7's exit-free library signatures are
  major); baikai-agent 0.1.0.0 → 0.2.0.0; baikai-effectful 0.3.0.3 → 0.3.0.4 if EP-4 and
  EP-9 left `Baikai.Effectful`'s exports untouched, else 0.4.0.0; baikai-smoke stays
  0.1.0.0 (never released). Bounds cascade: every dependent's `baikai ^>=0.5.0` becomes
  `^>=0.6.0`; `baikai-agent`'s `baikai-claude ^>=0.5` and `baikai-openai ^>=0.5` become
  `^>=0.6`. Versions are bumped in Milestone 2; the release is cut after EP-11.
  Rationale: PVP requires a major for every removal or type change; a dependent whose
  only change is a bound still needs a patch (release skill, "Internal dependency
  bounds").
  Date: 2026-08-27
- Decision: This plan edits documentation only where a removed or renamed identifier is
  named (README.md, `docs/user/cli-providers.md`, `docs/user/models-and-providers.md`,
  `docs/user/streaming.md`, and the capability records CAP-8, CAP-9 and CAP-13) plus
  the Haddock of every function it changes; prose rewrites belong to EP-11.
  Rationale: the master plan's rule that every code plan updates the Haddock and
  capability record naming what it changes, and a guide that teaches a deleted name
  between EP-10 and EP-11 is a broken guide.
  Date: 2026-08-27
- Decision: The surface regression checks are `baikai/test/SurfaceSpec.hs`, extended
  to build every hidden record from its base, plus compile-only `PublicSurface*` test
  modules in baikai, both providers, baikai-trace-otel and baikai-agent that import only
  public, non-`.Internal` modules and no `Baikai.Prelude`.
  Rationale: plan 43 chose compile-time probes over golden `:browse` dumps; a module
  that sees only what a downstream sees is the closest in-repo proxy for the twelve
  registered consumers.
  Date: 2026-08-27

- Decision (Milestone 1): `ApiProvider` derives `Generic` (stock). Rationale:
  the constructor is hidden, and both this plan and the sibling plans write
  `apiProvider tag stream & #describeThinking .~ f`, which needs a generic-lens
  label and so needs the instance. It costs no export of the constructor, and
  the Decision Log already accepts that a `Generic` field is reachable by label
  (the note under the constructor-policy decision).
  Date: 2026-08-27
- Decision (Milestone 1): `emptyAgentConfigPaths` sets
  `repositoryRoot = "."`, not the current directory read at use. Rationale:
  EP-6 added the field as a plain `FilePath` and documented it as an explicit
  value rather than a `getCurrentDirectory` call, so a base value must supply
  one; `"."` is the relative spelling of the same root and keeps the base pure.
  `defaultAgentConfigPaths` remains the discovering, `IO` path.
  Date: 2026-08-27
- Decision (Milestone 3): `Aborted` is retired — the default branch. EP-4's
  Decision Log (`docs/plans/61-…`, the single `Aborted` hit) records that
  "nothing here produces an `Aborted` terminal, so EP-10's retirement of
  `Aborted` stands", and no test pinned it. No consumer of the alternative
  branch exists.
  Date: 2026-08-27
- Decision (Milestone 3): `describeApi` is exported from
  `Baikai.Provider.Registry` rather than left unexported as the Plan of Work
  says. Both call sites — `Registry.completeRequestWith` and
  `Stream.noProviderEvents` — are in different modules, so an unexported
  function cannot serve both, and duplicating a two-line renderer is exactly the
  drift this plan removes elsewhere. `Baikai.Provider.Registry` is deliberately
  not in the umbrella (`baikai/src/Baikai.hs` omits it), and
  `Baikai.Provider` does not re-export the name, so the umbrella surface is
  unchanged.
  Date: 2026-08-27
- Decision (Milestone 3): `nonEmptyStops :: [Text] -> Maybe (Vector Text)` is
  defined privately in each provider's `Internal/Request.hs` rather than once in
  core. Rationale: it is a wire adapter, not a rule — both SDKs happen to model
  an absent field as `Nothing` and each conversion is two lines beside the field
  it feeds. Core owns the representation decision (empty means "send nothing");
  the SDKs own their own encodings.
  Date: 2026-08-27

- Decision (Milestone 2): the ADR is
  `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md`, not `0006`.
  The corpus grew from five records to fifteen while EP-1..EP-9 landed, and the
  MasterPlan's Integration Points fix the slug, not the number: the number is
  taken at implementation time in landing order.
  Date: 2026-08-27
- Decision (Milestone 2): the removals are recorded in `CHANGELOG.md`'s existing
  `[Unreleased]` section, which names the seven versions this cycle ships as and
  marks each removal with the release that takes the name away, rather than in
  seven newly opened per-package version headings. Rationale: the whole cycle's
  entries — EP-1 through EP-10 — already sit in `[Unreleased]`, and the release
  skill's documented procedure (`agents/skills/release/SKILL.md`, "Release the
  package") is to move them into dated per-package sections at release time.
  Opening those sections now would either duplicate several hundred lines or
  leave seven empty headings above the 0.5.0.0 sections. What ADR 0016 actually
  requires — that the changelog name the version that removes each deprecated
  name — is satisfied. The release is after EP-11 and is not this plan's.
  Date: 2026-08-27
- Decision (Milestone 2): `Baikai.Compat.defaultAnthropicThinkingStyle` is
  removed here, making twenty-six removals rather than the twenty-five this plan
  enumerated. EP-3 deprecated it and its own Interfaces section asks EP-10 to
  remove it "at the next major with a changelog line naming the version", which
  is exactly this release. Deprecating and removing a name inside one cycle is
  not a violation of ADR 0016: the name was never released deprecated, so no
  consumer ever saw a warning promising it a major of overlap.
  Date: 2026-08-27
- Decision (Milestone 2): five unused imports left by EP-7, EP-8 and EP-9 were
  deleted in the same commit (`Baikai.Compat`'s `Data.Text`,
  `Evidence/Build.hs`'s `declaredStrength`, `Kit/Install.hs`'s
  `computeKitHash`, and both CLI modules' `ProviderRegistry` /
  `registerApiProviderWith`). They were invisible while their modules stayed
  cached and surfaced the moment the version bump forced a full rebuild; a plan
  that runs `cabal check` and `cabal haddock` as acceptance cannot leave a
  warning it has seen.
  Date: 2026-08-27

- Decision (Milestone 1): `Baikai.Provider.Claude.Api` and
  `Baikai.Provider.OpenAI.Api` keep their full module Haddock and each export
  exactly three names; the long per-function Haddock for the stream (worker
  bracketing, queue bound, cancellation strengths) moves with the public
  `<p>ChatStream` façade rather than staying with `<p>ChatStreamWith` in the
  `.Internal` module, because that is where a reader who is not reading
  internals will find it.
  Date: 2026-08-27

- Decision (added by `docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md`,
  2026-08-27): `Baikai.Provider.Registry.ApiProvider` now has five fields —
  `apiTag`, `stream`, `complete`, `describeThinking` and the new
  `strengthCeiling :: EvidenceStrength` — and needs the base value this plan
  defines for every evolvable record. EP-8 deliberately added none, because a
  base value added there and renamed here would break third parties twice.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/baikai`) is a multi-package Haskell
project built with cabal from the root `cabal.project`. The packages, in publish order:
`baikai/` (core), `baikai-claude/` and `baikai-openai/` (providers), `baikai-trace-otel/`
(OpenTelemetry sink), `baikai-effectful/` (effect binding), `baikai-kit/` (kit
installer), `baikai-agent/` (unattended runs and the `baikai` executable), and
`baikai-smoke/` (live tests, never published). Released versions at drafting time are
baikai/-claude/-openai 0.5.0.0, -trace-otel/-effectful 0.3.0.3, -kit 0.1.0.4, -agent
0.1.0.0 (per-package git tags; the root `CHANGELOG.md` is Keep-a-Changelog with
per-package headings). Every package compiles with `GHC2024`, the default extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and
`-Wpartial-fields` and `-Wmissing-export-lists` on.

The core's umbrella module `baikai/src/Baikai.hs` (an *umbrella module* only re-exports
other modules) states the constructor policy in its Haddock and deliberately omits
`Baikai.Trace`, `Baikai.Embedding`, `Baikai.Cost.Log`, `Baikai.Cost.Pricing`,
`Baikai.Provider.Registry`, `Baikai.Models.Generated` and `Baikai.Prelude`.
`baikai/src/Baikai/Prelude.hs` re-exports all of `Control.Lens` and generic-lens and is
documented as outside the compatibility contract. The registry
(`baikai/src/Baikai/Provider/Registry.hs`, façaded by `baikai/src/Baikai/Provider.hs`)
maps an `Api` tag (`baikai/src/Baikai/Api.hs`: four built-in constructors plus
`Custom !Text`) to an `ApiProvider` record of four functions; `completeRequest` looks
the handler up by `Model.api`. Every exposed module's export list was read for this
plan; the ones that change are named in Plan of Work with full paths.

Terms this plan uses, defined once here. *PVP* is Hackage's Package Versioning Policy:
versions are `A.B.C.D`; any change that can break a downstream build — removing an
export, changing a type, adding a constructor to an exported sum — requires a *major
bump* (`A.B` changes, here 0.5 → 0.6); a compatible addition bumps `C`; a change with
no API effect bumps `D`. A *constructor export* is `T (..)` in an export list, which
exports the type, its data constructor and its selectors; a *selector-only export* is
`T (field1, field2, …)`, which omits the constructor, so record update
(`base { field = v }`), `OverloadedRecordDot` reads (`r.field`) and generic-lens labels
(`r ^. #field`, `base & #field .~ v`) keep working while construction and positional
application stop compiling outside the defining module. Haskell has no package-private
visibility: sibling modules lose the constructor too. A *base value* is the exported
starting point for record update (`emptyOptions`, `baseEvidence`,
`defaultOtelSinkOptions`); it is how baikai adds fields in minor releases. A *partial
record selector* is a field defined on only some constructors of a sum, whose selector
crashes on the others (`ResponseFormat.name` on `JsonObject`). An *orphan instance* is
a class instance defined in a module that defines neither the class nor the type; two
packages can define conflicting ones, which is why this plan owns `HeaderName` rather
than instancing `CI Text`. The *`.Internal` convention* (plan 43) is that a module named
`….Internal….` is exposed for tests and sibling packages but its Haddock header says it
may change in any release. `DuplicateRecordFields` lets records share field names at
the cost that an ambiguous bare selector is an error — the sinks dodge it today by
matching on the constructor, which is why hiding those constructors needs
`OverloadedRecordDot`. A *capability record* is a file in `docs/capabilities/`, an OKF
bundle whose profile requires a `log.md` entry for every edit.

ADRs read for this plan: `docs/adr/0001-architecture-decision-record-convention.md`
(plain Markdown files, sequential `NNNN-` numbering, frontmatter `title`/`status`/`date`,
body Context/Decision/Consequences; this plan creates `0006` that way and adds a row to
`docs/adr/README.md`), and `docs/adr/0005-what-baikai-deliberately-does-not-do.md`
(baikai does not own retries; the evidence record carries `attempt`/`supersedes` as
caller-supplied provenance — the reason the duplicated field names stay). ADRs 0002
through 0004 govern the evidence vocabulary EP-8 owns and are not contradicted here.
No cross-repository ADR applies.

The review that scopes this plan is `docs/reviews/correctness-and-api-review-follow-up.md`:
G.1 constructor exports and assembler seams; G.2 `ResponseFormat` partial fields; G.3
shims with no removal version; G.4 the registry keyed on derived `Eq Api` and the
blank-tag message; G.5 naming and type consistency; G.6 `AgentRunResult` accessors,
`OtelSinkOptions` deriving, no `parseThinkingLevel`; G.7 `appendToolResult`; G.8 release
metadata; B.6 `Aborted`; and the residuals R5, R8, R10, R12 and R14. Every fact this
plan relies on is restated here with its file and line at `c3753c5`.

Sibling plans. EP-4 (`docs/plans/61-…`) owns both provider `Api.hs` files and lands
before this plan's relocation; EP-5 (`62-…`) may have answered the `ContentFiltered`
question; EP-8 (`65-…`) may add a strength ceiling to `ApiProvider`; EP-9 (`66-…`) may
add a parent-context field to `OtelSinkOptions`; EP-2 (`59-…`) may change
`EmbeddingModel.apiKey`; EP-3 (`60-…`) adds catalog fields; EP-6 (`63-…`) may add
`AgentJob` fields; EP-7 (`64-…`) changes `baikai-kit` signatures. Field lists in this
plan are as of `c3753c5`; the implementer enumerates the fields as they exist. EP-11
(`68-…`) hard-depends on this plan and rewrites the guides.

Downstream consumers. `mori registry dependents shinzui/baikai --packages` lists twelve
registered projects: handan, kanmon, kazuha, kikan, kioku, mina, mori, okf, rei, shiki,
shikigami and shikumi (paths from `mori registry show shinzui/<name> --full`). Their
sources were grepped for every name this plan removes, hides or retypes. The sites that
must move, by project (line numbers as of 2026-08-27):

- handan: `handan-core/test/{TraceSpec,ReleaseClassifySpec,StubLLM}.hs` use `_Response`
  and `_TextContent` → `emptyResponse`, `emptyTextContent`.
- kanmon: `kanmon-core/src/Kanmon/Enrich/Stub.hs:24,74-75` use `_Response`,
  `_TextContent`; `:61-66` constructs `ApiProvider { … }` → `apiProvider`.
- kioku: `kioku-core/test/Kioku/DistillSpec.hs:8,1735-1738` use `_Response`,
  `_TextContent`; `kioku-core/src/Kioku/Memory/Embedding.hs:47-54` constructs
  `EmbeddingModel { … }` → `emptyEmbeddingModel { … }`.
- mina: `mina-core/test/Mina/Trace/RuntimeSpec.hs:17-21,50,68,192` use `_Context`,
  `_Model`, `_Options`; `:90,185` and `mina-core/test/Mina/Agent/JudgeCacheSpec.hs:93`
  construct `ApiProvider { … }`; `mina-core/test/Mina/PlanDigest/Spike/PurposeSpike.hs:36-37,153-154`
  use `_Response`, `_TextContent`, and `:39,129` call `registerWithRegistryAndConfig`
  → `registerApiProviderWith reg (claudeCliProvider defaultClaudeCliConfig)`.
- shiki: `shiki-cli/src/Shiki/Cli/Agent/Launch.hs:39-41,170,174,193,203` and
  `shiki-core/src/Shiki/Analysis/Baikai.hs:20-21,63,68` use `_Context`, `_Model`,
  `_Options`. Its `InteractiveLaunchResult { exitCode }` matches keep compiling.
- shikigami: `shikigami-core/src/Shikigami/Behavior/StubProvider.hs:32,37,59,70` use
  `_Model`, `_Response`; `shikigami-agent/test/Shikigami/Agent/Capability/OneOffSpec.hs:213-215`
  and `shikigami-core/test/Shikigami/BehaviorToolSpec.hs:228,305` construct
  `ApiProvider { … }`; `OneOffSpec.hs:251` and `BehaviorToolSpec.hs:348` pattern-match
  `WireTool.Tool { WireTool.name = name }` → `map WireTool.name (…)`;
  `shikigami-core/test/Shikigami/RunEvidenceSpec.hs:84,115,626` pattern-match
  `EvidenceRequest { … }` and `ModelCallEvidence { … }` → `req.runId` or `#runId`.
- shikumi: `_X` aliases in `shikumi-jitsurei/app/{Streaming,Multimodal}.hs`,
  `shikumi-jitsurei/src/Shikumi/Jitsurei/Stub.hs`, `shikumi-eval/test/{UsageSpec,
  EvalFixtures}.hs`, `shikumi-compile/test/Test/Fixtures.hs`,
  `shikumi-optimize/test/StubLM.hs`, `shikumi-cache-redis/test/Main.hs`,
  `shikumi-trace/test/TraceFixtures.hs`, `shikumi-tools/src/Shikumi/Tool.hs:103`,
  `shikumi-tools/src/Shikumi/Agent/ReAct.hs:419`; `shikumi/src/Shikumi/Routing.hs:128`
  and `shikumi/test/RoutingSpec.hs:165,268` construct `JsonSchema {name = …, schema = …,
  strict = True}` → `JsonSchema (jsonSchemaFormat "output" s & #strict .~ True)`. Its
  `#headers` sites keep compiling and produce the same bytes.
- rei: `rei-core/src/Rei/Modules/Agent/Infrastructure/BaikaiBatchBackend.hs:104-117`
  matches every `ErrorCategory` constructor without a wildcard → add a
  `ContentFiltered ->` arm.
- kazuha, kikan, mori, okf: no affected sites (okf's `UserScope`/`ProjectScope` are
  `baikai-kit`'s `KitScope`, untouched).

Consumers move on their own schedule against the published 0.6 packages; this plan
records the sites so each project's upgrade is a known quantity and so EP-11 can name
them in the changelog's migration notes.

One repository rule to honour: record fields never carry Hungarian-style prefixes, even
on internal records. `HeaderName`, `JsonSchemaFormat` and every base value introduced
here follow it.


## Plan of Work

The work is four milestones, in the order and with the titles the master plan fixes.
Each leaves the whole project building and green under the keyless gate in Concrete
Steps. All paths are repository-relative; run every command from
`/Users/shinzui/Keikaku/bokuno/baikai`.


### Milestone 1 — constructor policy applied to every evolvable record; assembler seams behind `.Internal`

Scope: every remaining record outside plan 43's decided set that can grow a field stops
exporting its constructor, each gets a base value, and the two providers' streaming
internals move under `.Internal`. At the end, the surface probe builds every hidden
record from its base and nothing in-repo constructs one positionally.

Start with the reconciliation the first Decision Log entry requires, and fold every
field the sibling plans added into the export lists below before editing.

**`ApiProvider`.** In `baikai/src/Baikai/Provider/Registry.hs` change the export from
`ApiProvider (..)` to `ApiProvider (apiTag, stream, complete, describeThinking)` plus
any EP-8 field, and add this Haddock to the type:

```haskell
-- | Construction: the constructor is deliberately not exported. Start
-- from 'Baikai.Provider.apiProvider' and override fields by record
-- update, so that a field added in a later release cannot break a
-- registration site — as adding 'describeThinking' in 0.5.0.0 did.
```

`Baikai.Provider` is not the defining module, so `Registry.hs` exports the explicit
builder and `Baikai.Provider` (importing `Baikai.Stream (streamingComplete)`) the
convenience over it:

```haskell
-- Baikai.Provider.Registry — all three functions explicit; no Baikai.Stream import.
apiProviderWith ::
  Api ->
  (Model -> Context -> Options -> Stream IO AssistantMessageEvent) ->
  (Model -> Context -> Options -> IO Response) ->
  ApiProvider
apiProviderWith tag producer completer =
  ApiProvider
    { apiTag = tag,
      stream = producer,
      complete = completer,
      -- Honest for a transport with no reasoning controls; override by record update.
      describeThinking = \_ _ -> noThinkingRequested
    }

-- Baikai.Provider — the documented construction path; re-exported by Baikai.
apiProvider ::
  Api -> (Model -> Context -> Options -> Stream IO AssistantMessageEvent) -> ApiProvider
apiProvider tag producer = apiProviderWith tag producer (streamingComplete producer)
```

Export `ApiProvider` with the same selector list from `Baikai.Provider`. Sweep the
in-repo construction sites: `baikai-claude/src/Baikai/Provider/Claude/Api.hs:116-124` and
`Cli.hs:104`, `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:135-146` and `Cli.hs:105`
(the CLI providers keep their direct `complete` via `& #complete .~ …`, preserving
EP-3's latency decision), `baikai/test/Main.hs:81`, `baikai/test/CostSpec.hs:180`,
`baikai/test/ErrorInfoSpec.hs:54`, `baikai/test/HelpersSpec.hs:180,207,216,225`,
`baikai/test/StrictEvidenceSpec.hs:413,423`,
`baikai/test/TraceSpec.hs:116,127,292,386,699`, `baikai-claude/test/EvidenceSpec.hs:189`,
`baikai-openai/test/EvidenceSpec.hs:237`, `baikai-effectful/test/StubProvider.hs:100`,
`baikai-trace-otel/test/Main.hs:108,119,316`, and the two snippets at
`docs/user/models-and-providers.md:274,315` (mechanical edit only; EP-11 rewrites the
prose and the "Changed in 0.5.0.0" callout).

**Evidence records.** In `baikai/src/Baikai/Evidence.hs` export `ModelCallEvidence`
with every selector enumerated from its `data` block (at `c3753c5` it runs
`schemaVersion`, `runId`, `callId`, `attempt`, `supersedes`, `endpoint`,
`requestedModel`, `thinking`, … , `strength`, `requestCommitment`,
`requestConfiguration`, `responseCommitment`) and `EvidenceRequest (runId, strictness,
attempt, supersedes)`. The two sinks that match on the constructors to dodge
`DuplicateRecordFields` ambiguity — `baikai/src/Baikai/Trace/Sink.hs`
(`evidenceSummary`, ~line 117) and `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`
(`evidenceAttributes`, ~line 181) — add `{-# LANGUAGE OverloadedRecordDot #-}` and read
`ev.runId`, `ev.callId`, `ev.strength`; replace the "Read through a record pattern"
comments accordingly. Add the constructor-policy Haddock to both types, pointing at
`baseEvidence` and `evidenceRequest`.

**Smaller records.** `baikai/src/Baikai/Tool.hs`: export `Tool (name, description,
parameters)`, add `mkTool :: Text -> Text -> Value -> Tool`, keep `emptyTool`.
`baikai/src/Baikai/Embedding.hs`: `EmbeddingModel (modelId, baseUrl, dimensions,
apiKey)` as EP-2 left the fields. `baikai/src/Baikai/Cost/Log.hs`: `CallLogConfig
(path, enabled)` plus `callLogConfig :: FilePath -> CallLogConfig` (enabled); fix the
module Haddock's `withCallLog (CallLogConfig "/tmp/baikai.jsonl" True)` example.
`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`: `OtelSinkOptions (spanName,
includePromptSummary, …EP-9's field)`. `baikai-agent/src/Baikai/Agent/Cli.hs`:
`AgentCliOptions (command, overrides, userConfig, repoConfig, jsonOutput, evidenceFile,
runId, requiredEvidence)` plus `agentCliOptions :: AgentCliCommand -> AgentCliOptions`
(everything else empty), and `AgentCliRun (exitCode, standardOutput, standardError)`
plus `agentCliRun :: Int -> AgentCliRun`. `baikai-agent/src/Baikai/Agent/Config.hs`:
`AgentJob (provider, executable, modelId, effort, workingDir, extraDirs, capability,
allowedTools, providerArgs, timeout, output, outputLimit, envRequires, …EP-6's fields)`
plus `agentJob :: AgentProvider -> FilePath -> AgentCapability -> AgentJob` (the three
required fields; the rest empty, `output` at the module's own default), and
`AgentConfigPaths (userConfig, repoConfig)` plus `emptyAgentConfigPaths` (both
`Nothing`). Check `baikai-agent/app/Main.hs` reads `AgentCliRun` through selectors.

**The `.Internal.Stream` relocation.** For `baikai-claude`:

```bash
git mv baikai-claude/src/Baikai/Provider/Claude/Api.hs \
       baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs
```

Edit the moved file's `module` line to `Baikai.Provider.Claude.Internal.Stream`, replace
its module header with the no-guarantees block plan 43 standardised:

```haskell
-- | __Internal module — no stability guarantees.__ This module is
-- exposed so baikai's own test suites and sibling packages can reach
-- it, but it is not part of the public API: its contents may change
-- in /any/ release without a PVP major bump. Do not import it from
-- application code.
```

and export `SseDriver`, `liveSseDriver`, `claudeMessagesStreamWith`, `Assembler (..)`,
`emptyAssembler`, `translate`, `anthropicStrength` (deleting `register`,
`registerWithRegistry`, `claudeMessagesProvider`, `claudeMessagesStream`). Then create
a new `baikai-claude/src/Baikai/Provider/Claude/Api.hs` keeping the old public module
Haddock and defining only:

```haskell
register :: IO ()
register = registerApiProvider claudeMessagesProvider

claudeMessagesProvider :: ApiProvider
claudeMessagesProvider =
  apiProvider AnthropicMessages claudeMessagesStream
    & #describeThinking .~ describeThinkingFor

claudeMessagesStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStream = claudeMessagesStreamWith liveSseDriver
```

Add `Baikai.Provider.Claude.Internal.Stream` to `exposed-modules` in
`baikai-claude/baikai-claude.cabal`; repoint `baikai-claude/test/ThinkingSpec.hs:7`,
`SseSpec.hs:6` and `EvidenceSpec.hs:18`. Mirror this for `baikai-openai`
(`Internal/Stream.hs` additionally exports `RawChunk (..)`, `RawToolDelta (..)`,
`parseChunk`, `TagScanState (..)`, `emptyTagScanState`, `scanThinkTags`,
`closeOpenStream`, `RawUsage (..)`, `parseUsage`, `rawUsageToUsage`, `openaiStrength`;
rename `_TagScanState` at `Api.hs:734` and sweep; repoint
`baikai-openai/test/{SseSpec,ReasoningSpec,ShapeSpec,EvidenceSpec,Main}.hs`; delete the
"may move behind an .Internal namespace" comment). Add the same header, adapted
("exposed so the test suites can drive the transport without a socket"), to `Shape.hs`,
`Sse.hs` and `Transport.hs` in both providers, and point CAP-13's `proves` line for
`SseDriver`/`anthropicStrength` at the `.Internal.Stream` resource.

**Surface probe.** Extend `baikai/test/SurfaceSpec.hs` with a case "hidden records build
from their bases": `apiProvider (Custom "probe") (\_ _ _ -> Stream.nil)`,
`evidenceRequest "r" & #attempt .~ 2`, `mkTool "t" "d" Aeson.Null`,
`emptyEmbeddingModel & #modelId .~ "e"`, `callLogConfig "/dev/null"`, and in the otel
and agent suites `defaultOtelSinkOptions & #spanName .~ "x"`, `agentCliOptions …`,
`agentJob AgentClaude "." AgentReadOnly & #modelId .~ Just "m"`,
`emptyAgentConfigPaths`, asserting one field of each.

Acceptance: `cabal build all --enable-tests` and the keyless `cabal test all` succeed;
`git grep -n "ApiProvider$\|ApiProvider {"  -- '*.hs'` hits only `Registry.hs`;
the repl transcript in Validation shows no constructor for `ApiProvider`, `Tool`,
`ModelCallEvidence`; `grep -n "Internal.Stream" baikai-claude/baikai-claude.cabal
baikai-openai/baikai-openai.cabal` shows both modules.


### Milestone 2 — deprecated shims removed; versions bumped; changelog states removals

Scope: the twenty-five deprecated names go, the policy that would have removed them on
time becomes an ADR, and the release bookkeeping for this major opens.

Delete each `{-# DEPRECATED … #-}` pragma with the definition beneath it and the
export above it (`grep -rn DEPRECATED */src` lists all twenty-five lines): the sixteen
`_X` names in `baikai/src/Baikai/{Options,Context,Model,Response,Usage,Cost,Tool,
Content,Embedding,Interactive}.hs`, the six `Cli` registration shims at
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs:129-146` and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs:126-143`, `registerWithRegistry` in
both `.Internal.Stream` modules if it survived Milestone 1, and `newEventId` in
`baikai/src/Baikai/Trace.hs:39,535-543`. Rewrite the module Haddocks that recommend
the removed names (`Claude/Cli.hs:6`, `OpenAI/Cli.hs:6`).

`baikai/test/TraceSpec.hs` deliberately exercises `newEventId`; its header comment
(line 1) and this case must change rather than be deleted:

```haskell
  testCase "newEventId yields 70000 distinct 32-char ids" $ do
    ids <- replicateM 70000 newEventId
```

becomes `testCase "newCallId yields 70000 distinct 32-char ids"` over
`Baikai.Evidence.newCallId`, keeping the distinctness and length assertions that
follow. (The local `registerWithUsage` helper at `TraceSpec.hs:287` is not a shim.)

Mechanical edits where a removed identifier is named: `README.md:131-134` and
`docs/user/cli-providers.md:113-162` (the `registerWith*` sentences and snippets become
`registerApiProvider (claudeCliProvider cfg)` / `registerApiProviderWith reg
(codexCliProvider cfg)`), `docs/user/models-and-providers.md:232`,
`docs/capabilities/anthropic-messages-backend.md:37,68`, and
`docs/capabilities/call-tracing.md:74` ("removed in baikai 0.6.0.0; use `newCallId`").
Every capability edit gets a dated entry in `docs/capabilities/log.md`.

Create `docs/adr/0006-deprecated-names-are-removed-at-the-next-major.md`:

```markdown
---
title: A deprecated name is removed at the next major release after the one that deprecates it
status: accepted
date: 2026-08-27
---
```

with a Context recounting that the 0.3.0.0 changelog said the `_X` aliases "remain for
this release" and 0.4.0.0 and 0.5.0.0 shipped without removing them; a Decision stating
the rule, that every `DEPRECATED` pragma ends with "Removed in <package> <A.B.0.0>.",
and that the deprecating changelog entry names that version; and Consequences noting
that a consumer building with `-Werror=deprecations` gets exactly one major to migrate
and that release step 2 should grep for pragmas naming the version being cut. Add the
row to `docs/adr/README.md`.

Version bumps and bounds: set `version:` to `0.6.0.0` in `baikai/baikai.cabal`,
`baikai-claude/baikai-claude.cabal`, `baikai-openai/baikai-openai.cabal`; `0.4.0.0` in
`baikai-trace-otel/baikai-trace-otel.cabal`; `0.2.0.0` in `baikai-kit/baikai-kit.cabal`
and `baikai-agent/baikai-agent.cabal`; `0.3.0.4` (or `0.4.0.0`, per the Decision Log
rule) in `baikai-effectful/baikai-effectful.cabal`. Change every `baikai ^>=0.5.0`
(library and test stanzas of the six dependents) to `^>=0.6.0`, and in
`baikai-agent.cabal` `baikai-claude ^>=0.5` / `baikai-openai ^>=0.5` to `^>=0.6`.

`CHANGELOG.md`: above the 0.5.0.0 sections add `[baikai 0.6.0.0]`, `[baikai-claude
0.6.0.0]`, `[baikai-openai 0.6.0.0]`, `[baikai-trace-otel 0.4.0.0]`, `[baikai-effectful
<version>]`, `[baikai-kit 0.2.0.0]`, `[baikai-agent 0.2.0.0]`, dated `Unreleased` until
the release skill dates them. Each Removed list names every deleted identifier with its
replacement; each Changed list carries a **Breaking** marker per hidden constructor and
per relocation; later milestones append to these sections.

Acceptance: `grep -rn DEPRECATED */src` prints nothing; the two greps in Concrete Steps
for the removed names hit only `CHANGELOG.md`, `docs/plans/`, `docs/reviews/` and the
new ADR; `grep -rn "\^>=0\.5" --include='*.cabal' .` prints nothing; the build and the
keyless gate are green.


### Milestone 3 — `Api` key normalisation, `Aborted` decision, naming and type consistency decisions recorded and applied

Scope: the registry agrees with `parseApi`; the `Aborted` question is answered in code;
`ErrorCategory` gains its missing category; the G.5 type decisions land.

**`Api` normalisation.** In `baikai/src/Baikai/Api.hs` add and export:

```haskell
-- | Collapse a 'Custom' tag that spells a built-in API onto that
-- constructor, so @Custom "anthropic-messages"@ and 'AnthropicMessages'
-- are one registry key. Every other value is returned unchanged.
normaliseApi :: Api -> Api
normaliseApi = parseApi . renderApi
```

In `baikai/src/Baikai/Provider/Registry.hs`, `registerApiProviderWith` inserts under
`normaliseApi (apiTag p)` and `lookupApiProviderWith` looks up `normaliseApi tag`;
`assertRegistered` and both dispatch paths go through the lookup. Add an unexported
`describeApi :: Api -> Text` rendering `Custom ""` as `<blank Custom tag —
emptyModel.api was never set>` (otherwise `renderApi`) and use it in the "No provider
registered for API:" messages at `Registry.hs:166` and `Stream.hs` (`noProviderEvents`);
warn on `emptyModel`'s Haddock. Tests in `baikai/test/HelpersSpec.hs`: a handler under
`Custom "anthropic-messages"` is found by `lookupApiProviderWith reg AnthropicMessages`
and the reverse; `completeRequest emptyModel …` yields an error whose message contains
`blank Custom tag`.

**`Aborted`.** Run `grep -n "Aborted" docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md`
and read every hit in context. Default branch (no producer recorded): delete `Aborted`
from `data StopReason` in `baikai/src/Baikai/StopReason.hs` and `"aborted"` from its
wire-form Haddock, rewrite `baikai/src/Baikai/Stream/Event.hs:110-115` to say
`stopReason = ErrorReason` only, and remove the constructor from
`docs/user/streaming.md:59,130,182` (mechanical; EP-11 owns the prose). No test pins
`Aborted` at `c3753c5`. Alternative branch (EP-4 recorded a producer): keep it; in
`baikai/src/Baikai/Response.hs` change `responseError`'s guard to `sr == ErrorReason ||
sr == Aborted`; in `baikai/src/Baikai/Stream.hs` `finalizeState` synthesise
`normalizedError` for `(Aborted, Nothing)` too (`eventsFor` already keys on
`responseError`); add a `baikai/test/StreamSpec.hs` case that an `Aborted` response with
`errorInfo = Just e` lifts to `EventError` and stops `runToolLoop`. Record the branch
taken in the Decision Log.

**`ContentFiltered`.** In `baikai/src/Baikai/Error.hs` add the constructor between
`InvalidRequest` and `TransientError` (Haddock: "The provider refused or filtered the
content — OpenAI @content_filter@, Anthropic @refusal@. Not retryable as-is."), whose
derived JSON tag is `content_filtered`, plus `contentFiltered :: Text -> BaikaiError`.
Route the OpenAI `"content_filter"` finish-reason arm (was `Api.hs:1312`) and the
Claude `refusal` error (was `Api.hs:634`), both now in `Internal/Stream.hs`, through it,
with one test per provider suite asserting the category. Update
`docs/capabilities/categorised-error-model.md` ("Nine categories" → ten) with a log
entry.

**G.5 applications.** `baikai/src/Baikai/Options.hs`: `seed :: !(Maybe Int)`,
`stopSequences :: ![Text]` (`emptyOptions` sets `[]`); fix the mappers in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs:94-95` and
`baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs:76-80` and the tests at
`baikai-claude/test/Main.hs:116` and `baikai-openai/test/Main.hs:137`. Create
`baikai/src/Baikai/Header.hs`:

```haskell
-- | A case-insensitive HTTP header name that remembers its original
-- spelling, so a @Map HeaderName v@ holds at most one value per header.
newtype HeaderName = HeaderName (CI Text)
  deriving stock (Eq, Ord, Generic)

instance IsString HeaderName where fromString = headerName . Text.pack

headerName :: Text -> HeaderName
headerName = HeaderName . CI.mk

renderHeaderName :: HeaderName -> Text
renderHeaderName (HeaderName n) = CI.original n
```

plus `Show` (via `renderHeaderName`), `ToJSON`/`FromJSON` and `ToJSONKey`/`FromJSONKey`
(`toJSONKeyText renderHeaderName`, `FromJSONKeyText headerName`). Add `case-insensitive
^>=1.2` to `baikai/baikai.cabal`, the module to `exposed-modules` and to the umbrella.
Change `headers :: !(Map HeaderName Text)` in `Options.hs` and `Model.hs`; simplify
`applyHeaderOverrides` in both `Transport.hs` files (unwrap with `renderHeaderName`
before encoding); the generated catalog sets `headers = Map.empty` and needs no
regeneration; update the fixtures that build header maps (`baikai/test/Main.hs`,
`SurfaceSpec.hs`, both `TransportSpec.hs`). Add a `HelpersSpec` case: `Map.fromList
[("Authorization", "a"), ("authorization", "b")] :: Map HeaderName Text` has size 1. In
`baikai-agent/src/Baikai/Agent/Config.hs` rename `UserScope`/`RepositoryScope` to
`AgentUserScope`/`AgentRepositoryScope` and sweep `Cli.hs` and the tests. Record every
"keep" decision on the field's Haddock: `cacheRetention` and `toolChoice` ("`Nothing`
and `CacheRetentionNone` / `ToolChoiceAuto` are equivalent on the wire"), `ApiKeyEnv`
("`String` because `lookupEnv` takes one"), `TraceEvent.model` ("the requested model id;
see `CallEvidence` for the observed one", unless EP-8 already wrote it).

Acceptance: build and keyless gate green; `HelpersSpec` has the three new cases;
`git grep -n "CI.mk" -- 'baikai-*/src'` hits nothing (the key type carries the rule);
the repl shows `:t emptyOptions & #stopSequences .~ ["END"]` typechecks and
`emptyOptions & #stopSequences .~ Just (V.fromList ["END"])` does not.


### Milestone 4 — accessors, parsers and deriving gaps closed; release metadata complete

Scope: the remaining G.6/G.7/G.8 items, the `ResponseFormat` restructure, the public
surface compile modules, and every cabal-level release fact.

`baikai/src/Baikai/Agent.hs`: change the export `AgentRunResult,` to `AgentRunResult
(provider, exitCode, stdout, stderr, duration),`. `OpenTelemetry.hs`: add `deriving
stock (Generic)` to `OtelSinkOptions` (and `Eq, Show` if EP-9's field admits them;
record which). `baikai/src/Baikai/Embedding.hs`: `deriving stock (Eq, Show, Generic)`.

`baikai/src/Baikai/ThinkingLevel.hs`: add and export `parseThinkingLevel :: Text ->
Maybe ThinkingLevel`, the inverse of `renderThinkingLevel` over the six names. In
`baikai/src/Baikai/Evidence.hs` define `parseThinkingLevelText = maybe (fail …) pure .
parseThinkingLevel` and add the exported `parseEvidenceStrength :: Text -> Maybe
EvidenceStrength`, used by the `FromJSON EvidenceStrength` instance. In
`baikai-agent/src/Baikai/Agent/Config.hs:341-353` replace `effortDecoder`'s six-pair
`enumDecoder` with `parsedDecoder "one of: minimal, low, medium, high, xhigh, max"
(maybe (Left "unknown effort") Right . parseThinkingLevel)` and delete the comment
saying the core has no parser; in `baikai-agent/src/Baikai/Agent/Cli.hs:470-474`
replace the four-way `parse` with `parseEvidenceStrength`.
`baikai/test/ThinkingLevelSpec.hs` gains a round-trip case over every level.

`baikai/src/Baikai/ResponseFormat.hs`: remove `{-# OPTIONS_GHC -Wno-partial-fields #-}`;
define `data JsonSchemaFormat = JsonSchemaFormat { name :: !Text, schema :: !Value,
strict :: !Bool }` with the constructor-policy Haddock, `jsonSchemaFormat :: Text ->
Value -> JsonSchemaFormat`, and `data ResponseFormat = JsonSchema !JsonSchemaFormat |
JsonObject`; export `ResponseFormat (..)`, `JsonSchemaFormat (name, schema, strict)`,
`jsonSchemaFormat`. Hand-write the JSON instances so `JsonSchema f` still encodes as
`{"tag":"JsonSchema","name":…,"schema":…,"strict":…}` and `JsonObject` as
`{"tag":"JsonObject"}`, pinned by a golden case in `baikai/test/Main.hs`'s JSON
round-trip group. The two mappers (`Claude/Internal/Request.hs:160`,
`OpenAI/Internal/Request.hs:93`) read `f.schema` with `OverloadedRecordDot`, since the
constructor is hidden outside its module. Update `docs/capabilities/structured-output.md`'s
`Shape` if it spells the record (log entry).

`baikai/src/Baikai/Context.hs:109-131`: guard `appendToolResult ctx resp dispatcher`
with `| Just _ <- responseError resp = pure ctx` before the existing body, and rewrite
the Haddock's concurrency sentence to "The dispatcher is invoked once per call,
sequentially; an error-shaped response appends nothing." Add a `ContextSpec` case that
an `errorResponse` leaves the context unchanged and never calls the dispatcher.

Release metadata. Add `tested-with: GHC == 9.12.4` under `build-type:` in every
`.cabal` file including `baikai-smoke` (confirm with `ghc --version` in the dev shell;
`cabal.project` pins ghc912 and README.md:235 says 9.12.4). Create
`<pkg>/CHANGELOG.md -> ../CHANGELOG.md` symlinks for the six packages that lack one,
exactly as `baikai/CHANGELOG.md` is, and add `extra-doc-files: CHANGELOG.md`
(effectful: `CHANGELOG.md README.md`) to each. Rewrite the `description:` of
`baikai-claude.cabal` (Messages API provider, `claude -p` batch provider, Claude Code
launcher, unattended-agent renderer) and `baikai-openai.cabal` (OpenAI-compatible
hosts, `codex exec`, the Codex launcher and renderer). Change `baikai-trace-otel.cabal`'s
`streamly-core ^>=0.3` (library and test) to `>=0.3 && <0.5`. Remove `streamly` from
`baikai-effectful.cabal`'s library stanza (its one module imports only `streamly-core`).
In `CHANGELOG.md`'s `[baikai 0.5.0.0]` section add, marked "(entry added retroactively
in 0.6.0.0)", the missing items — strict evidence mode with its pre-dispatch refusal,
sink-failure semantics under strict mode, and the **Breaking**
`ApiProvider.describeThinking` field — and correct lines 86-89 ("every record has
strength `requested_only`") to say that held for the first evidence commit only.

Public surface compile modules. `baikai/test/PublicSurfaceSpec.hs` imports `Baikai`,
`Baikai.Trace`, `Baikai.Embedding`, `Baikai.Cost.Log` and `Baikai.Provider` only — no
`Baikai.Prelude`, no `Control.Lens` — and with record-update syntax alone builds every
base-constructed record, registers `apiProvider (Custom "public") (\_ _ _ ->
Stream.fromList [])` into a fresh registry, calls `completeRequestWith` and reads
`responseError`. The provider twins import only `Baikai.Provider.Claude.{Api,Cli,
Interactive,Agent}` (and the OpenAI mirror); the otel twin builds `otelSinkWith tracer
(defaultOtelSinkOptions {spanName = "x"})`; the agent twin builds `agentJob`,
`agentCliOptions` and `emptyAgentConfigPaths`. Register each in its `.cabal`
`other-modules` and test `main`. Update the master plan's four EP-10 Progress boxes and
registry row.

Acceptance: `cabal build all --enable-tests`, the keyless gate, `cabal haddock baikai`
and `cabal check` in each of the seven publishable package directories succeed;
`grep -n "tested-with" */*.cabal` shows eight lines; `ls -l */CHANGELOG.md` shows seven
symlinks; the OKF validation of `docs/capabilities` passes.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`,
inside the Nix dev shell (`nix develop` or direnv).

Before Milestone 1 — reconcile with the sibling plans and confirm the baseline:

```bash
for p in 58 59 60 61 62 63 64 65 66; do
  f=$(ls docs/plans/$p-*.md)
  echo "== $f"; sed -n '/## Decision Log/,/## Outcomes/p' "$f"
  sed -n '/## Interfaces and Dependencies/,$p' "$f"
done
git log --oneline -15
grep -rn DEPRECATED */src | wc -l        # expect 25 at c3753c5
```

The build-and-test loop after each batch of edits. The test gate must run with every
provider key and both coding-agent binaries hidden — `baikai-smoke` bills real calls on
keys and spawns `claude`/`codex` on `PATH` alone — so use the release skill's command
(`agents/skills/release/SKILL.md`, step 4), quoted verbatim for `zsh`:

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

preceded by `cabal build all --enable-tests`. Every suite must pass, not merely skip;
the tail reads one `PASS` line per suite:

```text
Test suite baikai-test: PASS
Test suite baikai-claude-test: PASS
…
Test suite baikai-smoke: PASS
```

Milestone 1 relocation and sweep checks (expected: the first two greps hit only
`Registry.hs` and `Provider.hs`; the third lists both new modules; the last is empty):

```bash
git grep -n "ApiProvider$\|ApiProvider {" -- '*.hs'
git grep -n "Tool {\|EmbeddingModel {\|CallLogConfig \"" -- '*.hs' '*.md' | grep -v "docs/plans\|docs/reviews\|CHANGELOG"
grep -n "Internal.Stream" baikai-claude/baikai-claude.cabal baikai-openai/baikai-openai.cabal
git grep -n "_TagScanState" -- '*.hs'
```

Milestone 2 removal sweep (expected: hits only in `CHANGELOG.md`, `docs/plans/`,
`docs/reviews/`, `docs/adr/0006-…`):

```bash
git grep -n -E "\b(_Options|_Context|_Model|_ModelCost|_Response|_Usage|_Cost|_CostBreakdown|_Tool|_TextContent|_ThinkingContent|_ToolCall|_ImageContent|_EmbeddingModel|_InteractiveLaunchRequest|_InteractiveLaunchResult)\b" -- '*.hs' '*.md' '*.cabal'
git grep -n "registerWith\b\|registerWithRegistry\|registerWithRegistryAndConfig\|newEventId" -- '*.hs' '*.md'
grep -rn DEPRECATED */src                              # expect: nothing
grep -rn "\^>=0\.5" --include='*.cabal' .               # expect: nothing
grep -n "^version" */*.cabal
```

Milestone 3 checks (expected: `HelpersSpec` reports the three new cases passing; the
grep is empty in the default `Aborted` branch):

```bash
cabal test baikai:test:baikai-test --test-options='-p /normaliseApi/'
git grep -n "\bAborted\b" -- '*.hs' 'docs/user'
git grep -n "CI.mk" -- 'baikai-*/src'
```

Milestone 4 release-metadata checks:

```bash
grep -n "tested-with" */*.cabal                        # expect: 8 lines
ls -l */CHANGELOG.md                                   # expect: 7 symlinks -> ../CHANGELOG.md
grep -n "streamly" baikai-effectful/baikai-effectful.cabal baikai-trace-otel/baikai-trace-otel.cabal
for d in baikai baikai-claude baikai-openai baikai-trace-otel baikai-effectful baikai-kit baikai-agent; do
  (cd "$d" && cabal check)                             # expect each: "No errors or warnings could be found in the package."
done
cabal haddock baikai                                   # expect: "Documentation created: …/doc/html/baikai/index.html"
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

`cabal check` also runs at release time (release skill step 6a); running it here
means the release finds nothing new.

Downstream re-check (expected: exactly the sites listed in Context and Orientation,
until each consumer migrates):

```bash
for p in handan kanmon kazuha kikan kioku mina mori-project/mori okf rei-project/rei shiki shikigami shikumi; do
  echo "== $p"
  grep -rn --include='*.hs' -E "\b(_Options|_Context|_Model|_ModelCost|_Response|_Usage|_Cost|_CostBreakdown|_Tool|_TextContent|_ThinkingContent|_ToolCall|_ImageContent|_EmbeddingModel|_InteractiveLaunchRequest|_InteractiveLaunchResult)\b|registerWith|newEventId|ApiProvider *\{|JsonSchema *\{|EmbeddingModel *\{|\bTool *\{|ModelCallEvidence *\{|EvidenceRequest *\{" \
    "/Users/shinzui/Keikaku/bokuno/$p" | grep -v dist-newstyle
done
```

Commit after each milestone (checkpoints inside Milestone 1 are encouraged) with a
conventional-commit subject — `refactor(api)!:` for Milestones 1 and 2, `fix(core)!:`
for Milestone 3, `chore(release):` for Milestone 4 — and always the three trailers:

```text
refactor(api)!: hide the remaining evolvable constructors; move assembler seams under .Internal

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/67-freeze-the-public-surface.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(core)!: normalise Api registry keys, retire Aborted, add ContentFiltered, type headers

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/67-freeze-the-public-surface.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```


## Validation and Acceptance

The change is accepted when all of the following hold, in this order.

Behavioural proof of the export policy. The repl check must run from a downstream-style
target, not `cabal repl baikai` (plan 43 found the library repl shows internal
constructors). Expected transcript shape:

```text
$ printf 'import Baikai\nimport Baikai.Provider\nimport Baikai.Prelude\nimport Streamly.Data.Stream qualified as Stream\n:t ApiProvider\n:t apiProvider (Custom "x") (\\_ _ _ -> Stream.nil)\n:t mkTool "t" "d" Null\n:t Tool { name = "t" }\n:t emptyOptions & #stopSequences .~ ["END"]\n:quit\n' | cabal repl baikai-test
ghci> <interactive>: error: [GHC-76037]
    Not in scope: data constructor 'ApiProvider'
ghci> apiProvider (Custom "x") (\_ _ _ -> Stream.nil) :: ApiProvider
ghci> mkTool "t" "d" Null :: Tool
ghci> <interactive>: error: [GHC-76037]
    Not in scope: data constructor 'Tool'
ghci> emptyOptions & #stopSequences .~ ["END"] :: Options
```

The same holds for `ModelCallEvidence`, `EvidenceRequest`, `EmbeddingModel` and
`CallLogConfig` in `cabal repl baikai-test`, `OtelSinkOptions` in `cabal repl
baikai-trace-otel-test`, and the four agent records in `cabal repl baikai-agent-test`.
`baikai/test/SurfaceSpec.hs` and the five `PublicSurface*` modules compile — their
compilation is the test that every intended-public name is still exported and that a
consumer without generic-lens can build every record.

Behavioural proof of the removals: `grep -rn DEPRECATED */src` prints nothing;
`:t _Options` in the repl above fails with "Variable not in scope: _Options";
`TraceSpec`'s renamed case passes over `newCallId`.

Behavioural proof of Milestone 3, each also a test case: after `reg <-
newProviderRegistryFrom [apiProvider (Custom "anthropic-messages") (\_ _ _ ->
Stream.nil)]`, `lookupApiProviderWith reg AnthropicMessages` is `Just _`;
`completeRequest emptyModel emptyContext emptyOptions` yields an error whose message
contains `blank Custom tag`; in the default branch `:info StopReason` lists `Stop |
Length | ToolUse | ErrorReason` and `docs/user/streaming.md` no longer names `Aborted`
(in the alternative branch the new `StreamSpec` case lifts an `Aborted` response to
`EventError`); `toJSON ContentFiltered` is `"content_filtered"`, `isRetryable
(contentFiltered "x")` is `False`, and the provider suites classify a `content_filter`
finish reason and a `refusal` stop as `ContentFiltered`; `Map.size (Map.fromList
[("Authorization","a"), ("authorization","b")] :: Map HeaderName Text)` is `1` and both
`TransportSpec`s still pass.

Behavioural proof of Milestone 4: `-Wpartial-fields` is on and `ResponseFormat.hs`
compiles warning-free; `toJSON (JsonSchema (jsonSchemaFormat "o" Null))` equals the
pinned flat object; the new `ContextSpec` case passes with a dispatcher that would
`error` if called; `parseThinkingLevel . renderThinkingLevel` is `Just` on every level.

Release acceptance: the seven `version:` lines read 0.6.0.0 / 0.6.0.0 / 0.6.0.0 /
0.4.0.0 / 0.3.0.4-or-0.4.0.0 / 0.2.0.0 / 0.2.0.0; no `^>=0.5` bound remains; every
publishable package has `tested-with` and a `CHANGELOG.md` symlink; `cabal check`
reports no errors or warnings for each; `cabal haddock baikai` ends with
"Documentation created"; the OKF capability validation passes; `CHANGELOG.md` has a
section per bumped package naming every removal; the master plan's four EP-10 boxes are
checked.


## Idempotence and Recovery

Every step is a plain source edit under git; recover from a misstep with
`git checkout -- <path>` before commit or `git revert` after. One commit per milestone
(with checkpoints inside Milestone 1 after the core sweep compiles and after each
provider's relocation) keeps a bad state one `git reset --hard HEAD~1` away.

The sweeps are idempotent and compiler-enforced: a missed construction site is a hard
error, a missed rename is an error once the shim is gone, and re-running the greps in
Concrete Steps lists exactly the remaining sites. The `git mv` relocations are safe to
redo; a half-applied one produces a build error naming the missing module. Symlink
creation (`ln -sf ../CHANGELOG.md <pkg>/CHANGELOG.md`), version and changelog edits are
pure text.

If a sibling plan decided something this plan assumes differently — EP-4 producing
`Aborted`, EP-5 adding a filter category under another name, EP-8 adding an
`ApiProvider` field needing a different default, EP-9 giving `OtelSinkOptions` a field
without `Eq` — do not improvise silently: record the conflict and resolution in both
Decision Logs, then take the branch this plan spells out. If EP-2's redaction instances
and `HeaderName` collide in `Options.hs` or `Model.hs`, the later change rebases and
keeps EP-2's rule (redact credential-bearing values, render keys with
`renderHeaderName`). The release itself is not part of this plan: the release skill
dates the changelog sections, tags and uploads after EP-11.


## Interfaces and Dependencies

New external dependency: `case-insensitive ^>=1.2` in `baikai/baikai.cabal` (already a
dependency of both provider packages). Removed: `streamly` from `baikai-effectful`'s
library stanza. Everything else is already in the build plan. Tooling: `cabal`
(build/test/haddock/check/repl), GHC 9.12.4, `okf` for the capability bundle.

At the end of Milestone 1:

- `Baikai.Provider.Registry.apiProviderWith :: Api -> (Model -> Context -> Options -> Stream IO AssistantMessageEvent) -> (Model -> Context -> Options -> IO Response) -> ApiProvider`
  and `Baikai.Provider.apiProvider :: Api -> (Model -> Context -> Options -> Stream IO AssistantMessageEvent) -> ApiProvider`
  (re-exported by `Baikai`); `ApiProvider` exports selectors only from both modules.
- `Baikai.Tool.mkTool :: Text -> Text -> Value -> Tool`;
  `Baikai.Cost.Log.callLogConfig :: FilePath -> CallLogConfig`;
  `Baikai.Agent.Cli.agentCliOptions :: AgentCliCommand -> AgentCliOptions`;
  `Baikai.Agent.Cli.agentCliRun :: Int -> AgentCliRun`;
  `Baikai.Agent.Config.agentJob :: AgentProvider -> FilePath -> AgentCapability -> AgentJob`;
  `Baikai.Agent.Config.emptyAgentConfigPaths :: AgentConfigPaths`.
- None of `ApiProvider`, `ModelCallEvidence`, `EvidenceRequest`, `Tool`,
  `EmbeddingModel`, `CallLogConfig`, `OtelSinkOptions`, `AgentCliOptions`, `AgentCliRun`,
  `AgentJob`, `AgentConfigPaths` exports a data constructor from any exposed module.
- `Baikai.Provider.Claude.Internal.Stream` and `Baikai.Provider.OpenAI.Internal.Stream`
  exposed with the no-guarantees header, exporting the seams listed in the Decision Log;
  `Baikai.Provider.Claude.Api` exports exactly `register`, `claudeMessagesProvider`,
  `claudeMessagesStream`; `Baikai.Provider.OpenAI.Api` exactly `register`,
  `openaiChatProvider`, `openaiChatStream`.

At the end of Milestone 2: the twenty-five removed names are absent from every export
list; `docs/adr/0006-deprecated-names-are-removed-at-the-next-major.md` exists; every
`.cabal` carries the versions and bounds recorded in the Decision Log.

At the end of Milestone 3: `Baikai.Api.normaliseApi :: Api -> Api` (re-exported by
`Baikai`); `Baikai.Error.ErrorCategory` has `ContentFiltered` and
`Baikai.Error.contentFiltered :: Text -> BaikaiError` exists; `StopReason` is `Stop |
Length | ToolUse | ErrorReason` (default branch) or unchanged with `responseError`
honouring `Aborted` (alternative branch); `Baikai.Header.HeaderName` with `headerName ::
Text -> HeaderName`, `renderHeaderName :: HeaderName -> Text` and the `IsString`, `Eq`,
`Ord`, `Show`, `ToJSON`, `FromJSON`, `ToJSONKey`, `FromJSONKey` instances;
`Options.headers` and `Model.headers :: Map HeaderName Text`; `Options.stopSequences ::
[Text]`; `Options.seed :: Maybe Int`; `AgentConfigScope = AgentUserScope |
AgentRepositoryScope`.

At the end of Milestone 4: `Baikai.Agent.AgentRunResult (provider, exitCode, stdout,
stderr, duration)` exported; `OtelSinkOptions` and `EmbeddingModel` derive `Generic`
(plus `Eq`/`Show` as decided); `Baikai.ThinkingLevel.parseThinkingLevel :: Text -> Maybe
ThinkingLevel`; `Baikai.Evidence.parseEvidenceStrength :: Text -> Maybe
EvidenceStrength`; `ResponseFormat = JsonSchema !JsonSchemaFormat | JsonObject` with
`JsonSchemaFormat (name, schema, strict)` selector-only and `jsonSchemaFormat :: Text ->
Value -> JsonSchemaFormat`; `appendToolResult` returns its input context unchanged for
an error-shaped response; every publishable `.cabal` has `tested-with: GHC == 9.12.4`
and `extra-doc-files: CHANGELOG.md`; `baikai-trace-otel` bounds `streamly-core >=0.3 &&
<0.5`; `baikai-effectful`'s library does not depend on `streamly`.
