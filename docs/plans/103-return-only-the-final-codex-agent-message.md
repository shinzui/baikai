---
id: 103
slug: return-only-the-final-codex-agent-message
title: "Return only the final Codex agent message"
kind: exec-plan
created_at: 2026-11-13T23:08:47Z
intention: "intention_01m7bjpm6gec59r6fd1w91vxmz"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-13T23:08:47Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T23:51:21Z
      mode: "implement"
      note: "Implement final completed-message selection, regression coverage, and release preparation"
---

# Return only the final Codex agent message

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction with `agents/skills/exec-plan/record-friction.ts` under `agents/skills/exec-plan/FRICTION.md`. Before completion, distill durable decisions into `docs/adr/` under `agents/skills/exec-plan/ADR.md`.


## Purpose / Big Picture

A caller requesting structured JSON through the Codex CLI provider must receive the final answer even when Codex emits intermediate commentary. Affected Baikai releases join complete messages together, so two independently valid JSON objects become invalid adjacent JSON. This breaks consumers such as Mina's plan explain commands, which can report `MissingField "why"` even though every original object contains that field.

Fix [BUG-2](../bug-reports/codex-concatenates-complete-agent-messages.md) by selecting the last completed agent message while continuing to collect thread identity and token usage from the entire event stream. Prove the behavior through the public provider using a fake executable that needs neither credentials nor Codex. The work finishes with a published correction and successful consumer checks; creation of this document does not execute those later steps.


## Progress

- [x] Milestone 1 (2026-11-13): the sanitized two-object fixture returns only the final object through public Codex dispatch. Before the fix, 9/21 parser and 9/22 public-provider cases failed, including whole-body JSON decoding; afterwards all 21 parser and 22 provider cases passed.
- [x] Milestone 2 (2026-11-14 UTC): compatibility, malformed-answer, evidence, synthetic-stream, and lifecycle regressions pass. Complete affected suites passed 857 core, 339 OpenAI, and 473 Claude cases. Doc-shapes passed (30 Haskell blocks, one KDL block, one existing skip); capability/user/bug profiles and `git diff --check` passed. The CLI guide, CAP-15, BUG-2 progress, changelog, and ADR 0030 document the correction.
- [ ] Milestone 3: publication and all candidate consumer checks pass. Durable Mina adoption remains pending a coordinated shared runtime/cohort update; its existing branch keeps the old coherent dependency selection, and the tested update is preserved as a reviewable patch.

Implementation handoff (2026-11-14 UTC): local implementation is `1923517`; release commit `7a1d45ee7437e5f572cec741bcf68e464a3e43c2` is pushed. Both annotated tags (`baikai-0.10.1.1`, `baikai-openai-0.7.3.1`) peel to that commit. Both source packages and Haddock archives are published on Hackage, and matching GitHub releases exist. Isolated core tests pass 857 cases; isolated adapter tests pass 339 cases, with its solver plan selecting core 0.10.1.1 as a `repo-tar` from the signed Hackage repository. No workspace sibling supplies the core in that check. The downloaded published core archive matches the uploaded SHA-256. Publication was explicitly approved by the user before the release commit and uploads.

Consumer handoff (2026-11-14 UTC): the targeted Mina candidate resolves released core 0.10.1.1, adapter 0.7.3.1, Shikumi 0.5.1.0, and compatible effectful binding 0.4.0.5 at Hackage index-state `2026-11-14T00:37:57Z`. All 34 explain examples pass, including both positive final-briefing checks. Complete Mina core (1,803 examples, zero failures, two existing pending), CLI (1,050 examples, zero failures), and golden suites pass. The candidate binary passes Kotei MP-27 and ExecPlan 127 cold, repeat, preview-miss, and preview-hit commands using the original codex-cli / gpt-5.6-luna / high settings. A fresh private cache grows from zero to two entries; repeated/preview reads preserve entry hashes and modification times.

