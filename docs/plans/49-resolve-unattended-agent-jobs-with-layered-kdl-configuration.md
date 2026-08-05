---
id: 49
slug: resolve-unattended-agent-jobs-with-layered-kdl-configuration
title: "Resolve unattended agent jobs with layered KDL configuration"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Resolve unattended agent jobs with layered KDL configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Earlier plans in this initiative built the pieces needed to run a coding agent unattended: a way
to describe a run, a way to render it into a command line, and a way to execute it. What is still
missing is the reason the initiative exists at all — a way for a **repository to own the
description**, so a shell script can name a job instead of embedding provider flags.

This plan adds that. After it, a repository can contain `.baikai/agents.kdl` describing a named
job, an operator can contain `~/.config/baikai/agents.kdl` describing defaults and a **safety
limit**, and a program can ask for a job by name and receive a fully resolved run description —
together with a report saying, for every single value, which file and which line it came from.

The security shape matters more than the convenience. A repository configuration file is
**untrusted input**: an automation daemon that encounters a checkout is reading a file somebody
else wrote, and that file could ask for unrestricted filesystem access. So this plan implements two
separate loads with deliberately different rules. Job settings resolve through five layers, where
later layers win. The **safety ceiling** does not: it is read from the operator's own file and from
nowhere else, so no repository file, environment variable, or command-line flag can raise it. A job
that asks for more than the ceiling permits is refused with a message naming the requested value,
the permitted maximum, and where the ceiling came from.

Almost none of the hard part is written here, and that is the point. The `settei` library — a
first-party, published Haskell package for typed, layered, provenance-aware configuration — already
implements deterministic layer precedence, per-value origin tracking with exact file spans, and
secret redaction that survives into structured error messages. This plan declares what an
unattended job *is* and wires four sources into `settei`'s resolver. What it must build itself is
the ceiling, because bounding a value is not the same as layering one, and `settei` deliberately
does not do it.

**The observable outcome**, verifiable by running one test command: after this plan,
`cabal test baikai-agent-test` passes with cases that write KDL files into a temporary directory
and resolve a job from them. One proves a repository file's `provider` value beats a user file's,
and that the resolution report attributes it to the repository file with a line number. One proves
that a repository job asking for full filesystem access is refused under the default ceiling, while
the same job asking to edit its workspace is accepted. One proves that a command-line override
cannot raise the ceiling even though it can change every other setting. And one proves that raw
provider arguments render as `<redacted>` in the effective-configuration report.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (2026-08-05): Add the four `settei` dependencies to `baikai-agent`, and prove the
      KDL reader works end to end with a throwaway spike before designing the schema around it.
- [x] Milestone 2 (2026-08-05): Declare the job schema — `AgentJob`, its per-job `Config`, decoders,
      and the conversion to an `AgentRunRequest`.
- [x] Milestone 3 (2026-08-05): Implement scope discovery and the five-layer resolution order.
- [x] Milestone 4 (2026-08-05): Implement ceiling loading from user scope only, and apply it to
      every resolved job.
- [x] Milestone 5 (2026-08-05): Implement job enumeration with source attribution.
- [x] Milestone 6 (2026-08-05): Add tests for precedence, provenance, redaction, and ceiling
      refusal. 43 tests pass, 26 of them new.
- [x] Milestone 7 (2026-08-05): Document the schema and precedence rules, add changelog bullets, and
      run the full offline validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (Milestone 1, 2026-08-05): the KDL-to-key mapping is exactly as Context and Orientation
  described, and **hyphens are legal in key segments** — in job names as well as leaf names, so no
  word-separator change is needed. Reading the plan's own spike document produced this key set,
  every one of them carrying a path, a line, and a column:

  ```text
  jobs.sync-keiro-dsl.extra-dirs            array[2]   line 10, column 16
  jobs.sync-keiro-dsl.provider              text       line  8, column 14
  jobs.sync-keiro-dsl.safety.allowed-tools  array[2]   line 14, column 21
  jobs.sync-keiro-dsl.safety.capability     text       line 13, column 18
  jobs.sync-keiro-dsl.timeout               text       line 11, column 13
  jobs.sync-keiro-dsl.working-dir           text       line  9, column 17
  policy.allow-provider-args                bool False line  3, column 23
  policy.allowed-providers                  array[2]   line  4, column 21
  policy.max-capability                     text       line  2, column 18
  ```

  Three levels of nesting flatten correctly, so `safety { capability … }` reaches
  `jobs.<name>.safety.capability`; `#false` is the right KDL v2 boolean literal and arrives as
  `RawBool`; and `settei-kdl`'s span preservation reaches `Candidate`'s `Origin`, which is what
  Milestone 6's provenance assertion depends on.

- Discovery (Milestone 1, 2026-08-05): **a KDL node's argument count changes its raw type, so
  `listDecoder` alone would reject the plan's own documented example.** Spiking a second document
  showed a list-shaped node takes three different shapes:

  ```text
  extra-dirs                 -> RawNull        (zero arguments)
  extra-dirs "/tmp/only"     -> RawText        (one argument)
  extra-dirs "/one" "/two"   -> RawArray       (two or more arguments)
  ```

  `settei`'s `listDecoder` accepts `RawArray` and nothing else — `settei/src/Settei/Value.hs`
  matches `RawArray values` and falls through to `failure key "an array"`. So
  `extra-dirs "/path/one"`, which the Interfaces and Dependencies section of this plan writes
  verbatim as the documented single-directory form, would have failed to decode with "expected an
  array". The same trap catches every list-valued setting from the command line, because
  `cliOverride` always builds a `RawText`, meaning `--set jobs.demo.extra-dirs=/tmp/one` could
  never populate a list. Consequence: this plan defines its own `scalarOrListDecoder`, which maps
  `RawNull` to the empty list, a scalar to a one-element list, and an array elementwise. Every
  list-valued setting uses it; plain `listDecoder` is used nowhere.

- Discovery (Milestone 5, 2026-08-05): **`SourceKind` cannot tell the two configuration files
  apart**, so `AgentJobEntry`'s `scope` field could not have the type the Interfaces and
  Dependencies section gave it. `settei-kdl/src/Settei/Kdl.hs` line 230 builds every source it reads
  as `source (options ^. #name) (FileSource "KDL v2") root` — the `FileSource` payload names the
  *format*, not the path — so the user document and the repository document carry an identical
  `SourceKind`. What does distinguish them is `sourceName`, which is the label this plan passes to
  `kdlSourceOptions`. Consequence: this plan defines its own `AgentConfigScope` (`UserScope` /
  `RepositoryScope`) with a `renderAgentConfigScope` that doubles as the source label, and
  `AgentJobEntry` carries that instead of `SourceKind`. EP-6 should display this type rather than
  reaching for `SourceKind`, which would show `FileSource "KDL v2"` twice.

- Discovery (Milestone 6, 2026-08-05): **`renderResolutionText` names the source but drops the file
  location; only `renderResolutionJson` carries path, line, and column.** `Settei.Render` builds a
  `locationJson` object with `path`, `line`, and `column` for the JSON rendering and has no
  equivalent in the text rendering, which prints `from file source repository configuration
  (KDL v2)` and a `shadowed:` line and stops there. The spans really do survive from `settei-kdl`
  into the report — the JSON rendering proves it — so this is a renderer limitation, not lost
  provenance. Consequence: this plan's provenance test asserts the scope names against the text
  rendering and the line number against the JSON rendering. Consequence for EP-6: `agent show`
  cannot satisfy improvement-request acceptance criterion 5 by printing `renderResolutionText`
  alone. It must either emit the JSON rendering or walk `reportNodes` and render
  `origin ^. #location` itself.

