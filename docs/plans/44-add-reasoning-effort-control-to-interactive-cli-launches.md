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
constructs the command line. Today a caller can pick the model for such a launch, but it
cannot control the **reasoning effort**: how hard the model thinks before answering. Both
CLIs support this (Claude via `--effort <level>`, Codex via a config override
`-c model_reasoning_effort=<value>`), but Baikai's interactive request type has no field
for it, so the only escape hatch is the raw `extraArgs` list, which forces every caller to
re-learn each vendor's flag spelling.

After this change, a caller sets one provider-neutral field on the interactive request and
Baikai translates it to the right vendor flag. Concretely, Baikai's `ThinkingLevel` — the
existing four-bucket effort preference already used on the batch/API path — gains two higher
buckets (`ThinkingXHigh`, `ThinkingMax`) so it can express the full range both CLIs accept,
and the interactive request gains an `effort :: Maybe ThinkingLevel` field.

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

**The observable outcome**, verifiable with pure unit tests and no authenticated session:
given an interactive request whose `effort` is `Just ThinkingHigh`,
`claudeInteractiveCommand` produces an argv containing `["--effort","high"]`, and
`codexInteractiveCommand` produces one containing `["-c","model_reasoning_effort=high"]`.
With `effort = Nothing` (the default), neither flag appears, so existing behavior is
unchanged. The higher buckets map through too: `ThinkingMax` yields `--effort max` for
Claude and `model_reasoning_effort=max` for Codex.

This unblocks downstream callers such as Seihou, which want deterministic, explicit
reasoning-effort selection per agent command rather than inheriting whatever effort the
ambient CLI session defaults to.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: Extend `ThinkingLevel` with `ThinkingXHigh` and `ThinkingMax` in
  `baikai/src/Baikai/ThinkingLevel.hs`; make every existing pattern-match total with the
  documented clamps; add unit coverage. `baikai`, `baikai-claude`, `baikai-openai` all build
  and their test suites pass unchanged.
- [ ] Milestone 2: Add `effort :: Maybe ThinkingLevel` to `InteractiveLaunchRequest` and
  translate it in both vendor launchers (`--effort` for Claude, `-c model_reasoning_effort=`
  for Codex). Add argv unit tests. `effort = Nothing` leaves argv byte-identical to today.
- [ ] Milestone 3: Documentation, per-package CHANGELOG entries, version-bump note, full
  test + smoke run.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent interactive reasoning effort by **extending the existing
  `ThinkingLevel` type** with two new constructors, `ThinkingXHigh` and `ThinkingMax`,
  rather than introducing a separate interactive-only effort enum.
  Rationale: One effort vocabulary across the API and interactive surfaces is simpler for
  callers and keeps `Baikai.ThinkingLevel` the single source of truth. The cost — API
  providers that cannot express the two new levels must clamp — is small and localized to
  three mapping functions, and is documented at each site.
  Date: 2026-07-20

- Decision: For the **OpenAI Chat Completions API path**, clamp `ThinkingXHigh` and
  `ThinkingMax` to `high`. The upstream `openai` Haskell SDK enum
  `OpenAI.V1.Chat.Completions.ReasoningEffort` only has `Minimal | Low | Medium | High`
  (verified in the SDK source), so `high` is the strongest value it can send.
  Rationale: Clamping preserves a valid request instead of failing or inventing a wire
  value the SDK/endpoint would reject.
  Date: 2026-07-20

- Decision: For the **Anthropic API path**, `ThinkingXHigh`/`ThinkingMax` behave like the
  current top of the scale: in *adaptive* mode `adaptiveEffort` returns `Nothing` (the same
  as `ThinkingHigh`, meaning "let adaptive use its highest effort"); in *budget* mode
  `thinkingTokenBudget` returns larger token budgets (`ThinkingXHigh -> 24576`,
  `ThinkingMax -> 32768`) that continue the existing doubling-ish progression.
  Rationale: Anthropic has no `xhigh`/`max` primitive; mapping them to the strongest
  available behavior is the faithful interpretation.
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
  It has no call sites in `baikai`/vendor source today (only the API request builders use
  `toReasoningEffort`/`effort`, which stay clamped), so widening it is purely additive for
  existing values and lets the Codex launcher reuse it.
  Rationale: One canonical string function avoids a second near-duplicate; the API-specific
  clamps remain in the API-specific mappers where they belong.
  Date: 2026-07-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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
