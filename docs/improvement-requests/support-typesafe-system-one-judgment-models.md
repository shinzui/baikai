---
type: Improvement Request
title: Support TypeSafe System One judgment models
description: >-
  Add a TypeSafe System One (Jev) provider and provider-neutral structured-data content that
  carries per-answer probability distributions, so callers can ask declared closed-set
  questions and read calibrated evidence instead of generated text.
timestamp: 2026-09-26T03:50:00Z
requestId: IR-10
status: proposed
origin: mori://shinzui/shikumi
---

# Improvement Request: Support TypeSafe System One Judgment Models

## Status

Proposed. This is the Baikai-owned phase of
`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`.
Shikumi's decision-type and local-derivation work can proceed offline without it. Routing a real
program to Jev is blocked on it.

## Context

TypeSafe's System One models, currently the `jev-*` family (`jev-latest`, `jev-preview`, and
versioned ids such as `jev-1.13.0`), are not generative. Each request carries one *state* and a
set of declared *questions*. Jev returns a probability distribution over each question's
declared answers. It never produces free text. DSPy 3.4.0 ships a client for it through its
vendored `lm15` layer; the wire facts below come from that implementation, which is the only
tested client we have seen.

- **Endpoint.** `POST https://api.typesafe.ai/v1/systemone`, with a bearer credential taken from
  `TYPESAFE_API_KEY`. The model listing is `GET /v1/models`, which returns `{"models": [{"name": …}]}`.
  Each reply carries an `x-typesafe-request-id` header.
- **Request body.** `{"model": …, "state": <string | JSON value>, "questions": {<name>: <question>}}`.
  A question has one of three types:
  - `{"type": "noul", "instructions": …}` is a yes/no judgment.
  - `{"type": "choice", "instructions": …, "criteria": {<label>: <description | null>}}` selects
    one of at most 255 labels.
  - `{"type": "score", "instructions": …, "criteria": [<level description>, …]}` rates on 2 to 10
    ordered levels, numbered 0 to N−1.

  Descriptions and instructions may be any JSON value.
- **Response body.** `{"answers": {<name>: …}, "usage": {"input_tokens", "output_tokens"}, "model": …}`.
  The answer shapes are:
  - A noul answer is `{"type": "noul", "noul": p}`, where `p` is P(true).
  - A choice answer is `{"type": "choice", "probabilities": {<label>: p}, "choice": <label>}`.
  - A score answer is `{"type": "score", "probabilities": {"0": p0, …}}`.

  The answer keys must match the declared questions exactly. Each probability must be a finite
  number in [0, 1]. `lm15` deliberately validates each probability on its own and never
  requires them to sum to 1.
- **Refused shapes.** Jev has no system prompt, no multi-turn conversation, no media, no tools,
  no streaming, and no sampling or generation controls (temperature, top-p, max tokens, stop,
  seed, logprobs, reasoning).

`lm15` maps this onto a generic request. The state is the single user message, which must hold
exactly one text or data part. The questions are read from a `json_schema` response format.
A top-level property is a judgment when it has one of three shapes:

- `"type": "boolean"`;
- a string `enum`, or an `anyOf` of `const` branches whose `description` fields become criteria;
- an integer `enum` or `anyOf` of `const` values that is exactly `0..n-1`, which is ordered.

A property's `description` becomes the question's instructions. Any other property is
free-form, and the request is refused before it reaches the wire.

Baikai cannot express this exchange today:

- **No field for probabilities.** `Baikai.Content.AssistantContent` is only text, thinking, and
  tool calls, and `Baikai.Response.Response` has no free-form provider-data field. The
  per-answer distribution, which is the whole value of the call, has nowhere to go.
- **No structured user input.** `Baikai.Content.UserContent` is only text and images. A JSON
  state therefore has to be sent as a string. The model would receive it as text rather than
  as structured data.
- **No provider for the endpoint.** No provider speaks `/v1/systemone`. Every baikai provider is
  also built around a streamed `AssistantMessageEvent` sequence, while this endpoint answers in
  one piece.
- **No model capability for it.** Nothing on `Baikai.Model.Model` says a model answers only
  declared judgments. Callers such as Shikumi currently decide structured-output capability
  themselves from `(provider, api)` pairs.

