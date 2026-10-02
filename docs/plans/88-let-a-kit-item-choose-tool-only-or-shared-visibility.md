---
id: 88
slug: let-a-kit-item-choose-tool-only-or-shared-visibility
title: "Let a kit item choose tool-only or shared visibility"
kind: exec-plan
created_at: 2026-10-01T23:43:36Z
intention: "intention_01m3wxm567effr24vt0j7cbn45"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-01T23:43:36Z
---

# Let a kit item choose tool-only or shared visibility

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`baikai-kit` installs AI-agent skills and subagents for command-line tools such as
`mori://shinzui/rei`, `mori://shinzui/mori`, `mori://shinzui/okf`, and notion-hub. Today
nobody decides where an installed item is visible. The answer depends on the provider, and the
two providers behave in opposite ways. A Claude Code copy is always **tool-only**: it is visible
only in sessions the tool itself launches, because the launcher passes
`--add-dir ~/.config/<tool>/agents`. A Codex copy is always **shared**: it lands in
`~/.agents/skills/` or `<root>/.agents/skills/`, which every Codex session reads. `kit status`
says neither.

After this change, visibility is a declared setting per item, independent of user or project
scope. A kit author writes `"visibility": "shared"` on an item in `kit.json`. The default is
`"tool-only"`. A user can override it on one install with `kit install NAME --shared` or
`--tool-only`. Each provider then either honours the requested visibility or the kit says
plainly that it cannot:

- **Claude Code, shared:** the kit places a symbolic link (an *alias* file that points at another
  path) at `~/.claude/skills/<name>`, or `<root>/.claude/skills/<name>` for project scope,
  pointing at the copy the tool already owns. Every plain `claude` session discovers it, and
  `kit update` changes the content without touching the link.
- **Codex skills, tool-only:** the skill is installed into the Codex discovery root as today.
  The kit also adds a `[[skills.config]] path = "…/SKILL.md" enabled = false` entry to
  `~/.codex/config.toml`, so a plain `codex` session does not see the skill. The tool's own Codex
  launches re-enable it with one `-c skills.config=[…]` argument, which the new
  `Baikai.Kit.Session.codexSessionArgs` function builds. A spike on 2026-10-01 proved this works
  with codex-cli 0.159.3 (see Surprises & Discoveries).
- **Codex custom agents (subagents), tool-only:** Codex has no known way to hide one. `kit install`
  refuses, saying the Codex copy would be visible to every Codex session, unless the user passes
  `--accept-shared-codex` or the tool's confirmation callback says yes. It never shares silently.

`kit status` (table and `--json`) reports each provider copy's requested and effective
visibility. It also reports a link or config entry that has gone missing, which `kit update`
repairs. `kit uninstall` removes exactly the links and config entries the kit created. A shared
install never takes over a name in `~/.claude/skills/` or a Codex root that the kit did not
create. Items installed before this change keep their placement, and `kit status` points out the
Codex ones that are shared.

To see it working, run `cabal test baikai-kit`; new tests cover each of the behaviours above
against a temporary `HOME`. Then follow the manual check in Validation and Acceptance. It installs a
tool-only skill into an isolated `HOME` and runs `codex debug prompt-input` twice: without the
session arguments the skill is absent, and with them it is listed.

This plan implements [IR-12](../improvement-requests/let-a-kit-item-choose-tool-only-or-shared-visibility.md)
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-12`), raised by
`mori://shinzui/rei` for its `rei-capture-session` skill.


## Progress

- [ ] Milestone 1: visibility is a declared, overridable per-item setting. Claude Code shared
  installs create, repair, and remove tracked links. Shared names the kit did not create are
  refused in `~/.claude/skills/`, `<root>/.claude/skills/`, and the Codex roots. Accepted when
  the Milestone 1 tests listed in Validation and Acceptance pass under `cabal test baikai-kit`.
- [ ] Milestone 2: Codex tool-only skills are hidden through tracked `[[skills.config]]` entries
  and re-enabled by `codexSessionArgs`. A tool-only Codex agent is refused unless accepted.
  Accepted when the Milestone 2 tests pass, and when the manual `codex debug prompt-input` check
  shows the skill hidden without the arguments and listed with them.
- [ ] Milestone 3: `kit status` and `kit status --json` report requested and effective
  visibility and the `visibility-broken` condition, and the legacy Codex note is printed. The
  goldens are regenerated at `formatVersion` 1. `docs/user/kit.md`, the changelog,
  the `baikai-kit` 0.4.0.0 version, ADR 0025, and IR-12's status are updated. Accepted when
  `cabal test all` passes and IR-12's Status section maps every acceptance criterion to a test
  or recorded check.


## Surprises & Discoveries

- Observation: The workaround IR-12 left unverified works. A `[[skills.config]] enabled = false`
  entry in the user's Codex config hides a skill. A launch-time `-c skills.config=[…]` override
  re-enables it, and **the override merges with the user's entries by path; it does not replace
  the array**. This was the risk IR-12 asked a spike to settle. The test used codex-cli 0.159.3
  in an isolated `HOME`/`CODEX_HOME`, with two skills `alpha-skill` and `beta-skill` in
  `$HOME/.agents/skills/`, both disabled in `config.toml`. `codex debug prompt-input` prints the
  model-visible context offline, without an API call. The command below counted lines naming
  each skill:

  ```text
  --- both disabled in config
  exit=0 alpha=0 beta=0
  --- -c array with alpha enabled only
  exit=0 alpha=1 beta=0
  --- -c indexed skills.config.0.enabled=true
  exit=1 alpha=0 beta=0
  Error: invalid type: map, expected a sequence
  ```

  Beta stayed hidden while alpha was re-enabled, so the user's other entries survive the override.
  The same run established the following:

  - A project-scope skill at `<work>/.agents/skills/proj-skill` is hidden by an absolute-path
    entry in the *user* config and re-enabled by `-c`.
  - Two entries in one `-c` array both apply.
  - The entry's `path` must name the `SKILL.md` file. A directory path does not match.
  - Codex canonicalises paths. An entry spelled `/tmp/…` matched a skill under `/private/tmp/…`.
  - A symlinked skill directory inside a Codex root is followed and listed.
  - An `enabled = true` entry for a `SKILL.md` *outside* the discovery roots does **not** add the
    skill. Tool-only Codex skills therefore must still be installed into the Codex root.

  Evidence: commands run from
  `/private/tmp/claude-501/…/scratchpad/codex-spike` on 2026-10-01; the method is repeated in
  Validation and Acceptance so it can be rerun.