-Wredundant-constraints`. `-Wall` includes `-Wincomplete-patterns`, so a non-exhaustive
`\case` on `ThinkingLevel` after adding constructors will produce a warning (not a hard
error). We nevertheless make every match total — leaving a partial match would be a latent
runtime `error` at the new levels.

### The `ThinkingLevel` type and its consumers

`baikai/src/Baikai/ThinkingLevel.hs` defines:

```haskell
data ThinkingLevel
  = ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

renderThinkingLevel :: ThinkingLevel -> Text   -- "minimal"/"low"/"medium"/"high"
thinkingTokenBudget :: ThinkingLevel -> Natural -- 1024/2048/8192/16384
```

It is re-exported from the umbrella module `baikai/src/Baikai.hs` (which has
`module Baikai.ThinkingLevel` in its export list), so downstream code imports it as
`Baikai.ThinkingLevel` or via `import Baikai`.

Every place that pattern-matches a `ThinkingLevel` constructor (found by grepping the three
packages) — these are the sites that must become total when we add `ThinkingXHigh`/
`ThinkingMax`:

1. `baikai/src/Baikai/ThinkingLevel.hs`:
   - `renderThinkingLevel` (`\case` over all four constructors).
   - `thinkingTokenBudget` (`\case` over all four).
2. `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`, function `effort :: ThinkingLevel -> Text`
   (around line 211), currently: `Minimal->"low", Low->"low", Medium->"medium", High->"high"`.
3. `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`, function
   `toReasoningEffort :: ThinkingLevel -> Chat.ReasoningEffort` (around line 124), mapping onto
   the upstream SDK enum `OpenAI.V1.Chat.Completions.ReasoningEffort`
   (`ReasoningEffort_Minimal | _Low | _Medium | _High` — no higher variants).
4. `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, function
   `adaptiveEffort :: ThinkingLevel -> Maybe Text` (around line 181), currently:
   `Minimal->Just "low", Low->Just "low", Medium->Just "medium", High->Nothing`. It is called
   from `computeThinking`; the budget branch of `computeThinking` uses `thinkingTokenBudget`.

There are no other constructor matches in the packages. The `effectful`-flavored package
(`baikai-effectful`) does not pattern-match `ThinkingLevel`.

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
    extraArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
```

The module exports the *type* and each field accessor by name (so field selectors are on),
plus the smart constructor:

```haskell
interactiveLaunchRequest :: Text -> InteractiveLaunchRequest
interactiveLaunchRequest prompt = InteractiveLaunchRequest
  { systemPrompt = Nothing, userPrompt = prompt, modelId = Nothing,
    workingDir = Nothing, extraDirs = [], safety = DefaultSafety, extraArgs = [] }
```

Callers build a request with `interactiveLaunchRequest prompt` and then set fields via
record-update using the exported selectors (e.g. Seihou does
`(interactiveLaunchRequest p) { modelId = m, systemPrompt = Just s, … }`). Vendor launchers
read fields via `generic-lens` labels (`req ^. #modelId`), enabled by the `Generic`
derivation, so they do not import the selectors directly.

The two vendor launchers each expose a pure argv builder and an `IO` launcher:

- `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`:
  `claudeInteractiveCommand :: ClaudeInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])`.
  It concatenates `modelArgs <> systemPromptArgs <> extraDirArgs <> safetyArgs <>
  cfg.extraArgs <> req.extraArgs <> ["--", userPrompt]`. `modelArgs` emits `["--model", mid]`
  for a non-blank model, else `[]`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`:
  `codexInteractiveCommand :: CodexInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])`.
  It concatenates `modelArgs <> workingDirArgs <> extraDirArgs <> safetyArgs <>
  cfg.extraArgs <> req.extraArgs <> ["--", prompt]`.

Both `claudeInteractiveCommand` and `codexInteractiveCommand` are already exercised by unit
tests in `baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs` respectively (grep for
the function names). The core request type is tested in `baikai/test/InteractiveSpec.hs`,
whose `requestDefaultTest` asserts every default field value of
`interactiveLaunchRequest "start here"`.

### Verified CLI facts (the flags this plan targets)

These were confirmed live against the installed CLIs (`claude` 2.1.215, `codex` 0.144.6):

- Claude: `--effort <level>`. Passing an unknown value prints
  `Valid values: low, medium, high, xhigh, max.` — note there is **no** `minimal`.
- Codex: no dedicated flag; use its generic config override
  `-c model_reasoning_effort=<value>`. The backend validates the enum and reports the full
  accepted set: `none, minimal, low, medium, high, xhigh, max`. Setting
  `-c model_reasoning_effort=low` was observed to change the session header from the default
  `xhigh` to `low`.

`ThinkingLevel` has no `none` constructor and this plan does not add one: `effort = Nothing`
already means "do not pass any effort flag; let the CLI use its own default", which is the
useful distinction. A caller that explicitly wants Codex's `none` can still use `extraArgs`.


## Plan of Work

Three milestones. Milestone 1 is pure core/provider vocabulary and is verifiable by building
and running the existing suites plus new unit tests. Milestone 2 adds the request field and
the two launcher translations, verifiable with pure argv unit tests (no live session).
Milestone 3 documents and validates end-to-end.

### Milestone 1 — Extend `ThinkingLevel` and keep every mapping total

Scope: add the two constructors and update the four mapping sites with documented clamps. At
the end, `cabal build all` is clean and every existing test still passes, plus new unit tests
pin the new levels' behavior.

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

2. Widen `renderThinkingLevel` to the canonical names and update its Haddock to say it
   returns the canonical level name (a superset of what OpenAI's Chat Completions endpoint
   accepts; API-specific mappers clamp):

   ```haskell
   renderThinkingLevel = \case
     ThinkingMinimal -> "minimal"
     ThinkingLow     -> "low"
     ThinkingMedium  -> "medium"
     ThinkingHigh    -> "high"
     ThinkingXHigh   -> "xhigh"
     ThinkingMax     -> "max"
   ```

3. Extend `thinkingTokenBudget` (continue the progression):

   ```haskell
   thinkingTokenBudget = \case
     ThinkingMinimal -> 1024
     ThinkingLow     -> 2048
     ThinkingMedium  -> 8192
     ThinkingHigh    -> 16384
     ThinkingXHigh   -> 24576
     ThinkingMax     -> 32768
   ```

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`, function `effort` — clamp the two
new levels to `"high"`:

```haskell
effort = \case
  ThinkingMinimal -> "low"
  ThinkingLow     -> "low"
  ThinkingMedium  -> "medium"
  ThinkingHigh    -> "high"
  ThinkingXHigh   -> "high"   -- Chat Completions has no higher level
  ThinkingMax     -> "high"
```

Edit `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`, function
`toReasoningEffort` — clamp to `Chat.ReasoningEffort_High`, with a comment referencing this
plan:

```haskell
toReasoningEffort = \case
  ThinkingMinimal -> Chat.ReasoningEffort_Minimal
  ThinkingLow     -> Chat.ReasoningEffort_Low
  ThinkingMedium  -> Chat.ReasoningEffort_Medium
  ThinkingHigh    -> Chat.ReasoningEffort_High
  ThinkingXHigh   -> Chat.ReasoningEffort_High  -- SDK enum stops at High; clamp
  ThinkingMax     -> Chat.ReasoningEffort_High
```

Edit `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, function
`adaptiveEffort` — treat the two new levels like `ThinkingHigh` (return `Nothing`, i.e. let
adaptive use its top effort):

```haskell
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow     -> Just "low"
  ThinkingMedium  -> Just "medium"
  ThinkingHigh    -> Nothing
  ThinkingXHigh   -> Nothing
  ThinkingMax     -> Nothing
