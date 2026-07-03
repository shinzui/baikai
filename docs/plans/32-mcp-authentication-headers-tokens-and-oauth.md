---
id: 32
slug: mcp-authentication-headers-tokens-and-oauth
title: "MCP authentication: headers, tokens, and OAuth"
kind: exec-plan
created_at: 2026-06-27T17:57:46Z
intention: "intention_01kw53ney9enqsnx9w2s55771p"
master_plan: "docs/masterplans/6-mcp-support-across-the-agent-stack.md"
---

# MCP authentication: headers, tokens, and OAuth

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Many useful MCP servers are not anonymous. "MCP" here means **Model Context Protocol** — a
JSON-RPC wire protocol over which a host application asks an external "MCP server" for tools,
resources, and prompts. A remote MCP server reached over HTTP frequently sits behind a wall:
it expects either a fixed secret on every request (an API token in an HTTP header), or a full
OAuth login where the user grants consent in a browser and the server hands back a short-lived
access token that must be refreshed as it expires.

Today baikai can talk to AI providers (Anthropic, OpenAI) but has no MCP client at all. A
sibling plan, `docs/plans/30-mcp-transport-and-json-rpc-client-core.md` (referred to throughout
as **C1**), builds the MCP transport and JSON-RPC client: it can open a connection to an MCP
server and exchange JSON-RPC messages, and it defines a configuration record `McpServerConfig`
with an `auth` field left as a placeholder. **This plan fills that placeholder.**

After this change, a host wiring up an MCP server can declare how to authenticate to it, and
the transport will honor that declaration on every request without further intervention:

- For a server that wants a static token, the host writes one line — "use this bearer token"
  (sourced from an environment variable so the secret never lives in code) — and every
  outgoing MCP request carries `Authorization: Bearer <token>`. A server that rejects an
  unauthenticated request with HTTP 401 now accepts the authenticated one.
