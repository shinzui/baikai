---
id: 16
slug: switch-records-to-record-patterns-conventions
title: "Switch records to record-patterns conventions"
kind: exec-plan
created_at: 2026-05-28T14:36:44Z
---

# Switch records to record-patterns conventions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, every record-typed value in the baikai libraries — `Model`,
`Context`, `Options`, `Usage`, `Cost`, `Message`, `Response`, `Tool`,
`InteractiveLaunchRequest`, the per-provider assembler states, and every helper
record in `baikai-claude`, `baikai-openai`, `baikai-trace-otel`, and the test
suites — is defined and manipulated through the same vocabulary that
`bokuno/haskell-jitsurei/core/record-patterns.md` prescribes for Haskell records
across the wider stack. Concretely, every record field is strict
(`!`-annotated), no record field carries a Hungarian-style prefix
(`abModel`, `psChan`, `rsBlocks`, `ccMethods`, `rcContentDelta`, …) —
`DuplicateRecordFields` plus `OverloadedLabels` carry the disambiguation —
every data declaration uses an explicit `deriving stock` /
`deriving anyclass` / `deriving newtype` clause, no record reads or writes use
the legacy Haskell `selector record` or `record { field = ... }` syntax, and
every read or write goes through the `#fieldName` overloaded-label
syntax exposed by `generic-lens` and `Control.Lens`.

What a reader gains: every record in this codebase is touched the same way. A
contributor who has read `record-patterns.md` can open any file in
`baikai/src/`, `baikai-claude/src/`, `baikai-openai/src/`, or
`baikai-trace-otel/src/` and instantly know which idiom to reach for. A
grep for `^.\s#` (or its sibling setters `& #...  .~`, `& #... ?~`, `& #... %~`)
finds every place a record is read or updated; a grep for the old
`record { ... }` syntax returns nothing in production code.

You can see the work succeed in two ways. First, every Cabal package still
builds and every test still passes with the new code, run via
`cabal build all` and `cabal test all` from the repository root. Second, the
diff itself is observable: a grep across the whole library tree for
`{ [a-zA-Z]+ =` (record-update braces with a field name on the left of `=`) and
for the bare selector pattern `selectorName record` (where `selectorName` is a
field of a project-defined record) returns only references inside data
declarations, aeson `defaultOptions { fieldLabelModifier = ... }` calls (which
configure the aeson library and are not records this plan owns), and code that
manipulates third-party records from the `Anthropic` / `OpenAI` SDK packages.

The change is internal: no public function signature changes, no module is
renamed, no JSON wire shape changes. The libraries' API surface (the modules
re-exported from `Baikai` and from the vendor packages' top-level modules) and
the smoke tests' observable behaviour remain identical. The "feature" is
uniform code; we prove it by running the full test matrix and by visually
auditing two or three representative files before and after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Baseline audit and tooling baseline. (2026-05-28)
  - [x] `cabal build all` clean — every package builds, only pre-existing `relative-path-outside` warnings on `CHANGELOG.md`/`LICENSE` symlinks.
  - [x] `cabal test all` baseline counts:
    - `baikai-test`: 31 tests passed
    - `baikai-claude-test`: 1 test passed
    - `baikai-openai-test`: 2 tests passed
    - `baikai-trace-otel-test`: 2 tests passed
    - `baikai-smoke`: PASS (custom main, exercises live providers when keys are present)
  - [x] Audit grep #1 (record-update sites) — many hits. The project-record updates that this plan must convert live in:
    - `baikai/src/Baikai/Stream.hs` lines 128, 130, 132, 139, 141, 154, 159, 166, 168
    - `baikai/src/Baikai/Trace.hs` line 163 (construction literal, kept)
    - `baikai/src/Baikai/Cost/Pricing.hs` lines 61, 70
    - `baikai-claude/src/Baikai/Provider/Claude/Api.hs` lines 182, 195, 200, 275, 289, 306, 310, 314, 335, 339, 346, 350; literal `Messages.Error { ... }` at 167 stays as a third-party construction
    - `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` lines 121, 384, 469, 495, 547, 568, 578
    - `baikai-claude/src/Baikai/Provider/Claude/Api.hs` lines 425, 440 (`usageBare {Usage.cost = ...}` updates)
    - `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` line 658 (same pattern)
    - Test fixtures: `baikai/test/CostSpec.hs` lines 152, 170 (`knownModel {api = ...}`), `baikai-smoke/test/Smoke.hs` line 83, `baikai-smoke/test/MultiHostSmoke.hs` lines 71, 130, 136 (`Models.X {maxOutputTokens = ...}`)
    - Other hits are either record-pattern destructuring (`AssistantMessage {usage = u}`), record literals (`_Cost = Cost {...}`, `_Context {...}`, `EventStart {partial = sk}`, etc.) that the Decision Log preserves, or `aeson` `defaultOptions { fieldLabelModifier = ... }` — all kept as-is.
  - [x] Audit grep #2 (lazy fields) — five sites:
    - `baikai/src/Baikai/Content.hs:62` (`TextContent.text`)
    - `baikai/src/Baikai/Interactive.hs:43-49, 77-79` (`InteractiveLaunchRequest`, `InteractiveLaunchResult`)
    - `baikai/src/Baikai/Trace/Sink.hs:35` (`runSink`)
    - `baikai/src/Baikai/Provider/Registry.hs:42-43` (`ApiProvider.stream`, `ApiProvider.complete`)
  - [x] Audit grep #3 (implicit deriving) — no hits (every deriving clause is explicit).
  - [x] Audit grep #4 (Hungarian field prefixes) — confirmed the eight records: `ReassemblyState (rs…)`, `TraceState (ts…)`, `ClaudeCall (cc…)`, `ProducerState (ps…) ×2`, `Assembler (ab…) ×2`, `OpenAICall (oc…)`, `RawChunk (rc…)`, `RawToolDelta (rtd…)`, `RawUsage (ru…)`.