## Requested contract

1. **Structured assistant data with evidence.** Add an assistant content variant, provisionally
   `AssistantData`. It carries:
   - a JSON value holding the chosen answer per field;
   - an optional map from field name to a distribution over that field's declared keys, with
     probabilities as `Double`;
   - an optional method tag, such as `provider_classification`, that says how the probabilities
     were obtained.

   Its JSON encoding, stream events, and trace/cost-log encodings must round-trip it. The
   stream events may be a single start/end pair, since no provider streams it incrementally.
   Callers persist and replay whole `Response` values: Shikumi's response cache and trace replay
   both do this.
2. **Structured user data.** Add a user content variant carrying a JSON value, provisionally
   `UserData`. Providers that cannot send structured data should render it deterministically as
   JSON text, or refuse with a typed error. They must never silently drop it.
3. **A `baikai-typesafe` package.** It registers an `ApiProvider` under a new `Api` tag and
   includes catalog entries for `jev-latest` and `jev-preview`. It must:
   - resolve credentials from `TYPESAFE_API_KEY`;
   - accept a base-URL override;
   - translate a `Context` plus a `JsonSchema` response format into the systemone payload, using
     the judgment convention above;
   - parse and strictly validate the reply into one `AssistantData` part with probabilities;
   - map HTTP failures onto the existing `BaikaiError` classification: 401 is auth, 429 is rate
     limit, 400/422 are invalid request, 5xx is server, and an "unknown model" 400 is an
     unsupported model;
   - record `x-typesafe-request-id` as the provider request identifier in `ModelCallEvidence`.

   Its stream function may emit a synthetic start / data / done sequence around the single reply.
4. **Typed refusal before the wire.** Any request carrying a feature from the refused-shapes list
   above fails with a typed unsupported-feature error. So do free-form schema properties, a
   choice with more than 255 keys, and a score with more than 10 levels. The error names the
   offending field, and no HTTP request is sent. Sampling controls that cannot change the answer
   may be dropped rather than refused, but the drop must be recorded in the call evidence.
5. **A capability a caller can read.** Expose on `Model`, or through a pure function over it,
   whether a model answers only declared judgments. Shikumi can then route on it without
   hard-coding provider names.

## Acceptance

1. An offline test against a local HTTP fixture sends a `Context` whose single user message is a
   `UserData` state. The response format has one boolean, one described string choice, and one
   ordered 0..2 integer property. The test observes the exact systemone payload on the wire and
   decodes the reply into one `AssistantData` part whose three distributions match the fixture.
2. Each refused shape from Requested contract item 4 fails before any bytes reach the fixture.
   So does a malformed reply: missing answers, extra keys, a probability outside [0, 1], or a
   choice label that was not declared.
3. A `Response` containing `AssistantData` round-trips through its JSON encoding byte-for-byte
   stable, and appears in trace events without losing the distributions.
4. An opt-in live smoke test, not run in CI and gated on `TYPESAFE_API_KEY`, runs one call
   against `jev-latest`.
5. The release notes and the major/minor version bumps state which packages changed their
   public content types.

## Non-goals

- **Decision types and decoding.** Rich decision types (yes/no, choice, and score values with
  confidence), per-field thresholds, cuts, and weights, and deriving answers locally from
  probabilities are all Shikumi-owned. They are specified by the MasterPlan named in Status.
- **Generative probabilities.** Extracting token log-probabilities from generative providers is
  a separate question that this request does not ask for.
- **Streaming.** Streaming judgments is out of scope, because the endpoint has no stream.

## References

- MasterPlan: `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`
- Shikumi's ExecPlan for the consumer side, which routes decision outputs to System One models:
  `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`
- DSPy 3.4.0 reference implementation, where the artifact-level URIs are pending:
  - wire provider: `mori://stanfordnlp/dspy`, path `dspy/_vendor/lm15/providers/typesafe.py`;
  - judgment schema convention: `mori://stanfordnlp/dspy`, path `dspy/_vendor/lm15/judgments.py`;
  - user-facing contract: `mori://stanfordnlp/dspy`, path `docs/docs/api/experimental/DecisionTypes.md`.
