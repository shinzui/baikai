---
id: 102
slug: deliver-aborted-call-evidence-through-the-effectful-binding
title: "Deliver aborted-call evidence through the effectful binding"
kind: exec-plan
created_at: 2026-11-03T04:34:31Z
intention: intention_01m6gvw8ffepc88e68gqsesyc6
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-03T04:34:31Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-03T13:21:45Z
      verdict: "changes-requested"
      note: "Verified API shapes against Trace, Effectful, Registry; test filters named absent tasty groups, global test assumed unregister, strict capability validation conflicts with FRIC-2, capability growth needs a new record"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-03T13:21:45Z
      mode: "update"
      note: "Applied validation findings: fixed test filters, registry isolation, capability-record approach, bundle validation form, refusal mechanics, doc surfaces"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T14:09:47Z
      mode: "implement"
      note: "Implement fold-owned tracing, effectful collection, regression tests, and release preparation"
---

# Deliver aborted-call evidence through the effectful binding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Implement [IR-13](../improvement-requests/deliver-aborted-call-evidence-through-the-effectful-binding.md): an application using `Baikai.Effectful` can collect streamed events with a trace sink and, when cancelled, receive Baikai's own aborted-call evidence before the original exception reaches its handler, provided the sink completes within the existing bound. Prove this with a network-free provider and an acknowledgement read immediately in the caller's exception handler. Ship the operation in a tagged Hackage release; downstream adoption is separate work.

A trace sink is a fold that consumes tracing events in a worker thread. A `CallEvidence` event carries a `ModelCallEvidence` record describing the call; `CallAborted` is that record's status when collection ends before a terminal event. A terminal event is `EventDone` or `EventError`, ending the provider's event sequence. This plan adds no retry policy, synthetic cancellation terminal, blocking-completion abort support, or changes to `streamCollect` and `streamEach`. In core, the new primitive owns the trace lifetime around any fold; the existing synchronous wrapper `withTrace` is re-expressed on it and inherits the same cancellation guarantee, while `withTraceStream` keeps its documented general-stream contract.

## Progress


- [x] (2026-11-03) The fold, list, and response wrappers own tracing across the complete fold. The 847-case core suite passes, including cancellation inside providers, consumer steps, and early-fold cleanup; interrupted terminal cleanup resumes without a second budget or abort.
- [x] (2026-11-03) `StreamCollectTraced` and `streamCollectTraced` delegate to core. All 16 effectful tests pass (12 new traced cases, existing collection/callback/completion cases, and the explicitly skipped live case), including both interpreters, evidence identity, refusal before dispatch, opt-out, missing-record strictness, and healthy/blocked/throwing cancellation.
- [x] (2026-11-03) Haddock builds for both packages; CAP-32 and its compiled Shape agree; all 32 capability records pass required validation. ADR-15 now distinguishes fold ownership from general streams, and the README/Cabal operation inventories describe all four constructors. The full scrubbed offline gate passes all 12 suites; `cabal build all`, formatting, and `nix flake check` pass.
- [ ] Publish and tag `baikai 0.10.1.0` followed by `baikai-effectful 0.5.0.0`. Versions, changelog, lower core bound, README, CAP-32 availability, and both source archives are prepared. The user approved the concrete cohort on 2026-11-03. Release commit, tags, uploads, released-binding verification, and IR-13 delivery are now authorized and in progress.

## Surprises & Discoveries


2026-11-03: A custom exception sent with `throwTo` must belong to Haskell's asynchronous exception hierarchy to model cancellation. `liftCompleteToStream` correctly turns ordinary synchronous exceptions into terminal provider errors. The fixtures use `asyncExceptionToException` and `asyncExceptionFromException`, preserving a distinct payload without changing provider error handling.

2026-11-03: Cleanup ownership includes the first drain after an early-finishing fold, not just the stream drive. That wait can receive cancellation too. It now runs inside the same exception handler, and a deterministic sink-end barrier proves that its interrupted drain completes before propagation.

2026-11-03: Isolating CAP-32 removes the concepts its `requires` and body links reference. Strict checks therefore run in the full dependency context and assert that the only diagnostics are the 29 historical missing-`reviews` recommendations, with none for CAP-32. Required whole-bundle validation still passes. [FRIC-4](../friction-log/4-isolated-capability-validation-loses-required-concept-context.md) records and resolves the documentation workaround.

