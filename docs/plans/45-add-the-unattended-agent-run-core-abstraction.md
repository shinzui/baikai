---
id: 45
slug: add-the-unattended-agent-run-core-abstraction
title: "Add the unattended agent-run core abstraction"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Add the unattended agent-run core abstraction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Baikai is a Haskell library that hides the differences between AI providers behind one
interface. Today it can do two things with a local coding-agent command-line tool such as
Claude Code (the `claude` binary) or Codex (the `codex` binary). It can run one as a
**batch completion**, meaning it shells out to `claude -p` or `codex exec`, waits, and turns
the output into a normal Baikai response value. And it can perform an **interactive
launch**, meaning it hands the user's terminal to the tool and waits for the human to quit.

There is a third thing automation needs that Baikai cannot currently express: an
**unattended coding-agent run**. That means starting the coding agent with no human present
and no terminal, letting it run its own internal loop of reading and editing files, allowing
it to change files inside directories the caller explicitly authorized, and then collecting
a process result — an exit status, optionally captured output, and how long it took. It is
not a completion, because the interesting output is the changed files rather than the text.
It is not an interactive launch, because nobody is watching.

This plan adds the shared vocabulary for that third thing, and nothing else. After this plan
a Haskell programmer can build a value describing an unattended run — which provider, what
prompt, which working directory, which extra directories, what safety policy, what timeout,
whether output is captured — and can ask a pure function whether that request is permitted
by a policy limit. No process is spawned by any code in this plan. Spawning arrives in
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`, and
translating a request into actual command-line flags arrives in
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md`.

The part of this plan that matters most is the **policy ceiling**. A repository can contain a
file describing a job to run. If an automated system encounters a repository it did not
write, that file is untrusted input: it could ask for unlimited filesystem access. A ceiling
is a separate limit, owned by the person running the automation, that bounds what any job may
ask for. This plan makes the ceiling a pure value and the check a pure function, so it can be
tested exhaustively before any subprocess exists anywhere in the codebase.

**The observable outcome**, verifiable by running one test command and reading its output:
after this plan, `cabal test baikai-test` passes with a new `Baikai.Agent` test group in
which a request asking for full filesystem access is refused by the default ceiling with a
structured error naming the requested value and the permitted maximum, while the same
request asking only for permission to edit its own working directory is accepted unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (2026-08-05): Create `baikai/src/Baikai/Agent.hs` with provider identity,
      capability profile, safety request, request record, output discipline, rendered-command
      type, and result record; register the module in `baikai/baikai.cabal`.
      `cabal build baikai` succeeds with no warnings.
- [x] Milestone 2 (2026-08-05): Add the policy ceiling, the `CeilingViolation` type, and the
      pure `applyAgentCeiling` function that refuses rather than clamps.
      `cabal build baikai` succeeds with no warnings.
- [x] Milestone 3 (2026-08-05): Add the render-error and run-failure taxonomies.
      `cabal build baikai` succeeds with no warnings.
- [x] Milestone 4 (2026-08-05): Add `baikai/test/AgentSpec.hs` covering defaults, every
      capability and ceiling pair, every refusal, and every canonical rendering; register it in
      `baikai/baikai.cabal` and `baikai/test/Main.hs`. `cabal test baikai-test` reports
      `All 168 tests passed`, with eleven cases in the new `Baikai.Agent` group.
