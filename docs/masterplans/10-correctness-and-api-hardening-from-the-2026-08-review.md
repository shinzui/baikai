---
id: 10
slug: correctness-and-api-hardening-from-the-2026-08-review
title: "Correctness and API hardening from the 2026-08 review"
kind: master-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
---

# Correctness and API hardening from the 2026-08 review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The review recorded as REV-2 in `docs/reviews/correctness-and-api-review-follow-up.md`
re-examined every package at commit `c3753c5` (baikai, baikai-claude and baikai-openai
0.5.0.0, baikai-trace-otel and baikai-effectful 0.3.0.3, baikai-kit 0.1.0.4,
baikai-agent 0.1.0.0). It confirmed that the previous review's findings (REV-1,
`docs/reviews/correctness-and-api-review.md`, remediated by
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`) are fixed
and pinned, and it found one critical, twenty-three major, twenty-eight minor and sixteen
design defects, concentrated in code added or reshaped since July: the baikai-owned SSE
transports, the evidence and tracing surface, and `baikai-agent`. This initiative fixes
every finding in REV-2, in dependency order, so the library can be trusted for unattended
work and so the public surface can be frozen.

When the initiative is complete, the following user-visible behaviours hold. The shipped
`baikai` executable runs on the threaded runtime, so `baikai agent run` with a `timeout`
actually stops a hung agent, escalates to SIGKILL, keeps the output it drained, and writes
its result as UTF-8 regardless of locale. A `Model.baseUrl` with an `@` anywhere after the
authority can no longer select another host's API key or compatibility record; a header
that carries a credential is redacted wherever baikai prints or serialises `Options`,
`Model` or `Response`; embeddings resolve their key through the same per-host table as
chat calls; and a redirect never forwards a bearer token. A thinking request on
`claude-sonnet-5` — or any Anthropic model the catalog marks adaptive — sends the
adaptive shape and drops sampling parameters the generation rejects, recording the
adjustment in evidence, because the thinking style and sampling support are fields of
the generated catalog record rather than a hand-written prefix table. Every error stream
from every provider begins with `EventStart` and ends with exactly one terminal; a
consumer that stops reading cancels the worker and releases the connection; a tool call
cut off by the output cap is never delivered as a well-formed call with empty arguments.
A connection reset mid-body, a chunked-encoding EOF, and an in-band `{"error": …}` frame
on a 2xx stream all classify as the retryable or typed failure they are. An evidence
record states the thinking level the caller asked for on every path, strict evidence mode
fails a call whose terminal carries no record, and the OpenTelemetry span reports the model
the provider observed, never the one the caller requested. A trace sink that blocks or
throws cannot hang the call or corrupt its sibling sinks, and the timing of the synthetic
abort terminal is documented. The unattended-run policy ceiling gates every field a
repository can set, treats `allowedTools` as the permission grant it is on Claude Code,
and the guide describes exactly which operator inputs choose the ceiling file.
`baikai-kit` refuses a symlinked source, installs every listed file, and never exits the
host process from library code. Finally, the public surface sheds its constructor exports
on evolvable records, its two-majors-overdue deprecated shims, and its partial record
selectors, and every capability `Shape`, guide and Haddock describes the code that ships.

Out of scope: new provider integrations; the MCP work in
`docs/masterplans/6-mcp-support-across-the-agent-stack.md`; the improvement requests IR-4
and IR-5 in `docs/improvement-requests/` (system-prompt replace-versus-append and Ctrl-C
delegation), which are separate proposals; per-TTL cache-write pricing beyond what the
wire reports; and any change not traceable to a finding in REV-2 or to a residual REV-2
recorded against a REV-1 item. Where a fix would require changing the MercuryTechnologies
`claude` or `openai` SDKs, a plan may bypass the SDK type locally (as the July work did
with the SSE transports and shaped request bodies) but does not fork it; where a bypass
is impossible, the limitation is recorded in the plan's outcome. Live verification
against Anthropic (the thinking and sampling parameters) requires a key this initiative
does not assume; every plan that depends on it says what the keyed run must show.


## Decomposition Strategy

REV-2 groups its findings into nine themes (A transport and classification, B streaming
lifecycle, C thinking and request shaping, D evidence and tracing, E secrets, F kit and
agent, G public surface, H documentation, I tests). The plans below follow functional
concern rather than theme or package, because several themes span packages (a cut-off
tool call is closed the same wrong way in both provider assemblers; the host parse lives
in core but misdirects keys in both transports) and because the same file is often the
seam for two unrelated concerns (both provider `Api.hs` modules hold the worker lifecycle,
the assembler, the evidence assembly and the usage mapping). Test-coverage findings
(Theme I) are distributed to the plan that owns the code under test rather than collected
in a plan of their own, because a pin written apart from the fix it pins tends to pin the
wrong thing.

Eleven plans exceed the preferred seven, so they are grouped in four implementation
waves. Wave 1 holds six plans with no dependencies on each other: the coding-agent
runtime and surfaces (EP-1), host parsing and credential hygiene (EP-2), catalog-driven
thinking style (EP-3), stream lifecycle and protocol conformance (EP-4), the unattended
policy ceiling (EP-6), and baikai-kit (EP-7). Wave 2 holds the three plans that build on
wave-1 seams: mid-stream classification (EP-5) after the worker and terminal shape are
settled by EP-4; evidence truthfulness (EP-8) after EP-4 fixes the `immediateError` paths
it must also thread thinking descriptions through; and trace-sink robustness (EP-9) after
EP-8, because both edit `baikai/src/Baikai/Trace.hs`. Wave 3 is the surface freeze
(EP-10), which must cover every name the earlier plans add or move. Wave 4 is the
documentation sweep (EP-11), which must describe final behaviour and final names and
therefore hard-depends on EP-10.

Alternatives considered. A per-package split (one plan per package) was rejected because
the four highest-severity defects each span two or three packages and would have forced
the same decision to be made twice. A per-theme split (one plan per REV-2 theme) was
rejected because Theme A and Theme B both edit the provider assemblers, which is the
single most contended file in the initiative, and because Theme F mixes a runtime defect
in `baikai-agent` (the RTS) with a policy-model defect (the ceiling) that different people
would sensibly own. Folding EP-9 (sink robustness) into EP-8 (evidence truthfulness) was
rejected to keep the evidence semantics — which touch the documented contract in
`docs/adr/0002-…` through `0004-…` — separable from concurrency work in the same module.
A separate test plan was rejected as explained above. Folding the documentation sweep into
EP-10 was rejected because the sweep must also describe behaviour changed by every other
plan, and a freeze plan that also rewrites twelve capability records would be the
eighty-percent plan the decomposition principles warn against.

ADR context. The local corpus `docs/adr/` is a plain-file convention (see
`docs/adr/0001-architecture-decision-record-convention.md`; it is not a profiled OKF
bundle, so no handle allocation applies). Three records constrain this initiative:
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md` (the caller's request,
the adapter's translation, and the provider's observation are separate facts — EP-8 exists
because several paths collapse the first into "absent", and EP-3 must record dropped
sampling parameters as a translation, not silently); `docs/adr/0003-the-adapter-owns-the-translation-description.md`
(EP-8's threading of `describeThinkingFor` through core paths must call into the adapter
rather than re-derive); and `docs/adr/0004-two-digests-commitment-and-configuration.md`
(EP-8's decision on whether structured-output schemas belong in the configuration digest,
and on removing cost from the commitment digest, must be recorded as a revision of that
ADR). `docs/adr/0005-what-baikai-deliberately-does-not-do.md` bounds EP-5: baikai
classifies retryability but does not own retries. No cross-repository ADR applies; a Mori
search of `okf-profiles`, `mori`, `keiro` and `seihou` concepts for "threaded", "policy
ceiling", "deprecation" and "URL host" returned nothing relevant.

