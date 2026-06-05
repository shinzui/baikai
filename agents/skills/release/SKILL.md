---
name: release
description: Cut a release of the baikai Haskell packages and publish them to Hackage following PVP. Packages version independently, publish in dependency order (baikai first), and are tagged per-package. Run manually when shipping a new version.
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

## ⚠️ Pre-flight blocker — read first

`baikai` depends on `streamly ^>=0.12` and `streamly-core ^>=0.4`, which are
**pinned to a GitHub checkout** in `cabal.project` (the project needs the
unreleased 0.12 / 0.4 pair):

```
source-repository-package
  type: git
  location: https://github.com/composewell/streamly
  ...
```

**Hackage rejects any package whose dependencies are not themselves on
Hackage.** Until `streamly-0.12.*` and `streamly-core-0.4.*` are published to
Hackage, `cabal upload` of `baikai` (and therefore every dependent) will fail
constraint resolution for downstream users even if `sdist` succeeds locally.

Before doing anything else, verify the pin is resolvable from Hackage:

```bash
cabal info streamly streamly-core 2>/dev/null
# or check the index:
cabal list --simple streamly | grep -E '^streamly 0\.12'
cabal list --simple streamly-core | grep -E '^streamly-core 0\.4'
```

If those versions are **not** on Hackage yet, **stop** and tell the operator the
release is blocked on an upstream streamly release. Do not proceed; do not
remove the git pin to work around it (that would ship a package nobody else can
build).

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

Packages 2–4 depend only on `baikai`, so once `baikai` is up they can be
published in any order among themselves.

### Not released (internal)

- **`baikai-smoke`** (`baikai-smoke/`) — **test-suite only, no library
  component.** Live smoke tests that hit real provider networks when API keys
  are present. Nothing to ship; never upload it.

## Internal dependency bounds

Today the inter-package `build-depends` are **unbounded** — e.g.
`baikai-claude` lists `baikai` with no version constraint. Before publishing,
every dependent's bound on a publishable internal package should be an explicit
PVP-caret bound, e.g.:

```
build-depends:
  , baikai ^>=0.1.0
```

When you bump `baikai` in a way that changes the bound dependents resolve
against:

- Update the `baikai ^>=…` bound in `baikai-claude`, `baikai-openai`, and
  `baikai-trace-otel`.
- A dependent that changed **only** because of that bound bump still needs a new
  version (a `patch` bump is the minimum) and its own release + tag, because its
  `.cabal` content changed.

Call this out explicitly when it happens — it is the one place independent
versioning still forces a coordinated bump.

## Release steps

> Run from the repo root, inside the Nix dev shell (`nix develop` / direnv).

### 1. Pick the packages to release

Decide which of the four publishable packages this run covers. If the operator
named packages, use those. Otherwise, look at `git log` since each package's last
tag and propose the set with changes. If it is ambiguous, confirm with
`AskUserQuestion`. Always release a changed dependency (`baikai`) before its
changed dependents in the same run.

### 2. Determine changes and compute each bump

For each package being released, find its last release tag and review changes:

```bash
# last tag for a package (per-package tags look like baikai-0.1.0.0):
git tag --list 'baikai-*' --sort=-v:refname | head -1
git log --oneline <last-tag>..HEAD -- baikai/
```

(Repeat with the package's directory and tag prefix: `baikai-claude-*`,
`baikai-openai-*`, `baikai-trace-otel-*`.)

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

**Confirm the computed bumps and changelog edits with the operator before
committing.**

### 4. Run the gates (all four are mandatory)

Every gate must pass before any tag or upload. Stop on the first failure.

```bash
nix fmt                 # then confirm the tree is clean:
git diff --exit-code    # fails if formatting changed anything uncommitted
cabal build all
cabal test all
nix flake check
```

If `nix fmt` produced changes, fold them into the release commit (re-run the
build/test/check after re-formatting).

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

### 6. Publish to Hackage — in dependency order

For each released package, **in dependency order (`baikai` first)**, build the
source distribution and upload it. Use `--publish` only when you are certain;
omit it first to push a *candidate* you can inspect on Hackage.

```bash
# from the package directory (or pass the path):
cabal sdist baikai
cabal upload --publish dist-newstyle/sdist/baikai-0.1.0.1.tar.gz
```

Then build and upload the Haddock documentation for the same package:

```bash
cabal haddock baikai --haddock-for-hackage --enable-documentation
cabal upload --documentation --publish \
  dist-newstyle/baikai-0.1.0.1-docs.tar.gz
```

Confirm the package page renders on Hackage before moving to the next package.
**If any upload fails, stop** — do not publish a dependent (`baikai-claude`,
`baikai-openai`, `baikai-trace-otel`) while its dependency `baikai` failed to
publish.

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

## Important

- **Confirm the version bumps and changelog edits with the operator before
  committing.** Publishing to Hackage is irreversible.
- **Honor the pre-flight blocker.** If the pinned `streamly` / `streamly-core`
  versions are not on Hackage, the release is blocked — stop and report it.
- **Always publish in dependency order:** `baikai` before `baikai-claude`,
  `baikai-openai`, `baikai-trace-otel`.
- **Never skip the gates** (`nix fmt` clean, `cabal build all`, `cabal test
  all`, `nix flake check`). Stop on any failure.
- **Never continue publishing dependents after an upstream upload fails.**
- **Never publish `baikai-smoke`** — it is a test-only package with no library.
- Keep tags **annotated** and **per-package** (`<package>-<version>`).