## Decision Log


2026-11-03: Put lifecycle ownership in `Baikai.Trace` and expose a list-collecting core function for the effectful interpreter. A plain `Stream.toList (withTraceStreamWith ...)` does not close the window outside stream steps. Reuse the existing evidence builder and terminal commitment logic so the binding cannot reconstruct provider-owned facts.

2026-11-03: Preserve the existing one-second sink-drain bound and worker-abandonment policy. A caller-owned acknowledgement is proof of delivery; absence after cancellation means delivery was not confirmed, and an abandoned worker may deliver later. Do not claim unconditional exactly-once delivery through a failing sink or replace the cancellation exception with a delivery error.

2026-11-03: Document the operation as a new capability record that `requires` CAP-20, CAP-9, and CAP-19, instead of editing CAP-20's `since`. The capabilities profile pinned in `docs/capabilities/profile.dhall` says material growth is recorded as a new capability so that a consumer pinning an older version is not misinformed. CAP-20 keeps `since: "0.1.0.0"`; only its text that calls three operations the whole surface changes.

2026-11-03: Make the core primitive fold-general and name the additions by the module's convention, superseding the list-only `collectTraceWith` shape in the first entry above. `withTraceFoldWith` owns the trace lifetime around any `Fold IO AssistantMessageEvent b`; `withTraceListWith` is that primitive applied to `Fold.toList`, and `withTraceWith` becomes that primitive applied to `reassembleResponse`, so the existing synchronous wrapper and `runRequestWithRegistry` gain synchronous finalization on cancellation at no extra cost. Each function has a global-registry sibling without the `With` suffix, as every other wrapper in the module does, and the list pair mirrors `streamRequestList` and `streamRequestListWith`. The effectful operation keeps its requested shape and delegates to `withTraceListWith`.

## Outcomes & Retrospective


2026-11-03: Implementation and local documentation acceptance are complete. The public effectful operation receives core-owned abort evidence before the caller handles cancellation with a healthy sink, preserves the original asynchronous exception, and bounds unconfirmed delivery through blocked or throwing sinks. Terminal evidence remains identical, opt-out remains silent, and legacy collection and callback operations retain their behavior. ADR-15 holds the durable ownership, deadline, and acknowledgement decisions.

The final offline gate ran under the supplied Nix toolchain with provider credentials and live flags unset and both `claude` and `codex` absent from PATH. All 12 suites passed: core 847, Claude 473, OpenAI 328, effectful 16, kit 116, agent 117, TypeSafe 11, OTel 11, plus smoke-options, the skipped live smoke programs, and doc-shapes (30 Haskell blocks, one KDL block, one intentional non-code skip). Full output is in `/tmp/baikai-plan102-tests-all.log`. `cabal build all`, Haddock for both changed packages, `cabal check` for each, `nix fmt`, `git diff --check`, the required bundle gates, dependency graphs, and host `nix flake check` pass. The first overlapping Haddock/test attempt was discarded after shared Cabal build metadata interfered; the accepted gate ran sequentially after Haddock finished.

Hackage package metadata and upstream annotated tags both identify the prior releases as core 0.10.0.0 and binding 0.4.0.5. The prepared cohort is core 0.10.1.0 (additive exports) and binding 0.5.0.0 (new exported effect constructor), with binding `baikai ^>=0.10.1`; unchanged sibling bounds already admit this core. The refreshed Hackage index admits the existing dependency bounds without source overrides. Both archives include their new Haskell test modules. Core’s source archive builds and passes all 847 tests outside the workspace against Hackage-only dependencies; its plan contains 187 registry-source entries and only core itself as a local source. The final archive files are `dist-newstyle/sdist/baikai-0.10.1.0.tar.gz` and `dist-newstyle/sdist/baikai-effectful-0.5.0.0.tar.gz`. The user approved publication under `agents/skills/release/SKILL.md` on 2026-11-03; IR-13 remains proposed until publication and released-package verification.

