---
id: 68
slug: bring-the-documentation-back-to-the-code
title: "Bring the documentation back to the code"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Bring the documentation back to the code

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This is the last plan (EP-11, wave 4) of
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`. Every
other plan in that initiative changes what the library does; this one makes every
document that describes the library say what the code does after those changes, and
adds one mechanism so the most-copied documentation cannot drift silently again.

The review at `docs/reviews/correctness-and-api-review-follow-up.md` (REV-2, Theme H)
found that twelve of the twenty-two capability records under `docs/capabilities/` show
a `## Shape` block that does not compile or names things that do not exist; that the
README and two guides still teach a registration path made of deprecated names; that
five helpers added in July (`responseError`, `streamRequestEach`, `streamRequestList`,
`ApiKeyEnvChain`, `mkModel`) and the sampling options appear in no guide; and that a
long list of sentences in the guides, the records and the Haddock describe the code as
it was before July or before August. A consumer who copies a `Shape` today gets a
compile error; one who follows the README's registration paragraph gets deprecation
warnings that `-Werror=deprecations` turns into a failed build.

After this plan a reader gets four things. Every fenced `haskell` block under
`docs/capabilities/` is compiled by a test suite that runs under the ordinary
`cabal test all`, and a change to the record or the code that breaks their agreement
fails that test naming the record and the first differing line. `README.md` and every
guide in `docs/user/` teach registration through `register`, the first-class
`*Provider` values, `newProviderRegistryFrom` and `assertRegistered`, and document the
helpers that exist. Every stale claim the review enumerated — in prose, in the records
and in the Haddock — reads as the code behaves after EP-1 through EP-10. And
`CHANGELOG.md` states what 0.5.0.0 shipped in the four places it omitted, the records
whose behaviour the earlier plans changed say so with a dated `docs/capabilities/log.md`
entry, and the bundle validators the release skill runs pass.

You can see it working by running `cabal test baikai-smoke:test:doc-shapes` and reading
one "agrees" line per record, by running
`okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce`
and reading `OK: 22 concepts (okf_version 0.2)`, by building the Haddock of every
package, and by grepping the guides for `registerWith` and getting nothing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Before Milestone 1 — reconciliation:

- [x] Read the Outcomes & Retrospective and Decision Log of `docs/plans/58-…` through
      `docs/plans/67-…`; resolve every angle-bracket placeholder in this plan and record
      each resolution in the Decision Log.
- [x] Run the starting-state greps in Concrete Steps and paste the output into Surprises
      & Discoveries.

Milestone 1 — every capability `Shape` compiles under a test:

- [x] Add the `doc-shapes` test-suite stanza to `baikai-smoke/baikai-smoke.cabal`.
- [x] Create `baikai-smoke/doc-shapes/DocShapes.hs`, `Shape/Fixtures.hs`, and one
      `Shape/CapN.hs` per record with a `haskell` fence (twenty modules).
- [x] Rewrite the twelve failing Shape blocks (CAP-4, 5, 9, 12, 13, 16, 17, 18, 19, 20,
      22 and the `import Baikai` + `withTrace` fix), plus CAP-7 and CAP-14.
- [x] Resolve the CAP-18 KDL block through `Baikai.Agent.Config` in the same test.
- [x] State the Shape convention in `docs/capabilities/index.md`.
- [x] `cabal test baikai-smoke:test:doc-shapes` green; keyless `cabal test all` green.

Milestone 2 — README and guides teach the supported registration path and the helpers
that exist:

- [x] Registration rewrite in `README.md`, `docs/user/cli-providers.md`,
      `docs/user/models-and-providers.md`, `docs/user/getting-started.md`.
- [x] New sections: `responseError`; `streamRequestEach` / `streamRequestList` and the
      streamly paragraph; `ApiKeyEnvChain`; `mkModel`; the sampling options; the
      base-URL composition rule; the `ApiProvider` base value from EP-10.
- [x] `git grep registerWith` over `README.md docs/user docs/capabilities` is empty.

Milestone 3 — stale claims and Haddock swept:

- [ ] Every enumerated guide and record claim fixed (list in Plan of Work).
- [ ] Every H.4 Haddock sentence rewritten; `git grep -n "EP-[0-9]" -- '*.hs'` hits only
      the survivors recorded in the Decision Log.
- [ ] `cabal haddock` succeeds for all seven packages.

Milestone 4 — changelog, capability log and bundle validation:

- [ ] `CHANGELOG.md`: the four 0.5.0.0 gaps filled; the `[Unreleased]` entries EP-1..EP-10
      should have added verified or added; the three wrong 0.5.0.0 sentences corrected.
- [ ] Twelve capability records updated in the body (never `since`), `generated.at`
      advanced, one dated `docs/capabilities/log.md` entry.
- [ ] `okf validate` (capabilities, reviews, improvement-requests), `okf graph`,
      `mori validate`, `mori register`, keyless `cabal test all` pass; master plan updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Found while drafting: `docs/capabilities/subscription-cli-backends.md:86-88` and
  `CHANGELOG.md:127` say the `--version` probe is bounded by two seconds; the code says
  five (`baikai/src/Baikai/Provider/Cli/Internal.hs:650-659`,
  `versionProbeMicros = 5000000`). Fixed in Milestone 4.
- Found while drafting: `docs/capabilities/usage-and-cost-accounting.md:59-60` calls
  `runRequestWithLog` under a bare `import Baikai`; it lives in `Baikai.Cost.Log`, which
  the umbrella omits, and the block builds `CallLogConfig` positionally — a constructor
  REV-2 G.1 lists as a hazard EP-10 may hide. Rewritten in Milestone 1 although the
  review did not count it among the twelve.
- Found while drafting: `docs/capabilities/anthropic-messages-backend.md:48-51` says the
  provider transports over `servant-client` and classifies `ClientError`; the transport
  has been baikai's own SSE reader over `http-client` since July. CAP-8's evidence line
  30 says the same. Both fixed in Milestone 4.

Starting-state greps, run at `ff5fa08` before any edit (the plan predicted nine
`registerWith` hits, two `EP-` hits in the guides and twenty-eight in the sources):

```text
$ git grep -n "registerWith" -- README.md docs/user docs/capabilities baikai-effectful/README.md
(no output)
$ git grep -n "assistantContent\|zero usage\|report zeros\|24h" -- README.md docs/user docs/capabilities
README.md:151:  text out, zero usage, synthetic one-shot streams. See
docs/capabilities/openai-chat-completions-backend.md:86:  anything that exists only there — including the 24h prompt-cache bucket
docs/capabilities/prompt-cache-retention.md:72:- `CacheRetentionLong` is documented as 24h on the OpenAI Responses API, but
docs/capabilities/subscription-cli-backends.md:81:- Before 0.5.0.0 both providers hardcoded zero usage, so every such call looked
docs/capabilities/usage-and-cost-accounting.md:77:- Before 0.5.0.0 both subprocess providers hardcoded zero usage. Totals over
docs/user/getting-started.md:190:EventStart   { partial = AssistantMessage {…, assistantContent = []} }
docs/user/prompt-caching.md:23:  | CacheRetentionLong   -- Long bucket (Anthropic: ttl "1h"; OpenAI Responses: 24h).
docs/user/prompt-caching.md:30:| `CacheRetentionLong` | `cache_control.ttl: "1h"` | 24h |
docs/user/prompt-caching.md:126:- **CLI providers report zeros.** `claude -p` and `codex exec` don't
$ git grep -n "EP-[0-9]" -- README.md 'docs/user/*.md' 'docs/capabilities/*.md'
docs/user/tools.md:260:  of the context is cached. See the EP-5 retrospective in the
$ git grep -n "EP-[0-9]" -- '*.hs' | wc -l
22
```

The four plan-43 greps (`OPENAI_KEY`, `ProviderError`, `0.1 API`, the underscore-prefixed
field names) all come back empty, so those residuals stayed fixed.

Two of the three predictions were high: EP-10 had already removed every `registerWith`
mention from the guides and records, and six of the twenty-eight `EP-n` source comments
had already gone with the modules EP-4, EP-5 and EP-10 rewrote. Both the remaining
`24h` claims and the `zero usage` / `report zeros` claims are exactly where the review
put them.

Milestone 1, three things the plan did not predict.

*The formatter is the arbiter of a Shape block.* `nix fmt` runs `ormolu` over the new
`Shape/CapN.hs` modules, so the moment the first commit was formatted, twenty blocks
that had agreed began to differ: aligned `let` columns collapsed, `Baikai :> es =>`
gained parentheses, a two-space comment gap became one, and a record construction moved
onto its own line. Two changes settled it. The checker now trims blank lines from both
edges of the marked region, because the formatter puts one before a closing `-- END`
comment and that is layout, not content. And every record's block was regenerated from
its formatted module rather than the other way round, so what a consumer copies is
canonically formatted Haskell. That is a better outcome than the plan's: a record can no
longer show a block the repository's own formatter would rewrite.

*A fixture can be shadowed by a selector.* `Shape.Fixtures.model` is ambiguous against
`Baikai.Response.model` under `DuplicateRecordFields` in every module that imports both,
which is ten of the twenty. The modules resolve it with `import Baikai hiding (model)`;
the records are untouched, because the ambiguity is an artifact of supplying fixtures,
not something a consumer with a real `model` in scope would meet. This is the same
hazard EP-10's Outcomes flagged for guide prose, from the other direction.

*Deleting a module cannot be the drift proof the plan wanted.* `Shape.Cap12` is listed
in `other-modules`, so removing the file fails the build before the checker runs. The
completeness check was proven from the other side instead, which is also the drift that
actually happens: adding a `haskell` fence to CAP-3's record, which has none, printed
`doc-shapes: no module for a record with a haskell Shape block: Cap3.hs` and exited 1.
The record-versus-module proof ran as the plan wrote it — one character changed inside
`prompt-cache-retention.md` printed `DIFFERS` with both lines and exited 1.

*One block is compiled and one is not.* `docs/capabilities/opentelemetry-span-export.md`
shows two `haskell` fences under `## Shape`: `otelSink`, and `otelSinkWith` under a
caller's parent context. The checker reads the first, as the plan specifies, so the
second is unchecked. It was read against
`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` by hand and is correct;
covering it would need either a second marker pair per module or a second module per
record, and neither is worth the shape of the rule.

Milestone 2: four of the seven prescribed edits were already in the tree, done by the
plan that owned the behaviour, and the greps say so. `registerWith` is gone from every
guide and record; `docs/user/models-and-providers.md`'s "Base URLs" section already
states the `/v1` folding rule EP-2 chose, segment-wise, with the `/v10` and `/v1beta`
exceptions; its "Sampling parameters" section already carries the five-field table and
both `sampling_dropped_*` adjustment kinds EP-3 added; and `getting-started.md` already
teaches `ApiKeyEnvChain`, the empty-variable `AuthError` and header redaction. What was
left was the registration prose in `README.md` and the guide's own "The registry"
section, the two helper sections (`responseError`, `streamRequestEach` /
`streamRequestList`), `mkModel` at the head of "Hand-rolled models", and the custom
provider.

