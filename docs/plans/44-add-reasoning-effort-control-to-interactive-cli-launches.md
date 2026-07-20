---
id: 44
slug: add-reasoning-effort-control-to-interactive-cli-launches
title: "Add reasoning-effort control to interactive CLI launches"
kind: exec-plan
created_at: 2026-07-20T14:40:08Z
intention: "intention_01kxzzgg92es4an5y5wrvjh8f9"
master_plan: "docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md"
---

# Add reasoning-effort control to interactive CLI launches

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Baikai can launch local **interactive agent CLIs** — a Claude Code (`claude`) session or a
Codex (`codex`) session — where the vendor tool owns the terminal loop and Baikai only
constructs the command line. Before this plan, callers could pick the model for such a
launch but could control **reasoning effort** only through raw `extraArgs`, which forced
each caller to re-learn the vendor spelling (`--effort <level>` for Claude and
`-c model_reasoning_effort=<value>` for Codex).

The completed implementation lets a caller set one provider-neutral field on the
interactive request and translates it to the right vendor flag. Baikai's `ThinkingLevel`,
formerly a four-bucket API preference, now includes the shared higher levels
`ThinkingXHigh` and `ThinkingMax`, and `InteractiveLaunchRequest` has
`effort :: Maybe ThinkingLevel`. This provides one six-level Baikai vocabulary from
`minimal` through `max`; it does not claim to model every provider-only mode.

**Term definitions (used throughout, defined once):**

- **Interactive launch** — starting a real `claude`/`codex` terminal session that inherits
  stdin/stdout/stderr and returns only when the user exits it. This is distinct from the
  *batch/completion* path (`claude -p`, `codex exec`) that returns a parsed `Response`.
  Baikai's interactive surface lives in `baikai/src/Baikai/Interactive.hs` (core vocabulary)
  and the two vendor launchers `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` and
  `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`.
- **Reasoning effort** — a coarse dial telling a reasoning-capable model how much internal
  deliberation to spend. Baikai's provider-neutral spelling is `ThinkingLevel` in
  `baikai/src/Baikai/ThinkingLevel.hs`.
- **argv** — the executable path plus the ordered list of string arguments Baikai hands to
  the operating system when it spawns the CLI. The pure functions that build it are
  `claudeInteractiveCommand` and `codexInteractiveCommand`; both are exported and unit-tested,
  so we can verify the new behavior without launching a real session.
- **SDK and wire value** — an SDK (software development kit) is the typed Haskell dependency
  used to construct a request. A wire value is the final JSON value Baikai actually sends
  over HTTP after request shaping; the two can differ because Baikai deliberately rewrites
  serialized SDK requests for newer or provider-compatible fields.
- **PVP** — the Haskell Package Versioning Policy. It treats the first two components of an
  `A.B.C.D` package version as the major version and requires a major bump for breaking
  exported API changes such as adding constructors to a public sum type.

**The observable outcome**, verifiable with pure unit tests and no authenticated session:
given an interactive request whose `effort` is `Just ThinkingHigh`,
`claudeInteractiveCommand` produces an argv containing `["--effort","high"]`, and
`codexInteractiveCommand` produces one containing `["-c","model_reasoning_effort=high"]`.
With `effort = Nothing` (the default), neither flag appears, so existing behavior is
unchanged. The higher buckets map through too: `ThinkingMax` yields `--effort max` for
Claude and `model_reasoning_effort=max` for Codex. Codex-only `none` and the newer
model-dependent `ultra` mode remain available through `extraArgs`; `Nothing` means "leave
the CLI default alone" and is deliberately not treated as an explicit `none`.

This unblocks downstream callers such as Seihou, which want deterministic, explicit
reasoning-effort selection per agent command rather than inheriting whatever effort the
ambient CLI session defaults to.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-20: Revalidated this plan against the current repository, the dependency
  sources located through Mori, Hackage releases, installed CLI help, and current vendor
  documentation. Corrected the API wire mappings, test wiring, changelog convention,
  parent-plan synchronization, and coordinated-release scope.
- [x] 2026-07-20 16:12Z: Registered this follow-up as in-progress EP-4 in the parent
  MasterPlan and reopened the parent's progress, coordination notes, and retrospective.
- [x] 2026-07-20 16:16Z: Milestone 1: Extended `ThinkingLevel` with `ThinkingXHigh` and `ThinkingMax` in
  `baikai/src/Baikai/ThinkingLevel.hs`; made every source and test pattern-match total;
  preserved `xhigh`/`max` on native OpenAI and Anthropic wire requests while documenting
  the typed-SDK and compatible-host clamps; added unit coverage. `cabal build all` passed
  without incomplete-pattern warnings, and the affected suites passed 157 core, 147 Claude,
  and 55 OpenAI tests.
- [x] 2026-07-20 16:19Z: Milestone 2: Added `effort :: Maybe ThinkingLevel` to
  `InteractiveLaunchRequest` and translated it in both vendor launchers (`--effort` for
  Claude, `-c model_reasoning_effort=` for Codex). Exact argv tests cover all six levels,
  and the unchanged existing command tests prove `effort = Nothing` preserves prior argv.
  The affected suites passed 157 core, 153 Claude, and 61 OpenAI tests; pure REPL checks
  rendered `--effort high` and `model_reasoning_effort=max` as expected.
- [x] 2026-07-20 16:25Z: Milestone 3: Updated `docs/user/interactive-launches.md`, the
  single root `CHANGELOG.md`, and the parent MasterPlan; recorded the coordinated PVP release
  set; and passed `nix fmt`, `git diff --check`, `cabal build all`, a provider-key- and
  CLI-binary-scrubbed `cabal test all`, and `nix flake check`. Installed CLI help still
  reports Claude Code 2.1.215 with `--effort` and Codex CLI 0.144.6 with `-c key=value`.