The user confirmed the prepared versions, changelog and documentation on 2026-11-03. The release sequence is to commit on `master` with both `ExecPlan:` and `Intention:` trailers, create annotated tags `baikai-0.10.1.0` and `baikai-effectful-0.5.0.0`, and follow the release skill in dependency order. Core archive verification is recorded in `/tmp/baikai-plan102-verify-core.log`; the extracted trees are named by `/tmp/baikai-plan102-verify-root`. After publishing core, run `cabal update`, confirm 0.10.1.0 appears in the refreshed index, and build and test the extracted binding with credentials, CLI binaries and live flags scrubbed. No workspace sibling or local repository may substitute for that released dependency. Only after binding publication and verification may IR-13 become delivered through its bundle workflow.

FRIC-4 is resolved: strict metadata checks retain the complete dependency context, distinguish the historical review baseline, and do not invent reviews for older records. No friction entry under this plan remains logged.

## Context and Orientation


`baikai-effectful/src/Baikai/Effectful.hs` exports the dynamic `Baikai` effect, constructors `Complete`, `StreamCollect`, `StreamCollectTraced`, and `StreamEach`, and interpreters `runBaikaiWith` (explicit registry) and `runBaikai` (global registry). A registry selects the provider implementation. `StreamCollect` currently drains `Baikai.streamRequestWith` without tracing. The new operation is a thin `liftIO` delegation to `withTraceListWith`. The module imports the umbrella `Baikai` module, which re-exports `Baikai.Evidence` and `Baikai.Evidence.Build` but not `Baikai.Trace`; the binding therefore adds an import of `Baikai.Trace` for `TraceSink` and for the new collector. `TraceSink` is defined in `baikai/src/Baikai/Trace/Sink.hs` as a newtype over a streamly `Fold IO TraceEvent ()` and is re-exported by `Baikai.Trace`.

`baikai/src/Baikai/Trace.hs` owns `TraceState`, the channel and sink worker, `traceEvent`, `commitTerminal`, `finalizeTrace`, and `sinkDrainBoundMicros = 1_000_000`. Its `closed` flag prevents duplicate channel closure, `finalized` tracks completed draining, and `drainDeadline` carries the shared monotonic sink deadline; `terminalSent` prevents an abort replacing an already committed terminal. `finalizeTrace` builds abort evidence using `Baikai.Evidence.Build` and the registered adapter's `describeThinking`. It sends the channel's shutdown sentinel, waits for the worker, reports sink errors on stderr, and releases a stable root that keeps the state alive. `withTraceStreamWith` installs cleanup through Streamly's `finallyIO`. This covers exceptions inside a stream step but can defer cleanup to garbage collection outside a step. Before this implementation `withTraceWith` folded that stream with `reassembleResponse` and had the same window. It now delegates to the fold owner, and `runRequestWithRegistry` builds on `withTraceWith`. A consumer's fold step runs between stream steps, so an exception that arrives while the fold step is executing is invisible to `finallyIO`; this is both the gap and the way to exercise it in a test. The initial allocation/fork sequence also needs exception-safe acquisition in the new collector.

`baikai/src/Baikai/Stream.hs` performs strict pre-dispatch refusal and missing-evidence enforcement. Do not duplicate those checks. A refusal happens inside `streamRequestWith` when `evidenceRefusals` in `baikai/src/Baikai/Provider/Registry.hs` finds that the request's required strength exceeds the provider's `strengthCeiling`, or that the adapter's thinking translation would weaken the requested level. `apiProviderWith` defaults the ceiling to `EvidenceRequestedOnly`, so a stub provider is refused by requesting `EvidenceRequired EvidenceCorrelated`. The refused stream is `EventStart` then `EventError`; its terminal carries an evidence record with status `CallFailed` and the `invalidRequest` refusal error. There is no separate refused status. `baikai/test/TraceSpec.hs` is the tasty group `Baikai.Trace` and covers existing trace semantics; its `terminalPathAtomicityTest` and `throwToAroundTerminalTest` already prove that an exception after terminal commitment adds no abort, and its `registerOkWithEvidence` fixture shows how a stub builds evidence with `Build.minimalEvidence`. `baikai-openai/test/ResponsesEvidenceSpec.hs` is the tasty group `Responses strict evidence over SSE bytes`; it already tests cancellation of a traced Responses stream, but waits for evidence after a timeout, which does not prove evidence is present at the instant the exception is observed.

