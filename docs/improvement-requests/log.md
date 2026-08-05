# Bundle Update Log

## 2026-08-05

* **Review**: IR-3 records an Anthropic Claude review with claude-opus-5 after in-repository
  verification against the trace and cost-log surfaces, both API providers, both subprocess
  completion providers, the unattended agent surface, the local SSE transports, and the
  `MercuryTechnologies/claude` SDK source. Every premise the request asserts was verified true,
  and two are stronger than stated: no observed model exists anywhere in the codebase, because
  both API providers build their assistant skeleton from the caller's own `Model` record; and the
  silent thinking-downgrade surface is six distinct sites across three packages, two of which are
  model-capability and token-budget interactions rather than effort mappings. Approved with nine
  corrections. Four resolve ambiguities the request left open — which CLI surface acceptance
  criterion 1 means, the internally inconsistent single request digest, the trace-sink failure
  policy under strict mode, and the ownership of retries. Five are findings the request did not
  anticipate, including a call-id generator that is not unique across processes, a trace path that
  elides token and cost fidelity the cost log keeps, and an Anthropic translation record that is
  already computed and discarded. A sixth finding was raised and withdrawn: the OpenAI-native
  effort mapping was reported as a wire bug on the strength of a stale Haddock, but
  `compatibleEffort` is scoped to the non-native shapes and `ShapeSpec` guards the native values
  reaching the wire intact, so the behaviour is deliberate and only the comment needs correcting.
  The accepted design changes no wire behaviour on any transport.

* **Planned**: IR-3 is `planned`. The accepted design is
  `docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md`, which
  decomposes the work into seven ExecPlans (`docs/plans/51` through `docs/plans/57`): the evidence
  vocabulary and canonical hashing core, the adapter-to-trace channel, one plan per provider
  family, a separate plan for the unattended agent surface — which has no observability of any
  kind today — and a final plan for strict evidence mode, the migration guidance, the repository's
  first ADRs, and the coordinated release across five packages.

* **Completion**: IR-1 is `completed`. The unattended coding-agent surface is built, tested,
  and documented in `mori://shinzui/baikai` across the six ExecPlans of
  `docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: the
  `Baikai.Agent` vocabulary and pure policy ceiling, both vendor argument-vector renderers, the
  repaired interactive launchers, the `baikai-agent` package with its process runner and
  layered KDL configuration, and the `baikai` executable with `agent run`, `agent show`, and
  `agent list`. All seven acceptance criteria are proved by tests that invoke no live model and
  require no coding-agent binary. Criterion 7 is met with the one pre-approved exception the
  review recorded. Publishing to Hackage and migrating
  `mori://shinzui/keiro-syntax`'s `scripts/sync-keiro-dsl.sh` remain outside the request.

## 2026-08-02

* **Addition**: IR-3 requests provider-boundary model-call evidence for sanctioned agent-run
  attestations in `mori://shinzui/kikan/okf/use-cases/concepts/UC-8`.

## 2026-07-30

* **Addition**: IR-2 requests the planned MCP client, tool, and authentication contracts as a
  coherent public release for Shikumi and Shikigami.

* **Review**: IR-1 records an Anthropic Claude review with claude-opus-5 after in-repository
  verification against Baikai's three coding-agent surfaces, the cradle and settei dependency
  sources, and installed Claude Code 2.1.220 and codex-cli 0.146.0 help output. Approved with
  four corrections; accepted design is
  `docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`.

## 2026-07-29

* **Addition**: IR-1: add a configurable CLI for unattended coding-agent runs.