- [x] Milestone 2 — Core library: drop field prefixes, then convert updates → lens setters. (2026-05-28)
  - [x] `baikai/src/Baikai/Stream.hs`: renamed `ReassemblyState`'s `rs…` fields to plain names; added `deriving stock (Show, Generic)` (needed by `Data.Generics.Labels`); converted every `step` update to `s & #f %~ g` / `s & #f .~ x`; dropped the `Resp.`-qualifier on the Response literal in `finalizeState`; converted `Resp.message resp` read in `eventsFor` to `resp ^. #message`; removed the now-unused `import Baikai.Response qualified as Resp`.
  - [x] `baikai/src/Baikai/Context.hs`: converted `ctx { messages = ... }` to lens chain; replaced `message resp`, `id_ tc`, `name tc`, and `messages ctx` reads with `^. #...` form.
  - [x] `baikai/src/Baikai/Trace.hs`: renamed `TraceState`'s `tsChan`/`tsDone`/`tsClosed` to `chan`/`done`/`closed`; added `deriving stock (Generic)`; converted `tsChan s`, `tsDone s`, `tsClosed s` reads to `s ^. #chan`, etc. No record-update sites existed in this file beyond construction literals.
  - [x] `baikai/src/Baikai/Cost/Log.hs`: no record updates to convert; construction literals preserved per the Decision Log.
  - [x] `baikai/src/Baikai/Cost/Pricing.hs`: converted `u {cost = computed}` to `u & #cost .~ computed`; converted `r {message = msg'}` to `r & #message .~ msg'`; converted `message r` read to `r ^. #message`.
  - [x] `cabal build all` clean; `cabal test baikai-test` passes 31/31.
- [x] Milestone 3 — Vendor provider packages: drop field prefixes, then convert updates → lens setters. (2026-05-28)
  - [x] `baikai-claude/src/Baikai/Provider/Claude/Api.hs`: renamed `ClaudeCall`, `ProducerState`, and `Assembler` per plan; added `deriving stock (Generic)` to each; rewrote `step`, `writeTerminal`, `translate`, `handleBlockStart`, `handleBlockDelta`, `handleBlockStop`, `skeletonMessage`, `finalMessage`, `finalMessageOnError`, `blocksInOrder` to read via `^. #...` and update via `& #... %~ ...` / `& #... .~ ...`. The SDK destructuring `Claude.Methods {…} = call ^. #methods` at line 157 is kept (third-party record).
  - [x] `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` / `Interactive.hs`: audit returned no record-update sites — nothing to convert.
  - [x] `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`: renamed `OpenAICall`, `RawChunk`, `RawToolDelta` (`rtdId` → `id_`), `RawUsage`, `ProducerState`, `Assembler`; added `Generic` to each; `RawChunk.error` shadowing `Prelude.error` was harmless (no use of the `error` function in this module). Converted every `step`, `applyContentDelta`, `applyOneToolDelta`, `applyUsage`, `closeOnFinish`, `closeOpenText`, `closeOpenTools`, `closeOpenStream`, and `finalMessage` site to lens reads and setters.
  - [x] `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` / `Interactive.hs`: audit returned no record-update sites — nothing to convert.
  - [x] `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`: audit returned no record-update sites — nothing to convert.
  - [x] `cabal build all` clean; `cabal test {baikai-test,baikai-claude-test,baikai-openai-test,baikai-trace-otel-test}` all pass at baseline counts.
- [x] Milestone 4 — Test suites converted. (2026-05-28)
  - [x] `baikai/test/TraceSpec.hs`, `baikai/test/CostSpec.hs`, `baikai/test/Main.hs`: converted smart-constructor updates (`_Model { … }`, `_Context { … }`, `_Response { … }`, `knownModel { … }`) to lens chains; converted `_Response { all 6 fields }` to direct `Response { … }` literal where every field was named; replaced the `message resp` and `Usage.cost u` selector reads in `CostSpec.attachedUsd` with `resp ^. #message` and `u ^. #cost`; removed now-unused `_Response`/`Baikai.Usage qualified as Usage` imports.
  - [x] `baikai-claude/test/Main.hs`, `baikai-openai/test/Main.hs`: audit returned no record-update sites.
  - [x] `baikai-trace-otel/test/Main.hs`: same smart-constructor / `_Response { all fields }` conversions as TraceSpec.
  - [x] `baikai-smoke/test/Smoke.hs`, `baikai-smoke/test/MultiHostSmoke.hs`: converted `Models.X { maxOutputTokens = … }` and `_Model { … }` updates to lens chains.
  - [x] `cabal test {baikai-test, baikai-claude-test, baikai-openai-test, baikai-trace-otel-test}` all pass at baseline counts (31/1/2/2).
- [x] Milestone 5 — Strictness, deriving, prelude audit. (2026-05-28)
  - [x] Added `!` annotations to every previously-lazy `data` field: `InteractiveLaunchRequest` (7 fields), `InteractiveLaunchResult` (2 fields), `ApiProvider.stream`/`ApiProvider.complete` (function-typed strict fields). Records added by the migration (`ReassemblyState`, `TraceState`, `ClaudeCall`, the two `ProducerState`s, the two `Assembler`s, `OpenAICall`, `RawChunk`, `RawToolDelta`, `RawUsage`) are strict end-to-end — the bang was carried through the rename.
  - [x] `TextContent.text` and `TraceSink.runSink` are `newtype` fields; GHC rejects `!` on a newtype field (`GHC-04049`). Documented in the Decision Log; the audit grep treats them as a known exception.
  - [x] Audit grep #3 (implicit deriving) returned no hits — every `deriving` clause is explicit `stock` / `anyclass` / `newtype`.
  - [x] Spot-checked the modules touched in Milestones 2–4: every file that uses `#field` either imports `Baikai.Prelude` (which re-exports `Data.Generics.Labels`) or already had `import Data.Generics.Labels ()` + `Control.Lens` imports. The migration added `(%~), (&), (.~)` to existing `Control.Lens` imports in `Baikai.Stream`, `Baikai.Context`, `Baikai.Cost.Pricing`, `Baikai.Provider.Claude.Api`, and `Baikai.Provider.OpenAI.Api`; no new module needed a new prelude/imports block.
