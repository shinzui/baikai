---
id: 59
slug: unify-host-parsing-and-stop-credential-misdirection
title: "Unify host parsing and stop credential misdirection"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Unify host parsing and stop credential misdirection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

baikai decides which API key to send, and which per-host compatibility record to apply,
by looking at the host name inside `Model.baseUrl`. Today that host name is extracted by
`urlHost` in `baikai/src/Baikai/Compat.hs`, which takes everything after the *last* `@`
anywhere in the URL. A base URL such as `https://proxy.example.com/v1?u=@api.openai.com`
therefore resolves the host `api.openai.com`, so both API providers read
`OPENAI_API_KEY` from the environment and send it as a bearer token to
`proxy.example.com`. The evidence module already has a second, nearly correct parser
(`dropUserInfo` in `baikai/src/Baikai/Evidence/Build.hs`), so two parts of the library
disagree about what host a URL names. The 2026-08 review
(`docs/reviews/correctness-and-api-review-follow-up.md`, finding A.1) rates this the
library's one credential-misdirection defect, and lists five smaller ways a credential
or a request can go somewhere the caller did not intend (E.2, E.6, E.3, A.5, A.6 — all
spelled out under Context and Orientation).

After this plan there is exactly one URL parser in baikai, `Baikai.Url`, and every
consumer uses it: compat auto-detection, the per-host API-key table, evidence endpoint
sanitisation, the base-URL check both providers run before sending anything, and the
`ClientEnv` cache. A base URL with an `@` after the host resolves no key and no known
compat record; `https://user:pw@api.openai.com/` still resolves OpenAI at the parser level
and is then refused with a descriptive error rather than silently sent. Printing an
`Options`, a `Model`, or a `Response` never reveals an `Authorization`, `x-api-key`,
`api-key` or `cookie` header value. An empty key variable is reported as an `AuthError`
naming the variable instead of producing `Authorization: Bearer ` and a provider 401. An
`EmbeddingModel` pointed at DeepSeek resolves `DEEPSEEK_API_KEY` through the same table
as chat calls and reuses the same cached connection manager. A provider POST never
follows a redirect. And `https://api.deepseek.com/v1` — the base URL every OpenAI SDK
teaches — composes to one `/v1/chat/completions`, because the rule "the base URL is the
API root without the version segment" is stated in the guide and enforced in code.

You can see all of it working offline: the new `baikai/test/UrlSpec.hs`, the negative
cases added to `baikai/test/Main.hs`, the redaction and empty-variable cases, the
embeddings key-resolution cases, and the redirect and path-composition cases in both
provider `TransportSpec.hs`/`SseSpec.hs` suites all run under the release skill's keyless
gate with no network.

This is EP-2 (wave 1) of the master plan at
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`. Its
Integration Points bind this document: EP-2 *defines* the single URL host parser and
every other plan consumes it; EP-3 (`docs/plans/60-…`) edits the thinking-style region in
the middle of `baikai/src/Baikai/Compat.hs` and must not reintroduce a second parser when
it reads `baseUrl`; EP-10 owns export-list hygiene and version bumps, so this plan adds
names with Haddock and records the one breaking change it makes without bumping a
version; EP-11 owns the documentation sweep, so this plan updates only the guide sections
and capability records that describe the behaviour it changes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1 (2026-08-27): `baikai/src/Baikai/Url.hs` created with `parseUrl`, `urlHost`, `hostMatchesSuffix`, `renderEndpoint`, `stripApiVersion`, `baseUrlProblem`; registered in `baikai/baikai.cabal`.
- [x] M1 (2026-08-27): `Baikai.Compat` re-exports `urlHost` and `hostMatchesSuffix` from `Baikai.Url`; its own definitions deleted; `Baikai.Auth` and `Baikai.Evidence.Build` (`sanitizeEndpoint` is now `renderEndpoint <$> parseUrl`, `dropUserInfo` deleted) rewired.
- [x] M1 (2026-08-27): `baikai/src/Baikai/Http.hs` created: `canonicalBaseUrl`, `getClientEnvCached`, `cachedClientEnvCount`; both provider `Transport.hs` delegate to it; core `build-depends` gains `servant-client`, `http-client`, `http-client-tls`.
- [x] M1 (2026-08-27): `baikai/test/UrlSpec.hs` written and registered; the negative cases added to `baikai/test/Main.hs` including a QuickCheck property over four `@`-bearing suffixes; the cache-key normalisation assertions folded into the existing cache case in both `TransportSpec.hs`.
- [x] M1 (2026-08-27): `docs/adr/0008-one-url-host-parser-and-every-consumer-uses-it.md` created and listed in `docs/adr/README.md`; `CHANGELOG.md` `[Unreleased]` entries written.
- [x] M2 (2026-08-27): `isCredentialHeader`, `redactHeaderValues`, `redactedMarker` added to `Baikai.Auth`; hand-written `Show`/`ToJSON` on `Options` and `Model`; field-coverage guard test and four redaction cases in `baikai/test/Main.hs`.
- [x] M2 (2026-08-27): `resolveApiKey` treats an empty (whitespace-only) variable as unset; five `HelpersSpec` cases added; Haddock and `docs/user/getting-started.md` updated.
- [x] M3 (2026-08-27): `EmbeddingModel` derives `Eq`/`Generic`; `apiKey :: Maybe ApiKeySource`; `resolveEmbeddingKey` and `embeddingClientEnv` added; `embed` routes through `Baikai.Http`; six `EmbeddingSpec` cases added; `docs/capabilities/text-embeddings.md` and `docs/capabilities/log.md` updated. The `baseUrlProblem` check in `embed` belongs to M4, which owns it for both providers as well.
- [ ] M4: `buildRequest` extracted in both `Sse.hs` with `redirectCount = 0`; `canonicalBaseUrl` strips a trailing `/v1`; `baseUrlProblem` checked in both `prepareCall`s and in `embed`.
- [ ] M4: fake-manager redirect test and path-composition tests in both provider suites; base-URL refusal tests; `docs/user/models-and-providers.md` "Base URLs" section; Limits bullets in both backend capability records; `docs/capabilities/log.md` entry.
- [ ] Final: keyless `cabal test all` gate green; `nix fmt` clean; master plan Progress lines for EP-2 ticked; Outcomes & Retrospective written; ADR distillation pass done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Four discoveries from plan research are recorded here so they are not lost:

- The "correct" parser the review points to is itself incomplete. `dropUserInfo` in
  `baikai/src/Baikai/Evidence/Build.hs:227-235` bounds the authority at the first `/`
  only, so `https://proxy.example.com?u=@api.openai.com` (a query with no path) would
  still yield `api.openai.com`. The rule this plan adopts bounds the authority at the
  first `/`, `?` *or* `#`, which is what RFC 3986 means by "authority".
- `servant-client-core`'s `parseBaseUrl` (source at
  `/Users/shinzui/Keikaku/hub/haskell/servant-project/servant/servant-client-core/src/Servant/Client/Core/BaseUrl.hs:123-142`)
  silently prepends `http://` to a base URL with no scheme, so a `Model.baseUrl` of
  `api.openai.com` today sends the key over plaintext HTTP. The base-URL check in M4
  refuses a scheme-less URL rather than guessing.
- `parseBaseUrl` also rejects any URL with userinfo (`user:pw@host`) or a query string,
  throwing `InvalidBaseUrlException`, which `prepareCall`'s `exceptionToError` classifies
  as a generic `OtherError`. Every "unsupported base URL" case must therefore be caught
  by baikai's own check first, so the caller gets an `InvalidRequest` that says what is
  wrong.
- `http-client`'s `defaultRequest` (source at
  `/Users/shinzui/Keikaku/hub/haskell/http-client-project/http-client/http-client/Network/HTTP/Client/Request.hs:295`)
  sets `redirectCount = 10`, and `Request.shouldStripHeaderOnRedirect` defaults to
  "keep all headers intact" (`Types.hs:617-619`). With `redirectCount = 0` the 3xx
  response is returned to the caller untouched (`Client.hs:284`), which is exactly what
  the SSE reader needs: it already classifies any non-2xx into one in-band error.

Recorded during implementation.

- __The credential misdirection, reproduced.__ `UrlSpec` was written and run before
  `Baikai.Compat` was rewired, so its assertions still went through the old parser:

  ```text
    the authority ends at the first /, ? or #
      an @ in the query does not rename the host:  FAIL
        expected: Nothing
         but got: Just "OPENAI_API_KEY"
      an @ in the path does not rename the host:   FAIL
        expected: Just "OPENAI_API_KEY"
         but got: Nothing
    rendering an endpoint
      userinfo, query and fragment are gone …:     FAIL
        expected: Just "https://host.example:8443/a/b"
         but got: Just "https://Host.example:8443/a/b"
  ```

  The first is the defect itself: a base URL of
  `https://proxy.example.com/v1?u=@api.openai.com` resolved `OPENAI_API_KEY`, which
  baikai would then have sent to `proxy.example.com`. The second is the same defect in
  the benign direction. The third is the evidence endpoint's separate parser, which
  never lower-cased the host. (2026-08-27, M1)
- __Two cache cases cannot both count.__ Moving the `ClientEnv` cache into core made it
  one process-global map shared by both provider suites' cases. A second case that read
  the count and expected it to move by exactly one raced the first under tasty's
  parallel execution and failed with `expected: 2, but got: 3`. The normalisation
  assertions are folded into the existing cache case in each suite rather than added
  beside it, so only one case per process reads that counter. (2026-08-27, M1)
