---
type: Explanation
title: Model-Call Evidence
description: Explain model-call evidence, provenance strength, strict mode, and limitations.
docId: DOC-6
tags: [evidence, provenance, tracing, verification, providers]
generated:
  by: human:nadeem
  at: 2026-08-27T21:59:56Z
---

# Model-Call Evidence

A trace event answers "what did this call cost?". Evidence answers a
different and harder question: **what actually crossed the boundary
between your process and the provider, and how much of that can be
corroborated?**

A `ModelCallEvidence` record keeps three things strictly apart and never
collapses one into another:

- what you **requested** — the model id and reasoning level you asked for;
- what baikai **translated** that into for the specific provider you
  reached — the effort word, the token budget, the wire field actually
  sent, and every clamp, collapse, or drop applied on the way;
- what the provider was **observed** to report back — recorded such that
  a field the provider stayed silent about reads as `"unobserved"` and is
  **never** filled in from the request.

## It costs nothing to ignore

If you never set `Options.evidence`, nothing changes and nothing is
spent. No digest is computed, no call identifier is generated, no
executable version is probed, and no evidence event is emitted. The
trace output is byte-identical to what the same call produced before
evidence existed, and a golden-fixture test in the repository pins that.

This is a hard property of the design rather than a best effort. The two
digests each hash the full request envelope, and imposing two SHA-256
passes over every prompt on someone who only wanted token counts would
be a real and unjustifiable cost.

## Asking for a record

```haskell
import Baikai

let opts = emptyOptions & #evidence .~ Just (evidenceRequest "nightly-2026-08-05")
resp <- withTrace sink model ctx opts
```

`evidenceRequest` takes your own identifier for the logical unit of work
this call belongs to. Baikai treats it as opaque text and never parses
it. The record it produces reaches your trace sink as a fourth event
kind:

```bash
jq 'select(.kind == "call_evidence") | .evidence' trace.jsonl
```

Two spelling details matter when you write that filter. A trace line has
no `data` wrapper — the event's own fields sit beside `kind` — and the
evidence record inside spells its fields in `snake_case` while the trace
event around it does not. So it is `.evidence.requested_model`, never
`.data.evidence.requestedModel`. The difference is deliberate: an
evidence record renders an absent field as explicit `null` so a reader
can tell "baikai recorded nothing here" from "this record predates the
field", while a trace event drops absent fields to keep log lines small.

There is deliberately no `FromJSON` for the record. `Usage` embeds a
`Cost` whose exact `Rational` amounts encode through an approximating
`Scientific`, so a decoder could not round-trip one faithfully and would
be claiming a fidelity it does not have. Read an emitted record as a
plain `Value` and match on its `schema_version`.

## What the record says

| field | meaning |
|---|---|
| `schema_version` | the string consumers pin against |
| `run_id`, `call_id`, `attempt`, `supersedes` | your identifier, baikai's globally unique one, and the retry provenance you supplied |
| `endpoint` | provider, api, transport, sanitized endpoint, baikai's version, the implementation's version |
| `requested_model`, `thinking` | what you asked for, and what it became on the wire |
| `observed_model`, `observed_thinking`, `response_id`, `provider_request_id`, `usage` | what the provider reported, or `"unobserved"` |
| `started_at`, `ended_at`, `latency_ms`, `status`, `error_info` | how it went |
| `strength` | the record's honest self-assessment |
| `request_commitment`, `request_configuration`, `response_commitment` | the digests |

### The thinking translation

This is the field that makes an otherwise silent downgrade visible. It
carries the level you asked for, the mode it travelled in, the exact
effort word and token budget sent, the wire field they sent in, and a
list of `adjustments` — one per thing that happened to your request on
the way to the wire. An empty list means the request was expressed
exactly.

The provider adapter that built the request owns this value, and no
downstream layer may re-derive it. Re-deriving it in a trace sink would
mean reimplementing every provider's translation and per-host
compatibility lookup, and would silently diverge the first time a
translation changed.

There are eight places baikai currently adjusts a request between what
you asked for and what goes on the wire; only four of them are effort
mappings, and two are not about reasoning at all:

| adjustment | when |
|---|---|
| `effort_clamped` | the word sent differs from the level you named — `minimal` becomes `low`, `xhigh` and `max` become `high`, on hosts that route through the compatibility table |
| `effort_collapsed_to_toggle` | Z.ai and Qwen accept a bare on/off flag with no depth, so **every** level is wire-identical there |
| `effort_omitted` | Anthropic's adaptive `high` sends no effort field, making the request indistinguishable on the wire from the provider's own default |
| `thinking_dropped_unsupported_model` | the chosen model does not advertise reasoning support |
| `thinking_dropped_unsupported_host` | the host exposes no reasoning controls |
| `thinking_dropped_budget_exceeded` | the computed thinking budget does not fit the resolved output-token ceiling — **the least discoverable of them**, because it fires when you lower `maxTokens` on a reasoning model |
| `sampling_dropped_unsupported_model` | `temperature` and `top_p` were removed because the model generation rejects them (Anthropic's adaptive-era generations return a 400 for them) |
| `sampling_dropped_unsupported_api` | `seed`, `frequency_penalty` or `presence_penalty` were removed because the API has no such field on any generation (Anthropic Messages) |

The last two carry a `fields` array naming what was removed, in wire
order, and **no** `requested` level — they are not about thinking, and
they appear on calls whose `thinking.mode` is `absent`. Strict evidence
mode does not refuse a call over them: the contract is refusing a call
that would weaken the requested *thinking level*, and a parameter the API
never had is not that. The drop is still in the record, where you can see
it.

The native OpenAI shape is deliberately not on that list. It sends every
canonical level verbatim and expresses all six exactly.

### The two digests

`request_commitment` covers the canonicalized request envelope with
nothing removed, prompt included. It leaks nothing on its own —
publishing it does not disclose the prompt — and anyone who
independently holds the request can recompute it and confirm that a
given record describes that request. That is what makes it possible to
bind a recorded call to a reviewed artifact.

`request_configuration` covers the same request with all content
removed, through an explicit allow-list. Two calls that ask the same
model the same way about different subjects produce the same value here.
That is the point: it is safe to compare across runs that legitimately
differ in content, and it must never be presented as binding a run to
any particular input.

The projection is an allow-list and never a denylist. A denylist over
request bodies from the Anthropic Messages API and seven
OpenAI-compatible hosts would miss a field the first time any of them
added one, and the failure mode would be prompt content leaking into a
digest callers were told is content-free. The allow-list fails the other
way: a genuinely new configuration field is silently omitted until
someone adds it, which loses fidelity rather than leaking.

A **JSON schema is content wherever it appears.** A structured-output
schema carries author-written `description` strings that describe the
caller's domain as freely as a prompt does, so `output_config` keeps its
effort and reduces its `format` to a type and a character count, and
`response_format` keeps its type and reduces its `json_schema` to a name,
a strictness flag and a character count — the same treatment a tool's
`input_schema` already got.

On the three subprocess transports the request envelope is an argument
vector rather than a JSON object, and the projection admits named fields
only — so their configuration digest is currently degenerate. That is
the allow-list failing safe, and it is noted here rather than hidden.

`response_commitment` covers what came back — the assembled content, the
stop reason, and the **provider-reported token counts** — and is
`"unobserved"` when the call failed before a complete response arrived. A
digest of an empty envelope would be a real-looking value standing for a
response that never came.

It deliberately does **not** cover the computed cost. The cost comes from
the caller's own catalog rates rather than from the response, so
including it made the digest change whenever a price was edited, and left
a verifier holding only the response unable to recompute it.

Both of those changes are why records now say
`baikai.model-call-evidence/2.0`. A verifier selects its rules by
`schema_version`: under `1.x`, `response_commitment` also covered the
cost and `request_configuration` carried both structured-output schemas
verbatim.

## Strength: what a record proves

```text
requested_only  <  correlated  <  model_observed  <  fully_observed
```

- **`requested_only`** — baikai recorded what it requested and what it
  translated. The provider corroborated none of it.
- **`correlated`** — the provider returned an identifier, so the call can
  be located in the provider's own records; it did not say which model
  ran.
- **`model_observed`** — the provider reported the model it ran, as well
  as an identifier.
- **`fully_observed`** — the provider also reported its effective
  thinking configuration.

Each transport has a maximum it can reach under ideal conditions:

| transport | maximum | why |
|---|---|---|
| Anthropic Messages | `model_observed` | echoes the model and a `request-id` header |
| OpenAI-compatible Chat Completions | `model_observed` | echoes the model and a correlation header |
| `claude -p` | `model_observed` | names the model that consumed tokens in its result event |
| `codex exec` | `correlated` | names a thread identifier but **no model, anywhere** |
| unattended agent run | the tool's own maximum, or `requested_only` under `inherit` | nothing can be observed from output baikai never held |
| a custom transport | `requested_only` | baikai knows nothing about it |

**No transport reaches `fully_observed`**, because no provider in this
ecosystem echoes the reasoning configuration it applied. A
reasoning-token count corroborates output volume and says nothing about
which effort setting was in force, so it is not that echo.

**A successful outcome never raises the strength.** A 200 means the
request was accepted, not that any particular model ran. A coding-agent
CLI that exits zero has demonstrated that it ran and did not crash — and
since subprocess calls almost always exit zero, encoding that as
corroboration would make the weakest evidence in the system look like the
strongest.

## Strict mode: demanding rather than hoping

A workload that must be able to show which model ran cannot express that
by inspecting the record afterwards — by then the work is done and the
money is spent. Strict mode makes baikai refuse **before dispatch**:

```haskell
let opts = emptyOptions
      & #thinking .~ Just ThinkingMax
      & #evidence .~ Just
          (evidenceRequest "run-42" & #strictness .~ EvidenceRequired EvidenceModelObserved)

resp <- completeRequest model ctx opts
```

Two things refuse. The transport's declared maximum being below what you
required, and your reasoning request being one the transport would
weaken. Both are reported together rather than one per attempt, so an
operator fixing a configuration sees all of it in one run:

```text
strict evidence refused this call before dispatch: this transport can reach
at most correlated evidence, and the call required model_observed; the
reasoning-effort request would not reach the provider as asked: max would
become a bare on/off toggle, so this host cannot tell it from any other level
```

The call returns an error-shaped `Response` in the `InvalidRequest`
category, carrying an evidence record whose `thinking` field shows the
very downgrade that caused the refusal. Nothing was sent.

Requesting no reasoning level at all is never a downgrade — there is
nothing to weaken. Every non-empty adjustment list is one, including
`effort_omitted`: that request is not weaker in effect, merely
indistinguishable on the wire from the default, and a caller who demanded
strict evidence and cannot later prove they asked for `high` has not got
what they demanded.

Strict mode also changes what a trace-sink failure means. Baikai
normally isolates sink failures from calls — the sink runs on its own
worker, its exception is reported on stderr, and the call succeeds. For
a strict caller that is backwards: they asked for a record and the record
did not survive, so the call fails rather than handing back an answer
they cannot account for.

**A sink that blocks counts as a failure too.** Baikai waits at most one
second for the sink to confirm it has taken this call's events. On expiry
the worker is abandoned — not killed, which would abort the sink's fold
mid-step and lose its end-of-stream action — the call proceeds, and one
line goes to stderr:

```text
baikai: the trace sink did not confirm delivery within 1000 ms; its worker was abandoned, and events already queued may still be delivered later
```

A strict caller gets a failed call, with a message saying the record was
`not confirmed written`. That wording is deliberate: the events may still
be delivered when the sink eventually unblocks, but they were not
confirmed delivered before the call returned, and a record you cannot
account for at the moment you get the answer is not evidence.

**A record that was never built fails the call the same way.** A provider
can pass the gate and then attach nothing to its terminal, which used to
give a strict caller a successful answer, no record, and no error
anywhere — the same failure the sink rule exists to prevent, arriving
through a different door. Such a call now fails with a message beginning
`this call required evidence, but the provider attached no evidence
record`. A call that failed for the provider's own reason keeps the
provider's error, which is the more useful of the two. Those are the two
places in baikai where a call that reached the provider and came back is
nevertheless reported failed; see
[ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md).

The gate compares your requirement against the provider's own
`strengthCeiling`, not against a table keyed by the `Api` tag. A custom
transport that observes a model can therefore serve a strict caller who
requires that it did — which the tag-keyed table made impossible, because
it answered `requested_only` for every `Custom` tag. The declaration is a
promise: a provider that declares more than it delivers is the one
remaining way to make strict mode lie.

**Callers who do not opt in are never refused**, on any transport at any
reasoning level. The test for that guarantee is exhaustive rather than
representative, because it is the promise every existing caller depends
on without knowing the feature exists.

### When the record is written

On a call you drain to its terminal — `withTrace`, or a fold that keeps
consuming — the evidence record is pushed to the sink **synchronously,
before the terminal event reaches you**, and `withTrace` does not return
until the sink has taken it (or the one-second bound expires). That is
the ordinary case and it holds no matter which sink you use.

A consumer that **abandons the stream** — `Stream.take 1`, a fold that
stops early, an exception on the consumer's side — is different. Baikai
still records a synthetic `CallFailed` and an `aborted` evidence record,
but they are delivered from streamly's garbage-collection hook: at the
next major collection after the abandoned stream becomes unreachable, not
at the moment you stopped reading. A short-lived process that abandons a
stream and exits may never write them at all.

If you need the record before your process exits, drain to the terminal.
`withTrace` does this for you; with `withTraceStream`, use a fold that
keeps consuming after you have what you need rather than `Stream.take`.
Calling `System.Mem.performMajorGC` after abandoning is a last resort,
not a guarantee. See
[ADR 0015](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md).

### On the unattended agent surface

`baikai agent run --require-evidence STRENGTH` refuses the same way,
before anything is spawned, taking the same strength names a record
spells. Its gate is **structural rather than predictive**: it refuses
when the requirement is impossible with this configuration — an
`inherit` job can observe nothing, and a `codex` job can never learn a
model — and stays silent when the requirement is merely uncertain. A run
that could have reported what you needed and did not says so in its own
record's `strength`; failing it after the fact would destroy a report of
work that really happened.

Getting above `requested_only` from an unattended run takes two things,
neither of which is the default: the job must **capture** output, and the
tool must be configured to print a structured format — `--output-format
json` for `claude`, `--json` for `codex exec` — through the job's
`provider-args`. See
[Unattended Agent Runs](unattended-agent-runs.md#recording-what-a-run-was).

## Scope: what this is not

Baikai reports what it requested, what it translated, and what it
observed at its own boundary. That is the whole claim.

It **does not sign anything**. It **does not know what happened inside a
provider**. It **has no opinion about which models are sanctioned**. It
**does not own retries** — baikai has no retry loop, so `attempt` and
`supersedes` are provenance you supply, not something baikai observes.

A trace record is evidence in the sense that a well-kept logbook is
evidence: a contemporaneous record by a party with no independent
knowledge of the other side. Anyone presenting it as more than that is
misrepresenting it. Provider-signed receipts and confidential-computing
attestation are strictly stronger and need provider support baikai does
not have.

## Migrating an existing consumer

A caller who never mentions `Baikai.Evidence` sees no runtime cost and no
behavioural change beyond the four corrections below. A caller who
implements a **custom provider** or a **custom trace sink** has edits to
make.

**If you implement a custom provider.** `ApiProvider` gains a fourth
field, `describeThinking :: Model -> Options -> ThinkingTranslation`,
which the pre-dispatch strictness gate calls. If your provider has no
reasoning controls, `\_ _ -> noThinkingRequested` is correct and honest.
`TerminalPayload`'s two smart constructors take the evidence as their new
first argument; passing `Nothing` reproduces the previous behaviour
exactly.

It gains a **fifth** field in the next release, `strengthCeiling ::
EvidenceStrength`, and `checkEvidenceRequirements` takes that ceiling
where it took an `Api`. `EvidenceRequestedOnly` is the honest declaration
for a provider that attaches no record or a minimal one, and matches what
the old tag-keyed table said about every `Custom` transport — so it is
also the no-behaviour-change answer. Declare more only if you attach a
record that reaches it, and write the test that drives it there.

**If you implement a custom trace sink.** `TraceEvent` gains a fourth
constructor, `CallEvidence`. A sink that pattern-matches exhaustively
must handle or ignore it. `FromJSON TraceEvent` deliberately refuses a
`call_evidence` line with an explanation rather than decoding it, for the
round-trip reason above.

**If you read `CallFinished`.** It gains `cachedInputTokens`,
`cacheWriteTokens`, `reasoningTokens`, and `totalTokens`. Those are
additive and a consumer reading only `inputTokens` and `outputTokens` is
unaffected. But `usd` **used to be omitted when the computed cost was
zero**, and is now always present. A dashboard that read an absent `usd`
as "cost unknown" must stop: a zero now means zero.

**If you track cost for the CLI providers.** They used to report
`zeroUsage` on every call, so `claude -p` and `codex exec` calls appeared
to consume no tokens and cost nothing. Both tools report their own
counts and baikai now carries them through; `claude` additionally reports
a total cost, which now populates `Usage.cost` exactly. **Real tokens and,
for `claude`, a real dollar figure now appear where zeroes used to.**
That is the correction, not a regression — but totals over historical
data will not match totals over new data.

**If you use `baikai-trace-otel`.** It gains span attributes and loses
nothing. `Baikai.Cost.Log`'s `CallLogEntry` is unchanged in shape.
