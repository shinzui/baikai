---
id: 102
slug: deliver-aborted-call-evidence-through-the-effectful-binding
title: "Deliver aborted-call evidence through the effectful binding"
kind: exec-plan
created_at: 2026-11-03T04:34:31Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-03T04:34:31Z
---

# Deliver aborted-call evidence through the effectful binding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Implement [IR-13](../improvement-requests/deliver-aborted-call-evidence-through-the-effectful-binding.md): an application using `Baikai.Effectful` can collect streamed events with a trace sink and, when cancelled, receive Baikai's own aborted-call evidence before the original exception reaches its handler, provided the sink completes within the existing bound. Prove this with a network-free provider and an acknowledgement read immediately in the caller's exception handler. Ship the operation in a tagged Hackage release; downstream adoption is separate work.

A trace sink is a fold that consumes tracing events in a worker thread. A `CallEvidence` event carries a `ModelCallEvidence` record describing the call; `CallAborted` is that record's status when collection ends before a terminal event. A terminal event is `EventDone` or `EventError`, ending the provider's event sequence. This plan adds no retry policy, synthetic cancellation terminal, blocking-completion abort support, or changes to `streamCollect` and `streamEach`.

## Progress


- [ ] Scoped core collection finalizes tracing synchronously on cancellation, including between stream steps, with bounded sink cleanup and unchanged exception propagation.
- [ ] The public effectful operation passes hermetic evidence, refusal, cancellation, sink-failure, and compatibility tests.
- [ ] Haddock, capability examples, and ADR context describe the verified delivery contract and pass documentation checks.
- [ ] A coherent Hackage-only package cohort is released and tagged, with release evidence recorded here.

## Surprises & Discoveries


## Decision Log


2026-11-03: Put lifecycle ownership in `Baikai.Trace` and expose a list-collecting core function for the effectful interpreter. A plain `Stream.toList (withTraceStreamWith ...)` does not close the window outside stream steps. Reuse the existing evidence builder and terminal commitment logic so the binding cannot reconstruct provider-owned facts.

2026-11-03: Preserve the existing one-second sink-drain bound and worker-abandonment policy. A caller-owned acknowledgement is proof of delivery; absence after cancellation means delivery was not confirmed, and an abandoned worker may deliver later. Do not claim unconditional exactly-once delivery through a failing sink or replace the cancellation exception with a delivery error.

## Outcomes & Retrospective


## Context and Orientation


`baikai-effectful/src/Baikai/Effectful.hs` exports the dynamic `Baikai` effect, constructors `Complete`, `StreamCollect`, and `StreamEach`, and interpreters `runBaikaiWith` (explicit registry) and `runBaikai` (global registry). A registry selects the provider implementation. `StreamCollect` currently drains `Baikai.streamRequestWith` without tracing. The new operation must remain a thin `liftIO` delegation.

`baikai/src/Baikai/Trace.hs` owns `TraceState`, the channel and sink worker, `traceEvent`, `commitTerminal`, `finalizeTrace`, and `sinkDrainBoundMicros = 1_000_000`. Its `closed` flag prevents duplicate finalization; `terminalSent` prevents an abort replacing an already committed terminal. `finalizeTrace` builds abort evidence using `Baikai.Evidence.Build` and the registered adapter's `describeThinking`. It sends the channel's shutdown sentinel, waits for the worker, reports sink errors on stderr, and releases a stable root that keeps the state alive. `withTraceStreamWith` installs cleanup through Streamly's `finallyIO`. This covers exceptions inside a stream step but can defer cleanup to garbage collection outside a step. The initial allocation/fork sequence also needs exception-safe acquisition in the new collector.

`baikai/src/Baikai/Stream.hs` performs strict pre-dispatch refusal and missing-evidence enforcement. Do not duplicate those checks. `baikai/test/TraceSpec.hs` covers existing trace semantics. `baikai-openai/test/ResponsesEvidenceSpec.hs` already tests cancellation of a traced Responses stream, but waits for evidence after a timeout; that does not prove evidence is present at the instant the exception is observed.

