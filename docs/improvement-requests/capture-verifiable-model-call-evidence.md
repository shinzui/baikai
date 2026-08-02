---
type: Improvement Request
title: Capture verifiable model-call evidence at the provider boundary
description: Record the requested and provider-observed model, effective thinking configuration, provider correlation identifiers, usage, and payload digests for every Baikai call without claiming that client-side evidence proves provider internals.
timestamp: "2026-08-02T18:29:04Z"
requestId: IR-3
status: proposed
origin: mori://shinzui/kikan/okf/use-cases/concepts/UC-8
---

# Improvement Request: capture verifiable model-call evidence at the provider boundary

## Why

Baikai already owns provider-neutral model selection, `ThinkingLevel`, provider-specific thinking
translation, response and usage normalization, cost accounting, and trace events. Its current trace
events record the configured `Model` and token totals, but they do not preserve the requested thinking
level, the exact provider wire representation, provider request identifiers, or a distinction between
requested and provider-observed model identity. A caller can therefore show what its process was
configured to request, but cannot construct a complete, reviewable record of what crossed the provider
boundary.

This request supplies the call-level evidence consumed by the sanctioned-run attestation in
`mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-7` and the portfolio contract in
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`.

## Requested contract

Add a versioned `ModelCallEvidence` value emitted once for every terminal provider call. The public
shape may follow Baikai conventions, but it must preserve:

- a caller-supplied run id and a globally unique call id;
- provider, API/transport, normalized endpoint identity, and Baikai/provider implementation version;
- requested model id and the model id returned or otherwise observed from the provider;
- requested canonical `ThinkingLevel`;
- the exact effective provider representation after compatibility mapping, including effort text,
  adaptive/manual mode, token budget, and any clamping or collapse such as `minimal -> low`;
- provider response id, provider request id or equivalent correlation value, and client request id;
- start and terminal timestamps, latency, status, retry/fallback relationship, and normalized error;
- input, output, cached-input, and reasoning/thinking token usage when reported;
- canonical hashes of the redacted request envelope and terminal response envelope.

Requested, effective, and observed values are separate fields. A provider response that does not echo
the model or thinking configuration records `unobserved`; it must not copy the request into an
“observed” field. Likewise, reasoning-token usage is corroborating usage evidence, not a replacement
for the requested effort setting.

## Dispatch behavior

The provider adapter is the authority for translating canonical options to wire settings, so it must
return the translation description used for the actual request rather than re-compute it later in a
trace sink. Unsupported thinking levels and prohibited fallback behavior fail before dispatch when the
caller requests strict evidence mode.

API providers should capture server response metadata before the SDK or stream adapter discards it.
CLI providers should capture the executable identity and version, rendered argument-vector digest,
structured result identifiers, and effective configuration exposed by the CLI. When a CLI cannot
report the selected model or effort, the evidence remains explicitly weaker; successful process exit
does not upgrade it to provider-observed.

Baikai must allow a caller to require minimum evidence strength. A critical workload can reject a
transport that cannot provide required correlation or observed fields, while ordinary callers retain
the current best-effort trace behavior.

## Privacy and integrity

The evidence envelope contains hashes and bounded summaries, not API keys, raw prompts, thinking text,
tool payloads, or complete responses. Header capture uses an allow-list. Canonical hashing must be
stable across map ordering and JSON encoder differences, with an explicit schema/version identifier.

Baikai does not sign run attestations or decide whether a model is sanctioned. It reports what it
requested, translated, and observed at its boundary. Shikigami correlates calls, evaluates the pinned
profile, binds them to the reviewed artifact, and signs the run-level statement.

## Acceptance

This request is complete when:

1. OpenAI-compatible API, Anthropic API, Codex CLI, and Claude CLI fixtures emit schema-valid terminal
   evidence for successful and failed calls.
2. Tests prove every canonical thinking level's exact provider translation, including clamping,
   adaptive/manual mode, and budget mappings.
3. A provider-returned model and request id are preserved independently of the configured model; absent
   metadata remains absent.
4. Run/call correlation survives streaming, retries, early consumer termination, and trace-sink
   failure without emitting two terminal records.
5. Strict evidence mode rejects a provider/transport that cannot meet the caller's required evidence
   strength or would silently downgrade thinking.
6. Golden tests prove stable canonical request/response hashes and verify that credentials, prompt
   bodies, thinking text, and tool payloads are absent.
7. Existing trace and cost consumers can migrate without treating the new evidence as a claim about
   provider-internal execution.

## Non-goals

This request does not define the organization-wide sanctioned-model policy, sign an agent-run proof,
verify a code-review gate, or claim independent knowledge of provider internals. Provider-signed
receipts and confidential-computing attestation would be stronger future evidence and require their
own provider support and threat model.

## References

- `mori://shinzui/kikan/okf/use-cases/concepts/UC-8`
- `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`
- `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-7`
- `mori://shinzui/baikai/packages/baikai`
- `mori://shinzui/baikai/packages/baikai-openai`
- `mori://shinzui/baikai/packages/baikai-claude`