- [x] Milestone 5 (2026-08-05): Document the new surface in
      `docs/user/interactive-launches.md`, add the `README.md` highlight bullet and the
      `baikai`-scoped `[Unreleased]` changelog bullets, and run the full offline validation.
      `nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed
      `cabal test all`, and `nix flake check` all succeed; the smoke suite reports
      `no provider keys or CLI binaries available; skipping all cases`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-08-05): a field name shared by two records in the same module cannot be
  exported as a bare name at all, not even once. The plan assumed the conflict was only
  between `AgentRunRequest` and `AgentRunResult` accessors both being exported; in fact GHC
  9.12.4 rejects the export item itself. Reduced to a two-record file:

  ```text
  Dup.hs:2:18: error: [GHC-87543]
      Ambiguous occurrence ‘provider’.
      It could refer to
         either the field ‘provider’ of record ‘Req’,
             or the field ‘provider’ of record ‘Res’,
  ```

  Consequence: `Baikai.Agent` exports the accessors of its abstract records through the
  subordinate-name form, `AgentRunRequest (provider, prompt, …)`. That form exports the
  selectors without exporting the data constructor, so the abstract-record property the plan
  requires is preserved and downstream record-update syntax still works — verified with a
  two-module scratch build before writing the module. See the Decision Log entry.


## Decision Log

Record every decision made while working on the plan.

- Decision: Do **not** add `Baikai.Agent` to the export list of the umbrella module
  `baikai/src/Baikai.hs`.
  Rationale: `baikai/src/Baikai.hs` re-exports `module Baikai.Interactive`, and
  `Baikai.Interactive` exports bare field accessors named `modelId`, `workingDir`,
  `extraDirs`, `safety`, `extraArgs`, and `effort`. `Baikai.Agent` needs accessors with
  several of the same names. Re-exporting both modules from one umbrella module makes GHC
  report a conflicting-exports error, because these are genuinely different functions that
  happen to share a name. The precedent already exists in this repository:
  `Baikai.Provider.Cli.Internal` is an exposed module that the umbrella deliberately does not
  re-export. Consumers write `import Baikai.Agent` or
  `import Baikai.Agent qualified as Agent`.
  Date: 2026-07-30

- Decision: `Baikai.Agent` defines new safety vocabulary rather than reusing
  `Baikai.Interactive.InteractiveSafety`.
  Rationale: `InteractiveSafety` is `DefaultSafety | ClaudeAllowedTools [Text] |
  CodexSandbox CodexSandboxMode CodexApprovalPolicy`. It cannot express Claude Code's
  `--permission-mode` at all, and the first consumer of this initiative needs
  `--permission-mode acceptEdits` together with a tool allow-list. It also carries an
  approval policy, which the unattended Codex path cannot use because `codex exec` has no
  approval flag. Rather than widening a published type with fields that are meaningless on
  one of its two surfaces, the two surfaces share the *refusal* type and keep separate policy
  types. A future contributor tempted to unify them should read this entry first.
  Date: 2026-07-30

- Decision: `envPassthrough` is a list of variable **names the job declares it requires**, not
  name/value pairs and not an allow-list that restricts the child's environment.
  Rationale: the improvement request requires environment-variable references without embedding
  secret values in configuration, and a list of names cannot contain a secret by construction —
  a stronger guarantee than redacting values after the fact. The child process inherits the
  parent's full environment, because both coding-agent tools need `HOME`, `PATH`, and their own
  credential files to function; restricting the child to an allow-list would break their
  authentication and is deliberately out of scope for a first version. What the list buys is a
  precondition check: the runner in
  `docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` fails with
  `MissingEnvironment` naming every declared variable that is unset or empty, so a misconfigured
  job produces one clear error instead of a coding agent that starts and then flails. Give the
  field a Haddock comment saying exactly this, because "passthrough" could otherwise be read as
  "only these".
  Date: 2026-07-30

- Decision: `workingDir` is a required `FilePath`, not a `Maybe FilePath`, even though
  `Baikai.Interactive.InteractiveLaunchRequest` makes it optional.
  Rationale: the safety contract is that a run gets no filesystem authority beyond its
  working directory and its explicit extra directories. If the working directory can be
  absent, that sentence has no meaning and the effective authority silently becomes
  "wherever the parent process happened to be". An unattended run must state its root.
  Date: 2026-07-30

- Decision: Capture the result's standard output and standard error as an explicit
  three-state value rather than as a plain byte string.
  Rationale: the improvement request's illustrative result record has
  `stdout :: ByteString`, but the same request also allows output to be *inherited*, in which
  case the bytes went to the parent's terminal and no bytes exist to report. An empty byte
  string would be indistinguishable from a command that legitimately printed nothing. The
  three states are: not captured, captured in full, and captured but truncated at the byte
  limit.
  Date: 2026-07-30


- Decision (2026-08-05): export the accessors of `AgentRunRequest`, `AgentSafety`, and
  `AgentCeiling` using the subordinate-name export form — `AgentRunRequest (provider, prompt,
  …)` — rather than as bare top-level names as the plan's Interfaces section described.
  Rationale: GHC rejects a bare export of a field name that two records in the same module
  define, so `provider` could not be exported bare in any case (see Surprises &
  Discoveries). The subordinate form exports the selectors while still hiding the data
  constructor, which is the property the plan actually depends on: a later plan can add a
  defaulted field without breaking callers who use the smart constructor plus record-update
  syntax. All three abstract records use the same form for consistency, so a future record
  that happens to introduce a duplicate field name does not force a second style.
  Consumers see no difference: `import Baikai.Agent` brings the same names into scope.
  Date: 2026-08-05

- Decision (2026-08-05): the unattended failure taxonomies do not reuse
  `baikai/src/Baikai/Error.hs`.
  Rationale: `BaikaiError` is built around an `ErrorCategory` oriented to HTTP-shaped provider
  failures — authentication, rate limiting, context overflow — and it is what
  `completeRequest` returns. An unattended run is not a completion, and most of those
  categories cannot occur on it, so reporting through that type would force every caller to
  handle variants that are unreachable while saying nothing about the failures that actually
  happen: a refused policy, a failed spawn, a timeout, a missing precondition. The two new
  types are also split along the line that matters operationally — `AgentRenderError` means
  nothing was started, `AgentRunFailure` means something was.
  Date: 2026-08-05

- Decision (2026-08-05): register `AgentSpec` immediately **after** `AgentAssetsSpec` in
  `baikai/baikai.cabal`, `baikai/test/Main.hs`'s imports, and its root test group, not before
  it as Milestone 4 instructed.
  Rationale: the instruction to keep those lists alphabetical is the governing one, and
  `AgentAssetsSpec` sorts before `AgentSpec` because `A` precedes `S` at the seventh
  character. Placing it first would have broken the ordering the surrounding lists follow.
  Date: 2026-08-05

- Decision (2026-08-05): the tests build `AgentSafety` and `AgentCeiling` values with their
  smart constructor plus `generic-lens` field updates rather than with record syntax as
  Milestone 4's prose implied.
  Rationale: both records are exported abstractly, so their data constructors are not in
  scope in the test module — which is the property the plan asked for. Writing the tests
  through the public surface is also a better test: it exercises exactly what a downstream
  caller can do.
  Date: 2026-08-05

- Decision (2026-08-05): do not create `docs/adr/` as part of this plan.
  Rationale: this repository has no ADR corpus at all — there is no `docs/adr/` directory and
  `mori.dhall` declares exactly one OKF bundle, `improvement-requests` at
  `docs/improvement-requests`, with no bundle whose path is `docs/adr`.
  `agents/skills/exec-plan/ADR.md` says to preserve the repository's established filesystem
  convention when no profiled bundle exists and not to invent OKF frontmatter or Mori identity
  as an incidental plan edit; adopting a corpus is separate work through the
  `adopt-architecture-decisions` Seihou blueprint. Establishing the repository's first ADR
  bundle inside a wave-one child plan would be exactly that incidental structural change.
  The durable decisions this plan settled — core stays pure, the ceiling refuses rather than
  clamps, the two policy types stay separate, the failure taxonomies do not reuse
  `Baikai.Error` — are recorded in this plan's Decision Log and in the parent MasterPlan's,
  and the parent's completion pass is where they should be promoted if the corpus is adopted.
  Date: 2026-08-05

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-08-05): complete, and it matches the stated purpose. `baikai/src/Baikai/Agent.hs`
exists with every name and signature the Interfaces and Dependencies section promised, so the
five downstream plans can be written against it without reinterpretation. The observable
outcome the Purpose section named is real: `cabal test baikai-test` reports
`All 168 tests passed`, and inside it the `Baikai.Agent` group demonstrates that a request
asking for `AgentFullAccess` is refused by `defaultAgentCeiling` with exactly
`[CapabilityExceeded AgentFullAccess AgentEditWorkspace]` while the same request asking for
`AgentEditWorkspace` comes back equal to its input value. Eleven test cases were written where
the plan sketched ten; the extra one splits the raw-provider-argument channel into its own
case, since it is the only field whose acceptance depends on an operator flag rather than on an
ordering comparison.

No dependency was added, and `baikai` still depends on none of `process`, `directory`, or
`filepath`. No existing module changed, and every pre-existing test passes unchanged.

Gaps, all of them deliberate and none of them blocking a downstream plan. Nothing renders a
flag or spawns a process yet, so the `AgentCommand` prompt-transport contract is documented
and typed but not yet exercised by a real renderer — EP-2 and EP-4 are where it earns its
keep. `AgentRenderError`'s `SafetyNotExpressible` constructor is exported and rendered but
unused in tree until `docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`
consumes it; that is by design and the constructor must not be pruned as dead code.
`docs/user/unattended-agent-runs.md` does not exist yet and is EP-6's to write; this plan
added the third-surface section to `docs/user/interactive-launches.md` instead, as scoped.

Lessons worth carrying forward. First, the export shape cost more care than the code: a field
name shared by two records in one module cannot be exported bare at all, so the abstract
records use the subordinate-name form. Any later plan adding a record to `Baikai.Agent` whose
field names collide with an existing one must use the same form rather than reaching for a type
prefix, which repository convention forbids. Second, deriving `Ord` on `AgentCapability` in
ascending authority order is load-bearing security logic, not a convenience — a reordering
would silently invert the ceiling check, and the multiple-violation and refusal tests are what
would catch it. Third, the plan's own instruction to sort `AgentSpec` before `AgentAssetsSpec`
was wrong; where a plan's specific instruction contradicts the rule it cites, the rule wins.


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this
repository.

Baikai is a multi-package Cabal workspace. Cabal is the Haskell build tool; a "package" is a
directory with a `.cabal` file describing what to build. The packages that exist today are
listed in `cabal.project` at the repository root. This plan edits exactly one package,
`baikai`, whose source lives under `baikai/src/` and whose tests live under `baikai/test/`.

The `baikai` package is the **core** package. Its rule is that it owns provider-neutral
vocabulary and never talks to a specific vendor or spawns a process. You can verify this from
`baikai/baikai.cabal`: its `build-depends` list contains `aeson`, `base`,
`base64-bytestring`, `bytestring`, `containers`, `generic-lens`, `lens`, `openai`,
`scientific`, `streamly`, `streamly-core`, `text`, `time`, `unliftio-core`, and `vector`. It
does **not** contain `process`, `directory`, or `filepath`. This plan must not add any
dependency. Everything it introduces is a data type or a pure function.

### The existing pattern this plan copies

`baikai/src/Baikai/Interactive.hs` is the closest existing model and you should read it
before writing any code. It defines the provider-neutral vocabulary for interactive launches
and deliberately implements no process spawning; a comment at the top of the file says so.
Its structure is the template for this plan:

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

interactiveLaunchRequest :: Text -> InteractiveLaunchRequest
interactiveLaunchRequest prompt = InteractiveLaunchRequest
  { systemPrompt = Nothing, userPrompt = prompt, modelId = Nothing,
    workingDir = Nothing, extraDirs = [], safety = DefaultSafety,
    extraArgs = [], effort = Nothing }
```