- Discovery (Milestone 4, 2026-08-05): the ceiling test earns its keep. Mutating `loadAgentCeiling`
  to append the repository sources to the user sources — the exact one-line \"consistency fix\" the
  module's comment warns against — makes `A REPOSITORY FILE CANNOT RAISE THE CEILING` fail while
  every other test in the workspace keeps passing. The mutation was applied, the failure observed,
  and the module restored. This is the evidence that the plan's central security property is pinned
  by a test rather than only by a comment.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build on `settei` with KDL as the configuration format, rather than parsing KDL
  directly or hand-rolling a layering scheme.
  Rationale: the parts this plan needs are the parts that are dangerous to get wrong — layer
  precedence, per-value scope attribution, and secret redaction that holds inside error messages —
  and `settei` already implements all three, with published Hackage releases. KDL is also the
  established convention across this fleet. Dhall was rejected because repository configuration is
  untrusted input here and a format whose parser resolves imports enlarges that attack surface.
  TOML was rejected because its only real advantage was matching Codex's own `config.toml`, which
  is a weak reason next to reusing a first-party provenance-aware library. Recorded caveat: `settei`
  0.2.0.0 describes itself as experimental in its own README, and this adds four dependencies.
  Date: 2026-07-30

- Decision: The safety ceiling is loaded from **user scope only**, through a separate resolution
  that excludes the repository file, the environment, and command-line overrides.
  Rationale: a ceiling that any lower layer could raise is not a ceiling. If the repository file
  could set `policy.max-capability`, an untrusted checkout would grant itself whatever it liked; if
  a command-line override could, then `--set policy.max-capability=full-access` would defeat the
  entire mechanism, and that flag is exactly what a compromised automation script would add. The
  asymmetry between the two loads is the security property, so it must be visible in the code as
  two separate functions rather than one function with a flag.
  Date: 2026-07-30

- Decision: Job names are discovered dynamically from the loaded sources, and the `Config` for a job
  is built per name.
  Rationale: `settei`'s `Config a` describes a statically known set of keys, so a configuration
  containing an unknown number of named jobs cannot be one `Config`. Because a `Config` is an
  ordinary value, the plan builds one per job name with keys constructed as
  `jobs.<name>.provider` and so on. This keeps full per-value provenance, which decoding the whole
  document into an opaque map would lose — and provenance is the acceptance criterion.
  Date: 2026-07-30

- Decision: Repository configuration is read from `./.baikai/agents.kdl` in the current working
  directory only. No searching upward through parent directories.
  Rationale: an upward search means the effective configuration depends on where the process
  happened to start, and a job could silently pick up a file from a parent directory outside the
  repository it believes it is working in. For an untrusted-input file that grants filesystem
  authority, that is an unacceptable surprise. A caller who wants a different file passes an
  explicit path. Scripts already `cd` to their repository root; the first consumer does so on its
  third line.
  Date: 2026-07-30

- Decision: Declare the raw `provider-args` setting as **secret** in the `settei` schema.
  Rationale: it is the one field in the schema that can carry a credential — nothing stops an
  operator from writing `--api-key sk-…` there — and `settei` redacts a secret-classified value
  before it can enter a resolution report or a structured error. Every other field is structurally
  incapable of holding a secret, because environment variables are referenced by name and never by
  value, and the coding agents keep their own credentials in their own stores. The consequence,
  which must be documented, is that `agent show` displays raw provider arguments as `<redacted>`; an
  operator who needs to see them can read the file they wrote them in.
  Date: 2026-07-30

- Decision: Durations are written as a string with a unit suffix, such as `"45m"`, rather than as a
  bare number of seconds.
  Rationale: an unattended coding-agent run is measured in minutes, and `timeout 2700` invites a
  reader to guess whether the unit is seconds or milliseconds. A bare number is still accepted and
  means seconds, so a terse configuration is not rejected, but the documented form carries its unit.
  Date: 2026-07-30

- Decision: A default output limit is supplied by the built-in layer rather than left unbounded.
  Rationale: `Baikai.Agent`'s request type treats `Nothing` as unbounded, which is the honest
  meaning for a library. But an operator who never mentions a limit should not be one runaway agent
  away from exhausting memory, so the lowest configuration layer sets a concrete default that any
  higher layer can override or explicitly unset.
  Date: 2026-07-30

- Decision: The built-in layer is expressed as `settei` named default rules inside `agentJobConfig`,
  not as a synthetic `BuiltInSource`, which the Plan of Work's Milestone 3 had prescribed.
  Rationale: every job key contains the job name, so a built-in *source* would have to be rebuilt
  per name and could not be a module-level constant — and resolving job `b` against a built-in
  source constructed for job `a` would emit unknown-key warnings for every one of `a`'s keys. Named
  rules are name-independent, keep `agentJobConfig` complete and testable on its own without any
  source at all, and appear in the report with a rule name and a rationale
  (`from default rule inherit-output`), which is strictly more informative than `built-in`. The
  precedence semantics are identical: a default applies only when no source supplies the key, which
  is exactly "lowest layer". This also makes the job load consistent with the ceiling load, which
  the plan already specified as `withDefault` seeded from `defaultAgentCeiling`. The user guide's
  precedence table still lists built-in defaults as layer one, because that is what they are.
  Date: 2026-08-05

- Decision: Unsetting the output limit is spelled `output-limit "unlimited"` rather than
  `output-limit 0` or a KDL null.
  Rationale: the Decision Log above promises a higher layer can "explicitly unset" the default, and
  neither obvious spelling works. A KDL `#null` is a present value that fails to decode as an
  integer rather than reading as absent, and `0` is genuinely ambiguous — an operator could
  reasonably read it as "capture nothing". A word says what it means. This is also consistent with
  the neighbouring refusal of `timeout "0"`, where a zero was rejected precisely because its
  intended meaning was unguessable.
  Date: 2026-08-05

- Decision: `AgentJobEntry` carries Baikai's own `AgentConfigScope` and a `definingScopes` count,
  rather than `settei`'s `SourceKind` as the Interfaces section specified.
  Rationale: `settei-kdl` tags every document `FileSource "KDL v2"`, naming the format rather than
  the file, so `SourceKind` reports the user and repository documents identically and could not
  satisfy Milestone 5's own acceptance criterion. The count is included because Milestone 5 asked
  for the winner plus a count: a bare name with no indication that two files define it hides a real
  source of confusion.
  Date: 2026-08-05

- Decision: The four environment-variable bindings are a function of the job name,
  `agentEnvBindings :: Text -> Bindings`, rather than the module-level constant the Interfaces
  section showed.
  Rationale: a binding maps an environment variable to a configuration *key*, and every job key
  contains the job name, so a name-independent binding list cannot exist. The reference
  application's validate-once-and-force-in-a-test trick is preserved: the `error` on an invalid
  binding list is still inside the function, and the test suite forces `agentEnvBindings "probe"`,
  so a bad edit fails in tests rather than at start-up.
  Date: 2026-08-05

- Decision: The schema and the ceiling ship in one commit rather than the two the Concrete Steps
  section sketched.
  Rationale: both live in one module, `Baikai.Agent.Config`, so splitting them across commits would
  mean landing a file that does not compile or performing an artificial two-step edit of the same
  file. The reviewability the split was meant to buy is preserved a different way: the ceiling is a
  separate exported function with a separate source list and its own commented rationale, and it has
  five dedicated tests, two of them named in capitals. The commit message states both halves.
  Date: 2026-08-05


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository or of
the `settei` library.