`baikai-effectful/test/StubProvider.hs` registers a deterministic custom provider, currently with no evidence on its terminals. Extend it with separate evidence-aware and blocking fixtures; preserve the existing deterministic fixture used by `StreamSpec.hs`. Add `TracedStreamSpec.hs`, wire it in `baikai-effectful/test/Main.hs` and the Cabal test stanza. `baikai-effectful/test/LiveSpec.hs` is optional and gated by `BAIKAI_EFFECTFUL_LIVE`.

Relevant ADRs were discovered by scanning local filenames and titles. [ADR-3](../adr/0003-the-adapter-owns-the-translation-description.md) requires adapter-owned translation facts. [ADR-5](../adr/0005-what-baikai-deliberately-does-not-do.md) keeps retries and policy outside Baikai. [ADR-10](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md) makes the consumer responsible for producer cancellation; trace-worker cleanup is a separate concern. [ADR-14](../adr/0014-strict-evidence-means-a-record-exists.md) requires a record for strict successful calls and preserves provider failures. [ADR-15](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) establishes bounded waiting and garbage-collection-eventual cleanup for general streams. This plan adds a stronger scoped collector without changing that general-stream contract. [ADR-17](../adr/0017-a-documented-example-compiles-in-the-test-suite.md) requires capability examples to match compiled smoke-test fixtures.

The request originates from `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-3`. Its other streaming work is tracked in `mori://shinzui/shikumi/plans/68-support-streamed-judgment-programs-with-typed-result-parity`; this plan neither depends on nor edits that implementation. No MasterPlan or intention is assigned.

## Plan of Work


### Milestone 1: Own the complete trace collection lifetime


Add `collectTraceWith` to `baikai/src/Baikai/Trace.hs` with the interface below. Extract shared initialization and stream decoration from `withTraceStreamWith`, retaining the existing stream wrapper's behavior. The collector must acquire trace state, start the sink worker, and install its cleanup handler under exception masking before restoring cancellation during the entire list drain. Its enclosing IO cleanup must run even when cancellation occurs between stream steps; it must not depend on a garbage-collection hook. Keep ordinary provider execution cancellable and ensure the forked sink does not accidentally inherit a permanent masked execution state.

Reuse `traceEvent`, `commitTerminal`, and `finalizeTrace` rather than generating evidence in the binding. Audit the terminal-commit and finalization transitions: cancellation after terminal commitment preserves that terminal's evidence, while cancellation before commitment produces one abort record. An outer cleanup must not silently skip a drain that an interrupted inner finalizer already claimed. Make ownership and completion distinct if needed, and ensure all paths send the sentinel and release the stable root exactly once. Bound the total sink wait for this call, not each duplicate cleanup attempt. Never apply uninterruptible masking to user sink code or an unbounded wait. Preserve the original exception if abort cleanup itself fails; diagnostics must not replace it.

First prove the scoped collector using `baikai/test/TraceSpec.hs`: barrier-controlled cancellation during provider execution, and a private test seam around the collection loop to force cancellation outside a stream step. A test seam must not become a public API or permit application callbacks in this operation. Observe evidence directly after exception propagation without forcing garbage collection or polling for evidence. Also prove that cancellation after a committed terminal does not add an abort. Promote the shared lifecycle refactor only when these tests and existing trace tests pass.

### Milestone 2: Expose and exercise the effectful operation


Add `StreamCollectTraced` and `streamCollectTraced` in `baikai-effectful/src/Baikai/Effectful.hs`. Re-export `TraceSink` for convenient signatures, and interpret the constructor using `collectTraceWith`; `runBaikai` inherits this branch through its existing delegation. Retain the old operation branches unchanged. Add `TracedStreamSpec.hs` with the acceptance cases below, primarily through `runEff . runBaikaiWith reg`. Include one hermetic global-interpreter case using a unique custom API tag and restoring/removing its registration on cleanup so it cannot interfere with other tests.

