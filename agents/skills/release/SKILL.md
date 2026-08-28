---
name: release
description: Cut a release of the baikai Haskell packages and publish them to Hackage following PVP. Packages version independently, publish in dependency order (baikai first), and are tagged per-package. baikai-agent additionally ships the `baikai` command-line tool, which carries extra verification. The release also moves the docs that name a published version — the README's Hackage column and the `docs/capabilities/` catalog's `since` fields — and validates the OKF bundles. Run manually when shipping a new version.
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Release baikai to Hackage

This skill walks an operator through cutting a release of this repository's
Haskell packages and publishing them to [Hackage](https://hackage.haskell.org/),
following the Haskell **PVP** (`A.B.C.D`).

Packages in this repo **version independently** — each one bumps on its own
changes and carries its own per-package git tag. Treat each publishable package
as a separate release decision; you may release one, several, or all of them in
a single run.

## Pre-flight dependency check — read first

This repository must publish packages that resolve from Hackage only. Do not
ship a release while any publishable package depends on a GitHub
`source-repository-package` pin or on dependency versions that are not available
from Hackage.

Historically, this project briefly pinned the unreleased `streamly 0.12` /
`streamly-core 0.4` pair from GitHub. That pin was removed before the first
Hackage release. The publishable package metadata should use released
Hackage-compatible bounds:

```cabal
streamly      >=0.11 && <0.13
streamly-core >=0.3  && <0.5
```

Before doing anything else, verify that `cabal.project` has no GitHub package
pins and that Hackage has versions satisfying the streamly bounds:

```bash
cabal info streamly streamly-core 2>/dev/null
if grep -n 'source-repository-package' cabal.project; then
  echo "non-Hackage package pin found in cabal.project"
  exit 1
fi
cabal list --simple streamly | grep -E '^streamly 0\.(11|12)(\.|$)'
cabal list --simple streamly-core | grep -E '^streamly-core 0\.(3|4)(\.|$)'
```

`baikai-agent` brings a second family that deserves the same check, because it
is newer and less widely mirrored than the rest of the dependency set:

```bash
for pkg in settei settei-env settei-kdl settei-optparse-applicative; do
  cabal list --simple "$pkg" | grep -E "^$pkg 0\.2(\.|$)" || echo "MISSING: $pkg"
done
```

If the `source-repository-package` check finds a package pin, stop and resolve
that first. If Hackage does not list versions satisfying the `.cabal` bounds,
stop and tell the operator which dependency is not resolvable from Hackage.

## Versioning strategy (PVP)

Versions are `A.B.C.D`:

- **`A.B`** — major version. A breaking API change bumps this. `major` →
  increment `B` (or `A` for a truly large break) and reset `C.D` to `0.0`
  (e.g. `0.1.0.0` → `0.2.0.0`).
- **`C`** — minor version. Backwards-compatible additions (new exports). `minor`
  → increment `C`, reset `D` to `0` (e.g. `0.1.0.0` → `0.1.1.0`).
- **`D`** — patch. No API change (bug fixes, docs, internal). `patch` →
  increment `D` (e.g. `0.1.0.0` → `0.1.0.1`).

The optional `[major|minor|patch]` argument forces the bump kind for the
package(s) being released. With no argument, infer the bump per package from its
changes since its last tag (see step 2).

Each package versions **independently** — do not bump a package that has no
changes just because a sibling moved, *except* when an internal-dependency bound
forces it (see "Internal dependency bounds" below).

## Publishable packages (in dependency order)

Publish in this order — a dependency must be on Hackage before its dependents:

1. **`baikai`** — `baikai/` — core library (the unified provider abstraction).
   No internal dependencies.
2. **`baikai-claude`** — `baikai-claude/` — Anthropic Claude providers. Depends
   on `baikai`.
3. **`baikai-openai`** — `baikai-openai/` — OpenAI providers. Depends on
   `baikai`.
4. **`baikai-trace-otel`** — `baikai-trace-otel/` — OpenTelemetry `TraceSink`
   adapter. Depends on `baikai`.
5. **`baikai-effectful`** — `baikai-effectful/` — `effectful` binding over
   baikai's transport (the `Baikai` dynamic effect). Its *library* depends only
   on `baikai`; its `baikai-openai` dependency is **test-only** and does not
   affect publish order.
6. **`baikai-kit`** — `baikai-kit/` — shared kit installer library for AI-agent
   skills and subagents (listing, install, update, uninstall, status, discovery).
   Depends only on `baikai`. No in-repo package depends on it.
7. **`baikai-agent`** — `baikai-agent/` — unattended coding-agent runs: the
   process runner, the layered configuration layer, and the **`baikai`
   executable** (`agent run`, `agent show`, `agent list`). Its library depends
   on `baikai`, `baikai-claude`, and `baikai-openai` — it dispatches a resolved
   job to the vendor renderer for its provider — so it publishes **last**, after
   all three. No in-repo package depends on it.

   It is the only package with third-party dependencies outside the usual set:
   `settei`, `settei-env`, `settei-kdl`, and `settei-optparse-applicative`, all
   pinned `^>=0.2`, plus `optparse-applicative ^>=0.19` (the version
   `baikai-kit` already uses, so the build plan carries one copy). All four
   `settei` packages are published on Hackage at `0.2.0.0` — verified by
   resolving and building them from Hackage on 2026-08-05 — so the Hackage-only
   rule above holds. `settei-formats` is deliberately **not** a dependency and
   must not be added: it bundles Dhall loading, and the repository
   configuration this package reads is untrusted input.

   It is also the only package that ships an executable a user installs, which
   changes what a release has to prove — see "Releasing the `baikai` command-line
   tool" below. Note that the executable is named `baikai` while a *package* is
   also named `baikai`, so an in-workspace `cabal run baikai` fails as ambiguous.
   Use `cabal run baikai-agent:exe:baikai` when exercising it before a release.

   `baikai` also builds two executables — `baikai-gen-models` and
   `baikai-fetch-models` — but those are catalog-generation tools, not something
   a user installs. They still have to build from the source distribution, which
   step 6's sdist check covers.

Packages 2–6 depend only on `baikai` (for their library component), so once
`baikai` is up they can be published in any order among themselves. Package 7 is
the only one that must wait for packages 2 and 3 as well.

### Not released (internal)

- **`baikai-smoke`** (`baikai-smoke/`) — **test-suite only, no library
  component.** Live smoke tests that hit real provider networks when API keys
  are present. Nothing to ship; never upload it.

## Internal dependency bounds

Every dependent pins its internal dependencies with explicit PVP-caret bounds,
never an unbounded `build-depends`. There are two internal edges:

- **On `baikai`** — `baikai-claude`, `baikai-openai`, `baikai-trace-otel`,
  `baikai-effectful`, `baikai-kit`, and `baikai-agent` each carry a
  `baikai ^>=…` bound.
- **On the provider packages** — `baikai-agent` additionally carries
  `baikai-claude ^>=…` and `baikai-openai ^>=…`, because its provider dispatch
  reaches both renderers. This edge is easy to forget: it is the only one that
  is not "something depends on `baikai`".

Read the current bounds rather than trusting an example, because they move with
every release:

```bash
grep -rn '^ *, baikai' */*.cabal | grep '\^>='
```

Before publishing, confirm every bound is present and admits the version you are
about to publish.

When you bump a package in a way that changes the bound its dependents resolve
against:

- Update the bound in every dependent. A `baikai` major forces edits in all six
  dependents; a `baikai-claude` or `baikai-openai` major forces an edit in
  `baikai-agent`.
- A dependent that changed **only** because of that bound bump still needs a new
  version (a `patch` bump is the minimum) and its own release + tag, because its
  `.cabal` content changed.

Call this out explicitly when it happens — it is the one place independent
versioning still forces a coordinated bump.

## Releasing the `baikai` command-line tool

`baikai-agent` is the only package a user installs rather than depends on:
`cabal install baikai-agent` puts a `baikai` binary on their `PATH`. Two things
follow that do not apply to the library-only packages.

**A library release is verified by its dependents; a tool release is not.** The
in-workspace build proves nothing about the tarball a user will actually build,
because `cabal.project` puts every sibling package on disk. Uploading is the
first moment `baikai-agent` resolves `baikai`, `baikai-claude`, and
`baikai-openai` from the index like everyone else. Step 6 therefore builds each
source distribution outside the workspace before uploading it, and step 8
installs the published tool from the index and runs it.

**The tool's user-facing docs are part of the release.** The README's package
table carries a Hackage column, and `docs/user/unattended-agent-runs.md` and
`docs/user/getting-started.md` tell a reader how to get the binary. A release
that publishes the tool but leaves those saying it is unpublished ships a
correct package with wrong instructions. Step 3 covers this.

### First upload of a package

**All seven publishable packages are now on Hackage** — `baikai-agent` was the
last to arrive, at `0.1.0.0` on 2026-08-05 — so every release described here is
an ordinary bump. This section applies only to a package added to the repository
after that.

A first upload also creates the package name on Hackage, and it is where a
missing source file or an unbuildable stanza shows up. It therefore deserves the
candidate path in step 6 — `cabal upload` *without* `--publish` — because a
published version can never be replaced or withdrawn, only deprecated. Inspect
the candidate page, then publish.

Check what is actually published rather than trusting this paragraph; it is the
kind of claim that goes stale silently:

```bash
for pkg in baikai baikai-claude baikai-openai baikai-trace-otel \
           baikai-effectful baikai-kit baikai-agent; do
  printf '%-20s ' "$pkg"
  curl -s -H 'Accept: application/json' \
    "https://hackage.haskell.org/package/$pkg.json" || echo "(not on Hackage)"
  echo
done
```

## Release steps

> Run from the repo root, inside the Nix dev shell (`nix develop` / direnv).

### 1. Pick the packages to release

Decide which of the seven publishable packages this run covers. If the operator
named packages, use those. Otherwise, look at `git log` since each package's last
tag and propose the set with changes. If it is ambiguous, confirm with
`AskUserQuestion`. Always release a changed dependency (`baikai`) before its
changed dependents in the same run.

### 2. Determine changes and compute each bump

For each package being released, find its last release tag and review changes:

```bash
# last tag for a package (per-package tags look like baikai-0.1.0.0).
# Anchor the version with [0-9] — a bare 'baikai-*' also matches every
# sibling's tags, so it answers baikai-trace-otel-0.3.0.3 for the core
# package and silently computes the bump against the wrong baseline:
git tag --list 'baikai-[0-9]*' --sort=-v:refname | head -1
git log --oneline <last-tag>..HEAD -- baikai/
```

(Repeat with the package's directory and tag prefix: `baikai-claude-[0-9]*`,
`baikai-openai-[0-9]*`, `baikai-trace-otel-[0-9]*`, `baikai-effectful-[0-9]*`,
`baikai-kit-[0-9]*`, `baikai-agent-[0-9]*`. Only `baikai` needs the anchor to be
correct, but use it throughout so the commands stay uniform.)

**A tag is not proof of a release.** This repo has at least one tag that was cut
but never uploaded (`baikai-0.3.2.0`; Hackage's `baikai` listing goes `0.3.1.0`
→ `0.4.0.0`), and `baikai-kit` conversely has no `0.1.0.0` tag *and* no
`0.1.0.0` on Hackage — its first published version is `0.1.0.1`. Compute the
bump from the tag, but confirm what is actually published before writing a
version into user-facing docs:

```bash
curl -s -H 'Accept: application/json' https://hackage.haskell.org/package/baikai.json
```

A package with no tag at all has never been released, so "changes since its last
tag" does not apply — review its whole directory and give it a starting version
(`0.1.0.0`) rather than inferring a bump. As of 2026-08-10 every publishable
package has a tag, so this applies only to a package added after that; confirm
with the tag listing rather than assuming.

Classify the change per package and compute the new PVP version:

- New/changed/removed exports or types → **major** or **minor** per PVP.
- Bug fixes / internal only → **patch**.
- Honor the `[major|minor|patch]` argument if the operator passed one (it
  overrides inference).

Read the current version straight from the cabal file:

```bash
grep -E '^version:' baikai/baikai.cabal
```

### 3. Update versions, internal bounds, and changelogs

For each released package:

- **`version:`** in its `.cabal` → the new PVP version.
- If `baikai` changed its API, update the `baikai ^>=…` bound in every dependent
  you are also releasing (see "Internal dependency bounds").
- **`CHANGELOG.md`** — this repo keeps a single root `CHANGELOG.md` in
  Keep a Changelog format with an `## [Unreleased]` section. Move the relevant
  entries from `[Unreleased]` into a new dated, versioned section. Use the bump
  date in `YYYY-MM-DD` form, and scope entries by package when more than one
  ships in a run, e.g.:

  ```markdown
  ## [Unreleased]

  ## [baikai 0.1.0.1] - 2026-06-04

  ### Fixed

  - ...
  ```

  Keep an empty `[Unreleased]` heading at the top for future work.

- **Docs that name a published version or an install method.** The README's
  package table has a **Hackage** column, and its *Install* section chooses
  between a `source-repository-package` git pin and ordinary `build-depends`
  based on what is published. A package moving from unpublished to published
  flips both. For `baikai-agent` that also means the install instruction becomes
  `cabal install baikai-agent` (which puts a `baikai` binary on `PATH`) rather
  than a library `build-depends` entry.

  Find the claims rather than editing from memory — they drift:

  ```bash
  grep -rn 'not yet\|source-repository-package\|cabal install' README.md docs/user/
  ```

  Write these edits as if the upload already succeeded, and include them in the
  release commit. They are a lie for the few minutes between step 5 and step 6;
  the alternative is a second commit that is easy to forget entirely. If step 6
  fails, the fix is to revert, not to leave the tree describing a release that
  did not happen.

- **The capability catalog (`docs/capabilities/`).** This is the OKF bundle
  describing what baikai provides a consumer today. Every record carries a
  `since:` naming the version it first became available in, so a release can
  invalidate it in three ways. Handle each:

  1. **A record says `since: "unreleased"`.** The capability existed only on the
     default branch; this release publishes it. Change `since` to the version
     being released.
  2. **The release ships a capability the catalog does not describe.** Add a
     record. Read `docs/capabilities/index.md` first — it states the three rules
     (evidence or it does not exist; provision, not composition; one thing a
     consumer adopts *and* verifies independently) and the local conventions.
     Take the next free `CAP-N`; never renumber an existing handle.
  3. **An existing capability grew.** Ask whether a consumer pinned to the older
     release could still do the thing the record describes. If **yes, just less
     well** — keep the record, keep its `since`, and describe the evolution in
     the body. If **no, the thing is impossible for them** — add a new record
     with this release as its `since` that `requires` the old one. **Never move
     an older record's `since` forward**; a consumer pinning an older version is
     exactly who that field is for.

  A retired capability becomes `status: deprecated` (or `withdrawn`) and then
  *requires* a `replacedBy`. There is deliberately no `planned` status — a
  capability that does not exist yet is an improvement request, not a record.

  `since` names the version of the **first package listed** in that record,
  because the packages version independently and `since` is a single scalar.
  Check which package that is before writing a version into it.

  Add a dated entry to `docs/capabilities/log.md` describing what changed. The
  bundle's profile enforces the log, so a catalog edit without a log entry fails
  the gate in step 4.

**Confirm the computed bumps, changelog edits, and doc updates with the operator
before committing.**

### 4. Run the gates (all five are mandatory)

Every gate must pass before any tag or upload. Stop on the first failure.

```bash
nix fmt                 # then confirm the tree is clean:
git diff --exit-code    # fails if formatting changed anything uncommitted
cabal build all
nix flake check
```

**Validate the OKF bundles**, so a stale or malformed capability record cannot
ride out with the release:

```bash
mori validate
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf validate docs/improvement-requests \
  --profile mori/improvement-requests-profile.dhall --profile-enforce
okf validate docs/reviews --strict --profile docs/reviews/profile.dhall \
  --profile-enforce --log-enforce
okf validate docs/user --strict \
  --profile mori/user-documentation-profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
okf graph docs/user
```

`okf graph` must show an edge for every `requires` entry in the catalog. `okf`
derives concept-to-concept edges from Markdown **body links only**, so a
requirement declared in frontmatter and not mirrored as a body link validates
cleanly and is invisible to the graph.

Do **not** add `--strict` to the capability bundle as a gate. It additionally
reports the profile-recommended `reviews` family, which the machine-authored
records do not have; that is expected output, not a failure, and fabricating
review provenance to silence it would misreport the trust tier.

If `nix fmt` produced changes, fold them into the release commit (re-run the
build/test/check after re-formatting).

**Run the test gate with the provider keys and the coding-agent binaries
removed.** A bare `cabal test all` on a developer machine makes real, billable
provider calls: `baikai-smoke` gates its API cases on the key environment
variables *and* gates its batch CLI cases on `findExecutable` alone, so merely
having `claude` or `codex` on `PATH` is enough to spend money. Two independent
gates, and both have to be closed. This `zsh` command closes them while keeping
the active toolchain — adjust the two filtered `PATH` entries to wherever the
coding agents are installed on this machine:

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

Every suite must pass, not merely skip. If a suite reports zero tests run,
something was filtered that should not have been — investigate rather than
proceeding.

### 5. Commit, tag, push

Commit with a Conventional Commits message (this project follows Conventional
Commits):

```bash
git add -A
git commit -m "chore(release): baikai 0.1.0.1, baikai-claude 0.1.0.1"
```

Create an **annotated, per-package** tag for each released package
(`<package>-<version>`), then push commit and tags:

```bash
git tag -a baikai-0.1.0.1 -m "baikai 0.1.0.1"
git tag -a baikai-claude-0.1.0.1 -m "baikai-claude 0.1.0.1"
git push origin master --follow-tags
```

Then refresh Mori's index, because **editing concept Markdown does not update
it** — the capability and improvement-request read models are written at
registration time, so until this runs, `mori registry concepts --search` and
`mori path mori://shinzui/baikai/okf/capabilities/concepts/CAP-N` still answer
from the pre-release snapshot:

```bash
mori register
mori registry concepts shinzui/baikai --bundle capabilities
```

### 6. Publish to Hackage — one package at a time, in dependency order

Run the whole of this step for one package before starting the next, **in
dependency order (`baikai` first)**. Do not batch the sdists and then batch the
uploads: a dependent cannot be verified until its dependencies are live on the
index, which is the point of the sdist check below.

**6a. `cabal check`.** Hackage rejects some `.cabal` problems outright and warns
about others. Catch them before the upload:

```bash
(cd baikai-agent && cabal check)
```

**6b. Build the source distribution and verify it outside the workspace.** This
is the gate the in-workspace build cannot give you. Inside the repo,
`cabal.project` supplies every sibling package from disk, so a dependent builds
even if its Hackage bound is wrong or its tarball is missing a file. Unpacking
elsewhere resolves everything from the index, exactly as a user will:

```bash
cabal sdist baikai-agent            # -> dist-newstyle/sdist/baikai-agent-0.1.0.0.tar.gz

cabal update                        # required: pick up dependencies published
                                    # earlier in THIS run
verify=$(mktemp -d)
tar xzf dist-newstyle/sdist/baikai-agent-0.1.0.0.tar.gz -C "$verify"
(cd "$verify"/baikai-agent-0.1.0.0 && cabal build all)
```

The `cabal update` is not optional. Hackage's index is what the unpacked tarball
resolves against, and a local index from before this run's earlier uploads makes
the build fail with a missing dependency that is in fact already published.

A failure here means the tarball is wrong, not the workspace — usually a source
file that no stanza references, or an internal bound that admits only a version
you have not uploaded yet. Fix it, and note that fixing it means a new version if
the package was already published.

**6c. Upload.** Use `--publish` only when you are certain. Omitting it pushes a
*candidate* you can inspect first — do that for a package's first upload (see
"First upload of a package"), since a published version can never be replaced.