- For a server that requires OAuth, the host supplies a small callback (the "interactive
  authorizer") that completes the browser consent step. baikai discovers the authorization
  server's endpoints, runs the OAuth 2.1 authorization-code flow with PKCE, stores the
  resulting tokens through a pluggable token store, attaches the access token to every
  request, and — when the server answers 401 because the token expired — silently refreshes
  the token using the saved refresh token and retries the request once.

The observable win: a previously unreachable authed MCP server becomes reachable, demonstrated
end-to-end against a stub server that first refuses (401) and then, once a token is present,
succeeds (200); and against a stub authorization server that issues a token, then issues a
fresh one when asked to refresh.

This work is consumed downstream by **C6**, the shikigami declaration layer (cross-repo,
`shinzui/shikigami`), which lets users declare authed MCP servers in their agent configuration.
C6 cannot offer authed servers until the types and behavior in this plan exist.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Define `Baikai.Mcp.Auth` core types (`McpAuth`, `StaticCredential`, `TokenSet`,
      `TokenStore`, `InteractiveAuthorizer`) and the `applyAuth` request decorator.
- [ ] M1: Wire `McpServerConfig.auth` into C1's transport so static headers/bearer tokens are
      injected on every request.
- [ ] M1: Test — stub server rejects an unauthenticated request (401) and accepts the
      authenticated one (200).
- [ ] M2: Implement OAuth authorization-server metadata discovery (RFC 8414 + RFC 9728
      protected-resource metadata) and optional dynamic client registration (RFC 7591).
- [ ] M2: Implement the PKCE authorization-code flow: build the authorization URL, run the
      interactive authorizer, exchange the code for a `TokenSet` at the token endpoint.
- [ ] M2: Test — full OAuth flow obtains a token against a stub authorization server.
- [ ] M3: Implement token refresh (proactive on expiry, reactive on 401) and retry-once.
- [ ] M3: Provide a default in-memory token store and a default loopback-redirect interactive
      authorizer; keep both pluggable.
- [ ] M3: Test — an expired/401 token is refreshed against the stub authorization server and
      the retried request succeeds; refresh is idempotent.
- [ ] Update the MasterPlan registry row for this plan and note the C6 dependency.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Support exactly three authentication modes — none, static header/bearer, and
  OAuth 2.1 authorization-code-with-PKCE — encoded as the closed sum type `McpAuth`.
  Rationale: These three cover the MCP authorization spec's realistic deployment shapes. "No
  auth" is the local/dev default; static tokens cover API-key servers; OAuth 2.1 with PKCE is
  the standard interactive flow the MCP spec mandates for user-delegated access. A closed sum
  keeps the transport's handling exhaustive and lets the compiler force every call site to
  account for each mode. Other OAuth grant types (client-credentials, device code) are
  deliberately omitted from v1; if needed they become new constructors later.
  Date: 2026-06-27

- Decision: Hand-roll the OAuth client against `http-client` rather than adopt a third-party
  OAuth library.
  Rationale: The MCP profile of OAuth is narrow (one grant type, PKCE, metadata discovery,
  refresh). A dedicated library (e.g. `hoauth2`) would pull a large dependency for a few HTTP
  round-trips and JSON shapes we already know how to build with `aeson`. baikai already uses
  `http-client`/`http-client-tls` in its `baikai-fetch-models` executable, so the dependency
  is familiar in-repo. PKCE's cryptography (a SHA-256 hash and random bytes) comes from
  `crypton`, and base64url encoding from `base64-bytestring`, which is already a `baikai`
  dependency. We revisit if the hand-rolled surface grows unwieldy.
  Date: 2026-06-27

- Decision: Make the token store pluggable via a record-of-functions `TokenStore`, default to
  an in-memory store, and route all OAuth HTTP through an injectable `HttpBackend`
  request-runner.
  Rationale: Hosts differ in where they persist tokens (memory for ephemeral CLIs, a file or
  OS keychain for long-lived daemons). A record of `IO` actions keeps the persistence policy
  out of baikai while letting baikai drive it. The injectable `HttpBackend` lets tests run the
  entire OAuth flow against an in-process stub authorization server (a pure function returning
  canned responses) with no sockets — deterministic and idempotent. Production wiring passes a
  backend backed by the same `http-client` `Manager` C1's transport owns.
  Date: 2026-06-27

- Decision: Model the interactive consent step as a single seam — `InteractiveAuthorizer`, a
  `newtype` over `AuthorizationRequest -> IO AuthorizationResult` — and ship a default
  loopback-redirect implementation, while keeping the real UX with the consumer.
  Rationale: Completing OAuth consent inevitably involves host-specific behavior (opening a
  browser, running a tiny local web server to catch the redirect, or pasting a code). baikai
  must not hard-code any of that. The seam isolates "show the user this URL, return the code
  and state they came back with" from the protocol mechanics baikai owns. The default opens
  the system browser and listens on a loopback port for the redirect, which works for desktop
  hosts; servers/CLIs without a browser supply their own authorizer.
  Date: 2026-06-27

- Decision: Note `shinzui/shomei` (the portfolio's own auth service) as a *future* alternative
  interactive-auth backend, not a v1 dependency.
  Rationale: A future host could implement `InteractiveAuthorizer` by delegating consent to
  shomei rather than a raw browser flow, centralizing portfolio auth. But MCP's standard is
  the OAuth 2.1 flow specified here, so v1 targets that and leaves shomei as a pluggable
  implementation a consumer can write against the same seam. No code dependency on shomei is
  introduced.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### What this repository is

`baikai` (媒介, "intermediary") is a multi-package Haskell project providing a unified interface
to AI providers. It is a Cabal project built with GHC 9.12.4 inside a Nix dev shell. The
packages live in sibling directories, each with its own `.cabal` file:

- `baikai/` — the core library (`baikai.cabal`), modules under `Baikai.*` in `baikai/src`.
- `baikai-claude/`, `baikai-openai/` — vendor provider packages.
- `baikai-kit/`, `baikai-trace-otel/`, `baikai-smoke/`, `baikai-effectful/` — supporting packages.

The canonical build/test commands (from `README.md`) run inside the Nix dev shell:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

Tests use `tasty` with `tasty-hunit`; the core test-suite is `baikai-test` (see the
`test-suite baikai-test` stanza in `baikai/baikai.cabal`, source in `baikai/test`, entry point
`baikai/test/Main.hs` which aggregates `*Spec` modules).

### Terms of art, defined plainly

- **MCP (Model Context Protocol):** a JSON-RPC protocol for a host application to obtain tools,
  resources, and prompts from an external server. "Remote MCP server" means one reached over
  HTTP (as opposed to a local subprocess speaking over stdin/stdout).
- **JSON-RPC:** a request/response convention where each message is a small JSON object with a
  method name, parameters, and an id. C1 owns the JSON-RPC encoding; this plan only concerns
  the HTTP headers wrapping those messages and the tokens that authorize them.
- **Bearer token:** a secret string presented in the HTTP header `Authorization: Bearer
  <token>`. The server trusts any caller who presents a valid token, like a hotel key card.
- **OAuth 2.1:** the current consolidation of the OAuth 2.0 authorization framework. It defines
  how a user (the "resource owner") grants a client application delegated access to a protected
  resource without sharing their password. The relevant pieces here are: an **authorization
  server** that authenticates the user and issues tokens; an **authorization endpoint** the
  user's browser visits to consent; and a **token endpoint** the client calls to exchange a
  short-lived authorization code for an **access token** (and usually a **refresh token**).
- **Authorization-code flow:** the OAuth flow where the browser receives a one-time `code`
  after consent, and the client exchanges that `code` (plus proof it started the flow) for
  tokens out-of-band. Preferred because the long-lived token never travels through the browser.
- **PKCE (Proof Key for Code Exchange, "pixy"):** an extension that hardens the
  authorization-code flow against code interception. The client invents a random secret (the
  **code verifier**), sends only its SHA-256 hash (the **code challenge**) when starting the
  flow, and reveals the verifier when redeeming the code. The authorization server checks that
  `SHA256(verifier) == challenge`, proving the redeemer is the same party that started the
  flow. OAuth 2.1 makes PKCE mandatory for authorization-code flows.
- **Authorization-server metadata (RFC 8414):** a JSON document at a well-known URL
  (`/.well-known/oauth-authorization-server`) listing the server's endpoints (authorization,
  token, registration) and supported features. Discovering it means the host need not hard-code
  endpoint URLs.
- **Protected-resource metadata (RFC 9728):** a JSON document the MCP *resource* server
  publishes (or names via a `WWW-Authenticate` header on its 401) pointing at which
  authorization server(s) protect it. This is how the MCP client learns which authorization
  server to discover in the first place.
- **Dynamic client registration (RFC 7591):** an endpoint that mints a fresh OAuth client id
  (and optionally secret) on demand by POSTing client metadata, for clients that were not
  pre-registered with the authorization server.

### How baikai handles provider authentication today

baikai already has a small, redaction-aware credential abstraction we will reuse rather than
reinvent. In `baikai/src/Baikai/Auth.hs`:

```haskell
data ApiKeySource
  = ApiKeyLiteral !Text     -- a literal token (e.g. supplied by a test)
  | ApiKeyEnv !String       -- the name of an environment variable to read lazily

resolveApiKey :: (MonadIO m) => ApiKeySource -> m Text
```

`ApiKeySource`'s `Show` and `ToJSON` instances redact literal secrets (`renderApiKeySourceForDebug`
prints `ApiKeyLiteral <redacted>`), and `resolveApiKey` reads the environment lazily, throwing a
`BaikaiError` in the `AuthError` category if a named env var is unset. We will source MCP static
tokens and OAuth client secrets through `ApiKeySource` so MCP credentials inherit the same
redaction and env-var behavior.