- Observation: Codex custom agents (`~/.codex/agents/<name>.toml`) do not appear in
  `codex debug prompt-input`. Their visibility cannot be checked offline, and no documented
  per-agent disable switch was found. This is why tool-only Codex agents take the refusal path.
  Evidence: a `spy-agent.toml` in the isolated `$CODEX_HOME/agents/` produced zero matches in
  the prompt-input JSON.


## Decision Log

- Decision: Deliver Codex tool-only for **skills** through a tracked `[[skills.config]]
  enabled = false` entry plus a launch-time `-c` override. For **custom agents**, refuse unless
  the user accepts shared visibility.
  Rationale: The spike (Surprises & Discoveries) proved the skill mechanism and refuted the risk
  that `-c` replaces the user's array. No equivalent switch is known for agents, and their
  visibility cannot be observed offline. IR-12's contract allows either branch per provider, as
  long as nothing is shared silently. If Codex later documents an agent switch, the agent branch
  can be upgraded without changing the manifest or the sidecar shape.
  Date: 2026-10-01

- Decision: Add the `visibility` key to manifest items without bumping the manifest `version`
  (it stays `1` or `2`).
  Rationale: The key is optional, and aeson's generic decoder ignores unknown keys, so an older
  `baikai-kit` reading a new `kit.json` installs the item exactly as it does today. An item that
  asks to be shared then gets today's placement: tool-only on Claude and shared on Codex. Nobody
  is broken by that, which is the safe failure. Bumping the version would make every older
  installer refuse the whole kit for one optional key.
  Date: 2026-10-01

- Decision: Items installed before this change (sidecar without a `visibility` field) keep their
  placement through `kit update`. Only an explicit `kit install` changes it. For an item
  installed by this release, `kit update` follows the manifest's current declaration unless
  the install used `--shared` or `--tool-only`, in which case the override is kept.
  Rationale: This is IR-12 contract point 6 ("Existing installs keep working"). Hiding existing
  Codex skills on an update would be a surprise in the other direction. Recording whether the
  value came from the manifest or a flag lets an author change a default without overwriting a
  user's explicit choice.
  Date: 2026-10-01

- Decision: A user-scope Claude link has an absolute target. A project-scope link has a target
  relative to the link (`../../.<tool>/agents/.claude/skills/<name>`).
  Rationale: A project's `.claude/skills/` may be committed. A relative link keeps working in
  every clone of the repository, and an absolute one would point into one person's checkout.
  The user scope never travels between machines.
  Date: 2026-10-01

- Decision: The Codex config file is edited as text and checked by parsing. The kit appends or
  removes one `[[skills.config]]` block. Before writing, it parses the old and new text with
  `toml-parser` and requires the new table to equal the old one plus or minus exactly that entry.
  It refuses if the file is a symbolic link, does not parse, or would stop parsing. It never
  re-serialises the file.
  Rationale: `~/.codex/config.toml` belongs to the user and to Codex. It carries comments,
  project trust entries, and formatting that a parse-and-print round trip would destroy. A
  symlinked config is typically generated by home-manager, so writing through the link or
  replacing it would be wrong.
  Date: 2026-10-01

- Decision: A tool that launches Codex must add `codexSessionArgs` to its launch request. The
  kit does not gate Codex tool-only hiding behind an opt-in flag.
  Rationale: `baikai-openai` does not depend on `baikai-kit`, and the consumer builds the Codex
  command, so the engine cannot inject the `-c` argument itself. An opt-in `KitConfig` flag
  would make every tool-only Codex skill hit the agent refusal path until each tool flipped it.
  That breaks `kit install` for every existing consumer, which is worse than asking a consumer
  that launches Codex for one line. This narrows IR-12 acceptance 7: "only a version bump"
  holds for Claude Code and for every kit verb, while a consumer's own Codex sessions need the
  one-line launcher change. The changelog and `docs/user/kit.md` must say this prominently.
  Date: 2026-10-01

- Decision: `baikai-kit` goes to 0.4.0.0, a breaking release. `SkillEntry`, `AgentEntry`,
  `SidecarMeta`, `RemovalOutcome`, `StatusRow`, and `KitConfig` gain fields, `KitInstall`
  gains an options argument, and `installItem` and `installFrom` take `InstallOptions`.
  `formatVersion` of the JSON documents stays `1`.
  Rationale: The Package Versioning Policy makes changed exported constructors a major change. A
  consumer that uses only `kitConfig`, `kitCommandParser`, and `runKit` needs only the bound
  bump, which is IR-12 acceptance 7. ADR 0024 keeps the version when keys and values are only
  added. A new condition label adds a value and does not change what an existing value means.
  Date: 2026-10-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The package and its vocabulary

`baikai-kit` (directory `baikai-kit/`, version 0.3.0.0 in `baikai-kit/baikai-kit.cabal`) is a
library a command-line tool links to get a complete `kit` subcommand: `kit list`,
`kit install NAME [--project]`, `kit update [NAME] [--force] [--json]`,
`kit uninstall NAME [--project]`, and `kit status [--json]`. Terms used below:

- **Kit**: a git repository of skills and agents with a `kit.json` manifest at its root. It is
  cloned to `~/.cache/<tool>/kit` (`Baikai.Kit.Repo.ensureKitRepo`).
- **Item**: one skill or one agent listed in `kit.json`. A **skill** is a directory with a
  `SKILL.md` and supporting files. An **agent** (a "subagent" or "custom agent") is one prompt
  file, Markdown for Claude Code and rendered to TOML for Codex.
- **Provider**: `InteractiveClaude` (Claude Code) or `InteractiveCodex` (Codex), the type
  `Baikai.Interactive.InteractiveProvider`, also called `AgentAssetProvider`. A `KitConfig` lists
  the providers a tool installs for, and each install writes one **provider copy** per provider.
- **Scope**: `UserScope` (under the home directory) or `ProjectScope` (under the project root),
  the type `Baikai.Kit.Config.KitScope`.
- **Sidecar**: a small JSON file written beside each provider copy, named
  `.<tool>-kit.json` inside a skill directory or `<name>.<tool>-kit.json` beside an agent file
  (`Baikai.Kit.Sidecar.sidecarPath`). It records name, kind, version, upstream hash, install
  time, and the installed file names and hash (`SidecarMeta`).
- **Visibility**: new in this plan. **Tool-only** means a copy is visible only in sessions the
  owning tool launches. **Shared** means it is visible in every session of that provider, on
  the machine for user scope or in the project for project scope. **Requested** visibility is
  what the manifest or install flag asked for. **Effective** visibility is what the files on disk
  actually produce.