- [x] 2026-07-20 17:28Z: Audited all relevant user documentation after implementation.
  Corrected the root README's live-smoke gating warning, documented API-side
  `Options.thinking` mappings in `docs/user/models-and-providers.md`, and synchronized this
  plan's current-state examples with the implemented six-level request and argv shapes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The `openai-2.5.3` Haskell dependency still exposes only
  `ReasoningEffort_Minimal | Low | Medium | High`, but Baikai does not send that typed value
  directly. `Baikai.Provider.OpenAI.Api.prepareCall` serializes it and then passes the JSON
  through `streamRequestBody`, so `ThinkingFormatOpenAI` can replace the staging `high` with
  the requested `xhigh` or `max` before the HTTP request is sent.
  Evidence: `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` constructs `requestBody` from
  `streamRequestBody`; the dependency source found by Mori at
  `/Users/shinzui/Keikaku/hub/haskell/openai-project/openai` stops its Chat Completions enum
  at `High`; Hackage lists `openai-2.5.3` as the current release.

- Discovery: The registered dependency checkouts match the current Hackage releases:
  `openai-2.5.3` and `claude-1.4.0`. Their authoritative upstream Git repositories expose no
  version tags through `git ls-remote --tags`, so Hackage is the release-version source of
  truth rather than an inferred Git tag.

- Discovery: Anthropic's current API accepts `low`, `medium`, `high`, `xhigh`, and `max` in
  `output_config.effort`, and the local `claude-1.4.0` dependency represents that field as
  `Maybe Text`. Therefore clamping adaptive `ThinkingXHigh`/`ThinkingMax` to `Nothing` would
  lose caller intent; only `ThinkingHigh` may use `Nothing`, because Anthropic documents an
  omitted effort as exactly equivalent to `high`.
  Evidence: `Claude.V1.Messages.OutputConfig.effort` is `Maybe Text`, and the current
  Anthropic effort guide documents all five values plus `high`-when-omitted semantics.

- Discovery: `baikai/test/ThinkingLevelSpec.hs` was a new test module, so adding it only to
  `baikai/test/Main.hs` would have been insufficient; Cabal also required it in the
  `other-modules` list in `baikai/baikai.cabal`. The existing duplicate `adaptiveEffort`
  expectation in `baikai-claude/test/ThinkingSpec.hs` was another constructor match that
  had to become total.

- Discovery: This repository has one root `CHANGELOG.md`, not one changelog per package,
  and a core PVP-major release forces bound-only patch releases of `baikai-trace-otel`,
  `baikai-effectful`, and `baikai-kit` as well as releases of the two provider packages.
  Evidence: `agents/skills/release/SKILL.md` lists the six publishable packages and the
  internal-bound rule; all five dependents currently use `baikai ^>=0.3.0`.

- Discovery: At implementation start, the child plan pointed at
  `docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md`, but that
  MasterPlan was marked complete and did not register this follow-up as EP-4. Implementation
  added the child, reopened the parent progress, and later marked the follow-up complete.

- Discovery: Current Codex documentation includes a model-dependent `ultra` reasoning mode,
  while installed `codex-cli 0.144.6` validation previously reported values only through
  `max`. This plan remains deliberately scoped to adding the two shared higher levels
  requested by the interactive-launch consumers; provider-only modes remain raw overrides.

- Discovery: Removing provider API-key environment variables does not make `cabal test all`
  entirely offline when `claude` or `codex` is on `PATH`. The `baikai-smoke` suite's
  `runCliCase` gates its batch CLI completion cases only with `findExecutable`, so the first
  key-only validation run made one locally authenticated Claude completion and one locally
  authenticated Codex completion. The final acceptance run removed both CLI directories
  from `PATH` as well as removing provider keys and reported explicit skips for every live
  case.
  Evidence: `baikai-smoke/test/Smoke.hs` calls `completeRequest` at line 258 whenever each
  binary is found; the first run logged `sonnet ok` and `<codex-default> ok`, while the final
  run logged both binaries as not on `PATH` and `skipping all cases`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent interactive reasoning effort by **extending the existing
  `ThinkingLevel` type** with two new constructors, `ThinkingXHigh` and `ThinkingMax`,
  rather than introducing a separate interactive-only effort enum.
  Rationale: One effort vocabulary across the API and interactive surfaces is simpler for
  callers and keeps `Baikai.ThinkingLevel` the single source of truth. Provider/model support
  is not uniform, so each boundary must either preserve the canonical value or document its
  compatibility clamp explicitly.
  Date: 2026-07-20

- Decision: For the native **OpenAI Chat Completions wire path**, preserve `xhigh` and `max`
  by having `injectThinkingShape` write the canonical string into the serialized request for
  `ThinkingFormatOpenAI`. Keep `toReasoningEffort` total by mapping the two new constructors
  to the SDK's `ReasoningEffort_High` only as an intermediate value. Continue clamping the
  non-native DeepSeek/OpenRouter/Together compatibility shapes to `high`, because their
  current common mapping exposes only `low | medium | high`.
  Rationale: The installed `openai-2.5.3` type stops at `High`, but Baikai's actual transport
  sends the post-shaped `Aeson.Value`. Using that existing raw-JSON seam preserves caller
  intent for current native OpenAI models without inventing unsupported values for other
  compatible hosts.
  Date: 2026-07-20

- Decision: For the **Anthropic API path**, adaptive mode maps `ThinkingXHigh` to
  `Just "xhigh"` and `ThinkingMax` to `Just "max"`; `ThinkingHigh` remains `Nothing` because
  Anthropic documents omission as equivalent to `high`. Budget mode uses
  `ThinkingXHigh -> 24576` and `ThinkingMax -> 32768` through `thinkingTokenBudget`.
  Rationale: Current Anthropic APIs have native `xhigh`/`max` effort values and the local SDK
  can carry them as text. The fixed budgets remain necessary for catalog entries still using
  manual thinking; keeping the highest budget at 32768 leaves visible-output room below the
  current 64000-token caps instead of causing `mapRequest` to drop thinking when the budget
  consumes the whole cap.
  Date: 2026-07-20