```

Tests for Milestone 1: add cases to `baikai`'s test suite (there is a suitable spec for
core; if none targets `ThinkingLevel`, add `renderThinkingLevel`/`thinkingTokenBudget` cases
to `baikai/test/InteractiveSpec.hs` is *not* appropriate — instead add a small
`ThinkingLevelSpec` module and wire it into `baikai/test/Main.hs`). Assert:
`renderThinkingLevel ThinkingXHigh == "xhigh"`, `renderThinkingLevel ThinkingMax == "max"`,
`thinkingTokenBudget ThinkingMax == 32768`. Optionally assert the clamps in
`baikai-openai`/`baikai-claude` where those functions are already tested (e.g.
`baikai-openai/test/ReasoningSpec.hs` and `baikai-claude/test/ThinkingSpec.hs`) — add a case
that a request built with `ThinkingMax` produces a `high`/top-budget shaped request.

Acceptance: `cabal build all` clean; `cabal test all` green with the new cases named.

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
   `import Baikai.ThinkingLevel (ThinkingLevel)` (or rely on `Baikai.Prelude` if it already
   re-exports it — check; if not, add the explicit import).

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

2. Add the imports it needs: `ThinkingLevel (..)` and `renderThinkingLevel` from
   `Baikai.ThinkingLevel` (or from `Baikai`).

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

   -- Codex takes reasoning effort as a config override; its enum accepts the
   -- full canonical set, so reuse renderThinkingLevel directly.
   effortArgs :: InteractiveLaunchRequest -> [String]
   effortArgs req = case req ^. #effort of
     Nothing -> []
     Just lvl -> ["-c", "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel lvl)]
   ```

2. Add the imports: `ThinkingLevel` and `renderThinkingLevel` from `Baikai.ThinkingLevel`
   (or `Baikai`).

Tests for Milestone 2: extend the existing command-builder tests in
`baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs`. For Claude, assert that
`snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)` for a request with
`effort = Just ThinkingHigh` contains `["--effort","high"]` in order and, for
`effort = Just ThinkingMinimal`, contains `["--effort","low"]`; and that with
`effort = Nothing` the argv equals today's (no `--effort`). For Codex, assert the argv for
`effort = Just ThinkingMax` contains `["-c","model_reasoning_effort=max"]` and that
`effort = Nothing` omits it. If those test modules build requests with the positional record
constructor rather than the smart constructor, update them to add the new field (or switch
to `interactiveLaunchRequest` + record-update, which is more robust to future fields).

Acceptance: `cabal test all` green; the argv assertions above pass.

### Milestone 3 — Docs, changelog, versioning, validation

Scope: document the new capability, record the API change, and validate the whole workspace.

1. Documentation: update the interactive-launch user guide under `docs/user/` (find it with
   `ls docs/user` and grep for "interactive"/"effort"; it is the guide produced by
   masterplan 3). Add an "reasoning effort" subsection showing the `effort` field, the
   provider-neutral levels, and the per-CLI mapping table (Claude has no `minimal`; API
   providers clamp `xhigh`/`max` to `high`).