```bash
cabal upload --publish dist-newstyle/sdist/baikai-agent-0.1.0.0.tar.gz
```

**6d. Documentation.** Build and upload the Haddock for the same package:

```bash
cabal haddock baikai-agent --haddock-for-hackage --enable-documentation
cabal upload --documentation --publish \
  dist-newstyle/baikai-agent-0.1.0.0-docs.tar.gz
```

Confirm the package page renders on Hackage before moving to the next package.
**If any upload fails, stop** — do not publish a dependent while a dependency
failed to publish. That means no `baikai-claude`, `baikai-openai`,
`baikai-trace-otel`, `baikai-effectful`, `baikai-kit`, or `baikai-agent` after a
failed `baikai`, and no `baikai-agent` after a failed `baikai-claude` or
`baikai-openai`.

> Hackage credentials: `cabal upload` reads `~/.config/cabal/config` or prompts.
> Make sure the operator is a Hackage maintainer/uploader for each package.

### 7. GitHub release (per package)

`gh` is available and the remote is `github.com/shinzui/baikai`. For each
per-package tag, create a matching GitHub release with notes drawn from the
changelog section:

```bash
gh release create baikai-0.1.0.1 \
  --title "baikai 0.1.0.1" \
  --notes "See CHANGELOG.md (baikai 0.1.0.1)."
```

