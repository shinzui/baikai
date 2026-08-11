---
title: "Categorised error model with retry classification"
type: Capability
description: "Branch on a typed BaikaiError — nine categories, an HTTP status, a Retry-After hint, and a subprocess exit code — delivered in band on the Response or the terminal event, so retry policy is written against structure instead of parsed out of provider error text."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
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
    proves: "The pure classifiers: 429 with Retry-After becomes RateLimited carrying the hint, an overflow body on 400 becomes ContextOverflow, 401 becomes AuthError, 500 defers to status as TransientError, status wins over a misleading body, and an HTTP-date Retry-After is ignored rather than misparsed."
  - kind: test
    resource: baikai/test/ErrorInfoSpec.hs
    proves: "BaikaiError round-trips through JSON, including values with omitted optional metadata fields."
  - kind: test
    resource: baikai-claude/test/ErrorClassSpec.hs
    proves: "The Anthropic transport maps servant-client ClientErrors and mid-stream Anthropic error events onto the shared categories."
  - kind: test
    resource: baikai-openai/test/ErrorClassSpec.hs
    proves: "The OpenAI-compatible transport does the same for its own status and mid-stream error text."
---

# Categorised error model with retry classification

`BaikaiError` is a record, not a string. It carries an `ErrorCategory` —
`AuthError`, `RateLimited`, `ContextOverflow`, `InvalidRequest`,
`TransientError`, `DecodeFailure`, `ProcessFailure`, `ProviderUnavailable`,
`OtherError` — plus an optional HTTP status, a `retryAfterSeconds` hint, and a
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

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
resp <- completeRequest model ctx opts
case resp ^. #errorInfo of
  Just err | isRetryable err -> backOff (retryAfterSeconds err) >> retry
  Just err                   -> giveUp err
  Nothing                    -> use resp
```

## Limits

- **baikai implements no retry policy.** It classifies; the caller decides. There
  is no built-in backoff, no retry budget, and no circuit breaker.
- Errors are in band, so a caller who never inspects `errorInfo` reads a failure
  as an empty answer. This is a deliberate change made in 0.3.0.0 and it is the
  most common way to misuse the library.
- An HTTP-date `Retry-After` is ignored rather than converted; only the integer
  seconds form produces a hint.
- Category assignment for a non-OpenAI, non-Anthropic host depends on that host
  imitating the status conventions of the API it is emulating. A compatible host
  with idiosyncratic statuses lands in `OtherError`.
- `ProcessFailure` carries the subprocess exit code, but a coding-agent CLI's
  exit code says little about *why* it failed; the classification is only as good
  as what the tool printed.