- The plan's M1 sketch had `canonicalBaseUrl` call `baseUrlProblem`, which would have
  landed M4's refusals — a scheme-less base URL, a query string — three milestones
  early and without the tests that pin them. M1's `canonicalBaseUrl` refuses only what
  it genuinely cannot build a `BaseUrl` from: no host, no scheme, or a scheme other
  than `http`/`https`. Likewise `stripApiVersion` is defined in M1 and applied in M4,
  as the plan's own note says. (2026-08-27, M1)
- The hand-written `Show` instances match the derived output exactly, checked by
  printing them rather than by reasoning about GHC's rules:

  ```text
  Options {maxTokens = Nothing, temperature = Nothing, apiKey = Nothing, timeoutMs = Nothing, headers = fromList [], metadata = fromList [], toolChoice = Nothing, …}
  Model {modelId = "", name = "", api = Custom "", provider = "", baseUrl = "", reasoning = False, input = [InputText], cost = ModelCost {…}, contextWindow = 0, maxOutputTokens = 0, headers = fromList [], compat = CompatNone}
  ```

  With credential headers present, the same rendering carries the marker and the
  ordinary header survives, while the field itself is untouched:

  ```text
  headers = fromList [("Authorization","<redacted>"),("Ocp-Apim-Subscription-Key","<redacted>"),("X-Title","my app")]
  Just "Bearer sk-live-secret"
  ```

  The `ToJSON` side is corroborated by the golden trace fixture and the evidence
  digest cases, which encode these records and compare bytes; all of them pass
  unchanged. (2026-08-27, M2)
- The field-coverage guard needs an explicit kind on its class
  (`class GFieldNames (f :: Type -> Type)`). Without it GHC infers a
  kind-polymorphic parameter and `selName (undefined :: S1 m f ())` fails with
  "Expected kind 'k', but '()' has kind '*'". (2026-08-27, M2)


## Decision Log

Record every decision made while working on the plan.

- Decision: the one URL parser lives in a new core module, `baikai/src/Baikai/Url.hs`
  (`Baikai.Url`), not in `Baikai.Compat`. `Baikai.Compat` keeps exporting `urlHost` and
  `hostMatchesSuffix` as re-exports so the umbrella `Baikai` module and every existing
  test compile unchanged.
  Rationale: `Baikai.Compat` is about per-host feature flags, and EP-3 edits its middle
  region concurrently; a parser in its own module avoids merge conflicts and gives the
  ADR a single place to point at. Re-exporting keeps this plan free of surface removals,
  which EP-10 owns.
  Date: 2026-08-27
- Decision: the parser rule. Strip leading and trailing whitespace. If the text before
  the first `://` is a syntactically valid scheme (a letter followed by letters, digits,
  `+`, `-` or `.`), that is the scheme, lower-cased, and it is removed; otherwise there
  is no scheme. The authority is everything up to the first `/`, `?` or `#`. Userinfo is
  everything up to the last `@` *inside the authority only*, and is dropped. If what
  remains starts with `[`, the host is the text up to and including the matching `]` (an
  IPv6 literal, brackets kept) and a following `:digits` is the port; otherwise the host
  is the text before the first `:` and the digits after it are the port (a non-numeric
  port is ignored, the host is still the text before the colon). The host is lower-cased.
  The path is everything from the first `/` up to the first `?` or `#`. An empty host
  means no result (`Nothing`).
  Rationale: this is the rule `dropUserInfo` documented, extended to bound the authority
  at `?` and `#` (see Surprises & Discoveries) and to keep IPv6 literals whole. It is a
  total function over `Text` with no dependency, which is what the compat and key tables
  need; it is not a validating URI parser and does not try to be.
  Date: 2026-08-27
- Decision: header redaction is done by hand-written `Show` and `ToJSON` instances on
  `Options` and `Model` that render every field exactly as the derived instances would,
  except that the `headers` map has credential-carrying values replaced by the marker
  `<redacted>`. The field type stays `Map Text Text`. A header name is credential-carrying
  when, lower-cased, it contains `authorization`, `api-key`, `apikey`, `token`, `secret`,
  `cookie` or `password`, or ends in `-key`. `Response` derives `Show` and embeds a
  `Model`, so `print resp` is covered without touching `Response`. `Eq` is unaffected —
  two records with different credential headers remain unequal. `Model`'s derived
  `FromJSON` is unchanged, so a `Model` encoded and decoded through JSON comes back with
  the marker in place of a credential header; that round trip is deliberately lossy.
  Rationale: a redacting newtype for the field would change a public field type on two
  evolvable records, a breaking change EP-10 has not planned for; hand-written instances
  over the same fields keep the surface stable. The name rule errs toward over-redaction
  (a header named `x-idempotency-key` will print as `<redacted>`), which is the safe
  direction because redaction only affects what is *printed*, never what is sent. The
  marker matches `renderApiKeySourceForDebug`'s existing `ApiKeyLiteral <redacted>`.
  Date: 2026-08-27
- Decision: an environment variable whose value is empty after stripping whitespace is
  treated exactly as an unset variable. `ApiKeyEnv name` then fails with an `AuthError`
  whose message names the variable and says "not set or empty"; `ApiKeyEnvChain` skips it
  and continues, and a chain in which every variable is unset or empty fails with an
  `AuthError` naming every variable. A non-empty value is passed through unchanged (no
  trimming).
  Rationale: an empty key can never authenticate, so reporting it early as the
  descriptive error is strictly better than a provider 401; trimming a real value would
  be a second, unrelated behaviour change and is out of scope.
  Date: 2026-08-27