Baikai is a multi-package Cabal workspace; Cabal is the Haskell build tool and each package is a
directory containing a `.cabal` file. This plan adds modules to one package, `baikai-agent`, which
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` created. That plan
must be complete before you start: you are adding files next to its `Baikai.Agent.Run` and adding
dependencies to the `.cabal` file it wrote. Add only your own modules and dependencies; do not
reorder or remove its entries.

### What earlier plans produced that you consume

`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` created
`baikai/src/Baikai/Agent.hs`. Read it before starting. This plan decodes configuration **into**
these types:

```haskell
data AgentProvider = AgentClaude | AgentCodex
renderAgentProvider :: AgentProvider -> Text
parseAgentProvider  :: Text -> Maybe AgentProvider

data AgentCapability = AgentReadOnly | AgentEditWorkspace | AgentFullAccess
renderAgentCapability :: AgentCapability -> Text
parseAgentCapability  :: Text -> Maybe AgentCapability

data AgentSafety = AgentSafety
  { capability :: !AgentCapability, allowedTools :: ![Text], providerArgs :: ![Text] }

data AgentCeiling = AgentCeiling
  { maxCapability :: !AgentCapability, allowProviderArgs :: !Bool
  , allowedProviders :: ![AgentProvider] }
defaultAgentCeiling :: AgentCeiling   -- edit-workspace, no raw args, both providers

data CeilingViolation
  = CapabilityExceeded !AgentCapability !AgentCapability
  | ProviderArgsForbidden ![Text]
  | ProviderForbidden !AgentProvider ![AgentProvider]
renderCeilingViolation :: CeilingViolation -> Text
applyAgentCeiling :: AgentCeiling -> AgentRunRequest -> Either [CeilingViolation] AgentRunRequest

data AgentRunRequest = AgentRunRequest
  { provider :: !AgentProvider, prompt :: !Text, modelId :: !(Maybe Text)
  , effort :: !(Maybe ThinkingLevel), workingDir :: !FilePath, extraDirs :: ![FilePath]
  , safety :: !AgentSafety, timeout :: !(Maybe NominalDiffTime)
  , output :: !AgentOutputMode, outputLimit :: !(Maybe Int), envPassthrough :: ![Text] }
agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest

data AgentOutputMode = InheritOutput | CaptureOutput | TeeOutput
parseAgentOutputMode :: Text -> Maybe AgentOutputMode
```

Note that `Baikai.Agent` is **not** re-exported from the umbrella module `baikai/src/Baikai.hs`,
so write `import Baikai.Agent` explicitly. `applyAgentCeiling` is already written and tested by
that plan; this plan's job is to *load* the ceiling and *call* it, not to re-implement the check.

Also note what the request does **not** contain: a job name, and an executable path. Those are
configuration concerns that belong to this plan's own record, described in Milestone 2.

### The settei library

`settei` is a first-party Haskell library, at `/Users/shinzui/Keikaku/bokuno/settei` on this
machine and published on Hackage. Its own one-line description is "typed, layered, explainable
configuration". Read its `README.md` and then
`examples/settei-cli/src/Settei/Example/Cli.hs`, which is a 289-line complete reference
application doing almost exactly what this plan needs. The four packages this plan uses, all at
version `0.2.0.0`:

- `settei` — the declaration algebra, the resolver, provenance, and report rendering.
- `settei-kdl` — reads a KDL v2 document into a source, preserving exact node spans.
- `settei-env` — explicit environment-variable bindings with injectable snapshots.
- `settei-optparse-applicative` — ordered command-line overrides.

The mental model has four parts.

A **`Setting a`** names one configuration key, says how to decode it, and declares whether it is
public or secret. Built with `publicSetting`, `publicShowSetting`, `secretSetting`, or
`publicSettingWithRenderer`, each taking a `Key`, a description, and a `Decoder a`.

A **`Config a`** is an applicative composition of settings describing a whole record. Built with
`required`, `optional`, `withDefault`, and `fallbackTo` from `Settei.Config`. It is an ordinary
value, which is what makes the per-job-name trick in Milestone 2 possible.

A **`Source`** is one layer of configuration. `Settei.Source.source` builds one from a `RawValue`
in memory, tagged with a `SourceKind` — `BuiltInSource`, `FileSource`, `EnvironmentSource`,
`CommandLineSource`, `DerivedSource`, or `CustomSource`. `Settei.Kdl.readKdlSource` builds one from
a file. `Settei.Env.environmentSource` builds one from bindings plus a snapshot.
`Settei.Optparse.cliSources` builds them from parsed overrides.

**`resolve`** takes options, a list of sources **ordered lowest to highest precedence**, and a
`Config a`, and returns a `ResolveResult a`:

```haskell
resolve :: ResolveOptions -> [Source] -> Config a -> ResolveResult a

data ResolveResult a = ResolveResult
  { answer :: !(Either (NonEmpty ConfigError) a),
    report :: !ResolutionReport,
    warnings :: ![ConfigWarning]
  }
```

The `report` is what makes `agent show` possible: `renderResolutionText` and
`renderResolutionJson` turn it into a per-key listing of the chosen value and its `Origin`, which
carries the `SourceKind`, the source name, and an optional `SourceLocation` with a path, line, and
column.

Two `settei` behaviors are load-bearing for this plan's safety story and you should not work around
either. A value declared `secretSetting` is converted to an opaque redacted form *before* it can be
retained in a report node or in a structural error, so it cannot leak through a diagnostic. And a
malformed value in a higher-precedence layer **fails resolution** rather than silently falling back
to a valid lower-precedence value — which means a typo in a repository file produces an error
rather than quietly activating an operator's default.

### How settei-kdl maps KDL to keys

You must know this before designing the schema, and Milestone 1 verifies it rather than trusting
this description. Nested KDL nodes become dot-separated keys. From
`/Users/shinzui/Keikaku/bokuno/settei/settei-kdl/test/fixtures/characterization/nested.kdl`:

```kdl
service {
  http {
    host "fixture.internal"
    port 8080
  }
}
```

That yields the keys `service.http.host` and `service.http.port`. A node with several positional
arguments becomes a list, as in `tags "api" "public"` from
`examples/settei-conformance/test/fixtures/service.kdl`, which yields a two-element list at
`service.tags`. KDL properties written `name=value` also become keys. One restriction the reader
enforces, visible in `settei-kdl/src/Settei/Kdl.hs`: positional arguments cannot be combined with
properties or child nodes on the same node, and doing so is a `KdlMixedNodeShape` error. Design the
schema so no node needs both.

`readKdlSource` has this shape:

```haskell
readKdlSource :: KdlSourceOptions -> FilePath -> IO (Either (NonEmpty KdlSourceError) Source)
kdlSourceOptions  :: Text -> KdlSourceOptions
withKdlSourcePath :: FilePath -> KdlSourceOptions -> KdlSourceOptions
renderKdlErrorsText :: NonEmpty KdlSourceError -> Text
```

`KdlSourceError` is deliberately secret-safe: it carries a category, a name, a path, a span, and a
concise message, and never retains a raw value or an excerpt of the document. When you surface one,
render it with `renderKdlErrorsText` and **do not append the original file content "for context"** —
`/Users/shinzui/Keikaku/bokuno/settei/docs/security.md` explains that this would defeat the
adapter's redaction.

### Enumerating what is in a source

`Settei.Source` exports `sourceLeaves :: Source -> [(Key, Candidate)]`, and `Settei.Key` exports
`keySegments` and `renderKey`. Milestone 5 uses these to list job names: take every leaf key whose
first segment is `jobs`, and collect the distinct second segments.

### Repository conventions

`baikai-agent` uses the same `.cabal` preamble as every other package: `default-language: GHC2024`
and `default-extensions: DeriveAnyClass, DuplicateRecordFields, OverloadedLabels,
OverloadedStrings`, with `-Wall -Wcompat -Wmissing-export-lists` among its warnings and no
`-Werror`. Field names carry no type prefix anywhere in this repository — write `provider`, not
`jobProvider`, and that applies to this plan's internal records too. Formatting is `nix fmt`,
running `fourmolu` with `fourmolu.yaml`.

Note that `settei` has its own prelude, `Settei.Prelude`, and its example application imports both
`Settei` and `Settei.Prelude`. Baikai has its own, `Baikai.Prelude`. Do not import both into one
module; import `Settei` and the specific `Settei.*` modules you need, and take Baikai's lens
vocabulary from `Baikai.Prelude` or from `Control.Lens` directly. If names collide, qualify.


## Plan of Work

Seven milestones. Milestone 1 is a spike that de-risks everything after it. Milestones 2 through 5
build the module in layers, each verifiable. Milestone 6 makes the behavior observable. Milestone 7
documents and validates.

### Milestone 1 — Spike the KDL reader before designing anything around it

Scope: add the dependencies and prove, with a throwaway test, exactly what `settei-kdl` produces
for a document shaped like the one this plan intends to use. At the end of this milestone the
Surprises & Discoveries section records the actual key set, and the schema in Milestone 2 is designed
against fact rather than against the description above.

This milestone exists because every later milestone depends on the KDL-to-key mapping, and a wrong
assumption there would be discovered late and force a schema redesign. Spend the small amount of
time.

Add to the library `build-depends` in `baikai-agent/baikai-agent.cabal`:

```cabal
    , settei                       ^>=0.2
    , settei-env                   ^>=0.2
    , settei-kdl                   ^>=0.2
    , settei-optparse-applicative  ^>=0.2
