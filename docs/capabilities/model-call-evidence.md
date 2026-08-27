---
title: "Verifiable model-call evidence"
type: Capability
description: "Opt one call in and get one record of what actually crossed the boundary to the provider — the model the provider said it ran, the correlation identifier, what the reasoning request became on the wire, two canonical digests, and an honest strength that a zero exit status and a 2xx never raise."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-19
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.5.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
  - baikai-agent
  - baikai-trace-otel
interface:
  - Baikai.Evidence
  - Baikai.Evidence.Build
requires:
  - CAP-1
  - CAP-9
  - CAP-11
evidence:
  - kind: test
    resource: baikai/test/EvidenceSpec.hs
    proves: "The canonical hashing core and the vocabulary: canonicalEncode gives a JSON value exactly one byte representation, commitmentDigest and configurationDigest differ in what they cover, and Observed distinguishes a reported value from an unreported one with no defaulting function."
  - kind: test
    resource: baikai/test/StrictEvidenceSpec.hs
    proves: "Strict mode's behaviour, including the sink-failure hook."
  - kind: test
    resource: baikai/test/TraceSpec.hs
    proves: "A successful call emits exactly one evidence record with status succeeded, and the record is emitted before the terminal call_finished/call_failed rather than after."
  - kind: test
    resource: baikai-claude/test/EvidenceSpec.hs
    proves: "The Anthropic transport records the model Anthropic reported running, the request-id correlation header, and reaches model_observed only when both arrived — never from a 2xx alone."
  - kind: test
    resource: baikai-openai/test/EvidenceSpec.hs
    proves: "The same for the Chat Completions transport, including that a call failing before any chunk arrives reports no observed model at all."
  - kind: test
    resource: baikai-claude/test/CliEvidenceSpec.hs
    proves: "That two claude -p calls the tool itself cannot tell apart — minimal and low, which render byte-identical argument vectors — produce evidence that can, and that a tool exiting non-zero records the failure and commits to no response."
  - kind: test
    resource: baikai-openai/test/CliEvidenceSpec.hs
    proves: "That the codex transport records what the tool reported and no more, so it cannot exceed correlated strength."
  - kind: test
    resource: baikai-agent/test/EvidenceTests.hs
    proves: "On the unattended surface: a zero exit with no identifier and no model stays at requested_only, a run killed by its own timeout still produces a record, an inherited run observes nothing because there are no bytes to read, a run that never started produces no record at all, and a run that asked for no evidence spawns exactly one process."
  - kind: guide
    resource: docs/user/model-call-evidence.md
    proves: "The requested/translated/observed split, the two digests, how much a record proves, strict mode, and what this deliberately is not."
---

# Verifiable model-call evidence

A `ModelCallEvidence` record answers a question a configuration file cannot: what
actually crossed the boundary to the provider? It carries the endpoint identity,
the transport kind, what the reasoning-effort request *became* on the wire
including every clamp and drop, whatever the provider reported about itself, the
call status, and an ascending `EvidenceStrength`.

Three decisions make the record worth trusting.

**Observation is never backfilled from the request.** `Observed` is a deliberate
non-`Maybe` with no function that supplies a default, so a field the provider did
not report reads `"unobserved"` forever. A stream that fails before Anthropic's
`message_start` reports no observed model, rather than echoing the model you
asked for.

**Corroboration is not inferred from success.** A 2xx means the request was
accepted, not that any particular model ran. A zero exit status means a
coding-agent CLI ran and did not crash, not which model served it — and since
almost every subprocess run exits zero, encoding that as corroboration would make
the weakest evidence in the system look like the strongest.

**Two digests, on purpose.** `commitmentDigest` hashes a full request envelope
and binds a record to one particular request; `configurationDigest` hashes an
allow-list projection that keeps configuration and replaces content with
structural summaries, so two calls that ask the same model the same way about
different subjects agree. `canonicalEncode` underlies both: sorted keys, no
insignificant whitespace, normalised numbers, and a hand-written string escaper
so an aeson upgrade cannot silently invalidate a recorded digest.

Records reach a consumer through
[CAP-9 — call tracing](call-tracing.md) as one `call_evidence` line per call,
under every way a call can end — including a consumer who abandons the stream,
which records `aborted` rather than `failed`, because an abort is the consumer's
doing.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md) and on
[CAP-11 — cross-provider reasoning-effort control](reasoning-effort-control.md),
whose translations it records.

## Shape

```haskell
let opts = emptyOptions & #evidence .~ Just (evidenceRequest "nightly-review-2026-08-10")
resp <- withTrace (fileSink "/tmp/evidence.jsonl") model ctx opts
```

```console
$ jq 'select(.kind == "call_evidence") | .evidence' /tmp/evidence.jsonl
$ baikai agent run review --prompt-stdin --evidence-file run.json
```

## Limits

- **A caller who does not opt in pays nothing** — no digest, no call identifier,
  no event, and the request envelope is never even forced. The converse is that
  evidence exists only where someone asked for it.
- `fully_observed` is **unreachable on every shipped transport**: neither
  Anthropic nor any OpenAI-compatible host echoes the reasoning configuration it
  applied. The top of the scale is currently aspirational.
- `codex exec` (0.146.0) names no model anywhere in its event stream, so no Codex
  run can exceed `correlated`.
- On the unattended surface two things gate what a record can prove, and neither
  is the default: the job must **capture** output, and the tool must be told to
  print a structured format (`--output-format json` for `claude`, `--json` for
  `codex exec`). Without both, the record honestly says `"unobserved"`.
- The `adjustments` list carries **sampling** changes as well as reasoning ones:
  `sampling_dropped_unsupported_model` and `sampling_dropped_unsupported_api`
  name parameters removed because the model generation or the API rejects them.
  They carry a `fields` array and no `requested` level, and can appear on a call
  whose `thinking.mode` is `absent`, so a reader must not treat that mode as
  "nothing happened". Strict evidence mode does not refuse a call over them —
  the contract is refusing a call that would weaken the requested *thinking
  level*.
- `ModelCallEvidence` has **no `FromJSON`**, deliberately: it embeds a `Cost`
  whose exact `Rational` amounts encode through an approximating `Scientific`, so
  a decoder would return a different value than was encoded. Read a record as a
  plain `Data.Aeson.Value`.
- A record proves what a provider *said*, not what it did. It is a boundary
  record, not an attestation, and nothing here is signed.
- `onSinkFailure` is documented as a hook a future release replaces. Much of the
  supporting machinery lives in `Baikai.Provider.Cli.Internal`, which is outside
  the PVP contract — hence `experimental`.