The custom-provider example was the one that could not have compiled: it imported
`ApiProvider (..)` and built the record positionally, and EP-10 unexported the
constructor. It is now `apiProviderWith tag stream complete` with `describeThinking` and
`strengthCeiling` shown as record updates over the builder's defaults, and the two
"Changed in …" callouts are gone — the builder is the fix for the hazard they described,
so a release note about the break they caused is no longer the thing a reader needs.

Transcript of the Milestone 2 acceptance check. Every name each new or changed fence
uses was resolved in `cabal repl baikai-smoke:test:doc-shapes`, which has all seven
packages in scope:

```text
newProviderRegistryFrom [ClaudeApi.claudeMessagesProvider, …] :: IO ProviderRegistry
\reg -> assertRegistered reg [AnthropicMessages, OpenAIChatCompletions]
  :: ProviderRegistry -> IO ()
mkModel OpenAIChatCompletions "deepseek-chat" "https://api.deepseek.com" :: Model
\str cmp -> apiProviderWith (Custom "my-llm-host") str cmp
  & #describeThinking .~ (\_model _opts -> noThinkingRequested)
  & #strengthCeiling .~ EvidenceRequestedOnly
  :: (Model -> Context -> Options -> Stream IO AssistantMessageEvent)
     -> (Model -> Context -> Options -> IO Response) -> ApiProvider
\p -> apiProviderWith (Custom "x") (liftCompleteToStream p) p
  :: (Model -> Context -> Options -> IO Response) -> ApiProvider
streamRequestEach :: (AssistantMessageEvent -> IO ())
                  -> Model -> Context -> Options -> IO Response
streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]
\resp -> (responseError resp, resp ^. #message . #usage)
  :: Response -> (Maybe BaikaiError, Usage)
\err -> (isRetryable err, retryAfterSeconds err) :: BaikaiError -> (Bool, Maybe Int)
\(ApiKeyEnvChain ns) -> ns :: ApiKeySource -> [String]
```

The last line is worth keeping: `ApiKeyEnv` and `ApiKeyEnvChain` carry `String`, not
`Text`, because `lookupEnv` takes one. The guide's new table names the sources without
claiming a type, so it is right either way, but a reader who assumed `Text` would be
wrong.

While the guide work was in progress another change landed in this repository as commit
`dc25860`, "docs(user): adopt shared OKF documentation profile": it converts
`docs/user/` into a fourth OKF bundle, prepending eleven lines of frontmatter to each of
the eleven guides and adding `docs/user/index.md`, `docs/user/log.md`,
`mori/user-documentation-profile.dhall` and a `user-documentation` bundle entry in
`mori.dhall`. It changed nothing else in any guide — every file is `11 insertions(+), 0
deletions(-)`. Two consequences for this plan, both in Milestone 4: the Decision Log's
"`mori.dhall`'s `docs` list is unchanged" now holds only for this plan's own edits, and
the validator list gains `okf validate docs/user`. A guide this plan edits is now also a
concept whose `generated.at` the bundle's log enforces.


## Decision Log

Record every decision made while working on the plan.

- Decision: The Shape-compile mechanism is a new test-suite stanza `doc-shapes` in
  `baikai-smoke/baikai-smoke.cabal` with sources under `baikai-smoke/doc-shapes/`: one
  module per record with a `haskell` fence (`Shape/Cap1.hs` … `Shape/Cap22.hs`, twenty
  of them — CAP-3's Shape is `console` and CAP-18's is `kdl`), a shared
  `Shape/Fixtures.hs` supplying the free names the blocks use, and a `DocShapes.hs` main
  that reads every `docs/capabilities/*.md`, extracts the fenced `haskell` block under
  `## Shape`, and compares it byte-for-byte with the region between `-- BEGIN CAP-N` and
  `-- END CAP-N` in that record's module. Compiling the suite proves every block
  type-checks; running it proves record and module agree. The exact command is
  `cabal test baikai-smoke:test:doc-shapes`; the suite is part of `cabal test all` and so
  of the release skill's keyless gate.
  Rationale: `baikai-smoke` is the one package that may depend on all seven publishable
  packages without touching publish order, is never uploaded, and is already described
  in the README as "useful as worked examples". The extractor lives inside the test
  executable, not in a shell script, so drift fails the same command that proves
  compilation. A doctest dependency was rejected: the blocks live in OKF Markdown, not in
  Haddock, so doctest cannot see them; a Markdown-to-literate-Haskell tool would add a
  build-tool and Nix packaging the repository does not have; and the blocks reference
  free names on purpose — a record should not carry fixture noise — which doctest cannot
  supply without a preamble in the record.
  Date: 2026-08-27
- Decision: The Shape convention, stated in `docs/capabilities/index.md`: a block is
  either a sequence of top-level declarations or the body of an `IO` `do` block; it may
  begin with a preamble of `import` lines followed by one blank line; `&`, `.~`, `^.`
  (`Control.Lens`), the `#field` labels (`Data.Generics.Labels ()`) and
  `Data.Vector qualified as V` are assumed in scope, as in the README's quick taste, and
  are not repeated per record. The checker strips a uniform two-space indent from the
  module region before comparing and requires each preamble import to appear verbatim in
  the module, which may import more. Blocks are compiled, never executed; every fixture
  is an `error` thunk saying so.
  Rationale: the smallest rule that keeps a record readable, lets one module family hold
  both fragment-shaped and declaration-shaped blocks, and keeps the imports a reader
  actually needs visible in the record.
  Date: 2026-08-27
- Decision: The documented registration path is `register` for the process-global
  registry; `newProviderRegistryFrom [ClaudeApi.claudeMessagesProvider, …]` for an
  explicit one; `registerApiProvider (ClaudeCli.claudeCliProvider cfg)` or
  `registerApiProviderWith reg (…)` for a configured CLI provider; and
  `assertRegistered reg [tags]` at startup. `registerWith`, `registerWithRegistry` and
  `registerWithRegistryAndConfig` appear nowhere in README, guides or records afterwards.
  Rationale: EP-10 removes the deprecated shims; the four `*Provider` values and
  `newProviderRegistryFrom` are what the tests and smokes use;
  `getting-started.md:82-87` already teaches it.
  Date: 2026-08-27