Durable adoption is pending a scope decision on a new shared runtime/cohort. Advancing the cutoff changes metadata hashes of three runtime-owned packages despite identical versions, archives, and flags. Mina ADR-36 requires atomic Cabal/Nix adoption with source-aware parity, so the current coherent consumer configuration is retained. The tested formatted patch and validation JSON are preserved under `mori://shinzui/mina`, project-relative `docs/plans/evidence/260-published-codex-adoption.patch` and `docs/plans/evidence/260-published-codex-validation.json` (artifact-level URIs pending), coordinated by `mori://shinzui/mina/plans/260-fix-missingfield-why-failures-in-plan-explain-commands`. The candidate patch applies with `git apply --unidiff-zero`. The production updater in `mori://shinzui/haskell-nix` has captured immutable Baikai/Shikumi group 12 and passed its warm/evaluation transaction, offline discovery check, and formatting; its metadata commit is local and not yet pushed. Full compiled matrix validation of that shared selection remains unexecuted.


## Surprises & Discoveries

Initial Mori registry discovery and `mori path` failed with a refused PostgreSQL socket (FRIC-6 in `docs/friction-log/`). Local `mori show --full` and `mori validate` work. A scoped sibling-checkout inspection found `mori://shinzui/mina` and verified its identity against `mori.dhall`; The originating plan and failure-asserting diagnostics were initially unchanged; its tested positive replacement is now preserved as the candidate patch described above. Registry access was subsequently recovered with a command-scoped `MORI_PG_CONNECTION_STRING` targeting the existing native socket `/Users/shinzui/.local/state/postgresql`; the inherited value targets a stale sungkyung-client socket. Global configuration is unchanged, and Baikai registration now succeeds.

Consumer adoption discovery (2026-11-14 UTC): Mina's current Cabal manifests require core `^>=0.8.0.0` and `mori://shinzui/shikumi/packages/shikumi` `^>=0.4.1.0`. Its imported cohort from `mori://shinzui/haskell-nix` (project-relative `cabal/cohort.freeze` at `e5a7c2c50080b3364f0f0fd667240c560596d0ed`; artifact-level URI pending) pins core 0.8.0.0, both adapters 0.7.1.1, and Shikumi 0.4.1.1 exactly. Those constraints cannot select the prepared correction. Published Shikumi 0.5.1.0 admits core `>=0.10.0.0 && <0.11` and adapter `>=0.7.3.0 && <0.8`; its upstream release tag peels to `7b96ecf06364b37de44b15c4f58b2528b5a3e0f5`. It still requires `baikai-effectful <0.5`, so do not upgrade every sibling to its newest version blindly. The targeted candidate solve reconciled the compatible released application family and passed positive diagnostics. The owning branch retains its prior source/bounds until atomic shared runtime adoption is ready.


Consumer metadata discovery (2026-11-14 UTC): the fresh candidate plan changes `pkg-cabal-sha256` for runtime-owned crypton-connection 0.4.6 (`a3764a44de9f...` to `8a5fdc00a76d...`), streamly 0.11.1 (`7b49316d922a...` to `5ea579ca2b04...`), and warp 3.4.16 (`f018481972d4...` to `ba90fc17687f...`). Their package archive hashes and flags are unchanged. This is a dependency-management integration prerequisite, independent of final-message extraction (FRIC-9 in `docs/friction-log/`). The existing shared runtime constructor compares runtime-owned source, metadata, flags, and policy, and the consumer ADR requires parity before atomic adoption. A new shared runtime/cohort requires a scope decision; do not weaken those checks to close this plan.



## Decision Log

- Decision: select the last completed `agent_message` from JSONL rather than introducing `--output-last-message` and a second temporary file. Rationale: Codex 0.169.0's own SDK follows this rule, the existing transport already reads the complete stream for observations, and the reported failure needs no command-line or process-lifetime change. Date: 2026-11-13.
- Decision: keep final-answer selection independent of whether its text parses as JSON. Rationale: a malformed final answer must not cause selection of an earlier valid object. Native schema enforcement remains Codex's responsibility; this correction does not introduce a JSON Schema validator. Date: 2026-11-13.
- Decision: release and consumer adoption remain required outcomes, tracked separately from the local fix. Rationale: the reporting consumer uses released dependencies and can continue to select a broken core even after a workspace test passes. Date: 2026-11-13.
- Decision: preserve the tested consumer update as a reviewable patch while the shared runtime/cohort update is scoped; retain the owning branch's coherent dependency selection. Rationale: all candidate behavior passes, but advancing the cutoff also changes three runtime-owned metadata hashes, and Mina requires atomic Cabal/Nix parity. Date: 2026-11-14 UTC.


