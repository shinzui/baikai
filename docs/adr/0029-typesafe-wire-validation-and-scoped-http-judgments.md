---
title: TypeSafe owns wire checks and uses scoped HTTP with synthetic atomic streams
status: accepted
date: 2026-10-25
---

# TypeSafe owns wire checks and uses scoped HTTP with synthetic atomic streams

## Context

TypeSafe System One returns a complete set of closed-set answers in one HTTP
reply. Its OpenAPI 0.2.0 wire contract requires usage/model and score/confidence
fields absent from the historical DSPy baseline. The neutral protocol in
[0028](0028-judgments-are-a-provider-neutral-core-protocol.md) cannot enforce
wire-specific input parts, content unions or score legends.

Existing boundaries remain authoritative: [0002](0002-requested-translated-observed-are-never-collapsed.md)
separates facts, [0005](0005-what-baikai-deliberately-does-not-do.md) excludes
internal retries, and [0011](0011-core-owns-transport-failure-classification.md)
assigns failure classification to core.

## Decision

`baikai-typesafe` depends on the released
`mori://shinzui/typesafe-hs/packages/typesafe-hs` wire codecs, not its servant
binding or the community clients. The client preserves ordered request maps and
Scientific numbers and owns wire shape decoding; the adapter checks TypeSafe
content/input restrictions, numeric bounds before conversion, required nonempty
model/nonnegative usage and exact score legends. The neutral core validator then
checks names, kinds, distributions and values and builds one `DataContent`.
Numeric and boolean descriptions are refused by their original schema path.
Box and unknown answer tags fail by field. Assets remain empty and omitted.

The adapter makes one scoped http-client POST with redirects disabled, core URL
normalization and cached manager, shared credential/header rules, and a timeout
covering initialization through body reading. Async cancellation propagates and
closes the response. There is no retry loop, separate classification vocabulary,
SSE transport or native streaming flag. Public streams synthesize one atomic
`DataStart`/`DataEnd` pair after a validated reply. Complete dispatch folds that
same event path.

Local refusals occur before credential lookup and dispatch. Explicit generation
controls are refused through core; consumers clear generation defaults after
routing. HTTP errors use core classification; only a structured
`api_usage_error` message starting `Unknown model:` adds typed model detail.
422 validation errors retain the upstream path without asserting a local mapping.

Call evidence commits the actual encoded request envelope and preserves actual
response headers and independently valid observations even when reply validation
fails. Requested and observed models remain separate. Request IDs do not become
response IDs. Success commitments contain structured values, distributions,
confidence and method plus provider usage; local prices are excluded. Unknown
catalog prices remain unavailable estimates. State and question content stay out
of the configuration projection.

## Consequences

Offline loopback tests prove both public call modes and the strict reply/refusal
matrices without TypeSafe access. Live verification requires explicit selection
and a key, and is reported separately. Client publication precedes adapter
publication; Baikai packages and tags still require a separate release operation.
The consumer handoff preserves independently cached answer evidence while keeping
per-call observations tied to the actual invocation.