- Decision: Names this plan cannot know until the siblings land are angle-bracket
  placeholders resolved before Milestone 1: `<apiProviderBase>` (EP-10's base value for
  `ApiProvider`), `<aborted>` (EP-10: `Aborted` produced-and-failure, or retired),
  `<baseUrlRule>` (EP-2: a trailing `/v1` deduplicated, or refused),
  `<cutOffArguments>` (EP-4's representation of a cut-off tool call),
  `<responseFormatShape>`, `<kitConfigBase>`, `<callLogConfigBase>` (EP-10 constructor
  decisions), `<codexRefusedApprovals>` (EP-1) and `<unsupportedModelAdjustment>`
  (EP-3). Each appears once in the Plan of Work with both readings written out.
  Rationale: PLANS.md forbids outsourcing decisions to the reader, but the MasterPlan
  assigns these to other plans; writing both readings keeps this plan self-contained
  while the implementer copies the winner from the owning plan's Outcomes.
  Date: 2026-08-27
- Decision: The 0.5.0.0 changelog gaps are filled *inside* `[baikai 0.5.0.0]`, each
  entry ending "(entry added 2026-08-27; the behaviour shipped in 0.5.0.0)", and the
  three wrong sentences (`:83-85`, `:86-89`, `:127`) are rewritten in place. This plan's
  own changes go under `[Unreleased]` (or the versioned sections EP-10 has cut).
  Rationale: a reader of the 0.5.0.0 section is who needs to know strict mode and the
  breaking `describeThinking` field shipped then; the dated parenthetical keeps the
  amendment honest.
  Date: 2026-08-27
- Decision: A record whose behaviour an earlier plan changed keeps its `since` and
  describes the change in its body (the release skill's "grew" rule); `generated.at`
  advances to the edit date and `generated.by` to this run; one dated `log.md` entry
  names every record touched. No record is added, renumbered or retired.
  Rationale: `since` is read by consumers pinning older releases; the profile enforces
  the log against concept timestamps (`okf log docs/capabilities --check-stale`).
  Date: 2026-08-27
- Decision: No new guide, so `mori.dhall`'s `docs` list is unchanged; every new section
  fits an existing guide. `mori register` still runs in Milestone 4 because editing
  concept Markdown does not refresh Mori's read model.
  Rationale: the eleven registered guides already partition the surface.
  Date: 2026-08-27
- Decision: No new ADR. The Shape convention lives in `docs/capabilities/index.md`, the
  bundle's own machine-validated contract; nothing here changes an architectural
  boundary, interface ownership or a constraint on code. Revisit at the distillation
  pass if the convention turns out to constrain code authors.
  Date: 2026-08-27
- Decision: The nine angle-bracket placeholders are resolved as follows, each read from
  the owning plan's Outcomes & Retrospective and then confirmed against the code.
  `<apiProviderBase>` — EP-10 exports no base *value*; it exports the smart constructors
  `Baikai.Provider.apiProvider tag producer` and `apiProviderWith tag producer complete`
  (`baikai/src/Baikai/Provider.hs:14-15,68-74`), and `ApiProvider` exports its five
  selectors and no constructor, so a custom provider is a record update on
  `apiProviderWith …`. `<aborted>` — retired: `Aborted` is gone from `StopReason`
  (`git grep -n "Aborted" -- '*.hs'` matches only the unrelated evidence status
  `CallAborted`), so every guide mention is deleted rather than rewritten.
  `<baseUrlRule>` — deduplication: one trailing `/v1` is folded, segment-wise, so
  `/v10` and `/v1beta` are ordinary segments (`baikai/src/Baikai/Url.hs:186-196`); EP-2
  already wrote the rule into `docs/user/models-and-providers.md:180-190`, so Milestone 2
  verifies rather than writes it. `<cutOffArguments>` — one rule,
  `Baikai.Content.toolArgumentsFromText`, keeps the raw partial text as a JSON string and
  `Baikai.Content.isCutOffToolCall` names the state
  (`baikai/src/Baikai/Content.hs:97-132`). `<responseFormatShape>` — `JsonSchema` now
  carries a `JsonSchemaFormat` payload built by `jsonSchemaFormat name schema` with
  `strict = False`, the constructor unexported
  (`baikai/src/Baikai/ResponseFormat.hs:11-51`); CAP-5 already shows it.
  `<kitConfigBase>` — unchanged: `KitConfig`'s constructor is still exported
  (`baikai-kit/src/Baikai/Kit/Config.hs:2,22`), so CAP-21's `KitConfig {…}` stands.
  `<callLogConfigBase>` — `callLogConfig "/tmp/baikai.jsonl"`, which defaults
  `enabled = True` (`baikai/src/Baikai/Cost/Log.hs:29-30,89-98`); CAP-7 already shows it.
  `<codexRefusedApprovals>` — `CodexApprovalUntrusted` and `CodexApprovalOnFailure`,
  refused as `SafetyNotExpressible`
  (`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs:14-15,148,163,192-193`).
  `<unsupportedModelAdjustment>` — the OpenAI side records
  `thinking_dropped_unsupported_model`, and EP-3 added two sampling kinds,
  `sampling_dropped_unsupported_model` and `sampling_dropped_unsupported_api`
  (`baikai/src/Baikai/Evidence.hs:340-383`), which the adjustment table must also list.
  Date: 2026-08-27
- Decision: Four of this plan's prescribed edits are already done by the plan that owned
  the behaviour, and are verified rather than rewritten: `registerWith` is gone from every
  guide and record (grep 1 is empty at the start), the base-URL composition rule is in
  `models-and-providers.md`, CAP-5's, CAP-7's, CAP-10's and CAP-18's `Shape` blocks were
  already updated, and `Trace/Event.hs`'s Haddock was corrected in `1717694` (EP-9's
  Outcomes say so). Where a sibling has already landed a sentence this plan prescribes,
  this plan leaves it alone and says so here rather than rewording it.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository, `/Users/shinzui/Keikaku/bokuno/baikai`, is a multi-package Haskell
workspace built with cabal (`cabal.project` at the root) inside a Nix dev shell
(`nix develop`). Seven packages are published to Hackage — `baikai/` (core),
`baikai-claude/` and `baikai-openai/` (providers), `baikai-trace-otel/`,
`baikai-effectful/`, `baikai-kit/`, `baikai-agent/` (which ships the `baikai`
executable) — and `baikai-smoke/` is a test-suite-only package that is never uploaded.
Versions at the start of the initiative: 0.5.0.0 core and providers, 0.3.0.3 trace-otel
and effectful, 0.1.0.4 kit, 0.1.0.0 agent. EP-10 bumps them; this plan does not.

Terms, in plain language. A *guide* is one of the eleven Markdown files under
`docs/user/`, each registered in `mori.dhall`'s `docs` list; `README.md` and
`baikai-effectful/README.md` count as guides here. An *OKF bundle* is a directory of
Markdown *concepts* with YAML frontmatter that the `okf` tool validates against a
*profile* (a Dhall descriptor of required fields); this repository has
`docs/capabilities/`, `docs/reviews/` and `docs/improvement-requests/`. Inside a bundle
`index.md` and `log.md` are reserved files, not concepts; `log.md` is a dated change log
the profile enforces, so a concept edited after the newest entry fails
`--log-enforce`. A *capability record* is one concept in `docs/capabilities/`: one thing
a consumer adopts and verifies, with `capabilityId` (`CAP-1` … `CAP-22`), `status`,
`stability`, `since` (the version of the first listed package in which it became
available — never advanced), `interface`, `requires`, `evidence`, and a body with a
`## Shape` and a `## Limits` section; the conventions are in `docs/capabilities/index.md`
and the release rules in `agents/skills/release/SKILL.md` step 3. A *Shape block* is
the fenced code under `## Shape`: the shortest thing a consumer copies to adopt the
capability. *Haddock* is the `-- |` documentation-comment convention `cabal haddock`
renders into Hackage's HTML; a malformed comment or unresolved `'link'` fails the
build. A *drift check* is a repository check whose failure means a document and the code
disagree. *Keep a Changelog* is `CHANGELOG.md`'s format: `## [Unreleased]` on top, then
one `## [<package> <version>] - <date>` section per release with `### Added` /
`### Changed` / `### Fixed`, breaking entries marked `**Breaking:**`.

The scope-defining review is `docs/reviews/correctness-and-api-review-follow-up.md`,
Theme H: H.1 the twelve non-compiling Shape blocks; H.2 the deprecated registration path
and the undocumented helpers; H.3 stale claims in guides and records; H.4 stale Haddock.
Its "Disposition of REV-1" adds residuals this plan owns: `docs/user/tools.md:70,231-237`
(Themes 4 and 5), the GC-eventual abort caveat (Theme 7.3, EP-9 owns the fix and this
plan checks the prose), and the "API design recommendations" residual naming
`responseError`, `streamRequestEach`, `streamRequestList`, `ApiKeyEnvChain`, `mkModel`,
the sampling options and `streaming.md:15-19`. Line numbers in this plan are as of
commit `5411947`; they will have moved by the time the earlier plans land, so use them
to find a sentence, not to edit blind.

Sibling plans. This plan hard-depends on EP-10, `docs/plans/67-freeze-the-public-surface.md`,
because the guides and records must name the final exports, and soft-depends on every
other plan because it describes their final behaviour. The ten sibling plans were
skeletons when this was drafted, so **before starting, open each plan's Outcomes &
Retrospective and Decision Log and reconcile this plan against them**; the owning plan
wins a disagreement, which is recorded in both Decision Logs. The MasterPlan's
Integration Points say every code plan updates the Haddock of what it changes and the
record that names the behaviour, and adds `[Unreleased]` entries in the same commits, so
this plan reconciles rather than discovers. What each plan will have touched:

- EP-1 (`docs/plans/58-…`: threaded RTS, SIGKILL, drained output kept, UTF-8 output,
  codex approval refusal, JSONL, TOML): `unattended-agent-runs.md` (timeout and
  "Streams"), `interactive-launches.md:225-232` (the `CodexSandbox` row),
  `agent-assets.md:67-70`, CAP-16, 17, 18, 22, Haddock in `baikai-agent/src/Baikai/Agent/Run.hs`,
  `baikai/src/Baikai/Interactive.hs`, `AgentAssets.hs`, `Provider/Cli/Internal.hs`.
- EP-2 (`59-…`: one host parser, header redaction, embedding keys, no redirects, base-URL
  rule): `models-and-providers.md:37-42,88-113`, `getting-started.md:132`, CAP-1, 6, 14,
  Haddock in `Compat.hs`, `Auth.hs`, `Options.hs`, `Model.hs`, `Embedding.hs`, both `Sse.hs`.
- EP-3 (`60-…`: catalog-driven thinking style and sampling support, OpenAI reasoning
  controls gated on `Model.reasoning`): `models-and-providers.md:168-176`,
  `model-call-evidence.md:96-103`, CAP-3, 11, 13, 14, 19, Haddock in `Compat.hs`,
  `Model.hs`, `Models/Generated.hs`, `Claude/Internal/Request.hs`, `OpenAI/Shape.hs`.
- EP-4 (`61-…`: cancellable workers, `EventStart` first everywhere, block closing,
  cut-off tool calls): `streaming.md:27-33,153-172`, `tools.md` (cut-off arguments),
  CAP-2, 4, 13, 14, Haddock in `Stream/Event.hs`, `Stream.hs`, both `Api.hs`.
- EP-5 (`62-…`: mid-stream classification, in-band error frames, 413, HTTP-date,
  `timeoutMs` edges): CAP-8, Haddock in both `Internal/ErrorClass.hs`, `Error.hs`, both
  `Transport.hs`.
- EP-6 (`63-…`: the ceiling gates every field, `allowedTools` as a grant, ceiling-file
  provenance, CLI truthfulness, 0.2 config): `unattended-agent-runs.md:265-285,366-383,488-555`,
  CAP-17, 18, Haddock in `Agent.hs`, `Agent/Config.hs`, `Agent/Cli.hs`.
- EP-7 (`64-…`: symlink-safe, exit-free kit): `kit.md:102-105,136-145`, CAP-21, Haddock
  under `baikai-kit/src/Baikai/Kit/`.
- EP-8 (`65-…`: truthful evidence, strict means a record exists, observed model in the
  span, endpoint default, digest without cost, `ApiProvider` ceiling):
  `model-call-evidence.md:65-76,181-230`, CAP-9, 10, 19, `docs/adr/0002-…`–`0004-…`,
  Haddock in `Trace.hs`, `Trace/Event.hs`, `Evidence.hs`, `Evidence/Build.hs`,
  `OpenTelemetry.hs`.
- EP-9 (`66-…`: sinks that cannot hang or corrupt, OTel parent context, abort
  semantics): `model-call-evidence.md:219-225`, CAP-9 `:47-51`, CAP-10, Haddock in
  `Trace.hs`, `Trace/Sink.hs`, `OpenTelemetry.hs`.
- EP-10 (`67-…`: constructor policy, `.Internal` relocations, shim removal, version
  bumps, `Aborted`, naming): every guide naming a removed shim or hidden constructor,
  CAP-1, 13, 14, 15, 16, 20, 21, `CHANGELOG.md` version sections, Haddock in
  `Baikai.hs`, `Provider/Registry.hs`, `ResponseFormat.hs`, both `Api.hs`.

ADR context. `docs/adr/` is a plain-file convention
(`docs/adr/0001-architecture-decision-record-convention.md`), so no handle allocation
applies. Three records constrain what this plan may *say*:
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md` (never describe an
observed field as backfilled), `docs/adr/0003-the-adapter-owns-the-translation-description.md`
(the adjustment table lists only adjustments an adapter emits) and
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` (no guide implies signing,
sanctioning, provider internals or retries). `docs/adr/0004-…` is revised by EP-8 and
this plan cites its revised text. No cross-repository ADR applies. One repository rule
holds throughout: record fields never carry Hungarian-style prefixes, even in the
checker's internal types.


## Plan of Work

Four milestones fixed by the MasterPlan. Each leaves the project building and its
validators green from the repository root; all paths are repository-relative. Before
Milestone 1, do the reconciliation step in Progress and run the starting-state greps.


### Milestone 1 — every capability `Shape` compiles under a test

Scope: build the mechanism, then use it to rewrite every Shape that does not compile.
At the end `baikai-smoke` has a second test-suite, `doc-shapes`, that compiles twenty
small modules and, when run, reports each record as agreeing with its module; the
twelve blocks the review named plus CAP-7 and CAP-14 are rewritten; and
`docs/capabilities/index.md` states the convention.

**The stanza.** Append to `baikai-smoke/baikai-smoke.cabal`:

```cabal
-- Compiles every fenced `haskell` block under docs/capabilities/ and, when run,
-- checks each block still matches the marked region of its Shape.CapN module.
-- Never contacts a provider; every fixture is an error thunk.
test-suite doc-shapes
  import:         common-options
  type:           exitcode-stdio-1.0
  hs-source-dirs: doc-shapes
  main-is:        DocShapes.hs
  other-modules:
    Shape.Cap1  Shape.Cap2  Shape.Cap4  Shape.Cap5  Shape.Cap6  Shape.Cap7
    Shape.Cap8  Shape.Cap9  Shape.Cap10 Shape.Cap11 Shape.Cap12 Shape.Cap13
    Shape.Cap14 Shape.Cap15 Shape.Cap16 Shape.Cap17 Shape.Cap19 Shape.Cap20
    Shape.Cap21 Shape.Cap22 Shape.Fixtures

  build-depends:
    , aeson
    , baikai
    , baikai-agent
    , baikai-claude
    , baikai-effectful
    , baikai-kit
    , baikai-openai
    , baikai-trace-otel
    , base                  >=4.20 && <5
    , containers
    , directory
    , effectful-core        ^>=2.6
    , filepath
    , generic-lens
    , hs-opentelemetry-api  >=1.0 && <1.1
    , lens                  ^>=5.3
    , settei-env            ^>=0.2
    , streamly-core         ^>=0.3
    , text                  ^>=2.1
    , vector
```

The `effectful-core`, `hs-opentelemetry-api` and `settei-env` bounds copy the owning
packages' bounds (`baikai-effectful/baikai-effectful.cabal:55`,
`baikai-trace-otel/baikai-trace-otel.cabal:56`, `baikai-agent/baikai-agent.cabal`) so
the build plan carries one copy. `cabal.project` already lists `baikai-smoke`, so
`cabal test all` and `nix flake check` pick the suite up without further wiring.