`baikai-effectful/test/StubProvider.hs` registers a deterministic custom provider, with no evidence on its deterministic terminals. Separate evidence-aware and blocking fixtures now coexist with it; preserve the existing deterministic fixture used by `StreamSpec.hs`. `Baikai.Provider.Registry` exports only construction, registration, and lookup; nothing removes a registration, so a test that touches the global registry isolates itself with a unique `Custom` tag and leaves the entry registered, as every global-registry test in `baikai/test/TraceSpec.hs` does. Add `TracedStreamSpec.hs`, wire it in `baikai-effectful/test/Main.hs` and the Cabal test stanza. `baikai-effectful/test/LiveSpec.hs` is optional and gated by `BAIKAI_EFFECTFUL_LIVE`.

Relevant ADRs were discovered by scanning local filenames and titles. [ADR-3](../adr/0003-the-adapter-owns-the-translation-description.md) requires adapter-owned translation facts. [ADR-5](../adr/0005-what-baikai-deliberately-does-not-do.md) keeps retries and policy outside Baikai. [ADR-10](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md) makes the consumer responsible for producer cancellation; trace-worker cleanup is a separate concern. [ADR-14](../adr/0014-strict-evidence-means-a-record-exists.md) requires a record for strict successful calls and preserves provider failures. [ADR-15](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) establishes bounded waiting and garbage-collection-eventual cleanup for general streams. This plan adds fold-owning wrappers with a stronger guarantee without changing that general-stream contract. [ADR-17](../adr/0017-a-documented-example-compiles-in-the-test-suite.md) requires capability examples to match compiled smoke-test fixtures. [ADR-1](../adr/0001-architecture-decision-record-convention.md) records that `docs/adr/` is plain Markdown rather than a profiled OKF bundle; `mori show --full` lists six OKF bundles and `docs/adr` is not among them, so ADR edits keep the existing file format and the table in `docs/adr/README.md`.

The capability records in `docs/capabilities/` are governed by the remote `coordination.capabilities` profile pinned in `docs/capabilities/profile.dhall` (okf-profiles v0.9.0). That profile says that when a capability grows materially in a later release, the growth is recorded as a new capability that `requires` the old one, rather than by moving the old record's `since` forward. Strict validation of the whole bundle currently reports pre-existing missing recommended `reviews` metadata on older records; the friction entry [FRIC-2](../friction-log/2-capability-strict-validation-encounters-pre-existing-missing-review-metadata.md) records this, and the release procedure validates the bundle without `--strict`.

The request originates from `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-3`. Its other streaming work is tracked in `mori://shinzui/shikumi/plans/68-support-streamed-judgment-programs-with-typed-result-parity`; this plan neither depends on nor edits that implementation. No MasterPlan is assigned. The user requested a new intention through `mina ci --json`; the active ID is recorded in frontmatter and must accompany the release commit.

## Plan of Work


### Milestone 1: Own the complete trace collection lifetime


Add `withTraceFoldWith` to `baikai/src/Baikai/Trace.hs` with the interface below, together with its global-registry sibling `withTraceFold` and the list wrappers `withTraceList` and `withTraceListWith`, which apply the primitive to `Fold.toList`. The names follow the module's pairing of a global-registry function with a `With` variant and mirror `streamRequestList` and `streamRequestListWith` in `baikai/src/Baikai/Stream.hs`. Re-express `withTraceWith` as the primitive applied to `reassembleResponse`, keeping its signature, so the synchronous wrapper and `runRequestWithRegistry` inherit the owned lifecycle; `withTraceStream` and `withTraceStreamWith` keep their current behavior and contract. Extract shared initialization and stream decoration from `withTraceStreamWith`, retaining the existing stream wrapper's behavior. The primitive must acquire trace state, start the sink worker, and install its own cleanup handler under exception masking before restoring cancellation for the entire fold drive; prefer not to install `finallyIO` inside the primitive's stream, since the primitive owns cleanup. Its enclosing IO cleanup must run even when cancellation occurs between stream steps, including inside the caller's fold step; it must not depend on a garbage-collection hook. Keep ordinary provider execution and the caller's fold cancellable, and fork the sink worker so it does not inherit the masked state, for example with `forkIOWithUnmask`.