- Decision: Each vendor launcher owns its effort→string mapping, matching how each already
  owns `modelArgs`, `safetyArgs`, etc. Claude's `--effort` accepts
  `low | medium | high | xhigh | max` (no `minimal`), so the Claude launcher maps
  `ThinkingMinimal -> "low"`; Codex's `model_reasoning_effort` accepts the full canonical
  set, so the Codex launcher reuses the core `renderThinkingLevel`.
  Rationale: Keeping the vendor-specific quirk (Claude has no `minimal`) inside the vendor
  package respects the existing separation and avoids leaking CLI trivia into core.
  Date: 2026-07-20

- Decision: Repurpose the core `renderThinkingLevel` as the **canonical** level renderer
  (`minimal | low | medium | high | xhigh | max`) rather than an OpenAI-wire-only renderer.
  It has no current source call sites, so widening it is behavior-preserving for existing
  values and lets both the Codex launcher and native OpenAI JSON shaper reuse it.
  Rationale: One canonical string function avoids duplicate renderers; provider-specific
  exceptions remain at their boundaries.
  Date: 2026-07-20

- Decision: Do not add `ThinkingNone` or `ThinkingUltra` in this plan.
  Rationale: `Nothing` must continue to mean "do not override the provider default," which
  is distinct from Codex's explicit `none`; current `ultra` is provider- and model-specific.
  Both remain expressible through interactive `extraArgs`, while the six named
  `ThinkingLevel` values cover the existing shared abstraction plus the two requested higher
  levels.
  Date: 2026-07-20

- Decision: Treat the core change as PVP-major but the provider changes as
  backwards-compatible additions. The future release should move `baikai` from in-tree
  `0.3.2.0` to `0.4.0.0`; the two provider packages need minor bumps for new behavior, while
  `baikai-trace-otel`, `baikai-effectful`, and `baikai-kit` need at least patch bumps because
  their `baikai` dependency bounds must change. Defer exact dependent versions and all
  publishing to `agents/skills/release/SKILL.md`.
  Rationale: Adding constructors to the exported closed `ThinkingLevel` sum can break
  exhaustive downstream matches. Adding a field to `InteractiveLaunchRequest` is not by
  itself breaking here: its constructor is hidden and callers use the exported
  `interactiveLaunchRequest` base plus record updates specifically so fields can be added.
  The provider function signatures remain unchanged.
  Date: 2026-07-20

- Decision: Keep this as EP-4 of the interactive-launch MasterPlan and synchronize the parent
  registry and living sections during implementation.
  Rationale: The work extends the exact launch abstraction owned by that initiative; removing
  the relationship would hide the integration history, while leaving the completed parent
  unchanged would make its registry inaccurate.
  Date: 2026-07-20

- Decision: Make the final full-suite acceptance environment hide installed Claude and
  Codex binaries in addition to removing provider API keys.
  Rationale: The smoke suite treats binary availability as authorization to run its batch
  CLI completion cases, independently of API-key environment variables. Filtering only the
  two CLI directories preserves the active Cabal/GHC toolchain while ensuring the final
  acceptance command itself performs no authenticated model request.
  Date: 2026-07-20

- Decision: Document `Options.thinking` alongside models and compatibility behavior, and
  describe smoke-test gates independently for API credentials and installed CLI binaries.
  Rationale: The interactive guide explains launch-specific `effort`, but API callers need
  one authoritative six-level mapping reference. The two smoke paths have different gates,
  so saying only that absent API keys cause skips is unsafe and can trigger unexpected
  subscription-backed completions.
  Date: 2026-07-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

2026-07-20 plan-validation outcome: the design remains feasible, but the original draft would
have discarded supported `xhigh`/`max` values on native API requests and described an
incomplete release workflow. The revised milestones preserve native wire values, cover every
constructor match and Cabal test-module registration, use the repository's single changelog,
and account for every internal dependent. As a baseline check, `cabal build all` succeeded
and `cabal test baikai-test baikai-claude-test baikai-openai-test` passed 145, 112, and 52
tests respectively. No product code has been implemented yet.

2026-07-20 Milestone 1 outcome: Baikai now has a tested six-level reasoning vocabulary.
Native OpenAI JSON and Anthropic adaptive requests preserve `xhigh` and `max`; the OpenAI
SDK staging type and non-native compatibility formats clamp explicitly. The new maximum
manual Anthropic budget remains below the 64000-token catalog cap, leaving visible-output
room. `cabal build all` and all three affected suites passed.

2026-07-20 Milestone 2 outcome: callers can now set one provider-neutral `effort` field on
an interactive request. Claude emits `--effort` and maps only `minimal` up to `low`; Codex
emits a `model_reasoning_effort` config override with the canonical name. Exact whole-argv
tests cover all mappings and preserve raw `extraArgs` as the later override. Pure REPL checks
produced `["--effort","high","--","hi"]` and
`["-c","model_reasoning_effort=max","--","hi"]`.

2026-07-20 final outcome: the requested provider-neutral interactive control is complete.
All six effort levels are covered from the core renderers through native API request shaping
and exact Claude/Codex argv construction; default requests remain unchanged. User guidance,
the root changelog, and the parent MasterPlan are synchronized. A post-completion audit also
added the API-side mapping reference and corrected the root README so it no longer implies
that removing API keys disables installed batch CLI smoke cases. Formatting, the full
build, all seven Cabal test components, and both flake checks passed. The only remaining work
is the deliberately separate coordinated PVP release: core `baikai` needs its `0.4.0.0`
major, both provider packages need feature releases, and the three bound-only dependents
need patch releases before Seihou can update its bounds and pins.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

Baikai is a Haskell library providing a provider-neutral abstraction over AI providers. It
is a multi-package Cabal workspace. The three packages this plan touches:

- `baikai` — the core library (`baikai/src/`). Owns provider-neutral vocabulary, including
  the interactive launch request type and `ThinkingLevel`.
- `baikai-claude` — the Anthropic/Claude provider (`baikai-claude/src/`). Owns the Claude
  API request shaping and the interactive `claude` launcher.
- `baikai-openai` — the OpenAI/Codex provider (`baikai-openai/src/`). Owns the OpenAI API
  request shaping and the interactive `codex` launcher.