- Decision: the `ClientEnv` cache moves from the two provider `Transport.hs` modules into
  core, as `baikai/src/Baikai/Http.hs` (`Baikai.Http`), keyed on the canonical rendering
  of the parsed base URL (`servant-client-core`'s `showBaseUrl` over a `BaseUrl` whose host
  is the lower-cased host from `Baikai.Url`, with the trailing slash removed and, from M4,
  a trailing `/v1` segment removed). The cache stays unbounded. Both provider
  `Transport.getClientEnvCached` and `cachedClientEnvCount` become re-exports of the core
  functions so the existing `TransportSpec` cases keep passing. This supersedes plan 41's
  decision ("the process-global Manager cache is duplicated … rather than added to
  core", `docs/plans/41-implement-compat-quirks-and-transport-options.md`).
  Rationale: plan 41's premise was that core `baikai` does not link `http-client`; it
  already does, transitively, through the `openai` SDK that `Baikai.Embedding` uses, so
  naming the three packages in core's `build-depends` adds nothing to the install plan.
  One cache is the only way M3's "embeddings share the cache" can be literally true, and
  one canonicalisation rule is the only way the key cannot drift between three copies.
  Unbounded is kept because the set of distinct base URLs a process talks to is
  configuration-sized, not request-sized; normalisation removes the one unbounded source
  the review named (textual variants of one host); and connection lifetime is already
  the `Manager`'s idle timeout. A per-tenant base-URL fleet is not a supported use of
  `Model.baseUrl`, and the capability record says so.
  Date: 2026-08-27
- Decision: embeddings. `EmbeddingModel` derives `Eq`, `Show` and `Generic`; `apiKey`
  becomes `Maybe ApiKeySource`, where `Nothing` means "the per-host table"
  (`defaultApiKeyEnvForBaseUrl` on the effective base URL, with the empty base URL
  substituted by `https://api.openai.com` as today); an unknown host with `Nothing` is an
  `AuthError` telling the caller to set `EmbeddingModel.apiKey`. `emptyEmbeddingModel`
  and `openAIEmbeddingModel` set `apiKey = Nothing`. `embed` obtains its `ClientEnv` from
  `Baikai.Http.getClientEnvCached` instead of the SDK's per-call `getClientEnv`. The
  `Maybe` is a breaking change, recorded in `CHANGELOG.md` under `[Unreleased]`; the
  version bump belongs to EP-10.
  Rationale: `Options.apiKey` is already `Maybe ApiKeySource` with exactly this meaning,
  so the two records now agree; the alternative of adding a "default for host"
  constructor to `ApiKeySource` would change the meaning of `Options.apiKey = Just …` and
  break exhaustive matches instead.
  Date: 2026-08-27
- Decision: both SSE request builders set `redirectCount = 0`. A 3xx therefore reaches
  `sseFromResponse` as a non-2xx and becomes the one in-band terminal error, carrying the
  status; nothing is retried and nothing is forwarded.
  Rationale: a chat-completions or messages POST has no legitimate redirect, and the
  http-client default forwards every header — including the bearer token — to whatever
  host `Location` names.
  Date: 2026-08-27
- Decision: the base-URL convention is "`Model.baseUrl` is the host root or the prefix
  the host mounts the API under, *without* the `/v1` version segment; baikai appends
  `/v1/chat/completions`, `/v1/messages` or `/v1/embeddings` itself". A base URL whose
  path ends in `/v1` is accepted and that one segment is removed before composing, so
  `https://api.deepseek.com/v1` composes to one `/v1`; this is documented in the guide
  and in the Haddock rather than warned about on stderr. A base URL with a query string,
  a fragment, userinfo, no scheme, a scheme other than `http`/`https`, or a path already
  ending in an endpoint path (`/chat/completions`, `/messages`, `/embeddings`) is refused
  before any key is resolved, with an `InvalidRequest` whose message names the problem.
  Query strings remain unsupported and the message says so.
  Rationale: dedupe-with-documentation was chosen over refusal because `/v1`-suffixed
  base URLs are what every OpenAI SDK teaches and what this repository's own tests use;
  refusing them would break a working configuration for no security gain, and a stderr
  warning would fire on every call for a legitimate URL. The other shapes are refused
  because each either cannot be sent (`parseBaseUrl` rejects them today as an unhelpful
  `OtherError`), would be sent in a way the caller does not expect (a scheme-less URL
  going over plaintext), or is an unambiguous mistake (a full endpoint URL as the base).
  Date: 2026-08-27
- Decision: the redirect fix is proven with a fake `http-client` `Manager` built from
  `managerRawConnection` and `makeConnection` (both in `Network.HTTP.Client.Internal`),
  which scripts a `302` response and records every connection attempt, rather than with
  a localhost socket server.
  Rationale: it needs no new test dependency, binds no port, and observes the thing that
  matters — which hosts a request was opened to — directly. The request builder is also
  exposed as a pure `buildRequest` so `redirectCount`, method and path are assertable
  without any connection at all.
  Date: 2026-08-27
- Decision: `sanitizeEndpoint` is reimplemented as `renderEndpoint <$> parseUrl`, so the
  recorded evidence endpoint now has a lower-cased scheme and host; the path is kept
  verbatim (case and trailing slash included), and the empty-string-to-`Nothing`
  behaviour is untouched (REV-2 D.8 belongs to EP-8).
  Rationale: one parser means one notion of "the host", and DNS names are
  case-insensitive; every existing `EvidenceSpec` expectation uses lower-case hosts and
  is unaffected.
  Date: 2026-08-27
- Decision: the ADR this plan creates is titled "There is one URL host parser and every
  consumer uses it", file slug `one-url-host-parser-and-every-consumer-uses-it`, at the
  next free number in `docs/adr/` at implementation time (`0006` if EP-1's ADR has not
  landed yet, `0007` if it has — check `ls docs/adr` immediately before creating the
  file).
  Rationale: the corpus is a plain-file convention
  (`docs/adr/0001-architecture-decision-record-convention.md`), numbered sequentially
  and never renumbered; EP-1 also creates a record and the two plans run in parallel.
  Date: 2026-08-27
  Resolved at implementation: EP-1 landed first and took both `0006` and `0007` (the
  second from its distillation pass), so this record is
  `docs/adr/0008-one-url-host-parser-and-every-consumer-uses-it.md`.
- Decision: M1's `canonicalBaseUrl` refuses only what it cannot build a `BaseUrl` from
  — no host, no scheme, or a scheme other than `http`/`https` — and does not call
  `baseUrlProblem`; `stripApiVersion` is defined in M1 and applied in M4.
  Rationale: the plan's M1 sketch would have landed M4's refusals and M4's path
  composition three milestones early, without the tests that pin them and without the
  before-and-after evidence M4's acceptance asks for. The parser is still the single
  source of the host in M1, which is what M1 is for.
  Date: 2026-08-27
- Decision: the cache-key normalisation assertions live inside each provider suite's
  existing `clientEnvCacheTest` rather than in a case of their own.
  Rationale: the cache is now one process-global map, and two parallel cases that each
  read its size and expect it to move by exactly one race each other — observed as
  `expected: 2, but got: 3` in `baikai-claude`. One counting case per process is the
  only shape that is not flaky.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

baikai is a multi-package Haskell workspace (`cabal.project` at the repository root,
GHC provided by the Nix dev shell). Only three packages matter here.

`baikai/` is the core library. `baikai/src/Baikai/Compat.hs` defines the two per-host
compatibility records and, at its bottom (lines 302-324 at `5411947`), the host helpers
`urlHost` and `hostMatchesSuffix` that `autoDetectOpenAICompletions` and
`autoDetectAnthropicMessages` use. `baikai/src/Baikai/Auth.hs` defines `ApiKeySource`
(`ApiKeyLiteral`, `ApiKeyEnv`, `ApiKeyEnvChain`), the per-host key table
`defaultApiKeyEnvForBaseUrl` (which imports `urlHost`), and `resolveApiKey`.
`baikai/src/Baikai/Evidence/Build.hs` defines `sanitizeEndpoint` and its helper
`dropUserInfo`, the second parser. `baikai/src/Baikai/Options.hs` and
`baikai/src/Baikai/Model.hs` each declare a `headers :: Map Text Text` field and derive
`Show` and `ToJSON` (`Model` also derives `FromJSON`); `baikai/src/Baikai/Response.hs`
derives `Show` and embeds a `Model`. `baikai/src/Baikai/Embedding.hs` is the embeddings
client; it calls the `openai` SDK's `getClientEnv` per call and hard-wires
`ApiKeyEnv "OPENAI_API_KEY"`. The umbrella module `baikai/src/Baikai.hs` re-exports
`Baikai.Auth` and `Baikai.Compat` (so `urlHost` is part of the public surface) but not
`Baikai.Embedding`. Core's `build-depends` include `openai ^>=2.5` and therefore already
link `servant-client`, `http-client` and `http-client-tls` transitively.

`baikai-openai/` and `baikai-claude/` are the two HTTP API providers; each depends on
`baikai`. Each has a `Transport.hs` (`baikai-openai/src/Baikai/Provider/OpenAI/Transport.hs`,
`baikai-claude/src/Baikai/Provider/Claude/Transport.hs`) holding a process-global
`MVar (Map Text ClientEnv)` cache keyed on the raw base-URL text, `resolveKey` (explicit
`Options.apiKey`, else the per-host table, else `AuthError`), and the header merge.
Each has an `Sse.hs` (`…/OpenAI/Sse.hs`, `…/Claude/Sse.hs`) that builds an
`http-client` `Request` from `HTTP.defaultRequest`, appending `/v1/chat/completions` or
`/v1/messages` to the base URL's path, and reads the response as a server-sent-event
stream. Each has an `Api.hs` whose `prepareCall` substitutes the provider's default host
for an empty `baseUrl` (`https://api.openai.com`, `https://api.anthropic.com`), calls
`Transport.resolveKey`, then `Transport.getClientEnvCached`; a `prepareCall` exception is
converted by `exceptionToError` and delivered as the in-band `[EventStart, EventError]`
pair by `immediateError`.

Terms used below, in plain language. A *URL authority* is the part between the scheme's
`://` and the first `/`, `?` or `#` — for `https://user:pw@api.openai.com:443/v1?x=1` it is
`user:pw@api.openai.com:443`. *Userinfo* is the optional `user:password@` prefix of the
authority. A *bearer token* is an API key sent as the header `Authorization: Bearer
<key>`; Anthropic uses `x-api-key: <key>` instead. A *`ClientEnv`* is
`servant-client`'s bundle of an `http-client` `Manager` (a connection pool that owns TLS
state) and a parsed `BaseUrl`; building one costs a TLS-manager setup, so baikai caches
them per base URL. A *redirect* is a 3xx HTTP response with a `Location` header;
`http-client` follows up to `redirectCount` of them automatically, re-sending the
original headers. *SSE* (server-sent events) is the line-oriented streaming format both
providers use. A *compat record* is the per-host feature-flag record `Baikai.Compat`
auto-detects from the host name. *Evidence* is the per-call record
`Baikai.Evidence.Build` assembles; its `endpoint` field is the sanitised base URL.

The findings this plan fixes, all from REV-2
(`docs/reviews/correctness-and-api-review-follow-up.md`; line references are as of
`c3753c5`, unchanged at `5411947`):

1. A.1 / E.1 (major, security). `urlHost` (`Compat.hs:311`) uses
   `last (Text.splitOn "@" noScheme)` over the whole remainder. Scenario: a `Model`
   decoded from JSON, or a proxy override as the guide suggests at
   `docs/user/models-and-providers.md:40`, carries
   `baseUrl = "https://proxy.example.com/v1?u=@api.openai.com"` and no `apiKey`;
   `defaultApiKeyEnvForBaseUrl` returns `Just "OPENAI_API_KEY"`,
   `autoDetectOpenAICompletions` returns the OpenAI record, and the bearer token goes to
   `proxy.example.com`. The benign form `https://api.openai.com/v1/@x` yields host `x`
   and a spurious `AuthError`. `baikai/test/Main.hs:191-223` covers `user@host` only.
2. E.2 (minor, security). `Options.headers` and `Model.headers` print verbatim through
   derived `Show`/`ToJSON` while `Options.hs:23-27` invites callers to put a gateway
   `Authorization` there and `docs/user/getting-started.md:132` says `print resp`.
3. E.6 (minor). `resolveApiKey` (`Auth.hs:88-102`) accepts `Just ""` as a key and
   short-circuits a chain on it.
4. E.3 (minor, security) and the Theme 10 residual. `Embedding.hs:55-72,104`: the
   default key is `OPENAI_API_KEY` whatever the host; a TLS manager is allocated per
   call; the record derives neither `Generic` nor `Eq`, so `#field .~` does not compile.
5. A.5 / E.4 (minor, security). `OpenAI/Sse.hs:128-138` and the Claude twin keep
   `redirectCount = 10`.