### Where files go today

`Baikai.Kit.Config.providerAgentsBase` (`baikai-kit/src/Baikai/Kit/Config.hs`) picks each
provider's base directory:

```haskell
providerAgentsBase config InteractiveClaude scope = resolveAgentsBase config scope  -- ~/.config/<tool>/agents or <root>/.<tool>/agents
providerAgentsBase _config InteractiveCodex UserScope = getHomeDirectory
providerAgentsBase config InteractiveCodex ProjectScope = config ^. #projectRoot
```

Below that base, `Baikai.AgentAssets.skillTargetPath` and `agentTargetPath`
(`baikai/src/Baikai/AgentAssets.hs`, always called with `InteractiveProjectScope` so they return
relative paths) add `.claude/skills/<name>`, `.claude/agents/<name>.md`,
`.agents/skills/<name>`, or `.codex/agents/<name>.toml`. Concretely, for tool `mytool` and item
`review`:

```text
Claude, user     ~/.config/mytool/agents/.claude/skills/review/          (tool-only via --add-dir)
Claude, project  <root>/.mytool/agents/.claude/skills/review/            (tool-only via --add-dir)
Codex, user      ~/.agents/skills/review/   ~/.codex/agents/review.toml  (shared)
Codex, project   <root>/.agents/skills/review/   <root>/.codex/agents/review.toml  (shared)
```

A multi-file agent also gets a resource directory named after it beside its agent file, for
example `.claude/agents/review/` (`agentResourceDir` in `Baikai.Kit.Install`).

`Baikai.Kit.Session.agentDirsForSession` (`baikai-kit/src/Baikai/Kit/Session.hs`) returns
`~/.config/<tool>/agents` and `<root>/.<tool>/agents` when they exist. A consuming tool passes
these as `extraDirs` on its `Baikai.Interactive.InteractiveLaunchRequest`. The Claude launcher
(`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`) turns each one into `--add-dir DIR`,
and Claude Code then loads `<DIR>/.claude/skills/*`. The Codex launcher
(`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`) also emits `--add-dir`, but for Codex
that only makes a directory writable and loads no skills. The same launcher already passes
`-c model_reasoning_effort=…` and copies `InteractiveLaunchRequest.extraArgs` onto the command
line before the prompt, which is where the new `-c skills.config=[…]` argument goes. No launcher
change is needed: `baikai-openai` does not depend on `baikai-kit`, and the consumer passes the
arguments through `extraArgs`.

### The modules this plan changes

- `baikai-kit/src/Baikai/Kit/Manifest.hs`: `KitManifest`, `SkillEntry`, `AgentEntry` (derived
  `FromJSON`), `KitItem`, `itemSources`.
- `baikai-kit/src/Baikai/Kit/Sidecar.hs`: `SidecarMeta` (derived `FromJSON`/`ToJSON`; aeson 2.2
  decodes a missing key into a `Maybe` field as `Nothing`, which is how `installedFiles` was
  added in 0.2), `newSidecarMeta`, `readSidecar`.
- `baikai-kit/src/Baikai/Kit/Install.hs`: install (`installFromIO` → `doInstall` →
  `planInstall` → `executePlan`, an atomic two-phase write of a list of `PlannedWrite`s),
  `uninstallItem`, `reinstallPresentIO` (the body of `kit update`), and `checkLocalEdits`.
  Every exported function returns `Either KitError a`. Internally the module throws `KitError`
  and catches it at the boundary with `kitTry`.
- `baikai-kit/src/Baikai/Kit/Status.hs`: `KitCondition` (constructor order is render order),
  `conditionLabel`, `StatusRow`, `collectStatus`, `renderStatusTable`, and
  `aggregateStatusRows`, which merges the Claude and Codex rows when every other column
  matches.
- `baikai-kit/src/Baikai/Kit/Json.hs`: hand-written encoders `listDocument`, `statusDocument`,
  and `updateDocument`, with `kitJsonFormatVersion = 1`.
- `baikai-kit/src/Baikai/Kit/Command.hs`: `KitCommand`, `kitCommandParser`, `runKitCommand`,
  and `runKit`, the only function that exits the process.
- `baikai-kit/src/Baikai/Kit/Config.hs`: `KitConfig` (built with `kitConfig`, with a
  hand-written `Show`), the path functions, and the labels.
- `baikai-kit/src/Baikai/Kit/Error.hs`: `KitError` (positional constructors) and
  `renderKitError`.
- `baikai-kit/src/Baikai/Kit/Session.hs`: `agentDirsForSession`.
- `baikai-kit/src/Baikai/Kit.hs`: the umbrella module re-exporting all of the above. A new
  module must be added there and to `exposed-modules` in `baikai-kit/baikai-kit.cabal`.
- `baikai-kit/test/Main.hs`: one tasty suite. Fixtures `withFreshHome`,
  `withPreparedKitHome` (writes a kit with skill `demo` and agent `reviewer` into a temporary
  `~/.cache/testkit/kit`), and `withStatusFixture`. `testConfig` is
  `kitConfig "testkit" "file:///not-used" [InteractiveClaude, InteractiveCodex]`. Goldens in
  `baikai-kit/test/golden/{list,status,update}.json` are compared as decoded JSON and
  regenerated with `BAIKAI_KIT_ACCEPT_GOLDEN=1`.

The changelog is the repository-root `CHANGELOG.md` (`baikai-kit/CHANGELOG.md` is a symbolic
link to it). The user guide is `docs/user/kit.md`. `baikai-smoke/baikai-smoke.cabal` depends on
`baikai-kit` without a version bound, so it needs no edit.

### What each agent can and cannot do

These facts came from IR-12 and were checked on 2026-10-01:

- Claude Code discovers skills in `~/.claude/skills/`, in `<project>/.claude/skills/`, and in
  `<dir>/.claude/skills/` for each `--add-dir`. It discovers agents in the matching `agents/`
  directories. It follows symlinked skill folders. It has no setting for extra skill paths.
- Codex discovers skills in `.agents/skills` from the working directory up to the repository
  root, in `$HOME/.agents/skills`, in `/etc/codex/skills`, and in its built-in skills. It has no
  flag that adds a skill directory. Its configuration lives in `$CODEX_HOME/config.toml`, with
  `CODEX_HOME` defaulting to `~/.codex`. `codex -c key=value` overrides configuration for one
  launch, with `value` parsed as TOML.
- The spike recorded in Surprises & Discoveries settled the rest: how `skills.config` entries
  and `-c` overrides combine, and that agents cannot be checked offline.

