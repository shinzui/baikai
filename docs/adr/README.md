# Architecture Decision Records

Durable decisions about how baikai is built: the ones that constrain
future work and that a reader should be able to find without knowing
which plan made them.

A decision that only governs one piece of work stays in that plan's
Decision Log under `docs/plans/`. A decision that outlives the plan is
promoted here.

[0001](0001-architecture-decision-record-convention.md) records the
format and why this corpus is plain files rather than a profiled OKF
bundle.

| # | Decision | Status |
|---|---|---|
| [0001](0001-architecture-decision-record-convention.md) | Record architecture decisions as plain Markdown files in `docs/adr` | accepted |
| [0002](0002-requested-translated-observed-are-never-collapsed.md) | Requested, translated, and observed are three separate facts and are never collapsed | accepted |
| [0003](0003-the-adapter-owns-the-translation-description.md) | The provider adapter owns the description of what it translated, and no layer re-derives it | accepted |
| [0004](0004-two-digests-commitment-and-configuration.md) | Emit two digests, because a commitment and a configuration fingerprint are different values | accepted |
| [0005](0005-what-baikai-deliberately-does-not-do.md) | Baikai does not sign, does not hold sanctioning policy, does not claim provider internals, and does not own retries | accepted |
| [0006](0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md) | A process-spawning executable ships on the threaded runtime, and its suite proves it | accepted |
| [0007](0007-text-crossing-a-process-boundary-is-encoded-explicitly.md) | Text crossing a process boundary is encoded explicitly as UTF-8, never through the locale | accepted |
| [0008](0008-one-url-host-parser-and-every-consumer-uses-it.md) | There is one URL host parser and every consumer uses it | accepted |