All three enable warnings but not `-Werror`: their `.cabal` files set
`-Wall -Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates
-Wredundant-constraints`. `-Wall` includes `-Wincomplete-patterns`, so the implementation
made every `\case` on `ThinkingLevel` total when it added the two constructors. Otherwise a
partial match would have remained a warning at build time and a latent runtime `error` at
the new levels.

### The `ThinkingLevel` type and its consumers

`baikai/src/Baikai/ThinkingLevel.hs` defines:

```haskell
data ThinkingLevel
  = ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  | ThinkingXHigh
  | ThinkingMax
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

renderThinkingLevel :: ThinkingLevel -> Text
-- "minimal"/"low"/"medium"/"high"/"xhigh"/"max"
thinkingTokenBudget :: ThinkingLevel -> Natural
-- 1024/2048/8192/16384/24576/32768
```

It is re-exported from the umbrella module `baikai/src/Baikai.hs` (which has
`module Baikai.ThinkingLevel` in its export list), so downstream code imports it as
`Baikai.ThinkingLevel` or via `import Baikai`.

Every source or test place that pattern-matches a `ThinkingLevel` constructor is now total:

1. `baikai/src/Baikai/ThinkingLevel.hs`:
   - `renderThinkingLevel` renders all six canonical names.
   - `thinkingTokenBudget` maps all six levels to the budgets shown above.
2. `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`, function
   `compatibleEffort :: ThinkingLevel -> Text`, maps `minimal` to `low`, preserves
   `low`/`medium`/`high`, and clamps `xhigh`/`max` to `high` for non-native
   OpenAI-compatible hosts.
3. `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`, function
   `toReasoningEffort :: ThinkingLevel -> Chat.ReasoningEffort`, maps onto the upstream SDK
   enum `OpenAI.V1.Chat.Completions.ReasoningEffort` and clamps `xhigh`/`max` to its highest
   typed staging value; final native JSON restores the canonical values.