**The fixtures.** `baikai-smoke/doc-shapes/Shape/Fixtures.hs` exports every free name a
block uses; each is an `error` thunk, and the header says why:

```haskell
-- | Free names the capability Shape blocks refer to. Every value is an
-- @error@ thunk: the blocks are compiled to prove they type-check against
-- the current exports and are never run, because running one would need
-- a provider. Add a fixture when a new block needs one; never make one
-- do anything.
module Shape.Fixtures (model, modelWithCliTag, ctx, opts, registry, dispatcher,
  getTimeTool, personSchema, tracer, request, config, reportRefusal,
  reportFailure, backOff, retry, giveUp, use, step, initial) where

fixture :: String -> a
fixture name = error ("doc shape fixture " <> name <> " is never evaluated")

model :: Model
model = fixture "model"
```

and so on, with these types: `modelWithCliTag :: Model`, `ctx :: Context`,
`opts :: Options`, `registry :: ProviderRegistry`, `dispatcher :: ToolCall -> IO ToolResult`,
`getTimeTool :: Tool`, `personSchema :: Aeson.Value`, `tracer :: Otel.Tracer` (import
the type from the same module `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`
uses), `request :: Baikai.Agent.AgentRunRequest`, `config :: ClaudeAgentConfig`,
`reportRefusal, reportFailure :: Text -> IO a`, `backOff :: Maybe Int -> IO ()`,
`retry, giveUp :: IO ()`, `use :: Response -> IO ()`,
`step :: Int -> AssistantMessageEvent -> Int`, `initial :: Int`. The compiler names any
fixture a block still lacks.

**The shape modules.** Every `baikai-smoke/doc-shapes/Shape/CapN.hs` has one exported
binding and one marker pair. All imports — the fixture import and the record's own
preamble imports — sit above the markers; the region holds only the block's body. A
fragment-shaped block sits inside a `do` at two-space indent (CAP-4):

```haskell
-- | CAP-4, docs/capabilities/tool-calling.md. DocShapes.hs compares the
-- region between the markers, indent-stripped, with the record's block.
module Shape.Cap4 (shape) where

import Baikai
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Vector qualified as V
import Shape.Fixtures (dispatcher, getTimeTool, model)

shape :: IO ()
shape = do
  -- BEGIN CAP-4
  let ctx = contextOf [user "What time is it? Use the tool."]
        & #tools .~ V.singleton getTimeTool
      opts = emptyOptions & #toolChoice .~ Just ToolChoiceAuto
  (finalCtx, resp) <- runToolLoop 8 dispatcher model ctx opts
  print (responseError resp, length (finalCtx ^. #messages))
  -- END CAP-4
```

and a declaration-shaped block sits at column zero (CAP-20):

```haskell
-- | CAP-20, docs/capabilities/effectful-binding.md.
module Shape.Cap20 (program) where

import Baikai.Effectful
import Effectful (Eff, (:>))
import Shape.Fixtures (ctx, model, opts)

-- BEGIN CAP-20
program :: Baikai :> es => Eff es Response
program = complete model ctx opts
-- END CAP-20
```

The rule the checker enforces: the record's block is split at its first blank line into
a *preamble* (zero or more lines starting with `import `) and a *body*; every preamble
line must occur verbatim at column zero somewhere in the module; the body must equal the
lines strictly between `-- BEGIN CAP-N` and `-- END CAP-N` after a uniform two-space
indent is removed when every non-blank region line carries one. A block with no import
lines is all body.

