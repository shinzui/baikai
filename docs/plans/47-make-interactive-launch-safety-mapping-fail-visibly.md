---
id: 47
slug: make-interactive-launch-safety-mapping-fail-visibly
title: "Make interactive launch safety mapping fail visibly"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Make interactive launch safety mapping fail visibly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Baikai can start a local coding-agent tool — the `claude` binary or the `codex` binary — as an
**interactive launch**, meaning it hands the user's terminal to the tool and returns only when
the human quits. The caller describes what the session may do using a shared safety value.
Today, if the caller describes a policy the chosen tool cannot express, Baikai silently starts
the tool **with no restriction at all** and reports success.

Concretely: a caller who asks to launch Claude Code with a Codex sandbox policy gets a Claude
session with no permission restrictions. A caller who asks to launch Codex with a Claude tool
allow-list gets a Codex session with its default sandbox. In both cases the caller asked to be
constrained, was not constrained, and was not told. That is a security-relevant silent
downgrade, and it is currently two lines of shipped code.

This plan fixes it. After this plan, both launchers refuse such a request with a structured
error naming the provider and explaining what it cannot express, and no process is started. A
caller who asks for a restriction either gets that restriction or gets an error — never a weaker
session presented as the one they asked for.

The fix is small in code and consequential in packaging. Both launchers' return types change, so
`baikai-claude` and `baikai-openai` need major version bumps and every downstream consumer must
handle the new result. That cost is the reason this is its own plan rather than a footnote in
another: it must be reviewable and revertible on its own.

**The observable outcome**, verifiable by running one test command: after this plan,
`cabal test baikai-claude-test baikai-openai-test` passes with new cases in which
`claudeInteractiveCommand` given a request whose safety is
`CodexSandbox CodexReadOnly CodexApprovalNever` returns `Left` with a message naming Claude and
the Codex policy, and `codexInteractiveCommand` given a request whose safety is
`ClaudeAllowedTools ["Read"]` returns `Left` with a message naming Codex and the tool allow-list.
Before this plan both return a successfully rendered, unrestricted command.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: Write temporary tests that demonstrate the current silent downgrade, and
      record the observed pre-fix output as evidence.
- [ ] Milestone 2: Change `claudeInteractiveCommand` and `launchClaudeInteractive` to refuse an
      inexpressible policy.
- [ ] Milestone 3: Change `codexInteractiveCommand` and `launchCodexInteractive` the same way.
- [ ] Milestone 4: Update every in-repository caller, including the smoke suite.
- [ ] Milestone 5: Document the change, record the breaking-release consequence, and run the full
      offline validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. Milestone 1 is designed to produce the first entry: paste the pre-fix rendered command
that proves the downgrade is real, so the retrospective has the before-and-after.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Both the pure command builders and the `IO` launchers return
  `Either AgentRenderError`, rather than the launchers throwing an exception.
  Rationale: an inexpressible safety policy is a caller mistake discovered before any process
  exists, which is exactly the situation a total function should describe in its return type.
  Throwing would make the failure invisible in the type, so a caller who forgot to handle it
  would crash at runtime rather than fail to compile — which is how the current defect survived
  in the first place. The existing repository style agrees: the batch providers in
  `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` return errors as values rather than throwing.
  Date: 2026-07-30

- Decision: Reuse `Baikai.Agent.AgentRenderError` rather than defining a new interactive-only
  error type.
  Rationale: the repository should assert one rule — unsupported policy fails visibly — and
  implement it once. Two refusal types would mean two renderers, two sets of messages, and two
  places for the rule to drift. The specific constructor used is `SafetyNotExpressible`, which
  `docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` added for exactly this purpose
  because it carries only a provider and an explanation, with no capability profile that the
  interactive vocabulary does not have.
  Date: 2026-07-30