Reuse `traceEvent`, `commitTerminal`, and `finalizeTrace` rather than generating evidence in the binding. Audit the terminal-commit and finalization transitions: cancellation after terminal commitment preserves that terminal's evidence, while cancellation before commitment produces one abort record. An outer cleanup must not silently skip a drain that an interrupted inner finalizer already claimed. Make ownership and completion distinct if needed, and ensure all paths send the sentinel and release the stable root exactly once. Bound the total sink wait for this call, not each duplicate cleanup attempt. Never apply uninterruptible masking to user sink code or an unbounded wait. Preserve the original exception if abort cleanup itself fails; diagnostics must not replace it.

First prove the primitive in `baikai/test/TraceSpec.hs` with two cancellation cases. The first cancels during provider execution behind an entry barrier, so the exception lands inside a stream step. The second cancels while the caller's fold step is executing, which is between stream steps where `finallyIO` cannot see it: pass a fold such as `Fold.lmapM` over `Fold.toList` whose step signals a barrier and then blocks on the first event, and cancel the consumer once the barrier is signalled. This exercises the between-steps window through the public primitive, so no private test seam is needed; do not add one. In both cases observe evidence directly after exception propagation without forcing garbage collection or polling. Also prove that cancellation after a committed terminal does not add an abort, that `withTraceList` on the normal path yields the same events as `Stream.toList` of `withTraceStream`, and that the existing `withTrace` tests pass unchanged after it is re-expressed. Promote the shared lifecycle refactor only when these tests and existing trace tests pass.

### Milestone 2: Expose and exercise the effectful operation


Add `StreamCollectTraced` and `streamCollectTraced` in `baikai-effectful/src/Baikai/Effectful.hs`. Re-export `TraceSink` for convenient signatures, and interpret the constructor as a `liftIO` of `withTraceListWith`; `runBaikai` inherits this branch through its existing delegation. Retain the old operation branches unchanged. Add `TracedStreamSpec.hs` with the acceptance cases below, primarily through `runEff . runBaikaiWith reg`. Include one hermetic global-interpreter case through `runBaikai` that registers a provider under a unique `Custom` API tag used by no other test; the registry cannot remove a registration, so isolation comes from the tag and the entry stays registered, as in `baikai/test/TraceSpec.hs`.

Evidence-aware stub terminals must use Baikai's evidence construction helpers and honor opt-out; do not invent endpoint or translation fields. A provider invocation counter proves strict refusal happens before dispatch; trigger the refusal by requesting `EvidenceRequired EvidenceCorrelated` against the stub's default `EvidenceRequestedOnly` ceiling. A blocking fixture signals an entry barrier before cancellation and signals release from its cleanup. Use a typed exception with a distinct payload to prove the same exception reaches the caller. Test the public producer/consumer path early, before expanding the sink failure matrix.

### Milestone 3: Document the actual guarantee


Update the Haddock of both modules, including the `Baikai.Trace` module header, which currently describes only the garbage-collection-eventual abort path and defines `withTrace` as a fold of `withTraceStream`; describe the fold-owning primitive there and name the functions that inherit synchronous finalization. Update `baikai-effectful/README.md`. Also update the three places that enumerate the binding's operations as exactly three: the `description` in `baikai-effectful/baikai-effectful.cabal`, the `baikai-effectful` row of the package table in the root `README.md`, and the description and Limits of `docs/capabilities/effectful-binding.md` (CAP-20), which say three operations are the whole surface and that the API has not changed since 0.1.0.0. Explain all four effect constructors, opt-out, terminal/evidence identity, and the difference between the fold-owning wrappers and arbitrary stream abandonment.