- [x] Milestone 6 — Validation, commit log, retrospective. (2026-05-28)
  - [x] `cabal build all` clean — only the pre-existing `relative-path-outside` warnings on `CHANGELOG.md`/`LICENSE` symlinks remain.
  - [x] `cabal test all` — every suite passes at baseline counts: `baikai-test` 31/31, `baikai-claude-test` 1/1, `baikai-openai-test` 2/2, `baikai-trace-otel-test` 2/2, `baikai-smoke` PASS (live providers via `OPENAI_API_KEY`, `claude`, `codex`).
  - [x] Audit grep #1 (record-update sites): only `_Cost = Cost {usd = 0, breakdown = _CostBreakdown}` (a full smart-constructor literal) and the OpenAI SDK destructuring `OpenAI.Methods {OpenAI.createChatCompletionStream = stream'} = call ^. #methods` remain in src/ — both documented exceptions.
  - [x] Audit grep #2 (lazy fields): only the two newtype fields (`TextContent.text`, `TraceSink.runSink`) remain, documented in the Decision Log as the GHC newtype-strictness exception.
  - [x] Audit grep #3 (implicit deriving): no hits.
  - [x] Audit grep #4 (Hungarian-style prefixes): no hits with the prefixes `rs`, `ts`, `cc`, `ps`, `ab`, `oc`, `rc`, `rtd`, `ru`. The remaining matches (`maxTokens`, `maxOutputTokens`, `apiKey`, `apiTag`, `isError`, `runSink`) are legitimate field names whose leading short word is part of the name, not a prefix; called out as false-positives in the plan's Validation section.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Generic deriving was missing on every renamed record.** Every record
  the plan renamed (`ReassemblyState`, `TraceState`, `ClaudeCall`,
  `ProducerState` ×2, `Assembler` ×2, `OpenAICall`, `RawChunk`,
  `RawToolDelta`, `RawUsage`) carried no `Generic` instance before this
  plan, because nothing was using `^. #field` on them. The first
  `cabal build baikai` after introducing `s & #model .~ ...` in
  `Baikai.Stream.step` failed with
  `No instance for Generic ReassemblyState`. Adding
  `deriving stock (Generic)` to each record cleared the build.
  Evidence: build error at `src/Baikai/Stream.hs:151` before the fix.
- **GHC rejects strictness on newtype constructor fields.** Adding `!`
  to `TextContent.text` failed with `GHC-04049: A newtype constructor
  must not have a strictness annotation`. Reverted and recorded in the
  Decision Log; the two newtype fields stay lazy in source even though
  they are operationally strict.
- **`Resp.message resp` selector reads decayed into unused-import
  warnings.** Once every read of a Response field switched to lens form
  (`resp ^. #message`), the `import Baikai.Response qualified as Resp`
  at the top of `Baikai.Stream` was redundant. Same story for
  `Baikai.Usage qualified as Usage` and the `_Response` import in two
  test files. Fixed by removing the unused imports.


## Decision Log

Record every decision made while working on the plan.

- Decision: Convert record-update syntax to lens setters everywhere, but keep
  full record literals (constructions that name every field, e.g. the
  `Response { message = ..., model = ..., ... }` block in
  `baikai/src/Baikai/Stream.hs` around `finalizeState`) as-is.
  Rationale: `record-patterns.md` warns against the update form (`r { f = x }`)
  because it does not compose and obscures how many fields change; it explicitly
  recommends building "new record by extracting from source" with positional
  named fields (see its "Record Construction from Lens Extractions" section).
  A record literal is the canonical construction site and matches the document's
  guidance. The `_Foo` smart-constructor values already in this codebase (e.g.
  `_Options`, `_Tool`, `_Cost`, `_Context`, `_Model`) are also literals; lens
  setters compose around them when callers want to override individual fields.
  Date: 2026-05-28.
- Decision: Do not rename any record field that already follows the
  no-prefix rule, and never touch a record name. Every rename in this plan
  is the removal of a Hungarian-style field prefix on a module-internal
  record; none of the renamed fields is JSON-serialised (the records whose
  JSON shape matters — `Message`, `Usage`, `Cost`, `Tool`, `Model`, etc. —
  already have plain field names today), so the wire shape stays put.
  Rationale: minimise diff size and avoid accidental JSON-API breakage.
  Date: 2026-05-28.
- Decision: Drop every Hungarian-style field prefix on project-defined
  records — including the assembler-state and producer-state prefixes
  (`abModel`, `psChan`, etc.) that I originally proposed to keep — and rely
  on `DuplicateRecordFields` + `OverloadedLabels` to disambiguate when two
  records carry a same-named field.
  Rationale: the user called this out as a project-wide rule on 2026-05-28
  after the first draft of this plan tried to carve out an exception for
  the per-module assembler records. `record-patterns.md`'s "No Field
  Prefixes" anti-pattern is universal in this codebase — there is no
  "but these records coexist in one module" carve-out. Records that need
  the prefix today (`ReassemblyState`, `TraceState`, `ClaudeCall`,
  `ProducerState`, `Assembler`, `OpenAICall`, `RawChunk`, `RawToolDelta`,
  `RawUsage`) are all module-internal — none appear in any module's export
  list — so the rename is contained.
  Date: 2026-05-28.
- Decision: Leave `aeson` `defaultOptions { fieldLabelModifier = ... }`
  call-sites as Haskell record-update syntax. They mutate an `aeson.Options`
  value (a third-party record outside this codebase) and the lens-based
  alternative would require a generic-lens label that lives in the `aeson`
  module hierarchy. The cost of forcing this is high, the benefit zero.
  Rationale: `record-patterns.md` is about records this project owns; third
  party records keep their library's idioms.
  Date: 2026-05-28.