- Decision: Do **not** unify `Baikai.Interactive.InteractiveSafety` with the unattended
  `Baikai.Agent.AgentSafety`.
  Rationale: they describe different things. `InteractiveSafety` has provider-specific
  constructors and an approval policy that only makes sense when a human is present to approve;
  `AgentSafety` has a provider-neutral capability profile and a policy ceiling that only make
  sense when nobody is. Merging them would give each surface fields that are meaningless on it.
  The two surfaces share the *refusal* type, which is what makes the contract common; sharing the
  policy type would make the vocabulary dishonest. This decision is also recorded in the parent
  MasterPlan; if you are reading this while tempted to simplify, that is the argument.
  Date: 2026-07-30

- Decision: `DefaultSafety` continues to render no flags, and that is not a downgrade.
  Rationale: `DefaultSafety` means "I am not specifying a policy; use the tool's own default".
  Rendering nothing is precisely honoring it. The defect is only about a caller who specified a
  policy that was then discarded. Do not turn `DefaultSafety` into an error.
  Date: 2026-07-30

- Decision: An **empty** `ClaudeAllowedTools` list renders successfully on both providers rather
  than being refused by Codex.
  Rationale: an empty allow-list restricts nothing, so there is nothing Codex is failing to
  honor, and refusing it would break callers that pass an empty list to mean "no restriction".
  Only a non-empty list represents a restriction Codex cannot express. The asymmetry is
  deliberate and must be commented in the code.
  Date: 2026-07-30


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository.

Baikai is a multi-package Cabal workspace; Cabal is the Haskell build tool and each package is a
directory containing a `.cabal` file. The packages are listed in `cabal.project` at the repository
root. This plan edits two packages, `baikai-claude` and `baikai-openai`, plus any callers
elsewhere in the workspace.

Baikai has three surfaces that involve a local coding-agent binary, and confusing them is the main
hazard when working in these files.

The **batch completion** surface drives `claude -p` or `codex exec`, waits, and returns a parsed
Baikai response value. It lives in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. **This plan does not touch it.**

The **interactive launch** surface starts a real terminal session, inheriting the parent's
standard input, output, and error, and returns an exit code when the human quits. It lives in
`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, over the shared vocabulary in
`baikai/src/Baikai/Interactive.hs`. **This is the surface this plan fixes.**

The **unattended run** surface starts the tool with no human and no terminal. Its vocabulary is in
`baikai/src/Baikai/Agent.hs` and its renderers in
`baikai-claude/src/Baikai/Provider/Claude/Agent.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs`. **This plan does not touch it**, but it
borrows one type from it.

### The shared interactive vocabulary

`baikai/src/Baikai/Interactive.hs` defines:

```haskell
data InteractiveSafety
  = DefaultSafety
  | ClaudeAllowedTools [Text]
  | CodexSandbox CodexSandboxMode CodexApprovalPolicy
  deriving stock (Eq, Ord, Show, Generic)

data CodexSandboxMode = CodexReadOnly | CodexWorkspaceWrite | CodexDangerFullAccess
data CodexApprovalPolicy
  = CodexApprovalUntrusted | CodexApprovalOnFailure
  | CodexApprovalOnRequest | CodexApprovalNever
```

Notice that this single type carries constructors for both providers. That is the design that
makes the defect possible: nothing prevents handing a `CodexSandbox` value to the Claude launcher.
This plan does not change the type — it changes what the launchers do when they receive a
constructor they cannot use.

`InteractiveLaunchRequest` is the request record, with fields `systemPrompt`, `userPrompt`,
`modelId`, `workingDir`, `extraDirs`, `safety`, `extraArgs`, and `effort`. Callers build it with
`interactiveLaunchRequest :: Text -> InteractiveLaunchRequest` and then use record-update or lens
syntax. `InteractiveLaunchResult` holds a provider and an `ExitCode`.

### The exact defect

In `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`, the final function in the file:

```haskell
safetyArgs :: InteractiveLaunchRequest -> [String]
safetyArgs req = case req ^. #safety of
  ClaudeAllowedTools [] -> []
  ClaudeAllowedTools tools ->
    ["--allowedTools", Text.unpack (Text.intercalate "," tools)]
  DefaultSafety -> []
  CodexSandbox _ _ -> []