Record the new operation as a new capability record rather than by moving CAP-20's `since`, because the house capabilities profile treats material growth as a new capability that `requires` the old one. Allocate its handle with `okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP` (CAP-32 at the time of writing; do not assume it), give it `requires` entries for CAP-20, CAP-9, and CAP-19 (the binding, call tracing, and model-call evidence), list `baikai-effectful` as its package and `Baikai.Effectful` as its interface, set its `since` to the binding release that ships the operation, and cite the new `TracedStreamSpec.hs` cases as its evidence. Give it a `## Shape` block whose compiled twin is a new `baikai-smoke/doc-shapes/Shape/CapN.hs` module listed in the `doc-shapes` stanza of `baikai-smoke/baikai-smoke.cabal`, so that a program importing `Baikai.Effectful`, supplying a sink, and calling `streamCollectTraced` compiles; leave `Shape/Cap20.hs` as the compiled twin of CAP-20's existing block. Touch `docs/capabilities/call-tracing.md` and `docs/capabilities/model-call-evidence.md` only where they describe abort delivery, so they point at the new record. Record each changed or added record in the bundle's `log.md` with `okf log add`, as the release procedure's `--log-enforce` check requires.

Describe the caller acknowledgement pattern: a short, nonblocking sink records the complete `CallEvidence` in a caller-owned cell before acknowledging it; the exception handler reads that cell. With a healthy sink the record is already present. With a blocked or throwing sink the operation still unwinds, the existing stderr diagnostic reports unconfirmed delivery, and absence in the cell means unconfirmed rather than impossible future delivery. Later arrival is possible after worker abandonment. Exactly-once refers to Baikai submitting one evidence event, not guaranteed durable external delivery. Providers that omit evidence retain ADR-14 behavior; the collector must not fabricate a successful record for them.

Revise ADR-15 to distinguish the fold-owning wrappers (`withTraceFold`, `withTraceList`, `withTrace`, and their `With` variants) from general streams (`withTraceStream` and `withTraceStreamWith`), preserving its general-stream caveat and one-second policy, and amend its advice that a caller who needs the record must drain to the terminal, since a fold-owning wrapper now also delivers it on cancellation. Update its row in `docs/adr/README.md` if its title changes. The ADR corpus is plain Markdown under ADR-1; re-check `mori show --full` before editing in case a `docs/adr` bundle has since been declared, and follow that descriptor if so. Finish the ADR distillation pass before declaring implementation complete.

### Milestone 4: Publish a coherent cohort


Prepare and execute the repository release procedure in `agents/skills/release/SKILL.md` when release work is authorized. Adding an exported effect constructor is a PVP major change because third-party interpreters must handle it. Before implementation the working tree had `baikai-effectful 0.4.0.5` and core `baikai 0.10.0.0`; Hackage metadata and upstream tags verified those prior releases. The prepared targets are binding 0.5.0.0 and core 0.10.1.0. Verify Hackage and upstream tags before choosing final versions. Every sibling package bounds core as `baikai ^>=0.10.0`, which admits a `0.10.1.0` core, so no sibling needs a release for the core change alone. The additive core exports normally need a minor increment, and re-expressing `withTraceWith` keeps its signature, so it is a changelog behavior note rather than a version signal; the binding needs a major increment and a lower core bound that includes the new export. Publish core before the binding, and release other packages only where changed code or internal bounds require it.

Update package changelogs, the root README Hackage table, capability release references and bundle logs using the release procedure. Build source distributions and prove they resolve using only released Hackage dependencies, without source overrides. Record actual versions, per-package tags, and successful upload/verification evidence here. Mark IR-13 delivered only after publication and validation through its bundle workflow. Do not close the downstream request or modify Shikumi's bounds. If publication is outside the implementation session's authorization, leave this milestone explicitly pending with a concrete release-ready handoff.

## Concrete Steps


Run from the repository root. Enter the supplied toolchain and run the focused checks after each relevant milestone:

```bash
nix develop
cabal test baikai:baikai-test --test-option=-p --test-option='/Baikai.Trace/' --test-show-details=always
env -u BAIKAI_EFFECTFUL_LIVE cabal test baikai-effectful:baikai-effectful-test --test-show-details=always
cabal test baikai-openai:baikai-openai-test --test-option=-p --test-option='/Responses strict evidence/' --test-show-details=always
cabal test baikai-smoke:doc-shapes --test-show-details=always
cabal haddock baikai baikai-effectful
```