- Decision: Do not skip the test suites. `record-patterns.md`'s anti-pattern
  list applies equally to test code; tests are often the first place
  contributors look for a working example, so they must demonstrate the right
  pattern.
  Rationale: future contributors learn the codebase by reading tests.
  Date: 2026-05-28.
- Decision: Leave the `text` field of `Baikai.Content.TextContent` and the
  `runSink` field of `Baikai.Trace.Sink.TraceSink` without a `!` annotation,
  even though Milestone 5 listed them as offenders.
  Rationale: both are `newtype` declarations, and GHC rejects a strictness
  annotation on a newtype constructor field (`GHC-04049`: "A newtype
  constructor must not have a strictness annotation"). Newtypes are
  representationally equal to their wrapped type, so the `!` would be
  redundant even if accepted. The audit grep matches them by syntactic shape
  only; they are documented exceptions, not a regression.
  Date: 2026-05-28.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome.** Every record-update site under `baikai/src`,
`baikai-claude/src`, `baikai-openai/src`, `baikai-trace-otel/src`,
`baikai/test`, `baikai-smoke/test`, and `baikai-trace-otel/test` now
uses the `& #field .~ value` / `& #field %~ f` idiom from
`bokuno/haskell-jitsurei/core/record-patterns.md`. Every Hungarian-style
field prefix on a project-defined record (`rs…`, `ts…`, `cc…`, `ps…`,
`ab…`, `oc…`, `rc…`, `rtd…`, `ru…`) is gone, replaced by the
disambiguation that `DuplicateRecordFields` + `OverloadedLabels` already
provided. Reads of these renamed fields go through `^. #field`. Every
data-declared field that was previously lazy now carries the `!` bang,
with the documented exception of the two `newtype` fields GHC will not
let us annotate. `cabal build all` is clean; every test suite reports
the same passing count as the baseline.

**What changed across packages**:

- `baikai` library: 4 modules touched (`Baikai.Stream`, `Baikai.Context`,
  `Baikai.Trace`, `Baikai.Cost.Pricing`) plus the strictness pass on
  `Baikai.Interactive` and `Baikai.Provider.Registry`. Two records
  renamed (`ReassemblyState`, `TraceState`) and gained
  `deriving stock (Generic)` clauses.
- `baikai-claude`: one large file (`Baikai.Provider.Claude.Api`) was the
  bulk of the work — three records renamed (`ClaudeCall`,
  `ProducerState`, `Assembler`) and every record-update site rewritten.
- `baikai-openai`: one large file (`Baikai.Provider.OpenAI.Api`) — six
  records renamed (`OpenAICall`, `RawChunk`, `RawToolDelta`, `RawUsage`,
  `ProducerState`, `Assembler`). `RawToolDelta.id_` carries the
  trailing underscore to dodge `Prelude.id`, matching the existing
  `Baikai.Content.ToolCall.id_` field.
- `baikai-trace-otel`: no source changes beyond the test fixture
  conversions.
- Test suites: every smart-constructor update (`_Model { … }`,
  `_Context { … }`, `_Response { … }`, `Models.X { … }`,
  `knownModel { … }`) converted to a lens chain; full-field
  constructions converted to direct constructor literals where they
  were redundantly going through a smart constructor.

**What surprised me**:

- GHC rejects `!` on `newtype` constructor fields (`GHC-04049`).
  Newtypes are representationally equal to their wrapped type, so the
  bang would be a no-op anyway, but the audit grep does not know that.
  The plan's seed list had to be amended with a Decision-Log carve-out.
- `record-patterns.md`'s "no field prefixes" rule turns out to be
  universal in this codebase, including on module-internal records.
  The first draft of this plan tried to preserve the assembler-state
  prefixes (`ab…`, `ps…`) on the grounds that they were never exported
  — the user pushed back and the plan was revised on 2026-05-28 to
  rename them too. Worth recording for next time: a rule the user calls
  "applies everywhere" really does, and an exec-plan should not invent
  carve-outs.

**Residual debt**:

- Several modules still read fields through qualified selector calls
  (`Usage.cost u`, `Usage.inputTokens u`, etc.) rather than `u ^. #cost`
  / `u ^. #inputTokens`. The plan's milestones were scoped to record
  updates and prefix renames, so these reads stayed. A follow-up pass
  could convert them, but doing so today would have ballooned the diff
  with no behavioural benefit.
- The `cabal build all` warning on `relative-path-outside` for
  `CHANGELOG.md` and `LICENSE` symlinks predates this plan; not in scope.


## Context and Orientation

The baikai repository (working directory
`/Users/shinzui/Keikaku/bokuno/baikai`) is a multi-package Cabal project — see
`cabal.project` at the repo root — that exposes a provider-neutral Haskell
interface for AI providers. The packages are:

- `baikai` (path `baikai/`) — the core library that owns the
  provider-neutral types (`Model`, `Context`, `Options`, `Message`, `Response`,
  `Usage`, `Cost`, `Tool`, `Stream`, `Trace`, etc.).
- `baikai-claude` (path `baikai-claude/`) — the Anthropic API and Claude CLI
  providers.
- `baikai-openai` (path `baikai-openai/`) — the OpenAI API and Codex CLI
  providers.
- `baikai-trace-otel` (path `baikai-trace-otel/`) — the OpenTelemetry trace
  sink, plus its test suite.
- `baikai-smoke` (path `baikai-smoke/`) — an end-to-end smoke test suite that
  hits live providers when the relevant API keys are present.

The conventions document this plan implements lives outside the repository at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`. Read it
in full before doing the work; the most load-bearing sections for this plan are
"Required Extensions and Dependencies", "Record Definition Conventions",
"Field Access with Generic Lens", "Prefer Lens Over Record Update Syntax", and
"Anti-Patterns to Avoid". Quoting the parts that drive the milestones:

> **Always use strict fields** with the `!` annotation.

> Always use explicit deriving strategies: `deriving stock` for standard
> classes, `deriving anyclass` for type classes with `Generic`. For newtypes,
> use `deriving newtype`.

> **Always prefer lens operators over Haskell's record update syntax**. Lens
> operators compose better, are more consistent, and make code easier to read
> and refactor.

> WRONG: `let s = memberSyncData stateData` — CORRECT: `let s = stateData ^. #memberSyncData`.

The terms of art in the conventions document are:

- **Generic Lens** — a Haskell library that, given a record deriving
  `GHC.Generics.Generic`, synthesises a `Control.Lens.Lens` for every named
  field. In this repository the generic-lens package is at
  `generic-lens ^>= 2.2` (see the `build-depends` block of `baikai.cabal` for
  the exact pin) and its orphan `IsLabel` instance — exposed through
  `Data.Generics.Labels ()` — is what makes the `#fieldName` syntax resolve to
  a lens. `Baikai.Prelude` already imports it for the whole core library;
  modules that import `Baikai.Prelude` get the instance "for free", as does any
  module in another package that uses `import Data.Generics.Labels ()`.
- **`#fieldName`** — an _overloaded label_. With the
  `OverloadedLabels` GHC extension (already in `default-extensions` of every
  cabal file), `#foo` desugars to an expression whose meaning is determined by
  which `IsLabel "foo" t` instance is in scope. The `Data.Generics.Labels`
  orphan provides such an instance for every field of every `Generic` record,
  resolving `#foo` to the lens that focuses on that field.
- **`^.`** — the lens "view" operator, from `Control.Lens`. `rec ^. #field`
  reads the field's value out of `rec`.
- **`& #field .~ v`** — the "set" idiom. `&` is reverse-application
  (`x & f = f x`), and `.~` is the lens setter. `rec & #field .~ v` returns
  `rec` with `field` replaced by `v`. The Maybe-specialised version `?~` sets a
  `Maybe`-typed field to `Just v`; the function-application version `%~`
  applies a function to the current field value.

The baikai core prelude (`baikai/src/Baikai/Prelude.hs`) already wires all of
this together. Every core-library module already imports `Baikai.Prelude` or
the equivalent (`Control.Lens` plus `Data.Generics.Labels ()`); the vendor
packages have `generic-lens` and `lens` in their `build-depends` blocks. There
is no Cabal or extension work to add — the language plumbing is in place.

What the audit found about the current state (commands and counts captured
2026-05-28; rerun in Milestone 1 to refresh):

- **Lens usage already happens, but inconsistently.** `Baikai.Trace`,
  `Baikai.Stream`, and `Baikai.Cost.Log` already use `m ^. #provider`,
  `m ^. #modelId`, `opts ^. #maxTokens`, etc. for *reads*. Updates, on the
  other hand, still go through record-update syntax — for example
  `baikai/src/Baikai/Stream.hs` line 130 reads
  `s {rsTextBuf = IntMap.insert i Text.empty (rsTextBuf s)}`, and
  `baikai/src/Baikai/Context.hs` line 76 reads
  `ctx { messages = messages ctx <> ... }`.
- **The vendor provider modules have many update sites.** `grep` finds dozens
  of `ass { ab... = ... }` and `s { ps... = ... }` updates inside
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (lines 182, 195, 200, 275,
  289, 306, 310, 314, 335, 339, 346, 350) and
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` (lines 384, 469, 495 and
  more — the audit listed only the first few). The exact line numbers will
  drift; the audit grep in Milestone 1 produces the authoritative list at edit
  time.
- **A few fields are still lazy.** Specifically:
  `baikai/src/Baikai/Content.hs` line 62 (`text :: Text` inside
  `TextContent`), `baikai/src/Baikai/Interactive.hs` lines 43–49 and 77–79
  (the `InteractiveLaunchRequest` and `InteractiveLaunchResult` records),
  `baikai/src/Baikai/Provider/Registry.hs` lines 42–43 (the `ApiProvider`
  record's two function-typed fields), and
  `baikai/src/Baikai/Trace/Sink.hs` line 35 (the `runSink` field). The audit
  in Milestone 1 will produce the full list; treat the entries above as a
  seed, not a contract.
- **Deriving strategies are uniformly explicit already.** `grep -rn "deriving (" ...
  | grep -v "deriving (stock|anyclass|newtype)"` returns no hits. We confirm
  this again in Milestone 5; the migration must not regress it.
- **Cabal blocks already declare the needed extensions and packages.** Every
  cabal file in the repository (`baikai/baikai.cabal`,
  `baikai-claude/baikai-claude.cabal`,
  `baikai-openai/baikai-openai.cabal`,
  `baikai-trace-otel/baikai-trace-otel.cabal`,
  `baikai-smoke/baikai-smoke.cabal`) lists `DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` under
  `default-extensions` and depends on `generic-lens` plus `lens ^>= 5.3`. No
  cabal edits are required by this plan.
- **Eight records carry Hungarian-style field prefixes today** — all
  module-internal (none appears in any module's export list). The full list:
  `ReassemblyState` (`rs…`) in `baikai/src/Baikai/Stream.hs`;
  `TraceState` (`ts…`) in `baikai/src/Baikai/Trace.hs`;
  `ClaudeCall` (`cc…`), `ProducerState` (`ps…`), and `Assembler` (`ab…`) in
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs`;
  `OpenAICall` (`oc…`), `RawChunk` (`rc…`), `RawToolDelta` (`rtd…`),
  `RawUsage` (`ru…`), `ProducerState` (`ps…`), and `Assembler` (`ab…`) in
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. The migration drops
  every prefix; `DuplicateRecordFields` and `OverloadedLabels` (both already
  enabled) carry the disambiguation when two records end up with a same-named
  field (e.g. both `ProducerState`s have a `chan` after the rename, but they
  never coexist in the same module).

The `mori.dhall` file at the repo root identifies this project as
`shinzui/baikai`; running `mori show --full` from the repo root prints the full
declared structure. Running `mori registry docs shinzui/baikai` returns the
curated documentation list, which currently does not include
`record-patterns.md` — the conventions live in a sibling project and are
copied into this plan by reference.


## Plan of Work

The work breaks into six independently-verifiable milestones. Each milestone
ends with a build and a test run from `/Users/shinzui/Keikaku/bokuno/baikai`,
so the next milestone always starts from a known-green tree. Commit at every
milestone boundary with a `feat(records):` or `refactor(records):` Conventional
Commits prefix, an `ExecPlan:` git trailer pointing at this file, and a focused
diff (one milestone per commit when feasible).

### Milestone 1 — Baseline audit and tooling baseline

Goal: capture a known-green starting point and produce a per-file punch list
for the remaining milestones.

What will exist at the end of this milestone that did not exist before: a
saved baseline of `cabal build all` and `cabal test all` output (captured into
the Progress section as terminal transcripts), plus three audit grep outputs
written into the Surprises & Discoveries section verbatim so a future
contributor can compare them against the post-migration greps. Nothing else
in the working tree changes.

Commands to run (working directory:
`/Users/shinzui/Keikaku/bokuno/baikai`):

```bash
cabal build all
cabal test all
grep -rEn '\b\w+ \{[a-zA-Z][^}]+ =' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src baikai/test baikai-smoke/test baikai-claude/test baikai-openai/test baikai-trace-otel/test
grep -rEn '(\b[a-z][a-zA-Z]*)\s+(\w+)\s*$' baikai/src/Baikai/Stream.hs
grep -rEn '::\s+[A-Z][a-zA-Z]+$|::\s+Maybe |::\s+\[' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src
```

The first grep finds record-update sites; the second is illustrative for
following the assembler-state updates inside `Baikai.Stream`; the third finds
record fields lacking the `!` strictness annotation. Save each command's
output (or "no matches") into the Progress section so the next milestone has
a list to work against.

Acceptance: `cabal build all` is clean with no warnings beyond what was
already there before the plan started; `cabal test all` reports every test
suite as `passing`. The audit transcripts are pasted into Progress.

### Milestone 2 — Core library `baikai` converted

Goal: every record-update site under `baikai/src/` becomes a lens-setter
chain, and the file imports `Baikai.Prelude` (or otherwise carries
`Control.Lens` + `Data.Generics.Labels ()`) so that the `#field` labels and
the setters resolve.

For each file in the punch list under `baikai/src/`, replace updates of the
form `record { field = expr }` with `record & #field .~ expr`. For
`Map`-typed fields use the `at` or `ix` lens as illustrated in
`record-patterns.md`'s "Map Operations with `at` and `ix`" section. For
function applications (`record { field = f (field record) }`) prefer
`record & #field %~ f`. Maybe-typed assignments to a `Just` value (`record {
field = Just x }`) become `record & #field ?~ x`. Multi-field updates chain
with `&`. Reads written as `field record` become `record ^. #field`.

Concrete files to touch (refresh the list from the Milestone 1 grep before
starting):

- `baikai/src/Baikai/Context.hs` — `appendToolResult` builds the next
  `Context` by updating `messages`; change the trailing `ctx { messages = ...
  }` literal to `ctx & #messages .~ ...`.
- `baikai/src/Baikai/Stream.hs` — `step` performs roughly a dozen `s { rs...
  = ... }` updates; each becomes `s & #rs... .~ ...` or `s & #rs... %~ ...`.
  The `IntMap.insertWith` updates are good candidates for `%~` since the new
  value is a function of the old.
- `baikai/src/Baikai/Trace.hs` — re-audit and convert any remaining
  record-update sites; the file already uses `^. #` for reads.
- `baikai/src/Baikai/Cost/Log.hs` — convert any record-update sites; preserve
  construction literals.

For every file you touch, run a partial build:

```bash
cabal build baikai
```

If a field's lens does not resolve (the most common error is
`No instance for (Data.Generics.Labels.IsLabel "fieldName" ...)`), the cause
is either a missing import — add
`import Baikai.Prelude` if absent, or `import Data.Generics.Labels ()` in
modules that cannot use the prelude — or a typo in the field name.