The error type, in `baikai/src/Baikai/Error.hs`, is `BaikaiError` with a closed `ErrorCategory`
enum. The members relevant here are `AuthError` (HTTP 401/403 or a missing credential),
`TransientError` (network/5xx, retryable), and `InvalidRequest`. Smart constructors include
`authError :: Text -> BaikaiError`, `providerError`, and `invalidRequest`. The pure helper
`classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory` maps 401/403 to `AuthError`, 429 to
`RateLimited`, 5xx/408 to `TransientError`, etc. We will raise `BaikaiError` values from this
module so MCP auth failures look like every other baikai failure to callers.

The provider packages show the request-decoration pattern we mirror. In
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, `resolveKey` reads `Options.apiKey` (an
`ApiKeySource`) or falls back to `ApiKeyEnv "ANTHROPIC_API_KEY"`, then passes the resolved text
to the Anthropic SDK which sets the `x-api-key` header. The per-call `Options` record
(`baikai/src/Baikai/Options.hs`) already carries `apiKey :: Maybe ApiKeySource` and
`headers :: Map Text Text`, establishing the project's convention that headers are a
`Map Text Text` and credentials are `Maybe ApiKeySource`. We follow both conventions.

### The C1 contract this plan depends on (hard dependency)

C1 (`docs/plans/30-mcp-transport-and-json-rpc-client-core.md`) owns the transport and defines
`McpServerConfig` with an `auth` placeholder. **At the time of writing, C1 is a skeleton and
the exact field names are not yet finalized.** This plan assumes the following C1 shapes; the
first implementation task is to read C1's actual definitions and reconcile any differences,
recording them in the Decision Log. The integration contract is: `Baikai.Mcp.Auth` defines
`McpAuth` and `McpServerConfig.auth :: McpAuth`.

Assumed C1 module layout — MCP code lives under the `Baikai.Mcp.*` namespace. Whether C1 places
it in the core `baikai` library or in a new `baikai-mcp` package is C1's decision; **this plan
adds `Baikai.Mcp.Auth` to whichever package C1 chose.** For concreteness this plan assumes a new
`baikai-mcp` package (so the heavier `http-client`/`crypton` dependencies stay out of the core
published library), exposing modules such as `Baikai.Mcp.Transport`, `Baikai.Mcp.Connection`,
and `Baikai.Mcp.Config`. If C1 instead used the core `baikai` library, substitute that package
name in every command below.