```

The last line is the bug. A caller who supplied a Codex sandbox policy gets an empty argument
list, so `claudeInteractiveCommand` renders a command with no permission flags and
`launchClaudeInteractive` starts an unrestricted Claude session.

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, the mirror image:

```haskell
safetyArgs :: InteractiveLaunchRequest -> [String]
safetyArgs req = case req ^. #safety of
  CodexSandbox sandbox approval -> codexSafetyArgs sandbox approval
  DefaultSafety -> []
  ClaudeAllowedTools _ -> []
```

The last line is the bug. Note that neither is an incomplete-pattern warning: both matches are
total. The compiler cannot help here, which is why the defect needs a test rather than a flag.

### The current signatures you will change

In `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`:

```haskell
claudeInteractiveCommand ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])

launchClaudeInteractive ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest -> IO InteractiveLaunchResult
```

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`:

```haskell
codexInteractiveCommand ::
  CodexInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])

launchCodexInteractive ::
  CodexInteractiveConfig -> InteractiveLaunchRequest -> IO InteractiveLaunchResult
```

`launchClaudeInteractive` spawns through the `cradle` library —
`run $ cmd exe & addArgs args & maybe id setWorkingDir (req ^. #workingDir)`.
`launchCodexInteractive` spawns through `System.Process` with `std_in`, `std_out`, and `std_err`
all set to `P.Inherit`. Neither spawning mechanism changes in this plan; only the code path that
decides whether to spawn at all.

### The type you will borrow

`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` created
`baikai/src/Baikai/Agent.hs`, which exports:

```haskell
data AgentProvider = AgentClaude | AgentCodex

data AgentRenderError
  = UnsupportedCapability !AgentProvider !AgentCapability !Text
  | UnsupportedToolRestriction !AgentProvider !Text
  | SafetyNotExpressible !AgentProvider !Text
  | ProviderMismatch !AgentProvider !AgentProvider
  | CeilingRejected ![CeilingViolation]

renderAgentRenderError :: AgentRenderError -> Text
```

You will use `SafetyNotExpressible`, which was added for exactly this purpose: it carries a
provider and a human-readable explanation and nothing else, because the interactive safety
vocabulary has no capability profile to report.

Note that `Baikai.Agent` is **not** re-exported from the umbrella module `baikai/src/Baikai.hs` —
its field accessor names would conflict with `Baikai.Interactive`'s — so you must add an explicit
`import Baikai.Agent (AgentProvider (..), AgentRenderError (..))` to each interactive module.

There is a small vocabulary wrinkle to handle deliberately. The interactive surface identifies
providers with `Baikai.Interactive.InteractiveProvider`, whose constructors are `InteractiveClaude`
and `InteractiveCodex`; `AgentRenderError` names providers with `AgentProvider`, whose constructors
are `AgentClaude` and `AgentCodex`. Each interactive module knows statically which provider it is,
so write the `AgentProvider` constructor literally in the error value —
`SafetyNotExpressible AgentClaude "..."` in the Claude module. Do not add a conversion function
between the two provider types; there is exactly one call site per module, and a conversion
function would imply the two vocabularies are interchangeable, which is the confusion this
initiative is trying to reduce.

### Repository conventions

Every package sets `default-extensions: DeriveAnyClass, DuplicateRecordFields, OverloadedLabels,
OverloadedStrings` and `default-language: GHC2024`. Warning flags include `-Wall` and
`-Wmissing-export-lists`, with no `-Werror`, so read build output rather than trusting exit
status. Formatting is `nix fmt`, running `fourmolu` with `fourmolu.yaml`.

Tests use `tasty` with `tasty-hunit`. `baikai-claude/test/Main.hs` and
`baikai-openai/test/Main.hs` each define cases inline and list them in a root `testGroup`. The
existing `commandRenderingTest` and `effortRenderingTests` in both files call the command builders
and compare whole rendered vectors with `@?=`. **Those existing tests will stop compiling** when
you change the return type, because they compare against a bare tuple. Fixing them is part of
Milestones 2 and 3, and the fix is mechanical: wrap the expected tuple in `Right`.


## Plan of Work

Five milestones. Milestone 1 proves the bug exists. Milestones 2 and 3 fix one provider each.
Milestone 4 updates callers. Milestone 5 documents and validates.

### Milestone 1 — Prove the defect before fixing it

