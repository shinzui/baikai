---
id: 7
slug: correctness-and-api-hardening-from-the-2026-07-review
title: "Correctness and API hardening from the 2026-07 review"
kind: master-plan
created_at: 2026-07-02T04:11:37Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
---

# Correctness and API hardening from the 2026-07 review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

The library review recorded in `docs/reviews/2026-07-01-correctness-and-api-review.md`
found roughly forty-five correctness defects and fourteen API-design gaps across the
baikai packages. The review's verdict was that the architecture is sound but three
load-bearing subsystems do not work as documented: error classification never produces
a usable retry category for real failures, extended thinking breaks on request (over-cap
`max_tokens`) and on replay (signatures stripped by stream reassembly), and the
compat-quirk system is defined and tested but consumed by no provider code. This
initiative fixes every finding in that review, in dependency order, so the library can
be trusted for production workloads.

When the initiative is complete, the following user-visible behaviors hold. A caller
hitting a real HTTP 429 from Anthropic or OpenAI receives a `BaikaiError` with category
`RateLimited`, a populated `retryAfterSeconds` when the server sent one, and
`isRetryable = True` — on both the streaming and blocking paths, through one documented
error channel. A thinking-enabled request with default options succeeds instead of
returning HTTP 400, and replaying the returned assistant turn (signatures, redacted
blocks and all) is accepted by Anthropic. Reported `Cost` matches what the provider
bills — cached tokens are no longer double-counted on OpenAI. Every flag in
`Baikai.Compat` either changes the request that goes over the wire or no longer exists.
`Options.timeoutMs` bounds a stalled stream. The CLI providers survive prompts that
start with `-`, never deadlock on chatty stderr, and the codex provider sends the
system prompt. A trace sink that throws cannot hang the caller. A malicious kit
repository cannot write outside the install root. Finally, the public API grows the
helpers the review identified as missing (a tool round-trip loop, context construction
helpers, streamly-free streaming entry points) and sheds its pre-freeze debt
(constructor exports, misleading `_X` names, stale docs) so the surface can be frozen.

Out of scope: new provider integrations, the MCP work tracked by
`docs/masterplans/6-mcp-support-across-the-agent-stack.md`, publishing to Hackage, and
any feature not traceable to a finding in the review document. Where a fix requires a
change in the MercuryTechnologies claude/openai SDKs, the plan may wrap or bypass the
SDK locally but does not fork it; if a wrap is impossible the limitation is recorded and
surfaced in the plan's outcome rather than silently absorbed.


## Decomposition Strategy

The review's findings cluster into ten work streams grouped in four implementation
waves. The grouping is by functional concern — what invariant or behavior the plan
restores — not by package, because several findings span core and provider code (for
example, thinking fidelity requires both a core event-algebra change and provider
mapping changes).

Wave 1 contains five plans with no dependencies on each other, all independently
verifiable: worker-thread resilience in trace/call-log (EP-1), baikai-kit hardening
(EP-2), CLI subprocess hardening (EP-3), usage/cost accounting (EP-4), and the core
streaming event-protocol fidelity work (EP-5). EP-5 is in wave 1 because it is the
artifact-producing bottleneck for wave 2: the event algebra must be able to carry
thinking signatures, redacted payloads, and response ids before either provider can
emit them.

Wave 2 restores the two broken subsystems that sit on top of the event protocol: the
error contract and live error classification (EP-6), and extended thinking/reasoning
(EP-7). Both hard-depend on EP-5 because they modify `baikai/src/Baikai/Stream.hs` and
the event payload types that EP-5 reshapes; serializing them avoids conflicting edits
to the same functions.

Wave 3 is the remaining wire-conformance work (EP-8): implement-or-delete every compat
quirk, wire `timeoutMs`/headers, fix tool-schema mangling and host detection. It runs
after EP-7 because both edit `mapRequest` in the Claude provider (an integration
dependency, resolved by ordering).

Wave 4 is the API pre-freeze work: new ergonomic helpers (EP-9), then the
surface-hygiene and documentation sweep (EP-10). EP-10 is last because renames and
export-policy changes must cover the helpers EP-9 introduces, and the doc sweep must
describe final behavior.