Assumed C1 types (reconcile on first contact):

```haskell
-- Baikai.Mcp.Config (C1)
data McpServerConfig = McpServerConfig
  { name    :: !Text
  , baseUrl :: !Text          -- the remote MCP server's HTTP endpoint
  , auth    :: !McpAuth       -- <-- the placeholder THIS plan defines (Baikai.Mcp.Auth)
  -- ... other C1 fields (timeouts, headers, etc.)
  }

-- Baikai.Mcp.Transport (C1)
-- The transport performs each MCP HTTP request. C1 exposes a hook so that an
-- outbound request can be decorated before it is sent, and a way to observe the
-- response status so a 401 can trigger a refresh-and-retry.
```

If C1's transport does not yet expose a decoration/response hook, M1 adds the minimal seam
described in "Plan of Work" and C1 adopts it; coordinate via the MasterPlan Integration Points.


## Plan of Work

The work proceeds in three independently verifiable milestones, in the order the masterplan
requires: static tokens first (smallest, unblocks C6 for the common case), then the OAuth
discovery + PKCE flow, then refresh + pluggability + the interactive seam. Each milestone ends
with a test that proves observable behavior against a stub server.

All new code lands in `baikai-mcp/src/Baikai/Mcp/Auth.hs` (create the file), with tests in the
MCP package's test-suite (assume `baikai-mcp/test`, suite `baikai-mcp-test`; if C1 named it
differently, use that name). Add `Baikai.Mcp.Auth` to the package's `exposed-modules` and add
`crypton` to its `build-depends` (`http-client`, `http-client-tls`, `aeson`, `bytestring`,
`base64-bytestring`, `text`, `containers`, `time` are assumed already present from C1; add any
that are missing).

### Milestone M1 — static headers and bearer tokens, injected by the transport

Scope: define the `McpAuth` type and the no-auth and static-credential modes, plus the request
decorator that injects headers, and wire it into C1's transport. At the end, a host can declare
`McpNoAuth`, a custom-header set, or a bearer token, and the transport attaches the right
headers to every MCP request. Nothing about OAuth exists yet.

Edits:

1. Create `baikai-mcp/src/Baikai/Mcp/Auth.hs`. Define the top-level sum and the static
   credential record. Source the token through `Baikai.Auth.ApiKeySource` so secrets are
   redacted and env-sourced:

   ```haskell
   data McpAuth
     = McpNoAuth
     | McpStatic !StaticCredential
     | McpOAuth !OAuthConfig            -- defined in M2; in M1 leave the constructor with a
                                        -- minimal placeholder field set, or stub OAuthConfig
                                        -- as an opaque record completed in M2.

   newtype StaticCredential = StaticCredential
     { headers :: Map Text Text }       -- header name -> value; matches Options.headers shape

   -- Convenience constructors:
   noAuth :: McpAuth
   bearerToken :: ApiKeySource -> McpAuth      -- Authorization: Bearer <resolved token>
   customHeaders :: Map Text Text -> McpAuth   -- arbitrary static headers (e.g. X-Api-Key)
   ```

2. Define the runtime auth handle and the request decorator. The handle holds resolved state
   (for static auth, the materialized header map; OAuth state is added in M2). `applyAuth`
   takes the handle and an `http-client` `Request` and returns the decorated request:

   ```haskell
   data McpAuthState                      -- opaque; built by initAuth
   initAuth :: HttpBackend -> McpServerConfig -> IO McpAuthState
   applyAuth :: McpAuthState -> Request -> IO Request
   ```

   For `McpStatic`, `initAuth` resolves each `ApiKeySource`-backed value once (so a missing env
   var fails fast with an `AuthError`), and `applyAuth` merges the headers into
   `requestHeaders`. For `McpNoAuth`, `applyAuth` returns the request unchanged.

3. Define `HttpBackend`, the injectable request-runner used by everything in this module so
   tests need no sockets. In production it wraps the `http-client` `Manager` C1's transport owns:

   ```haskell
   newtype HttpBackend = HttpBackend
     { performRequest :: Request -> IO (Response ByteString) }

   managerBackend :: Manager -> HttpBackend     -- httpLbs against a real Manager
   ```

4. Wire into C1's transport. In C1's transport module, where an outbound MCP `Request` is built
   just before it is sent, call `applyAuth state req`. Construct the `McpAuthState` once when the
   connection opens (`initAuth backend config`) and thread it through the connection. If C1 does
   not yet expose this seam, add a single field to the transport's connection state holding the
   `McpAuthState` and call `applyAuth` in the send path; this is the minimal change and must be
   coordinated with C1.

Commands to run (Nix dev shell, repo root):