Scope: add two temporary test cases that demonstrate the current silent downgrade, run them, and
record what they show. At the end of this milestone you have written evidence in Surprises &
Discoveries that the bug is real.

This ordering matters. A test written after the fix proves the new code does what you just wrote.
A test written before it proves the old code did something wrong, which is what justifies a
breaking release.

In `baikai-claude/test/Main.hs`, add a case that renders a Claude command from a request whose
safety is a Codex policy, and assert the **current** behavior — that the rendered vector contains
no permission-related flag:

```haskell
silentDowngradeTest :: TestTree
silentDowngradeTest =
  testCase "PRE-FIX: Claude silently drops a Codex sandbox policy" $ do
    let req =
          interactiveLaunchRequest "inspect the repo"
            & #safety .~ CodexSandbox CodexReadOnly CodexApprovalNever
    snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)
      @?= ["--", "inspect the repo"]
```

Add the mirror case to `baikai-openai/test/Main.hs` with
`#safety .~ ClaudeAllowedTools ["Read"]`. Rather than guessing its exact expected vector, write an
obviously wrong expectation, run the test, and copy the actual value from the failure output —
that value is your evidence.

Run them:

```bash
cabal test baikai-claude-test baikai-openai-test
```

Both should pass, which is the problem. Copy the rendered vectors into Surprises & Discoveries
with a note that a caller requesting a read-only sandbox received an unrestricted session. Then
**delete these two temporary cases** at the start of Milestone 2 and replace them with the refusal
tests; do not leave a test asserting the buggy behavior in the tree. Their purpose is evidence,
and the evidence now lives in the plan.

### Milestone 2 — Refuse an inexpressible policy in the Claude launcher

Scope: change `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` so both its pure builder
and its launcher refuse a policy Claude cannot express. At the end of this milestone
`cabal build baikai-claude` and `cabal test baikai-claude-test` both succeed.

Add the import:

```haskell
import Baikai.Agent (AgentProvider (..), AgentRenderError (..))
```

Change `safetyArgs` to describe failure in its result rather than returning silently empty:

```haskell
safetyArgs :: InteractiveLaunchRequest -> Either AgentRenderError [String]
safetyArgs req = case req ^. #safety of
  DefaultSafety -> Right []
  ClaudeAllowedTools [] -> Right []
  ClaudeAllowedTools tools ->
    Right ["--allowedTools", Text.unpack (Text.intercalate "," tools)]
  CodexSandbox sandbox approval ->
    Left
      ( SafetyNotExpressible
          AgentClaude
          ( "Claude Code cannot express a Codex sandbox policy ("
              <> renderCodexSandboxMode sandbox
              <> ", "
              <> renderCodexApprovalPolicy approval
              <> "); use ClaudeAllowedTools, or DefaultSafety to accept Claude's own default"
          )
      )
```

The message names what was asked for and what to do instead. `renderCodexSandboxMode` and
`renderCodexApprovalPolicy` are already exported from `Baikai.Interactive`, so the error can quote
the caller's actual values rather than a generic complaint; add both to the module's import list
from `Baikai.Interactive`.

Keep `DefaultSafety` and the empty allow-list returning `Right []`. As recorded in the Decision
Log, `DefaultSafety` means the caller declined to specify a policy, and honoring that by rendering
nothing is correct.

Change the command builder's signature and thread the `Either` through:

```haskell
claudeInteractiveCommand ::
  ClaudeInteractiveConfig ->
  InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
claudeInteractiveCommand cfg req = do
  safety <- safetyArgs req
  pure
    ( cfg ^. #executable,
      modelArgs req
        <> effortArgs req
        <> systemPromptArgs req
        <> extraDirArgs req
        <> safety
        <> fmap Text.unpack (cfg ^. #extraArgs)
        <> fmap Text.unpack (req ^. #extraArgs)
        <> ["--", Text.unpack (req ^. #userPrompt)]
    )
```

Preserve the argument order exactly. The existing tests pin it, and reordering would turn a
mechanical test update into a behavioral change smuggled inside a bug fix.

Change the launcher so it does not spawn on refusal:

```haskell
launchClaudeInteractive ::
  ClaudeInteractiveConfig ->
  InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
launchClaudeInteractive cfg req = case claudeInteractiveCommand cfg req of
  Left err -> pure (Left err)
  Right (exe, args) -> do
    code <-
      run $
        cmd exe
          & addArgs args
          & maybe id setWorkingDir (req ^. #workingDir)
    pure (Right (interactiveLaunchResult InteractiveClaude code))
```

The `cradle` call is unchanged; only the decision to reach it is new. Note in the Haddock comment
that a `Left` result means no process was started, so a caller can distinguish "refused" from "ran
and failed" — the latter is a `Right` carrying a non-zero `ExitCode`.

The set of exported names does not change; only their types. Update the Haddock comment at the top
of the file to mention that an inexpressible safety policy is refused before launch.

Now fix the tests. Delete the temporary `silentDowngradeTest` from Milestone 1 and replace it with
a refusal test:

```haskell
safetyRefusalTest :: TestTree
safetyRefusalTest =
  testCase "refuses a Codex sandbox policy instead of launching unrestricted" $ do
    let req =
          interactiveLaunchRequest "inspect the repo"
            & #safety .~ CodexSandbox CodexReadOnly CodexApprovalNever
    case claudeInteractiveCommand defaultClaudeInteractiveConfig req of
      Right rendered -> assertFailure ("expected refusal, rendered: " <> show rendered)
      Left err -> do
        let message = renderAgentRenderError err
        assertBool "names the provider" ("Claude" `Text.isInfixOf` message)
        assertBool "names the rejected policy" ("read-only" `Text.isInfixOf` message)
        assertBool "suggests an alternative" ("ClaudeAllowedTools" `Text.isInfixOf` message)
```

Also pin the error's identity, not only its wording, by asserting the constructor: match on
`Left (SafetyNotExpressible provider _)` and assert `provider @?= AgentClaude`.

Then update the existing `commandRenderingTest`, `effortRenderingTests`, and every other case that
calls `claudeInteractiveCommand`: wrap each expected tuple in `Right`. Where a test previously
wrote `snd (claudeInteractiveCommand cfg req)`, use `fmap snd (...)` and compare against
`Right [...]`. These edits are mechanical and must not change any expected argument vector — if one
changes, you altered rendering behavior and should stop and find out why.

Add a positive test proving the allow-list path still renders, so the fix cannot be mistaken for
"refuse everything".

Verify:

```bash
cabal build baikai-claude
cabal test baikai-claude-test
```

### Milestone 3 — Refuse an inexpressible policy in the Codex launcher

Scope: the mirror-image change in `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`. At
the end of this milestone `cabal build baikai-openai` and `cabal test baikai-openai-test` both
succeed.

Apply the same shape. `safetyArgs` becomes:

```haskell
safetyArgs :: InteractiveLaunchRequest -> Either AgentRenderError [String]
safetyArgs req = case req ^. #safety of
  DefaultSafety -> Right []
  CodexSandbox sandbox approval -> Right (codexSafetyArgs sandbox approval)
  -- An empty allow-list restricts nothing, so there is nothing Codex fails to
  -- honor. Only a non-empty list is a restriction Codex cannot express.
  ClaudeAllowedTools [] -> Right []
  ClaudeAllowedTools tools ->
    Left
      ( SafetyNotExpressible
          AgentCodex
          ( "Codex has no tool allow-list flag, so it cannot honor the requested tools ("
              <> Text.intercalate ", " tools
              <> "); use CodexSandbox to restrict Codex, or DefaultSafety to accept its own \
                 \default"
          )
      )
```

`codexInteractiveCommand` gains the same `Either` return and threads `safety` through in its
existing position, preserving the order
`modelArgs <> effortArgs <> workingDirArgs <> extraDirArgs <> safety <> cfg extraArgs <> req
extraArgs <> ["--", prompt]`.

`launchCodexInteractive` becomes:

```haskell
launchCodexInteractive ::
  CodexInteractiveConfig ->
  InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
launchCodexInteractive cfg req = case codexInteractiveCommand cfg req of
  Left err -> pure (Left err)
  Right (exe, args) -> do
    let spec =
          (P.proc exe args)
            { P.std_in = P.Inherit,
              P.std_out = P.Inherit,
              P.std_err = P.Inherit,
              P.cwd = req ^. #workingDir
            }
    code <- P.withCreateProcess spec (\_ _ _ ph -> P.waitForProcess ph)
    pure (Right (interactiveLaunchResult InteractiveCodex code))
```

Add the mirror refusal test asserting the message names Codex, quotes the rejected tools, and
suggests `CodexSandbox`; add a test that an empty `ClaudeAllowedTools` list renders successfully;
and mechanically wrap the existing expected tuples in `Right`.

Verify:

```bash
cabal build baikai-openai
cabal test baikai-openai-test
```

### Milestone 4 — Update every caller in the workspace

Scope: find and fix every call site of the four changed functions. At the end of this milestone
`cabal build all` and `cabal test all` succeed.

Find them:

```bash
rg -n 'launchClaudeInteractive|launchCodexInteractive|claudeInteractiveCommand|codexInteractiveCommand' \
  --glob '!dist-newstyle' .
```

Expect hits in the two modules you just edited, the two vendor test suites, and
`baikai-smoke/test/InteractiveSmoke.hs`. Read the smoke module before editing it: the
`baikai-smoke` package is an internal, never-published test suite whose cases make real
authenticated calls when credentials or binaries are available. Update it to handle the new
`Either`, and preserve its existing gating — do not remove a `findExecutable` guard or a credential
check while adjusting types, because that would turn a type fix into an accidental live-call
change. This is the single most dangerous edit in the plan.

For any call site that only needs the rendered command, `fmap` over the `Either`. For any that
launches, match both branches and fail loudly on `Left` with the rendered message; in a test,
`assertFailure (Text.unpack (renderAgentRenderError err))` is the right shape, because a refusal in
a smoke test is a genuine failure rather than a skip.

If `rg` finds a call site outside this repository, it is not yours to fix here — record it in
Milestone 5's release note instead. The known downstream consumer is the `shinzui/seihou` project,
whose `Seihou.CLI.AgentLaunchExec` module builds interactive launch requests; it will need updating
after the release, and that is noted, not performed, by this plan.

Verify:

```bash
cabal build all
cabal test baikai-test baikai-claude-test baikai-openai-test
```

### Milestone 5 — Document, record the release consequence, and validate

Scope: explain the new behavior to users, write down precisely what the release must do, and prove
the workspace is green offline.

Edit `docs/user/interactive-launches.md`. It currently documents the launchers as returning an
`InteractiveLaunchResult`. Change those signatures and add a short section explaining that a safety
policy the chosen provider cannot express is now refused before launch; that a `Left` means no
process started; that a `Right` with a non-zero exit code means the session ran and exited
non-zero; and that `DefaultSafety` still means "use the tool's own default" and is never a refusal.
Include the two refusal messages verbatim so a user searching for the text finds the explanation.
State plainly that this is a behavior change from previous releases, in which such a policy was
silently ignored, because a user upgrading needs to know their previously "working" call may now
return `Left`.

Add bullets under `[Unreleased]` in the single root `CHANGELOG.md`, scoped to `baikai-claude` and
`baikai-openai`. Mark them clearly as breaking. This repository has one changelog for every
package; do not create per-package changelogs or dated release headings during feature work.