Alternatives considered. A single "fix the review findings" ExecPlan was rejected: the
review spans seven packages and would produce a plan with a dozen milestones touching
unrelated modules, violating the decomposition guidance. Splitting error classification
into separate Claude and OpenAI plans was rejected because the fix is the same disease
in both (SDK-level text errors bypassing the classifiers) and the contract they must
satisfy is defined once in core. Folding EP-4 (usage/cost) into EP-8 (wire conformance)
was rejected to keep a small, high-value billing fix landable in wave 1 rather than
behind the largest plan. Ten plans exceeds the preferred seven, which is why the waves
above exist; each wave is at most five plans and waves 2–4 are two plans or fewer.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Harden trace and call-log workers | docs/plans/34-harden-trace-and-call-log-workers.md | None | None | Complete |
| 2 | Harden baikai-kit install and status | docs/plans/35-harden-baikai-kit-install-and-status.md | None | None | Complete |
| 3 | Harden CLI subprocess argument and pipe handling | docs/plans/36-harden-cli-subprocess-argument-and-pipe-handling.md | None | None | Complete |
| 4 | Correct usage and cost accounting | docs/plans/37-correct-usage-and-cost-accounting.md | None | None | Complete |
| 5 | Carry full fidelity through the streaming event protocol | docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md | None | None | Complete |
| 6 | Unify the error contract and revive error classification | docs/plans/39-unify-the-error-contract-and-revive-error-classification.md | EP-5 | None | Complete |
| 7 | Fix extended thinking and reasoning across providers | docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md | EP-5 | EP-6 | Complete |
| 8 | Implement compat quirks and transport options | docs/plans/41-implement-compat-quirks-and-transport-options.md | None | EP-6, EP-7 | Not Started |
| 9 | Add core ergonomic helpers before the API freeze | docs/plans/42-add-core-ergonomic-helpers-before-the-api-freeze.md | None | EP-6 | Not Started |
| 10 | Tighten the public surface and sweep the docs | docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md | EP-9 | EP-1..EP-8 | Not Started |


## Dependency Graph

EP-1 through EP-5 have no dependencies and can proceed in parallel; they touch disjoint
modules (trace/log workers; baikai-kit; the CLI provider subprocess layer plus
`Baikai.Provider.Cli.Internal`; the OpenAI usage mapping plus `Baikai.Usage` haddock;
the core `Baikai.Stream` / `Baikai.Stream.Event` modules respectively).

EP-6 hard-depends on EP-5 because both rewrite parts of `baikai/src/Baikai/Stream.hs`:
EP-5 reshapes `reassembleResponse`, the event payload types, and
`liftCompleteToStream`'s emitted sequence, while EP-6 changes the error-terminal
semantics of those same functions (an error-shaped `Response` must lift to `EventError`,
not `EventDone`). Implementing EP-6 against the pre-EP-5 shapes would produce
conflicting edits to the same code.

EP-7 hard-depends on EP-5 because thinking fidelity is impossible until the event
algebra can carry a signature and a redacted payload from provider to reassembler; that
carriage is an EP-5 artifact. EP-7 soft-depends on EP-6 only because its acceptance
tests want to assert typed `BaikaiError` categories for the 400s it eliminates; it can
proceed with string assertions if EP-6 is not done.