Three details of that pattern are load-bearing and this plan must reproduce all three.

First, the module exports the **type without its data constructor** and exports each field
accessor by name, plus a smart constructor that fills in defaults. Look at the export list at
the top of `Baikai/Interactive.hs`: it lists `InteractiveLaunchRequest` (no `(..)`) and then
`systemPrompt`, `userPrompt`, `modelId`, and so on as separate entries. This is intentional
and is explained in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md`: hiding the
constructor while exporting a base value plus accessors means a later plan can add a
defaulted field without breaking any caller who built a value with the smart constructor and
then used record-update syntax. Adding a field to an exported *constructor* would be a
breaking change; adding one here is not.

Second, `deriving stock (Eq, Show, Generic)` is required. `Generic` is what makes the
`generic-lens` library able to write `request ^. #workingDir`, using the field name as a
type-level label. Every module in this repository reads fields that way rather than by
importing the selector. You can see it in
`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`, which does `req ^. #modelId`
without importing `modelId`.

Third, every field is marked strict with `!`. Follow that.

### Repository conventions you must follow

The project prelude is `baikai/src/Baikai/Prelude.hs`. It re-exports the whole of
`Control.Lens`, the `generic-lens` vocabulary, `MonadIO`, the types `Text`, `Vector`, and
`Natural`, the `Generic` class, and the aeson JSON classes. Most core modules begin with
`import Baikai.Prelude`. Note that `Baikai.Prelude` does **not** re-export `ThinkingLevel`;
`Baikai/Interactive.hs` imports it explicitly with
`import Baikai.ThinkingLevel (ThinkingLevel)`. Do the same.

Every field name in this repository is written without a type prefix. There is no
`agentRunProvider` or `arrProvider`; the field is simply `provider`. The GHC extensions
`DuplicateRecordFields` and `OverloadedLabels` are switched on for every package in the
`default-extensions` stanza of each `.cabal` file, which is what makes unprefixed names
across different records legal. This applies to internal helper records too, not only public
ones.

Warnings matter. Each package sets `-Wall -Wcompat -Widentities
-Wincomplete-uni-patterns -Wincomplete-record-updates -Wredundant-constraints
-fhide-source-paths -Wmissing-export-lists -Wpartial-fields
-Wmissing-deriving-strategies`. Two of those will bite you if you are careless.
`-Wmissing-export-lists` means every module needs an explicit export list.
`-Wall` includes `-Wincomplete-patterns`, so every `case` on a closed set of constructors
must handle all of them — which is exactly the property this plan wants for safety mappings.
The packages do not set `-Werror`, so a warning will not fail the build; you must read the
build output.

Formatting is checked by `nix fmt`, which runs `fourmolu` using the settings in
`fourmolu.yaml`. Run it before finishing.

### How tests are organized

`baikai/test/Main.hs` is the entry point. It imports each spec module qualified, for example
`import InteractiveSpec qualified`, and lists `InteractiveSpec.tests` inside a
`testGroup "baikai" [...]`. Each spec module exports exactly one value named `tests` of type
`TestTree`. The test framework is `tasty` with `tasty-hunit`; assertions use `@?=` which
compares expected and actual, and `assertBool`.

`baikai/test/InteractiveSpec.hs` is a short, complete example worth copying in structure. It
has four test cases: one asserting every default field of the smart constructor, one
asserting canonical string renderings, one asserting safety-value renderings, and one
asserting the result constructor.

A new test module needs **three** registrations, and missing the third is a common mistake
recorded in `docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md`:
create the file, add it to the `other-modules` list of the `baikai-test` stanza in
`baikai/baikai.cabal`, and import plus list it in `baikai/test/Main.hs`.

### Verified facts about the two coding-agent tools

You do not need these facts to write this plan's code, because this plan renders no flags.
They are recorded here because they justify the shape of the types, and a later reader will
want to know why the vocabulary looks the way it does. All were checked against the tools
installed on the machine where this plan was written: Claude Code version 2.1.220 and
`codex-cli` version 0.146.0.

Claude Code's `--permission-mode` flag accepts six values: `acceptEdits`, `auto`,
`bypassPermissions`, `manual`, `dontAsk`, and `plan`. Its `--allowedTools` flag accepts a
comma- or space-separated list of tool names. Its `--add-dir` flag is documented as
"additional directories to allow tool access to".

`codex exec` accepts `-s`/`--sandbox` with the three values `read-only`, `workspace-write`,
and `danger-full-access`; `-C`/`--cd` to set the working root; `--add-dir`, documented as
"additional directories that should be writable alongside the primary workspace"; and
`--dangerously-bypass-approvals-and-sandbox`. It has **no** approval-policy flag — `codex`
has `-a`/`--ask-for-approval` but only on the interactive top-level command, not on `exec`.
This is why the shared vocabulary in this plan has no approval field.

Both tools can read the prompt from standard input. `codex exec` documents that if standard
input is piped and a positional prompt is also supplied, standard input is appended as a
`<stdin>` block — so a renderer must never supply both. This is why the rendered-command
type in this plan carries the prompt transport as an explicit choice rather than leaving it
to convention.