Decisions this initiative is expected to promote to ADRs, each owned by the plan that makes
it: a process-spawning executable ships on the threaded runtime (EP-1); there is one URL
host parser and every consumer uses it (EP-2); provider capability facts such as thinking
style and sampling support live in the generated catalog record and never in a hand
table (EP-3); a stream consumer that stops owns cancelling the producer (EP-4); the
unattended policy ceiling gates every field a repository can set, and `allowedTools` is a
grant (EP-6); library code never calls `exitFailure` (EP-7); strict evidence means a
record exists, not merely that the sink did not throw (EP-8); a deprecated name is
removed at the next major release after the one that deprecates it, and the changelog
states the version (EP-10).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Ship baikai-agent on the threaded RTS and fix the coding-agent surfaces | docs/plans/58-ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces.md | None | None | Complete |
| 2 | Unify host parsing and stop credential misdirection | docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md | None | None | Complete |
| 3 | Make Anthropic thinking style and sampling support catalog-driven | docs/plans/60-make-anthropic-thinking-style-and-sampling-support-catalog-driven.md | None | EP-2 | Complete |
| 4 | Make stream workers cancellable and error streams protocol-conformant | docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md | None | None | Complete |
| 5 | Classify mid-stream failures and in-band error frames | docs/plans/62-classify-mid-stream-failures-and-in-band-error-frames.md | None | EP-4 | Complete |
| 6 | Close the unattended-run policy ceiling | docs/plans/63-close-the-unattended-run-policy-ceiling.md | None | EP-1 | Complete |
| 7 | Make baikai-kit symlink-safe and exit-free | docs/plans/64-make-baikai-kit-symlink-safe-and-exit-free.md | None | None | Complete |
| 8 | Make evidence records truthful and strict mode strict | docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md | None | EP-3, EP-4 | Complete |
| 9 | Make trace sinks unable to hang or corrupt a call | docs/plans/66-make-trace-sinks-unable-to-hang-or-corrupt-a-call.md | None | EP-8 | In Progress |
| 10 | Freeze the public surface | docs/plans/67-freeze-the-public-surface.md | None | EP-1..EP-9 | Not Started |
| 11 | Bring the documentation back to the code | docs/plans/68-bring-the-documentation-back-to-the-code.md | EP-10 | EP-1..EP-9 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1, EP-2, EP-3, EP-4, EP-6 and EP-7 have no dependencies and may proceed in parallel.
They touch disjoint regions: EP-1 owns `baikai-agent/baikai-agent.cabal`,
`baikai-agent/app/Main.hs`, the process-lifecycle half of
`baikai-agent/src/Baikai/Agent/Run.hs` (`waitWithTimeout`, `terminateGroup`, output
retention), `baikai/src/Baikai/Provider/Cli/Internal.hs` (`parseCodexJsonlStream`),
`baikai/src/Baikai/AgentAssets.hs` (TOML rendering) and the codex approval-policy
rendering in `baikai/src/Baikai/Interactive.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`; EP-2 owns the URL parser in
`baikai/src/Baikai/Compat.hs` and its callers in `baikai/src/Baikai/Auth.hs`,
`baikai/src/Baikai/Evidence/Build.hs`, both `Transport.hs` modules and both `Sse.hs`
request builders, plus `baikai/src/Baikai/Embedding.hs` and the `Show`/`ToJSON` instances
of `Options` and `Model`; EP-3 owns the catalog generator (`baikai/gen/`, `baikai/fetch/`,
`data/models/`), `baikai/src/Baikai/Models/Generated.hs`, the thinking-style region of
`baikai/src/Baikai/Compat.hs` and `baikai/src/Baikai/Model.hs`, and
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`; EP-4 owns both provider
`Api.hs` modules (worker, assembler, `translate`, `immediateError` event shape) and the
reassembly fallbacks in `baikai/src/Baikai/Stream.hs`; EP-6 owns `baikai/src/Baikai/Agent.hs`,
both provider `Agent.hs` renderers, `baikai-agent/src/Baikai/Agent/Config.hs`,
`baikai-agent/src/Baikai/Agent/Cli.hs`, and the evidence/endpoint half of `Run.hs`; EP-7
owns `baikai-kit/`.

EP-3 soft-depends on EP-2 only because both edit `baikai/src/Baikai/Compat.hs`; the regions
are disjoint (the URL helpers at the bottom of the module against the thinking-style table
in the middle) and either order rebases cleanly.

EP-5 soft-depends on EP-4 because EP-4 rewrites the worker's `Left` path and the terminal
shape in both `Api.hs` modules, and EP-5's classification changes must land on the final
shape: EP-5 edits the classifier modules
(`baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs`,
`baikai-openai/src/Baikai/Provider/OpenAI/Internal/ErrorClass.hs`), `baikai/src/Baikai/Error.hs`,
the timeout helpers in both `Transport.hs`, and one bounded region of the OpenAI `Api.hs`
(`parseChunk`, lines 343–385 at `c3753c5`) to detect in-band error frames. Running EP-5
before EP-4 is possible with string-level assertions but would be rebased.

EP-6 soft-depends on EP-1 because both edit `baikai-agent/src/Baikai/Agent/Run.hs`: EP-1
owns the process-lifecycle functions and EP-6 the evidence `endpoint` resolution and the
`errorInfo` bound. Either order works; the later plan rebases.

EP-8 soft-depends on EP-4 because EP-8 must thread the adapter's thinking description
through both providers' `immediateError`, whose event shape EP-4 changes, and on EP-3
because EP-3 may extend the adjustment vocabulary EP-8 records. EP-8 can proceed first by
calling the existing `describeThinkingFor`; EP-4 then keeps the call when it reshapes the
function.

EP-9 soft-depends on EP-8 because both edit `baikai/src/Baikai/Trace.hs`: EP-8 owns the
evidence semantics (what is pushed, when strict mode fails) and EP-9 the worker and
finaliser mechanics (`terminalSent`, `finalizeTrace`, `multiSink`). Serialising them
avoids conflicting edits to `finalizeTrace` and the terminal paths.

EP-10 soft-depends on every code plan because the export policy, the `.Internal`
relocations and the shim removals must cover the names those plans add. It has no hard
dependency: a name added after EP-10 is simply held to the policy EP-10 establishes.

EP-11 hard-depends on EP-10 because the guides and capability records must name the final
exports (for example the replacement for `registerWith*` and the base value for
`ApiProvider`), and soft-depends on every other plan because it must describe their final
behaviour.


## Integration Points

The provider assemblers, `baikai-claude/src/Baikai/Provider/Claude/Api.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, are the most contended files. EP-4
owns them and lands first: it holds the worker `ThreadId` and cancels it, pre-seeds
`EventStart` on every Claude failure path, closes open blocks on a mid-stream `Left`, and
changes how a cut-off tool call is closed. EP-5 edits only the OpenAI `parseChunk` region
(error-frame detection) and calls the classifiers EP-5 owns. EP-8 edits only the
`immediateError` evidence content and the strength derivation. EP-3 edits only the usage
and cache-pricing mapping. EP-10 relocates the assembler types and seams behind
`.Internal` and must do so after the others. Any further change to these files must be
recorded here and in EP-4's Decision Log.

The cut-off tool-call contract is shared by EP-4 (both assemblers) and core reassembly in
`baikai/src/Baikai/Stream.hs`, which already keeps undecodable arguments as
`Aeson.String rawText` in its recovery path (`danglingBlocks`). EP-4 adopts that same
representation in both assemblers so the three layers agree; EP-10 documents it on
`ToolCall.arguments`, and EP-11 describes it in `docs/user/tools.md`.

The URL host parser is defined once by EP-2 (replacing `urlHost` in
`baikai/src/Baikai/Compat.hs` with the rule `dropUserInfo` in
`baikai/src/Baikai/Evidence/Build.hs` already implements: the last `@` before the first
`/` of the path) and consumed by `defaultApiKeyEnvForBaseUrl`, `autoDetectOpenAICompletions`,
`autoDetectAnthropicMessages`, `sanitizeEndpoint`, and the `ClientEnv` cache key. EP-3
must not reintroduce a second parser when it reads `baseUrl` for the thinking style.

The catalog record shape is owned by EP-3: it adds an Anthropic thinking-style field and
a sampling-support field to `Model` (or to `AnthropicMessagesCompat`, as EP-3 decides and
records), populates them from `data/models/anthropic.json` through the generator, and
removes or demotes `defaultAnthropicThinkingStyle`. EP-8 consumes the resulting
`ThinkingTranslation` unchanged; EP-10 must not export a constructor for the new record
fields; EP-11 documents the fields in `docs/user/models-and-providers.md`.

