# Changelog

All notable changes to baikai are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial scaffold: `baikai` library with `Baikai` and `Baikai.Prelude`.

### Changed

- Depend on released `streamly ^>=0.11` / `streamly-core ^>=0.3` from Hackage
  instead of the unreleased 0.12/0.4 pair. Dropped the `source-repository-package`
  git pins from `cabal.project`, so all dependencies now resolve from Hackage —
  a prerequisite for publishing to Hackage.