EP-8 has no hard dependency but soft-depends on EP-7: both plans edit `mapRequest` in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` (EP-7 owns the thinking/max_tokens
computation; EP-8 owns tools, tool_choice, cache_control, and header shaping). Running
EP-8 after EP-7 avoids a rebase of the same function. Its soft dependency on EP-6
exists because EP-8's timeout work must decide what a timeout *raises*, and that answer
comes from EP-6's contract.

EP-9 can start any time (its helpers are additive) but soft-depends on EP-6 because
`runToolLoop` and `responseError` must be written against the final error contract.
EP-10 hard-depends on EP-9 (export policy and renames must cover the new helpers) and
soft-depends on everything else (the documentation sweep must describe post-fix
behavior; doing it earlier would document code that is about to change).


## Integration Points

The streaming event algebra (`baikai/src/Baikai/Stream/Event.hs`) is shared by EP-5,
EP-6, and EP-7. EP-5 defines its final shape: `ThinkingEnd` carries the full
`ThinkingContent` (signature and redacted flag) rather than bare text, a carriage
mechanism for the provider message id exists (on `StartPayload` or the terminal
payload), and the reassembler treats the terminal event's message as authoritative for
block content where present. EP-6 consumes the terminal payload types unchanged; EP-7
emits the new fields from both providers. Any further change EP-6/EP-7 need in the
algebra must be recorded here and in EP-5's Decision Log, not made silently.

Two sequenced changes to the event algebra's terminal constructors are agreed between
EP-5 and EP-6: EP-5 reshapes `doneTerminal`/`errorTerminal` to carry a `Maybe Text`
response id, and EP-6 subsequently tightens `errorTerminal`'s error argument from
`Maybe BaikaiError` to a required `BaikaiError` (enforcing the
`ErrorReason ⟹ errorInfo` invariant by construction). The final signature after both
plans is `errorTerminal :: Maybe Text -> StopReason -> Message -> BaikaiError ->
TerminalPayload`. EP-6's SSE work also introduces local transport modules
(`Baikai.Provider.Claude.Sse`, `Baikai.Provider.OpenAI.Sse`) that bypass the SDKs'
lossy error paths; EP-8 must wire `timeoutMs`/headers through those modules rather
than the SDK client env, and EP-10 may relocate them behind `.Internal`.

The error contract is shared by EP-6 (owner), EP-7, EP-8, and EP-9. The contract,
decided in this MasterPlan (see Decision Log), is: failures are reported in-band —
`stopReason = ErrorReason` with `errorInfo = Just be` on the blocking path, a single
terminal `EventError` carrying the same `BaikaiError` on the streaming path — and the
invariant `stopReason == ErrorReason` implies `errorInfo` is present is enforced.
`completeRequest` on an unregistered tag and the CLI providers conform to in-band
reporting instead of throwing. EP-6 implements this and exports
`responseError :: Response -> Maybe BaikaiError`; EP-7 and EP-8 write their acceptance
tests against it; EP-9's `runToolLoop` terminates on it.

`mapRequest` in `baikai-claude/src/Baikai/Provider/Claude/Api.hs` is edited by EP-7
(thinking field, `max_tokens` computation) and EP-8 (tool schemas, `ToolChoiceNone`,
cache control, headers). EP-7 lands first; EP-8 rebases on its result. Neither plan may
change the other's region without a Decision Log entry in both.

`Baikai.Usage` field semantics are defined by EP-4: `inputTokens` excludes
`cacheReadTokens` (the Anthropic convention), documented on the record's haddock, and
every provider mapping must satisfy it. EP-7 and EP-8 tests that touch usage must
assert the EP-4 semantics. The `requiresThinkingAsText` compat flag is consumed by
EP-7 (it is reasoning extraction), while every other `Baikai.Compat` flag is EP-8's
responsibility; EP-8 must not delete `requiresThinkingAsText` as "unused" once EP-7
has wired it.

The public export surface is shared by EP-9 (adds helpers) and EP-10 (sets constructor
export policy, renames `_Context`/`_Options`/`_Model`, moves internals). EP-10 owns the
final surface; EP-9 should add new helpers to the existing module structure and let
EP-10 relocate them if needed.


## Progress

- [x] EP-1 M1: workers always signal — sink/log failures captured and reported once, no hang
- [x] EP-1 M2: collision-free 64-bit event ids
- [x] EP-1 M3: synthetic terminal on early abort; OTel unknown-id drop documented
- [x] EP-2 M1: path sanitization and CRLF-safe frontmatter stripping
- [x] EP-2 M2: truthful status — scan-keyed sidecars, dirty+outdated and delisted states
- [x] EP-2 M3: robust install (staged writes + rollback), truthful uninstall, loud update failures
- [x] EP-3 M1: `--` option terminator at all four launch sites, argv builders unit-tested
- [x] EP-3 M2: system prompt sent through the codex batch provider
- [x] EP-3 M3: concurrent stderr drain and exception-safe cleanup for codex
- [x] EP-4 M1: `Usage` invariant defined and documented in core (disjoint token classes)
- [x] EP-4 M2: OpenAI mapping normalized with wire-payload regression tests
- [x] EP-5 M1: event algebra reshaped (ThinkingEndPayload, responseId carriage) and workspace compiling
- [x] EP-5 M2: full-fidelity reassembly (terminal-authoritative content)
- [x] EP-5 M3: protocol and exception invariants (EventStart-first, sync-only catch, clamped latency)
- [x] EP-5 M4: validation, hand-off contract, living sections
- [x] EP-6 M1: one error contract in core (`responseError`, non-throwing dispatch, in-band lift)
- [x] EP-6 M2: Claude live classification via local SSE transport
- [x] EP-6 M3: OpenAI live classification, `content_filter`, codex CLI in-band
- [x] EP-6 M4: conformance sweep, documentation, changelog
- [x] EP-7 M1: Claude cap-safe `max_tokens` and per-generation thinking style
- [x] EP-7 M2: Claude stream fidelity and verbatim replay (signature, redacted, phantom tool calls)
- [x] EP-7 M3: OpenAI-compatible reasoning extraction
- [x] EP-7 M4: live proof and validation sweep
- [x] EP-8 M1: core groundwork — honest host detection, flag deletions, key-env table
- [x] EP-8 M2: OpenAI request shaping (every kept flag on the wire, zero-cap, delta keying)
- [x] EP-8 M3: Claude raw streaming path — verbatim tool schemas, tool_choice none, cache markers
- [x] EP-8 M4: transport options — manager cache, headers, timeout, per-host keys
- [x] EP-8 M5: truth pass and live evidence
- [x] EP-9 M1: honest message timestamps and a lawful `Context`
- [ ] EP-9 M2: tool loop, one-shot completion, streamly-free streaming
- [ ] EP-9 M3: registry, auth, model-construction, and Options ergonomics
- [ ] EP-9 M4: living proof — smoke and worked examples rewritten on the new helpers
- [ ] EP-10 M1: constructor export policy, `_X` → `empty*`/`zero*` renames, consistency nits
- [ ] EP-10 M2: internal namespacing, Prelude policy, umbrella statement
- [ ] EP-10 M3: robustness cleanups (embeddings partial function, generator escaping/collisions)
- [ ] EP-10 M4: documentation sweep, CHANGELOG, version bumps


## Surprises & Discoveries

- Discovered while drafting EP-1 (verified in the streamly source, module
  `Streamly.Internal.Data.Stream.Exception`): `Stream.finallyIO` runs its cleanup
  synchronously only when the stream stops normally or a step throws. When the
  *consumer* abandons the stream (`Stream.take`, or an exception in the driving fold),
  the finalizer runs from a GC hook — eventually, not at abort time. Consequences:
  EP-1's synthetic abort terminal is delivered on GC, its tests must force
  `performMajorGC`; EP-5 and EP-10 must not document trace-terminal delivery on
  consumer abort as immediate; no future plan may rely on `finallyIO` for
  deterministic cleanup on early-stop. (2026-07-01, EP-1 planning)
- Discovered while drafting EP-3 (verified in the cradle source): the Claude batch CLI
  provider is already deadlock- and zombie-safe — cradle forks a reader thread per pipe
  and brackets with `cleanupProcess`. The stderr-flood/cleanup fixes are needed only on
  the codex side; the claude side gets a pinning regression test. Also verified:
  `codex exec --help` has no system-prompt flag, so EP-3 sends the system prompt by
  rendering it into the prompt text via a shared helper in
  `baikai/src/Baikai/Provider/Cli/Internal.hs`. (2026-07-01, EP-3 planning)
- Discovered while drafting EP-8 (verified in the claude SDK source): the SDK's typed
  `InputSchema` physically cannot carry `$defs`, `enum`, or `additionalProperties`, so
  the review's suggested fix for tool-schema mangling ("build the Tool value directly")
  is insufficient. EP-8 instead patches the encoded request `Value`, inserting the
  caller's JSON Schema verbatim — which is also what unlocks `tool_choice: none` and
  custom headers. This reinforced the decision to route Claude streaming through the
  baikai-owned SSE transport that EP-6 introduces. (2026-07-01, EP-8 planning)
- The two SSE-transport plans (EP-6, EP-8) were drafted in parallel and both specified
  a `Baikai.Provider.Claude.Sse` module; reconciled after drafting — EP-6 creates the
  modules, EP-8 extends them (`ssePostValue` with a classified `Either BaikaiError`
  callback; `claudeSseStream` becomes a typed wrapper). Recorded in EP-8's Decision Log
  and revision note. (2026-07-01, consistency pass)
- While implementing EP-1, the first early-abort regression exposed a sharper version
  of the streamly cleanup caveat: before `finallyIO`'s GC-driven finalizer writes the
  synthetic trace terminal, the trace worker blocked in `readChan` can be considered
  unreachable and killed with `BlockedIndefinitelyOnMVar`. EP-1 now keeps each active
  `TraceState` rooted with a `StablePtr` until `finalizeTrace` completes. Future
  documentation or cleanup work must preserve the "abort terminal is eventual but the
  worker remains rooted until finalization" invariant. (2026-07-03, EP-1
  implementation)
- While implementing EP-2, the expanded `baikai-kit` filesystem tests exposed that the
  suite's isolated-home helper was not safe under Tasty's default parallel execution:
  tests race through the process-wide `HOME` variable and can briefly operate on the
  real user home. EP-2 serializes the `baikai-kit` suite with `NumThreads 1` and
  restores `HOME` with `finally`. Future kit tests that mutate process-global
  environment should stay under that serial suite or use a different configuration
  injection strategy. (2026-07-03, EP-2 implementation)
- While implementing EP-5, the stream protocol type change exposed a positional
  `TerminalPayload` pattern in `baikai-smoke/test/Smoke.hs`, outside the initially
  listed four-suite compile-through. It was converted to a record pattern. Also
  verified in Streamly source that `Fold.foldlM'` supports a monadic initial state,
  which is what lets `reassembleResponse` capture its wall-clock start at fold start.
  (2026-07-03, EP-5 implementation)