No binaries are attached. `baikai-agent` ships source like everything else, and
users install the tool with `cabal install baikai-agent`.

### 8. Verify the installed tool (only when `baikai-agent` was released)

A library's release is exercised by whatever depends on it. Nothing depends on
`baikai-agent`, so unless you install it from the index nobody finds out until a
user does. Install the published package into a scratch directory — not onto
your `PATH`, where it would shadow whatever you already have:

```bash
installdir=$(mktemp -d)
cabal update
cabal install baikai-agent --installdir="$installdir" --install-method=copy
"$installdir"/baikai --help
"$installdir"/baikai agent --help
```

`--help` is the whole check: the executable has no `--version` flag, and every
other subcommand reads configuration or spawns a coding agent. Confirm the
binary is named `baikai` (not `baikai-agent`) and that `agent run`, `agent show`,
and `agent list` all appear.

## Important

- **Confirm the version bumps and changelog edits with the operator before
  committing.** Publishing to Hackage is irreversible.
- **Honor the pre-flight dependency check.** If any publishable dependency is
  pinned to a non-Hackage source or cannot resolve from Hackage, the release is
  blocked — stop and report it.
- **Always publish in dependency order:** `baikai` before `baikai-claude`,
  `baikai-openai`, `baikai-trace-otel`, `baikai-effectful`, `baikai-kit`; and
  all of `baikai`, `baikai-claude`, `baikai-openai` before `baikai-agent`.