Record the release consequence precisely, because this is the part that is easy to get wrong. Both
provider packages change exported function types, which the Haskell Package Versioning Policy
treats as breaking, so each needs a **major** bump from its in-tree `0.4.0.0`. The core `baikai`
package is unchanged by this plan — it only gains a *use* of a type that
`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` already added — so it needs no bump
on account of this plan. Every package depending on `baikai-claude` or `baikai-openai` must have its
bounds checked. Note in the changelog and in the parent MasterPlan that the downstream
`shinzui/seihou` project must handle the new `Either` before it can upgrade. Do not hand-edit any
version or dependency bound here; the release runs separately through
`agents/skills/release/SKILL.md` and is coordinated for the whole initiative by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`.

Update the parent MasterPlan
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: set EP-3 to
`Complete`, check off its two Progress lines, and add the pre-fix evidence from Milestone 1 to its
Surprises & Discoveries section — the initiative's retrospective should be able to show what was
actually broken.

Then run the full validation in Concrete Steps.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Milestone 1, demonstrate the defect:

```bash
cabal test baikai-claude-test baikai-openai-test
```

The temporary pre-fix cases pass, which is the evidence. Record the rendered vectors.

Milestones 2 and 3, after each provider:

```bash
cabal build baikai-claude
cabal test baikai-claude-test
cabal build baikai-openai
cabal test baikai-openai-test
```

If a test fails with a type error about comparing a tuple to an `Either`, that is the expected
mechanical breakage described in Context and Orientation: wrap the expected value in `Right`.

Milestone 4, find and fix callers:

```bash
rg -n 'launchClaudeInteractive|launchCodexInteractive|claudeInteractiveCommand|codexInteractiveCommand' \
  --glob '!dist-newstyle' .
cabal build all
```

To see the refusal by hand, use the interactive interpreter. This is pure and starts no process:

```bash
cabal repl baikai-claude
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Baikai.Interactive
import Baikai.Provider.Claude.Interactive
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text.IO qualified as TIO
let bad = interactiveLaunchRequest "inspect" & #safety .~ CodexSandbox CodexReadOnly CodexApprovalNever
either (TIO.putStrLn . renderAgentRenderError) (const (putStrLn "rendered")) (claudeInteractiveCommand defaultClaudeInteractiveConfig bad)
-- expect a message containing: Claude Code cannot express a Codex sandbox policy (read-only, never)
let ok = interactiveLaunchRequest "inspect" & #safety .~ ClaudeAllowedTools ["Read", "Grep"]
fmap snd (claudeInteractiveCommand defaultClaudeInteractiveConfig ok)
-- expect: Right ["--allowedTools","Read,Grep","--","inspect"]
:quit
```

Full validation after Milestone 5. Two independent gates cause the `baikai-smoke` suite to make real
billable calls and both must be closed: provider API-key environment variables, and — as discovered
during the work recorded in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md` — the mere presence of
the `claude` or `codex` binary on `PATH`, because `baikai-smoke/test/Smoke.hs` gates its batch CLI
cases on `findExecutable` alone. This matters more than usual in this plan, because you edited
`baikai-smoke/test/InteractiveSmoke.hs`. This `zsh` command closes both gates while keeping the
active toolchain:

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

Expect no unintended formatting diff, nothing from `git diff --check`, a clean build, every suite
passing, the smoke suite reporting both binaries and all keys unavailable and skipping every live
case, and a successful flake check.

Commit with all three trailers, and mark the breaking change in the subject:

```text
fix(interactive)!: refuse safety policy a provider cannot express

Both interactive launchers silently dropped a cross-provider safety
policy and started an unrestricted session. They now return
Left SafetyNotExpressible and start no process.

BREAKING CHANGE: claudeInteractiveCommand, codexInteractiveCommand,
launchClaudeInteractive, and launchCodexInteractive now return Either
AgentRenderError. Callers must handle the refusal branch.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan is accepted when all of the following hold.

`claudeInteractiveCommand` given a request whose safety is
`CodexSandbox CodexReadOnly CodexApprovalNever` returns
`Left (SafetyNotExpressible AgentClaude msg)`, where `msg` names Claude, quotes the rejected
sandbox mode and approval policy, and suggests `ClaudeAllowedTools` or `DefaultSafety`.
`launchClaudeInteractive` given the same request returns that `Left` and starts no process.

`codexInteractiveCommand` given a request whose safety is `ClaudeAllowedTools ["Read"]` returns
`Left (SafetyNotExpressible AgentCodex msg)`, where `msg` names Codex, quotes the rejected tools,
and suggests `CodexSandbox` or `DefaultSafety`. `launchCodexInteractive` behaves correspondingly.

Every previously working combination still renders identically, wrapped in `Right`: Claude with
`ClaudeAllowedTools`, Codex with `CodexSandbox`, and either with `DefaultSafety`. An empty
`ClaudeAllowedTools` list renders successfully on both providers rather than being refused. No
expected argument vector in any pre-existing test changed.

The Surprises & Discoveries section contains the pre-fix rendered vectors demonstrating that a
caller requesting a restriction previously received an unrestricted command, and no test asserting
the buggy behavior remains in the tree.

Every call site in the workspace compiles, including `baikai-smoke/test/InteractiveSmoke.hs`, whose
existing credential and binary-availability gating is unchanged.

`docs/user/interactive-launches.md` shows the new signatures, explains that a `Left` means no
process started while a `Right` with a non-zero exit means the session ran and failed, states that
`DefaultSafety` is never a refusal, and explicitly warns that this is a behavior change from
previous releases. The root `CHANGELOG.md` records both provider changes as breaking. The parent
MasterPlan shows EP-3 complete and notes that `shinzui/seihou` must handle the new `Either` before
upgrading.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`, and
`nix flake check` all succeed. No acceptance step starts an interactive session or invokes a live
model.