- While implementing EP-6, the local Claude and OpenAI SSE transports became the durable
  seam for live HTTP classification because they preserve status, `Retry-After`, and
  response bodies that the SDK streaming callbacks drop. EP-8 must extend these modules
  for `Options.timeoutMs`, request headers, and host-specific transport behavior rather
  than reintroducing the SDK streaming path. (2026-07-03, EP-6 implementation)
- While implementing EP-7 M3, OpenAI-compatible replay was tightened to drop
  `AssistantThinking` blocks instead of serializing them as visible `<thinking>` text.
  EP-10's documentation sweep should describe provider-specific replay behavior:
  Anthropic can replay signed/redacted thinking; OpenAI-compatible providers keep only
  visible assistant text and tool calls. (2026-07-03, EP-7 implementation)
- EP-7's final smoke module is present and the full build/test sweep passed, but this
  environment lacked Anthropic and DeepSeek API keys. The new live thinking cases
  therefore skipped explicitly; a later keyed run should still be used to verify the
  Anthropic adaptive/budget table against the current provider API. (2026-07-03, EP-7
  implementation)


## Decision Log

- Decision: Adopt the in-band error contract everywhere (error-shaped `Response` /
  terminal `EventError`), rather than switching `completeRequest` to
  `IO (Either BaikaiError Response)`.
  Rationale: the streaming path already commits to in-band terminals and "partial
  output is always recoverable" (masterplan 4's decision log); making the blocking path
  `Either` would create a second shape for the same information and break every
  existing caller. The gap is closed instead by making the two throwing paths (CLI
  providers, unregistered-tag dispatch) conform, enforcing the
  `ErrorReason ⟹ errorInfo` invariant, and adding a `responseError` accessor. A
  throwing convenience wrapper can be added in EP-9 if callers want exceptions.
  Date: 2026-07-01