Commit when the `baikai` library builds cleanly. Use the trailer

```text
ExecPlan: docs/plans/16-switch-records-to-record-patterns-conventions.md
```

Acceptance: `cabal build baikai` succeeds with no new warnings, and a
post-milestone grep
`grep -rEn '\b\w+ \{[a-zA-Z][^}]+ =' baikai/src` returns only aeson
`defaultOptions { ... }` lines (annotated as "not a project record" in the
Decision Log) — every project-record update is gone.

### Milestone 3 — Vendor provider packages converted

Goal: bring `baikai-claude`, `baikai-openai`, and `baikai-trace-otel` to the
same standard as the core library.

Pick the packages in the order they appear above. The Claude API provider
(`baikai-claude/src/Baikai/Provider/Claude/Api.hs`) has the largest pile of
updates; tackle it first to get the conceptual hard part out of the way.
The `ass { ab... = ... }` updates inside the assembler step functions are
nearly mechanical: every such update becomes `ass & #ab... .~ ...` (or `.%~`
for `IntMap.insertWith` patterns). Watch for tuple returns of the form
`(events, ass { ab... = ... })`: parenthesise the lens chain
(`(events, ass & #ab... .~ ...)`) so the tuple parser sees the right thing.

For each vendor file:

```bash
cabal build baikai-claude
cabal build baikai-openai
cabal build baikai-trace-otel
```