6. A.6 (minor). Both transports append the endpoint path with no dedupe
   (`OpenAI/Sse.hs:133`, `Claude/Sse.hs:136`); `parseBaseUrl` rejects query strings and
   userinfo as an unhelpful `OtherError`; the convention is stated nowhere;
   `baikai/test/Main.hs:214` and `baikai-openai/test/Main.hs:542,547` treat `/v1` URLs as
   legitimate.
7. Theme 10 residual. The `ClientEnv` cache is keyed on raw URL text (`https://h` and
   `https://h/` are two managers) and never evicted. Theme 4 residual: the `@` and IPv6
   edge cases of `urlHost` are untested.

Verified facts from dependency sources this plan relies on, beyond those under Surprises
& Discoveries (sources located with `mori registry show snoyberg/http-client --full`,
`… haskell-servant/servant --full`, `… MercuryTechnologies/openai --full`):
`Network.HTTP.Client.Internal` re-exports `makeConnection :: IO ByteString -> (ByteString
-> IO ()) -> IO () -> IO Connection` and `ManagerSettings.managerRawConnection :: IO
(Maybe HostAddress -> String -> Int -> IO Connection)`, which is how the redirect test
fakes a server; `servant-client-core`'s `BaseUrl` has fields `baseUrlScheme`,
`baseUrlHost`, `baseUrlPort`, `baseUrlPath`, and `showBaseUrl` renders
`scheme://host[:port]path` omitting a default port (`BaseUrl.hs:94-105`); the `openai`
SDK's `getClientEnv` (`openai/src/OpenAI/V1.hs:166-180`) is `parseBaseUrl` plus a fresh
`newTlsManagerWith` per call, and `makeMethods` accepts any `ClientEnv`, so a cached one
works.

ADR context. The local corpus `docs/adr/` is a plain-file convention
(`docs/adr/0001-architecture-decision-record-convention.md`: `NNNN-slug.md`, YAML
`title`/`status`/`date`, Context/Decision/Consequences, a row in `docs/adr/README.md`);
it is not a profiled OKF bundle, so no handle allocation or `okf validate` applies to it.
No existing record covers URL parsing, credentials or transports;
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` is adjacent only in that it
bounds baikai to classifying errors rather than retrying them, which is why a refused
redirect is delivered as one in-band error and nothing more. No cross-repository ADR
applies (the master plan's Mori search for "URL host" returned nothing).


## Plan of Work

The work is four milestones, fixed by the master plan. M1 lands the parser and the
cache and rewires every consumer; M2 and M3 are independent of each other and depend
only on M1; M4 depends on M1 (it extends `canonicalBaseUrl` and uses `baseUrlProblem`).
Each milestone ends in a green `cabal build all --enable-tests` and green offline suites
for `baikai`, `baikai-claude` and `baikai-openai`, and one commit.

### Milestone 1 — one URL host parser, used by compat detection, key resolution, evidence and the client cache

Scope: a new `baikai/src/Baikai/Url.hs`, a new `baikai/src/Baikai/Http.hs`, edits to
`Baikai.Compat`, `Baikai.Auth`, `Baikai.Evidence.Build`, both provider `Transport.hs`,
`baikai/baikai.cabal`, a new `baikai/test/UrlSpec.hs`, the negative cases in
`baikai/test/Main.hs`, one case in each `TransportSpec.hs`, the ADR, and the changelog.
At the end there is one function that answers "what host does this URL name", every
consumer calls it, and the cache treats `https://Api.OpenAI.com/` and
`https://api.openai.com` as one entry.

The parser. Create `baikai/src/Baikai/Url.hs` exporting the record's selectors (not its
constructor — `parseUrl` is the only producer) and the functions below. The record is
credential-free by construction: it records *whether* userinfo, a query or a fragment
were present, never their text.

```haskell
-- | The pieces of a URL that baikai needs: enough to name a host, key a
-- cache, and record an endpoint. Not a validating URI parser.
data UrlParts = UrlParts
  { -- | Lower-cased scheme without "://", when one was present.
    scheme :: !(Maybe Text),
    -- | Lower-cased host. An IPv6 literal keeps its brackets: "[::1]".
    host :: !Text,
    -- | Numeric port when one was given.
    port :: !(Maybe Int),
    -- | From the first "/" up to (not including) "?" or "#"; "" when absent.
    path :: !Text,
    hasUserInfo :: !Bool,
    hasQuery :: !Bool,
    hasFragment :: !Bool
  }
  deriving stock (Eq, Show, Generic)

parseUrl :: Text -> Maybe UrlParts          -- Nothing when no host can be found
urlHost :: Text -> Maybe Text               -- fmap host . parseUrl
hostMatchesSuffix :: Text -> Text -> Bool   -- moved verbatim from Baikai.Compat
renderEndpoint :: UrlParts -> Text          -- scheme://host[:port]path
stripApiVersion :: Text -> Text             -- path -> path without a trailing "/v1"
baseUrlProblem :: Text -> Maybe Text        -- Nothing when usable as Model.baseUrl
```