The two `--add-dir` flags do not mean the same thing: Claude grants tool access, Codex grants
write access. The shared `extraDirs` field therefore means "directories this run may reach
beyond its working directory", and the precise authority is provider-dependent. Say so in the
Haddock comment on the field.


## Plan of Work

Five milestones. Milestones 1 through 3 build up one new module and are verifiable by
compiling. Milestone 4 adds the tests that make the behavior observable. Milestone 5
documents and validates.

### Milestone 1 — The vocabulary module

Scope: create `baikai/src/Baikai/Agent.hs` containing provider identity, the capability
profile, the safety request, the request record, the output discipline, the rendered-command
type, and the result record. At the end of this milestone `cabal build baikai` succeeds and
the new module is part of the library.

Create the file with a module header explaining, in the same voice as
`baikai/src/Baikai/Interactive.hs`, that this module owns provider-neutral vocabulary for
unattended coding-agent runs, that it deliberately implements no process spawning, and that
vendor packages own the translation into command-line flags. Import `Baikai.Prelude`, import
`Baikai.ThinkingLevel (ThinkingLevel)` explicitly, import `System.Exit (ExitCode)`, and
import `Data.ByteString (ByteString)` and `Data.Time.Clock (NominalDiffTime)`. All of
`bytestring` and `time` are already dependencies of the package.

Define provider identity as a closed two-value set with a canonical renderer and a parser.
The parser exists because the configuration layer in
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` must turn
the string `"claude"` from a configuration file into this type, and the round trip belongs
next to the type rather than in the configuration package:

```haskell
data AgentProvider
  = AgentClaude
  | AgentCodex
  deriving stock (Eq, Ord, Show, Generic)

renderAgentProvider :: AgentProvider -> Text
parseAgentProvider :: Text -> Maybe AgentProvider
```

Render `AgentClaude` as `"claude"` and `AgentCodex` as `"codex"`, matching
`renderInteractiveProvider` in `Baikai/Interactive.hs` so the two surfaces name the same
tools identically.

Define the capability profile. This is the shared, provider-neutral answer to "how much
authority does this run get". Keep it to three values. Derive `Ord` with the constructors in
ascending order of authority, because the ceiling check in Milestone 2 is an ordering
comparison and getting the declaration order wrong would invert the security check:

```haskell
data AgentCapability
  = AgentReadOnly
  | AgentEditWorkspace
  | AgentFullAccess
  deriving stock (Eq, Ord, Show, Generic)

