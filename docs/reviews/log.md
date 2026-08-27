# Bundle Update Log

## 2026-08-27

* **Addition**: REV-2 re-reviews every package at `c3753c5` (baikai 0.5.0.0,
  baikai-agent 0.1.0.0), continuing from REV-1. Every REV-1 finding and
  recommendation was re-verified against the current code and tests: all are
  fixed, superseded, or consciously declined except the Anthropic
  thinking-style table, which routes `claude-sonnet-5` to `budget_tokens`.
  Ten parallel readers then reviewed the current code fresh and the review
  requests changes: a critical `-threaded` omission in the shipped `baikai`
  binary, a host parse that can misdirect an API key, Claude error streams
  without `EventStart`, non-retryable mid-stream failures, a policy ceiling
  that gates less than documented, evidence records that misstate the
  caller's thinking request, and a documentation sweep (twelve capability
  `Shape` blocks do not type-check). Build and all offline suites were green;
  live smoke was skipped by policy.

* **Addition**: Adopt the shared OKF reviews profile (okf-profiles
  `assurance.reviews`, pinned at v0.13.1) and convert the free-form review of
  2026-07-01 into REV-1: a full, model-run review of every package at
  `759ddc9` (baikai 0.2.0.0) that requested changes to error classification,
  extended thinking, usage accounting, and the compat-quirk system. The body is
  the original text verbatim; the frontmatter records the commit examined, the
  reconstructed reviewer identity, and the master plan and ten exec plans it
  produced. The file moved from `2026-07-01-correctness-and-api-review.md` to
  `correctness-and-api-review.md`, and every plan that cited the old path was
  updated.