```

Also add `containers` — you will need `Data.Map.Strict` to build in-memory sources — and add
`settei` and `settei-kdl` to the test suite's `build-depends`.

Do **not** add `settei-formats`. It bundles YAML and Dhall loading behind a tagged
`FORMAT:PATH` interface, which would pull in dependencies this plan does not want, including a Dhall
parser that the Decision Log explicitly rejected for untrusted input. Use `settei-kdl` directly.

Verify the packages resolve. All four are published on Hackage at `0.2.0.0`, which matters because
`agents/skills/release/SKILL.md` requires every publishable package to resolve from Hackage only:

```bash
cabal build baikai-agent
```

Now write a temporary test that writes this document to a temporary directory and reads it back:

```kdl
policy {
  max-capability "edit-workspace"
  allow-provider-args #false
  allowed-providers "claude" "codex"
}
jobs {
  sync-keiro-dsl {
    provider "claude"
    working-dir "."
    extra-dirs "/tmp/one" "/tmp/two"
    timeout "45m"
    safety {
      capability "edit-workspace"
      allowed-tools "Read" "Write"
    }
  }
}
```

Read it with `readKdlSource (withKdlSourcePath path (kdlSourceOptions "spike")) path`, then print
`fmap (map fst . sourceLeaves)` of the result and assert nothing — just print. Run the test and
copy the actual key list into Surprises & Discoveries.

Check four things specifically and record each. That `jobs.sync-keiro-dsl.provider` is the key
shape, so nested nodes really do become dotted keys. That a hyphen is legal in a key segment — if
`KdlInvalidName` comes back, the schema must switch to a different word separator, and finding that
out now instead of in Milestone 2 is the whole point of this spike. That
`jobs.sync-keiro-dsl.extra-dirs` is a two-element list. And that the boolean literal form KDL v2
expects is what you wrote; adjust the schema documentation if `#false` is wrong for the parser
version in use.

Then delete the spike test. Its output now lives in the plan.

### Milestone 2 — Declare the job schema

Scope: create `baikai-agent/src/Baikai/Agent/Config.hs` with the job record, its per-name `Config`,
the decoders, and the conversion into an `AgentRunRequest`. At the end of this milestone
`cabal build baikai-agent` succeeds and a unit test can resolve a job from a single in-memory source.

First, decide what a job contains beyond what `AgentRunRequest` holds, and why. A job needs an
**executable path override**, because an operator may have `claude` installed somewhere unusual and
the request type has no field for it — the vendor configuration records
`ClaudeAgentConfig` and `CodexAgentConfig` do. A job also needs a **prompt source**, because the
request carries prompt *text* while a job describes where the text comes from. Everything else maps
onto request fields.

```haskell
data AgentJob = AgentJob
  { provider :: !AgentProvider,
    executable :: !(Maybe FilePath),
    modelId :: !(Maybe Text),
    effort :: !(Maybe ThinkingLevel),
    workingDir :: !FilePath,
    extraDirs :: ![FilePath],
    capability :: !AgentCapability,
    allowedTools :: ![Text],
    providerArgs :: ![Text],
    timeout :: !(Maybe NominalDiffTime),
    output :: !AgentOutputMode,
    outputLimit :: !(Maybe Int),
    envRequires :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
```

Flatten the safety fields into the job record rather than nesting an `AgentSafety`. The KDL document
still nests them under a `safety` node, so the *file* stays readable, but a flat Haskell record maps
one-to-one onto `settei` settings, which are addressed by dotted key and not by nested record. The
conversion function reassembles the `AgentSafety`.

Deliberately do **not** put a `name` field in the record. The name is how you looked the job up, not
a property of it, and storing it invites a mismatch between the two.

Now the per-job `Config`. Because `settei`'s `Config` describes statically known keys and a
configuration file holds an unknown number of jobs, build the `Config` from the job name:

```haskell
agentJobConfig :: Text -> Config AgentJob
agentJobConfig name =
  AgentJob
    <$> required (providerSetting name)
    <*> optional (executableSetting name)
    <*> optional (modelSetting name)
    <*> optional (effortSetting name)
    <*> required (workingDirSetting name)
    <*> withDefault [] (extraDirsSetting name)
    <*> required (capabilitySetting name)
    <*> withDefault [] (allowedToolsSetting name)
    <*> withDefault [] (providerArgsSetting name)
    <*> optional (timeoutSetting name)
    <*> required (outputSetting name)
    <*> optional (outputLimitSetting name)
    <*> withDefault [] (envRequiresSetting name)
```

Each setting builds its key from the name:

```haskell
jobKey :: Text -> Text -> Key
jobKey name leaf =
  either (error . show) id (parseKey ("jobs." <> name <> "." <> leaf))
```

Using `error` for an unparseable key is acceptable here **only** because the leaf names are
compile-time constants and the job name was itself obtained from a parsed key in Milestone 5, so a
failure means a programming error rather than bad input. Follow the precedent in
`/Users/shinzui/Keikaku/bokuno/settei/examples/settei-cli/src/Settei/Example/Cli.hs`, whose
`validKey` does the same, and force the value in a test so an invalid edit fails in tests rather
than at run time. But note the one real risk: a job name containing a dot or a character `parseKey`
rejects would throw. Validate job names when enumerating them in Milestone 5 and reject invalid ones
with a proper error there, so this function is only ever reached with a good name.

Write the decoders using `Settei.Value`'s combinators — `textDecoder`, `listDecoder`,
`boundedIntegralDecoder`, `boolDecoder`, `enumDecoder`, and `parsedDecoder`.

For the enumerations, prefer reusing `Baikai.Agent`'s own parsers over re-listing the strings, so
the configuration vocabulary cannot drift from the code vocabulary. Build them with `parsedDecoder`
over `parseAgentProvider`, `parseAgentCapability`, and `parseAgentOutputMode`. Use
`publicSettingWithRenderer` with the matching `render*` function so the resolution report prints
the canonical spelling.