**The checker.** `baikai-smoke/doc-shapes/DocShapes.hs` is `module Main (main) where`.
It finds the repository root by walking up from the current directory to the directory
holding `cabal.project` (the trick `baikai/gen/GenModels.hs` uses for `baikai.cabal`),
lists `docs/capabilities/*.md` minus `index.md` and `log.md`, and for each reads the
`capabilityId:` line, finds the line `## Shape`, takes the first fence after it whose
opener is exactly ```` ```haskell ````, and compares it with
`baikai-smoke/doc-shapes/Shape/Cap<N>.hs` by the rule above. Two completeness checks
keep it honest: every module on disk must have a record with a `haskell` block and vice
versa. The CAP-18 `kdl` block is not skipped — the checker writes it to a temporary
file, builds `AgentConfigPaths {userConfig = Nothing, repoConfig = Just path}`, expects
`Baikai.Agent.Config.listAgentJobs` to return exactly the job the block declares, and
expects `resolveAgentJob paths (envSnapshot []) [] "review"` to be `Right`
(`envSnapshot` from `Settei.Env`, as `baikai-agent/test/ConfigTests.hs:35,99-100` uses
it). Configuration is data, so resolving it is the honest equivalent of compiling.
Output is one line per record and a summary; drift names the record, the module and the
first differing line on each side, and exits 1:

```text
CAP-1  docs/capabilities/unified-provider-calls.md  agrees with Shape/Cap1.hs
CAP-2  docs/capabilities/typed-streaming.md         agrees with Shape/Cap2.hs
CAP-3  docs/capabilities/generated-model-catalog.md no haskell Shape (console); skipped
…
CAP-18 docs/capabilities/baikai-agent-command.md    kdl Shape resolves: jobs [review]
…
CAP-22 docs/capabilities/agent-asset-layouts.md     agrees with Shape/Cap22.hs
doc-shapes: 20 haskell blocks agree, 1 kdl block resolves, 1 skipped
```

```text
CAP-12 docs/capabilities/prompt-cache-retention.md  DIFFERS from Shape/Cap12.hs
  record line 3:  print (resp ^. #message . #usage . #cacheReadTokens)
  module line 3:  print (resp ^. #usage . #cacheReadTokens)
doc-shapes: 1 block differs
```

**The rewritten blocks**, each as the record will show it, grounded in the signatures
at `5411947`; a placeholder marks a dependence on a sibling plan.

CAP-4, `docs/capabilities/tool-calling.md` — `#tools` lives on `Context`, and
`runToolLoop :: Int -> (ToolCall -> IO ToolResult) -> Model -> Context -> Options -> IO (Context, Response)`
takes the budget first (`baikai/src/Baikai/Provider/Registry.hs:238-245`):

```haskell
let ctx = contextOf [user "What time is it? Use the tool."]
      & #tools .~ V.singleton getTimeTool
    opts = emptyOptions & #toolChoice .~ Just ToolChoiceAuto
(finalCtx, resp) <- runToolLoop 8 dispatcher model ctx opts
print (responseError resp, length (finalCtx ^. #messages))
```

CAP-5, `docs/capabilities/structured-output.md` — `JsonSchema` has three fields
(`baikai/src/Baikai/ResponseFormat.hs:26-30`). `<responseFormatShape>`: if EP-10 turned
it into a payload record, use that constructor instead:

```haskell
let opts = emptyOptions
      & #responseFormat .~ Just JsonSchema {name = "person", schema = personSchema, strict = True}
```

CAP-7, `docs/capabilities/usage-and-cost-accounting.md` — `runRequestWithLog` and
`CallLogConfig` live in `Baikai.Cost.Log`. `<callLogConfigBase>`: if EP-10 hides the
constructor, write `<callLogConfigBase> & #path .~ "/tmp/baikai.jsonl" & #enabled .~ True`:

```haskell
import Baikai.Cost.Log (CallLogConfig (..), runRequestWithLog, withCallLog)

withCallLog CallLogConfig {path = "/tmp/baikai.jsonl", enabled = True} $ \h ->
  runRequestWithLog h model ctx opts
```

CAP-8, `docs/capabilities/categorised-error-model.md` — teach `responseError`, which
synthesises an error for a nonconforming provider, rather than raw `#errorInfo`:

```haskell
resp <- completeRequest model ctx opts
case responseError resp of
  Just err | isRetryable err -> backOff (retryAfterSeconds err) >> retry
  Just err                   -> giveUp
  Nothing                    -> use resp
```

CAP-9, `docs/capabilities/call-tracing.md` — the `import` fix: `Baikai` omits tracing
(`baikai/src/Baikai.hs:6-9`), `withTrace` is `Baikai.Trace.withTrace`, and
`fileSink :: FilePath -> IO TraceSink` (`baikai/src/Baikai/Trace/Sink.hs:51`):

```haskell
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink (fileSink)

sink <- fileSink "/tmp/baikai-trace.jsonl"
resp <- withTrace sink model ctx opts
```

CAP-12, `docs/capabilities/prompt-cache-retention.md` — usage sits on the assistant
payload (`baikai/src/Baikai/Response.hs:42-44`):

```haskell
let opts = emptyOptions & #cacheRetention .~ Just CacheRetentionLong
-- then, after the call:
print (resp ^. #message . #usage . #cacheReadTokens)
```

CAP-13, `docs/capabilities/anthropic-messages-backend.md` — `registerWith` is not
exported by `Baikai.Provider.Claude.Api`; the explicit-registry path is a value:

```haskell
import Baikai.Provider.Claude.Api qualified as ClaudeApi

ClaudeApi.register
-- or, keeping registration out of global state:
registry <- newProviderRegistryFrom [ClaudeApi.claudeMessagesProvider]
```

CAP-14, `docs/capabilities/openai-chat-completions-backend.md` — the base URL is the
host root (`baikai/data/models/deepseek.json:3`); the transport appends
`/v1/chat/completions` (see `<baseUrlRule>` in Milestone 2):

```haskell
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi

OpenAIApi.register
-- a non-OpenAI host is just a Model with a different baseUrl:
let m = mkModel OpenAIChatCompletions "deepseek-chat" "https://api.deepseek.com"
```

CAP-16, `docs/capabilities/interactive-launches.md` —
`interactiveLaunchRequest :: Text -> InteractiveLaunchRequest` takes the prompt,
`modelId :: Maybe Text`, and the config is the required first argument
(`baikai/src/Baikai/Interactive.hs:96-106`,
`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs:85`); `renderAgentRenderError`
is in `Baikai.Agent`, which the umbrella omits:

```haskell
import Baikai.Agent (renderAgentRenderError)
import Baikai.Provider.Claude.Interactive (defaultClaudeInteractiveConfig, launchClaudeInteractive)
import System.Exit (exitWith)

result <-
  launchClaudeInteractive
    defaultClaudeInteractiveConfig
    ( interactiveLaunchRequest "Inspect this project and suggest next steps."
        & #modelId .~ Just "claude-opus-5"
        & #safety .~ ClaudeAllowedTools ["Read", "Grep"]
    )
case result of
  Left refusal -> reportRefusal (renderAgentRenderError refusal)  -- nothing was started
  Right done -> exitWith (done ^. #exitCode)
```

CAP-17, `docs/capabilities/unattended-agent-runs.md` — `AgentRenderError` has no
`Exception` instance (the only one in core is `BaikaiError`,
`baikai/src/Baikai/Error.hs:112`), so `either throwIO pure` does not type-check; match:

```haskell
import Baikai.Agent
import Baikai.Agent.Run (runAgentCommand)
import Baikai.Provider.Claude.Agent (claudeAgentCommand)
import System.Exit (exitWith)

case claudeAgentCommand config request of
  Left refusal -> reportRefusal (renderAgentRenderError refusal)  -- nothing was started
  Right (cmd, thinking) -> do
    outcome <- runAgentCommand Nothing thinking request cmd
    case outcome ^. #outcome of
      Right result -> exitWith (result ^. #exitCode)
      Left failure -> reportFailure (renderAgentRunFailure failure)
```

`result ^. #exitCode` works through generic-lens because `AgentRunResult` derives
`Generic` although it exports no selectors (REV-2 G.6).

CAP-18, `docs/capabilities/baikai-agent-command.md` — the keys are `jobs.<name>.provider`
and `jobs.<name>.safety.capability`, and `working-dir` is required
(`baikai-agent/src/Baikai/Agent/Config.hs:302-303,427,505-513`); keep exactly the keys
EP-6's Outcomes leave in the 0.2 schema:

```kdl
// .baikai/agents.kdl
jobs {
  review {
    provider    "claude"
    working-dir "."
    model       "claude-opus-5"
    output      "capture"
    safety { capability "read-only" }
  }
}
```

CAP-19, `docs/capabilities/model-call-evidence.md` — the same `import` fix;
`evidenceRequest` reaches `Baikai` through `Baikai.Evidence`:

```haskell
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink (fileSink)

let opts = emptyOptions & #evidence .~ Just (evidenceRequest "nightly-review-2026-08-10")
sink <- fileSink "/tmp/evidence.jsonl"
resp <- withTrace sink model ctx opts
```

CAP-20, `docs/capabilities/effectful-binding.md` —
`complete :: Baikai :> es => Model -> Context -> Options -> Eff es Response`
(`baikai-effectful/src/Baikai/Effectful.hs`), not `Eff es Text`:

```haskell
import Baikai.Effectful
import Effectful (Eff, (:>))

program :: Baikai :> es => Eff es Response
program = complete model ctx opts
```

CAP-22, `docs/capabilities/agent-asset-layouts.md` — `ProjectScope` is `baikai-kit`'s
`KitScope`; the asset API takes `InteractiveProjectScope`, and
`skillAsset :: AgentAssetProvider -> AgentAssetScope -> FilePath -> AgentAssetLayout`
already returns the layout (`baikai/src/Baikai/AgentAssets.hs:62-66`):

```haskell
import Baikai.AgentAssets
import Baikai.Interactive (InteractiveProvider (..), InteractiveScope (..))

layout :: AgentAssetLayout
layout = skillAsset InteractiveClaude InteractiveProjectScope "reviewer"
-- layout ^. #path is ".claude/skills/reviewer"
```

The blocks the review found clean (CAP-1, 2, 6, 10, 11, 15, 21) are copied into their
modules unchanged, except that CAP-21's `KitConfig {…}` becomes a record update on
`<kitConfigBase>` if EP-10 hides that constructor, and CAP-2 gains the preamble
`import Streamly.Data.Fold qualified as Fold` / `import Streamly.Data.Stream qualified as Stream`.

**The convention, written down.** Add to `docs/capabilities/index.md`, after "Evidence
discipline", a "Shape blocks" section of three short paragraphs: what a Shape is for;
the rule from the Decision Log; and "Every `haskell` Shape is compiled by
`cabal test baikai-smoke:test:doc-shapes`, which also fails when a record and its
`baikai-smoke/doc-shapes/Shape/CapN.hs` twin diverge — edit both together."

Acceptance: `cabal build baikai-smoke:test:doc-shapes` succeeds;
`cabal test baikai-smoke:test:doc-shapes` prints twenty `agrees` lines, one `resolves`
line, one `skipped` line and exits 0; editing one character inside any record's
`haskell` fence makes it print `DIFFERS` and exit 1; the keyless `cabal test all` is
green.


### Milestone 2 — README and guides teach the supported registration path and the helpers that exist

Scope: H.2 in full plus the API-recommendations residual. At the end no guide names a
deprecated shim, and each helper and the sampling options has a home.

**Registration.** In `README.md:129-137` rewrite the "Registry" paragraph: simple
programs call each vendor package's `register :: IO ()`; tests and larger applications
build a `ProviderRegistry` with `newProviderRegistryFrom` from the provider values
`ClaudeApi.claudeMessagesProvider`, `OpenAIApi.openaiChatProvider`,
`ClaudeCli.claudeCliProvider cfg` and `CodexCli.codexCliProvider cfg`, and dispatch with
`completeRequestWith` / `streamRequestWith`; `assertRegistered reg [tags]` at startup
throws once, early, when an expected tag has no handler; otherwise an unregistered tag
returns an error-shaped `Response` (`ProviderUnavailable`). Keep the tag table. In
`docs/user/cli-providers.md:108-162` delete the sentence at `:113-114` and replace both
`registerWith` examples with:

```haskell
import Baikai.Provider.Claude.Cli
  ( claudeCliProvider, defaultClaudeCliConfig, executable, extraArgs, workingDir )
import Baikai.Provider.Registry (registerApiProvider)

main :: IO ()
main =
  registerApiProvider
    ( claudeCliProvider
        defaultClaudeCliConfig
          { executable = "/Users/me/.local/bin/claude"
          , extraArgs = ["--allowed-tools", "Bash,Read"]
          , workingDir = Just "/path/to/project"
          }
    )
```

and the Codex mirror with `codexCliProvider`, `skipGitRepoCheck` and `ephemeral`, then:
"Into an explicit registry, pass the same value to `registerApiProviderWith reg` or
list it in `newProviderRegistryFrom`." In `docs/user/models-and-providers.md:230-236`
replace "register handlers with `registerApiProviderWith` or a provider package's
`registerWithRegistry`" with the `newProviderRegistryFrom` sentence and add
`assertRegistered`. `getting-started.md:82-87` is right; add
`ClaudeCli.claudeCliProvider defaultClaudeCliConfig` to its list so all four values are
named once.

**`responseError`.** After the blocking example in `getting-started.md:144-152` add a
"Did it fail?" paragraph: `responseError :: Response -> Maybe BaikaiError` is the one
question to ask; it is `Just` exactly when `stopReason = ErrorReason`, carries the
provider's classified `errorInfo`, and synthesises an `OtherError` from `errorMessage`
when a nonconforming provider omitted it (`baikai/src/Baikai/Response.hs:112-121`);
`completeText` and `runToolLoop` use it. Cross-reference it from `streaming.md:126-131`.
`<aborted>`: if EP-10 retired `Aborted` the sentence reads "is `ErrorReason` on
failure"; if EP-10 made it a produced failure reason, say `responseError` is `Just` for
it too.

**`streamRequestEach` and `streamRequestList`.** Replace `streaming.md:15-19` with: the
stream is a `streamly` `Stream IO AssistantMessageEvent` and the fold patterns import
`Streamly.Data.Stream` and `Streamly.Data.Fold`; a caller who would rather not depend on
`streamly` uses
`streamRequestEach :: (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response`,
which invokes the callback once per event and returns the same reassembled `Response`
`completeRequest` would, or
`streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]`; both
have `…With` variants taking a `ProviderRegistry` (`baikai/src/Baikai/Stream.hs:117-158`).
Add a "Print deltas as they arrive, without streamly" pattern after `:71-85`.

**`ApiKeyEnvChain`.** `getting-started.md:136-143` names it; give it a sentence in the
multi-host section of `models-and-providers.md:193-221`: `ApiKeySource` is
`ApiKeyLiteral`, `ApiKeyEnv name` or `ApiKeyEnvChain [names]` (first set variable wins),
and `Show`/`ToJSON` redact the literal (`baikai/src/Baikai/Auth.hs:26-49`). After EP-2
M2, add that an empty-string variable is an `AuthError`, not a key.

**`mkModel`.** Lead `models-and-providers.md:88-113` with
`mkModel :: Api -> Text -> Text -> Model` (tag, model id, base URL; `name` defaults to
the id and `provider` to `renderApi` of the tag, `baikai/src/Baikai/Model.hs:161-173`)
and keep the `emptyModel` record update for prices, caps and `compat`. Warn that
`emptyModel.api` is `Custom ""` and dispatches nowhere.

**The sampling options.** Add a "Sampling options" section to `models-and-providers.md`
before "Reasoning effort": `topP`, `stopSequences` (`Vector Text`), `seed` (`Integer`),
`frequencyPenalty`, `presencePenalty`, all `Maybe` on `Options`; Anthropic maps `topP`
and `stopSequences`, the OpenAI-compatible provider maps all five, the CLI providers
none (`baikai/src/Baikai/Options.hs:11-16`). After EP-3, add its sentence about
`temperature`/`topP` being dropped and recorded on Anthropic models whose catalog record
marks sampling unsupported.

**The base-URL composition rule.** In `models-and-providers.md:36-42` and the
hand-rolled section state `<baseUrlRule>`: a `baseUrl` is the host root, or the API root
*without* the version segment — `https://api.openai.com`, `https://api.deepseek.com`,
`https://openrouter.ai/api` (`baikai/data/models/*.json`) — because the transport
appends `/v1/chat/completions` (`/v1/messages` on Anthropic). If EP-2 chose
deduplication, add "a trailing `/v1` is tolerated and folded"; if refusal, "a
`/v1`-suffixed base URL is refused before dispatch as `InvalidRequest`". Say a query
string in `baseUrl` is not supported.

**The custom-provider base value.** In `models-and-providers.md:257-336` replace the
two positional `ApiProvider {…}` constructions with a record update on
`<apiProviderBase>` and delete the "Changed in 0.5.0.0" callout (the base value is the
fix for the hazard it describes); keep `describeThinking` and its honest
`noThinkingRequested` default. Mirror in `model-call-evidence.md:275-281`.

Acceptance: `git grep -n "registerWith" -- README.md docs/user docs/capabilities` is
empty; every fence added or changed here evaluates in
`cabal repl baikai-smoke:test:doc-shapes` (every package in scope) without a scope
error, with the transcript recorded in Surprises & Discoveries.


### Milestone 3 — stale claims and Haddock swept

Scope: H.3 and H.4 in full, plus the guide sentences the earlier plans' behaviour
changes touched. Each item is "fix, then re-read the surrounding section". Brevity would
obscure meaning, so the items are listed with the fix written out.

Guides and records:

- `README.md:147-150`, `models-and-providers.md:354-357`, `prompt-caching.md:126-128`
  ("CLI providers … zero usage / report zeros"): replace with what
  `cli-providers.md:174-193` states — both tools report token counts and baikai carries
  them (`claude` Anthropic-shaped and disjoint plus `total_cost_usd` into `Usage.cost`;
  `codex` inclusive counts with cached tokens subtracted); a zero means the tool said
  nothing. `prompt-caching.md` keeps its advice to measure caching on the API providers.
- `README.md:76-78`, `getting-started.md:20-23` ("re-exports nothing of its own"): say
  each vendor package adds nothing to the core vocabulary and exports its provider
  values, configuration records and launchers.
- `tools.md:70` and `:231-233` (`ToolChoiceNone` suppresses `tools`): the Anthropic
  provider keeps `tools` and sends `tool_choice: {"type":"none"}`
  (`baikai-claude/src/Baikai/Provider/Claude/Shape.hs:57-61`). Fix the row; delete the
  caveat.
- `tools.md:234-237` (tool-side `cache_control` "not currently wired … EP-5
  retrospective"): it is wired — with `cacheRetention` set the Anthropic provider marks
  the last tool definition, gated by `supportsCacheControlOnTools` (`Shape.hs:63-69`).
  Rewrite; drop the plan reference.
- `tools.md:215-222` ("Streaming tool calls"): add `<cutOffArguments>` — a tool call
  whose argument JSON was cut off by the output cap (`stopReason = Length`) closes with
  `arguments` holding the raw partial text as a JSON string, never an empty object, so a
  loop must check the stop reason before dispatching. Copy EP-4's wording and the
  Haddock EP-10 puts on `ToolCall.arguments`.
- `prompt-caching.md:23` and `:26-30` ("OpenAI Responses: 24h"; the OpenAI-compatible
  column): no code emits either. The OpenAI-compatible provider injects Anthropic-style
  markers only where the compat record sets `cacheControlFormat = Just
  CacheControlFormatAnthropic` — OpenRouter in the shipped table
  (`baikai/src/Baikai/Compat.hs:256-261`,
  `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs:219-242`): `{type: ephemeral}` for
  `Short`, `{type: ephemeral, ttl: "1h"}` for `Long` when `supportsLongCacheRetention`;
  `api.openai.com` gets no marker because Chat Completions caches automatically and has
  no retention control. Rewrite the column as Anthropic / OpenRouter / other hosts and
  delete "24h". Mirror in CAP-12 Limits (`:72-74`) and CAP-14 Limits (`:81-83`).
- `streaming.md:47`: `ThinkingEnd` carries `ThinkingEndPayload` with `contentIndex` and
  `content :: ThinkingContent` (text, signature, redacted flag;
  `baikai/src/Baikai/Stream/Event.hs:154-163`).
- `streaming.md:59`, `:130`, `:182` (`Aborted`): `<aborted>` — if retired, delete it
  from the `StopReason` list, the failure table and the "`ErrorReason` or `Aborted`"
  sentence; if produced, the row reads "the consumer stopped reading or `timeoutMs`
  expired; the terminal message carries whatever streamed first; `responseError` is
  `Just`".
- `streaming.md:159-164`, `models-and-providers.md:323-325`: the lifted stream emits
  `TextStart`, `TextDelta`, `TextEnd` (`baikai/src/Baikai/Stream.hs:507-512`); add
  `TextStart`.
- `streaming.md:174`, `getting-started.md:174`: `assistantContent = []` is
  `content = []` (`baikai/src/Baikai/Message.hs:104`).
- `streaming.md:27-33` and `:189-194`: after EP-4 the "exactly once, first" promise is
  unconditional; keep it and add that a consumer who stops reading cancels the worker
  and releases the connection.
- `getting-started.md:11-18`: add rows for `baikai-trace-otel` and `baikai-effectful`
  from `README.md:88-89`.
- `models-and-providers.md:83`: "EP-5's `baseUrl` auto-detection" becomes "the
  provider's `baseUrl` auto-detection (`autoDetectOpenAICompletions`)". `:13-28`: the
  list is a sample; `Models.allModels` is the full catalog (about thirty entries,
  including every `deepseek_*` and `openrouter_*` binding). `:190`: the anchor
  `#model-and-reasoning-effort` does not exist; the section is `## Reasoning Effort`,
  so use `interactive-launches.md#reasoning-effort`.
- `cli-providers.md:283-293` ("The one exception is `Options.thinking`"):
  `Options.evidence` is honoured too (`Claude/Cli.hs:224-236`, `OpenAI/Cli.hs:234-246`);
  say "two exceptions" and point at `model-call-evidence.md`.
- `unattended-agent-runs.md:550`: the quoted refusal prints raw provider arguments,
  which the renderer no longer does (`baikai/src/Baikai/Agent.hs:359-362`: a count, and
  "their values are not shown"). Paste `renderCeilingViolation`'s exact output for a
  two-argument request. `:580-594`: the guide names settei's `renderResolutionText` /
  `renderResolutionJson` and their format; `agent show` prints `renderEffectiveConfig`'s
  format ("from repository configuration at .baikai/agents.kdl:4:17"), which the guide's
  own transcript at `:80-118` shows. Rewrite around that transcript.
- `unattended-agent-runs.md` after EP-6: `:381` (`allowed-tools` "no narrowing") becomes
  "a permission grant on Claude Code, ceiling-gated"; the setting reference gains the
  fields EP-6 added to the ceiling; `:488-503` matches EP-6's environment-layer
  decision; `:505-521` states EP-6's ceiling-file provenance (`--user-config`,
  `XDG_CONFIG_HOME`); `:277` exit 70 stays only if EP-6 made it reachable.
- `interactive-launches.md:225-232`: `<codexRefusedApprovals>` — the `CodexSandbox` row
  shows `Left SafetyNotExpressible` for the approval policies EP-1 refuses (expected
  `CodexApprovalUntrusted` and `CodexApprovalOnFailure`, which `codex 0.149.1` rejects)
  and `Right` for the rest; update the refusal quote at `:219-222` to EP-1's wording.
- `kit.md:102-105` and `:136-145`: after EP-7 every listed file is installed (confirm the
  guide is right) and the lower-level functions return typed errors instead of exiting;
  rewrite the five-line example with EP-7's final signatures.
- `model-call-evidence.md:35-38`: the `import Baikai` + `withTrace` fix as in CAP-19.
  `:71`: `endpoint` is "the sanitized URL, or on the subprocess transports the resolved
  executable path". `:101`: `<unsupportedModelAdjustment>` — after EP-3 both adapters
  drop a reasoning request on a model that does not advertise `reasoning` and record it;
  if EP-3 chose a new adjustment name for the OpenAI side, list it, else the row stays.
  `:219-225`: after EP-8 strict mode fails a call whose terminal carries no record, not
  only one whose sink threw; copy EP-8's sentence. Add the GC-eventual caveat unless EP-9
  did: a consumer that abandons a stream gets its `aborted` record from a finaliser that
  runs when the stream is garbage collected, so a short-lived process that aborts and
  exits may write none — drain or bracket the stream when the record matters.
- `docs/capabilities/generated-model-catalog.md:42`: `Models.claude_sonnet_5` is
  `Models.anthropic_claude_sonnet_5` (`Generated.hs:224`). `:71-74`: DeepSeek and
  OpenRouter *are* generated (`Generated.hs:247-270,799-822`); say every file under
  `baikai/data/models/` is generated and coverage is curated per file. After EP-3 name
  the thinking-style and sampling-support fields.
- `docs/capabilities/call-tracing.md:47-51`: match EP-9's Outcomes (a blocking sink
  cannot hang the call; one throwing sink no longer starves its `multiSink` siblings)
  and carry the abort caveat. `model-call-evidence.md:35` (the record): the `TraceSpec`
  evidence line claims an ordering assertion EP-9 M4 adds — verify it exists by name.
  `:129`: `onSinkFailure` is the hook through which a strict caller's call is failed
  (shipped in 0.5.0.0, commit `143718d`), not "a hook a future release replaces".
- `docs/capabilities/anthropic-messages-backend.md:37`, `:48-51`: the evidence line
  names `registerWith`; the body says `servant-client`. The transport is baikai's own
  SSE reader over `http-client` (`baikai-claude/src/Baikai/Provider/Claude/Sse.hs`) and
  classification reads status, `Retry-After` and body from that response.
- `docs/capabilities/tool-calling.md:17-19`, `kit-installer.md:15-22`: the `interface`
  lists omit `Baikai.Provider.Registry` / `Baikai.Context` and `Baikai.Kit.Config` /
  `Baikai.Kit.Path` / `Baikai.Kit.Sidecar`; add them.
- `baikai-effectful/README.md`: re-read against `baikai-effectful/src/Baikai/Effectful.hs`
  and EP-10's constructor decisions; expect no change, but confirm.

Haddock (H.4), with the corrected sentence for each. EP-4, EP-5, EP-8 and EP-9 own
several of these files, so check whether a sentence is already fixed before editing:

- `baikai/src/Baikai/Trace/Event.hs:87-90`: "Emitted exactly once per call, immediately
  *before* the matching 'CallFinished' or 'CallFailed' (since 0.5.0.0, so a sink that
  ends a span on the terminal sees the evidence first), and only when …".
- `Trace/Event.hs:42-43`: "Token counts are 'Maybe' because a non-assistant terminal has
  no usage and a subprocess tool may report nothing; since 0.5.0.0 both CLI providers
  carry the counts the tool reported."
- `baikai/src/Baikai/Trace.hs:22-24`: "… they do not propagate into the provider call,
  except under 'EvidenceRequired', where a sink that drops the record fails the call
  (see 'Baikai.Evidence.EvidenceStrictness')." Use EP-9's wording if it wrote one.
- `baikai/src/Baikai/Stream/Event.hs:14-17`: delete the "One temporary provider-side gap
  remains … EP-7 …" sentence once EP-4 pre-seeds; the invariant is unconditional.
- `Stream/Event.hs:6-8` and `:73-75`: the skeleton is "an 'AssistantMessage' with empty
  content, zero usage and no stop reason yet; api, provider and model live on the
  'Baikai.Response.Response', not on the message".
- `baikai/src/Baikai/Stream.hs:97`: "Returns an 'EventStart' then 'EventError' stream
  when no handler is registered" (as `:91-92` says); `:578`: "The two-event
  ('EventStart', 'EventError') stream a strict call refused before dispatch returns".
- `Stream.hs:426-427`: "'EventStart' carrying the response's message skeleton — empty
  content, but the final usage, stop reason and error text already filled in, because
  the lifted response is complete before the stream begins."
- `baikai/src/Baikai/Compat.hs:140-156`, `:197`, `:213`: point at
  `Baikai.Provider.OpenAI.Internal.Request.mkOpenAIResponseFormat`,
  `…Internal.Request.applyThinkingFormat`, `Baikai.Provider.OpenAI.Api.scanThinkTags`
  (there is no `translateTextLikeDelta`),
  `Baikai.Provider.Claude.Internal.Request.computeCacheControl` and `computeThinking`;
  after EP-10's relocations, `grep -rn "^computeThinking\|^scanThinkTags" baikai-*/src`
  and copy the module names it prints.
- `Compat.hs:83-84`: "Three of the other six — OpenRouter, DeepSeek and Together — route
  through @compatibleEffort@, which clamps …; Z.ai and Qwen send a bare toggle, and
  'ThinkingFormatNone' drops the control."
- `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs:110-114`: "They are
  injected as raw JSON keys by 'Baikai.Provider.OpenAI.Shape.injectThinkingShape' after
  the SDK value is encoded, which is why this function answers 'Nothing' for them."
- `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:155-163`: the worker "drives the
  local SSE transport ('Baikai.Provider.OpenAI.Sse.openaiSseStreamValueWithHeaders') and
  pushes raw chunk values onto a 'Chan'"; after EP-4, that the worker's 'ThreadId' is
  held and killed when the consumer stops.
- `baikai-claude/src/Baikai/Provider/Claude/Api.hs:139-140`: the channel is `newChan`,
  unbounded (`:183`) — say what EP-4 leaves. `:830-836`: two `-- |` headers on
  `immediateError`; merge into one.
- `baikai-claude/…/Internal/ErrorClass.hs:7-9` and the OpenAI twin `:7-8`: "an
  exception thrown by the @http-client@ transport beneath 'Baikai.Provider.Claude.Sse'"
  — EP-5 M4 owns this; verify, do not duplicate.
- `baikai/src/Baikai/Message.hs:18-19`, `baikai/src/Baikai/Context.hs:5`: system prompts
  live on `'Baikai.Context.Context.systemPrompt'`; `Baikai.Request` no longer exists.
- `baikai/src/Baikai/Model.hs:6-7`: "and a per-API 'Compat' record ('CompatNone' lets the
  provider auto-detect from the base URL; see "Baikai.Compat")".
