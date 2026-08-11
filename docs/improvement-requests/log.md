# Bundle Update Log

## 2026-08-11

* **Addition**: IR-4 requests an explicit replace-or-append mode on the neutral
  `systemPrompt` field, because the four subprocess renderers divide in two and the type
  says nothing about which a caller will get: the Claude interactive and batch providers
  render `--system-prompt`, which displaces Claude Code's own coding-agent harness prompt,
  while the Codex ones route through `wrapSystemPrompt`, which leaves the harness prompt
  intact and prepends a labelled block to the user turn. Both renderings are correct for
  their vendor — verified against installed `claude` and `codex` help output, where Claude
  exposes both `--system-prompt` and `--append-system-prompt` and Codex exposes neither —
  so this is a modelling gap rather than a defect. It also leaves Claude's append flag
  unreachable through the neutral type, which is what `mori://shinzui/okf` needs; its
  assist command has appended since it shipped and its Baikai adoption currently smuggles
  `--append-system-prompt` through `extraArgs`. The request leaves one question open for
  review rather than presuming it: whether `ReplaceSystemPrompt` against Codex should be
  refused with an `AgentRenderError`, following the existing `SafetyNotExpressible`
  precedent in both launchers, or approximated and documented.

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

* **Completion**: IR-3 is `completed`. Verifiable model-call evidence is built, tested, and
  documented in `mori://shinzui/baikai` across the seven ExecPlans of
  `docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md`: the
  `Baikai.Evidence` vocabulary and canonical hashing core, the adapter-to-trace channel, the
  Anthropic and OpenAI-compatible API providers, both subprocess completion providers, the
  unattended agent surface, and strict evidence mode with the migration guidance, the
  repository's first ADRs, and the release.

  Five of the seven acceptance criteria are met as stated. Criterion 1: all four completion
  transports emit schema-valid terminal evidence for successful and failed calls, proved against
  recorded fixtures and fake executables with no credentials. Criterion 2: every canonical
  thinking level's translation is pinned per transport, including a forty-two-row table across
  the seven OpenAI-compatible wire shapes and both Anthropic thinking styles. Criterion 3: a
  provider-returned model and correlation identifier are preserved independently of the
  configured model, and an absent one reads as `"unobserved"` rather than being backfilled — the
  gap here was larger than the request stated, since no observed model existed anywhere in the
  codebase before this work. Criterion 5: strict evidence mode refuses before dispatch, both when
  a transport's declared strength is too low and when the request would be downgraded, with a
  named test per downgrade site. Criterion 6: golden tests pin both digests and prove no
  credential, prompt body, thinking text, or tool payload appears in the configuration envelope.

  Two are met in the modified form the review agreed. Criterion 4's "hash of the redacted request
  envelope" became two digests, because a commitment to content and a redaction-stable
  configuration fingerprint are different values and the request asked for both under one name;
  and its retry clause is caller-supplied provenance, because baikai has no retry loop and
  acquiring one was out of scope. Correlation does survive streaming, early consumer termination,
  and trace-sink failure without emitting two terminal records — and under strict mode a sink
  failure now fails the call, which the review established is what that criterion is for.
  Criterion 7's migration guidance is `docs/user/model-call-evidence.md`, which is explicit that
  the record is a contemporaneous logbook rather than a claim about provider internals; it also
  has to carry three unconditional behaviour changes the request did not anticipate, the loudest
  being that the two CLI providers reported `zeroUsage` on every call and now report real tokens
  and, for `claude`, a real cost.

  Outside the request: baikai signs nothing, holds no sanctioned-model policy, claims no
  knowledge of provider internals, and owns no retry loop. Those exclusions are recorded in
  `docs/adr/0005-what-baikai-deliberately-does-not-do.md`. Publishing to Hackage remains
  outside it.

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