## Outcomes & Retrospective

Local outcome (2026-11-14 UTC): callers of the public Codex provider receive only the last completed message, including empty or malformed final bodies, while thread, usage, evidence, typed failures, and owned cleanup retain their contracts. The original parser and provider regressions failed before the fix and pass afterwards; all 1,669 affected package tests and doc-shapes pass. ADR 0030 distills the durable rule that complete bodies are independent answers, separate from pipe byte chunks. No extra process or temporary-file lifecycle was introduced.

Release preparation outcome (2026-11-14 UTC): core `0.10.1.1` and adapter `0.7.3.1` are prepared but unpublished. All twelve offline workspace suites, `cabal build all`, both `cabal check` runs, formatting, Nix checks, and all requested manifest/profile/graph checks pass. Core source archive `dist-newstyle/sdist/baikai-0.10.1.1.tar.gz` has SHA-256 `237be7b8d652b7128b6a07b9afbf9177174585647b13ff60a99f3b255479f9a0`; its isolated directory is `/private/tmp/baikai-103-core-verify.8AXhdm/baikai-0.10.1.1`. Under the release skill's offline environment, `cabal build all --enable-tests` and `cabal test --test-show-details=always` passed there, including all 857 core cases. The source archive resolves released `tls 2.4.14` and `http-client-tls 0.4.0`, independently of the workspace's older compatible resolution. Documentation archive `dist-newstyle/baikai-0.10.1.1-docs.tar.gz` is ready. The adapter archive must still be created and verified against the published fixed core in release order after confirmation; no workspace override may substitute for that gate.

Publication outcome (2026-11-14 UTC): both releases, documentation archives, annotated tags, and GitHub releases are live. Adapter source SHA-256 is `8171b3cb291d8bbf3e7b34532161069aae8d2eaca1c9ea9c4520cb29f8e72563`; its isolated verification directory is `/private/tmp/baikai-103-openai-verify.047bFh/baikai-openai-0.7.3.1`. The solver selected the published fixed core and all 339 adapter tests passed. All candidate consumer regressions and live checks pass. Durable adoption remains unfinished under the runtime parity requirement, so BUG-2 remains confirmed.

FRIC-6 is accepted with the native-socket environment override, which restores registry discovery and registration without changing global settings. FRIC-7 is resolved: a scratch HTTPS Cabal config using the official hackage-content endpoint and curl transport obtains fresh signed metadata and published archives after primary-index lag and an HTTP mirror failure. Upload credentials and global Cabal configuration are unchanged.

Candidate consumer outcome (2026-11-14 UTC): the released correction works through Mina's actual judges and both public explain commands. The candidate's positive transport fixtures, whole core/CLI/golden suites, and cold/repeated/preview checks all pass. The tested source update is archived as a patch and is unapplied on the consumer's owning branch pending a coordinated runtime/cohort update. No live model call was used for offline suites; only the two cold public explain checks computed real briefings. Kotei's authored files and existing cache remain unchanged.

FRIC-8 is accepted: preserve the production updater's validation and reuse its completed result for unchanged metadata. FRIC-9 remains logged because the new shared runtime/cohort scope decision is pending. No new runtime generation has been created and this plan's final milestone is not complete.



## Context and Orientation

Baikai is a multi-package Haskell repository. `baikai` supplies shared types and helpers; `baikai-openai` registers the Codex subprocess provider under `OpenAICompletionsCli`. A subprocess provider launches a command-line program and converts its output into an ordinary `Response`. JSONL means one JSON document per line. An `agent_message` is a complete assistant message carried inside an event; it is not a fragment of its successor. This distinction is separate from operating-system pipe chunks, which can split any line at arbitrary byte boundaries.