- `baikai/src/Baikai/Response.hs:82`: "A blank assistant turn with no timestamp."
- `baikai/src/Baikai/Context.hs:106-108`: "Calls are dispatched one at a time, in the
  order they appear; any timeout or sandboxing lives in the dispatcher."
- `baikai/src/Baikai/CacheRetention.hs:5-6`, `:22-24`: delete the OpenAI Responses 24h
  sentences; say the OpenAI-compatible provider emits Anthropic-style markers only where
  the host's compat record sets 'cacheControlFormat'.
- `baikai/src/Baikai/Options.hs:29-30` ("EP-4 added @toolChoice@. EP-5 adds …") and the
  other `EP-n` mentions `git grep -n "EP-[0-9]" -- '*.hs'` lists (twenty-eight at
  `5411947`: `Trace.hs`, `Model.hs`, `Registry.hs`, `Embedding.hs`, `Cost/Log.hs`,
  `Context.hs`, `Content.hs`, both `Sse.hs`, `OpenAI/Cli.hs`, `OpenAI/Api.hs`,
  `OpenAI/Internal/Request.hs`, `gen/GenModelsCore.hs`, three test files): a plan
  number is not documentation. Rewrite each as a plain statement or delete it where the
  sentence only records history; a test comment may keep the number if it is the only
  pointer to a fixture's origin — note each survivor in the Decision Log.