### Relevant ADRs

- [docs/adr/0021-kit-project-scope-is-one-resolved-root.md](../adr/0021-kit-project-scope-is-one-resolved-root.md):
  every project-scope path derives from `KitConfig.projectRoot` through `projectAgentsDir`,
  `resolveAgentsBase`, or `providerAgentsBase`. The new shared-link location
  `<root>/.claude/skills` must also derive from `projectRoot` through a function in
  `Baikai.Kit.Config`, so `grep -rn getCurrentDirectory baikai-kit/src` still finds only the two
  places that ADR names. A new strict `KitConfig` field gets its default in `kitConfig`.
- [docs/adr/0022-kit-status-and-update-share-one-local-edit-check.md](../adr/0022-kit-status-and-update-share-one-local-edit-check.md):
  one implementation of each check is shared by status and update. Conditions are a sorted list
  spelled by `conditionLabel`. This plan follows the same rule for visibility: one function
  computes a copy's effective visibility and brokenness, and status reports it while update
  repairs from it.
- [docs/adr/0023-the-kit-engine-ships-no-terminal-ui.md](../adr/0023-the-kit-engine-ships-no-terminal-ui.md):
  interactive steps are optional function fields on `KitConfig`, defaulted to `Nothing` in
  `kitConfig`, and the engine never prompts. The Codex-shared confirmation follows this as
  `confirmSharedCodex`.
- [docs/adr/0024-machine-readable-kit-output-is-a-versioned-contract.md](../adr/0024-machine-readable-kit-output-is-a-versioned-contract.md):
  JSON is written by explicit encoders, every documented key is always present (`null` when
  absent), and adding a key keeps `formatVersion`. A golden that changes needs a recorded
  `formatVersion` decision (recorded above).
- [docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md):
  new failures are `KitError` constructors returned as `Left`. Only `runKit` exits.
- [docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md](../adr/0016-deprecated-names-are-removed-at-the-next-major.md):
  this plan changes signatures outright in a major release and adds no deprecated aliases.
- [docs/adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md](../adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md):
  the Codex config is read and written as UTF-8 bytes (`Data.ByteString` plus
  `Data.Text.Encoding`), never through the locale.

No existing ADR covers visibility. Milestone 3 adds
`docs/adr/0025-kit-visibility-is-honoured-per-provider-or-refused.md`.


## Plan of Work

The work has three milestones. Each leaves `cabal test baikai-kit` green and adds behaviour a
test can observe.

### Milestone 1: declared visibility, Claude shared links, and name protection

At the end of this milestone, an item can declare its visibility, `kit install` can override it,
and a shared Claude Code copy is reachable through a tracked link. The milestone also protects
names in the shared directories that the kit did not create.

Create `baikai-kit/src/Baikai/Kit/Visibility.hs` with the vocabulary:

```haskell
data KitVisibility = ToolOnlyVisibility | SharedVisibility
  deriving stock (Eq, Ord, Show, Enum, Bounded)

visibilityLabel :: KitVisibility -> Text          -- "tool-only" | "shared"
parseVisibility :: Text -> Either Text KitVisibility

-- Where a copy's requested visibility came from.
data VisibilitySource = FromManifest | FromInstallFlag
  deriving stock (Eq, Show)
```

Give `KitVisibility` a `FromJSON` instance that accepts exactly `"tool-only"` and `"shared"`
and fails on anything else. A manifest with `"visibility": "public"` is then a
`KitManifestInvalid` error naming the file, not a silent default. Add
`visibility :: !(Maybe KitVisibility)` to both `SkillEntry` and `AgentEntry` in
`Baikai.Kit.Manifest`, and export `itemVisibility :: KitItem -> KitVisibility`, which returns
`ToolOnlyVisibility` when the key is absent. Add the module to `Baikai.Kit` and to
`exposed-modules`.

Add to `SidecarMeta` (all `Maybe`, so older sidecars still decode):
`visibility :: Maybe Text` (the requested label; `Nothing` means the copy was installed before
0.4.0.0), `visibilitySource :: Maybe Text` (`"manifest"` or `"install-flag"`),
`sharedLinks :: Maybe [Text]` (absolute paths of links created for this copy), and
`codexDisabledSkills :: Maybe [Text]` (filled in Milestone 2). Keep the field names free of
prefixes (repository convention). `newSidecarMeta` takes the new values.

Add `InstallOptions` to `Baikai.Kit.Install`:

```haskell
data InstallOptions = InstallOptions
  { visibility :: !(Maybe KitVisibility),  -- Nothing: use the manifest's declaration
    acceptSharedCodex :: !Bool             -- used in Milestone 2
  }
  deriving stock (Eq, Show, Generic)

defaultInstallOptions :: InstallOptions   -- Nothing, False
```

Thread it through `installItem`, `installFrom`, and `installFromIO`. Change
`KitInstall !(Maybe Text) !KitScope` to `KitInstall !(Maybe Text) !KitScope !InstallOptions` in
`Baikai.Kit.Command`, and extend `installParser`:

- `--shared` and `--tool-only` are mutually exclusive, written as
  `optional (flag' SharedVisibility (long "shared" …) <|> flag' ToolOnlyVisibility (long "tool-only" …))`.
- `--accept-shared-codex` is a plain `switch`.

The help text must say that `--shared` makes the item visible in every Claude Code and Codex
session, and that `--tool-only` makes it visible only in sessions this tool launches.

Add the shared-location functions to `Baikai.Kit.Config`, next to `providerAgentsBase`. They
return the provider-native directory that every session of that provider reads, as defined
by ADR 0021:

```haskell
-- The directory under which a shared Claude link lives: ~ for user scope, projectRoot for project scope.
sharedClaudeBase :: KitConfig -> KitScope -> IO FilePath
```

The link for a skill is `sharedClaudeBase </> ".claude/skills/<name>"`. For an agent it is
`sharedClaudeBase </> ".claude/agents/<name>.md"`, plus `.claude/agents/<name>` for a multi-file
agent's resource directory. Each link targets the matching path under the Claude provider copy
(`providerAgentsBase config InteractiveClaude scope`). Use an absolute target for user scope.
For project scope, make the target relative to the link's directory with
`System.FilePath.makeRelative` applied to the parent and prefixed with the right number of
`..` segments. Write a helper `relativeLinkTarget :: FilePath -> FilePath -> FilePath` and unit
test it.

Write the link logic as a small set of functions in a new internal section of
`Baikai.Kit.Install`, or a new module `Baikai.Kit.Link` if Install grows unwieldy. Use
`System.Directory.createFileLink` / `createDirectoryLink`, `pathIsSymbolicLink`, and
`getSymbolicLinkTarget`. The rules are:

1. **Ownership.** A path at a shared location is *ours* when it is a symbolic link whose target,
   resolved against the link's directory, equals the expected target. It is also ours when it
   does not exist. Anything else is *foreign*: a real directory, a real file, a link to
   somewhere else, or a dangling link to somewhere else. A dangling link to *our* target counts
   as ours, because an uninstalled copy leaves exactly that.
2. **Refuse foreign names.** Before any write, check every link the install will create. If one
   is foreign, fail with the new `KitSharedNameTaken FilePath (Maybe Text)` and write nothing.
   The `Maybe Text` names the owner when it can be told: a link whose target lies under
   `~/.config/<x>/agents` or `<root>/.<x>/agents` belongs to tool `<x>`, and a directory holding
   a `.<x>-kit.json` sidecar belongs to tool `<x>`. The message reads, for example,
   `~/.claude/skills/review already exists and was not created by mytool (it belongs to rei); refusing to replace it.`
3. **Protect the Codex roots the same way.** A Codex copy writes into `~/.agents/skills/<name>`,
   `~/.codex/agents/<name>.toml`, or their project equivalents, which every tool and the user
   share. Before writing, if the skill directory exists without this tool's sidecar
   (`.<tool>-kit.json`), or the agent file exists without `<name>.<tool>-kit.json` beside it,
   fail with `KitSharedNameTaken`. This applies whatever the visibility, because these
   directories are shared either way. Today the kit silently writes into such a directory.
4. **Order.** First compute the requested visibility. It is the `InstallOptions` flag if one was
   given, otherwise `itemVisibility`. Then run every refusal check. Then read the previous
   sidecar of each provider copy, if any. Then run `executePlan`, which writes the files and the
   new sidecars that record `visibility`, `visibilitySource`, and the intended `sharedLinks`.
   Then create the missing links. Then remove links that the previous sidecar recorded and the
   new visibility does not want, but only links that are still ours. A failure after
   `executePlan` succeeded is reported as the new
   `KitVisibilityNotApplied Text [FilePath]` (reason and the paths not done). The message ends
   `run 'kit update NAME' to retry`, because update repairs this, as described next.

Make `kit update` repair visibility. In `reinstallPresentIO`, after deciding to reinstall or
skip an item, run the same visibility-apply step for every installed item, including a skipped
one. That way a deleted link is recreated even when local edits stop the file reinstall.
Compute the requested visibility for update as follows:

- If the sidecar's `visibilitySource` is `"install-flag"`, keep the sidecar's `visibility`.
- Otherwise, if the sidecar has a `visibility`, use the manifest's current `itemVisibility`.
- If the sidecar has no `visibility` (installed before 0.4.0.0), apply nothing and keep writing
  no `visibility`, so the item stays as it was. This follows the decision on legacy installs in
  the Decision Log.

Make `kit uninstall` remove links. `uninstallItem` must read each provider copy's sidecar
*before* deleting it. It removes each recorded link that is still ours, and also an unrecorded
link at the standard shared location that is ours, for example after a lost sidecar. It never
removes a foreign path. Extend `RemovalOutcome` with `linksRemoved :: [FilePath]`, and make
`renderUninstallReport` mention them, for example
`Uninstalled skill 'review' from user scope (claude,codex); removed 1 shared link.`

### Milestone 2: Codex tool-only skills, session arguments, and agent refusal

At the end of this milestone, a tool-only Codex skill is hidden from plain `codex` sessions,
the tool's own launches can re-enable it, and a tool-only Codex agent is never shared without
consent.

Add `toml-parser ^>=2.0.2` to the library's `build-depends`. Version 2.0.2.0 is the latest on
Hackage as of 2026-10-01 and supports base 4.21, the base of the pinned GHC 9.12. It needs
the `alex` and `happy` build tools, which cabal builds automatically. Its `Toml.parse :: Text ->
Either String (Table' Position)` parses TOML 1.1, and `Toml.forgetTableAnns` drops the source
positions so that two tables can be compared.

Create `baikai-kit/src/Baikai/Kit/CodexConfig.hs`:

```haskell
-- $CODEX_HOME/config.toml, defaulting to ~/.codex/config.toml.
codexConfigPath :: IO FilePath

-- The [[skills.config]] entries: SKILL.md path -> enabled.
-- A missing file is an empty map.
readSkillEntries :: FilePath -> IO (Either KitError [(FilePath, Bool)])

-- Append one `[[skills.config]] path = "<p>" enabled = false` block.
-- A no-op returning False if an enabled=false entry for p already exists;
-- True if this call added it.
addDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)

-- Remove the block whose path is p and enabled is false; False if none.
removeDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)

-- The launch argument that re-enables these SKILL.md paths:
-- ["-c", "skills.config=[{path=\"…\",enabled=true},…]"], or [] for none.
enableSkillsArgs :: [FilePath] -> [Text]
```