```bash
nix develop --command cabal build baikai-mcp
nix develop --command cabal test baikai-mcp
```

Acceptance: a `tasty-hunit` test (`McpAuthSpec`, "static bearer token") stands up a stub
`HttpBackend` that returns 401 unless the request carries `Authorization: Bearer s3cret`. With
`McpNoAuth` the decorated request gets 401; with `bearerToken (ApiKeyLiteral "s3cret")` the
decorated request gets 200. The test asserts both, proving the header is actually injected.

### Milestone M2 — OAuth metadata discovery and the PKCE authorization-code flow

Scope: implement everything needed to *obtain* an OAuth access token: discover the authorization
server's endpoints, optionally register a client dynamically, run the PKCE authorization-code
flow through the interactive seam, and exchange the code for a `TokenSet`. Refresh and the
default token store/authorizer come in M3; here the token store can be a passed-in stub and the
authorizer a test double.

Begin with a small PKCE verification spike (first task of M2): in GHCi or a throwaway test,
compute a code challenge from a known verifier with `crypton` + `base64-bytestring` and confirm
it matches a published PKCE test vector, proving the crypto pipeline before wiring it into the
flow. RFC 7636's worked example uses verifier
`dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` yielding challenge
`E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`.

Edits to `Baikai.Mcp.Auth`:

1. Define the OAuth data types:

   ```haskell
   data OAuthConfig = OAuthConfig
     { issuer       :: !(Maybe Text)          -- AS base URL; if Nothing, discover via RFC 9728
     , clientId     :: !(Maybe Text)          -- if Nothing, dynamic-register (RFC 7591)
     , clientSecret :: !(Maybe ApiKeySource)  -- confidential clients only; public clients omit
     , scopes       :: ![Text]
     , redirectUri  :: !Text                  -- e.g. "http://127.0.0.1:0/callback"
     , tokenStore   :: !TokenStore            -- pluggable persistence (M3 supplies a default)
     , authorizer   :: !InteractiveAuthorizer -- consent seam (M3 supplies a default)
     }

   data TokenSet = TokenSet
     { accessToken  :: !Text
     , tokenType    :: !Text                  -- normally "Bearer"
     , refreshToken :: !(Maybe Text)
     , expiresAt    :: !(Maybe UTCTime)       -- absolute expiry, computed from expires_in
     , scope        :: !(Maybe Text)
     }

   data AuthServerMetadata = AuthServerMetadata
     { issuer                      :: !Text
     , authorizationEndpoint       :: !Text
     , tokenEndpoint               :: !Text
     , registrationEndpoint        :: !(Maybe Text)
     , scopesSupported             :: ![Text]
     , codeChallengeMethodsSupported :: ![Text]
     }
   ```

2. Implement discovery: `discoverMetadata :: HttpBackend -> OAuthConfig -> Text -> IO
   AuthServerMetadata` where the third argument is the MCP server base URL. When `issuer` is
   set, GET `<issuer>/.well-known/oauth-authorization-server` and decode RFC 8414 JSON. When it
   is `Nothing`, first fetch the resource's protected-resource metadata (RFC 9728) — from
   `<resource>/.well-known/oauth-protected-resource`, or from the `WWW-Authenticate: Bearer
   resource_metadata=...` header on the 401 the MCP server returned — to learn the authorization
   server, then fetch its RFC 8414 metadata. Raise an `AuthError` `BaikaiError` if discovery
   fails or required endpoints are absent.

3. Implement optional dynamic client registration: `registerClient :: HttpBackend ->
   AuthServerMetadata -> OAuthConfig -> IO Text` (returns a client id). Only invoked when
   `clientId` is `Nothing` and `registrationEndpoint` is present; POSTs client metadata
   (redirect URIs, grant/response types, `token_endpoint_auth_method`) per RFC 7591 and reads
   `client_id` (and any `client_secret`) from the response.