- Decision: Ten child plans in four waves, exceeding the preferred seven.
  Rationale: the review spans seven packages and three broken subsystems; merging
  further would create plans that touch unrelated modules or hide a small high-value
  billing fix (EP-4) behind the largest plan (EP-8). Waves keep at most five plans
  concurrent.
  Date: 2026-07-01
- Decision: EP-5 (event-protocol fidelity) placed in wave 1 and made a hard dependency
  of both EP-6 and EP-7.
  Rationale: three plans edit `baikai/src/Baikai/Stream.hs` and the event payloads;
  the algebra's final shape must exist before providers emit it, and serializing edits
  to the same functions avoids conflicting parallel work.
  Date: 2026-07-01
- Decision: `requiresThinkingAsText` is wired by EP-7, all other compat flags by EP-8.
  Rationale: reasoning extraction is functionally part of the thinking work stream even
  though the flag lives in `Baikai.Compat`; splitting by concern beats splitting by
  file. Recorded as an integration point so EP-8 does not delete the flag as unused.
  Date: 2026-07-01
- Decision: Intention `intention_01kwjgavf8e3ps2c49sn1qjr1m` linked to this initiative and
  all ten child plans.
  Rationale: created via `mina ci` after the fact; the same intention id is recorded in the
  frontmatter of the master plan and every EP so the initiative is tracked as one unit.
  Date: 2026-07-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


---

Revision note (2026-07-01): after the ten child plans were drafted (in parallel), the
Progress section was replaced with the plans' actual milestone titles, three
planning-time discoveries were recorded in Surprises & Discoveries (streamly `finallyIO`
GC-driven cleanup; cradle's already-safe Claude CLI handling; the claude SDK
`InputSchema` limitation), and the Integration Points section gained the agreed
`errorTerminal` signature sequencing between EP-5 and EP-6 plus the shared SSE-transport
seam that EP-6 creates and EP-8 extends. EP-8's plan file was edited in the same pass to
extend rather than re-create that seam (see its revision note).