For effort, `Baikai.ThinkingLevel` has `renderThinkingLevel` but check whether it has a parser; if
it does not, write a local `enumDecoder` over the six canonical names `minimal`, `low`, `medium`,
`high`, `xhigh`, and `max`, and note in a comment that the canonical list lives in
`baikai/src/Baikai/ThinkingLevel.hs` so a future level must be added in both places.

For the duration, write a decoder accepting a unit-suffixed string or a bare number:

```haskell
parseDuration :: Text -> Maybe NominalDiffTime
-- "90s" -> 90, "45m" -> 2700, "2h" -> 7200, "45" -> 45
```

Accept `s`, `m`, and `h`. Reject a negative value and reject zero, with a message saying a timeout
of zero is not a way to disable the timeout — omitting the setting is. Without that rejection,
`timeout "0"` would mean "kill every run immediately", which no operator intends and which would be
baffling to diagnose.

Declare `providerArgsSetting` with **`secretSetting`**, not `publicSetting`. The Decision Log
explains why: it is the only field that can carry a credential, and `settei` redacts a
secret-classified value before it can reach a report or an error. Every other setting is public.

Write the conversion into a request. It takes the prompt text, because the job describes
configuration and the prompt arrives at call time:

```haskell
agentJobRequest :: AgentJob -> Text -> AgentRunRequest
```

Build with `agentRunRequest (job ^. #provider) (job ^. #workingDir) promptText` and then set every
other field, reassembling `AgentSafety` from the three flattened fields. Do not apply the ceiling
here; that is Milestone 4's separate, explicitly named step, and burying it inside a conversion
function would make it easy to bypass by calling the conversion directly.

Add `Baikai.Agent.Config` to `exposed-modules` in `baikai-agent/baikai-agent.cabal`.

Verify with `cabal build baikai-agent` and one unit test that resolves a job from a single
in-memory `source` built with `RawObject` and `RawText`, following the `builtInSource` example in
`settei`'s reference application.

### Milestone 3 — Scope discovery and the five-layer order

Scope: implement locating the two configuration files and resolving a job across all five layers.
At the end of this milestone a test can prove that a repository value beats a user value and that a
command-line override beats both.

Define the paths explicitly:

```haskell
data AgentConfigPaths = AgentConfigPaths
  { userConfig :: !(Maybe FilePath),
    repoConfig :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

defaultAgentConfigPaths :: IO AgentConfigPaths
```

The user path is `$XDG_CONFIG_HOME/baikai/agents.kdl` when that variable is set, otherwise
`$HOME/.config/baikai/agents.kdl`. The `~/.config/<tool>` shape matches
`baikai-kit/src/Baikai/Kit/Config.hs`, which builds `home </> ".config" </> toolName`. The
repository path is `./.baikai/agents.kdl` relative to the current working directory, and **nothing
else** — the Decision Log explains why there is no upward search. Set each field to `Nothing` when
the file does not exist, so a missing file is a normal state rather than an error; an operator with
no user file must still be able to run a job.

Making the paths an explicit record with a pure resolution function underneath is what lets the
tests point at a temporary directory. Do not read `getHomeDirectory` inside the resolution path.

Build the built-in layer in memory, as `settei`'s reference application does with its
`builtInSource`. It supplies the defaults that make a terse job file work: output mode `inherit`,
an output limit, and an empty extra-directory list. It must **not** supply a provider, a working
directory, or a capability — those are `required`, and defaulting a capability would mean a job that
forgot to state its authority silently got some.

The built-in output limit is a concrete number rather than unbounded, for the reason in the
Decision Log. Choose a value large enough not to truncate a normal run — a few megabytes — define it
as a named top-level constant with a comment, and note that a job can override it or unset it.

Now the resolution function:

```haskell
resolveAgentJob ::
  AgentConfigPaths ->
  EnvSnapshot ->
  [CliOverride] ->
  Text ->
  IO (Either AgentConfigError (ResolveResult AgentJob))
```

Load each present file with `readKdlSource`, converting a `NonEmpty KdlSourceError` into your own
`AgentConfigError` via `renderKdlErrorsText`. Then resolve with the sources in this order, which
`settei` reads as lowest precedence first:

```haskell
resolve defaultResolveOptions
  ( [builtInSource]
      <> userSources
      <> repoSources
      <> [environmentSource agentEnvBindings snapshot]
      <> cliSources "arguments" overrides
  )
  (agentJobConfig name)
```

That is exactly the order the improvement request specifies: built-in defaults, user configuration,
repository configuration, environment, then explicit command-line flags. Write the order in a
comment next to the list, because the list is the only place it is expressed and a later reordering
would be a silent behavior change.

Define the environment bindings with `Settei.Env.bindings` and `binding`, following the
`environmentBindings` value in `settei`'s reference application — including its trick of validating
the binding list once at module level and forcing it in a test, so an invalid edit fails in tests
rather than at start-up. Bind a small, deliberately chosen set: the provider, the model, the
executable, and the timeout. Do **not** bind the capability, the tool list, or the provider
arguments. An environment variable is easy to set accidentally and is inherited by child processes;
letting one widen a job's authority would create exactly the kind of ambient influence the ceiling
exists to prevent. Note this reasoning in a comment.

Take the `EnvSnapshot` as a parameter rather than reading the real environment inside the function.
`settei-env` provides `envSnapshot` for injecting one, which is what makes the environment layer
testable without `setEnv`.

Accept `[CliOverride]` rather than parsing anything. `docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`
owns the command-line parser and will pass the parsed overrides in. This keeps this module free of
`optparse-applicative` wiring while still supporting the highest-precedence layer.

Verify with tests writing two KDL files to a temporary directory: a user file setting
`jobs.demo.provider` to `codex` and a repository file setting it to `claude`. Assert the resolved
provider is `AgentClaude`. Then pass a `CliOverride` setting it back to `codex` and assert
`AgentCodex`.

### Milestone 4 — Load the ceiling from user scope only

Scope: implement ceiling loading and the function that applies it. At the end of this milestone a
test can prove a repository job cannot exceed the operator's limit and that no lower layer can raise
it.

This is the security core of the plan and it is deliberately a **separate function with separate
sources**:

```haskell
agentCeilingConfig :: Config AgentCeiling

loadAgentCeiling :: AgentConfigPaths -> IO (Either AgentConfigError AgentCeiling)
```

`agentCeilingConfig` declares three settings at the keys `policy.max-capability`,
`policy.allow-provider-args`, and `policy.allowed-providers`, using `withDefault` seeded from
`defaultAgentCeiling` so an operator file that sets only one of the three still yields a complete
ceiling.

`loadAgentCeiling` resolves against **exactly two** sources: a built-in source encoding
`defaultAgentCeiling`, and the user file. It must not include the repository file, the environment
source, or command-line overrides. Write a comment above the source list saying so and why, in the
strongest terms the file will tolerate — this single list is the entire mechanism, and someone
"fixing an inconsistency" by adding the repository source here would silently remove the security
property while every test that does not specifically check it would keep passing.

Then the applying step:

```haskell
applyCeilingToJob ::
  AgentCeiling -> AgentRunRequest -> Either AgentRenderError AgentRunRequest
applyCeilingToJob ceiling request =
  case applyAgentCeiling ceiling request of
    Left violations -> Left (CeilingRejected violations)
    Right ok -> Right ok
```

The check itself is `Baikai.Agent.applyAgentCeiling`, already written and tested by
`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md`. This wrapper only converts the
violation list into the `AgentRenderError` shape that the command-line tool reports through, so
there is one error type on the path from configuration to rendered command. Do not re-implement the
comparison.