In `baikai/src/Baikai/Provider/Cli/Internal.hs`, `parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport` splits and decodes lines, then folds them with `absorbCodexEvent`. The original `CodexAccumulator.messages` stored a reversed list of all extracted message texts, and `CodexRunReport.message` was built with `Text.concat (reverse ...)`. The correction replaces that private list with `lastMessage :: Maybe Text`, and returns its candidate or empty text when absent. `extractAgentMessage` recognizes the modern nested `item` shape, an older nested `msg` shape, and flat events. The original extractor did not distinguish `item.completed` from other outer event types; the correction requires that modern completion type while retaining the legacy shapes. The same fold retains the first thread identifier and the last usage report. Model observation is read only beside usage, never inferred from request arguments.

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, `runCodexCli` brackets the schema file, invokes `withOwnedProcess`, and calls `consume`. `consume` parses stdout, concurrently drains stderr through `withOwnedWorker`, waits for the process, and returns `Text.strip (report ^. #message)` on success. A nonzero exit still returns a typed process error and retains available observations. `codexCliProvider` exposes direct completion and a synthetic stream: completion runs first, then its answer is replayed as stream events through `liftCompleteToStream` from `baikai/src/Baikai/Stream.hs`. Thus both public paths must expose the same final answer. Preserve the existing outer-whitespace trimming at the provider boundary.

The regression belongs in `baikai/test/CliInternalSpec.hs` and `baikai-openai/test/StructuredCliSpec.hs`. The latter's `withFakeCodex` fixture already records the `--output-schema` file and runs the actual public dispatch path through an isolated registry. Its current `conformingEvents` emits only one message. `baikai-openai/test/CliEvidenceSpec.hs` checks observed usage, thread identity, and commitments. `baikai-openai/test/CliCancellationSpec.hs` checks completion, active synthetic-stream cancellation, evidence-probe ownership, and schema lifetime. Those modules are already registered in `baikai-openai/test/Main.hs` and `baikai-openai/baikai-openai.cabal`. `baikai/test/fixtures/codex-events.jsonl` is an existing sanitized single-message recording; retain it and add distinct multi-message fixtures or inline generated events.

[Plan 87](87-pass-structured-output-schemas-through-the-claude-and-codex-cli-providers.md) implemented `--output-schema` and promised final-message output, but its one-message tests could not distinguish selection from concatenation. [The user guide](../user/cli-providers.md) makes the same final-message promise. [CAP-15](../capabilities/subscription-cli-backends.md) records the batch provider contract. This correction restores that contract for plain text as well as `JsonSchema` requests; it does not require a new capability.

