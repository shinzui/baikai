---
title: "Categorised error model with retry classification"
type: Capability
description: "Branch on a typed BaikaiError — ten categories, an HTTP status, a Retry-After hint, and a subprocess exit code — delivered in band on the Response or the terminal event, so retry policy is written against structure instead of parsed out of provider error text."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-8
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.2.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.Error
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/ErrorSpec.hs
    proves: "The pure classifiers: 429 with Retry-After becomes RateLimited carrying the hint, an overflow body on 400 becomes ContextOverflow, 401 becomes AuthError, 413 becomes ContextOverflow from the status alone, 500 defers to status as TransientError, status wins over a misleading body, and an HTTP-date Retry-After converts to seconds against a reference instant while parseRetryAfterSeconds stays integer-only."
  - kind: test
    resource: baikai/test/ErrorInfoSpec.hs
    proves: "BaikaiError round-trips through JSON, including values with omitted optional metadata fields."
  - kind: test
    resource: baikai-claude/test/ErrorClassSpec.hs
    proves: "The Anthropic provider delegates transport failures to the shared classifier and maps mid-stream Anthropic error events onto the shared categories."
  - kind: test
    resource: baikai-openai/test/ErrorClassSpec.hs
    proves: "The OpenAI-compatible provider does the same and classifies in-band error frames on 2xx streams by status, code, type, then message."
  - kind: test
    resource: baikai/test/TransportClassifySpec.hs
    proves: "One classifier for every shape http-client, tls and the socket layer raise: a reset, a mid-chunk close, a short body and a post-handshake TLS failure are TransientError; a failed handshake, a server that does not speak HTTP and a programming error are not."
  - kind: test
    resource: baikai-claude/test/MidStreamSpec.hs
    proves: "A stream that starts healthily and then loses its connection terminates as a retryable EventError carrying the partial text, and a stalled socket is cut off by timeoutMs while a non-positive bound is refused before any connection is opened."
  - kind: test
    resource: baikai-openai/test/MidStreamSpec.hs
    proves: "The same, plus an in-band error frame on a 2xx stream terminating with the frame's own classification and upstream status."
---

# Categorised error model with retry classification

`BaikaiError` is a record, not a string. It carries an `ErrorCategory` —
`AuthError`, `RateLimited`, `ContextOverflow`, `InvalidRequest`,
`ContentFiltered`, `TransientError`, `DecodeFailure`, `ProcessFailure`,
`ProviderUnavailable`, `OtherError` — plus an optional HTTP status, a `retryAfterSeconds` hint, and a
subprocess exit code. `isRetryable` answers the question most callers actually
have, and `classifyHttpStatus` / `classifyHttpStatusWithBody` are pure, so retry
policy is testable without a provider.

Errors arrive **in band**. A failed `completeRequest` returns an error-shaped
`Response` with `errorInfo` set rather than throwing, and a failed stream
terminates with an `EventError` carrying the same value. Both API providers and
both subprocess providers classify into the same categories, so one retry policy
covers every backend.

Classification prefers the HTTP status over the body: a 429 whose body mentions
context length is still `RateLimited`, because acting on the body there would
retry the wrong way.

A transport failure is classified by **where** it happened, not by what type it
is. `Baikai.Provider.Transport.Classify` is core's single rule, shared by both
HTTP providers and available to a third-party one: anything that breaks or ends
the connection after the request went out is `TransientError`; anything that says
the request or the configuration is wrong is not retryable; a programming error
is neither and stays `OtherError`. This matters because `http-client` delivers
the same underlying failure in three different shapes depending on the phase it
happened in.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
resp <- completeRequest model ctx opts
case responseError resp of
  Just err | isRetryable err -> backOff (retryAfterSeconds err) >> retry
  Just _ -> giveUp
  Nothing -> use resp
```

## Limits

- **baikai implements no retry policy.** It classifies; the caller decides. There
  is no built-in backoff, no retry budget, and no circuit breaker.
- Errors are in band, so a caller who never inspects `errorInfo` reads a failure
  as an empty answer. This is a deliberate change made in 0.3.0.0 and it is the
  most common way to misuse the library.
- An HTTP-date `Retry-After` is converted to seconds against the response's
  `Date` header (or the local clock when absent); a date already in the past
  yields `0`.
- A failure while the body is streaming is `TransientError` whether it surfaces
  as a reset, a mid-chunk close, or a TLS termination; a TLS handshake that fails
  is not retryable, because against a well-known API host that is a trust-store
  or protocol mismatch a retry reproduces.
- HTTP 413 is `ContextOverflow` from the status alone, whatever the body says.
- A provider that refuses or filters the content — OpenAI's
  `finish_reason: "content_filter"`, Anthropic's `refusal` stop — is
  `ContentFiltered`, added in baikai 0.6.0.0. It is not retryable: the caller
  must change what it sent. Before 0.6.0.0 both landed in `OtherError` and the
  only way to tell a filter from any other failure was to match on the message
  text.
- Category assignment for a non-OpenAI, non-Anthropic host depends on that host
  imitating the status conventions of the API it is emulating. A compatible host
  with idiosyncratic statuses lands in `OtherError`.
- `ProcessFailure` carries the subprocess exit code, but a coding-agent CLI's
  exit code says little about *why* it failed; the classification is only as good
  as what the tool printed.