renderAgentCapability :: AgentCapability -> Text
parseAgentCapability :: Text -> Maybe AgentCapability
```

Render them as `"read-only"`, `"edit-workspace"`, and `"full-access"`. Document each in a
Haddock comment: `AgentReadOnly` means the run may read but must not modify anything;
`AgentEditWorkspace` means it may modify files inside the working directory and the explicit
extra directories and nowhere else; `AgentFullAccess` means no sandbox at all, which is why
the ceiling refuses it by default.

Define the safety request — what a job asks for, as opposed to what it is permitted:

```haskell
data AgentSafety = AgentSafety
  { capability :: !AgentCapability,
    allowedTools :: ![Text],
    providerArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

agentSafety :: AgentCapability -> AgentSafety
```

`allowedTools` is an optional narrowing: an empty list means "do not restrict tools beyond
what the capability implies", and a non-empty list is rendered where the provider supports a
tool allow-list. `providerArgs` is the deliberate escape hatch for flags Baikai does not
model; it is the field the ceiling gates, because arbitrary flags can widen authority in ways
no capability profile can see. `agentSafety` builds a value with the given capability, no
tool narrowing, and no raw arguments.

Define the output discipline. Three modes, matching what the improvement request asks for:

```haskell
data AgentOutputMode
  = InheritOutput
  | CaptureOutput
  | TeeOutput
  deriving stock (Eq, Ord, Show, Generic)

renderAgentOutputMode :: AgentOutputMode -> Text
parseAgentOutputMode :: Text -> Maybe AgentOutputMode
```

`InheritOutput` means the child writes straight to the parent's own output streams and Baikai
captures nothing, which is what the first consumer wants because its log is the terminal.
`CaptureOutput` means Baikai collects the bytes and the parent sees nothing.
`TeeOutput` means both. Render as `"inherit"`, `"capture"`, and `"tee"`.

Define the captured-output value with the three states from the Decision Log:

```haskell
data AgentCapturedOutput
  = OutputNotCaptured
  | OutputCaptured !ByteString
  | OutputTruncated !ByteString
  deriving stock (Eq, Show, Generic)
```

`OutputTruncated` carries the bytes kept up to the limit and records that more existed.
Provide a helper `capturedBytes :: AgentCapturedOutput -> Maybe ByteString` returning
`Nothing` for `OutputNotCaptured`, so a caller that just wants the text does not have to
match three constructors.

Define the request. This is the plan's central type:

```haskell
data AgentRunRequest = AgentRunRequest
  { provider :: !AgentProvider,
    prompt :: !Text,
    modelId :: !(Maybe Text),
    effort :: !(Maybe ThinkingLevel),
    workingDir :: !FilePath,
    extraDirs :: ![FilePath],
    safety :: !AgentSafety,
    timeout :: !(Maybe NominalDiffTime),
    output :: !AgentOutputMode,
    outputLimit :: !(Maybe Int),
    envPassthrough :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest
```

The smart constructor takes the three values that have no safe default — which provider,
which working directory, and the prompt — and defaults the rest: no model override, no
effort override, no extra directories, `agentSafety AgentReadOnly`, no timeout,
`InheritOutput`, no output limit, and no forwarded environment variables.

Default the capability to `AgentReadOnly`, not to `AgentEditWorkspace`. A caller who wants to
change files must say so. This is the least-authority default required by the improvement
request's first safety requirement, and it is independent of the *ceiling* default, which is
a different thing decided in Milestone 2: the ceiling says what a caller is allowed to ask
for, the request default says what they get if they ask for nothing.

Give `outputLimit` a Haddock comment stating that it counts bytes per stream, not total, and
that `Nothing` means unbounded.

Define the rendered command. This is the boundary type between the vendor renderers and the
process runner, and it lives here so that neither side needs to depend on the other:

```haskell
data AgentPromptTransport
  = PromptOnStdin
  | PromptAsArgument
  deriving stock (Eq, Ord, Show, Generic)

data AgentCommand = AgentCommand
  { executable :: !FilePath,
    arguments :: ![String],
    promptTransport :: !AgentPromptTransport,
    promptText :: !Text
  }
  deriving stock (Eq, Show, Generic)
```

Export `AgentCommand (..)` and `AgentPromptTransport (..)` with their constructors, unlike
the request and result: this is a plain rendered value that both sides construct and pattern
match, and hiding its constructor would force pointless accessors. Document that when
`promptTransport` is `PromptOnStdin` the prompt is **not** present anywhere in `arguments`
and the runner must write `promptText` to the child's standard input, and that when it is
`PromptAsArgument` the prompt is already the final element of `arguments`, protected by the
provider's `--` separator, and the runner must supply no standard input at all. This is the
type-level guard against the Codex `<stdin>`-block trap described in Context and Orientation.

`AgentCommand` deliberately does **not** carry the working directory, and this omission is a
design decision rather than an oversight. Claude Code has no working-directory flag at all —
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs` sets it on the child process with cradle's
`setWorkingDir` rather than in the argument vector — so for one of the two providers the
working directory can only ever be a process-level setting. Codex does have `-C`/`--cd` and
its renderer will emit it, but the child's actual working directory must be set for both
providers regardless. The runner in
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` therefore
takes both values, with the signature
`runAgentCommand :: AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)`:
the request remains the single source of truth for every process-level setting — working
directory, timeout, output discipline, output limit, and forwarded environment variables —
while `AgentCommand` is purely the rendered argument vector plus prompt transport. Duplicating
those fields into `AgentCommand` was considered and rejected because two copies of a working
directory can disagree, and the disagreement would be a sandbox escape rather than a cosmetic
bug. Record this reasoning in a Haddock comment on `AgentCommand`.

Define the result:

```haskell
data AgentRunResult = AgentRunResult
  { provider :: !AgentProvider,
    exitCode :: !ExitCode,
    stdout :: !AgentCapturedOutput,
    stderr :: !AgentCapturedOutput,
    duration :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

agentRunResult :: AgentProvider -> ExitCode -> NominalDiffTime -> AgentRunResult
```

The smart constructor fills both output fields with `OutputNotCaptured`.

Now write the export list, and be careful here because this is where the build most easily
breaks. Export `AgentRunRequest` abstractly — the type name with no `(..)` — followed by each
of its field accessors by name, exactly as `Baikai/Interactive.hs` does, because callers need
those names in scope to use record-update syntax. Export `AgentSafety` and `AgentCeiling`
(added in Milestone 2) the same way. Export `AgentRunResult` abstractly **without** bare
field accessors: it is a value callers read rather than build, reading is done with
`result ^. #provider` through `generic-lens`, and exporting a bare `provider` accessor for
both the request and the result would be a conflicting export because they are two different
functions with one name. Export the small closed enumerations with `(..)`.

Verify at the end of this milestone:

```bash
cabal build baikai
```

Add `Baikai.Agent` to the `exposed-modules` list in the `library` stanza of
`baikai/baikai.cabal` first, keeping the list alphabetical — it goes immediately after
`Baikai.AgentAssets`. Do not add `Baikai.Agent` to `baikai/src/Baikai.hs`; the Decision Log
explains why, and doing so produces a conflicting-exports error.

### Milestone 2 — The policy ceiling and its enforcement

Scope: add the ceiling type, the violation type, and the pure function that checks a request
against a ceiling. At the end of this milestone the security core of the whole initiative
exists as a pure function with no dependencies on anything unbuilt.

A ceiling is the limit an operator places on what any job may request. Add to
`baikai/src/Baikai/Agent.hs`:

```haskell
data AgentCeiling = AgentCeiling
  { maxCapability :: !AgentCapability,
    allowProviderArgs :: !Bool,
    allowedProviders :: ![AgentProvider]
  }
  deriving stock (Eq, Show, Generic)

defaultAgentCeiling :: AgentCeiling
defaultAgentCeiling =
  AgentCeiling
    { maxCapability = AgentEditWorkspace,
      allowProviderArgs = False,
      allowedProviders = [AgentClaude, AgentCodex]
    }
```

That default is a decision taken at the MasterPlan level and you must not change it while
implementing: with no operator policy file present, a job may ask for read-only or
edit-workspace authority, may not ask for full access, and may not pass raw provider
arguments. The reasoning is recorded in the Decision Log of
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`; briefly, an
edit-capable default is the only one under which the first consumer works on a fresh machine,
while the two things that can widen authority without bound — sandbox-bypassing modes and
arbitrary flags — stay opt-in.

An empty `allowedProviders` list means no provider is permitted, not "all providers". Say so
in the Haddock comment, because the opposite reading is a plausible and dangerous mistake.

Now the violation type. It must carry enough to print a message a human can act on: which
field was at fault, what was asked for, and what was permitted.

```haskell
data CeilingViolation
  = CapabilityExceeded !AgentCapability !AgentCapability
  | ProviderArgsForbidden ![Text]
  | ProviderForbidden !AgentProvider ![AgentProvider]
  deriving stock (Eq, Show, Generic)

renderCeilingViolation :: CeilingViolation -> Text
```

For `CapabilityExceeded` the first field is what was requested and the second is the
permitted maximum; document that order in a comment, because a reversed pair here produces a
message that blames the wrong side. `renderCeilingViolation` produces one line of plain
English, for example:

```text
requested capability full-access exceeds the permitted maximum edit-workspace
raw provider arguments are not permitted: --dangerously-skip-permissions
provider codex is not permitted; permitted providers: claude
```

Then the enforcement function:

```haskell
applyAgentCeiling :: AgentCeiling -> AgentRunRequest -> Either [CeilingViolation] AgentRunRequest
```

It returns the request **unchanged** on success and the complete list of violations on
failure. Two properties are essential and both must be tested in Milestone 4. It never
modifies the request to fit the ceiling — no clamping, ever; a job that asked for more than
it may have is an error to report, not a request to quietly weaken. And it collects *all*
violations rather than stopping at the first, so an operator fixing a configuration file sees
every problem in one run instead of rediscovering them one at a time.

Check three things in order: that `request ^. #provider` is an element of
`ceiling ^. #allowedProviders`; that the requested capability is less than or equal to
`maxCapability`, which is a plain `<=` comparison and is why the `Ord` derivation order in
Milestone 1 matters; and that if `providerArgs` is non-empty then `allowProviderArgs` is
`True`. Return `Right request` when the violation list is empty.

Note deliberately what this function does *not* do. It does not inspect the contents of
`providerArgs` looking for dangerous flags. Trying to decide whether an arbitrary vendor flag
weakens a sandbox is a losing game — flag spellings change, and a denylist that misses one
provides false confidence. The design instead treats the entire raw-argument channel as
privileged and requires an operator to open it. Put that reasoning in a Haddock comment on
`providerArgs` so nobody later adds a well-meaning substring check and believes it is a
security boundary.

Verify with `cabal build baikai`.

### Milestone 3 — The failure taxonomies

Scope: add the two error types that let callers distinguish the five failure kinds the
improvement request enumerates. At the end of this milestone the vocabulary is complete.

There are two distinct failure categories and conflating them is the mistake to avoid. A
**render error** happens before anything is spawned: the requested policy cannot be expressed
for the chosen provider, so the run must be refused. A **run failure** happens while
spawning or waiting. A non-zero exit code is neither of those — it is a perfectly normal
result and lives in `AgentRunResult`, because a coding agent that fails its task and exits 1
has still run.

```haskell
data AgentRenderError
  = UnsupportedCapability !AgentProvider !AgentCapability !Text
  | UnsupportedToolRestriction !AgentProvider !Text
  | SafetyNotExpressible !AgentProvider !Text
  | ProviderMismatch !AgentProvider !AgentProvider
  | CeilingRejected ![CeilingViolation]
  deriving stock (Eq, Show, Generic)

renderAgentRenderError :: AgentRenderError -> Text

data AgentRunFailure
  = SpawnFailed !FilePath !Text
  | RunTimedOut !NominalDiffTime
  | MissingEnvironment ![Text]
  | WorkingDirMissing !FilePath
  | OutputMalformed !Text
  deriving stock (Eq, Show, Generic)

renderAgentRunFailure :: AgentRunFailure -> Text
```

The `Text` field on `UnsupportedCapability` and `UnsupportedToolRestriction` is a
human-readable explanation supplied by the vendor renderer, such as "codex exec has no
approval-policy flag". Requiring it means a refusal always tells the operator *why*, which is
the difference between a usable error and a dead end. `SpawnFailed` carries the executable
path that could not be started plus the operating system's message, which is what
distinguishes "the tool is not installed" from "the tool is installed but the working
directory does not exist".

`ProviderMismatch` exists because each vendor renderer is a separate function in a separate
package, so nothing in the type system stops a caller from handing a request whose `provider`
field says `AgentCodex` to the Claude renderer. The first field is the provider the renderer
implements and the second is the provider the request named. Without this constructor the
Claude renderer's only options would be to silently render Claude flags for a request that
asked for Codex, or to throw — and the first is exactly the class of silent mismatch this
initiative exists to eliminate. Document the field order, because a reversed pair produces a
message that names the wrong culprit.

`SafetyNotExpressible` is the general "this tool cannot honor the policy you asked for" case,
carrying only the provider and a human-readable explanation. It exists because this type is
deliberately shared with a second surface that has no capability profile at all.
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` repairs the interactive
launchers in `baikai-claude` and `baikai-openai`, which today silently discard a
cross-provider safety policy; those launchers consume
`Baikai.Interactive.InteractiveSafety`, whose constructors carry no capability, so
`UnsupportedCapability` cannot describe their failure. Providing one general constructor here
means both surfaces refuse through the same type and share `renderAgentRenderError`, rather
than the repository growing two parallel refusal vocabularies. It also means that plan does
not have to widen an already-published sum type, which would force a major version bump on
core for no semantic gain. Do not delete this constructor because the unattended renderers
happen not to use it.

`MissingEnvironment` and `WorkingDirMissing` are the two preconditions the runner checks before
spawning, and they exist so that a misconfigured job produces a precise message instead of an
opaque spawn error or, worse, a coding agent that starts and then flails. `MissingEnvironment`
carries every variable named in the request's `envPassthrough` that is unset or empty, checked as
a group so an operator sees all of them at once. `WorkingDirMissing` carries the path that does
not exist or is not a directory.

This module intentionally does not define a failure for "the process exited non-zero". If you
find yourself wanting one, re-read the paragraph above.

The existing error vocabulary in `baikai/src/Baikai/Error.hs` is not reused here. It is built
around `BaikaiError` with an `ErrorCategory` oriented to HTTP-shaped provider failures —
authentication, rate limiting, context overflow — and it is what `completeRequest` returns.
An unattended run is not a completion and should not be forced to report through a type whose
categories mostly cannot occur. Record this as a Decision Log entry when you implement the
milestone.

Verify with `cabal build baikai`.

### Milestone 4 — Tests that make the behavior observable

Scope: create `baikai/test/AgentSpec.hs` and register it in all three required places. At
the end of this milestone `cabal test baikai-test` reports the new group passing, and the
ceiling behavior is demonstrated rather than asserted in prose.

Create `baikai/test/AgentSpec.hs` following the shape of `baikai/test/InteractiveSpec.hs`: a
module exporting only `tests :: TestTree`, importing `Baikai.Agent`, `Baikai.Prelude`, the
tasty modules, and `System.Exit (ExitCode (..))`.

Write the following test cases.

A defaults test, mirroring `requestDefaultTest` in `InteractiveSpec.hs`. Build
`agentRunRequest AgentClaude "/tmp/work" "do the thing"` and assert every field: provider,
prompt, working directory, `modelId` is `Nothing`, `effort` is `Nothing`, `extraDirs` is
empty, the safety capability is `AgentReadOnly` with empty tool and raw-argument lists,
`timeout` is `Nothing`, `output` is `InheritOutput`, `outputLimit` is `Nothing`, and
`envPassthrough` is empty. This test is the guard that a future plan adding a field must
consciously decide its default rather than inherit an accident.

A canonical-rendering test asserting `renderAgentProvider`, `renderAgentCapability`, and
`renderAgentOutputMode` for every constructor, and asserting that `parseAgentProvider`,
`parseAgentCapability`, and `parseAgentOutputMode` invert them. Also assert that each parser
returns `Nothing` for an unrecognized string such as `"Claude"` with a capital letter, so the
configuration layer cannot later rely on accidental case-insensitivity.

A ceiling-acceptance test: with `defaultAgentCeiling`, a request whose capability is
`AgentReadOnly` and one whose capability is `AgentEditWorkspace` both pass, and the returned
request is equal to the input request. Assert the equality explicitly with `@?=` against the
original value — that is what proves no clamping happened.

A ceiling-refusal test, table-driven over every failing combination. With
`defaultAgentCeiling`: `AgentFullAccess` yields exactly
`[CapabilityExceeded AgentFullAccess AgentEditWorkspace]`; a non-empty `providerArgs` yields
`[ProviderArgsForbidden [...]]` with the arguments preserved in order; and a ceiling whose
`allowedProviders` is `[AgentClaude]` refuses an `AgentCodex` request with
`[ProviderForbidden AgentCodex [AgentClaude]]`. Assert the whole violation list, not merely
that a `Left` occurred, because the point of the type is the content of the message.

A multiple-violation test: one request that asks for `AgentFullAccess` **and** supplies raw
provider arguments **and** names a forbidden provider, checked against a restrictive ceiling,
must return all three violations. This is what pins the "collect everything" behavior.

An empty-allowed-providers test: a ceiling with `allowedProviders = []` refuses both
providers. This pins the documented reading that empty means none rather than all, which is
the one place where a plausible misreading is a security hole.

A violation-rendering test asserting that `renderCeilingViolation` mentions both the
requested and the permitted value for `CapabilityExceeded`, using `assertBool` with
`Text.isInfixOf`. Do not pin the exact sentence; pin that both facts appear, so wording can
be improved later without breaking the test.

A captured-output helper test: `capturedBytes OutputNotCaptured` is `Nothing`, and both
`OutputCaptured` and `OutputTruncated` return their bytes.

A failure-rendering test asserting that `renderAgentRenderError` and
`renderAgentRunFailure` produce non-empty text for every constructor, and specifically that
`ProviderMismatch AgentClaude AgentCodex` names both providers and that
`UnsupportedCapability` includes the explanation text it was given. Use `assertBool` with
`Text.isInfixOf` rather than pinning exact sentences.

A result-constructor test asserting `agentRunResult AgentCodex (ExitFailure 3) 1.5` records
the provider, the exit code, a duration, and `OutputNotCaptured` for both streams.

Register the module in three places, all of which are required:

1. Add `AgentSpec` to `other-modules` in the `test-suite baikai-test` stanza of
   `baikai/baikai.cabal`, keeping the list alphabetical so it lands before `AgentAssetsSpec`.
2. Add `import AgentSpec qualified` to `baikai/test/Main.hs`, keeping imports alphabetical.
3. Add `AgentSpec.tests` to the `testGroup "baikai" [...]` list in `baikai/test/Main.hs`,
   before `AgentAssetsSpec.tests`.

Verify:

```bash
cabal test baikai-test
```

### Milestone 5 — Documentation, changelog, and validation

Scope: tell a reader that the third surface exists and is not the other two, record the
change, and prove the workspace is green without contacting any provider.

Edit `docs/user/interactive-launches.md`. It currently explains why inherited-terminal
launches are a separate use case from batch completions. Add a short section explaining that
there is now a third case — an unattended run — and that its vocabulary lives in
`Baikai.Agent`. State plainly what distinguishes it: no terminal, no human, a working
directory it is authorized to modify, a capability profile bounded by an operator ceiling, and
a process result rather than a `Response`. Note that flag rendering and process spawning are
not part of this module and name the two plans that add them. Do not write a usage example
that spawns anything, because nothing in this plan can.

Add bullets under the `[Unreleased]` heading of the single root `CHANGELOG.md`. This
repository has exactly one changelog covering every package; there are no per-package
changelog files, and you must not create dated release headings during feature work. Scope
the bullets to `baikai` and describe the new module, the capability profile, the ceiling, and
that no existing surface changed.

Consider the version implication but do not perform a release. Adding an exposed module and
new types is an additive change under the Haskell Package Versioning Policy, so the in-tree
`baikai` version `0.4.1.0` needs a minor bump rather than a major one. The release itself is
run separately through `agents/skills/release/SKILL.md`, and
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` coordinates it
for the whole initiative. Do not hand-edit versions or dependency bounds here.

Update the parent MasterPlan: set EP-1 to `Complete` in the Exec-Plan Registry of
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`, check off
the four EP-1 lines in its Progress section, and add any cross-plan discovery to its
Surprises & Discoveries section — in particular, if a capability profile turned out not to be
expressible, EP-2 needs to know before it starts.

Then run the full validation described in Concrete Steps.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, unless
stated otherwise.

Build after each of Milestones 1 through 3:

```bash
cabal build baikai
```

Expect a successful build with no incomplete-pattern warnings. If you see
`Conflicting exports for 'provider'` or a similar message naming a field, you have either
exported bare accessors for both the request and the result, or added `Baikai.Agent` to
`baikai/src/Baikai.hs`. Re-read the export-list paragraph at the end of Milestone 1.

Run the core suite after Milestone 4:

```bash
cabal test baikai-test
```

Expect output ending in a pass line similar to the following, with a higher total than the
current baseline because of the cases you added:

```text
All 170 tests passed (0.30s)
```

To see the ceiling refusing a request without writing a test, use the interactive
interpreter. This is pure and contacts nothing:

```bash
cabal repl baikai
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
let base = agentRunRequest AgentClaude "/tmp/work" "reconcile the grammar"
let greedy = base & #safety .~ agentSafety AgentFullAccess
fmap (^. #safety) (applyAgentCeiling defaultAgentCeiling greedy)
-- expect: Left [CapabilityExceeded AgentFullAccess AgentEditWorkspace]
let ok = base & #safety .~ agentSafety AgentEditWorkspace
fmap (^. #safety) (applyAgentCeiling defaultAgentCeiling ok)
-- expect: Right (AgentSafety {capability = AgentEditWorkspace, allowedTools = [], providerArgs = []})
either (mapM_ (putStrLn . show . renderCeilingViolation)) (const (pure ())) (applyAgentCeiling defaultAgentCeiling greedy)
-- expect: "requested capability full-access exceeds the permitted maximum edit-workspace"
:quit
```

Full validation after Milestone 5. Two independent gates cause the `baikai-smoke` test suite
to make real, billable provider calls, and both must be closed. The first is provider API-key
environment variables. The second, discovered during the work recorded in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md`, is that
`baikai-smoke/test/Smoke.hs` runs authenticated batch CLI completions whenever the `claude` or
`codex` binary is merely found on `PATH`, regardless of API keys. The command below removes
the keys and filters the two directories that hold those binaries while keeping the active
Cabal and GHC toolchain. It is written for `zsh`, which is this machine's shell:

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

Expect `nix fmt` to leave no unintended diff, `git diff --check` to print nothing, every
component to build, every suite to pass, the smoke suite to report that provider keys and
both CLI binaries are unavailable and to skip all live cases, and the flake check to succeed.

Commit with both trailers required by the parent MasterPlan and the active intention:

```text
feat(agent): add unattended coding-agent run vocabulary

Add Baikai.Agent with the provider-neutral unattended request and result
types, the capability profile, and the pure policy ceiling that refuses
rather than clamps an over-broad request.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/45-add-the-unattended-agent-run-core-abstraction.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan is accepted when all of the following hold.

Building `baikai` succeeds with no incomplete-pattern warning, which is what proves every
mapping over the closed capability, provider, and output-mode sets is total.

A request built by `agentRunRequest AgentClaude "/tmp/work" "prompt"` has capability
`AgentReadOnly`, output mode `InheritOutput`, no timeout, no output limit, no extra
directories, and no forwarded environment variables. A test asserts every field, so a later
plan cannot add a field with an unconsidered default.

Checking a request against `defaultAgentCeiling` accepts `AgentReadOnly` and
`AgentEditWorkspace` and returns the request byte-identical to the input, and refuses
`AgentFullAccess` with exactly `[CapabilityExceeded AgentFullAccess AgentEditWorkspace]`. A
request with non-empty `providerArgs` is refused under the default ceiling and accepted under
a ceiling whose `allowProviderArgs` is `True`. A ceiling with an empty `allowedProviders`
list refuses every provider.

A request that violates the ceiling in three ways at once returns all three violations rather
than the first, and `renderCeilingViolation` output for a capability violation mentions both
the requested and the permitted value.

`Baikai.Agent` is listed in `exposed-modules` in `baikai/baikai.cabal` and is **not**
re-exported from `baikai/src/Baikai.hs`; `import Baikai` continues to compile for every
existing consumer, which is the source-compatibility requirement carried from the improvement
request.

`AgentSpec` is registered in `baikai/baikai.cabal`, imported in `baikai/test/Main.hs`, and
present in its root test group. `cabal test baikai-test` passes.

`docs/user/interactive-launches.md` describes the third surface and distinguishes it from the
other two. The root `CHANGELOG.md` has `baikai`-scoped bullets under `[Unreleased]`. The
parent MasterPlan shows EP-1 complete.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`,
and `nix flake check` all succeed. No acceptance step invokes a live model or an installed
coding-agent binary.


## Idempotence and Recovery

Every change in this plan is additive: one new source module, one new test module, three
registration lines, one documentation section, and changelog bullets. No existing module's
behavior changes, so every existing test must keep passing unchanged — if one starts failing,
you have edited something outside this plan's scope.

All commands are safe to repeat. `cabal` and `nix` may refresh local caches, and `nix fmt`
may rewrite formatting, but nothing here contacts a provider, mutates remote state, or writes
outside the repository.

To roll back, revert the commit. Nothing else in the workspace depends on `Baikai.Agent`
yet, so removing it cannot break another package. If you have already committed a milestone
and want to redo it, the module compiles standalone at the end of each of Milestones 1
through 3, so you can reset to any of them and continue.

The one irreversible-feeling step is the `exposed-modules` edit, and it is not: removing the
line and deleting the file returns the package to its previous state exactly.


## Interfaces and Dependencies

No new dependencies. This plan adds no entry to any `build-depends` list. It uses `bytestring`
for `ByteString`, `time` for `NominalDiffTime`, and `base` for `ExitCode`, all of which are
already dependencies of the `baikai` library. If you find yourself needing `process`,
`directory`, or `filepath`, you have strayed into
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`.

At completion, `baikai/src/Baikai/Agent.hs` exports the following interface. Later plans
depend on these exact names and signatures.

```haskell
-- Provider identity
data AgentProvider = AgentClaude | AgentCodex
renderAgentProvider :: AgentProvider -> Text
parseAgentProvider  :: Text -> Maybe AgentProvider

-- Capability profile, ascending in authority
data AgentCapability = AgentReadOnly | AgentEditWorkspace | AgentFullAccess
renderAgentCapability :: AgentCapability -> Text
parseAgentCapability  :: Text -> Maybe AgentCapability

-- What a job asks for
data AgentSafety = AgentSafety
  { capability :: !AgentCapability, allowedTools :: ![Text], providerArgs :: ![Text] }
agentSafety :: AgentCapability -> AgentSafety

-- What an operator permits
data AgentCeiling = AgentCeiling
  { maxCapability :: !AgentCapability, allowProviderArgs :: !Bool
  , allowedProviders :: ![AgentProvider] }
defaultAgentCeiling :: AgentCeiling   -- edit-workspace, no raw args, both providers

-- Enforcement: refuses, never clamps; reports every violation
data CeilingViolation
  = CapabilityExceeded !AgentCapability !AgentCapability  -- requested, permitted
  | ProviderArgsForbidden ![Text]
  | ProviderForbidden !AgentProvider ![AgentProvider]
renderCeilingViolation :: CeilingViolation -> Text
applyAgentCeiling :: AgentCeiling -> AgentRunRequest -> Either [CeilingViolation] AgentRunRequest

-- The request
data AgentRunRequest = AgentRunRequest
  { provider :: !AgentProvider, prompt :: !Text, modelId :: !(Maybe Text)
  , effort :: !(Maybe ThinkingLevel), workingDir :: !FilePath, extraDirs :: ![FilePath]
  , safety :: !AgentSafety, timeout :: !(Maybe NominalDiffTime)
  , output :: !AgentOutputMode, outputLimit :: !(Maybe Int), envPassthrough :: ![Text] }
agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest

-- Output discipline
data AgentOutputMode = InheritOutput | CaptureOutput | TeeOutput
renderAgentOutputMode :: AgentOutputMode -> Text
parseAgentOutputMode  :: Text -> Maybe AgentOutputMode
data AgentCapturedOutput = OutputNotCaptured | OutputCaptured !ByteString | OutputTruncated !ByteString
capturedBytes :: AgentCapturedOutput -> Maybe ByteString

-- The renderer/runner boundary. No working directory by design: Claude has no
-- working-directory flag, so it is a process-level setting the runner reads from
-- the request. The runner therefore takes both values.
data AgentPromptTransport = PromptOnStdin | PromptAsArgument
data AgentCommand = AgentCommand
  { executable :: !FilePath, arguments :: ![String]
  , promptTransport :: !AgentPromptTransport, promptText :: !Text }

-- The result
data AgentRunResult = AgentRunResult
  { provider :: !AgentProvider, exitCode :: !ExitCode
  , stdout :: !AgentCapturedOutput, stderr :: !AgentCapturedOutput
  , duration :: !NominalDiffTime }
agentRunResult :: AgentProvider -> ExitCode -> NominalDiffTime -> AgentRunResult

-- Failures: refusal before spawn, and failure while running
data AgentRenderError
  = UnsupportedCapability !AgentProvider !AgentCapability !Text
  | UnsupportedToolRestriction !AgentProvider !Text
  | SafetyNotExpressible !AgentProvider !Text        -- general case; used by the interactive surface
  | ProviderMismatch !AgentProvider !AgentProvider   -- renderer's provider, request's provider
  | CeilingRejected ![CeilingViolation]
renderAgentRenderError :: AgentRenderError -> Text
data AgentRunFailure
  = SpawnFailed !FilePath !Text
  | RunTimedOut !NominalDiffTime
  | MissingEnvironment ![Text]     -- every declared variable that is unset or empty
  | WorkingDirMissing !FilePath
  | OutputMalformed !Text
renderAgentRunFailure :: AgentRunFailure -> Text
```

Export shape, restated because it is the easiest thing to get wrong: `AgentRunRequest`,
`AgentSafety`, `AgentCeiling`, and `AgentRunResult` are exported as bare type names without
`(..)`. The field accessors of `AgentRunRequest`, `AgentSafety`, and `AgentCeiling` are
exported individually by name. `AgentRunResult`'s accessors are **not** exported, to avoid a
name conflict on `provider` with the request; read it with `result ^. #provider`. The
enumerations `AgentProvider`, `AgentCapability`, `AgentOutputMode`, `AgentCapturedOutput`,
`AgentPromptTransport`, `AgentCommand`, `CeilingViolation`, `AgentRenderError`, and
`AgentRunFailure` are exported with `(..)`.

Downstream impact: none yet. No package depends on `Baikai.Agent` at the end of this plan.
The consumers arrive in
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md`,
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` (which uses
`AgentRenderError` only),
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`,
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`, and
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`.