Each command must exit zero and run the intended cases; a zero-case filter is not evidence. The tasty patterns name the groups as the files declare them: `baikai/test/TraceSpec.hs` is the group `Baikai.Trace` and `baikai-openai/test/ResponsesEvidenceSpec.hs` is the group `Responses strict evidence over SSE bytes`. Neither module name appears in a test path, so a filter on the module name runs nothing. The effectful suite should explicitly skip the live provider test and pass `TracedStreamSpec`, `StreamSpec`, and `CompleteSpec`. Add the new module to the Cabal manifest before running it.

For documentation and final local verification:

```bash
nix fmt
git diff --check
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
nix flake check
```

Validate the capability bundle in the form the release procedure uses. Adding `--strict` to the whole-bundle command reports pre-existing missing recommended `reviews` metadata on older records (FRIC-2), so strict validation is evidence only for the new record. As FRIC-4 explains, preserve dependency context and classify the known baseline rather than isolating the file:

```bash
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce > /tmp/baikai-plan102-capabilities-strict.log 2>&1
python3 - <<'PY'
from pathlib import Path
lines = Path('/tmp/baikai-plan102-capabilities-strict.log').read_text().splitlines()
assert len(lines) == 29
assert all('reviews' in line and 'missing' in line and 'traced-effectful-collection' not in line for line in lines)
print('CAP-32 has no strict diagnostics; only the historical reviews baseline remains.')
PY
```

Run the complete release test gate using the credential- and CLI-scrubbed command in `agents/skills/release/SKILL.md`, also unsetting `BAIKAI_EFFECTFUL_LIVE`. Inspect the resolved PATH to ensure neither `claude` nor `codex` can run before launching all tests. Capture full output and preserve command exit status. Follow the same skill for archive checks, version verification, bundle validation, tags, and upload; do not substitute a local build for published-package verification.

## Validation and Acceptance


For success and provider terminal failure with evidence requested, the sink sees exactly one `CallEvidence`, equal to the terminal's evidence including its `callId`. Strict pre-dispatch refusal produces one `CallEvidence` whose record has status `CallFailed` and carries the refusal error, with no provider invocation. No evidence request produces no `CallEvidence`. Existing untraced collection and incremental callbacks retain their behavior, demonstrated by the existing tests. The re-expressed `withTrace` keeps its normal-path behavior, demonstrated by the existing trace tests.

Cancel after a provider-entry barrier with a distinct asynchronous exception. On entering the caller's exception handler, assert that the sink already contains exactly one `CallAborted` record and the original exception payload is unchanged. Prove provider cleanup with its release barrier and trace-worker completion using the sink fold's end action. No garbage collection or delayed evidence polling is permitted for this assertion. Repeat the assertion with a fold whose step blocks, covering the window outside stream steps through the public primitive. Cancellation after terminal commitment must retain one terminal record, never a second abort.

Use separate blocked-sink and throwing-sink fixtures. Both preserve cancellation and finish within a generous outer watchdog, such as three seconds; the production sink-drain budget remains one second. Measure elapsed cleanup time with a monotonic clock and allow scheduler tolerance. Always unblock test-owned sink barriers in fixture cleanup, then verify any eventual arrival does not duplicate the event. Missing acknowledgement is explicitly unconfirmed delivery, with the diagnostic exercised. Test strict and best-effort evidence modes so abort cleanup never replaces cancellation with an evidence error. Existing trace sink-failure tests must still prove normal strict-success rewriting and provider-error preservation.

The final user-facing proof is an effectful program that imports the public operation, supplies a sink, runs under `runBaikaiWith`, and observes the exact abort record without importing stream functions or wrapping a registry. Publication acceptance additionally requires the released binding to resolve against its released core dependency and the tag to identify the tested source.

## Idempotence and Recovery


Local builds and tests can be rerun. Keep fixture barriers under cleanup so failures leave no blocked test threads. Preserve the old stream operations and general tracing semantics while refactoring shared internals; use their regression tests to recover from an incorrect lifecycle change. Do not widen the API to work around an unresolved race: fix ownership and rerun the deterministic boundary test. Never overwrite an existing package version or move a published tag; after a partial cohort release, verify what exists and resume only unpublished packages under the release procedure. Keep release-dependent milestones open until evidence is available.