Compare paths the way Codex does, canonicalised. Apply `canonicalizePath` to both sides
(it works on paths that do not exist) and compare the results. Write the path as a TOML basic
string with `"`, `\`, and control characters escaped. A local escaper is enough; test it with
a path containing a quote. Validate edits the way the Decision Log describes:

1. Read the bytes and decode them as UTF-8. If the path is a symbolic link, or the bytes do not
   decode or parse, fail with the new `KitCodexConfigUnusable FilePath Text`. The message must
   include the exact block the user can add by hand, and it must say that
   `--shared` or `--accept-shared-codex` installs without the entry.
2. Build the new text. To add, ensure the text ends with a newline, then append a blank line
   and the three-line block. To remove, delete the lines from the matching `[[skills.config]]`
   header up to the next line starting with `[` or the end of the file.
3. Parse the new text and check it semantically. The `skills.config` array must equal the old
   array plus or minus exactly that entry, and every other key must be unchanged. If not, fail
   with `KitCodexConfigUnusable` and write nothing. This also catches a config that sets
   `skills.config = [...]` inline, where appending `[[skills.config]]` is a TOML error.
4. Write atomically: a temporary file in the same directory, the original file's permissions
   copied with `getPermissions`/`setPermissions` (the file is normally mode 0600), then
   `renameFile`. Create `$CODEX_HOME` and the file if neither exists.

An existing entry for the same path that this kit did not record is handled two ways. If it
says `enabled = false`, reuse it and do not record it, so uninstall leaves it alone. If it says
`enabled = true`, the user explicitly enabled the skill: fail with `KitCodexConfigUnusable` and
explain.

Wire it into install. For a Codex **skill** copy whose requested visibility is tool-only,
`addDisabledSkill` its `SKILL.md` path after `executePlan` and record the path in the sidecar's
`codexDisabledSkills`. For a shared one, remove any entry the previous sidecar recorded. Run the
config preflight (the file is readable, not a link, and the edit would validate) together with
the other refusal checks, before any write. Uninstall removes recorded entries. Update repairs
missing ones, exactly as for links. If the item lists no `SKILL.md` in its files, which is
unusual, fail with `KitCodexConfigUnusable` saying that tool-only on Codex needs a `SKILL.md`.

Handle a tool-only Codex **agent**. When `InteractiveCodex` is among the providers and the
item is an agent whose requested visibility is tool-only, the install would make it shared.
Allow it in any of these cases:

- `acceptSharedCodex` is true;
- the new `KitConfig` field
  `confirmSharedCodex :: Maybe (KitItem -> IO Bool)` (defaulted to `Nothing` in `kitConfig`,
  shown in the hand-written `Show` like `chooseItem`) is `Just f` and `f item` returns `True`.

Otherwise fail with the new `KitCodexCannotIsolate Text` before writing anything:
`'planner' is a tool-only agent, but Codex cannot hide a custom agent from other sessions: its Codex copy would be visible to every Codex session. Pass --accept-shared-codex to install it anyway, or --shared.`
`kit update` never asks this question: an existing Codex agent copy is already shared, and it
stays that way.

Add the session function to `Baikai.Kit.Session`:

```haskell
-- Arguments a Codex launch by this tool adds so that its tool-only skills,
-- hidden from other Codex sessions, are visible in this one.
codexSessionArgs :: KitConfig -> IO [Text]
```

It reads the Codex skill sidecars of this tool at user scope and at the current project root,
through `providerAgentsBase`. It collects their `codexDisabledSkills` and returns
`enableSkillsArgs` of them. It returns `[]` when the tool does not list `InteractiveCodex` or
nothing is hidden. A consumer appends the result to the request's `extraArgs` for Codex launches
only, interactive or `codex exec`.

### Milestone 3: status, JSON, documentation, and release metadata

At the end of this milestone, a user can see each copy's visibility and any broken link or
config entry, and the documentation, version, ADR, and IR-12 record describe the new behaviour.

Write one function that both status and update use, following ADR 0022:

```haskell
data VisibilityCheck = VisibilityCheck
  { requested :: !(Maybe KitVisibility),  -- Nothing: installed before 0.4.0.0
    effective :: !KitVisibility,
    broken :: ![FilePath]                  -- recorded links or config paths that are missing or wrong
  }

checkVisibility :: KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError VisibilityCheck)
```

Effective visibility follows these rules:

- A Claude copy is shared when an *ours* link exists at its standard shared location, and
  tool-only otherwise.
- A Codex skill copy is tool-only when the Codex config has an `enabled = false` entry for its
  `SKILL.md`, and shared otherwise.
- A Codex agent copy is always shared.

Read the Codex config once per `kit status` run, not once per row. Add the condition
`KitVisibilityBroken`, labelled `visibility-broken`, as the last constructor of `KitCondition`.
A row carries it when `broken` is non-empty, and `kit update` clears it. Add
`requestedVisibility :: Maybe KitVisibility` and `effectiveVisibility :: KitVisibility` to
`StatusRow`, and include both in `aggregateStatusRows`'s grouping key. Add a `VISIBILITY` column
to `renderStatusTable` after `PROVIDERS`. It shows the effective label, followed by
` (requested tool-only)` or ` (requested shared)` when the requested value is known and
differs. When any Codex skill row has no requested visibility and is effectively shared, end the
table with:

```text
Note: Codex skills installed before baikai-kit 0.4.0.0 are visible to every Codex session.
Reinstall one with 'kit install NAME --tool-only' to limit it to this tool's sessions.
```

In `Baikai.Kit.Json`:

- Add `"requestedVisibility"` (the label or `null`) and `"effectiveVisibility"` (the label) to
  each `statusDocument` item.
- Add `"visibility"` (the declared default label, `"tool-only"` when the key is absent) to each
  `listDocument` item.
- Keep `kitJsonFormatVersion = 1`.

Extend `withStatusFixture` with one shared Claude skill and one item whose link has been
deleted. Regenerate the three goldens with `BAIKAI_KIT_ACCEPT_GOLDEN=1`, read the diff, and
confirm that it only adds keys and the new condition value.

Update `docs/user/kit.md`:

- Replace the paragraph "Claude Code assets install below the tool's agent base … Codex assets
  install into Codex-native discovery roots" with a **Visibility** section. It contains the
  two-by-two table from IR-12 and the manifest key, plus the flags, the Claude link layout, the
  Codex config entry, the agent refusal, and the name-protection rule.
- Add `visibility` to the Manifest example.
- Add `codexSessionArgs` to Session Discovery with a short example that sets `extraArgs` on a
  Codex `InteractiveLaunchRequest`.
- Add the new condition and column to Status And Sidecars, and the new sidecar fields.
- Add the shared and tool-only checks to Smoke Checks.

Per ADR 0017, resolve every name in a new or changed `haskell` fence in
`cabal repl baikai-smoke:test:doc-shapes` and paste the transcript into this plan.

Bump `baikai-kit/baikai-kit.cabal` to `version: 0.4.0.0`. Add a `## [baikai-kit 0.4.0.0] -
Unreleased` block under `## [Unreleased]` in `CHANGELOG.md` with Added, Changed (breaking), and
Fixed (the Codex root takeover) entries. Write
`docs/adr/0025-kit-visibility-is-honoured-per-provider-or-refused.md` with the frontmatter
style of ADR 0021 and add its row to `docs/adr/README.md`. The ADR's decision: visibility is
per item and independent of scope, each provider honours it or the kit refuses, the kit never
takes over a shared name, and every link and config entry is recorded in a sidecar and
reconciled by one check.

Update IR-12. In `docs/improvement-requests/let-a-kit-item-choose-tool-only-or-shared-visibility.md`,
set `status: completed` and rewrite its Status section to map each acceptance criterion to the
test or check below. Append a `* **Completion**:` entry to
`docs/improvement-requests/log.md` **by hand** under a new dated heading, in the style of the
IR-11 entry, because `okf log add` rewrites every existing entry. Releasing to Hackage is
outside this plan.


## Concrete Steps

Run everything from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, inside the Nix
development shell (`nix develop`, or direnv), which provides GHC 9.12 and cabal.