## Idempotence and Recovery

The source edits are small and confined to two files plus their callers, and all commands are safe
to repeat. Nothing here contacts a provider, mutates remote state, or writes outside the repository
— provided you did not weaken the smoke suite's gating in Milestone 4, which is the one edit in
this plan that could cause a live call. Re-read that milestone's warning if you touched
`baikai-smoke/test/InteractiveSmoke.hs`.

Milestones 2 and 3 are independent: either provider can be fixed and committed alone, and the
workspace stays green as long as that provider's callers are updated in the same commit. That makes
"one provider plus its callers" the natural commit boundary if you want smaller commits than the
single commit suggested above.

To roll back, revert the commit. The reverted state is the current shipped behavior — silently
downgrading — so a rollback reintroduces the defect rather than leaving the tree broken. Note that
in the Progress section if you do it, so the next contributor knows the defect is live again.

There is one thing this plan cannot make idempotent: once the major version is published,
downstream consumers must adapt. That is why the version bump and publish are deliberately not part
of this plan and are deferred to the coordinated release in
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`.


## Interfaces and Dependencies

No new package dependencies. Both vendor packages already depend on `baikai`, which is where
`Baikai.Agent` lives; you add an `import` of a module that already ships in a package already
depended upon. `cradle` remains the Claude launcher's spawning mechanism and `process` remains the
Codex launcher's; neither changes.

Signatures at completion:

```haskell
-- baikai-claude/src/Baikai/Provider/Claude/Interactive.hs
claudeInteractiveCommand ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
launchClaudeInteractive ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)

-- baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs
codexInteractiveCommand ::
  CodexInteractiveConfig -> InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
launchCodexInteractive ::
  CodexInteractiveConfig -> InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
```

The set of exported names is unchanged in both modules; only these four types change.
`ClaudeInteractiveConfig`, `CodexInteractiveConfig`, their accessors, the two default configuration
values, and `codexInteractivePrompt` are untouched.

`baikai/src/Baikai/Interactive.hs` is **not** modified by this plan. `InteractiveSafety`,
`CodexSandboxMode`, `CodexApprovalPolicy`, `InteractiveLaunchRequest`, `InteractiveLaunchResult`,
and every renderer keep their current shape. The Decision Log explains why unifying
`InteractiveSafety` with the unattended `AgentSafety` is out of scope and undesired.

The refusal behavior table, which the user guide documents:

```text
request safety                   Claude launcher            Codex launcher
DefaultSafety                    Right, no safety flags     Right, no safety flags
ClaudeAllowedTools []            Right, no safety flags     Right, no safety flags
ClaudeAllowedTools ["Read"]      Right, --allowedTools      Left SafetyNotExpressible
CodexSandbox mode approval       Left SafetyNotExpressible  Right, --sandbox/--ask-for-approval
```

Downstream impact: `baikai-claude` and `baikai-openai` each need a PVP-major release from
`0.4.0.0`. `baikai` needs no bump on account of this plan. Any package depending on either provider
package must have its bounds updated by the coordinated release, and the external `shinzui/seihou`
project must handle the new `Either` in its interactive launch call site before it can upgrade.