- `baikai-trace-otel/test/Main.hs:241-248`: the comment says evidence is pushed after the
  terminal and hand-feeding is "the only way"; it is pushed before. Fix the comment.
- `CHANGELOG.md:83-85`, `:86-89`, `:127`: handled in Milestone 4.

Acceptance: `cabal haddock` for all seven packages ends with a "Documentation created"
line each; the drift greps in Concrete Steps are clean; every changed fence evaluates
in `cabal repl baikai-smoke:test:doc-shapes`.


### Milestone 4 — changelog, capability log and bundle validation

Scope: the release bookkeeping the earlier plans deferred to this one, and the gates.

**`CHANGELOG.md`.** Inside `[baikai 0.5.0.0]` add under `### Added` an entry for strict
evidence mode — `EvidenceStrictness` with `EvidenceBestEffort` and
`EvidenceRequired strength`, the pre-dispatch refusal that returns an `InvalidRequest`
error-shaped `Response` carrying the record with the very downgrade that caused it, and
the guarantee that callers who do not opt in are never refused; under `### Changed` a
`**Breaking:**` entry that `ApiProvider` gained a fourth field
`describeThinking :: Model -> Options -> ThinkingTranslation` every custom provider
must supply (`\_ _ -> noThinkingRequested` for one with no reasoning controls); under
`### Fixed` that a strict caller's call fails when the trace sink drops its record
(`143718d`). Each ends "(entry added 2026-08-27; the behaviour shipped in 0.5.0.0)".
Rewrite `:83-85` to "and `onSinkFailure` is the hook through which a strict caller's
call is failed when the trace sink does"; `:86-89` to "the core release records
`requested_only` on the adapter-less paths; the `baikai-claude` and `baikai-openai`
sections below describe what each transport observes"; `:127` "two-second" to
"five-second". Then verify `[Unreleased]` (or the sections EP-10 cut) holds an entry for
every behaviour change in EP-1..EP-10 — walk each plan's Outcomes and tick off — and add
any missing, quoting the owning plan. Add this plan's own entries: a "Documentation:"
bullet under `### Fixed` for each package whose Haddock changed. The `doc-shapes` suite
gets no package entry (`baikai-smoke` is unpublished); it is recorded in the capability
log entry instead.

**Capability records.** Update the body — description, prose, Limits — of each record
whose behaviour EP-1..EP-10 changed, keeping `since` and `status`, advancing
`generated.at` and `generated.by`. The list and what each says afterwards: CAP-21
kit-installer (symlinked sources refused on install, hash and status; library functions
return typed errors and never exit; every listed file installed); CAP-18
baikai-agent-command (the ceiling gates every repository-settable field; ceiling-file
provenance; the truthful exit-code list; `allowed-tools` as a grant); CAP-17
unattended-agent-runs (threaded runtime; SIGINT → SIGTERM → SIGKILL; drained output kept
on timeout; UTF-8 output regardless of locale); CAP-9 call-tracing (a blocking or
throwing sink cannot hang the call or starve its siblings; the abort terminal is
eventual); CAP-10 opentelemetry-span-export (`gen_ai.response.model` only from the
evidence event; the parent-context option); CAP-19 model-call-evidence (strict means a
record exists; `thinking.requested` on every path; endpoint default host; commitment
digest without cost; the `ApiProvider` strength ceiling; the `onSinkFailure` sentence);
CAP-8 categorised-error-model (mid-body transport failures retryable; in-band error
frames classified; 413 overflow; HTTP-date `Retry-After` per EP-5; evidence lines no
longer say servant-client); CAP-2 typed-streaming (a consumer that stops reading cancels
the worker and releases the connection — replacing `:72-75`; `EventStart` first on every
provider); CAP-4 tool-calling (cut-off tool calls carry raw text, never `{}`); CAP-13
anthropic-messages-backend (`EventStart` first on every failure path; the transport
sentence; the register line); CAP-3 generated-model-catalog (thinking style and sampling
support are catalog fields); CAP-15 subscription-cli-backends (the `--version` probe is
five seconds). Then add one `## 2026-08-27` entry to `docs/capabilities/log.md` in the
shape of the 2026-08-10 entry (`okf log add docs/capabilities`, or by hand): a
"**Change**" bullet naming every record edited and why, a bullet for the Shape rewrite
and the `doc-shapes` suite, and a bullet for the `index.md` convention paragraph.

**Gates.** Run every command under "Milestone 4 gates" in Concrete Steps. Update the
MasterPlan's four EP-11 Progress boxes and set the registry row to Complete. Write the
Outcomes & Retrospective entry and perform the ADR distillation pass (expected: no new
ADR, per the Decision Log; record that conclusion).

Acceptance: the capability validator prints `OK: 22 concepts (okf_version 0.2)`;
`okf graph docs/capabilities` shows one edge per `requires` entry (thirty-three at
`5411947`, unchanged because no `requires` changes); the reviews bundle validates
unchanged; `mori validate` prints "Configuration is valid."; `mori register` succeeds and
`mori registry concepts shinzui/baikai --bundle capabilities` lists twenty-two; the
keyless `cabal test all` passes with every suite reporting tests run.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai` inside the Nix dev shell.

Reconciliation, before Milestone 1 (read the two sections of each sibling plan and
resolve the placeholders):

```bash
for n in 58 59 60 61 62 63 64 65 66 67; do
  f=$(ls docs/plans/$n-*.md)
  echo "===== $f"
  sed -n '/^## Decision Log/,/^## Outcomes/p' "$f"
  sed -n '/^## Outcomes & Retrospective/,/^## Context/p' "$f"
