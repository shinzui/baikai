# Bundle Update Log

## 2026-08-05

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
