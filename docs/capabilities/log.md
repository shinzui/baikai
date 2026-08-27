# Bundle Update Log

## 2026-08-27

* **Update**: CAP-17 (unattended coding-agent runs) and CAP-18 (the `baikai
  agent` command) now describe the timeout as an escalation — interrupt, then
  terminate, then kill, each stage bounded by a grace period and ended early
  once the leader is reaped and no group member remains — and record that the
  output drained before the kill travels back with the failure rather than being
  discarded. Both gain `baikai-agent/test/BinaryTests.hs` as evidence: the first
  cases in this repository that spawn the __built__ executable, which is the
  only way to prove what runtime it ships with. Behind them,
  `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md`
  records why a suite's own `ghc-options` are never evidence about a binary.

* **Update**: CAP-16 (interactive launches) records that the refusal now also
  covers an approval policy the installed `codex` generation rejects.
  `codex --help` at 0.149.1 accepts only `on-request` and `never` for
  `--ask-for-approval`; the older `untrusted` and `on-failure` spellings made the
  CLI exit with a usage error, which reached a caller as a session that ran and
  failed rather than as a refusal.

## 2026-08-10

* **Add**: Adopt the shared OKF capability profile (okf-profiles
  `coordination/capabilities`, pinned at v0.9.0) and author the initial baikai
  capability catalog: 22 capabilities (CAP-1 … CAP-22) derived from the eight
  packages in `cabal.project`, their exposed modules, the offline test suites,
  the `baikai-smoke` live cases, the ten user guides, and the release history in
  `CHANGELOG.md` and the git tags.

* **Note**: `since` names the version of the **first package listed** in each
  record, because the eight packages version independently and the profile's
  `since` is a single scalar. The convention is stated in `index.md`.

* **Note**: `stability` is mixed rather than uniform. Eighteen records are
  `stable` under the profile's definition — baikai carries every breaking change
  on a PVP-major bump, which the changelog documents release by release. Four are
  `experimental` because their surface sits outside that promise: CAP-17 and
  CAP-18 (`baikai-agent` at 0.1.0.0), CAP-21 (`baikai-kit` at 0.1.0.x), and
  CAP-19, which rests substantially on `Baikai.Provider.Cli.Internal`. `index.md`
  spells out that `stable` here means "breaks come with a major bump", not
  "settled".

* **Note**: gaps the evidence requirement exposed, recorded in the records that
  own them —
  * **CAP-6 (text embeddings)** is the weakest record in the catalog: one
    hermetic request-mapping test, a live test gated behind
    `BAIKAI_EMBEDDING_LIVE=1` that no default run executes, no smoke case, and no
    user guide. `Baikai.Embedding` also sits outside the registry entirely, so
    tracing, cost accounting, and evidence do not cover it.
  * **`fully_observed` is unreachable on every shipped transport** (CAP-19). No
    Anthropic or OpenAI-compatible host echoes the reasoning configuration it
    applied, so the top of the evidence strength scale is currently aspirational
    rather than achievable.
  * **Live behaviour is under-proven by construction.** Everything requiring a
    real provider is in `baikai-smoke`, which skips without credentials. A
    default `cabal test all` proves mappings and mechanics, not round trips.
  * **`baikai-kit 0.1.0.0` was never released** — confirmed against Hackage,
    which lists exactly `0.1.0.1` … `0.1.0.4` for the package; no git tag exists
    either, and the version was bumped to `0.1.0.1` during the first release
    sweep that included it. CAP-21 records `0.1.0.1` as the earliest depend-able
    version and explains why. Every other record's `since` was checked against
    the same registry listing.

* **Note**: two repository-hygiene gaps found while inventorying, since fixed in
  `mori.dhall`: it listed five of the eight packages in `cabal.project`
  (`baikai-trace-otel`, `baikai-kit`, and `baikai-agent` were absent) and nine of
  the eleven files in `docs/user/` (`model-call-evidence.md` and
  `unattended-agent-runs.md` were absent). The capability records cited the real
  paths throughout, so no record changed.