4. `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, function
   `adaptiveEffort :: ThinkingLevel -> Maybe Text`, maps minimal to low, preserves low,
   medium, xhigh, and max, and omits high because it is Anthropic's default. The budget
   branch of `computeThinking` uses `thinkingTokenBudget`.
5. `baikai-claude/test/ThinkingSpec.hs` covers all six values in both its case table and its
   test-local adaptive-effort expectation.

There are no other constructor matches in Haskell source. `baikai-smoke/test/ThinkingSmoke.hs`
uses selected levels but does not exhaustively match them, and `baikai-effectful` does not
pattern-match `ThinkingLevel`.

The OpenAI provider has two layers that must not be confused. `mapRequest` first constructs
the dependency's typed `Chat.CreateChatCompletion`, whose `ReasoningEffort` enum stops at
`High`. `Baikai.Provider.OpenAI.Api.prepareCall` then serializes that value and calls
`streamRequestBody`; this is the actual JSON body sent by the Server-Sent Events (SSE)
streaming HTTP transport. Therefore
`toReasoningEffort` clamps the new levels merely to make the typed intermediate total,
while `injectThinkingShape` overwrites `reasoning_effort` with `"xhigh"` or `"max"` for
`ThinkingFormatOpenAI`. DeepSeek, OpenRouter, and Together keep their existing compatibility
mapping and clamp the new levels to `"high"`.

The Anthropic dependency does not impose the same restriction. Its
`Claude.V1.Messages.OutputConfig.effort` field is `Maybe Text`, and current Anthropic API
documentation defines `low`, `medium`, `high`, `xhigh`, and `max`. In adaptive mode,
`adaptiveEffort` preserves `xhigh` and `max`; only `high` remains omitted,
because omission is documented as exactly equivalent to `high`. Manual-thinking catalog
entries continue to use `thinkingTokenBudget` instead.

### The interactive launch surface

`baikai/src/Baikai/Interactive.hs` defines the provider-neutral request. Its current shape:

```haskell
data InteractiveLaunchRequest = InteractiveLaunchRequest
  { systemPrompt :: !(Maybe Text),
    userPrompt :: !Text,
    modelId :: !(Maybe Text),
    workingDir :: !(Maybe FilePath),
    extraDirs :: ![FilePath],
    safety :: !InteractiveSafety,
    extraArgs :: ![Text],
    effort :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
```

The module exports the *type* without its data constructor and exports each field accessor by
name, plus the smart constructor:

```haskell
interactiveLaunchRequest :: Text -> InteractiveLaunchRequest
interactiveLaunchRequest prompt = InteractiveLaunchRequest
  { systemPrompt = Nothing, userPrompt = prompt, modelId = Nothing,
    workingDir = Nothing, extraDirs = [], safety = DefaultSafety, extraArgs = [],
    effort = Nothing }
```

Callers build a request with `interactiveLaunchRequest prompt` and then set fields via
record-update using the exported selectors (e.g. Seihou does
`(interactiveLaunchRequest p) { modelId = m, systemPrompt = Just s, effort = e, … }`).
Vendor launchers read fields via `generic-lens` labels (`req ^. #modelId`), enabled by the
`Generic` derivation, so they do not import the selectors directly. This
hidden-constructor/base-value design is intentionally evolvable: adding a defaulted field
does not break ordinary downstream construction or record updates.

The two vendor launchers each expose a pure argv builder and an `IO` launcher:

- `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`:
  `claudeInteractiveCommand :: ClaudeInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])`.
  It concatenates `modelArgs <> effortArgs <> systemPromptArgs <> extraDirArgs <>
  safetyArgs <> cfg.extraArgs <> req.extraArgs <> ["--", userPrompt]`. `effortArgs` emits
  `["--effort", value]`, mapping only `minimal` up to `low`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`:
  `codexInteractiveCommand :: CodexInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])`.
  It concatenates `modelArgs <> effortArgs <> workingDirArgs <> extraDirArgs <> safetyArgs <>
  cfg.extraArgs <> req.extraArgs <> ["--", prompt]`. `effortArgs` emits the canonical value
  as `["-c", "model_reasoning_effort=<value>"]`.

Both `claudeInteractiveCommand` and `codexInteractiveCommand` are already exercised by unit
tests in `baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs` respectively (grep for
the function names). The core request type is tested in `baikai/test/InteractiveSpec.hs`,
whose `requestDefaultTest` asserts every default field value of
`interactiveLaunchRequest "start here"`, including `effort = Nothing`.

### Verified CLI facts (the flags this plan targets)

These were confirmed from installed CLI help (`claude` 2.1.215, `codex-cli` 0.144.6) and
current vendor documentation:

- Claude: `--effort <level>`. Passing an unknown value prints
  `Valid values: low, medium, high, xhigh, max.` — note there is **no** `minimal`.
- Codex: no dedicated flag; use its generic config override
  `-c model_reasoning_effort=<value>`. Installed help documents `-c key=value` and its TOML
  parsing/fallback-to-string behavior. The installed backend validation previously reported
  `none, minimal, low, medium, high, xhigh, max`; the current Codex manual additionally
  documents model-dependent `ultra`.

`ThinkingLevel` has no `none` or `ultra` constructor and this plan does not add either.
`effort = Nothing` means "do not pass any effort flag; let the CLI use its own default," not
"disable reasoning." A caller that explicitly wants a Codex-only value can still use
`extraArgs`, which is rendered after the structured effort arguments and therefore remains
the last raw override.

### Packaging, changelog, and parent-plan context

The repository has one root `CHANGELOG.md` covering every package. There are no
`baikai-claude/CHANGELOG.md` or `baikai-openai/CHANGELOG.md` files. Implementation work adds
package-scoped bullets under the root `[Unreleased]` section; the manual release workflow in
`agents/skills/release/SKILL.md` later moves those bullets into dated version sections.

The in-tree versions are `baikai-0.3.2.0`, `baikai-claude-0.3.0.1`, and
`baikai-openai-0.3.0.1`. Hackage currently lists `baikai-0.3.1.0` and the two provider
packages at `0.3.0.1`; the local `baikai-0.3.2.0` tag exists but has not yet appeared in the
local Hackage index. Adding exported `ThinkingLevel` constructors requires the next core
PVP-major (`0.4.0.0`). Every publishable internal dependent — `baikai-claude`,
`baikai-openai`, `baikai-trace-otel`, `baikai-effectful`, and `baikai-kit` — currently has a
`baikai ^>=0.3.0` bound. The release workflow must update all five bounds and release all
five dependents; only the provider packages have feature code, while the other three need at
least bound-only patch releases. `baikai-smoke` is internal and is never published.

Finally, frontmatter names
`docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md` as the parent. At
implementation start that MasterPlan contained only completed EP-1 through EP-3; it now
registers this plan as completed EP-4 and records the follow-up's progress and discoveries.


## Plan of Work

Three milestones. Milestone 1 is pure core/provider vocabulary and is verifiable by building
and running the existing suites plus new unit tests. Milestone 2 adds the request field and
the two launcher translations, verifiable with pure argv unit tests (no live session).
Milestone 3 documents and validates end-to-end.

### Milestone 1 — Extend `ThinkingLevel` and keep every mapping total

Scope: add the two constructors and update every source and test mapping. Preserve higher
levels on native OpenAI and Anthropic wire requests, while keeping unavoidable staging or
compatible-host clamps explicit. At the end, `cabal build all` is clean and unit tests pin
the six-level rendering, budgets, and provider request shapes.

Edit `baikai/src/Baikai/ThinkingLevel.hs`:

1. Add constructors (keep `Ord` ordering ascending by effort, so append at the end):

   ```haskell
   data ThinkingLevel
     = ThinkingMinimal
     | ThinkingLow
     | ThinkingMedium
     | ThinkingHigh
     | ThinkingXHigh
     | ThinkingMax
     deriving stock (Eq, Ord, Show, Generic)
     deriving anyclass (FromJSON, ToJSON)
   ```

2. Widen `renderThinkingLevel` to the canonical Baikai names and update its Haddock to stop
   describing it as an OpenAI-only wire renderer:

   ```haskell
   renderThinkingLevel = \case
     ThinkingMinimal -> "minimal"
     ThinkingLow     -> "low"
     ThinkingMedium  -> "medium"
     ThinkingHigh    -> "high"
     ThinkingXHigh   -> "xhigh"
     ThinkingMax     -> "max"
   ```

3. Extend `thinkingTokenBudget`. Use 24576 and 32768 rather than another pair of doublings:
   current manual-thinking models have 64000-token output caps, and `mapRequest` requires
   room above the thinking budget for visible output.

   ```haskell
   thinkingTokenBudget = \case
     ThinkingMinimal -> 1024
     ThinkingLow     -> 2048
     ThinkingMedium  -> 8192
     ThinkingHigh    -> 16384
     ThinkingXHigh   -> 24576
     ThinkingMax     -> 32768
   ```

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` in two coordinated ways. First,
make the `ThinkingFormatOpenAI` branch of `injectThinkingShape` insert the canonical value
after the SDK request is serialized:

```haskell
ThinkingFormatOpenAI ->
  insertTop "reasoning_effort" (String (renderThinkingLevel lvl)) body
```

Import `renderThinkingLevel` along with `ThinkingLevel (..)`. Second, keep the existing
helper for non-native OpenAI-compatible shapes total, preferably renaming it to make its
scope clear:

```haskell
compatibleEffort = \case
  ThinkingMinimal -> "low"
  ThinkingLow     -> "low"
  ThinkingMedium  -> "medium"
  ThinkingHigh    -> "high"
  ThinkingXHigh   -> "high"
  ThinkingMax     -> "high"
```

Use `compatibleEffort` only in the OpenRouter, DeepSeek, and Together branches. Native
OpenAI requests must keep `xhigh`/`max`; the compatible-host branches retain their current
three-level common denominator.

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`, function
`toReasoningEffort` — clamp to `Chat.ReasoningEffort_High` only for the typed staging value,
with a comment pointing readers to `Shape.injectThinkingShape` for the final wire override:

```haskell
toReasoningEffort = \case
  ThinkingMinimal -> Chat.ReasoningEffort_Minimal
  ThinkingLow     -> Chat.ReasoningEffort_Low
  ThinkingMedium  -> Chat.ReasoningEffort_Medium
  ThinkingHigh    -> Chat.ReasoningEffort_High
  -- The SDK enum stops at High. Shape.injectThinkingShape restores the
  -- canonical xhigh/max string in the serialized native OpenAI body.
  ThinkingXHigh   -> Chat.ReasoningEffort_High
  ThinkingMax     -> Chat.ReasoningEffort_High