Build and test the package after each milestone:

```bash
cabal build baikai-kit
cabal test baikai-kit
```

A passing run ends like this (the count grows as tests are added):

```text
All 112 tests passed (0.84s)
Test suite baikai-kit-test: PASS
```

Run one group while iterating:

```bash
cabal test baikai-kit --test-options='-p "/visibility/"'
```

Regenerate the goldens in Milestone 3, then inspect the diff:

```bash
BAIKAI_KIT_ACCEPT_GOLDEN=1 cabal test baikai-kit
git diff baikai-kit/test/golden/
```

The tests set `HOME` to a temporary directory. Codex's config location also depends on
`CODEX_HOME`, so every test touching the Codex config must set `CODEX_HOME` to
`<temp home>/.codex` and restore it afterwards, the way `withFreshHome` restores `HOME`.
Otherwise a developer's real `~/.codex/config.toml` could be read or edited. Add a
`withCodexHome` wrapper that sets both and use it in every Milestone 2 test.

Before the final commit, run the whole repository suite and the formatter:

```bash
cabal test all
nix fmt
```

The pre-commit hook runs treefmt and reflows a staged `.cabal` file into the repository's
layout. Keep its output; do not fight it.

Commit at each milestone with a Conventional Commit message and both trailers, for example:

```text
feat(kit): let a kit item declare shared visibility on Claude Code

Add KitVisibility, the manifest "visibility" key, kit install --shared/--tool-only,
tracked ~/.claude/skills links that update repairs and uninstall removes, and refuse
to replace a shared name the kit did not create.

ExecPlan: docs/plans/88-let-a-kit-item-choose-tool-only-or-shared-visibility.md
Intention: intention_01m3wxm567effr24vt0j7cbn45
```


## Validation and Acceptance

Each IR-12 acceptance criterion maps to tests in `baikai-kit/test/Main.hs`. Put the new tests in
a `testGroup "visibility"` so the `-p` filter above selects them. Every test runs against a
temporary `HOME` (and `CODEX_HOME` where relevant) with `testConfig` and a project root inside
the temporary directory.

Milestone 1 tests (IR-12 acceptance 1, 2, 5, 6):

- `a manifest item without visibility installs tool-only`: install `demo` at user scope.
  `~/.config/testkit/agents/.claude/skills/demo/SKILL.md` exists, and `~/.claude/skills/demo`
  does not. The sidecar records `visibility = "tool-only"` and `visibilitySource = "manifest"`.
- `a shared item links into ~/.claude/skills`: with `"visibility": "shared"` on `demo`,
  `~/.claude/skills/demo` is a symbolic link whose target is the absolute tool-namespaced
  directory, and reading `~/.claude/skills/demo/SKILL.md` returns the installed content.
- `a project-scope shared item uses a relative link`: `<root>/.claude/skills/demo` is a link
  whose target is `../../.testkit/agents/.claude/skills/demo`.
- `kit install --shared overrides the manifest and update keeps it`: after the change,
  `kit update` with the manifest still declaring tool-only leaves the link in place.
- `update follows a changed manifest default`: install without a flag, change the manifest to
  shared, run `reinstallPresent`, and the link appears.
- `update changes linked content without touching the link`: record the link's target with
  `getSymbolicLinkTarget` and its modification time with `getSymbolicLinkMetadata`, change the
  cached `SKILL.md` and its version, and run `reinstallPresent`. The target string and link
  metadata are unchanged, and the content read through the link is new.
- `update recreates a deleted link`: remove `~/.claude/skills/demo`, run `reinstallPresent`, and
  the link is back. Add the same test for an item skipped for local edits.
- `uninstall removes the link and nothing else`: a sibling `~/.claude/skills/other/` created by
  the test survives, and `linksRemoved` names exactly the one link.
- `a shared install refuses a foreign skill directory`: pre-create `~/.claude/skills/demo/` with
  a file. Install returns `Left (KitSharedNameTaken …)`, the directory's contents hash the same
  before and after, and no tool-namespaced copy was written.
- `a shared install names the owning tool`: pre-create `~/.claude/skills/demo` as a link into
  `~/.config/rei/agents/.claude/skills/demo`. The error's owner is `Just "rei"`.
- `a Codex install refuses a skill directory without this tool's sidecar`: pre-create
  `~/.agents/skills/demo/SKILL.md`. Install fails with `KitSharedNameTaken` and leaves the file
  byte-identical.
- `the parser accepts --shared, --tool-only and --accept-shared-codex`: the three parse,
  `--shared --tool-only` together fails, and the plain `kit install demo` yields
  `defaultInstallOptions`.
- `an unknown visibility value is an invalid manifest`.

Milestone 2 tests (IR-12 acceptance 3 and 6):

- `a tool-only Codex skill adds one disabled config entry`: after install,
  `$CODEX_HOME/config.toml` parses. It has exactly one `[[skills.config]]` with the absolute
  `~/.agents/skills/demo/SKILL.md` path and `enabled = false`, and the sidecar records it.
- `the config edit preserves the user's text`: seed the config with comments, a
  `[projects."/x"]` table, and a user `[[skills.config]]` entry. After install and uninstall the
  file is byte-identical to the seed.
- `a shared Codex skill writes no config entry`, and switching a tool-only install to `--shared`
  removes the entry it had added.
- `codexSessionArgs re-enables exactly this tool's hidden skills`: with one user-scope and one
  project-scope tool-only skill, the result is
  `["-c", "skills.config=[{path=\"<abs user SKILL.md>\",enabled=true},{path=\"<abs project SKILL.md>\",enabled=true}]"]`
  (compare after parsing the value with `toml-parser`, not as a string). It is `[]` for a
  Claude-only config.
- `a symlinked Codex config is refused untouched`: make `config.toml` a link. Install of a
  tool-only skill fails with `KitCodexConfigUnusable`, the message contains the block to add by
  hand, nothing is written, and the link and its target are unchanged.
- `an inline skills.config array is refused`: seed `skills.config = []` under `[skills]`.
  Install fails with `KitCodexConfigUnusable` and the file is unchanged.
- `an existing enabled=true entry is refused`, and `an existing enabled=false entry is reused
  and survives uninstall`.
- `update re-adds a deleted config entry`.
- `a tool-only agent with Codex is refused without acceptance`: installing `reviewer` fails with
  `KitCodexCannotIsolate "reviewer"` and writes nothing for either provider.
- `--accept-shared-codex installs it`, and so does a `confirmSharedCodex` stub returning `True`.
  A stub returning `False` refuses. A Claude-only config installs it without asking.