done
git log --oneline -40
```

Starting-state and drift greps — run once before editing and paste the output into
Surprises & Discoveries (expected at `5411947`: nine `registerWith` hits, two `EP-` hits
in the guides, twenty-eight in the sources), then after Milestones 2 and 3 (expected: no
output from the first three; the fourth lists only the survivors in the Decision Log):

```bash
git grep -n "registerWith" -- README.md docs/user docs/capabilities baikai-effectful/README.md
git grep -n "assistantContent\|zero usage\|report zeros\|24h" -- README.md docs/user docs/capabilities
git grep -n "EP-[0-9]" -- README.md 'docs/user/*.md' 'docs/capabilities/*.md'
git grep -n "EP-[0-9]" -- '*.hs'
```

The greps plan 43 used, repeated (expected: no hits outside `CHANGELOG.md`,
`docs/plans/` and `docs/reviews/`):

```bash
git grep -n "OPENAI_KEY\|ANTHROPIC_KEY" -- README.md docs/user | grep -v "API_KEY"
git grep -n "ProviderError" -- README.md docs/user baikai-effectful/README.md
git grep -n "0\.1 API\|published on Hackage\|being published" -- README.md docs/user
git grep -n "_Options\b\|_Context\b\|_Model\b\|_Response\b\|_Usage\b\|_Cost\b\|_Tool\b\|_InteractiveLaunchRequest\b" -- README.md docs/user docs/capabilities
```

Milestone 1 — build and run the shape suite (expected: one line per record and
`doc-shapes: 20 haskell blocks agree, 1 kdl block resolves, 1 skipped`), then prove the
checker bites (expected: `DIFFERS`, non-zero exit; then restore):

```bash
cabal build baikai-smoke:test:doc-shapes
cabal test baikai-smoke:test:doc-shapes --test-show-details=direct
sed -i.bak 's/cacheReadTokens/cacheWriteTokens/' docs/capabilities/prompt-cache-retention.md
cabal test baikai-smoke:test:doc-shapes --test-show-details=direct; echo "exit=$?"
mv docs/capabilities/prompt-cache-retention.md.bak docs/capabilities/prompt-cache-retention.md
```

Milestones 2 and 3 — check every new or changed guide fence against the real exports in
a REPL that has every package in scope (expected: no "not in scope" errors):

```bash
cabal repl baikai-smoke:test:doc-shapes
```

Haddock for every package (expected: each ends `Documentation created: …/index.html`):

```bash
for p in baikai baikai-claude baikai-openai baikai-trace-otel baikai-effectful baikai-kit baikai-agent; do
  cabal haddock "$p" || { echo "haddock failed: $p"; break; }
done
```

Milestone 4 gates. The bundle validators (expected output after each command). Do not
add `--strict` to the capability bundle: it reports the profile-recommended `reviews`
family the machine-authored records lack, which is expected output, not a failure
(release skill step 4):

```bash
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
# OK: 22 concepts (okf_version 0.2)
okf log docs/capabilities --check-stale
# (no concept reported newer than its log entry)
okf graph docs/capabilities | jq '.edges | length'
# 33
okf validate docs/reviews --strict --profile docs/reviews/profile.dhall \
  --profile-enforce --log-enforce
# OK: 2 concepts (okf_version 0.2)
okf validate docs/improvement-requests \
  --profile mori/improvement-requests-profile.dhall --profile-enforce
```

The Mori registry (expected: "Configuration is valid." then a table of twenty-two
concepts and the eleven guides):

```bash
mori validate
mori register
mori registry concepts shinzui/baikai --bundle capabilities
mori registry docs shinzui/baikai
```

The keyless test gate, exactly as `agents/skills/release/SKILL.md` step 4 states it.
`baikai-smoke` gates its API cases on the key variables and its CLI cases on
`findExecutable` alone, so both gates are closed here; adjust the two filtered `PATH`
entries to wherever `claude` and `codex` live on this machine. Expected: every suite,
including `doc-shapes`, reports tests run and passing — a suite reporting zero tests
means something was filtered that should not have been:

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

Formatting and the flake (expected: `git diff --exit-code` exits 0 after `nix fmt`;
`nix flake check` succeeds):

```bash
nix fmt && git diff --exit-code
cabal build all --enable-tests
nix flake check
```

Commit once per milestone with Conventional Commits messages; every commit carries the
three trailers below. `nix fmt` runs as a pre-commit hook and formats the new Haskell
files, so run it before the first commit:

```text
test(docs): compile every capability Shape under baikai-smoke:doc-shapes

Adds the doc-shapes test-suite, one Shape.CapN module per record, and the
checker that diffs each record's fenced haskell block against its module.
Rewrites the twelve Shape blocks REV-2 H.1 found non-compiling, plus CAP-7
and CAP-14.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/68-bring-the-documentation-back-to-the-code.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
docs(guides): teach the supported registration path and the July helpers

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/68-bring-the-documentation-back-to-the-code.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
docs(sweep): bring stale guide claims and Haddock back to the code

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/68-bring-the-documentation-back-to-the-code.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
docs(release): fill the 0.5.0.0 changelog gaps and log the capability updates

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/68-bring-the-documentation-back-to-the-code.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```


## Validation and Acceptance

The change is accepted when all of the following hold, in this order.

Shape proof. `cabal test baikai-smoke:test:doc-shapes` compiles twenty `Shape.CapN`
modules and, when run, prints one `agrees with Shape/CapN.hs` line per record with a
`haskell` fence, `kdl Shape resolves: jobs [review]` for CAP-18, `skipped` for CAP-3,
and the summary `doc-shapes: 20 haskell blocks agree, 1 kdl block resolves, 1 skipped`,
exiting 0. The "prove the checker bites" step prints `DIFFERS` with the record line and
the module line and exits 1. Deleting `Shape/Cap12.hs` and re-running reports a record
without a module and exits 1 (restore with `git checkout`).

Registration proof. `git grep -n "registerWith" -- README.md docs/user docs/capabilities baikai-effectful/README.md`
prints nothing. Every fence in the "Registry", "Configuration", "The registry" and
"Custom providers" sections evaluates in `cabal repl baikai-smoke:test:doc-shapes`
without a scope error, transcript in Surprises & Discoveries.

Helper proof. `getting-started.md` names `responseError` and `ApiKeyEnvChain`;
`streaming.md` names `streamRequestEach` and `streamRequestList` with signatures and no
longer says everything assumes streamly imports; `models-and-providers.md` has sections
for `mkModel`, the sampling options and the base-URL rule, and its custom-provider
example uses EP-10's base value. A reader following the streaming guide without
importing `streamly` can print deltas with `streamRequestEach`.

Sweep proof. The drift greps and the plan-43 greps come back as stated;
`cabal haddock` succeeds for all seven packages (a broken `'Module.name'` link fails it,
which is the mechanical half of the Haddock check); every H.4 sentence, read at its new
location, states the current behaviour — `CallEvidence` before the terminal, CLI token
counts reported, sink failure under strict mode, no "temporary gap", no plan numbers.

Release proof. `[baikai 0.5.0.0]` contains the strict-mode, `describeThinking` and
sink-failure entries with the dated parenthetical, and `:83-89` and `:127` read as
Milestone 4 states; each of EP-1..EP-10 has its entries. The twelve listed records have
`generated.at` of `2026-08-27` or later and unchanged `since`; `docs/capabilities/log.md`
has a `## 2026-08-27` entry naming them. The three `okf validate` runs, `okf graph`,
`okf log --check-stale`, `mori validate`, `mori register` and the keyless
`cabal test all` pass as Concrete Steps shows. The MasterPlan's four EP-11 boxes are
checked and its registry row reads Complete.


## Idempotence and Recovery

Every step is a plain text or source edit under git; recovery is `git checkout -- <path>`
before a commit or `git revert` after one. Work milestone by milestone with one commit
each so a bad state is never more than one revert away.

The shape suite is idempotent by construction: re-running it on an unchanged tree prints
the same lines; a partial rewrite of the records leaves exactly the unfixed ones printing
`DIFFERS`, which is the work list. When a record and its module disagree, fix the side
that does not match the code — the compiler has already vouched for the module. The
`sed -i.bak` in Concrete Steps makes its own backup; `mv` it back.

The greps are safe to repeat and shrink as the sweep proceeds. The `CHANGELOG.md`,
record and `log.md` edits are pure text; re-applying them is harmless, but do not add a
second `2026-08-27` log entry on a retry — extend the existing one. `generated.at` may be
advanced more than once. `okf log docs/capabilities --check-stale` says when a record was
edited after the newest log entry. `mori register` rewrites Mori's read model from the
tree and is safe to repeat; `cabal haddock` and the keyless gate are read-only.

If an owning plan's Outcomes contradict a sentence this plan prescribes, do not
improvise: the owning plan wins, record the conflict and resolution in both Decision
Logs, then edit. If EP-10 has not landed when this plan starts, stop — the MasterPlan
makes that dependency hard because every registration paragraph and half the Shape
blocks would otherwise be rewritten twice.


## Interfaces and Dependencies

No new external dependency: the `doc-shapes` stanza depends only on packages already in
the workspace build plan (`aeson`, `containers`, `directory`, `effectful-core`,
`filepath`, `generic-lens`, `hs-opentelemetry-api`, `lens`, `settei-env`,
`streamly-core`, `text`, `vector`, `base`) plus the seven publishable packages. Tooling:
`cabal` (build, test, haddock, repl), GHC 9.12.4 (`GHC2024`), `okf`, `mori`, `jq` (the
edge count only), `nix`.

At the end of Milestone 1: `baikai-smoke/baikai-smoke.cabal` has the `test-suite
doc-shapes` stanza from Milestone 1; `baikai-smoke/doc-shapes/DocShapes.hs` is
`module Main (main) where` implementing `findRepoRoot :: IO FilePath` (walk up to
`cabal.project`), `shapeBlock :: Text -> Maybe (Text, [Text])` (the capability id and
the `haskell` block under `## Shape`), `moduleRegion :: Text -> Text -> Maybe [Text]`
(the marker region for an id, indent-stripped), `splitPreamble :: [Text] -> ([Text], [Text])`,
and the CAP-18 resolution through `Baikai.Agent.Config.AgentConfigPaths`,
`listAgentJobs`, `resolveAgentJob` and `Settei.Env.envSnapshot []`, exiting 0 only when
every block agrees, the KDL block resolves, and the module set equals the set of records
with a `haskell` fence; `baikai-smoke/doc-shapes/Shape/Fixtures.hs` exports the names
listed in Milestone 1, every one an `error` thunk; `Shape/Cap1.hs` … `Shape/Cap22.hs`
(twenty files; no `Cap3`, no `Cap18`) each export one binding and contain exactly one
`-- BEGIN CAP-N` / `-- END CAP-N` pair; `docs/capabilities/index.md` has a "Shape
blocks" section.

At the end of Milestone 2 no code interface changes; the deliverables are `README.md`,
`docs/user/getting-started.md`, `streaming.md`, `models-and-providers.md`,
`cli-providers.md` and `model-call-evidence.md`.

At the end of Milestone 3 no code interface changes; the deliverables are the guide and
record edits listed and comment-only changes in `baikai/src/Baikai/Trace/Event.hs`,
`Trace.hs`, `Stream/Event.hs`, `Stream.hs`, `Compat.hs`, `Message.hs`, `Context.hs`,
`Model.hs`, `Response.hs`, `CacheRetention.hs`, `Options.hs`,
`baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`,
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`,
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, both `Internal/ErrorClass.hs` and
`baikai-trace-otel/test/Main.hs`, which `cabal haddock` renders and `cabal build` proves
harmless.

At the end of Milestone 4: `CHANGELOG.md`, the twelve capability records,
`docs/capabilities/log.md`, and the MasterPlan's Progress and registry row. `mori.dhall`
is unchanged. No ADR is added.