Local ADR headings and filenames were scanned. [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed facts to remain separate, so changing text extraction must not fill absent observations from configuration. [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md) preserves typed failure classification and leaves retries to callers. [ADR 0026](../adr/0026-batch-cli-cancellation-owns-process-groups-and-reader-workers.md) requires process groups and reader workers to finish cleanup before acknowledging cancellation; the schema file outlives that cleanup. [ADR 0001](../adr/0001-architecture-decision-record-convention.md) defines the current plain-Markdown ADR convention. The inspected `mori.dhall` declares no ADR bundle. Recheck the manifest before writing a new decision and follow any subsequently adopted profile.

Dependency lookup attempted `mori registry list` and `mori registry search codex` on 2026-11-13; both failed because Mori's local PostgreSQL socket refused connections. This limited registry discovery, not inspection of this repository. When Mori is available, use its registry search, full project metadata, docs, and canonical path resolution before further dependency investigation. The relevant upstream project is `mori://openai/codex`; its project-relative source paths are `sdk/typescript/src/thread.ts` and `codex-rs/exec/src/event_processor_with_jsonl_output.rs` (artifact-level source URIs pending). The released `rust-v0.169.0` tag was verified with `git ls-remote` and peels to `d32063f96c2dff1dc96af839b3952abb6acfeda4`. At that revision, the [SDK source](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/sdk/typescript/src/thread.ts) replaces `finalResponse` for each completed agent message; the [JSONL producer](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/exec/src/event_processor_with_jsonl_output.rs) likewise replaces its final-message candidate on completed agent messages. These sources support the selected extraction rule, without adding a dependency or choosing a new Codex version pin.

Consumer follow-up belongs to `mori://shinzui/mina/plans/260-fix-missingfield-why-failures-in-plan-explain-commands`. Its project is `mori://shinzui/mina`, with project-relative source `mina-core/test/Mina/PlanDigest/ExplainSpec.hs`, function `transportDiagnosis` (artifact-level source URI pending). BUG-2 reports that commit `03c14aa` contains two diagnostics asserting the current failure, one for each explain program. This plan creation has not independently rerun those tests. Do not interpret their current passing status as repaired behavior.


## Plan of Work

### Milestone 1: repair final-message selection through the public provider

Start with the exact sanitized two-message reproduction below. Add a parser assertion and a public `StructuredCliSpec` case requesting a native `JsonSchema` with required string fields `why`, `what`, `blocking`, and `status`, and `additionalProperties: false`. Reuse `withFakeCodex` and create a small event constructor with `Aeson.encode` to keep inner answer text separate from outer event JSON. Run the tests before changing the parser: they must fail because the answer contains both objects. This early public-provider check joins the real process launcher, schema forwarding, shared parser, and consumer-visible text before expanding edge cases.

Change `CodexAccumulator` to keep a single last-message candidate, initialized to no answer, rather than retaining every previous body. Each completed agent message replaces it, including an empty string. Build `CodexRunReport.message` from that candidate, using empty text only if none was seen, preserving the existing report type and no-message behavior. Update the record and parser Haddock so they no longer describe concatenation or message fragments. Leave the byte-chunk/newline assembly algorithm intact; it already avoids quadratic copying of long lines.

For modern `item` envelopes, only `type: item.completed` can replace the answer. `item.started` and `item.updated` are not completed answers, even if they contain text; unrelated reasoning, tool, and usage events cannot replace the candidate. Preserve recognized older flat `agent_message` and `msg`-nested `agent_message` events as complete messages, with last-message selection within those forms too. Do not tighten the unrelated thread and usage extractors. Run the focused commands in Concrete Steps and confirm that both regression tests pass and the public reply decodes to the final four-field object.

### Milestone 2: protect compatibility, evidence, and lifecycle behavior

Extend parser tests to cover three complete messages, plain-text commentary followed by JSON, a single answer, an empty final message, modern start/update events around completed messages, and both supported legacy shapes. Exercise message boundaries across pipe chunks and a final event without a newline. Keep existing non-JSON-line tolerance and the multi-megabyte performance regression. Crucially, a completed event with a valid outer JSON envelope whose inner final text is malformed JSON must still replace an earlier valid answer. The parser must neither inspect answer validity nor extract a JSON substring.

Extend the public provider tests with the single-answer case, multiple schema-conforming complete objects, prose commentary, no response format, and malformed final text. For the malformed case, emit an earlier valid object followed by final text such as `{"why":`; assert that the public answer is exactly that final text after the existing outer trim and that `Aeson.eitherDecodeStrict'` fails. A zero-exit fake can lie about schema enforcement; the test establishes faithful extraction, not a new provider-side validation promise. A complete final object with missing schema fields is similarly returned unchanged; Baikai does not silently recover an earlier object. Distinguish these cases from malformed outer JSONL lines, whose existing best-effort skip policy is unchanged.

Through public complete and synthetic-stream dispatch, assert that intermediate messages never enter the answer. Reassemble the stream with the existing response collector and compare its text with direct completion; check one final text block and the expected terminal event. In a multi-message run carrying thread and usage events, assert response identity, normalized usage, and evidence observations. For the same executable, options, thread, and usage, varying only the intermediate body must leave the final response commitment unchanged. Varying the final answer must change it. No evidence request still produces no evidence.

Retain nonzero-exit and rejected-`--output-schema` classification, including a fixture that emits an apparently valid answer before exiting nonzero. It must remain an error response and retain genuine thread/usage observations. Rerun cancellation and schema cleanup tests; this design adds no final-answer file or new process scope. Any implementation change introducing such a file is a consequential design revision and must first add explicit success, failure, and cancellation lifetime acceptance.

Update `docs/user/cli-providers.md` to explain that the last completed answer is returned and earlier messages are excluded. Update CAP-15's evidence to cite the positive multi-message tests, advance its timestamp and review metadata honestly, and add a bundle log entry with `okf log add`. Retain its original `since` field; record the correcting package versions in prose once known. Add an Unreleased entry to `CHANGELOG.md` and link BUG-2 to this plan. Keep BUG-2 open until the release/adoption evidence justifies its resolved status under `mori/bug-reports-profile.dhall`. Distill the durable rule that completed message bodies are alternatives rather than byte fragments into an ADR under the repository's current convention, updating `docs/adr/README.md`. Milestone acceptance is the focused and full offline package suites passing with documentation/profile checks valid.

### Milestone 3: publish the fix and verify the reporting consumer

Inspect authoritative Hackage package-version metadata and upstream release tags immediately before choosing versions or changing bounds; do not infer current releases from a local Cabal index or Mori corpus. Read and follow `agents/skills/release/SKILL.md` for the actual release, including source archives, offline test gates, documentation, bundle validation, and publication. This plan chooses no release numbers in advance. The current manifests are core `0.10.1.0` and adapter `0.7.3.0`; they are orientation facts, not an instruction to reuse or overwrite those versions.

Release the core correction first. Also release an adapter update whose library and test dependency lower bounds in `baikai-openai/baikai-openai.cabal` require the fixed core version. The current `baikai ^>=0.10.0` admits affected versions; releasing only a new core does not guarantee that consumers of a fresh adapter receive the repair. Preserve the existing compatible upper bound unless a separately justified API change requires otherwise. Check sibling bounds and publish other packages only if their own changes or bounds require it. Verify an out-of-workspace solver result from published archives actually selects a fixed core, not merely that a workspace build links local sources. Record the exact versions and tag commits in this plan and BUG-2.

In the consumer checkout located by `mori path mori://shinzui/mina`, inspect its current plan and test source before editing. Adopt the released versions through its established dependency configuration. Convert both `transportDiagnosis` expectations from `MissingField "why"` to a successfully decoded final briefing with `why = "Final"`, using the original native schema path and bounded attempt settings. Retain hermetic fake-executable coverage. Run the focused explain suite, then the two public explain commands under the original cold-cache, repeated, and preview settings recorded by the consumer's originating plan. Use a test-owned or fresh cache through the consumer's documented configuration; do not delete the user's cache. Record exact commands, package versions, cache state, and outcomes when this stage is reached. Cache hits alone cannot close the milestone.

If consumer access, its live authentication, or publication is unavailable, record the specific missing evidence and leave this milestone open. Preserve local acceptance separately from release and adoption. At completion, triage any implementation friction, finish the ADR distillation pass, and fill Outcomes & Retrospective with the demonstrated outcomes and remaining limitations.


## Concrete Steps

Run implementation commands from this repository's root. Enter the supplied GHC/Cabal environment, then run the focused suites. The patterns below name existing Tasty test groups; Tasty is the test runner, and a zero-case selection is not a passing regression check.

```bash
nix develop
cabal test baikai:baikai-test --test-option=-p --test-option='/codex exec --json event stream/' --test-show-details=always
cabal test baikai-openai:baikai-openai-test --test-option=-p --test-option='/StructuredCliSpec/' --test-show-details=always
cabal test baikai-openai:baikai-openai-test --test-option=-p --test-option='/CliEvidenceSpec/' --test-show-details=always
cabal test baikai-openai:baikai-openai-test --test-option=-p --test-option='/CliCancellationSpec/' --test-show-details=always
```

The first two commands must demonstrate the new two-message failures before the fix and pass afterwards. The evidence and cancellation groups must continue to pass. No command above invokes a real Codex or model. At the milestone boundary, run the complete affected package suites, plus the Claude suite because it shares the internal helper module:

```bash
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test --test-show-details=always
cabal test baikai-smoke:doc-shapes --test-show-details=always
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
okf validate docs/bug-reports --strict --profile mori/bug-reports-profile.dhall --profile-enforce --log-enforce
git diff --check
```

Expect exit zero and nonempty intended test selections. Follow current bundle conventions for timestamp, review, and log updates; diagnose existing validation failures rather than relaxing the profile or fabricating an independent review. Before publication, run the release skill's complete credential- and CLI-scrubbed offline gate, also unsetting `BAIKAI_EFFECTFUL_LIVE`, and its build/format/archive checks. A bare `cabal test all` can run live smoke calls when keys or agent binaries are present, so use that established offline command when broadening to all packages.

When the released fix has been adopted, run this command from the consumer repository root, then the broader explain checks described in Milestone 3:

```bash
cd "$(mori path mori://shinzui/mina)"
cabal test mina-core:test:mina-core-test --test-options='--match "decodes the final briefing through the Codex transport"'
```

That selector names the positive candidate checks. Apply the preserved adoption patch before running it; the owning branch still carries the original failure diagnostics until durable adoption. The candidate is based on consumer commit `03c14aa`. Passing old exception assertions is not acceptance. Exact live command flags and cache controls must be read from the consumer's current source/help and originating plan at execution time rather than guessed here; they do not block the local hermetic milestones.


## Validation and Acceptance

The minimal input to the fake executable is:

```jsonl
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"why\":\"Intermediate\",\"what\":\"X\",\"blocking\":\"B\",\"status\":\"S\"}"}}
{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\"why\":\"Final\",\"what\":\"X\",\"blocking\":\"B\",\"status\":\"S\"}"}}
```

The public completion response and collected synthetic stream must both contain exactly:

```json
{"why":"Final","what":"X","blocking":"B","status":"S"}
```

Require whole-body JSON decoding and equality with the final object; substring matching would allow the original defect to pass. The captured schema must still equal the requested strict schema, and its temporary file must be absent after the call. A single final answer must retain its existing result. An empty final body replaces preceding commentary. A malformed final inner body remains malformed and is never replaced with a valid earlier body. Plain-text calls follow the same message-selection rule. Chunk boundaries, legacy event nesting, unknown/non-JSON lines, and long-event processing retain their existing behavior except for the intentional modern completion-event filter.

Thread identity still comes from the first reported identifier, usage from the last reported accounting event, and absence stays unobserved. Success evidence commits to the selected final answer. Nonzero exits remain failures regardless of emitted answers, and cancellation still propagates only after owned subprocess and worker cleanup, with the schema file removed afterwards. These observations must be demonstrated by hermetic tests, not inferred from compilation.

Full acceptance additionally requires authoritative publication verification, an adapter dependency bound that excludes broken core versions, positive consumer diagnostics for both plan kinds, and cold/repeated/preview consumer checks under the original settings. Keep those outcomes visibly pending until executed.


## Idempotence and Recovery

Local tests use private temporary directories and isolated registries and can be rerun safely. Preserve the existing owned-process scopes and schema bracket; do not add detached workers or name-based process termination. If a new filter breaks a legacy fixture, retain explicit legacy recognition instead of returning to concatenation. If final-answer selection fails, retain the smallest failing fixture and fix that behavior before extending other cases. Never repair an invalid final answer by selecting an earlier object or weakening the schema request.

Do not replace published package versions, move existing release tags, or roll back unrelated working-tree changes. Resume a partial release by verifying what is already published and finishing only missing steps under the release procedure. Keep local, release, and consumer evidence distinct. Every implementation commit must use a Conventional Commit message with both `ExecPlan: docs/plans/103-return-only-the-final-codex-agent-message.md` and `Intention: intention_01m7bjpm6gec59r6fd1w91vxmz` trailers.


## Interfaces and Dependencies

Retain `Baikai.Provider.Cli.Internal.parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport` and the existing report fields `message :: Text`, `threadId :: Maybe Text`, `reportedModel :: Maybe Text`, and `usage :: Maybe Usage`. Only the private accumulation state and message-event eligibility need change. Retain `Baikai.Provider.OpenAI.Cli.codexCliProvider :: CodexCliConfig -> ApiProvider`, the command renderers, and the `NativeJsonSchema` capability. The process runner and public failure categories keep their existing contracts.

The implementation uses dependencies already present: `aeson` for outer event decoding, `bytestring` for stream chunks, `text` for answers, `streamly`/`streamly-core` for consumption, and the existing process and temporary-file helpers. No new dependency, Codex pin, final-answer file, or provider-neutral API is required. Use Mori source/docs discovery before changing any dependency APIs, and authoritative package registries and release tags before choosing bounds. This is a standalone ExecPlan with no parent MasterPlan; consumer follow-up is coordinated through the canonical Mina plan URI named above.