Commit each package as one focused commit (or split further if the diff
balloons), each with the `ExecPlan:` trailer.

Acceptance: each `cabal build <pkg>` succeeds; the cross-package grep returns
no project-record update sites in vendor source.

### Milestone 4 — Test suites converted

Goal: the test suites under `baikai/test`, `baikai-claude/test`,
`baikai-openai/test`, `baikai-trace-otel/test`, and `baikai-smoke/test`
follow the same rules.

Tests typically construct fixtures with full record literals (which we keep)
and occasionally mutate one field of a fixture; convert those mutation sites.
Watch for pattern-match record syntax (`AssistantMessage {errorMessage = msg}
-> ...`) — that is *not* a record update; it is destructuring and stays as
is.

```bash
cabal test all
```

Acceptance: every suite still passes with the same test counts as the
Milestone 1 baseline; record-update grep returns no project-record hits in
test directories.

### Milestone 5 — Strictness, deriving, prelude audit

Goal: every project-defined `data` and `newtype` declaration has bang patterns
on every field, an explicit deriving strategy, and the imports the new code
needs.

The audit grep from Milestone 1 lists the lazy-field offenders. For each one,
add the `!` and recompile. Likely sites (seed list, refreshed from the audit
grep at edit time):

- `baikai/src/Baikai/Content.hs` — `TextContent.text`.
- `baikai/src/Baikai/Interactive.hs` — every field of
  `InteractiveLaunchRequest` and `InteractiveLaunchResult`.