The evidence vocabulary in `baikai/src/Baikai/Evidence.hs` is shared by EP-3 (which may
add an adjustment for dropped sampling parameters), EP-8 (which unifies strength
derivation into one function and adds a strength ceiling to `ApiProvider`) and EP-10
(which decides whether `ModelCallEvidence(..)` and `EvidenceRequest(..)` keep exported
constructors). EP-8 owns the vocabulary; EP-3 adds its adjustment by extending the
existing `ThinkingAdjustment` sum (or the equivalent EP-8 defines, if EP-8 lands first)
and records the choice in both Decision Logs. `docs/adr/0002-…`, `0003-…` and `0004-…`
must be revised by EP-8 in the same change.

`baikai/src/Baikai/Trace.hs` is shared by EP-8 (evidence push and strict-mode failure)
and EP-9 (worker protocol, `terminalSent`, `finalizeTrace`, sink isolation). EP-8 lands
first; EP-9 rebases. The `TraceEvent` field semantics (`model` on `CallFinished` is the
requested id) are documented by EP-8 and consumed by the OpenTelemetry sink change EP-8
makes.

`baikai-agent/src/Baikai/Agent/Run.hs` is shared by EP-1 (process lifecycle) and EP-6
(evidence endpoint and `errorInfo` bound); the regions are disjoint and the later plan
rebases.

The unattended policy model (`AgentCeiling`, `AgentSafety`, `applyAgentCeiling` in
`baikai/src/Baikai/Agent.hs`, the KDL schema in `baikai-agent/src/Baikai/Agent/Config.hs`)
is owned by EP-6. EP-1's codex approval refusal lives in the interactive launcher, not the
unattended renderer, and does not touch this model. EP-10 must not add a base value or
change exports of these records without EP-6's field set being final.