- `the TOML escaper round-trips a path with a quote and a backslash`.

Manual Codex check (IR-12 acceptance 3, run once at Milestone 2 and record the output in
Progress). It needs `codex` on `PATH` and makes no API call. In a scratch directory, with
`HOME` and `CODEX_HOME` pointing inside it, install a tool-only skill named `vis-check` with a
small driver: `cabal repl baikai-kit` calling `installItem` with a local `file://` kit, or any
consumer tool built against this tree. Then run:

```bash
HOME=$S/home CODEX_HOME=$S/home/.codex codex debug prompt-input hi | grep -c 'vis-check:'
HOME=$S/home CODEX_HOME=$S/home/.codex codex debug prompt-input -c "skills.config=[{path=\"$S/home/.agents/skills/vis-check/SKILL.md\",enabled=true}]" hi | grep -c 'vis-check:'
```

Expect `0`, then `1`. The second command's argument must be exactly what `codexSessionArgs`
returned.

Optional manual Claude check (IR-12 acceptance 2): after a user-scope shared install in your
real home, start a plain `claude` session in any directory and confirm that `/skills` (or asking
it to list its skills) shows the item. Uninstall afterwards.

Milestone 3 tests (IR-12 acceptance 4):

- `status reports requested and effective visibility`: in the extended fixture, the shared
  Claude skill reads `shared`, the default skill's Claude copy reads `tool-only`, its Codex copy
  reads `tool-only` (config entry present), and a pre-0.4 Codex copy reads requested `null` and
  effective `shared`.
- `a deleted link reports visibility-broken and update clears it`.
- `status table prints the legacy Codex note only when a legacy Codex skill is shared`.
- The three goldens match after regeneration, with `formatVersion` still `1`.

Final acceptance is `cabal test all` passing, plus the manual Codex transcript recorded in
Progress. IR-12 acceptance 7 (consumers need only a version bump) is shown by the changelog,
which lists exactly which constructors changed. A tool that builds its integration from
`kitConfig`, `kitCommandParser`, and `runKit`, as `docs/user/kit.md` instructs, compiles
unchanged.


## Idempotence and Recovery

Every step can be rerun. Running `kit install` twice with the same options leaves one link and
one config entry, because ownership checks treat the kit's own link and its own recorded entry
as already present. `kit update` is the repair command for any half-applied visibility, and
`KitVisibilityNotApplied` says so.

The Codex config edit is the only change outside a tool-owned directory, which is why it is
guarded:

- It is never applied unless the parsed result differs from the original by exactly one entry.
- It is written by atomic rename, so a crash leaves either the old file or the new one.
- It refuses a symlinked file.

If a test or manual run ever damages a real config, the user's previous file is not backed up
by the kit, so tests must isolate `CODEX_HOME` as Concrete Steps requires. During manual checks,
copy `~/.codex/config.toml` aside first if you point `CODEX_HOME` at your real home.

Each milestone is one or more commits. To abandon a milestone, `git revert` its commits. The
goldens and the ADR live in the same commits as the code that needs them.


## Interfaces and Dependencies

New dependency: `toml-parser ^>=2.0.2` (Hackage, by Eric Mertens), used only by
`Baikai.Kit.CodexConfig` for parsing and comparing. It is never used to print the user's file.

New and changed public interface of `baikai-kit` 0.4.0.0. The changelog lists each item.

```haskell
-- Baikai.Kit.Visibility (new)
data KitVisibility = ToolOnlyVisibility | SharedVisibility
data VisibilitySource = FromManifest | FromInstallFlag
visibilityLabel :: KitVisibility -> Text
parseVisibility :: Text -> Either Text KitVisibility

-- Baikai.Kit.Manifest
SkillEntry { …, visibility :: Maybe KitVisibility }
AgentEntry { …, visibility :: Maybe KitVisibility }
itemVisibility :: KitItem -> KitVisibility

-- Baikai.Kit.Sidecar
SidecarMeta { …, visibility, visibilitySource :: Maybe Text,
                 sharedLinks, codexDisabledSkills :: Maybe [Text] }

-- Baikai.Kit.Config
KitConfig { …, confirmSharedCodex :: Maybe (KitItem -> IO Bool) }   -- Nothing in kitConfig
sharedClaudeBase :: KitConfig -> KitScope -> IO FilePath

-- Baikai.Kit.Install
data InstallOptions = InstallOptions { visibility :: Maybe KitVisibility, acceptSharedCodex :: Bool }
defaultInstallOptions :: InstallOptions
installItem :: KitConfig -> Text -> KitScope -> InstallOptions -> IO (Either KitError KitItem)
installFrom :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> InstallOptions -> IO (Either KitError KitItem)
RemovalOutcome { …, linksRemoved :: [FilePath], configEntriesRemoved :: [FilePath] }
data VisibilityCheck = VisibilityCheck { requested :: Maybe KitVisibility, effective :: KitVisibility, broken :: [FilePath] }
checkVisibility :: KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError VisibilityCheck)

-- Baikai.Kit.CodexConfig (new)
codexConfigPath :: IO FilePath
readSkillEntries :: FilePath -> IO (Either KitError [(FilePath, Bool)])
addDisabledSkill, removeDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)
enableSkillsArgs :: [FilePath] -> [Text]

-- Baikai.Kit.Session
codexSessionArgs :: KitConfig -> IO [Text]

-- Baikai.Kit.Command
KitInstall !(Maybe Text) !KitScope !InstallOptions

-- Baikai.Kit.Error
KitSharedNameTaken FilePath (Maybe Text)
KitCodexConfigUnusable FilePath Text
KitCodexCannotIsolate Text
KitVisibilityNotApplied Text [FilePath]

-- Baikai.Kit.Status
KitVisibilityBroken                       -- label "visibility-broken", last constructor
StatusRow { …, requestedVisibility :: Maybe KitVisibility, effectiveVisibility :: KitVisibility }
```

`checkVisibility` may live in `Baikai.Kit.Install` beside `checkLocalEdits`, which keeps the
dependency direction Status → Install that exists today.

The consumer-side contract that IR-12 acceptance 7 depends on is unchanged in shape: a tool
builds `kitConfig …`, wires `kitCommandParser config` and `runKit config`, and gains the new
flags and behaviour. A tool that launches Codex adds `Kit.codexSessionArgs config` to its
request's `extraArgs`. Without that, its tool-only Codex skills are hidden in its own sessions
too. `docs/user/kit.md` must say this prominently, because it is the one step a consumer has to
take beyond the version bump.