Also handle the ceiling's interaction with an absent user file: with no file, the ceiling is
`defaultAgentCeiling`, which permits read-only and edit-workspace capability and refuses full access
and raw provider arguments. That default is a MasterPlan-level decision recorded in
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`; do not change it
while implementing. It is what makes the first consumer work on a fresh machine without a setup step
while keeping the two authority-widening features opt-in.

Verify with tests. A repository job asking for `full-access`, with no user file, is refused, and the
message names both `full-access` and `edit-workspace`. The same job asking for `edit-workspace` is
accepted. A user file setting `policy.max-capability "full-access"` makes the first job succeed. And
the critical negative test: a **repository** file setting `policy.max-capability "full-access"` does
**not** raise the ceiling, and a command-line override attempting the same does not either. Those
last two are the tests that prove the security property, so name them so their purpose is
unmistakable.

### Milestone 5 — Enumerate jobs with source attribution

Scope: implement listing the configured job names and which scope each came from. At the end of this
milestone a test can prove a name defined in both files is reported once with the higher-precedence
scope.

```haskell
data AgentJobEntry = AgentJobEntry
  { name :: !Text,
    scope :: !SourceKind
  }
  deriving stock (Eq, Show, Generic)

listAgentJobs :: AgentConfigPaths -> IO (Either AgentConfigError [AgentJobEntry])
```

Load both files, then for each source use `sourceLeaves` to get its `(Key, Candidate)` pairs, take
`keySegments` of each key, keep those whose first segment is `jobs`, and collect the distinct second
segments. Return them sorted by name so output is stable across runs, which matters because a
script may diff it.

Attribute each name to the **highest-precedence** scope that defines it, so a job the repository
overrides is reported as coming from the repository. Sort the sources in the same precedence order
as Milestone 3 and let later ones win. Consider whether to report both scopes for a name defined in
both; prefer reporting the winner plus a count, and record the choice in the Decision Log — a bare
name with no indication that two files define it hides a real source of confusion.

This is also where job names are validated, closing the gap Milestone 2 noted about `jobKey`
throwing. A name segment that `parseKey` would reject cannot appear here, because it came *from* a
parsed key — but a name containing something the rest of the system cannot handle should still be
reported as a configuration error rather than passed on. Decide the rule, implement it, and note it.

Verify with a test where both files define `demo` and only the user file defines `user-only`,
asserting both names appear, sorted, with `demo` attributed to the repository file.

### Milestone 6 — Tests for precedence, provenance, redaction, and refusal

Scope: complete the test suite so every claim in this plan is pinned. At the end of this milestone
`cabal test baikai-agent-test` passes and the acceptance criteria are demonstrable.

Build a harness that writes KDL files into a temporary directory with `withSystemTempDirectory` and
constructs an `AgentConfigPaths` pointing at them. `docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`
already established temporary-directory testing in this package's suite; reuse its shape.

Beyond the tests named in Milestones 3, 4, and 5, add these.

A provenance test, which is the plan's headline capability and improvement-request acceptance
criterion 5. Resolve a job whose `provider` comes from the repository file and whose `timeout` comes
from the user file, then render the report with `renderResolutionText` and assert the output
attributes each key to the right file. Assert a **line number** appears for the repository value, so
the test proves `settei-kdl`'s span preservation is actually reaching the report rather than being
silently dropped.

A redaction test. Give a job a `provider-args` value containing a credential-looking string such as
`"--api-key sk-not-a-real-key"`, render both `renderResolutionText` and `renderResolutionJson`, and
assert with `assertBool` that neither output contains the substring `sk-not-a-real-key`. This is the
test that makes the secret classification from Milestone 2 real rather than decorative. Also assert
the key name itself *does* appear, since redacting the value should not hide that the setting was
set.

A malformed-value test. Give the repository file `capability "edit-worksapce"`, misspelled, and
assert resolution fails with an error naming the key — rather than silently falling back to a valid
user-file value. This pins `settei`'s no-silent-fallback behavior, which this plan depends on and
which a future dependency upgrade could regress.

A KDL syntax-error test. Write a file with unbalanced braces and assert the returned error is your
`AgentConfigError` carrying a rendered `settei-kdl` message. Assert the message does **not** contain
the file's full text, which pins the secret-safe error handling described in `settei`'s security
document.

A duration test table: `"90s"` is 90, `"45m"` is 2700, `"2h"` is 7200, a bare `"45"` is 45, and
`"0"`, `"-5m"`, and `"soon"` are all rejected.

A missing-file test: with both paths `Nothing`, resolving a job fails because required settings are
absent, and the error names them — not a crash and not a partially populated job.

A defaults test: a minimal job file stating only a provider, a working directory, and a capability
resolves successfully, with output mode `inherit`, the built-in output limit, and empty lists for
extra directories, tools, provider arguments, and required environment variables. This is what makes
a terse configuration file usable and is the counterpart to the runner's own defaults test.

A binding-validation test that forces the module-level environment bindings value, following the
comment in `settei`'s reference application explaining why: an invalid binding list should fail in
tests rather than at start-up.

### Milestone 7 — Documentation, changelog, and validation

Scope: document the file format and the precedence rules, record the change, and prove the workspace
is green offline.

The user guide for this surface is written by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`, which owns
`docs/user/unattended-agent-runs.md`. To avoid writing the same thing twice, create that file here
with only the sections this plan owns, and let the later plan add the command-line sections around
them. The sections you own:

The **file format**, with a complete commented example of both files. Show a repository
`.baikai/agents.kdl` containing the `sync-keiro-dsl` job that the initiative's first consumer needs,
and a user `~/.config/baikai/agents.kdl` containing a `policy` node. Give every setting, its type,
its default, and whether it is required.

The **precedence order**, stated as the five layers in order, with a worked example showing a value
set in three places and which one wins.

The **ceiling**, and this section deserves the most care. State that it is read from user scope only;
that no repository file, environment variable, or command-line flag can raise it; what the default is
when no user file exists; and that exceeding it is a refusal rather than a downgrade. Show the exact
refusal message. An operator needs to be able to predict this without reading Haskell.

The **redaction rule**: provider arguments are treated as secret and render as `<redacted>`, and every
other setting is public because none of them can hold a credential by construction.

Add bullets under `[Unreleased]` in the single root `CHANGELOG.md`, scoped to `baikai-agent`. Note
the four new `settei` dependencies, since a dependency addition is something a downstream consumer
may care about. This repository has one changelog for every package; do not create per-package
changelogs or dated release headings during feature work.

Update `agents/skills/release/SKILL.md` if needed: it requires publishable packages to resolve from
Hackage only, and all four `settei` packages do at `0.2.0.0`. Add a note recording that verification
and the version series, so a future release operator does not have to re-derive it.

Update the parent MasterPlan
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: set EP-5 to
`Complete`, check off its four Progress lines, and record the Milestone 1 spike findings in its
Surprises & Discoveries section — the command-line plan will be writing example configuration files
and needs the verified key shapes.

Then run the full validation in Concrete Steps.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, unless stated
otherwise.

After Milestone 1, confirm the dependencies resolve and the spike runs:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

If Cabal cannot find `settei`, refresh the package index with `cabal update` and confirm the
version: all four packages are at `0.2.0.0` on Hackage, verified by querying
`https://hackage.haskell.org/package/settei/preferred`, which returns
`{"normal-version":["0.2.0.0","0.1.0.0"]}`.

After each of Milestones 2 through 5:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

To resolve a job by hand and see its provenance, use the interactive interpreter. This reads files
and spawns nothing:

```bash
mkdir -p /tmp/baikai-demo/.baikai
cat > /tmp/baikai-demo/.baikai/agents.kdl <<'KDL'
jobs {
  demo {
    provider "claude"
    working-dir "/tmp/baikai-demo"
    timeout "10m"
    safety {
      capability "edit-workspace"
      allowed-tools "Read" "Edit"
    }
  }
}
KDL
cabal repl baikai-agent
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Baikai.Agent.Config
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text.IO qualified as TIO
import Settei (renderResolutionText)
import Settei.Env (envSnapshot)
let paths = AgentConfigPaths { userConfig = Nothing, repoConfig = Just "/tmp/baikai-demo/.baikai/agents.kdl" }
r <- resolveAgentJob paths (envSnapshot []) [] "demo"
case r of { Right res -> TIO.putStrLn (renderResolutionText (res ^. #report)); Left e -> print e }
-- expect a per-key listing whose provider line cites
--   /tmp/baikai-demo/.baikai/agents.kdl with a line number
ceiling <- loadAgentCeiling paths
ceiling
-- expect: Right (AgentCeiling {maxCapability = AgentEditWorkspace, allowProviderArgs = False, ...})
:quit
```

Then prove the ceiling cannot be raised from the repository file:

```bash
cat >> /tmp/baikai-demo/.baikai/agents.kdl <<'KDL'
policy {
  max-capability "full-access"
}
KDL
```

Re-run `loadAgentCeiling paths` in the interpreter. It must **still** return `AgentEditWorkspace`.
If it returns `AgentFullAccess`, the repository source has leaked into the ceiling load and the
plan's central security property is broken — stop and fix Milestone 4 before continuing.

Clean up with `rm -rf /tmp/baikai-demo`.

Full validation after Milestone 7. Two independent gates cause the `baikai-smoke` suite to make real
billable calls and both must be closed: provider API-key environment variables, and — as discovered
during the work recorded in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md` — the mere presence of
the `claude` or `codex` binary on `PATH`, because `baikai-smoke/test/Smoke.hs` gates its batch CLI
cases on `findExecutable` alone. This `zsh` command closes both while keeping the active toolchain:

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

Note one hazard specific to this plan: your tests must not depend on the real `HOME` or
`XDG_CONFIG_HOME`, because a developer with a real `~/.config/baikai/agents.kdl` would then get
different results from a clean machine. Every test constructs `AgentConfigPaths` explicitly. If a
test passes for you and fails in a clean environment, that is the cause.

Commit in two or three pieces — the schema, the layering, then the ceiling:

```text
feat(agent): resolve unattended jobs from layered KDL configuration

Declare the job schema over settei with KDL sources, and resolve it
across built-in, user, repository, environment, and command-line layers
with per-value provenance. Raw provider arguments are classified secret
and render redacted.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```

```text
feat(agent): cap repository job policy from user scope only

Load the safety ceiling from the operator's own configuration file and
from nowhere else, so no repository file, environment variable, or
command-line override can raise it. Exceeding it is refused, never
clamped.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan is accepted when all of the following hold.

`baikai-agent` depends on `settei`, `settei-env`, `settei-kdl`, and `settei-optparse-applicative`,
all at the `0.2` series, and not on `settei-formats`. `cabal build all` succeeds.

The Surprises & Discoveries section records the KDL key shapes the spike actually produced,
including whether hyphens are legal in key segments.

A job resolves across all five layers in the order built-in, user, repository, environment,
command-line, with later layers winning. A test proves a repository value beats a user value, and
that a command-line override beats both.

`renderResolutionText` of a resolution report attributes each chosen value to its source, and for a
value from a KDL file the attribution includes a line number.

A `provider-args` value containing `sk-not-a-real-key` does not appear in either
`renderResolutionText` or `renderResolutionJson` output, while the key name does.

A misspelled enumeration value in the repository file fails resolution with an error naming the key,
rather than silently falling back to a valid lower-precedence value. A KDL syntax error produces an
`AgentConfigError` whose message does not contain the file's contents.

With no user configuration file, the ceiling is `defaultAgentCeiling`: a job asking for
`edit-workspace` is accepted and one asking for `full-access` is refused with a message naming both
values. A user file raising `policy.max-capability` to `full-access` permits it.

**A repository file setting `policy.max-capability` does not change the ceiling, and neither does a
command-line override.** This is the plan's central security property and must have its own named
test.

`listAgentJobs` returns names sorted, with each attributed to the highest-precedence scope defining
it.

The duration decoder accepts `"90s"`, `"45m"`, `"2h"`, and a bare number as seconds, and rejects
zero, negatives, and unparseable text.

A minimal job stating only a provider, a working directory, and a capability resolves, with output
mode `inherit`, the built-in output limit, and empty lists elsewhere.

No test reads the real `HOME` or `XDG_CONFIG_HOME`; every test constructs `AgentConfigPaths`
explicitly.

`docs/user/unattended-agent-runs.md` documents the file format with a complete example of both
files, the five-layer precedence order with a worked example, the ceiling's user-scope-only rule and
its default, and the redaction rule. The root `CHANGELOG.md` has `baikai-agent` bullets under
`[Unreleased]` noting the new dependencies. The parent MasterPlan shows EP-5 complete.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`, and
`nix flake check` all succeed. No acceptance step invokes a live model or a coding-agent binary.


## Idempotence and Recovery

Every change is additive within `baikai-agent`: new modules, new dependencies, new tests, one new
documentation file, and changelog bullets. No existing module changes behavior, so every existing
test must keep passing. The only edits outside the package are the changelog, the new user guide, the
release skill note, and the parent MasterPlan.

All commands are safe to repeat. Tests write only into temporary directories created by
`withSystemTempDirectory`, which removes them even on failure. The manual demonstration writes under
`/tmp/baikai-demo`; remove it with `rm -rf /tmp/baikai-demo` when finished. Nothing contacts a
provider or mutates remote state.

The milestones are separable. Milestone 2's schema builds and tests without any file loading;
Milestone 3 adds files; Milestone 4's ceiling is an independent function. Committing after Milestone
2 or 3 leaves the workspace green because nothing outside this package imports the new module yet.

One recovery note. If the Milestone 1 spike reveals a KDL mapping different from the description in
Context and Orientation — most plausibly that hyphens are not legal in key segments — do not work
around it in the decoders. Change the schema's word separator, update every example in this plan and
in the user guide, and record the change in a revision note at the bottom of this plan. A schema
that fights its own parser will produce confusing errors for every future operator.

To roll back, revert the commits. Nothing imports `Baikai.Agent.Config` at the end of this plan;
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` is its first caller.


## Interfaces and Dependencies

Four new dependencies, added to `baikai-agent/baikai-agent.cabal`: `settei ^>=0.2`,
`settei-env ^>=0.2`, `settei-kdl ^>=0.2`, and `settei-optparse-applicative ^>=0.2`, plus
`containers` for the job-name map and set, and `filepath` for joining the configuration paths. All
four `settei` packages are published on Hackage at `0.2.0.0` — confirmed by resolving and building
them from Hackage during this work — which satisfies the Hackage-only rule in
`agents/skills/release/SKILL.md`. `settei-formats` is deliberately excluded: it would pull in YAML
and Dhall loading, and Dhall was rejected for untrusted input.

At completion, `baikai-agent/src/Baikai/Agent/Config.hs` exports:

```haskell
-- The configured shape of one job
data AgentJob = AgentJob
  { provider :: !AgentProvider, executable :: !(Maybe FilePath)
  , modelId :: !(Maybe Text), effort :: !(Maybe ThinkingLevel)
  , workingDir :: !FilePath, extraDirs :: ![FilePath]
  , capability :: !AgentCapability, allowedTools :: ![Text], providerArgs :: ![Text]
  , timeout :: !(Maybe NominalDiffTime), output :: !AgentOutputMode
  , outputLimit :: !(Maybe Int), envRequires :: ![Text] }

agentJobConfig  :: Text -> Config AgentJob          -- keys built from the job name
agentJobRequest :: AgentJob -> Text -> AgentRunRequest  -- second argument is the prompt

-- Where configuration lives
data AgentConfigPaths = AgentConfigPaths
  { userConfig :: !(Maybe FilePath), repoConfig :: !(Maybe FilePath) }
defaultAgentConfigPaths :: IO AgentConfigPaths
  -- user: $XDG_CONFIG_HOME/baikai/agents.kdl, else $HOME/.config/baikai/agents.kdl
  -- repo: ./.baikai/agents.kdl in the working directory only, no upward search

-- Five-layer resolution: built-in < user < repository < environment < command line
resolveAgentJob ::
  AgentConfigPaths -> EnvSnapshot -> [CliOverride] -> Text ->
  IO (Either AgentConfigError (ResolveResult AgentJob))

-- The ceiling: user scope only, deliberately excluding repository, environment, and CLI
agentCeilingConfig :: Config AgentCeiling
loadAgentCeiling   :: AgentConfigPaths -> IO (Either AgentConfigError AgentCeiling)
applyCeilingToJob  :: AgentCeiling -> AgentRunRequest -> Either AgentRenderError AgentRunRequest

-- Enumeration. The scope is Baikai's own type, not settei's SourceKind:
-- settei-kdl tags every document FileSource "KDL v2", naming the format
-- rather than the file, so the two documents are identical by kind.
data AgentConfigScope = UserScope | RepositoryScope
renderAgentConfigScope :: AgentConfigScope -> Text   -- doubles as the source label
data AgentJobEntry = AgentJobEntry
  { name :: !Text, scope :: !AgentConfigScope, definingScopes :: !Int }
listAgentJobs :: AgentConfigPaths -> IO (Either AgentConfigError [AgentJobEntry])

-- Errors from loading, distinct from resolution errors which settei reports
data AgentConfigError
  = ConfigFileUnreadable !FilePath !Text   -- rendered settei-kdl diagnosis, never the document
  | InvalidJobName !Text !Text
renderAgentConfigError :: AgentConfigError -> Text

-- Exported for testing
parseDuration      :: Text -> Maybe NominalDiffTime
agentEnvBindings   :: Text -> Bindings    -- per job name: every key contains it
defaultOutputLimit :: Int                 -- 4194304
scalarOrListDecoder :: Decoder a -> Decoder [a]
validateJobName    :: Text -> Either AgentConfigError ()
```

The KDL schema, which the user guide documents and the tests pin:

```kdl
// ~/.config/baikai/agents.kdl — operator scope. The policy node is read from
// here and nowhere else; no repository file or flag can raise it.
policy {
  max-capability      "edit-workspace"   // read-only | edit-workspace | full-access
  allow-provider-args #false
  allowed-providers   "claude" "codex"
}

// ./.baikai/agents.kdl — repository scope. Untrusted input, capped by the policy above.
jobs {
  sync-keiro-dsl {
    provider     "claude"          // required: claude | codex
    working-dir  "."               // required
    executable   "/usr/bin/claude" // optional override
    model        "sonnet"          // optional
    effort       "high"            // optional: minimal|low|medium|high|xhigh|max
    extra-dirs   "/path/one"       // optional list
    timeout      "45m"             // optional: 90s | 45m | 2h | bare seconds
    output       "inherit"         // inherit | capture | tee   (default inherit)
    output-limit 4194304           // bytes per stream, or "unlimited" (default 4194304)
    env-requires "KEIRO_PATH"      // names only; never values
    safety {
      capability    "edit-workspace"        // required
      allowed-tools "Read" "Write" "Edit"   // optional; refused for codex
      provider-args "--betas" "context-1m"  // optional; SECRET, needs operator opt-in
    }
  }
}
```

The precedence contract:

```text
layer              expressed as             can set job settings   can set the ceiling
built-in defaults  settei named default     yes                    yes (the default)
                   rules in the Config
user file          FileSource "KDL v2"      yes                    yes
repository file    FileSource "KDL v2"      yes                    NO
environment        EnvironmentSource        provider/model/exe/timeout only   NO
command line       CommandLineSource        yes                    NO
```

The built-in layer is a set of named default rules inside `agentJobConfig` rather than a synthetic
`BuiltInSource`, because every job key contains the job name and a source would therefore have to be
rebuilt per name. The precedence semantics are unchanged — a default applies only when no source
supplies the key — and the report attributes such a value to its rule, for example
`from default rule inherit-output`. See the Decision Log.

Downstream impact: none yet. Nothing imports `Baikai.Agent.Config` at the end of this plan.
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` is its first caller and
adds the `executable baikai` stanza plus `optparse-applicative` to the same `.cabal` file; add only
your own modules and dependencies so the two plans do not collide.


## Outcomes & Retrospective

The plan is complete and every acceptance criterion holds. `baikai-agent` gained one exposed module,
`Baikai.Agent.Config`, and one test module, `ConfigTests`, taking the package's suite from 17 tests
to 43. `nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`,
and `nix flake check` all pass. No acceptance step invoked a live model or a coding-agent binary.

Against the original vision. A repository can now own a job description and an operator can now cap
it, which is the reason the initiative exists; the layering, the provenance, the redaction, and the
refusal all behave as designed. The estimate that "almost none of the hard part is written here" held
— `settei` supplied precedence, provenance, and secret redaction, and the code this plan added is
mostly a schema plus two carefully-different source lists.

What the plan got wrong, all of it caught by Milestone 1 existing at all or by writing the tests.
Three of the Interfaces section's signatures could not be implemented as written: `agentEnvBindings`
had to become a function of the job name, `AgentJobEntry.scope` could not be `settei`'s `SourceKind`,
and the built-in layer could not be a `BuiltInSource` — each for the same underlying reason, that a
job name is part of every key and that `settei-kdl` names formats rather than files. The Decision Log
records each. The spike also caught that the plan's own documented `extra-dirs "/path/one"` example
would not have decoded, which would have been discovered by an operator rather than by a test if
Milestone 1 had been skipped.

What is worth carrying forward. The mutation check on `loadAgentCeiling` — appending the repository
sources and confirming exactly one test turns red — is the only evidence that the module's central
security property is enforced rather than merely commented, and it took two minutes. Any future
change to that source list deserves the same check.

Two things a later plan must pick up. `renderResolutionText` drops file locations, so EP-6's
`agent show` cannot satisfy improvement-request acceptance criterion 5 by printing it alone. And
`settei` 0.2.0.0 still self-describes as experimental in its own README; the four dependencies are
pinned `^>=0.2` and a 0.3 series should be read before it is adopted.


## Revision Notes

- 2026-08-05: Implemented. Four deviations from the plan as written, each recorded in the Decision
  Log with its rationale and reflected in the Interfaces and Dependencies section above: the built-in
  layer is named default rules rather than a synthetic `BuiltInSource`; `AgentJobEntry.scope` carries
  a new `AgentConfigScope` rather than `settei`'s `SourceKind`, and gained a `definingScopes` count;
  `agentEnvBindings` takes the job name; and the schema and ceiling shipped in one commit rather than
  two because they share one module. One addition the plan did not anticipate: `scalarOrListDecoder`,
  without which no single-element list and no list-valued `--set` override would decode. `filepath`
  was added as a fifth new dependency alongside `containers`.
