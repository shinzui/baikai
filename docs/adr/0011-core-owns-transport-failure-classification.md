---
title: Core owns transport failure classification, keyed on the phase the failure happened in
status: accepted
date: 2026-08-27
---

# Core owns transport failure classification, keyed on the phase the failure happened in

## Context

baikai promises that a failed call arrives as a typed `BaikaiError` whose
`category` and `isRetryable` let an application decide retry policy
without reading error text.
[0005](0005-what-baikai-deliberately-does-not-do.md) fixes the boundary:
baikai classifies retryability and never retries. That promise is only as
good as the classification.

Until this record, each HTTP provider package carried its own copy of the
table that turns an exception into a category. The two copies were
byte-for-byte the same and byte-for-byte wrong in the same way: each
matched `HttpException`, mapped six connect-time constructors to
`TransientError`, and sent everything else — including
`InvalidChunkHeaders`, `ResponseBodyTooShort` and `InternalException` —
to `OtherError`, which is not retryable.

The mechanism behind that is a detail of `http-client` worth recording,
because it is not obvious and it will outlive this change.
`Network/HTTP/Client/Core.hs` wraps the **connection phase** with the
manager's exception wrapper, which `http-client-tls` installs to turn a
socket or TLS failure into `HttpExceptionRequest _ (InternalException _)`.
It wraps the **body reader** with only its own thin `wrapExc`, which
converts `http-client`'s private wrapper type into `HttpExceptionRequest`
and nothing else. So an `IOException` raised inside `brRead` when the peer
resets the connection, or a `TLSException` when the session is torn down
after the handshake, reaches the caller **raw** — matching neither
provider's `HttpException` branch, falling through to the `otherwise` arm,
and arriving as `OtherError` with `isRetryable = False`.

The result a caller saw was that the *same* TCP reset was retryable or
not depending on which byte of the response it landed on. A reset during
connect was `ConnectionFailure`, transient. A reset four frames into the
generation was `OtherError`, final. Unattended work — the case this
library exists to be trusted for — gave up on failures that a single
retry would have cleared.

Plan 39 decided on 2026-07-01 that core should not grow an `http-client`
dependency "for two consumers". That reasoning rested on a false premise:
core already links `http-client`, `http-client-tls` and `servant-client`
through the `openai` SDK, and as of the URL work it depends on the first
two directly. It also could not have foreseen that a complete table needs
`tls`'s own exception type, whose constructor names are the only place
the phase of a TLS failure is recorded.

## Decision

Transport-failure classification is owned by core, in
`baikai/src/Baikai/Provider/Transport/Classify.hs`
(`Baikai.Provider.Transport.Classify`). It exports
`classifyTransportException :: SomeException -> Maybe BaikaiError` and the
per-type functions it composes. Every HTTP provider delegates to it and
keeps its own fallback for the `Nothing` case; the provider
`.Internal.ErrorClass` modules shrink to the vendor-specific JSON
classifiers, which are genuinely per-provider.

The rule is **where the failure happened, not what type it is**:

- Anything that breaks or ends the connection after the request went out
  is `TransientError`. That covers `ConnectionFailure`,
  `ConnectionTimeout`, `ResponseTimeout`, `ConnectionClosed`,
  `NoResponseDataReceived`, `IncompleteHeaders`, `InvalidChunkHeaders`,
  `ResponseBodyTooShort`, `HttpZlibException`, and whatever
  `InternalException` wraps; a socket `IOException` whose error type or
  errno names a vanished, aborted, reset or timed-out connection; and the
  TLS constructors that describe a session which existed and broke
  (`Terminated`, `PostHandshake`, `Uncontextualized`).
- Anything that says the caller's request or the process's configuration
  is wrong is not retryable. `InvalidUrlException`,
  `InvalidRequestHeader`, `InvalidDestinationHost` and
  `WrongRequestBodyStreamSize` are `InvalidRequest`; a server that does
  not speak HTTP, a proxy that cannot be reached, a TLS handshake that
  fails, and a redirect loop are `OtherError`.
- A programming error is neither, and yields `Nothing` so the caller's
  fallback keeps it as `OtherError`. A `userError` from a buggy callback
  must never be reported as a network blip a retry loop will chase.

Two consequences of that rule are deliberate and worth naming, because
each looks like an inconsistency until the phase is considered. A failed
TLS **handshake** is not retryable, while a socket reset during connect
is — because against a well-known API host a handshake failure is a
trust-store or protocol mismatch a retry reproduces, and a reset during
connect arrives as `ConnectionFailure` instead. And the `IOException`
rule consults the errno as well as the error type, because `base` maps
`ECONNABORTED` to the `IOErrorType` constructor named `OtherError`: a
type-only rule would call an aborted connection a programming error.

Core takes direct `build-depends` on `http-client`, `http-types` and
`tls`. This **supersedes** plan 39's rationale that core stays free of
`http-client`.

The module is a plain exposed module, not `.Internal`. A third-party
`Custom` provider written over `http-client` — the path
`docs/user/models-and-providers.md` teaches — should get the same
classification as baikai's own two without reimplementing this table.
`Baikai.Error` stays free of network types and is the module the umbrella
re-exports; `Classify` is not re-exported from `Baikai`.

## Consequences

There is one implementation and one test suite
(`baikai/test/TransportClassifySpec.hs`) rather than two copies that
drifted identically wrong. A constructor added by a future `http-client`
is handled in one place, and the provider suites pin the *delegation*
rather than re-testing the table.

Core's dependency list grows by `http-types` and `tls`. Neither adds a
package to any consumer's build plan; both were already in core's install
plan through the `openai` SDK.

The classifier is pure, which costs one thing: it cannot fall back to the
local clock when converting an HTTP-date `Retry-After` on a
`StatusCodeException` that carries no `Date` header. It converts the date
form only against a parseable `Date` and falls back to the integer form
otherwise. The transports, which are in `IO`, use `getCurrentTime`
instead. That arm is unreachable from baikai's own transports anyway —
neither installs `throwErrorStatusCodes` — and exists for third-party
providers.

Provider packages may still classify what only they can understand: an
Anthropic `error` event's `type`, an OpenAI-compatible in-band error
frame's `code`. Those are vendor vocabulary, not transport failures, and
stay where they are.

This record does not give baikai a retry loop. It makes the
retryability answer correct;
[0005](0005-what-baikai-deliberately-does-not-do.md) still holds, and
nothing in baikai acts on `isRetryable`.