Export lists and the `.Internal` namespace are owned by EP-10. Every earlier plan adds new
names to existing modules with a Haddock and leaves relocation to EP-10; a plan that must
hide something immediately (EP-8's strength setter) says so in its Interfaces section and
in EP-10's Decision Log.

Documentation is owned by EP-11 for the sweep, but every code plan updates the Haddock of
the functions it changes and the capability record that names the behaviour it changes,
so that EP-11 reconciles rather than discovers. Every code plan adds its `CHANGELOG.md`
entries under `[Unreleased]` in the same commits as the code.

Version bumps are owned by EP-10 (majors for the removals) and recorded once in
`CHANGELOG.md`; earlier plans do not bump versions.

Cross-plan decisions to promote to ADRs are listed at the end of Decomposition Strategy;
each is owned by the plan named there and is created in that plan's implementation.
Because every child plan was drafted against the same corpus (`docs/adr/0001` … `0005`),
several name `0006` as their record's number. The number is allocated at implementation
time in landing order — a plan takes the next free number when its ADR commit is made and
records the final path in its own Decision Log — and the slugs are the identity: EP-1
`a-process-spawning-executable-ships-on-the-threaded-runtime`, EP-2
`one-url-host-parser-and-every-consumer-uses-it`, EP-3
`provider-capability-facts-live-in-the-generated-catalog-record`, EP-4
`a-stream-consumer-that-stops-owns-cancelling-the-producer`, EP-5
`core-owns-transport-failure-classification`, EP-6 (the ceiling and `allowedTools` as a
grant), EP-7 `library-code-never-calls-exitfailure`, EP-8
`strict-evidence-means-a-record-exists`, EP-9
`trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual`, EP-10
`deprecated-names-are-removed-at-the-next-major`.

The following were settled after the child plans were drafted in parallel, and bind the
plans named (each plan's implementer reads this section before its first commit):

- Core takes a direct dependency on `http-client` (and `http-types`, `tls`,
  `servant-client`, `http-client-tls`) exactly once. EP-2 introduces it for
  `baikai/src/Baikai/Http.hs` (the shared `ClientEnv` cache) and EP-5 for
  `baikai/src/Baikai/Provider/Transport/Classify.hs`; whichever lands second reuses the
  stanza the first added. Both supersede plan 39's "core stays free of http-client"
  rationale, which rested on a false premise (core already links it through the `openai`
  SDK).
- New modules the surface freeze (EP-10) must cover: `Baikai.Url`, `Baikai.Http`,
  `Baikai.Header` (EP-10's own), `Baikai.Provider.Internal.StreamWorker` (EP-4, outside
  PVP like `Baikai.Provider.Cli.Internal`), `Baikai.Provider.Transport.Classify` (EP-5),
  `Baikai.Kit.Error` and `Baikai.Kit.Command` (EP-7), and the `.Internal.Stream` modules
  EP-10 creates by moving each provider's `Api.hs`.
- The header map. EP-2 hand-writes redacting `Show`/`ToJSON` instances for `Options` and
  `Model` over the existing `Map Text Text`; EP-10 later changes the key type to
  `HeaderName` (case-insensitive) with `ToJSONKey`. EP-10 keeps EP-2's redaction marker
  and rule when it rewrites the instances; the redaction test EP-2 adds must still pass.
- The evidence schema version is owned by EP-8 and ends at
  `baikai.model-call-evidence/2.0` (the commitment digest's content changes). EP-3's two
  additive `ThinkingAdjustment` constructors (`SamplingDroppedUnsupportedModel`,
  `SamplingDroppedUnsupportedApi`) ride whichever bump is current: if EP-3 lands first it
  sets `1.1` and EP-8 then sets `2.0`, naming both changes in the `2.0` note; if EP-8 lands
  first EP-3 adds no bump. EP-8's strict gate consults EP-3's `weakensThinking` so a
  dropped sampling parameter never refuses a strict call.
- `finalizeTrace` in `baikai/src/Baikai/Trace.hs` gains a `ProviderRegistry` first
  parameter in EP-8 (to call the registered adapter's `describeThinking` on the abort
  path); EP-9's `commitTerminal` and bounded wait are written against that signature.
  EP-8 words `Build.sinkFailureError` as "its record was not confirmed written", which
  is accurate for both a throwing sink (EP-8) and a stalled one (EP-9's
  `TraceSinkStalled`).
- The cut-off tool-call contract is EP-4's: `Baikai.Content.toolArgumentsFromText`,
  `isCutOffToolCall`, `runToolLoopWith` stopping with the response intact, and
  `appendToolResult` appending an `isError = True` result rather than dispatching. EP-10's
  separate guard — `appendToolResult` leaves the context unchanged when
  `responseError resp` is `Just` — composes with it (a cut-off call is a `Length` stop,
  not an error-shaped response). EP-11 documents both in `docs/user/tools.md`.
- `Aborted` is retired by EP-10. EP-4's cancellation design kills the worker and
  releases the connection; it produces no `Aborted` terminal, so the alternative branch in
  EP-10's Milestone 3 does not apply.
- `ErrorCategory` gains `ContentFiltered` in EP-10; EP-5 leaves `content_filter` as
  `OtherError` and records the question, as agreed.
- `baikai-agent`'s policy model changes are EP-6's: `policy.allowed-tools`,
  `policy.max-timeout`, `policy.max-output-limit`, `repositoryRoot` on
  `AgentConfigPaths`, the violations `ToolGrantForbidden`, `RepositoryScopeForbidden`,
  `WorkingDirOutsideRepository`, `UnknownPolicySetting`, the `outputFormat` field, the
  `envPassthrough` → `envRequires` rename, the deletion of `OutputMalformed` and exit 70,
  and the removal of `BAIKAI_AGENT_EXECUTABLE` from the environment layer. EP-1's
  `AgentTimedOut` record is the only other `baikai/src/Baikai/Agent.hs` change; EP-10's
  `emptyAgentConfigPaths` base value is written after EP-6's field lands.
- `CHANGELOG.md`. A released section is never rewritten in place. A correction to a
  released entry is a dated addition inside that section ("entry added 2026-08-27; the
  behaviour shipped in 0.5.0.0") so the record of what was said at release time survives;
  new behaviour goes under `[Unreleased]`. EP-8 and EP-11 both touch the 0.5.0.0
  section and follow this rule.
- Version bumps remain EP-10's: baikai, baikai-claude, baikai-openai 0.6.0.0;
  baikai-trace-otel 0.4.0.0; baikai-kit 0.2.0.0; baikai-agent 0.2.0.0; baikai-effectful
  0.3.0.4 (EP-9 only drops the `streamly` dependency); the release is cut after EP-11.


## Progress

- [x] EP-1 M1: `baikai` executable on the threaded RTS, proven by a spawned-binary timeout test
- [x] EP-1 M2: SIGKILL escalation, drained output kept on timeout, UTF-8 output regardless of locale
- [x] EP-1 M3: unexpressible codex approval policies refused as `SafetyNotExpressible`
- [x] EP-1 M4: linear-time JSONL line assembly and correct TOML escaping for agent assets
- [x] EP-2 M1: one URL host parser, used by compat detection, key resolution, evidence and the client cache
- [x] EP-2 M2: header credentials redacted in `Show`/`ToJSON`; empty key env vars are `AuthError`
- [x] EP-2 M3: embeddings resolve keys per host and share the `ClientEnv` cache
- [x] EP-2 M4: no redirects on provider POSTs; base-URL path composition rule stated and enforced
- [x] EP-3 M1: catalog record carries Anthropic thinking style and sampling support, generated from data
- [x] EP-3 M2: request shaping honours the record (sonnet-5 adaptive, sampling dropped and recorded, zero-cap, replay sanitation, tool-id normalisation)
- [x] EP-3 M3: OpenAI-compatible reasoning controls gated on `Model.reasoning` with a recorded adjustment
- [x] EP-3 M4: every catalog entry pinned in `ThinkingSpec`/`CatalogSpec`; keyed smoke cases written
- [x] EP-4 M1: stream workers cancelled when the consumer stops, connection released
- [x] EP-4 M2: `EventStart` first on every Claude failure path; `assertErrorContract` on every error stream
- [x] EP-4 M3: block-closing fidelity (cut-off tool calls, mid-stream `Left`, interleaved reasoning, unknown frames, `[DONE]` variants)
- [x] EP-4 M4: core reassembly fallbacks and the missing `StreamSpec` cases
- [x] EP-5 M1: mid-stream transport failures classified from the shapes http-client actually raises
- [x] EP-5 M2: in-band `{"error": …}` frames on 2xx streams classified
- [x] EP-5 M3: 413 overflow, HTTP-date `Retry-After`, and `timeoutMs` edge semantics
- [x] EP-5 M4: unreachable-shape tests retired; classifier module docs match the transport
- [x] EP-6 M1: ceiling gates every repository-settable field; `allowedTools` modelled as a grant
- [x] EP-6 M2: ceiling-file provenance decided and documented
- [x] EP-6 M3: CLI truthfulness (unknown-key noise, evidence flags, exit 70, endpoint, `errorInfo` bound, staging path)
- [x] EP-6 M4: 0.2 config-surface adjustments (`env-requires`, structured output, `show --json`)
- [x] EP-7 M1: symlinked kit sources refused on install, hash and status
- [x] EP-7 M2: library code returns typed errors; only the CLI exits
- [x] EP-7 M3: install fidelity (every listed file, phase-two rollback, unique temp names, manifest version gate, dirty-update refusal)
- [x] EP-7 M4: `docs/user/kit.md` and the kit capability record match
- [x] EP-8 M1: the caller's thinking request recorded on every evidence path
- [x] EP-8 M2: strict mode fails a call whose terminal carries no record
- [x] EP-8 M3: observed model only in the OTel span; endpoint default host; commitment digest without cost
- [x] EP-8 M4: one strength derivation; `ApiProvider` declares its ceiling; ADRs 0002–0004 revised
- [ ] EP-9 M1: terminal and evidence exactly once under asynchronous exceptions
- [ ] EP-9 M2: a blocking or throwing sink cannot hang the call or starve sibling sinks
- [ ] EP-9 M3: OTel parent-context option; strength rendering shared
- [ ] EP-9 M4: abort-terminal delivery semantics documented; evidence-order pinned in `TraceSpec`
- [ ] EP-10 M1: constructor policy applied to every evolvable record; assembler seams behind `.Internal`
- [ ] EP-10 M2: deprecated shims removed; versions bumped; changelog states removals
- [ ] EP-10 M3: `Api` key normalisation, `Aborted` decision, naming and type consistency decisions recorded and applied
- [ ] EP-10 M4: accessors, parsers and deriving gaps closed; release metadata complete
- [ ] EP-11 M1: every capability `Shape` compiles under a test
- [ ] EP-11 M2: README and guides teach the supported registration path and the helpers that exist
- [ ] EP-11 M3: stale claims and Haddock swept
- [ ] EP-11 M4: changelog, capability log and bundle validation


## Surprises & Discoveries

- The eleven child plans were drafted in parallel against sibling skeletons, so each one
  that depends on another's choice (EP-10 on every field the others add; EP-11 on every
  final name; EP-9 on EP-8's `finalizeTrace` signature; EP-3 and EP-8 on the evidence
  schema version) carries an explicit reconciliation step against the sibling's Decision
  Log, and EP-11 uses named placeholders for the nine decisions it cannot know yet. The
  Integration Points section above records the reconciled answers; an implementer reads
  it before the plan. (2026-08-27, drafting)
- Four drafting sessions (EP-1, EP-6, EP-9, EP-10) were cut off by an API spend limit
  during their final trim-and-verify pass; every file was already complete (1038–1117
  lines, balanced tagged fences, four milestones, seeded Decision Logs), so no plan was
  redrafted. Their Decision Logs were read and reconciled here instead of from their
  reports. (2026-08-27, drafting)
- Every child plan runs 1038–1348 lines against the 700–1000 guideline. The excess is
  named test lists, quoted validation gates and decision rationale, which
  `agents/skills/exec-plan/PLANS.md` forbids abbreviating; the July plans (34–43) ran
  587–1099 lines under the same rule. (2026-08-27, drafting)
- Two drafters independently discovered that plan 39's decision to keep core free of
  `http-client` rests on a false premise — core already links it through the `openai`
  SDK — so EP-2 and EP-5 both add the dependency directly; the Integration Points section
  makes it one stanza. (2026-08-27, drafting)
- EP-3 found that the catalog generator's compat-rendering path has never been compiled
  (every shipped entry is `CompatNone`) and its module header lacks the selector imports;
  the first regeneration after EP-3's change will fail to build until that is fixed,
  which EP-3's M1 now includes. (2026-08-27, drafting)
- EP-7 found that `baikai-kit`'s July hardening was never recorded in `CHANGELOG.md`
  (0.1.0.1 lists only a bound change) and that `Status.resolveCacheOrEmpty`'s
  `try @IOException` cannot catch the `ExitCode` exception `ensureKitRepo` throws — the
  mechanism behind `kit status` exiting 1 offline. (2026-08-27, drafting)
- EP-10 found that selector-only export does not make a field unsettable — generic-lens
  labels reach any `Generic` field — so `ModelCallEvidence.strength` is guarded by EP-8's
  single derivation, not by an export list; REV-2 D.10 conflated the two. (2026-08-27,
  drafting)
- __A test that spawns a process cannot assert a sub-second deadline.__ EP-1 found that
  starting `/bin/sh` while the rest of a suite runs in parallel under
  `-with-rtsopts=-N` takes longer than one second on a loaded machine, so every case
  whose assertion depends on work the child actually did — not merely on the run
  returning — failed deterministically in a full-suite run and passed in isolation. The
  affected cases now use three- or five-second deadlines against stubs that sleep for
  thirty or a hundred and twenty. Any later plan writing a subprocess test with a short
  timeout (EP-6 in particular, which also edits `baikai-agent`'s runner region) should
  start from that. (2026-08-27, EP-1)
- __cabal does not rebuild an executable when only its `ghc-options` change.__ EP-1's
  first `-threaded` build reported "Building executable" and still produced the
  unthreaded binary; `cabal build -v3` passed no `-threaded` to GHC. Removing the
  component's build directory fixed it. Recorded in
  `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md`.
  (2026-08-27, EP-1)
- __REV-2 F.9 is not reproducible on macOS.__ GHC 9.12.4 on Darwin reports `Just UTF-8`
  for the standard handles under `C`, `POSIX`, `en_US.ISO8859-1` and `C.UTF-8` alike,
  so the locale-encoded write EP-1 fixed cannot fail here; it fails on Linux, which is
  where an unattended run under cron lives. EP-1 kept the guard anyway and said so in
  `docs/adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md`. Any later
  plan predicting a pre-fix transcript should re-derive it rather than quote the review.
  (2026-08-27, EP-1)
- __A process-global cache makes count-based test cases race.__ EP-2 moved the
  `ClientEnv` cache into core, and the second case in a provider suite that read
  `cachedClientEnvCount` and expected it to move by exactly one failed against the
  first under tasty's parallel execution (`expected: 2, but got: 3`). Both provider
  suites now assert allocation and normalisation in a single case. Any later plan
  adding a case that counts entries in a shared global should fold it into the
  existing one. (2026-08-27, EP-2)
- __`EventError`'s `errorInfo` is a `Maybe BaikaiError`.__ A test that reaches
  through it with `^. #errorInfo . #category` does not compile; matching on the
  `Maybe` is both required and more honest, because whether a stream error carries a
  typed error at all is itself worth asserting. EP-4, EP-5 and EP-8 all write cases
  over stream errors. (2026-08-27, EP-2)


- __A capability flag added as a gate breaks every test that reached the gated code
  through a default-valued model.__ EP-3's plan named two pinned tests that gating
  `Model.reasoning` would re-base; five needed it. Three more `baikai-openai`
  `ShapeSpec` cases were built on `deepseek_deepseek_chat` (`reasoning = False`), and
  the whole `baikai-openai/test/Main.hs` strict-gate group builds its models from
  `emptyModel`, which is also `reasoning = False`. Each case is about a /host/
  vocabulary, so each moved to a reasoning model with a comment saying which half of
  the behaviour it proves. EP-4, EP-5 and EP-6 all add gates of some kind; the pattern
  to expect is that every test reaching the gated path through a default-valued record
  needs the same treatment, and that grepping for the flag is not enough — the
  default is invisible at the call site. (2026-08-27, EP-3)
- __`Baikai.Models.Generated`'s formatter exclusion is not reliably present in a
  checkout.__ `nix/pre-commit.nix` has excluded the generated catalog from the
  `treefmt` hook since `6af3032` (2026-06-21), because formatting it breaks
  `CatalogSpec`'s byte-identity round trip. But `.pre-commit-config.yaml` is
  gitignored and regenerated by `git-hooks.nix` on dev-shell entry, so a checkout
  whose copy predates that commit carries `"exclude": "^$"` and the hook reformats the
  file anyway — which is what happened to EP-3's first M1 commit. EP-3 made the
  generator emit `ormolu`-canonical layout, so the round trip now holds whether or not
  the exclusion is in force. Any later plan that changes what the generator renders
  must check `nix fmt` as well as the compiler. (2026-08-27, EP-3)
- __`SamplingPlan`'s field names collide with `Options`' under
  `DuplicateRecordFields`.__ A record with `temperature` and `topP` fields cannot be
  read with bare selectors in a module that also imports `Baikai.Options (Options
  (..))`; `sampling ^. #temperature` compiles and a bare `temperature sampling` does
  not. Every later plan adding a record whose fields mirror an `Options` field will
  hit this, and the generic-lens label is the repository's answer anyway. (2026-08-27,
  EP-3)

- __A shared test assertion cannot live in `Main.hs`.__ EP-4 strengthened
  `assertErrorContract` to the whole stream protocol and then needed it from
  `SseSpec` and `EvidenceSpec` as well, which cannot import `Main`. It now lives
  in a `test/Contract.hs` in each provider package. EP-5 and EP-8 both write
  cases over stream errors and should import it rather than growing a third
  copy. (2026-08-27, EP-4)
- __`docs/capabilities/log.md`'s 2026-08-27 entry mislabels two capability
  ids__ — "CAP-2 (OpenAI Chat Completions backend) and CAP-3 (Anthropic Messages
  backend)" are really CAP-14 and CAP-13; CAP-2 is typed streaming and CAP-3 the
  generated catalog. EP-4 appended its own entry rather than rewriting an earlier
  one, following the changelog-correction rule in Integration Points. __EP-11
  owns the correction__, as a dated addition inside that entry. (2026-08-27,
  EP-4)
- __`Baikai.Error` has no `timeoutError`.__ EP-4's plan named one for its
  mid-stream-failure cases; the module exports `providerError`,
  `invalidRequest`, `decodeError`, `processError`, `rateLimited`, `authError`,
  `providerUnavailable` and `httpError`. EP-5 rewrites this module and is the
  plan that would add such a constructor if one is wanted. (2026-08-27, EP-4)
- __A cross-cutting guard on a `\case`-shaped fold costs a re-indentation.__
  `Baikai.Stream.step` needed a named event argument for its first-terminal-wins
  guard, and GHC rejects two equations of different arity, so the whole body
  moved into one `step s event | … | otherwise = case event of`. (2026-08-27,
  EP-4)

- __A finish reason nobody recognises ends a stream /successfully/.__ EP-5 disabled its
  own frame detection to observe the pre-fix behaviour rather than quote the review, and
  found REV-2 A.3 understated. An OpenRouter-shaped in-band error frame carries
  `choices[0].finish_reason = "error"`, which `mapFinishReason` sends to
  `(Stop, Just "unrecognized finish_reason: error")` — so the call ended as `EventDone`
  with `errorInfo = Nothing`, and a consumer switching on the terminal saw a completed
  call. Only a frame with no `choices` produced the
  `OtherError "openai stream ended without finish_reason"` the review described. Both
  providers' `mapFinishReason`-equivalents still send an unknown reason to a /success/
  terminal with a note in `errorMessage`; EP-10, which owns `ErrorCategory` and the
  `content_filter` question, should decide whether that default is right.
  (2026-08-27, EP-5)
- __`http-types` exports the folded header names, so `case-insensitive` is not a
  dependency.__ Three plans' sketches reach for `Data.CaseInsensitive.mk "Retry-After"`
  to look up a response header. `Network.HTTP.Types.Header` exports `hRetryAfter`,
  `hDate` and the rest as constants, and `http-types` is already needed wherever
  `statusCode` is. EP-9 and EP-10, which both touch header handling, should start from
  that. (2026-08-27, EP-5)
- __A test that builds an `HTTP.Response` must import `Network.HTTP.Client.Internal`.__
  The record's constructor is not exported from `Network.HTTP.Client`, and the failure
  reads as a shadowing problem ("Illegal term-level use of the type constructor") rather
  than a missing export. Every existing fixture in the repository already does this; a
  new one should copy an existing import list rather than the module name. (2026-08-27,
  EP-5)
- __Deleting an export forces the tests that call it forward.__ EP-5's plan scheduled the
  `responseToError` deletion for M1 and the deletion of the tests calling it for M4, which
  cannot both be true: the provider suites stop compiling the moment the export list
  changes. Any later plan that removes a name should schedule its test deletions in the
  same milestone. (2026-08-27, EP-5)

- __A gate added to a shared check re-bases every test that reached it through a
  default-valued record — again.__ EP-6's finite `maxOutputLimit` default makes
  `applyAgentCeiling defaultAgentCeiling` refuse any request whose `outputLimit` is
  `Nothing`, which is what `agentRunRequest` defaults to; five cases in
  `baikai/test/AgentSpec.hs` had to start from a helper that sets a limit. This is the
  third instance of the pattern EP-3 first recorded (a capability flag), and it is now
  worth stating as a rule: __when a plan adds a bound to a check, grep for the
  constructor that builds the checked value, not just for the field name.__ The default
  is invisible at every call site. EP-8, EP-9 and EP-10 all add or move checks.
  (2026-08-27, EP-6)
- __Two top-level nodes of the same name in one KDL document are an array, not a
  merge.__ Building a fixture by concatenating `jobs { … }` with a second `jobs { … }`
  produces a repeated node, which settei reads as an array and then cannot traverse;
  every key fails with `cannot traverse jobs through array in file source repository
  configuration (KDL v2)`, which reads like a resolution bug rather than a malformed
  fixture. EP-6 hit it twice. Any later plan composing KDL fixtures by concatenation
  should compose /inside/ the node instead. (2026-08-27, EP-6)
- __`canonicalizePath` on macOS resolves `/etc` to `/private/etc` and `/tmp` to
  `/private/tmp`.__ Any test asserting a canonicalised path by equality against a
  literal, or against a path built from `withSystemTempDirectory`'s answer, has to
  canonicalise both sides or assert a suffix. (2026-08-27, EP-6)
- __A test that writes a process-global environment variable races the case that reads
  it.__ EP-6's new refusal case copied its fixture's `setEnv` calls and, under tasty's
  parallel execution, overwrote the value the fixture's own fake was writing through.
  The refusal case never reaches the runner, so it needed neither variable. Same shape
  as EP-2's `ClientEnv` count race: a case that writes shared process state must either
  not write it or be folded into the case that reads it. (2026-08-27, EP-6)

- EP-8's `ApiProvider.strengthCeiling` is the fifth field on that record, and EP-10
  (`docs/plans/67-freeze-the-public-surface.md`) now carries a Decision Log line saying
  so: the base value that plan defines for every evolvable record must cover it. EP-8
  deliberately added none, because a base value added there and renamed at the freeze
  would break third parties twice. (2026-08-27, EP-8)
- EP-8 bumped `evidenceSchemaVersion` to `baikai.model-call-evidence/2.0`, and both
  golden digests in `baikai/test/EvidenceSpec.hs` were recomputed. Any later plan that
  edits `configurationProjection`, `usageEnvelope` or `canonicalEncode` changes what a
  verifier must hash and owes another major bump; the constant's Haddock now states the
  rule per digest so the obligation is visible at the definition. (2026-08-27, EP-8)
- EP-8 found that a test fixture can hide the very defect the suite appears to cover.
  Every stub `describeThinking` answered `noThinkingRequested` whatever the caller set,
  which made the thinking-collapse defect invisible on four well-covered paths, and the
  evidence fixture planted no marker in a structured-output schema, which made the
  redaction test blind to two keys it was supposed to guard. EP-9, EP-10 and EP-11 should
  treat "the fixture cannot distinguish the two outcomes" as a finding in its own right.
  (2026-08-27, EP-8)
- EP-8's ADR 0014 is numbered 0014, not the `0006` its plan named, and was written in its
  Milestone 2 rather than Milestone 4: the milestone's own capability-record and changelog
  edits had to cite it, and a document linking a file that does not yet exist is a broken
  link at that commit. Later plans naming a prospective ADR number should expect the same.
  (2026-08-27, EP-8)
- EP-7's ADR, `docs/adr/0013-library-code-never-calls-exitfailure.md`, binds every
  package, not only `baikai-kit`: no exposed module may call `exitFailure`,
  `exitWith` or `error` on a failure path, and an adapter documented to *be* a
  subcommand gets a non-exiting twin. EP-10 must hold every name it freezes to that
  rule; a grep of the other packages during EP-7 found no violation to fix, so the
  record is a constraint on what may be added rather than a backlog. (2026-08-27, EP-7)
- EP-7's exit-boundary guard cannot be `grep -rn "System.Exit"`, as its plan proposed:
  `Baikai.Kit.Repo` matches on `ExitCode` from `readProcessWithExitCode`, which is
  reading a child's status, not exiting. The guard that works is
  `grep -rn "exitFailure\|exitWith"`. Any later plan pinning the same boundary should
  use the narrower grep. (2026-08-27, EP-7)
- EP-7 replaced `Text.IO.readFile` on an agent body with an explicit
  `decodeUtf8'`, refusing a source that is not UTF-8 as `KitSourceUnreadable` rather
  than letting the locale decide. That is ADR 0007 applied to a file read rather than
  a process boundary; EP-10 and EP-11 should expect the same rule wherever the library
  reads text a user supplied. (2026-08-27, EP-7)


## Decision Log

- Decision: EP-8's ADR is
  `docs/adr/0014-strict-evidence-means-a-record-exists.md`, so the next plan to promote a
  record takes `0015`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-8's
  distillation pass promoted the record-exists rule to 0014 and folded its other three
  durable decisions into revisions of the records that already owned them — the
  `not_translated` mode into 0002, the adapter-obtained description and the
  provider-declared ceiling into 0003, and the two digest changes into 0004 — rather than
  creating records that would have restated them.
  Date: 2026-08-27
- Decision: EP-7's ADR is
  `docs/adr/0013-library-code-never-calls-exitfailure.md`, so the next plan to promote
  a record takes `0014`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-7's
  distillation pass found nothing durable beyond that record: the symlink rule, the
  journaled two-phase write and the local-edit refusal are documented in
  `docs/user/kit.md` and `docs/capabilities/kit-installer.md` where a caller meets
  them, and none of them constrains a package other than `baikai-kit`.
  Date: 2026-08-27
- Decision: EP-6's ADR is
  `docs/adr/0012-the-unattended-policy-ceiling-gates-every-repository-settable-field.md`,
  so the next plan to promote a record takes `0013`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-6's
  distillation pass found nothing durable beyond that record: the evidence destination
  rule, the bounded `errorInfo` and the unique staging name are documented in
  `docs/user/unattended-agent-runs.md` where a caller meets them.
  Date: 2026-08-27
- Decision: EP-5's ADR is
  `docs/adr/0011-core-owns-transport-failure-classification.md`, so the next plan to
  promote a record takes `0012`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-5's
  distillation pass found nothing durable beyond that record: the 413 decision and the
  `timeoutMs` refusal are consequences of the phase rule or are documented where a caller
  meets them.
  Date: 2026-08-27
- Decision: Eleven child plans in four waves, exceeding the preferred seven.
  Rationale: REV-2's sixty-eight findings span eight packages and three surfaces that did
  not exist or were rewritten after July; merging further would either put the most
  contended files (the two provider assemblers) under two plans at once or produce a
  single plan carrying most of the work. Waves keep at most six plans concurrent.
  Date: 2026-08-27
- Decision: Test-coverage findings (REV-2 Theme I) are distributed to the plan that owns
  the code under test; there is no separate test plan.
  Rationale: a pin written apart from its fix pins the wrong shape — the July review's
  central complaint about the classifier tests.
  Date: 2026-08-27
- Decision: The cut-off tool-call fix (REV-2 B.2) belongs to EP-4, not EP-5.
  Rationale: it is a block-closing decision in both assemblers, which EP-4 owns; EP-5
  edits the assemblers only in the bounded `parseChunk` region.
  Date: 2026-08-27
- Decision: EP-11 hard-depends on EP-10; every other dependency is soft.
  Rationale: documentation must name final exports; nothing else in the initiative fails
  to compile or make sense without another plan's artifacts, so serialising more than
  the two `Trace.hs` and two `Api.hs` plans would only extend the timeline.
  Date: 2026-08-27
- Decision: One intention, `intention_01m10p16mxedft15rjkk2w21g0`, created with
  `mina ci --json` and recorded in the frontmatter of this MasterPlan and every child plan.
  Rationale: the house pattern from masterplans 7 and 9 and the skill's inheritance rule;
  the initiative is tracked as one unit and every commit carries the same `Intention:`
  trailer.
  Date: 2026-08-27
- Decision: Live verification against Anthropic is not a gate for any plan.
  Rationale: no key is assumed in the implementing environment; EP-3 writes the keyed
  smoke cases and states what a later keyed run must show, as EP-7 of masterplan 7 did.
  Date: 2026-08-27
- Decision: ADR numbers are allocated at implementation time in landing order; the slug
  is the identity a plan cites until then.
  Rationale: the plans were drafted in parallel against the same five-record corpus and
  several claim `0006`; numbering by drafting order would force renames at every
  reordering of the waves.
  Date: 2026-08-27
- Decision: A released `CHANGELOG.md` section is never rewritten in place; a correction
  is a dated addition inside that section.
  Rationale: EP-8's draft amended the 0.5.0.0 paragraph in place and EP-11's added dated
  notes; the changelog is the record of what was claimed at release time, and the release
  skill treats it as the record. The dated-addition form keeps both the claim and its
  correction readable.
  Date: 2026-08-27
- Decision: The evidence schema version is EP-8's to set, ending at `2.0`; EP-3's
  additive constructors ride whichever bump is current.
  Rationale: two plans bumping the same constant to different values would leave the
  final value dependent on landing order; the digest-content change is the breaking one.
  Date: 2026-08-27
- Decision: `Aborted` is retired (EP-10's primary branch), not produced.
  Rationale: EP-4's cancellation design leaves no consumer to receive such a terminal,
  and nothing else produces it; a stop reason with no producer and inconsistent failure
  semantics is a freeze hazard.
  Date: 2026-08-27
- Decision: `content_filter` gains its own category (`ContentFiltered`) in EP-10, not in
  EP-5.
  Rationale: widening a closed sum is a surface decision that belongs with the other
  freeze-time type changes and the major bump that carries them.
  Date: 2026-08-27
- Decision: EP-4's ADR is
  `docs/adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md`,
  so the next plan to promote a record takes `0011`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-4's
  distillation pass found nothing durable beyond that record: the cut-off
  tool-call contract is documented on `ToolCall` and in `docs/user/tools.md`
  where a caller meets it, and the `EventStart`-first invariant was already the
  documented protocol in `Baikai.Stream.Event` — EP-4 removed the exception, it
  did not make a new decision.
  Date: 2026-08-27
- Decision: EP-3's ADR is
  `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`,
  so the next plan to promote a record takes `0010`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-3's
  distillation pass found nothing durable beyond that record: the one other candidate
  — that generated output is emitted in the repository formatter's canonical layout —
  is already explained in `nix/pre-commit.nix` beside the mechanism that enforces it,
  and the repository has one generator.
  Date: 2026-08-27
- Decision: EP-2's ADR is `docs/adr/0008-one-url-host-parser-and-every-consumer-uses-it.md`,
  so the next plan to promote a record takes `0009`.
  Rationale: landing order, per the allocation rule in Integration Points. EP-2's
  distillation pass found nothing durable beyond that record.
  Date: 2026-08-27
- Decision: EP-1 allocated ADR numbers `0006` and `0007`, so the next plan to promote a
  record takes `0008`.
  Rationale: the allocation rule in Integration Points is landing order.
  `0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md` is the record
  the decomposition assigned EP-1; `0007-text-crossing-a-process-boundary-is-encoded-explicitly.md`
  came out of EP-1's distillation pass, because the fix to REV-2 F.9 completed a
  repository-wide rule the prompt read and prompt write already followed and that four
  call sites now depend on.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)

EP-6 complete (2026-08-27), four milestones in four commits `c629195`, `bb5113a`,
`a039ba9` and the completion commit. The unattended policy ceiling now gates every
field a repository file can set: six are bounded by an operator maximum, `executable`
and `extra-dirs` are refused from repository scope outright, and `working-dir` is
confined to the checkout after following symbolic links. `allowedTools` is modelled
and documented as the grant it is — a repository job asking for `Bash` under
`edit-workspace` exits 77 naming `Bash`, `edit-workspace` and `policy.allowed-tools`
before any process is created, and an operator opens it with one line in their own
file. An operator file lying inside the checkout is refused with exit 78 and no
ceiling, closing both `--user-config .baikai/policy.kdl` and
`XDG_CONFIG_HOME=$PWD/.baikai`; a misspelled `policy` key is an error rather than a
silently ignored line. The command surface stopped printing other jobs' unknown keys,
stopped building evidence records with nowhere to send them, lost the exit code 70
nothing produced, resolves a relative executable the way the child does, bounds
`errorInfo` at 4096 bytes of standard error, and stages the evidence file under a
fresh `O_EXCL` name so a planted symlink is never written through. The 0.2 surface
changes landed with them: `envPassthrough` → `envRequires`, `output-format "json"` on
both renderers, a repository-rooted `working-dir`, and aeson-built envelopes with
`show --json` emitting one seven-key object whatever happened. The keyless `cabal test
all` gate is green across all eight suites, `nix fmt` leaves the tree unchanged, `nix
flake check` passes, and `okf validate docs/capabilities` reports `OK: 22 concepts`.
ADR `0012` records the decision. The `AgentCeiling` field set is final and EP-10 must
not change it; the names EP-10 must cover are listed in EP-6's own Outcomes section.
No versions were bumped.

EP-5 complete (2026-08-27), four milestones in four commits `45485d6`, `5d7610c`,
`b5fd260` and the completion commit. A failure that lands while the response body is
streaming is now the transient failure it is on both providers — a reset, a mid-chunk
close, a short body and a TLS session torn down after the handshake all end the stream
with `TransientError`, `isRetryable = True` and the text already drained — through one
rule in `Baikai.Provider.Transport.Classify` with one test suite, keyed on the phase the
failure happened in rather than its type. An in-band `{"error": …}` frame on a `2xx`
stream ends the call with the frame's own classification, status and message, reaching
the assembler as the same `Left` element a non-2xx uses so EP-4's block closing applies
unchanged. 413 is `ContextOverflow` from the status alone; an HTTP-date `Retry-After`
converts against the response's `Date` header; and `timeoutMs <= 0` is refused as
`InvalidRequest` before any connection is opened, proven against a real listener whose
accept count stays at zero. Every servant-shaped classifier fixture is gone, along with
`responseToError` and `classifyErrorText` from both packages. The keyless `cabal test
all` gate is green across all eight suites, `nix fmt` leaves the tree unchanged, and
`okf validate docs/capabilities` reports `OK: 22 concepts`. ADR `0011` records the
ownership decision and supersedes plan 39's "core stays free of `http-client`"
rationale. Names EP-10 must cover: `Baikai.Provider.Transport.Classify` and its five
exports (recommended public — its Haddock offers it to third-party `Custom` providers),
`Baikai.Error.parseHttpDate`, `Baikai.Error.retryAfterSecondsAt`,
`classifyErrorFrame` and `parseFrame`. Core's direct dependencies grew by `http-types`
and `tls`, and `baikai-openai`'s by `scientific`. No versions were bumped.

EP-4 complete (2026-08-27), four milestones in four commits `20bd305`, `85731d5`,
`9276cb3` and the completion commit. A consumer that stops reading now stops the
provider: both HTTP providers hand frames through a bounded 64-slot queue and run
their worker under a bracket, so cancellation releases the connection
immediately, abandonment stops the socket read within 64 further frames and
releases at the next major GC, and a worker that dies asynchronously can no
longer strand its consumer. Every stream from either provider begins with
`EventStart` — the Claude producer pre-seeds it, so a 401, a rate limit, an
in-band error frame and an EOF before `message_start` are all
`[EventStart, EventError]` with structured `errorInfo`. A tool call cut off by
the output cap keeps its raw argument text through one shared rule and is
dispatched by neither `runToolLoop` nor `appendToolResult`; a mid-stream failure
closes the blocks that were open; reasoning after text closes the text block
first; unknown SSE frames, empty heartbeats and whitespace-trailing `[DONE]` no
longer end a healthy stream; and core reassembly is total under duplicated, late
and timestamp-less input. The keyless `cabal test all` gate is green across all
eight suites, `nix fmt` leaves the tree unchanged, and `okf validate
docs/capabilities` reports `OK: 22 concepts`. ADR `0010` records the cancellation
decision. Names EP-10 must cover: `Baikai.Provider.Internal.StreamWorker` and its
seven exports, `Baikai.Content.toolArgumentsFromText` and `isCutOffToolCall`, and
`Baikai.Provider.Claude.Sse.decodeFrame`. Nothing produces an `Aborted` terminal,
so EP-10's retirement of it stands. No versions were bumped.

EP-3 complete (2026-08-27), four milestones in four commits `29daac0`, `1b5ed8a`,
`54b992b`, `5fc558b`. The thinking style and sampling support of an Anthropic model
generation are now fields of its generated catalog record, curated in the fetcher's
include map and refused by the generator when missing, so `claude-sonnet-5` sends the
adaptive shape rather than the `budget_tokens` a retired prefix table chose for it.
Sampling parameters a generation rejects are dropped and recorded; `seed` and the two
penalties, which the Messages API has no field for, are recorded separately; neither
refuses a strict call. A model with an unknown output cap sends 1024 rather than
`max_tokens: 0`; replay never sends an empty block or an empty turn; tool-call ids no
longer collide. On the OpenAI-compatible side a level on a non-reasoning model sends no
reasoning control on any host and records the drop, making
`docs/user/model-call-evidence.md`'s baikai-wide promise true on both API adapters. The
keyless `cabal test all` gate is green across all eight suites, `nix fmt` leaves the
tree unchanged, and `okf validate docs/capabilities` reports `OK: 22 concepts`. ADR
`0009` records the catalog-record decision. Breaking changes recorded under
`[Unreleased]` for EP-10 to version: `AnthropicMessagesCompat` gains
`supportsSamplingParameters`, `evidenceSchemaVersion` moves to `1.1`, and the four
`baikai-openai` `Shape` functions take a `Bool` after the compat record;
`defaultAnthropicThinkingStyle` is deprecated and belongs on EP-10's removal list. No
keyed run happened, so the facts table is written from the API reference REV-2
consulted and the two `ThinkingSmoke` cases state what a keyed run must show; the
riskiest row is `claude-sonnet-4-6`, flipped from budget to adaptive on the reference's
strength.

EP-2 complete (2026-08-27), four milestones in four commits `81e2aad`, `0b21ea3`,
`f11c047`, `a75c59d`. There is one URL parser in baikai and every consumer calls it,
so a base URL with an `@` after the authority can no longer choose which provider's
key baikai sends. Credential-carrying headers are redacted wherever baikai prints or
serialises an `Options`, `Model` or `Response`; an empty key variable is an
`AuthError` naming it; embeddings resolve keys per host and share the chat providers'
connection cache; no provider POST follows a redirect; and the base-URL convention is
stated in `docs/user/models-and-providers.md` and enforced before a key is read. Two
breaking changes are recorded under `[Unreleased]` for EP-10 to version:
`EmbeddingModel.apiKey :: Maybe ApiKeySource`, and the hand-written `Show`/`ToJSON`
on `Options` and `Model`. ADR `0008` records the parser decision.

EP-1 complete (2026-08-27), four milestones in four commits `e2f33cc`, `ab9fc1f`,
`f5e8722`, `90894ca`. The shipped `baikai` executable now links the threaded runtime,
a timed-out run escalates to `SIGKILL` across its whole process group and reports what
it drained, the command writes UTF-8 whatever the locale says, the Codex launcher
refuses the two approval spellings the installed CLI rejects, and the codex JSONL
assembler and the Codex custom-agent TOML renderer are both correct. The keyless
`cabal test all` gate is green across all eight suites, `nix fmt` leaves the tree
unchanged, and `okf validate docs/capabilities` reports `OK: 22 concepts`. Two ADRs
were promoted, `0006` and `0007`. One breaking change to `baikai` — `RunTimedOut` now
carries `AgentTimedOut` — is recorded under `[Unreleased]` for EP-10 to version.


---

Revision note (2026-08-27, EP-6 complete): EP-6's registry row is Complete and its
four Progress lines are ticked. Four discoveries were added that bind later plans —
the gate/default-valued-record pattern is now on its third instance and is stated as
a rule for EP-8, EP-9 and EP-10 (grep for the constructor, not the field); two
top-level KDL nodes of the same name are an array settei cannot traverse;
`canonicalizePath` on macOS rewrites `/etc` and `/tmp`; and a test that writes a
process-global environment variable races the case that reads it — and the Decision
Log records that EP-6 took ADR number `0012`, so the next plan to promote a record
takes `0013`. Every Integration Points commitment for EP-6 was met as written: the
policy-model field set is exactly the one listed there (`policy.allowed-tools`,
`policy.max-timeout`, `policy.max-output-limit`, `repositoryRoot`, the four
violations, `outputFormat`, the `envPassthrough` → `envRequires` rename, the deletion
of `OutputMalformed` and exit 70, and the removal of `BAIKAI_AGENT_EXECUTABLE`), the
`AgentCeiling` field set is final for EP-10, and no version was bumped. Two names EP-6
adds beyond that list are recorded for EP-10: `Baikai.Agent.ceilingViolations` (the
pure violation list, so a caller can concatenate provenance-dependent violations with
it) and `Baikai.Agent.defaultMaxOutputLimit`.

Revision note (2026-08-27, EP-5 complete): EP-5's registry row is Complete and its four
Progress lines are ticked. Four discoveries were added that bind later plans — an
unrecognised `finish_reason` ends a stream as a /success/ terminal, which EP-10 should
weigh alongside the `content_filter` question it already owns; `http-types` exports the
folded header-name constants, so `case-insensitive` need not be a dependency (EP-9 and
EP-10 both touch header handling); a test that builds an `HTTP.Response` must import
`Network.HTTP.Client.Internal`; and deleting an export forces the tests that call it
into the same milestone — and the Decision Log records that EP-5 took ADR number `0011`,
so the next plan to promote a record takes `0012`. Two Integration Points commitments
were met as written: EP-5 made the one reserved edit to the OpenAI `worker`
(`parseChunk` → `parseFrame`) and recorded it in EP-4's Decision Log, and it left
`content_filter` as `OtherError` while recording the question in EP-10's. The single
core `http-client` stanza commitment resolved trivially: EP-2 landed it first, so EP-5
added only `http-types` and `tls`.

Revision note (2026-08-27, EP-4 complete): EP-4's registry row is Complete and its
four Progress lines are ticked. Four discoveries were added that bind later plans
— a shared test assertion cannot live in `Main.hs` (EP-5 and EP-8 both write
cases over stream errors and should import each provider suite's new
`test/Contract.hs`), `docs/capabilities/log.md`'s 2026-08-27 entry mislabels
CAP-2 and CAP-3 and EP-11 owns the dated correction, `Baikai.Error` has no
`timeoutError` (EP-5 owns that module), and a cross-cutting guard on a
`\case`-shaped fold costs a re-indentation — and the Decision Log records that
EP-4 took ADR number `0010`, so the next plan to promote a record takes `0011`.
Three Integration Points commitments were met as written: the cut-off tool-call
contract landed as `toolArgumentsFromText` / `isCutOffToolCall` with
`runToolLoopWith` stopping and `appendToolResult` appending an `isError` result,
`Baikai.Provider.Internal.StreamWorker` landed under that exact name outside the
PVP promise, and nothing produces an `Aborted` terminal, so EP-10's retirement of
it needs no alternative branch. One name is added to EP-10's coverage list beyond
those already recorded: `Baikai.Provider.Claude.Sse.decodeFrame`.

Revision note (2026-08-27, EP-3 complete): EP-3's registry row is Complete and its four
Progress lines are ticked. Three discoveries were added that bind later plans — a
capability flag added as a gate re-bases every test that reached the gated code through
a default-valued model (EP-4, EP-5 and EP-6 all add gates), `Generated.hs`'s formatter
exclusion is not reliably present in a checkout, and a record whose fields mirror
`Options`' must be read through generic-lens labels — and the Decision Log records that
EP-3 took ADR number `0009`, so the next plan to promote a record takes `0010`. Two
Integration Points commitments were met as written: EP-3 added its two
`ThinkingAdjustment` constructors to the existing sum and set the evidence schema
version to `1.1`, which EP-8 must move to `2.0` while naming both changes; and EP-8's
strict gate must consult `weakensThinking`, which EP-3 added and
`checkEvidenceRequirements` already filters through.

Revision note (2026-08-27, EP-2 complete): EP-2's registry row is Complete and its
four Progress lines are ticked. Two discoveries were added that bind later plans — a
process-global cache makes count-based test cases race under parallel execution, and
`EventError.errorInfo` is a `Maybe` — and the Decision Log records that EP-2 took ADR
number `0008`, so the next plan to promote a record takes `0009`.

Revision note (2026-08-27, EP-1 complete): EP-1's registry row is Complete and its four
Progress lines are ticked. Three discoveries were added to Surprises & Discoveries that
bind later plans — the sub-second-deadline trap in subprocess tests, cabal not
rebuilding an executable on a `ghc-options` change, and REV-2 F.9 being unreproducible
on macOS — and the Decision Log records that EP-1 consumed ADR numbers `0006` and
`0007`, so the next plan to promote a record takes `0008`.

Revision note (2026-08-27): after the eleven child plans were drafted in parallel, their
Decision Logs were read together and the cross-plan answers were recorded in Integration
Points (the ADR-numbering rule, the single core `http-client` stanza, the new modules
EP-10 must cover, the header-map handoff between EP-2 and EP-10, EP-8's ownership of the
evidence schema version and of `finalizeTrace`'s new parameter, EP-4's cut-off tool-call
contract, the retirement of `Aborted`, `ContentFiltered` in EP-10, EP-6's policy-model
field set, the changelog-correction rule, and EP-10's version plan) and in the Decision
Log. One child plan (EP-8, `docs/plans/65-…`) was edited in the same pass so its changelog
step follows the correction rule. The Progress section's milestone titles are the ones the
child plans use verbatim.