4. Implement PKCE helpers: `newCodeVerifier :: IO Text` (43–128 chars of base64url-encoded
   random bytes from `crypton`'s `getRandomBytes`), and `codeChallenge :: Text -> Text`
   (`base64url(SHA256(verifier))`, unpadded, via `crypton`'s `hashWith SHA256` and
   `Data.ByteString.Base64.URL.encodeUnpadded`).

5. Implement the authorization-code flow: `authorize :: HttpBackend -> AuthServerMetadata ->
   OAuthConfig -> IO TokenSet`. It (a) generates a verifier, challenge, and random `state`;
   (b) builds the authorization URL on `authorizationEndpoint` with `response_type=code`,
   `client_id`, `redirect_uri`, `scope`, `state`, `code_challenge`, `code_challenge_method=S256`;
   (c) calls `runAuthorization (authorizer cfg) AuthorizationRequest{..}` to get back the `code`
   and `state`; (d) verifies the returned `state` matches; (e) POSTs to `tokenEndpoint` with
   `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, the `code_verifier`,
   and client secret if confidential; (f) decodes the token response into a `TokenSet`,
   computing `expiresAt` from `expires_in` and the current time.

6. Define the seam types (full implementations land in M3):

   ```haskell
   newtype InteractiveAuthorizer = InteractiveAuthorizer
     { runAuthorization :: AuthorizationRequest -> IO AuthorizationResult }

   data AuthorizationRequest = AuthorizationRequest
     { authorizationUrl :: !Text, redirectUri :: !Text, state :: !Text }

   data AuthorizationResult = AuthorizationResult
     { code :: !Text, state :: !Text }
   ```

Commands:

```bash
nix develop --command cabal build baikai-mcp
nix develop --command cabal test baikai-mcp
```

Acceptance: `McpAuthSpec` ("oauth obtains a token") supplies an `HttpBackend` stub acting as a
stub authorization server — it answers the RFC 8414 well-known path with metadata JSON, and the
token endpoint with a JSON token response when the POST carries the expected `code`,
`code_verifier`, and `grant_type` — and an `InteractiveAuthorizer` double that returns a canned
`code` and echoes the `state`. The test asserts `authorize` returns a `TokenSet` whose
`accessToken` matches the stub, and that the token POST included `code_challenge_method=S256`
and a `code_verifier` whose SHA-256/base64url equals the challenge sent to the authorization
endpoint (proving PKCE is wired correctly, not just present).

### Milestone M3 — refresh, pluggable token store, interactive seam, retry-once

Scope: make OAuth durable and usable in production. Add token refresh (proactive when the
access token is near expiry, reactive when the server returns 401), the pluggable `TokenStore`
with a default in-memory implementation, the default loopback-redirect `InteractiveAuthorizer`,
and the transport's retry-once-on-401 behavior. At the end, the full lifecycle works: obtain →
attach → refresh on expiry → retry, all persisted through the store.

Edits:

1. Define and default the token store:

   ```haskell
   data TokenStore = TokenStore
     { loadTokens  :: IO (Maybe TokenSet)
     , saveTokens  :: TokenSet -> IO ()
     , clearTokens :: IO ()
     }

   inMemoryTokenStore :: IO TokenStore   -- backed by an IORef (Maybe TokenSet)
   ```

   A host wanting file/keychain persistence supplies its own `TokenStore`; baikai never decides
   where secrets live.

2. Extend `McpAuthState` to hold the `OAuthConfig`, the discovered `AuthServerMetadata`, the
   resolved `clientId`, and an `IORef (Maybe TokenSet)` mirror of the store. `initAuth` for the
   `McpOAuth` case loads any saved tokens from the store; if none, it does **not** run the
   browser flow eagerly — the first `applyAuth` that needs a token triggers `authorize` lazily
   (so opening a connection never blocks on consent unless a request is actually made).

3. Implement token acquisition/refresh logic:

   ```haskell
   currentAccessToken :: HttpBackend -> McpAuthState -> IO Text
   refreshTokens      :: HttpBackend -> McpAuthState -> IO TokenSet   -- uses refresh_token grant
   ```

   `currentAccessToken` returns the cached token if present and not within a small skew of
   `expiresAt`; otherwise it refreshes (if a `refreshToken` exists) or runs `authorize` (if
   not), saves the new `TokenSet` to the store, updates the IORef, and returns the access token.
   `refreshTokens` POSTs `grant_type=refresh_token` to the token endpoint. `applyAuth` for the
   OAuth case sets `Authorization: Bearer <currentAccessToken>`.

4. Implement the 401 retry seam. In C1's transport send path, after `applyAuth`, if the response
   status is 401 and the auth mode is OAuth, call `refreshTokens`, re-decorate the request with
   the new token, and resend **exactly once**. A second 401 surfaces as an `AuthError`
   `BaikaiError`. Static-auth 401s are not retried (a static token does not get fresher on
   retry); they surface immediately. Expose this as a helper
   `sendWithAuthRetry :: HttpBackend -> McpAuthState -> Request -> IO (Response ByteString)` so
   C1's transport calls one function.

5. Implement the default interactive authorizer:

   ```haskell
   loopbackAuthorizer :: InteractiveAuthorizer
   ```

   It opens the system browser at `authorizationUrl` (using `xdg-open`/`open`/`start` via
   `System.Process`, best-effort, also printing the URL for headless fallback) and starts a
   tiny loopback HTTP listener on the `redirectUri`'s port to capture the `code` and `state`
   from the redirect query string, then returns them. Keep this implementation small and
   isolated; document that hosts without a browser should supply their own authorizer (for
   example, one delegating to `shinzui/shomei` in the future — see Decision Log).

Commands:

```bash
nix develop --command cabal build baikai-mcp
nix develop --command cabal test baikai-mcp
nix develop --command cabal test all     # ensure no regressions elsewhere
```

Acceptance: `McpAuthSpec` ("oauth refreshes on 401") seeds an `inMemoryTokenStore` with an
expired `TokenSet` carrying a refresh token. The stub authorization server's token endpoint
returns a new access token for a `grant_type=refresh_token` POST. The stub MCP `HttpBackend`
returns 401 for the old token and 200 for the new one. Driving `sendWithAuthRetry` once yields a
200, the store now holds the refreshed `TokenSet`, and the authorization-server stub recorded
exactly one refresh call (proving retry-once, not a loop). A second test calls `refreshTokens`
twice and asserts the store ends in a consistent single-token state (idempotence).


## Concrete Steps

Run everything from the repository root inside the Nix dev shell. The first time, enter the
shell once and run commands within it, or prefix each command with `nix develop --command`.

1. Read C1's actual definitions and reconcile the assumed contract:

   ```bash
   cd /Users/shinzui/Keikaku/bokuno/baikai
   git grep -n "McpServerConfig" -- 'baikai*/src'
   git grep -n "module Baikai.Mcp" -- 'baikai*/src'
   ```

   Expected output: the `McpServerConfig` record with an `auth` field and the `Baikai.Mcp.*`
   modules C1 created. Note the real package name and transport send-path function; if they
   differ from this plan's assumptions, update the Decision Log and the paths below.

2. Create the module and register it in the package's cabal file:

   ```bash
   cd /Users/shinzui/Keikaku/bokuno/baikai
   $EDITOR baikai-mcp/src/Baikai/Mcp/Auth.hs        # new file (M1 types + applyAuth)
   $EDITOR baikai-mcp/baikai-mcp.cabal              # add Baikai.Mcp.Auth + crypton dep
   ```

3. Build and run focused tests after each milestone:

   ```bash
   nix develop --command cabal build baikai-mcp
   nix develop --command cabal test baikai-mcp
   ```

   Expected (success) transcript shape:

   ```text
   McpAuthSpec
     static bearer token: unauthenticated 401, authenticated 200: OK
     oauth obtains a token (PKCE S256):                            OK
     oauth refreshes on 401 and retries once:                     OK

   All N tests passed
   ```

4. The PKCE spike (during M2) can be checked directly in GHCi:

   ```bash
   nix develop --command cabal repl baikai-mcp
   ```

   ```haskell
   ghci> codeChallenge "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
   "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
   ```

   Matching this RFC 7636 vector confirms the SHA-256 + base64url-unpadded pipeline.

5. Before finishing, run the full suite to confirm no regressions:

   ```bash
   nix develop --command cabal build all
   nix develop --command cabal test all
   ```

This section must be updated as work proceeds — replace assumed package/suite names with the
real ones once C1 is read, and paste the actual test transcript.


## Validation and Acceptance

Acceptance is phrased as observable behavior verified by `tasty-hunit` tests in `McpAuthSpec`,
each of which fails before its milestone's code exists and passes after.

- Static token (M1): a stub `HttpBackend` returns HTTP 401 unless the request carries
  `Authorization: Bearer s3cret`. With `McpNoAuth`, `applyAuth` leaves the request bare and the
  stub returns 401. With `bearerToken (ApiKeyLiteral "s3cret")`, `applyAuth` adds the header and
  the stub returns 200. Both assertions must hold. This proves the header reaches the wire, not
  merely that a value was stored.

- OAuth obtains a token (M2): against a stub authorization server (`HttpBackend` returning RFC
  8414 metadata and a token-endpoint response) and a test `InteractiveAuthorizer` returning a
  canned `code`, `authorize` returns a `TokenSet` with the expected `accessToken`. The recorded
  token POST must include `code_challenge_method=S256` and a `code_verifier` that hashes
  (SHA-256, base64url) to the challenge that was sent to the authorization endpoint. This proves
  PKCE is correct, not cosmetic.

- OAuth refresh + retry-once (M3): an `inMemoryTokenStore` seeded with an expired token plus
  refresh token; the stub MCP backend returns 401 for the stale access token and 200 for the
  refreshed one; the stub authorization server returns a new token for a `refresh_token` grant.
  One call to `sendWithAuthRetry` returns 200, the store now holds the refreshed token, and the
  authorization-server stub saw exactly one refresh call. This proves refresh-on-401 with a
  single retry (no infinite loop).

Beyond compilation, these tests demonstrate the user-visible promise from Purpose: an authed
MCP server that refuses anonymous access becomes reachable, and an OAuth-protected one keeps
working across token expiry without manual reauthentication.


## Idempotence and Recovery

The plan is additive: it creates one new module and (minimally) extends C1's transport send
path. Re-running the build/test commands is always safe.

Runtime idempotence:

- `applyAuth` is a pure-ish decorator (it may read cached state but performs no destructive
  action); calling it repeatedly on fresh request values yields the same headers.
- Token refresh is idempotent in effect: `currentAccessToken` and `refreshTokens` converge the
  store on a single current `TokenSet`; calling refresh twice in succession ends with one valid
  token, never duplicates. The store's `saveTokens` overwrites rather than appends.
- The 401 retry is bounded to exactly one re-send. A second 401 is surfaced as an `AuthError`
  `BaikaiError` rather than retried again, so a misconfigured server cannot induce a loop.
- Discovery and dynamic registration are read-mostly; registration, when used, may mint a new
  client id on each run if the host does not persist it. Recommend (and document) that hosts
  persist the registered `client_id` via their `TokenStore`-adjacent config so repeated runs
  reuse it; absent that, a fresh registration is harmless but wasteful.

Recovery: if discovery or token exchange fails midway, no partial token is written to the store
(the store is updated only on a fully decoded `TokenSet`). A failed flow leaves the previous
stored token intact, so a transient outage degrades to "use the old token / retry later" rather
than corrupting state. To force a clean re-auth, a host calls `clearTokens` on its store.


## Interfaces and Dependencies

New module: `Baikai.Mcp.Auth` in package `baikai-mcp` (file
`baikai-mcp/src/Baikai/Mcp/Auth.hs`; substitute the package C1 actually used).

Libraries:

- `http-client` + `http-client-tls` — perform OAuth HTTP round-trips and (via C1) MCP requests.
  Already used in-repo by `baikai-fetch-models`.
- `crypton` (`Crypto.Hash` for SHA-256, `Crypto.Random.getRandomBytes` for the PKCE verifier).
- `base64-bytestring` (`Data.ByteString.Base64.URL.encodeUnpadded`) — already a `baikai`
  dependency.
- `aeson`, `bytestring`, `text`, `containers`, `time` — JSON, bytes, maps, and absolute expiry.
- `Baikai.Auth` (`ApiKeySource`, `resolveApiKey`) — credential sourcing/redaction, reused.
- `Baikai.Error` (`BaikaiError`, `authError`, `classifyHttpStatus`) — failure reporting.

Shared integration contract (must match C1 exactly): `Baikai.Mcp.Auth` exports `McpAuth`, and
`Baikai.Mcp.Config.McpServerConfig.auth :: McpAuth` consumes it.

Public surface that must exist by the end of each milestone (full module paths):

End of M1 — `Baikai.Mcp.Auth`:

```haskell
data McpAuth                      -- McpNoAuth | McpStatic StaticCredential | McpOAuth OAuthConfig
newtype StaticCredential
data McpAuthState                 -- opaque
newtype HttpBackend
noAuth        :: McpAuth
bearerToken   :: ApiKeySource -> McpAuth
customHeaders :: Map Text Text -> McpAuth
managerBackend :: Manager -> HttpBackend
initAuth      :: HttpBackend -> McpServerConfig -> IO McpAuthState
applyAuth     :: McpAuthState -> Request -> IO Request
```

End of M2 — add:

```haskell
data OAuthConfig
data TokenSet
data AuthServerMetadata
newtype InteractiveAuthorizer
data AuthorizationRequest
data AuthorizationResult
discoverMetadata :: HttpBackend -> OAuthConfig -> Text -> IO AuthServerMetadata
registerClient   :: HttpBackend -> AuthServerMetadata -> OAuthConfig -> IO Text
newCodeVerifier  :: IO Text
codeChallenge    :: Text -> Text
authorize        :: HttpBackend -> AuthServerMetadata -> OAuthConfig -> IO TokenSet
```

End of M3 — add:

```haskell
data TokenStore
inMemoryTokenStore  :: IO TokenStore
loopbackAuthorizer  :: InteractiveAuthorizer
currentAccessToken  :: HttpBackend -> McpAuthState -> IO Text
refreshTokens       :: HttpBackend -> McpAuthState -> IO TokenSet
sendWithAuthRetry   :: HttpBackend -> McpAuthState -> Request -> IO (Response ByteString)
```

Dependents: **C6** (`shinzui/shikigami`, cross-repo) — the shikigami declaration layer surfaces
authed MCP servers to end users and consumes `McpAuth` and its constructors. C6 must not be
started until M1's `McpAuth` type is merged, and benefits from M3's full OAuth surface before it
can declare OAuth-protected servers. Record this in the MasterPlan's Integration Points and
Dependency Graph.