```

Edit `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, function
`adaptiveEffort` — preserve the two new native Anthropic values:

```haskell
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow     -> Just "low"
  ThinkingMedium  -> Just "medium"
  ThinkingHigh    -> Nothing
  ThinkingXHigh   -> Just "xhigh"
  ThinkingMax     -> Just "max"
```

Tests for Milestone 1 are mandatory at all three layers:

1. Create `baikai/test/ThinkingLevelSpec.hs` with table-driven assertions for all six
   `renderThinkingLevel` outputs and all six budgets. Add `ThinkingLevelSpec` to
   `baikai/baikai.cabal`'s `baikai-test` `other-modules`, import it qualified in
   `baikai/test/Main.hs`, and add `ThinkingLevelSpec.tests` to the root test group.
2. In `baikai-openai/test/ShapeSpec.hs`, shape `Models.openai_gpt_5_6_terra` requests with
   `ThinkingXHigh` and `ThinkingMax` and assert the final JSON has
   `reasoning_effort = "xhigh"` / `"max"`. Also add at least one compatible-host case proving
   the new higher values still clamp to `"high"`. If a direct `mapRequest` assertion is
   added, name it as an SDK-staging clamp so it cannot be mistaken for the final wire value.
3. In `baikai-claude/test/ThinkingSpec.hs`, extend `thinkingLevels` and the test-local
   `adaptiveEffort` helper. Assert `anthropic_claude_opus_4_7` requests built with
   `ThinkingXHigh`/`ThinkingMax` have `Messages.output_config.effort = Just "xhigh"` /
   `Just "max"`, and assert an `anthropic_claude_haiku_4_5` request built with `ThinkingMax`
   uses 32768 budget tokens while retaining visible-output room.

Acceptance: `cabal build all` emits no incomplete-pattern warning; `cabal test baikai-test
baikai-claude-test baikai-openai-test` passes with named tests proving the native wire values
and compatibility clamps.

### Milestone 2 — Add the `effort` field and translate it in both launchers

Scope: thread a provider-neutral effort through the interactive request into each vendor's
argv. At the end, pure argv unit tests prove the flags appear (and are absent when
`effort = Nothing`).

Edit `baikai/src/Baikai/Interactive.hs`:

1. Add the field to `InteractiveLaunchRequest`:

   ```haskell
   data InteractiveLaunchRequest = InteractiveLaunchRequest
     { systemPrompt :: !(Maybe Text),
       userPrompt :: !Text,
       modelId :: !(Maybe Text),
       workingDir :: !(Maybe FilePath),
       extraDirs :: ![FilePath],
       safety :: !InteractiveSafety,
       extraArgs :: ![Text],
       effort :: !(Maybe ThinkingLevel)
     }
     deriving stock (Eq, Show, Generic)
   ```

2. Add `effort` to the module export list (next to the other accessors), and add
   `import Baikai.ThinkingLevel (ThinkingLevel)`. `Baikai.Prelude` does not re-export this
   type.

3. Default it to `Nothing` in the smart constructor:

   ```haskell
   interactiveLaunchRequest prompt = InteractiveLaunchRequest
     { …, extraArgs = [], effort = Nothing }
   ```

Edit `baikai/test/InteractiveSpec.hs`, `requestDefaultTest`: add
`req ^. #effort @?= Nothing` so the default stays pinned.

Edit `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`:

1. Add an `effortArgs` helper and splice it into `claudeInteractiveCommand` (place it right
   after `modelArgs req` so related model/effort flags stay adjacent):

   ```haskell
   claudeInteractiveCommand cfg req =
     ( cfg ^. #executable,
       modelArgs req
         <> effortArgs req
         <> systemPromptArgs req
         <> extraDirArgs req
         <> safetyArgs req
         <> fmap Text.unpack (cfg ^. #extraArgs)
         <> fmap Text.unpack (req ^. #extraArgs)
         <> ["--", Text.unpack (req ^. #userPrompt)]
     )

   -- Claude's --effort accepts low|medium|high|xhigh|max (no "minimal"),
   -- so ThinkingMinimal maps up to "low".
   effortArgs :: InteractiveLaunchRequest -> [String]
   effortArgs req = case req ^. #effort of
     Nothing -> []
     Just lvl -> ["--effort", Text.unpack (claudeEffortValue lvl)]

   claudeEffortValue :: ThinkingLevel -> Text
   claudeEffortValue ThinkingMinimal = "low"
   claudeEffortValue lvl = renderThinkingLevel lvl
   ```