- **Never skip the gates** (`nix fmt` clean, `cabal build all`, the key- and
  CLI-scrubbed `cabal test all`, `nix flake check`, and the OKF bundle
  validation). Stop on any failure.
- **Never run the test gate with provider keys or coding-agent binaries
  visible.** `baikai-smoke` will make real billable calls, and the CLI cases
  key off `PATH` alone rather than off any environment variable.
- **Never continue publishing dependents after an upstream upload fails.**
- **Never publish `baikai-smoke`** — it is a test-only package with no library.
- **Never upload a source distribution you have not built outside the
  workspace** (step 6b), and run `cabal update` first so it resolves against the
  uploads this run already made. The in-workspace build cannot catch a bad
  tarball, because `cabal.project` supplies the siblings from disk.
- **Use a candidate upload for a package's first appearance on Hackage.** A
  published version can never be replaced — only deprecated.
- **Move the docs with the release.** The README's Hackage column and Install
  section, and the `docs/user/` install instructions, state what is published;
  a release that leaves them stale ships correct code with wrong instructions.
- **Move the capability catalog with the release.** `docs/capabilities/` is the
  consumer-facing answer to "what does baikai provide today", and every record's
  `since` is a claim about a published version. Turn `unreleased` into the
  version being shipped, add a record for a capability this release introduces,
  and log the change. **Never advance an existing record's `since`** — a
  consumer pinning an older version is precisely who reads that field.
- Keep tags **annotated** and **per-package** (`<package>-<version>`).