## Interfaces and Dependencies


The intended public additions are:

```haskell
-- baikai/src/Baikai/Trace.hs

-- The fold-owning primitive: one traced call, drained by the caller's fold,
-- with trace cleanup owned by this function rather than by a stream hook.
withTraceFold ::
  TraceSink -> Model -> Context -> Options -> Fold IO AssistantMessageEvent b -> IO b
withTraceFoldWith ::
  ProviderRegistry -> TraceSink -> Model -> Context -> Options -> Fold IO AssistantMessageEvent b -> IO b

-- The list wrappers: the primitive applied to Fold.toList.
withTraceList ::
  TraceSink -> Model -> Context -> Options -> IO [AssistantMessageEvent]
withTraceListWith ::
  ProviderRegistry -> TraceSink -> Model -> Context -> Options -> IO [AssistantMessageEvent]

-- Existing, re-expressed as the primitive applied to reassembleResponse; signatures unchanged.
withTrace ::
  (MonadUnliftIO m) => TraceSink -> Model -> Context -> Options -> m Response
withTraceWith ::
  (MonadUnliftIO m) => ProviderRegistry -> TraceSink -> Model -> Context -> Options -> m Response

-- baikai-effectful/src/Baikai/Effectful.hs
StreamCollectTraced ::
  TraceSink -> Model -> Context -> Options -> Baikai m [AssistantMessageEvent]

streamCollectTraced ::
  (Baikai :> es) =>
  TraceSink -> Model -> Context -> Options -> Eff es [AssistantMessageEvent]
```

These signatures were checked against the working tree on 2026-11-03: every named type exists; `Fold` is `Streamly.Data.Fold.Fold` from `streamly-core`, which core already depends on and which `reassembleResponse` already returns; `TraceSink` is exported by `Baikai.Trace` and defined in `Baikai.Trace.Sink`; `ProviderRegistry` comes from `Baikai.Provider.Registry`; and the constructor has the shape `effectful-core` expects for a dynamic effect. The primitive returns `IO`, as `streamRequestListWith` does, and the `MonadUnliftIO` wrappers lift it. The four new core functions must be added to the export list of `Baikai.Trace`; the umbrella `Baikai` module does not re-export that module.

No new dependency is planned. Use existing `base` concurrency and exception facilities, `streamly-core` folds, and `effectful-core` dynamic dispatch. The Mori-discovered source for `mori://composewell/streamly/packages/streamly-core` confirms that stream-step handlers cannot guarantee cleanup outside a step; the source for `mori://effectful/effectful/packages/effectful-core` confirms the existing interpreter delegation pattern. Locate these through `mori registry search`, `mori registry show --full`, and `mori registry docs` before further API work. Never search the Nix store. Keep existing dependency bounds unless registry and upstream-tag verification justifies a necessary change. Current local corpus contents alone are not evidence of a released version.

## Revision Notes


2026-11-03: Validation pass against the working tree. Corrected the focused test filters, which named tasty groups that do not exist; removed the assumption that a global-registry test can unregister a provider, which the registry does not support; aligned capability-bundle validation with the release procedure and FRIC-2; moved the new operation's documentation into a new capability record as the house profile requires; and added the refusal mechanics, the umbrella-module import fact, the sibling core bounds, and the enumerating documentation surfaces an implementer must update.

2026-11-03: At the user's request, made the core primitive fold-general and renamed the additions to the module's convention: `withTraceFold` and `withTraceFoldWith` own the lifecycle around any fold, `withTraceList` and `withTraceListWith` apply it to `Fold.toList`, and `withTraceWith` is re-expressed on it so the existing synchronous wrapper inherits synchronous finalization on cancellation. Replaced the planned private test seam with a public fold-step barrier test, since a fold step runs between stream steps.

2026-11-03: Implementation records fold cleanup ownership across early-stop finalization as well as stream steps, and replaces the isolated strict-capability workaround with full-context diagnostic classification (FRIC-4). Release preparation names the registry-verified cohort, while publication acceptance stays open pending the release skill’s concrete confirmation.