2. Add the explicit imports `ThinkingLevel (..)` and `renderThinkingLevel` from
   `Baikai.ThinkingLevel`.

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`:

1. Add an `effortArgs` helper and splice it into `codexInteractiveCommand` (after
   `modelArgs req`):

   ```haskell
   codexInteractiveCommand cfg req =
     ( cfg ^. #executable,
       modelArgs req
         <> effortArgs req
         <> workingDirArgs req
         <> extraDirArgs req
         <> safetyArgs req
         <> fmap Text.unpack (cfg ^. #extraArgs)
         <> fmap Text.unpack (req ^. #extraArgs)
         <> ["--", Text.unpack (codexInteractivePrompt req)]
     )

   -- Codex takes reasoning effort as a config override. Reuse the six-level
   -- Baikai renderer; provider-only none/ultra remain raw extraArgs values.
   effortArgs :: InteractiveLaunchRequest -> [String]
   effortArgs req = case req ^. #effort of
     Nothing -> []
     Just lvl -> ["-c", "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel lvl)]
   ```

2. Add the explicit import of `renderThinkingLevel` from `Baikai.ThinkingLevel`. The helper
   does not need the `ThinkingLevel` type name in its signature.

Tests for Milestone 2: extend the existing command-builder tests in
`baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs`. Keep each existing exact
`commandRenderingTest` request at the default `effort = Nothing`; its unchanged expected
argv is the backward-compatibility proof. Add table-driven effort tests that compare the
whole rendered argv, not merely list membership:

- Claude cases: `minimal -> low`, `low -> low`, `medium -> medium`, `high -> high`,
  `xhigh -> xhigh`, and `max -> max`, each producing
  `["--effort", value, "--", "prompt"]` with the default config.
- Codex cases: all six canonical values, each producing
  `["-c", "model_reasoning_effort=" <> value, "--", "prompt"]`.

The existing tests already use `interactiveLaunchRequest` plus lens updates, so no positional
constructor migration is needed. Because config and request `extraArgs` are rendered after
`effortArgs`, preserve and document their existing last-override precedence rather than
deduplicating raw flags.

Acceptance: `cabal test baikai-test baikai-claude-test baikai-openai-test` passes; exact argv
tests cover all six levels and the unchanged default argv.

### Milestone 3 — Docs, changelog, versioning, validation

Scope: document the new capability, record the API change, and validate the whole workspace.

1. Documentation: edit `docs/user/interactive-launches.md`. Add a “Reasoning effort”
   subsection with a record-update example and the exact mapping: Claude maps minimal to low
   and otherwise uses the canonical name; Codex passes all six canonical names through
   `model_reasoning_effort`. Explain that `Nothing` preserves the CLI default, while
   Codex-only `none`/`ultra` require `extraArgs`. Document the API-side `Options.thinking`
   mappings in `docs/user/models-and-providers.md`. Update the root README so its interactive
   highlight mentions effort and its smoke-test guidance distinguishes API-key gates from
   installed-CLI gates.

2. Changelog: add package-scoped bullets under `[Unreleased]` in the single root
   `CHANGELOG.md`. Record the two new `ThinkingLevel` constructors and request field for
   `baikai`, the Claude launcher flag plus adaptive API mapping for `baikai-claude`, and the
   Codex override plus native OpenAI wire mapping for `baikai-openai`. Do not create
   per-package changelog files or dated release headings during feature implementation.

3. Parent coordination: edit
   `docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md` using its existing
   registry format. Register this file as EP-4, add a progress item, and record why the
   completed initiative was reopened for a follow-up. Set EP-4 Complete and update the
   retrospective only after every acceptance command below passes.

4. Versioning note: record but do not perform the release. The core's exported sum extension
   implies `baikai 0.3.2.0 -> 0.4.0.0`. Provider code additions imply minor bumps from
   `0.3.0.1`; the release operator chooses the exact versions after reviewing all changes.
   The core major also requires updating `baikai ^>=0.3.0` in `baikai-claude`,
   `baikai-openai`, `baikai-trace-otel`, `baikai-effectful`, and `baikai-kit`, with at least
   patch releases for bound-only dependents. Run the manual workflow at
   `agents/skills/release/SKILL.md` as a separate follow-up; do not hand-edit versions or
   bounds in this feature plan. After those releases, Seihou must update its Cabal bounds and
   reproducible Nix pins for `baikai`, both provider packages, and `baikai-kit`, then set
   `effort` where it wants non-default behavior.

5. Validation: run the formatter, affected tests, full workspace build/test, and flake check.
   The test suite named `baikai-smoke` performs live network calls when provider key
   environment variables are present and also runs authenticated batch CLI completions when
   `claude` or `codex` is on `PATH`. Explicitly remove the keys and filter the two CLI
   directories from the full test command below. Do not launch an authenticated CLI merely
   to validate argv construction.

Acceptance: the interactive and models/providers user guides, root README, and root
changelog describe the feature and live-test behavior accurately; the parent MasterPlan
registers completed EP-4; `nix fmt` leaves no unintended diff; `cabal build all`, the
credential- and CLI-scrubbed `cabal test all`, and `nix flake check` are green; exact
command-builder tests and provider wire-shape tests prove the behavior without a live session.


## Concrete Steps

Run all commands from the baikai repository root
`/Users/shinzui/Keikaku/bokuno/baikai` unless stated otherwise.

Build and test after Milestone 1:

```bash
cabal build all
cabal test baikai-test baikai-claude-test baikai-openai-test
```

Expected: clean build (no incomplete-pattern warnings for `ThinkingLevel`), and the suites
report the new `ThinkingLevel` cases passing alongside the existing ones.

After Milestone 2, exercise the pure argv builders in `cabal repl` to see the flags without
launching a session:

```bash
cabal repl baikai-claude
```

```haskell
:set -XOverloadedStrings
import Baikai.Interactive
import Baikai.Provider.Claude.Interactive
import Baikai
let req = (interactiveLaunchRequest "hi") { effort = Just ThinkingHigh }
snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)
-- expect: ["--effort","high","--","hi"]
:quit
```

```bash
cabal repl baikai-openai
```

```haskell
:set -XOverloadedStrings
import Baikai.Interactive
import Baikai.Provider.OpenAI.Interactive
import Baikai
let req = (interactiveLaunchRequest "hi") { effort = Just ThinkingMax }
snd (codexInteractiveCommand defaultCodexInteractiveConfig req)
-- expect: ["-c","model_reasoning_effort=max","--","hi"]
:quit
```

The safe local CLI checks are help/version reads only; they do not authenticate or start a
model request:

```bash
claude --version
claude --help | rg -- '--effort'
codex --version
codex --help | rg -A4 -- '-c, --config'
```

Expected relevant output on the validated machine:

```text
2.1.215 (Claude Code)
--effort <level>  Effort level for the current session (low, medium, high, xhigh, max)
codex-cli 0.144.6
-c, --config <key=value>
```

Do not use an invalid `codex exec` or `claude -p` request as a routine smoke test: those
commands cross the authenticated provider boundary. The pure argv and wire-shape tests are
the acceptance evidence.

Full validation after Milestone 3 uses zsh's `path` array to retain the active toolchain while
removing the two directories that contain the locally authenticated provider CLIs:

```zsh
nix fmt
git diff --check
cabal build all
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
nix flake check
```

Expected: formatting completes without unrelated rewrites, `git diff --check` prints
nothing, every Cabal component builds, all tests pass, the smoke suite reports that provider
keys and both CLI binaries are unavailable and skips all live cases, and the flake check
succeeds.


## Validation and Acceptance

Accepted when all hold:

1. `ThinkingLevel` has six constructors and every source and test mapping is total:
   `cabal build all` emits no incomplete-pattern warning, and table-driven core tests assert
   every canonical rendering and budget, including `ThinkingXHigh -> 24576` and
   `ThinkingMax -> 32768`.

2. Native API intent survives dependency limitations: an OpenAI request shaped with
   `ThinkingXHigh`/`ThinkingMax` has final JSON `reasoning_effort = "xhigh"` / `"max"`, while
   a covered compatible host clamps those values to `"high"`. An Anthropic adaptive request
   has `output_config.effort = "xhigh"` / `"max"`; a manual-thinking request with
   `ThinkingMax` uses a 32768-token budget and still leaves visible-output room.

3. Interactive translation holds through exact pure tests for all six levels. Claude maps
   only `ThinkingMinimal` upward to `low`; Codex uses each canonical value. With
   `effort = Nothing`, both complete argvs are byte-identical to their pre-change expected
   lists.

4. Backward compatibility: `interactiveLaunchRequest "x"` still has every prior default, plus
   `effort = Nothing` (asserted in `requestDefaultTest`). Callers that never set `effort`
   observe no argv change.

5. `docs/user/interactive-launches.md` and `docs/user/models-and-providers.md` describe the
   interactive and API mappings, the root README accurately distinguishes the two live-smoke
   gates, and the root `CHANGELOG.md` describes the change. The parent MasterPlan registers
   EP-4 as complete, and the coordinated release follow-up covers every internal dependent.

6. `nix fmt`, `git diff --check`, `cabal build all`, the provider-key- and
   CLI-binary-scrubbed `cabal test all`, and `nix flake check` succeed. No authenticated
   provider request or interactive launch is part of the final acceptance run.


## Idempotence and Recovery

All source edits are additive and the commands are safe to repeat. Cabal and Nix may refresh
local build caches, and `nix fmt` may rewrite formatting, but no acceptance command contacts
an AI provider or changes remote state. The `cabal repl` checks and argv builders are pure.
If a milestone is committed independently, the build stays green because the field defaults
to `Nothing` and every new constructor match is added in Milestone 1. To roll back, revert
the milestone's commit; earlier milestones remain valid because Milestone 2 only reads the
constructors introduced in Milestone 1.

The version bump / release is deliberately deferred to the release skill; until it runs, the
in-tree change is complete and testable but unreleased, so no downstream package is affected.


## Interfaces and Dependencies

No new external dependencies. Hackage's current `openai-2.5.3` still has the
`OpenAI.V1.Chat.Completions.ReasoningEffort` constructors `_Minimal | _Low | _Medium |
_High`; Baikai clamps only the typed staging request, then restores canonical higher values
in the raw JSON body that its streaming HTTP transport actually sends. Hackage's current
`claude-1.4.0` already exposes `OutputConfig.effort :: Maybe Text`, so no dependency upgrade
is needed there either.

Interfaces at completion:

- `baikai/src/Baikai/ThinkingLevel.hs`:
  ```haskell
  data ThinkingLevel = ThinkingMinimal | ThinkingLow | ThinkingMedium
                     | ThinkingHigh | ThinkingXHigh | ThinkingMax
  renderThinkingLevel  :: ThinkingLevel -> Text   -- canonical: minimal…max
  thinkingTokenBudget  :: ThinkingLevel -> Natural
  ```
- `baikai/src/Baikai/Interactive.hs`:
  ```haskell
  data InteractiveLaunchRequest = InteractiveLaunchRequest { …, effort :: !(Maybe ThinkingLevel) }
  -- `effort` added to the module export list; interactiveLaunchRequest defaults it to Nothing
  ```
- `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`: `claudeInteractiveCommand`
  emits `["--effort", <value>]` when `effort` is set (`ThinkingMinimal -> "low"`, else the
  canonical name).
- `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`: `codexInteractiveCommand` emits
  `["-c", "model_reasoning_effort=<value>"]` when `effort` is set (canonical name).
- `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`: native OpenAI JSON carries the
  canonical value; DeepSeek/OpenRouter/Together compatibility JSON clamps the two new levels
  to `high`.
- `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`: adaptive requests carry
  explicit `xhigh`/`max`; manual-thinking requests use the extended fixed token budgets.

Downstream impact: `baikai` needs a PVP-major release; all five publishable dependents need
new releases because their core bound changes, with feature-minor releases appropriate for
`baikai-claude` and `baikai-openai` and at least patches for bound-only packages. The exact
release operation belongs to `agents/skills/release/SKILL.md`. Seihou will then update its
`baikai*` Cabal bounds and Nix pins and may set `effort` on requests built in
`Seihou.CLI.AgentLaunchExec`.


## Revision Note

2026-07-20: Validated the draft against the current codebase, Mori-located dependency
sources, current Hackage releases, installed CLI help, official provider documentation, the
repository release workflow, and the parent MasterPlan. Revised the API work so native
OpenAI and Anthropic requests preserve `xhigh`/`max`; added missing test-module and exhaustive
test coverage; corrected the single-changelog and six-package release workflow; scoped
provider-only `none`/`ultra`; added parent-plan synchronization and full repository gates.

2026-07-20: Completed all three milestones. Corrected the final validation command after
discovering that API-key removal alone does not gate batch CLI smoke completions; the final
acceptance run now also hides installed Claude and Codex binaries while preserving the active
Cabal/GHC toolchain.

2026-07-20: Audited documentation after completion. Added the API-side six-level reasoning
mapping to the models/providers guide, corrected the root README's smoke-test gate and
interactive capability descriptions, and synchronized the plan's Purpose, current Context,
living sections, documentation milestone, and acceptance criteria with the implemented state.