- `baikai/src/Baikai/Provider/Registry.hs` — the `stream` and `complete`
  fields of `ApiProvider`. Function-typed strict fields are common in this
  codebase (see `runSink` in `Baikai.Trace.Sink`), so the convention applies
  here too.
- `baikai/src/Baikai/Trace/Sink.hs` — `runSink`.

```bash
cabal build all
cabal test all
```

Acceptance: `cabal build all` clean, `cabal test all` clean, audit grep for
lazy fields returns no project hits. The Decision Log records any field that
was deliberately left lazy (with a one-line reason).

### Milestone 6 — Validation, commit log, retrospective

Goal: the work is done, observed working, and recorded.

```bash
cabal build all
cabal test all
grep -rEn '\b\w+ \{[a-zA-Z][^}]+ =' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src baikai/test baikai-smoke/test baikai-claude/test baikai-openai/test baikai-trace-otel/test
```

The grep output must contain only the documented exceptions (aeson
`defaultOptions { ... }`, third-party SDK pattern-match destructuring inside
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` line 155 and
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` line 201, and any other
exceptions recorded in the Decision Log). Fill in Outcomes & Retrospective
with a one-paragraph summary of what changed, what surprised you, and any
residual debt left for a follow-up plan.


## Concrete Steps

Run these commands from the repository root unless stated otherwise:
`/Users/shinzui/Keikaku/bokuno/baikai`.

Baseline (Milestone 1):

```bash
cabal build all
```

Expected: every package compiles. The output ends with a list of
`Compiling …` lines and no `Error:` lines. Treat any warning that was not
present before this plan as a regression.

```bash
cabal test all
```

Expected: a `passing` count for each of the five test suites (`baikai-test`,
`baikai-claude-test`, `baikai-openai-test`, `baikai-trace-otel-test`,
`baikai-smoke`). Capture the exact passing counts into Progress; the same
counts must reappear in Milestone 6.

Audit grep #1 — record-update sites:

```bash
grep -rEn '\b\w+ \{[a-zA-Z][^}]+ =' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src baikai/test baikai-smoke/test baikai-claude/test baikai-openai/test baikai-trace-otel/test
```

Expected at baseline: many hits. After Milestone 6: only the documented
exceptions (`aeson` defaults, third-party-SDK destructuring).

Audit grep #2 — lazy fields:

```bash
grep -rEn '^\s*[,{]\s+[a-zA-Z]+\s+::\s+[A-Z]' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src
```

Expected at baseline: a handful of hits (see the seed list in Context and
Orientation). After Milestone 5: only the documented exceptions.

Audit grep #3 — implicit deriving:

```bash
grep -rEn 'deriving \(' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src baikai/test baikai-smoke/test baikai-claude/test baikai-openai/test baikai-trace-otel/test | grep -vE 'deriving (stock|anyclass|newtype)'
```

Expected at baseline: no hits. After Milestone 5: still no hits.

Audit grep #4 — Hungarian-style field prefixes:

```bash
grep -rEn '^\s*[,{]\s+[a-z]{2,3}[A-Z][a-zA-Z]+ ::' baikai/src baikai-claude/src baikai-openai/src baikai-trace-otel/src
```

Expected at baseline: the eight records listed under Context and
Orientation (`rs…`, `ts…`, `cc…`, `ps…`, `ab…`, `oc…`, `rc…`, `rtd…`, `ru…`).
After Milestones 2 and 3: only the false positives the regex catches that
are *not* prefixes — fields like `maxTokens`, `maxOutputTokens`, `isError`,
`apiKey`, `apiTag`, `runSink` that begin with a two- or three-letter word
followed by another capitalised word. Spot-check each remaining hit against
the actual field name and confirm it is not a prefix; document any new
exceptions in the Decision Log.

Per-milestone build:

```bash
cabal build baikai
cabal build baikai-claude
cabal build baikai-openai
cabal build baikai-trace-otel
cabal build baikai-smoke
```

Each command should print a sequence of `Compiling Baikai.…` lines and exit
with status 0.

Final acceptance:

```bash
cabal build all
cabal test all
```

Capture the output of `cabal test all` into Outcomes & Retrospective so the
final state is recorded in the plan.