Evidence-aware stub terminals must use Baikai's evidence construction helpers and honor opt-out; do not invent endpoint or translation fields. A provider invocation counter proves strict refusal happens before dispatch. A blocking fixture signals an entry barrier before cancellation and signals release from its cleanup. Use a typed exception with a distinct payload to prove the same exception reaches the caller. Test the public producer/consumer path early, before expanding the sink failure matrix.

### Milestone 3: Document the actual guarantee


Update Haddock, `baikai-effectful/README.md`, `docs/capabilities/effectful-binding.md`, `docs/capabilities/call-tracing.md`, and `docs/capabilities/model-call-evidence.md`. Explain all four effect constructors, opt-out, terminal/evidence identity, and the difference between scoped collection and arbitrary stream abandonment. Update `baikai-smoke/doc-shapes/Shape/Cap20.hs` alongside the capability Shape so a program using `streamCollectTraced` compiles. Record the new operation's release version separately from the original binding's introduction version.

Describe the caller acknowledgement pattern: a short, nonblocking sink records the complete `CallEvidence` in a caller-owned cell before acknowledging it; the exception handler reads that cell. With a healthy sink the record is already present. With a blocked or throwing sink the operation still unwinds, the existing stderr diagnostic reports unconfirmed delivery, and absence in the cell means unconfirmed rather than impossible future delivery. Later arrival is possible after worker abandonment. Exactly-once refers to Baikai submitting one evidence event, not guaranteed durable external delivery. Providers that omit evidence retain ADR-14 behavior; the collector must not fabricate a successful record for them.

Revise ADR-15 to distinguish this scoped collector from general streams, preserving its general-stream caveat and one-second policy. Inspect `mori show --full` before ADR edits; if the ADR bundle has become profiled, follow its descriptor and strict validation, otherwise retain the current plain Markdown format. Finish the ADR distillation pass before declaring implementation complete.

### Milestone 4: Publish a coherent cohort


Prepare and execute the repository release procedure in `agents/skills/release/SKILL.md` when release work is authorized. Adding an exported effect constructor is a PVP major change because third-party interpreters must handle it. The current working tree has `baikai-effectful 0.4.0.5` and core `baikai 0.10.0.0`; these are observations, not registry-verified release targets. Verify Hackage and upstream tags before choosing final versions. The additive core export normally needs a minor increment; the binding needs a major increment and a lower core bound that includes the new export. Publish core before the binding, and release other packages only where changed code or internal bounds require it.

Update package changelogs, the root README Hackage table, capability release references and bundle logs using the release procedure. Build source distributions and prove they resolve using only released Hackage dependencies, without source overrides. Record actual versions, per-package tags, and successful upload/verification evidence here. Mark IR-13 delivered only after publication and validation through its bundle workflow. Do not close the downstream request or modify Shikumi's bounds. If publication is outside the implementation session's authorization, leave this milestone explicitly pending with a concrete release-ready handoff.

## Concrete Steps


Run from the repository root. Enter the supplied toolchain and run the focused checks after each relevant milestone:

```bash
nix develop
cabal test baikai:baikai-test --test-options='-p TraceSpec' --test-show-details=always
env -u BAIKAI_EFFECTFUL_LIVE cabal test baikai-effectful:baikai-effectful-test --test-show-details=always
cabal test baikai-openai:baikai-openai-test --test-options='-p ResponsesEvidenceSpec' --test-show-details=always
cabal test baikai-smoke:doc-shapes --test-show-details=always
cabal haddock baikai baikai-effectful
```

Each command must exit zero and run the intended cases; a zero-case filter is not evidence. The effectful suite should explicitly skip the live provider test and pass `TracedStreamSpec`, `StreamSpec`, and `CompleteSpec`. Add the new module to the Cabal manifest before running it.

For documentation and final local verification:

```bash
nix fmt
git diff --check
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --strict --profile-enforce --log-enforce
nix flake check
```