2. CHANGELOG: add an entry to each affected package's changelog
   (`baikai/CHANGELOG.md`, `baikai-claude/CHANGELOG.md`, `baikai-openai/CHANGELOG.md` — or
   the repo's changelog convention; confirm by `ls`). Note the new `ThinkingLevel`
   constructors, the interactive `effort` field, and the two launcher flags.

3. Versioning: adding a constructor to the exported `ThinkingLevel` and a field to the
   exported `InteractiveLaunchRequest` are breaking changes under the Haskell PVP (downstream
   exhaustive matches and positional constructors can break). Recommend bumping `baikai`
   `0.3.2.0 -> 0.4.0.0`, and `baikai-claude`/`baikai-openai` `0.3.0.1 -> 0.4.0.0`, and
   widening their inter-package bounds accordingly. Do the actual coordinated version/tag via
   the repository's release skill (`.claude/skills/release`) as a follow-up rather than
   hand-editing versions here; this plan leaves a Progress note pointing at that step.
   Downstream note: Seihou currently depends on `baikai ^>=0.3.1.0`; after release it must
   widen to include `0.4` and set `effort` where it wants non-default behavior.

4. Validation: run the full workspace build, test, and the interactive smoke check.

Acceptance: docs render the new subsection; `cabal build all` and `cabal test all` are green;
`baikai/test/InteractiveSpec.hs` and both vendor command-builder tests pass; the smoke suite
(`baikai-smoke`) still builds.


## Concrete Steps

Run all commands from the baikai repository root
`/Users/shinzui/Keikaku/bokuno/baikai` unless stated otherwise.

Build and test after Milestone 1:

```bash
cabal build all
cabal test all
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
```

For reference, the live-CLI facts these flags rely on (already confirmed; no need to re-run
unless validating on a different machine):

```text
$ claude --effort __bogus__ -p "hi"
Warning: Unknown --effort value '__bogus__' — ignoring it and using the default effort. Valid values: low, medium, high, xhigh, max.

$ printf 'hi\n' | codex exec -m gpt-5.6-terra -c model_reasoning_effort=__bogus__ --sandbox read-only --skip-git-repo-check -
ERROR: … [reasoning.effort] [invalid_enum_value] Invalid value: '__bogus__'. Supported values are: 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', and 'max'.
```

Full validation after Milestone 3:

```bash
cabal build all
cabal test all
```


## Validation and Acceptance

Accepted when all hold:

1. `ThinkingLevel` has six constructors and every mapping is total: `cabal build all` emits
   no incomplete-pattern warning for it, and new unit cases assert
   `renderThinkingLevel ThinkingXHigh == "xhigh"`, `renderThinkingLevel ThinkingMax == "max"`,
   and `thinkingTokenBudget ThinkingMax == 32768`.

2. API clamps hold: a Chat-Completions request shaped with `ThinkingMax` sends
   `reasoning_effort = high` (via `toReasoningEffort`/`effort`), and the Anthropic adaptive
   path treats `ThinkingXHigh`/`ThinkingMax` like `ThinkingHigh`.

3. Interactive translation holds (pure, no live session): with `effort = Just ThinkingHigh`,
   `claudeInteractiveCommand` argv contains `["--effort","high"]`; with
   `effort = Just ThinkingMinimal` it contains `["--effort","low"]`; with `effort = Nothing`
   the argv is byte-identical to the pre-change output. With `effort = Just ThinkingMax`,
   `codexInteractiveCommand` argv contains `["-c","model_reasoning_effort=max"]`; with
   `effort = Nothing` it omits the flag.

4. Backward compatibility: `interactiveLaunchRequest "x"` still has every prior default, plus
   `effort = Nothing` (asserted in `requestDefaultTest`). Callers that never set `effort`
   observe no argv change.

5. `cabal build all` and `cabal test all` are green; docs and per-package CHANGELOGs describe
   the change; the versioning follow-up is recorded in Progress.


## Idempotence and Recovery

All edits are additive and re-runnable; building/testing has no side effects. The `cabal
repl` checks are read-only. No authenticated session is required for any acceptance step —
the argv builders are pure. If a milestone is committed independently, the build stays green
because the field defaults to `Nothing` and the mappings stay total. To roll back, revert the
milestone's commit; earlier milestones remain valid because Milestone 2 only *reads* the new
`ThinkingLevel` constructors added in Milestone 1.

The version bump / release is deliberately deferred to the release skill; until it runs, the
in-tree change is complete and testable but unreleased, so no downstream package is affected.


## Interfaces and Dependencies

No new external dependencies. The upstream `openai` Haskell SDK enum
`OpenAI.V1.Chat.Completions.ReasoningEffort` (`_Minimal | _Low | _Medium | _High`) is the
reason the OpenAI API path clamps; no SDK change is needed.

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

Downstream impact: `baikai`, `baikai-claude`, `baikai-openai` need coordinated PVP-major
version bumps (see Milestone 3) handled by `.claude/skills/release`. Seihou (a consumer)
will then widen its `baikai*` bounds and may set `effort` on the interactive requests it
builds in `Seihou.CLI.AgentLaunchExec`.
