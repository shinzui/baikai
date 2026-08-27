---
title: There is one URL host parser and every consumer uses it
status: accepted
date: 2026-08-27
---

# There is one URL host parser and every consumer uses it

## Context

baikai decides which API key to send by looking at the host name inside a
model's `baseUrl`, and it decides which per-host compatibility record to
apply the same way. Both are routing decisions about a credential: get
the host wrong and a caller's OpenAI key goes to somebody else's server,
with an `Authorization` header attached.

Until this record two functions answered "what host does this URL name",
and they did not agree.

`urlHost` in `baikai/src/Baikai/Compat.hs` took the text after the
**last** `@` anywhere in the URL. So
`https://proxy.example.com/v1?u=@api.openai.com` named the host
`api.openai.com`: `defaultApiKeyEnvForBaseUrl` resolved `OPENAI_API_KEY`,
`autoDetectOpenAICompletions` returned the vendor's own compatibility
record, and the bearer token went to `proxy.example.com`. Anyone who
could set `baseUrl` — a `Model` decoded from JSON, a proxy override of
the kind the guide suggests — could choose which provider's key baikai
would hand them. The same defect broke the benign direction too:
`https://api.openai.com/v1/@x` named the host `x` and resolved no key at
all. The 2026-08 review recorded this as its one credential-misdirection
finding (`docs/reviews/correctness-and-api-review-follow-up.md`, A.1).

`dropUserInfo` in `baikai/src/Baikai/Evidence/Build.hs` was the second
parser, written for the evidence record's `endpoint` field. It was nearly
right — it took the last `@` inside the authority — but it bounded the
authority at the first `/` only, so a URL with a query and no path
(`https://proxy.example.com?u=@api.openai.com`) still named the wrong
host. Two parsers, two answers, and neither was the one the code needed.

## Decision

There is one URL parser in baikai, `Baikai.Url` in
`baikai/src/Baikai/Url.hs`, and every consumer calls it. It is not a
validating URI parser and does not try to be: it knows enough to name a
host, key a cache, render an endpoint, and say why a base URL is
unusable, and it is total over `Text` with no dependency beyond `text`
and `base`.

The rule it implements: strip whitespace; take a scheme only when the
text before the first `://` is syntactically a scheme, and lower-case it;
take the **authority** as everything up to the first `/`, `?` **or** `#`;
drop userinfo at the last `@` *inside that authority only*; split off a
numeric port, keeping a bracketed IPv6 literal whole; lower-case the
host, because DNS names are case-insensitive; take the path from the
first `/` up to the first `?` or `#`, verbatim. An empty host is no
result at all.

Bounding the authority at all three of `/`, `?` and `#` is the whole
point. Everything after that boundary is path, query or fragment, and
none of it can name a host.

The consumers, all of which now call it: `autoDetectOpenAICompletions`
and `autoDetectAnthropicMessages` in `Baikai.Compat`, which re-exports
`urlHost` and `hostMatchesSuffix` rather than defining them;
`defaultApiKeyEnvForBaseUrl` in `Baikai.Auth`; `sanitizeEndpoint` in
`Baikai.Evidence.Build`, which is now `renderEndpoint <$> parseUrl` and
where `dropUserInfo` used to be; and `canonicalBaseUrl` in the new
`Baikai.Http`, which is where the `ClientEnv` cache lives now that there
is one of it rather than one per provider package.

Any future code that reads a host out of a `baseUrl` — a new provider, a
new per-host table, a new cache — calls `Baikai.Url`. Splitting the text
by hand is how this defect happened twice.

`Baikai.Url.UrlParts` is credential-free by construction. It records
*whether* userinfo, a query string or a fragment were present and never
their text, so a value of that type cannot carry a secret into a log
line, and `baseUrlProblem`'s refusal messages — which name the offending
URL — render through `renderEndpoint` rather than echoing the caller's
text.

## Consequences

The evidence record's `endpoint` now has a lower-cased scheme and host,
because that is what this parser says a host is. The path keeps its case
and its trailing slash. Every expectation in `baikai/test/EvidenceSpec.hs`
already used lower-case hosts, so nothing moved.

`Baikai.Compat` no longer defines `urlHost`; it re-exports it. The
umbrella `Baikai` module and every caller compile unchanged, and the name
stays where a reader looking at auto-detection expects to find it.

A URL the parser flags is refused rather than sent: `baseUrlProblem`
names the shapes baikai will not send to — no scheme, a scheme other than
`http`/`https`, userinfo, a query string, a fragment, or a path that is
already a full endpoint — and each refusal says what to do instead. That
is deliberately stricter than what `servant-client`'s `parseBaseUrl`
does, which silently prepends `http://` to a scheme-less URL (sending a
bearer token in plaintext) and rejects userinfo and query strings with an
exception that says nothing useful.

The one behavioural risk is over-refusal: a base URL shape somebody
relies on that this parser calls a problem. The fix for that is to narrow
`baseUrlProblem` and add the URL to `baikai/test/UrlSpec.hs`, never to
bypass the check at a call site — a call site that skips the check is a
call site that has its own idea of what host a URL names, which is the
thing this record exists to prevent.