Run the complete release test gate using the credential- and CLI-scrubbed command in `agents/skills/release/SKILL.md`, also unsetting `BAIKAI_EFFECTFUL_LIVE`. Inspect the resolved PATH to ensure neither `claude` nor `codex` can run before launching all tests. Capture full output and preserve command exit status. Follow the same skill for archive checks, version verification, bundle validation, tags, and upload; do not substitute a local build for published-package verification.

## Validation and Acceptance


For success and provider terminal failure with evidence requested, the sink sees exactly one `CallEvidence`, equal to the terminal's evidence including its `callId`. Strict pre-dispatch refusal produces one refused record with no provider invocation. No evidence request produces no `CallEvidence`. Existing untraced collection and incremental callbacks retain their behavior, demonstrated by the existing tests.

Cancel after a provider-entry barrier with a distinct asynchronous exception. On entering the caller's exception handler, assert that the sink already contains exactly one `CallAborted` record and the original exception payload is unchanged. Prove provider cleanup with its release barrier and trace-worker completion using the sink fold's end action. No garbage collection or delayed evidence polling is permitted for this assertion. Repeat the core boundary-seam test to cover the window outside stream steps. Cancellation after terminal commitment must retain one terminal record, never a second abort.

Use separate blocked-sink and throwing-sink fixtures. Both preserve cancellation and finish within a generous outer watchdog, such as three seconds; the production sink-drain budget remains one second. Measure elapsed cleanup time with a monotonic clock and allow scheduler tolerance. Always unblock test-owned sink barriers in fixture cleanup, then verify any eventual arrival does not duplicate the event. Missing acknowledgement is explicitly unconfirmed delivery, with the diagnostic exercised. Test strict and best-effort evidence modes so abort cleanup never replaces cancellation with an evidence error. Existing trace sink-failure tests must still prove normal strict-success rewriting and provider-error preservation.

The final user-facing proof is an effectful program that imports the public operation, supplies a sink, runs under `runBaikaiWith`, and observes the exact abort record without importing stream functions or wrapping a registry. Publication acceptance additionally requires the released binding to resolve against its released core dependency and the tag to identify the tested source.

## Idempotence and Recovery


Local builds and tests can be rerun. Keep fixture barriers under cleanup so failures leave no blocked test threads. Preserve the old stream operations and general tracing semantics while refactoring shared internals; use their regression tests to recover from an incorrect lifecycle change. Do not widen the API to work around an unresolved race: fix ownership and rerun the deterministic boundary test. Never overwrite an existing package version or move a published tag; after a partial cohort release, verify what exists and resume only unpublished packages under the release procedure. Keep release-dependent milestones open until evidence is available.

## Interfaces and Dependencies


The intended public additions are:

```haskell
-- baikai/src/Baikai/Trace.hs
collectTraceWith ::
  ProviderRegistry -> TraceSink -> Model -> Context -> Options -> IO [AssistantMessageEvent]

-- baikai-effectful/src/Baikai/Effectful.hs
StreamCollectTraced ::
  TraceSink -> Model -> Context -> Options -> Baikai m [AssistantMessageEvent]

streamCollectTraced ::
  (Baikai :> es) =>
  TraceSink -> Model -> Context -> Options -> Eff es [AssistantMessageEvent]
```

No new dependency is planned. Use existing `base` concurrency and exception facilities, `streamly-core` folds, and `effectful-core` dynamic dispatch. The Mori-discovered source for `mori://composewell/streamly/packages/streamly-core` confirms that stream-step handlers cannot guarantee cleanup outside a step; the source for `mori://effectful/effectful/packages/effectful-core` confirms the existing interpreter delegation pattern. Locate these through `mori registry search`, `mori registry show --full`, and `mori registry docs` before further API work. Never search the Nix store. Keep existing dependency bounds unless registry and upstream-tag verification justifies a necessary change. Current local corpus contents alone are not evidence of a released version.