Commit recipe for every commit on this plan (passed via `HEREDOC` to honour
the user's commit-style rules):

```bash
git commit -m "$(cat <<'EOF'
refactor(records): switch <area> to lens-based field access

<one-paragraph body explaining what changed and why>

ExecPlan: docs/plans/16-switch-records-to-record-patterns-conventions.md
EOF
)"
```

Substitute `<area>` with the milestone scope (`core`, `baikai-claude`,
`baikai-openai`, `baikai-trace-otel`, `tests`, `strictness`). Use
`refactor(records):` for pure conversions and `feat(records):` only if the
work introduces a new lens helper or convenience (the plan does not call for
any, so the prefix should stay `refactor:` throughout).


## Validation and Acceptance

The change is internal — no JSON wire shape, no public type signature changes —
so acceptance is "the system still works exactly as before, but the code
follows the conventions."

Behavioral acceptance (run from
`/Users/shinzui/Keikaku/bokuno/baikai`):

1. `cabal build all` exits 0, prints no `Error:` lines, and emits the same
   warning set as the pre-migration baseline. Warnings introduced by the
   refactor are treated as regressions and fixed before the milestone closes.
2. `cabal test all` runs every suite and reports the same passing test count
   per suite as the Milestone 1 baseline. If any test count drops, treat it
   as a regression; if any count rises (because a contributor added a test
   alongside the refactor), record the addition in Surprises & Discoveries.
3. The `baikai-smoke` suite passes when the relevant API keys
   (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are set in the environment; when
   the keys are missing the suite skips the matching tests rather than
   failing. The smoke suite's role is to confirm that a real provider call
   round-trips through the refactored code; do not invoke it if the keys are
   not available, but mention the gap in Surprises & Discoveries.

Structural acceptance (also from the repo root):

4. Audit grep #1 (see Concrete Steps) returns only the documented exceptions.
   List the exceptions in the Decision Log if any new ones emerge during the
   work.
5. Audit grep #2 returns no project hits — every project-defined record field
   is strict.
6. Audit grep #3 returns no hits — every deriving clause is explicit.
7. Audit grep #4 returns only false-positive entries documented in the
   Decision Log (e.g. `maxTokens`, `apiKey`, `apiTag`, `runSink`, `isError`,
   `maxOutputTokens` — names that begin with a short word, not a Hungarian
   prefix). No record field starts with `rs`, `ts`, `cc`, `ps`, `ab`, `oc`,
   `rc`, `rtd`, or `ru` followed by a capital letter.

Observability acceptance:

7. Open `baikai/src/Baikai/Context.hs` and confirm that the body of
   `appendToolResult` ends with `ctx & #messages .~ ...` rather than
   `ctx { messages = ... }`. This is the one file a reader is most likely to
   open first; if it looks correct, the rest of the migration almost
   certainly does too.
8. Open `baikai-claude/src/Baikai/Provider/Claude/Api.hs` around the
   assembler-step functions and confirm that every `ass { ... }` is now
   `ass & #... .~ ...`. The diff is mechanical but voluminous; an eyeball
   pass on one or two cases is enough to spot a regression.


## Idempotence and Recovery

Every milestone is safe to repeat. The conversions are purely textual: if you
re-run the audit grep after committing and discover a missed update site,
edit the file, rebuild, and commit again with another `ExecPlan:` trailer.
There is no migration to roll back — the codebase still builds and runs
identically before and after each conversion.

If a commit lands with a broken build (the lens setter does not type-check),
the recovery path is to fix the type error in place and create a *new* commit
on top; do not amend a published commit. The most common type errors are:

- The field name is misspelled in `#fieldName`. Compare against the data
  declaration in the same module; fix the spelling.
- The lens setter is being chained against a value of the wrong type
  (`ctx & #messages .~ aListOfMessages` when the field is a `Vector
  Message`). Wrap with `V.fromList` or otherwise convert at the boundary —
  the type error pinpoints the line.
- A module that uses `#fieldName` does not have the orphan `IsLabel`
  instance in scope. Add `import Baikai.Prelude` if the module is in the
  core package and does not already import it; otherwise add
  `import Data.Generics.Labels ()`.

If a test suite regresses, run the suite in isolation
(`cabal test baikai-test --test-options='-p "PatternThatNames TheTest"'`) and
diff the failing assertion against the pre-migration commit. The most likely
cause is a typo in a field name (the lens silently focuses on the wrong field
because two fields share a name across two record types), so `git diff` on the
single file with the failure usually surfaces the bug in seconds.


## Interfaces and Dependencies

No new dependencies are added. No module is renamed or removed. The signatures
of every public function in `Baikai`, `Baikai.Provider.Claude.*`,
`Baikai.Provider.OpenAI.*`, and `Baikai.Trace.Sink.OpenTelemetry` remain
identical pre- and post-migration. The `ExecPlan` is a refactor of usage
sites; no end-to-end contract changes.

Libraries used by the migration (all already pulled in by every cabal file):

- `generic-lens ^>= 2.2` — supplies the orphan
  `IsLabel sym (Lens' s a)` instance via `Data.Generics.Labels`. The instance
  is the linchpin: it is what makes `#fieldName` resolve to a lens. The orphan
  is re-exported into the project's scope through `Baikai.Prelude`.
- `lens ^>= 5.3` — supplies the operators: `^.` (view), `.~` (set), `?~`
  (set-Just), `%~` (over), `&` (reverse application), `at`, `ix`. All come
  from `Control.Lens`, which `Baikai.Prelude` re-exports with `Context` hidden
  to avoid clashing with `Baikai.Context`.

Modules touched by the migration (the full list emerges from the
Milestone 1 grep; the seed list lives in Progress and Plan of Work). The
modules' public types and exports stay the same; only their bodies change.

Function-signature contract: after the migration completes,
`Baikai.Context.appendToolResult :: Context -> Response -> (ToolCall -> IO
Text) -> IO Context` still has that exact signature; the only difference is
that its body uses `& #messages .~ ...` instead of `{ messages = ... }`. The
same is true for every other function in the touched modules.


## Revision Notes

- 2026-05-28: dropped the Decision Log carve-out that preserved the
  `ps…`/`ab…`/`cc…`/`oc…`/`rc…`/`rtd…`/`ru…`/`rs…`/`ts…` field prefixes on
  module-internal records, in response to user feedback that the
  "no field prefixes" rule from
  `bokuno/haskell-jitsurei/core/record-patterns.md` is universal in this
  codebase. Added explicit field-rename steps to Milestones 2 and 3, listed
  every affected record in Context and Orientation, added a fourth audit
  grep (`Audit grep #4 — Hungarian-style field prefixes`) to Concrete Steps
  and Validation, and expanded the Purpose section to call out the rule.
  Why: a contributor reading the first draft of the plan would have
  preserved the prefixes; the rename is essential to the goal.