`parseUrl` implements the rule in the Decision Log, step by step: strip whitespace;
split off a scheme only when the text before the first `://` is letters, digits, `+`,
`-`, `.` starting with a letter (`Text.breakOn "://"`); take the authority with
`Text.break (\c -> c == '/' || c == '?' || c == '#')`; drop userinfo with
`Text.breakOnEnd "@"` applied to the authority alone, setting `hasUserInfo` when the
prefix was non-empty; split host and port (bracketed literal first, then
`Text.breakOn ":"`, port via `Text.decimal`-style all-digits check); lower-case the host;
take the path with `Text.break (\c -> c == '?' || c == '#')` on the remainder and set
`hasQuery`/`hasFragment` from what follows. Return `Nothing` when the host is empty.
`renderEndpoint` is `maybe "" (<> "://") scheme <> host <> maybe "" ((":" <>) . tshow)
port <> path`. `stripApiVersion` removes trailing slashes, then one trailing `/v1`
segment (segment-wise: `/v10` and `/v1beta` are untouched), and returns either `""` or
a path beginning with `/`; it is defined here in M1 and only *used* from M4.
`baseUrlProblem` returns the first applicable message from this list: no host found;
scheme missing ("start with https:// or http://"); scheme not `http`/`https`; userinfo
present ("credentials before the host are never sent — use Options.apiKey for the API
key or Options.headers for a gateway header"); query string present ("baikai composes
the request path itself and does not support per-host query parameters such as
?api-version=; remove it, or front the host with a gateway that adds it"); fragment
present; path ends with `/chat/completions`, `/messages` or `/embeddings` ("Model.baseUrl
is the API root; baikai appends the endpoint path itself"). Each message includes the
offending base URL with userinfo and query removed (render it with `renderEndpoint`),
never the raw text, so an error log cannot leak a query-carried key.

Register the module under `exposed-modules` in `baikai/baikai.cabal`, alphabetically
between `Baikai.Trace.Sink` and `Baikai.Usage`.

Rewire the consumers. In `baikai/src/Baikai/Compat.hs` delete the `urlHost` and
`hostMatchesSuffix` definitions (lines 302-324), add `import Baikai.Url (hostMatchesSuffix,
urlHost)`, keep both names in the export list (they are now re-exports), and update the
module Haddock's last paragraph to say auto-detection uses `Baikai.Url`. In
`baikai/src/Baikai/Auth.hs` change the import to `Baikai.Url`. In
`baikai/src/Baikai/Evidence/Build.hs` replace the bodies of `sanitizeEndpoint` and delete
`dropUserInfo`:

```haskell
sanitizeEndpoint :: Text -> Maybe Text
sanitizeEndpoint = fmap renderEndpoint . parseUrl
```

and rewrite its Haddock to say the query, fragment and userinfo are dropped wholesale
because `Baikai.Url` never records them, keeping the sentence about why an allow-list of
query parameters would be wrong. `parseUrl ""` is `Nothing`, so the documented
empty-means-`Nothing` behaviour is preserved.

The cache. Create `baikai/src/Baikai/Http.hs`:

```haskell
module Baikai.Http
  ( canonicalBaseUrl,
    getClientEnvCached,
    cachedClientEnvCount,
  )
where

-- | Parse a base URL into the servant 'BaseUrl' baikai will actually
-- send to, normalised so that every spelling of one target is one
-- value: host lower-cased via 'Baikai.Url.parseUrl', default port
-- implied, trailing slash removed. (Milestone 4 adds: trailing "/v1"
-- segment removed.) Left carries a human-readable reason.
canonicalBaseUrl :: Text -> Either Text Client.BaseUrl

-- | The process-global cache. The key is @showBaseUrl@ of
-- 'canonicalBaseUrl'. Throws 'Baikai.Error.invalidRequest' when the
-- URL cannot be parsed.
getClientEnvCached :: Text -> IO Client.ClientEnv

cachedClientEnvCount :: IO Int
```

`canonicalBaseUrl` builds the `BaseUrl` from `parseUrl`'s parts directly — `Https`/`Http`
from the scheme, the lower-cased host, the explicit port or the scheme default (443/80),
the path with trailing slashes removed — rather than calling `parseBaseUrl` on the raw
text, so the parser is the one source of the host. Move `newClientEnv` (the
`newTlsManagerWith` call with `responseTimeoutNone`) and the `NOINLINE`
`unsafePerformIO` `MVar` from either provider `Transport.hs` here, unchanged except for
the key. Add `servant-client ^>=0.20`, `http-client ^>=0.7` and `http-client-tls ^>=0.3`
to the core library's `build-depends` (they are already in the install plan through
`openai`), and register `Baikai.Http` in `exposed-modules`. In both provider
`Transport.hs` delete `newClientEnv`, `clientEnvCache` and the two cache functions'
bodies, and re-export the core ones:

```haskell
import Baikai.Http (cachedClientEnvCount, getClientEnvCached)
```

keeping both names in each module's export list so `TransportSpec` and `Api.hs` compile
unchanged. Remove the now-unused `http-client-tls`, `MVar` and `unsafePerformIO` imports
from both.

Tests. Create `baikai/test/UrlSpec.hs` (register it in `baikai/baikai.cabal` under the
test suite's `other-modules` and in the test list in `baikai/test/Main.hs`) with these
cases, each a `testCase` asserting with `@?=`:

- `urlHost "https://proxy.example.com/v1?u=@api.openai.com"` is `Just "proxy.example.com"`,
  and the same URL gives `Nothing` from `defaultApiKeyEnvForBaseUrl` and
  `defaultOpenAICompletionsCompat` from `autoDetectOpenAICompletions`.
- `urlHost "https://proxy.example.com?u=@api.openai.com"` (no path) is
  `Just "proxy.example.com"` — the case `dropUserInfo` got wrong.
- `urlHost "https://api.openai.com/v1/@x"` is `Just "api.openai.com"` and the key table
  returns `Just "OPENAI_API_KEY"`.
- `urlHost "https://user:pw@api.openai.com/"` is `Just "api.openai.com"`,
  `hasUserInfo` is `True`, and the key table returns `Just "OPENAI_API_KEY"`.
- `parseUrl "http://[::1]:8080/v1"` has `host = "[::1]"`, `port = Just 8080`,
  `path = "/v1"`; `parseUrl "https://[::1]"` has `port = Nothing`.
- `parseUrl "https://Api.OpenAI.com:443/V1/"` has `host = "api.openai.com"`,
  `port = Just 443`, `path = "/V1/"` (path case preserved).
- `parseUrl "api.openai.com"` has `scheme = Nothing`; `parseUrl ""` and
  `parseUrl "https://"` are `Nothing`.
- `renderEndpoint` of `https://user:pw@Host.example:8443/a/b?k=v#f` is
  `https://host.example:8443/a/b`, and `sanitizeEndpoint` of the same text agrees.
- `stripApiVersion "/v1"`, `"/v1/"`, `"/"`, `""` are all `""`; `"/api/v1"` is `"/api"`;
  `"/compatible-mode/v1/"` is `"/compatible-mode"`; `"/v10"` and `"/v1beta"` are
  unchanged; `"v1"` (no leading slash) is `""` and `"api"` is `"/api"`.
- `baseUrlProblem` is `Nothing` for `https://api.openai.com`, `https://api.deepseek.com/v1`
  and `https://openrouter.ai/api`; is `Just` for each refused shape, and the message for
  `https://h.example/v1?api-version=1` contains `query string` and does not contain
  `api-version=1`; the message for `https://u:secret@h.example` does not contain `secret`.
- A QuickCheck property beside the existing `unknownHostGen` one in `baikai/test/Main.hs`:
  for any generated host `h` and any suffix drawn from `["/v1?u=@api.openai.com",
  "/@api.anthropic.com", "?x=@api.deepseek.com", "#@openrouter.ai"]`,
  `urlHost ("https://" <> h <> suffix) == Just h`.

In `baikai/test/Main.hs`'s "host auto-detection is suffix-bounded" and "default API-key
env table matches known hosts" cases add the four negative assertions the review asked
for, so the pins live beside the positive ones. In both provider `TransportSpec.hs` add
"cache key is normalised": `getClientEnvCached "https://Cache-Norm.test/"` then
`getClientEnvCached "https://cache-norm.test"` raises `cachedClientEnvCount` by exactly
one in total, and `Client.baseUrl` of the returned env has `baseUrlHost =
"cache-norm.test"` and `baseUrlPath = ""`.

The ADR. Create `docs/adr/NNNN-one-url-host-parser-and-every-consumer-uses-it.md` at the
next free number (see the Decision Log), with `status: accepted`, `date:` the day of the
commit, and a body whose Context names A.1 and the two disagreeing parsers, whose
Decision states the rule from this plan's Decision Log and names every consumer
(`autoDetectOpenAICompletions`, `autoDetectAnthropicMessages`,
`defaultApiKeyEnvForBaseUrl`, `sanitizeEndpoint`, `canonicalBaseUrl`, `baseUrlProblem`)
and the obligation that any future code reading a host out of `Model.baseUrl` or
`EmbeddingModel.baseUrl` calls `Baikai.Url` rather than splitting text, and whose
Consequences note the lower-cased evidence endpoint and the refusal of shapes the
parser flags. Add its row to the table in `docs/adr/README.md`.

Changelog. Under `## [Unreleased]` in `CHANGELOG.md` add, in the repository's
`- \`package\`: …` style: `baikai` Added `Baikai.Url` and `Baikai.Http`; `baikai` Fixed
the host parse (name A.1 and the `@`-after-authority scenario); `baikai` Changed the
evidence `endpoint` to a lower-cased scheme and host; `baikai-openai` and `baikai-claude`
Changed the `ClientEnv` cache to the shared core one with a normalised key.

Acceptance: `cabal test baikai baikai-claude baikai-openai` green; the new negative
cases fail on the pre-plan `urlHost` (verify once by running `UrlSpec` before rewiring
`Compat.hs`, and keep the failing output in Surprises & Discoveries) and pass after;
`grep -rn 'splitOn "@"\|breakOnEnd "@"' --include='*.hs' baikai/src baikai-*/src`
finds only `baikai/src/Baikai/Url.hs`.

### Milestone 2 — header credentials redacted in `Show`/`ToJSON`; empty key env vars are `AuthError`

Scope: `baikai/src/Baikai/Auth.hs`, `baikai/src/Baikai/Options.hs`,
`baikai/src/Baikai/Model.hs`, tests in `baikai/test/Main.hs` and
`baikai/test/HelpersSpec.hs`, Haddock, `docs/user/getting-started.md`. At the end
`show`, `print` and `Aeson.encode` of an `Options`, `Model` or `Response` never contain a
credential-carrying header value, and an empty key variable produces the descriptive
error.

Redaction helpers. In `baikai/src/Baikai/Auth.hs` add and export:

```haskell
-- | The text a credential is replaced with wherever baikai prints one.
redactedMarker :: Text
redactedMarker = "<redacted>"

-- | Whether a header name, by convention, carries a credential.
-- Case-insensitive; errs toward True, because this only affects printing.
isCredentialHeader :: Text -> Bool

-- | Replace the value of every credential-carrying header.
redactHeaderValues :: Map Text Text -> Map Text Text
```

with the name rule from the Decision Log (`Text.isInfixOf` over the lower-cased,
whitespace-stripped name for `authorization`, `api-key`, `apikey`, `token`, `secret`,
`cookie`, `password`, or `"-key" `Text.isSuffixOf``). `Baikai.Auth` gains an import of
`Data.Map.Strict`.

Instances. In `baikai/src/Baikai/Options.hs` change the deriving clause to
`deriving stock (Eq, Generic)` and add hand-written instances. Mirror GHC's derived
record syntax exactly — `showParen (d >= 11)`, the constructor name, `{`, fields as
`name = value` joined by `, `, `}`, each value shown with `showsPrec 0` — and list every
field in declaration order, passing `redactHeaderValues (headers o)` for `headers`:

```haskell
instance Show Options where
  showsPrec d o =
    showParen (d >= 11) $
      showString "Options {"
        . field "maxTokens" (maxTokens o)
        . next "temperature" (temperature o)
        . next "apiKey" (apiKey o)
        . next "timeoutMs" (timeoutMs o)
        . next "headers" (redactHeaderValues (headers o))
        -- … one line per remaining field, in declaration order …
        . showChar '}'
    where
      field name v = showString name . showString " = " . showsPrec 0 v
      next name v = showString ", " . field name v

instance ToJSON Options where
  toJSON o = genericToJSON defaultOptions (redactOptions o)
  toEncoding o = genericToEncoding defaultOptions (redactOptions o)

redactOptions :: Options -> Options
redactOptions o = o {headers = redactHeaderValues (headers o)}
```

`genericToJSON` and `genericToEncoding` (from `Data.Aeson`) encode through the `Generic`
representation, not through the `ToJSON Options` instance, so there is no recursion and
the output for a non-credential map is byte-identical to the derived instance's. Do the
same in `baikai/src/Baikai/Model.hs` for `Model` (twelve fields; keep `FromJSON` in the
`deriving anyclass` clause). Add a Haddock paragraph to each type: what is redacted, that
the field itself is untouched and the header is still sent, and (on `Model`) that a JSON
round trip of a credential header yields the marker. Extend the `headers` paragraph in
`Options.hs:23-27` with one sentence saying the same.

Tests in `baikai/test/Main.hs`, beside "Options Show redacts literal API keys": "Options
Show and JSON redact credential headers" — build `emptyOptions & #headers .~
Map.fromList [("Authorization","Bearer sk-live-secret"), ("X-Title","my app"),
("Ocp-Apim-Subscription-Key","azure-secret")]`, assert neither secret appears in `show`
or `Aeson.encode`, that `my app` does, and that `redactedMarker` appears twice; "Model
and Response Show redact credential headers" — the same map on `emptyModel`, then
`emptyResponse & #model .~ thatModel`, assert on `show` of both; "redacted Model still
parses" — `Aeson.decode (Aeson.encode m)` is `Just` a `Model` whose `Authorization`
header is `redactedMarker` and whose `X-Title` is intact; "Options and Model Show list
every field" — the drift guard for the hand-written instances, using a small
`GHC.Generics` field-name enumerator written in the test module:

```haskell
class GFieldNames f where
  gFieldNames :: Proxy f -> [String]

instance (GFieldNames f) => GFieldNames (D1 m f) where
  gFieldNames _ = gFieldNames (Proxy @f)

instance (GFieldNames f) => GFieldNames (C1 m f) where
  gFieldNames _ = gFieldNames (Proxy @f)

instance (GFieldNames f, GFieldNames g) => GFieldNames (f :*: g) where
  gFieldNames _ = gFieldNames (Proxy @f) <> gFieldNames (Proxy @g)

instance (Selector m) => GFieldNames (S1 m f) where
  gFieldNames _ = [selName (undefined :: S1 m f ())]

fieldNames :: forall a. (GFieldNames (Rep a)) => [String]
fieldNames = gFieldNames (Proxy @(Rep a))
```

(`fieldNames` has no argument mentioning `a`, so the test module needs
`{-# LANGUAGE AllowAmbiguousTypes #-}`; `TypeApplications` and `ScopedTypeVariables`
are already on under GHC2024) and assert, for every name in `fieldNames @Options`, that
`name <> " = "` is an infix of `show emptyOptions`, and likewise for `Model`. This is
what makes a field added by a later plan fail loudly here instead of silently vanishing
from `show`.

Empty variables. In `baikai/src/Baikai/Auth.hs` change `resolveApiKey`:

```haskell
resolveApiKey (ApiKeyEnv name) =
  liftIO $
    lookupNonEmptyEnv name >>= \case
      Just v -> pure v
      Nothing -> throwIO (authError ("env var " <> Text.pack name <> " is not set or is empty"))
resolveApiKey (ApiKeyEnvChain names) = liftIO (go names)
  where
    go [] = throwIO (authError ("none of the env vars " <> renderedNames <> " are set (an empty value counts as unset)"))
    go (name : rest) = lookupNonEmptyEnv name >>= maybe (go rest) pure
    …

-- | 'lookupEnv' that treats a blank value as absent.
lookupNonEmptyEnv :: String -> IO (Maybe Text)
```

Update the `resolveApiKey` Haddock. Tests in `baikai/test/HelpersSpec.hs`, using the
existing `withUnsetEnv` helper: "ApiKeyEnv rejects an empty variable" — `setEnv` the
variable to `""`, expect `AuthError` whose message contains the name and `empty`;
"ApiKeyEnvChain skips an empty variable" — first `""`, second `"second-key"`, expect
`"second-key"`; "ApiKeyEnvChain reports all names when every variable is empty". In
`docs/user/getting-started.md` at lines 136-142 extend the paragraph: `Show` and JSON
instances redact literal keys *and* credential-carrying headers (`Authorization`,
`x-api-key`, `api-key`, `cookie` and similar), and a key variable set to the empty string
counts as unset.

Acceptance: `cabal test baikai` green; the four new redaction cases fail on the derived
instances (verify by running them before switching the deriving clause) and pass after;
`show emptyOptions` is byte-identical before and after the change (compare the strings
in a scratch `cabal repl baikai` session and paste both into Surprises & Discoveries).

### Milestone 3 — embeddings resolve keys per host and share the `ClientEnv` cache

Scope: `baikai/src/Baikai/Embedding.hs`, `baikai/test/EmbeddingSpec.hs`,
`baikai/test/SurfaceSpec.hs` (unchanged unless it fails to compile),
`docs/capabilities/text-embeddings.md`, changelog. At the end an `EmbeddingModel` with no
explicit key uses the same per-host table as chat calls, an unknown host refuses rather
than sending `OPENAI_API_KEY`, and two embedding calls to one host share one `ClientEnv`
with the chat providers.

Edit `EmbeddingModel`: `deriving stock (Eq, Show, Generic)`; change the `apiKey` field to
`!(Maybe ApiKeySource)` with the Haddock "how to resolve the API key; `Nothing` means the
conventional variable for the host, from `Baikai.Auth.defaultApiKeyEnvForBaseUrl`, and an
unknown host then refuses with `AuthError`"; set `apiKey = Nothing` in both
`emptyEmbeddingModel` and `openAIEmbeddingModel` and rewrite their Haddocks ("keyed on
`OPENAI_API_KEY` by default" becomes "keyed per host by default; `api.openai.com` maps
to `OPENAI_API_KEY`"). Add and export two functions, both pure of network:

```haskell
-- | The key 'embed' will send: the explicit source, else the host's
-- conventional variable, else an 'AuthError' naming the host.
resolveEmbeddingKey :: EmbeddingModel -> IO Text

-- | The cached 'ClientEnv' 'embed' will use, from "Baikai.Http". Exposed
-- so the sharing is observable without a network call.
embeddingClientEnv :: EmbeddingModel -> IO Client.ClientEnv
```

`resolveEmbeddingKey` mirrors the providers' `resolveKey` over `urlOf m` (which already
substitutes `https://api.openai.com` for the empty string); the unknown-host message is
`"no default API key env is known for <url>; set EmbeddingModel.apiKey explicitly"`.
`embed` becomes: check `baseUrlProblem (urlOf m)` and `throwIO (invalidRequest problem)`
on `Just` (this line is written here so M3 compiles standalone; M4 documents it); then
`key <- resolveEmbeddingKey m`, `env <- embeddingClientEnv m`, then exactly the existing
`makeMethods`/`createEmbeddings` loop. Delete the `OpenAI.getClientEnv` call and rewrite
the module Haddock's first paragraph (it currently names `getClientEnv`). Add
`servant-client` to the `baikai-test` suite's `build-depends` so the test can inspect
`Client.baseUrl`.

Tests in `baikai/test/EmbeddingSpec.hs`: "embedding keys resolve per host" — with
`OPENAI_API_KEY` set to `openai-secret` and `DEEPSEEK_API_KEY` unset (use the
`withEnv`/`withUnsetEnv` pattern from the provider `TransportSpec.hs` and
`HelpersSpec.hs`), `resolveEmbeddingKey (emptyEmbeddingModel & #baseUrl .~
"https://api.deepseek.com")` throws `AuthError` whose message names `DEEPSEEK_API_KEY`;
"unknown embedding hosts refuse the OpenAI key" — same env, `baseUrl =
"https://vectors.example"`, `AuthError` whose message contains `EmbeddingModel.apiKey`;
"the OpenAI default still resolves OPENAI_API_KEY" — `openAIEmbeddingModel "m"` resolves
`"openai-secret"`; "an explicit key wins" — `apiKey = Just (ApiKeyLiteral "lit")`
resolves `"lit"`; "embeddings share the cached ClientEnv" —
`Http.cachedClientEnvCount`, then `embeddingClientEnv` for `https://api.openai.com` and
for `https://api.openai.com/`, then the count again: exactly one more, and the returned
env's `Client.baseUrl` has `baseUrlPath = ""`; "the #field idiom compiles on
EmbeddingModel" — `(openAIEmbeddingModel "m" & #dimensions .~ Just 256) ^. #dimensions
@?= Just 256`. Keep the live case as it is (it still needs `BAIKAI_EMBEDDING_LIVE=1`).

Documentation. In `docs/capabilities/text-embeddings.md` rewrite the paragraph "It reuses
baikai's `Baikai.Auth` key resolution, so the same `OPENAI_API_KEY` fallback…" to say the
key is resolved per host through the same table as chat calls and an unknown host
refuses; replace the Limits bullet about evidence with one that also says the client
now shares the process-global `ClientEnv` cache with the chat providers; add to the
`evidence` list the new `EmbeddingSpec` cases. Add a dated entry to
`docs/capabilities/log.md` (the release skill requires one whenever a record changes).
Changelog: `baikai` Changed (breaking) `EmbeddingModel.apiKey :: Maybe ApiKeySource`,
with the migration line "`apiKey = source` becomes `apiKey = Just source`; `Nothing` is
the per-host default"; `baikai` Fixed the per-call TLS manager.

Acceptance: `cabal test baikai` green; the "embedding keys resolve per host" case fails
on the pre-plan module (it resolves `openai-secret`) and passes after.

### Milestone 4 — no redirects on provider POSTs; base-URL path composition rule stated and enforced

Scope: both `Sse.hs`, both `Api.hs` (`prepareCall` only), `baikai/src/Baikai/Http.hs`
(`canonicalBaseUrl`), tests in both `SseSpec.hs`/`TransportSpec.hs` and
`baikai/test/UrlSpec.hs`, `docs/user/models-and-providers.md`, the two backend capability
records, changelog. At the end a 3xx is delivered as the terminal error and never
followed, `https://api.deepseek.com/v1` composes to one `/v1`, and the unsupported base
URL shapes are refused with a message that says why.

Request builder. In `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` extract the
`request` expression from `openaiSseStreamValueWithHeaders` into an exported pure
function and set the redirect count:

```haskell
-- | The exact request the transport sends. Pure and exported so that
-- what goes on the wire is assertable without a connection.
buildRequest :: Client.BaseUrl -> RequestHeaders -> Aeson.Value -> HTTP.Request
buildRequest base requestHeaders requestBody =
  HTTP.defaultRequest
    { HTTP.secure = …,
      HTTP.host = S8.pack (Client.baseUrlHost base),
      HTTP.port = Client.baseUrlPort base,
      HTTP.method = "POST",
      HTTP.path = S8.pack (normalizePath (Client.baseUrlPath base) <> "/v1/chat/completions"),
      HTTP.requestHeaders = requestHeaders,
      HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode requestBody),
      -- A chat-completions POST has no legitimate redirect, and following
      -- one would re-send the Authorization header to whatever host the
      -- Location names. A 3xx is delivered as the in-band terminal error.
      HTTP.redirectCount = 0,
      -- No per-response bound here: Options.timeoutMs is enforced around
      -- the whole call by Transport.runWithTimeout.
      HTTP.responseTimeout = HTTP.responseTimeoutNone
    }
```

Do the same in `baikai-claude/src/Baikai/Provider/Claude/Sse.hs` with `/v1/messages`.
Both replace the stale "EP-8 wires Options.timeoutMs" comment with the one above. Path
composition itself stays a plain append: from M1, every `BaseUrl` reaching the builder
comes from `Baikai.Http.canonicalBaseUrl`, which this milestone extends to apply
`Baikai.Url.stripApiVersion` to the path. Extend `canonicalBaseUrl`'s Haddock with the
convention and add the same sentence to `getClientEnvCached`.

The check. In both providers' `prepareCall`, immediately after the default-host
substitution and before `Transport.resolveKey`, add:

```haskell
case Url.baseUrlProblem url of
  Just problem -> pure (Left (invalidRequest ("Model.baseUrl is not usable: " <> problem)))
  Nothing -> do
    key <- Transport.resolveKey url opts
    …
```

so a refused URL never looks up a key. The resulting stream is the existing in-band
`[EventStart, EventError]` pair with category `InvalidRequest`.

Tests. In both provider `SseSpec.hs`:

- "the request follows no redirects and composes one /v1" — for each of
  `https://api.deepseek.com/v1`, `https://api.deepseek.com`, `https://openrouter.ai/api`,
  `https://openrouter.ai/api/v1/`, `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`:
  `canonicalBaseUrl` succeeds and `buildRequest base [] (Aeson.object [])` has
  `HTTP.redirectCount = 0`, `HTTP.method = "POST"`, and `HTTP.path` equal to
  `/v1/chat/completions`, `/v1/chat/completions`, `/api/v1/chat/completions`,
  `/api/v1/chat/completions`, `/compatible-mode/v1/chat/completions` respectively (the
  Claude suite uses `/v1/messages` and Anthropic-shaped hosts).
- "a 3xx is delivered as the terminal error and never followed" — the fake-manager test
  from the Decision Log. Build a `Manager` with `HTTP.newManager HTTP.defaultManagerSettings
  { HTTP.managerRawConnection = pure (\_ host port -> record (host, port) >> fakeConnection) }`
  where `fakeConnection` is `HTTP.makeConnection` returning, on the first read, the bytes
  `"HTTP/1.1 302 Found\r\nLocation: http://evil.test/steal\r\nContent-Length: 0\r\n\r\n"`
  and `""` thereafter, ignoring writes; `env = Client.mkClientEnv manager base` for the
  `Right base` of `canonicalBaseUrl "http://proxy.test"`; run
  `openaiSseStreamValueWithHeaders env [("Authorization","Bearer sk-test")] (Aeson.object [])`
  collecting events; assert the recorded attempts are exactly `[("proxy.test", 80)]` and
  the events are exactly one `Left e` with `e ^. #httpStatus @?= Just 302`. Before the
  fix this test records a second attempt to `evil.test` — run it once against the
  pre-fix builder and paste the recorded list into Surprises & Discoveries.

In both provider `TransportSpec.hs` (or a new `PrepareSpec`, if `TransportSpec` grows
unwieldy — record the choice): "unsupported base URLs are refused before any key is
read" — with the provider's key variable *unset*, for each of
`https://h.test/v1?api-version=2024-01`, `https://u:pw@h.test`, `h.test`,
`https://h.test/v1/chat/completions` (Claude: `/v1/messages`), drain the provider's stream
(`openaiChatStream` / `claudeMessagesStream` over `emptyModel & #api .~ … & #baseUrl .~
url` and `emptyOptions`) and assert the events are `[EventStart, EventError]` whose
error has category `InvalidRequest` and a message containing, respectively,
`query string`, `credentials`, `https://`, `endpoint path`; and that none of the messages
contains `api-version=2024-01` or `pw`. The `AuthError` that a missing key would have
produced proves the check ran first. In `baikai/test/UrlSpec.hs` add the
`canonicalBaseUrl` cases: `https://api.deepseek.com/v1` and `https://api.deepseek.com`
render to the same `showBaseUrl` text; `https://Api.OpenAI.com:443/` renders
`https://api.openai.com`.

Documentation. Add a `## Base URLs` section to `docs/user/models-and-providers.md`
directly after "Hand-rolled models" (before "Compatibility policy"), in prose: what
`baseUrl` is (the API root: the host, or the prefix under which the host mounts the
API), what baikai appends, that a trailing `/v1` is accepted and not doubled, the
catalog's own values as examples (`https://api.openai.com`,
`https://openrouter.ai/api`), what is refused and why (query strings are unsupported —
"front the host with a gateway that adds `?api-version=`"), that credentials never go in
the URL, that a redirect is never followed, and that `print`ing a record redacts
credential headers. Update the two `print resp` examples' surrounding text at lines 295
and 306 only if they claim anything now false (they do not; leave them). In
`docs/capabilities/openai-chat-completions-backend.md` and
`docs/capabilities/anthropic-messages-backend.md` add a Limits bullet each: the base-URL
convention, the refused shapes, no redirects, and that the `ClientEnv` cache is
unbounded and keyed per normalised base URL (so a fleet of per-tenant base URLs is not a
supported use of `Model.baseUrl`); add the new `SseSpec`/`TransportSpec` cases to each
record's `evidence` list. Add a dated `docs/capabilities/log.md` entry. Changelog:
`baikai-openai` and `baikai-claude` Fixed (A.5, A.6) with the convention stated in one
sentence; `baikai` Added `Baikai.Url.baseUrlProblem` and the `/v1` rule in
`canonicalBaseUrl`.

Acceptance: `cabal test baikai baikai-claude baikai-openai` green; the redirect test
fails before and passes after; the composition test's `/v1/v1/chat/completions` failure
before the fix is recorded; the guide section exists and `okf validate docs/capabilities`
(Concrete Steps) passes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`.

Find the dependency sources when a signature needs checking (never search the
filesystem for them):

```bash
mori registry show snoyberg/http-client --full
mori registry show haskell-servant/servant --full
mori registry show MercuryTechnologies/openai --full
```

Expected: each prints a `path:` line under `/Users/shinzui/Keikaku/hub/haskell/`; the
files this plan cites are relative to those roots.

Before creating the ADR, find the next free number:

```bash
ls docs/adr
```

Expected today: `0001-…` through `0005-…` plus `README.md`, so the new file is `0006-…`;
if EP-1 has already added `0006-…`, use `0007-…`.

Build and test after every milestone:

```bash
cabal build all --enable-tests
cabal test baikai baikai-claude baikai-openai --test-show-details=direct
```

Expected: each suite ends with `All N tests passed` (`baikai` was 931 tests across all
eight suites at `c3753c5`; the counts here grow by roughly thirty). A suite that hangs
for more than a minute indicates the fake-manager test is blocking on a read — its
`makeConnection` reader must return `""` after the scripted response, not block.

Format before every commit, as the release skill does:

```bash
nix fmt
git status --short
```

Expected: `git status --short` shows only the files you edited (a formatter change
shows up as a further modification of the same files; fold it in).

Before the final commit, run the keyless gate exactly as
`agents/skills/release/SKILL.md` specifies, so no live smoke case can spend money or
mask a skipped suite (adjust the two filtered `PATH` entries to wherever `claude` and
`codex` are installed on this machine):

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

Expected: every suite passes, none reports zero tests, and `baikai-smoke` prints one
`[baikai-smoke] … skipping` line per live case.

Validate the capability bundle after M3 and M4 touch its records:

```bash
mori validate
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
```

Expected: no errors; the graph shows an edge for every `requires` entry. Do not add
`--strict` (the release skill explains why).

Commit once per milestone with a Conventional Commits message and the three trailers.
The four messages, in order:

```text
feat(url): one URL host parser for compat, keys, evidence and the client cache

Add Baikai.Url and make it the only place baikai reads a host out of a URL:
Compat re-exports it, Auth's key table and Evidence.Build's sanitizeEndpoint
call it, and the ClientEnv cache — now one cache in Baikai.Http shared by
both providers — keys on the canonical rendering of its result. The
authority ends at the first "/", "?" or "#" and userinfo is only ever the
last "@" inside it, so https://proxy.example.com/v1?u=@api.openai.com
resolves no key and no known compat record (REV-2 A.1). ADR 000N records the
decision.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
feat(auth): redact credential headers in Show and ToJSON; treat empty key vars as unset

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
feat(embedding)!: resolve keys per host and share the ClientEnv cache

EmbeddingModel.apiKey is now Maybe ApiKeySource; Nothing means the host's
conventional variable from defaultApiKeyEnvForBaseUrl, and an unknown host
refuses instead of sending OPENAI_API_KEY (REV-2 E.3).

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(transport): never follow redirects; compose the API path from a version-less base URL

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

Each body should also name the finding fixed and the tests that pin it, in the style of
the second and third examples. Commit directly on `master` (no feature branch) and do
not tag or bump versions; EP-10 does both.

At completion, tick the four `EP-2` lines in the Progress section of
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md` in the
same commit as the last milestone, and fill in this plan's Outcomes & Retrospective.


## Validation and Acceptance

Acceptance is behavioural, per finding, and every item below runs offline.

Host parsing (A.1, Theme 4 residual). In `cabal repl baikai` after M1:

```haskell
ghci> import Baikai
ghci> urlHost "https://proxy.example.com/v1?u=@api.openai.com"
Just "proxy.example.com"
ghci> defaultApiKeyEnvForBaseUrl "https://proxy.example.com/v1?u=@api.openai.com"
Nothing
ghci> autoDetectOpenAICompletions "https://proxy.example.com/v1?u=@api.openai.com" == defaultOpenAICompletionsCompat
True
ghci> defaultApiKeyEnvForBaseUrl "https://user:pw@api.openai.com/"
Just "OPENAI_API_KEY"
ghci> urlHost "http://[::1]:8080/v1"
Just "[::1]"
```

and the same five facts are asserted by `UrlSpec` and the extended cases in
`baikai/test/Main.hs`. Before M1 the first line prints `Just "api.openai.com"`.

Redaction (E.2). After M2:

```haskell
ghci> import qualified Data.Map.Strict as Map
ghci> let o = emptyOptions & #headers .~ Map.fromList [("Authorization","Bearer sk-live-1"),("X-Title","demo")]
ghci> "sk-live-1" `Data.Text.isInfixOf` Data.Text.pack (show o)
False
ghci> Map.lookup "Authorization" (o ^. #headers)
Just "Bearer sk-live-1"
```

The second answer shows the field is untouched and only the rendering is redacted; a
`Response` over a `Model` with the same map prints `<redacted>` too.

Empty variables (E.6). After M2, with `OPENAI_API_KEY=""` exported and the OpenAI
provider registered, `completeRequest Models.openai_gpt_4o_mini ctx emptyOptions` returns
an error-shaped `Response` whose `errorInfo` has category `AuthError` and message
`env var OPENAI_API_KEY is not set or is empty`, with no request sent (the key is
resolved before the transport). The `HelpersSpec` cases pin the pure resolution.

Embeddings (E.3). After M3, with only `OPENAI_API_KEY` set:

```haskell
ghci> import Baikai.Embedding
ghci> resolveEmbeddingKey (emptyEmbeddingModel & #baseUrl .~ "https://api.deepseek.com")
*** Exception: BaikaiError {category = AuthError, message = "env var DEEPSEEK_API_KEY is not set or is empty", …}
```

Before M3 the same call quietly yields the OpenAI secret. `EmbeddingSpec`'s "embeddings
share the cached ClientEnv" shows two spellings of one host add one cache entry.

Redirects (A.5). After M4 the fake-manager test in each `SseSpec` records exactly one
connection attempt, to the configured host, and one `Left` with `httpStatus = Just 302`;
before M4 it records `[("proxy.test",80),("evil.test",80)]`.

Path composition (A.6). After M4, `buildRequest` over `canonicalBaseUrl
"https://api.deepseek.com/v1"` has path `/v1/chat/completions`; before, the transport
requested `/v1/v1/chat/completions`. Streaming against a `Model` whose `baseUrl` is
`https://h.test/v1?api-version=2024-01` yields `[EventStart, EventError]` with category
`InvalidRequest` and a message containing `query string` and not `api-version=2024-01`.

Cache (Theme 10 residual). After M1, `cachedClientEnvCount` grows by one for
`https://Cache-Norm.test/` followed by `https://cache-norm.test`; before, by two.

The final gate is the keyless `cabal test all` command in Concrete Steps, green, with
every suite reporting a non-zero test count.


## Idempotence and Recovery

Every step is an ordinary source edit guarded by tests and can be repeated. The
milestones are sliced so each commit compiles and passes on its own: M1 rewires callers
to a parser that is a superset of the old behaviour for every URL the tests previously
accepted, so if a downstream package in this workspace fails to compile after M1 the
cause is an import of the deleted `dropUserInfo` or of a provider `Transport` internal,
both fixed by importing from `Baikai.Url`/`Baikai.Http`. If the hand-written `Show`
instances in M2 drift from the derived format, the "list every field" guard names the
missing field; restoring `deriving stock (Show)` temporarily is a safe intermediate
state that only reopens E.2. The `Maybe` change to `EmbeddingModel.apiKey` in M3 is the
one edit that changes a public type; if a consumer in this workspace breaks, wrap the
value in `Just` — there is nothing to migrate. In M4, `redirectCount = 0` and the
base-URL check are independent one-line changes; if a legitimate base URL is refused by
`baseUrlProblem`, the correct fix is to narrow the check and add the URL to `UrlSpec`,
never to bypass the check at a call site. Nothing here touches the network at build or
test time: the redirect test's "server" is an in-process `makeConnection` and the
embeddings tests resolve keys without sending. If the keyless gate reports a suite with
zero tests, a test module was not registered in its cabal `other-modules`; add it and
re-run.


## Interfaces and Dependencies

New public surface in core `baikai` (every name with a Haddock; EP-10 decides later
whether any of it moves behind `.Internal`):

- `Baikai.Url` (new, exposed): `UrlParts` (selectors only) and the six functions whose
  signatures Milestone 1 lists. Depends only on `text` and `base`.
- `Baikai.Http` (new, exposed): `canonicalBaseUrl :: Text -> Either Text
  Servant.Client.BaseUrl`; `getClientEnvCached :: Text -> IO Servant.Client.ClientEnv`;
  `cachedClientEnvCount :: IO Int`. Core `build-depends` gain `servant-client ^>=0.20`,
  `http-client ^>=0.7`, `http-client-tls ^>=0.3`.
- `Baikai.Compat`: `urlHost` and `hostMatchesSuffix` become re-exports of `Baikai.Url`;
  no other change to its exports.
- `Baikai.Auth`: adds `redactedMarker :: Text`, `isCredentialHeader :: Text -> Bool`,
  `redactHeaderValues :: Map Text Text -> Map Text Text`; `resolveApiKey` keeps its
  signature and changes the empty-value behaviour.
- `Baikai.Options`, `Baikai.Model`: hand-written `Show` and `ToJSON`; `Model` keeps its
  derived `FromJSON`; no field changes.
- `Baikai.Evidence.Build`: `sanitizeEndpoint` keeps its signature; `dropUserInfo` was
  never exported and is deleted.
- `Baikai.Embedding`: `EmbeddingModel` derives `Eq`, `Show`, `Generic`;
  `apiKey :: Maybe ApiKeySource` (breaking); adds `resolveEmbeddingKey :: EmbeddingModel
  -> IO Text` and `embeddingClientEnv :: EmbeddingModel -> IO Servant.Client.ClientEnv`.

Provider packages (no new dependencies; both already depend on `http-client`,
`http-client-tls`, `servant-client`, `case-insensitive`):

- `Baikai.Provider.OpenAI.Transport` and `Baikai.Provider.Claude.Transport`:
  `getClientEnvCached` and `cachedClientEnvCount` become re-exports of `Baikai.Http`;
  `resolveKey`, `requestHeaders`, `runWithTimeout` unchanged.
- `Baikai.Provider.OpenAI.Sse` and `Baikai.Provider.Claude.Sse`: add `buildRequest ::
  Servant.Client.BaseUrl -> RequestHeaders -> Aeson.Value -> Network.HTTP.Client.Request`;
  the four existing entry points keep their signatures.
- `Baikai.Provider.OpenAI.Api` and `Baikai.Provider.Claude.Api`: `prepareCall` gains the
  `baseUrlProblem` check; no signature change.

Test dependencies: `baikai:baikai-test` adds `servant-client`; the provider suites use
`Network.HTTP.Client.Internal` (already reachable through `http-client`) for the fake
manager. No new packages enter the install plan.

Cross-plan interfaces: EP-3 (`docs/plans/60-…`) reads `baseUrl` for the thinking style
and must call `Baikai.Url` if it needs a host; EP-5 (`docs/plans/62-…`) owns
`Transport.runWithTimeout` and the `timeoutMs` edge semantics that the replaced comment
in both `Sse.hs` now points to; EP-8 (`docs/plans/65-…`) owns the empty-`baseUrl`
evidence-endpoint default (REV-2 D.8), which this plan leaves as `Nothing`; EP-10
(`docs/plans/67-…`) records the `EmbeddingModel.apiKey` break in its version bump and
decides the final home of `Baikai.Url`, `Baikai.Http`, `buildRequest` and the two
embedding helpers; EP-11 (`docs/plans/68-…`) reconciles the guide section and capability
bullets this plan writes with the rest of the sweep.
