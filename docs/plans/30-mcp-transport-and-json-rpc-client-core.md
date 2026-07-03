---
id: 30
slug: mcp-transport-and-json-rpc-client-core
title: "MCP transport and JSON-RPC client core"
kind: exec-plan
created_at: 2026-06-27T17:57:46Z
intention: "intention_01kw53nep1e9kbvq5ebzpjevmr"
master_plan: "docs/masterplans/6-mcp-support-across-the-agent-stack.md"
---

# MCP transport and JSON-RPC client core

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, baikai can open a live connection to a remote **MCP server** and talk
to it. MCP — the *Model Context Protocol* — is an open protocol that lets an AI application
(the "host" or "client") connect to an external program (the "server") that exposes tools,
data, and prompts the model can use. Servers speak it over a network using **JSON-RPC 2.0**,
a small, well-known convention for sending a request (a JSON object naming a `method`, some
`params`, and an `id`) and getting back a matching response (a JSON object carrying the same
`id` and either a `result` or an `error`).

This plan delivers the *foundation* — the parts every later MCP feature stands on:

1. The JSON-RPC 2.0 message types and their JSON encoders/decoders.
2. The MCP connection *lifecycle*: the `initialize` handshake (where client and server tell
   each other who they are and what they can do) and the `notifications/initialized`
   message that finishes it.
3. A network *transport* that carries those messages over HTTP — both the modern
   "Streamable HTTP" transport and the legacy "HTTP+SSE" transport — reusing baikai's
   existing HTTP and `streamly` streaming stack.
4. A small client API: an opaque `McpConnection` handle, `connectMcp` to open and hand-shake
   it, `closeMcp` to tear it down, and generic `request` / `notify` calls to send any
   JSON-RPC method over the wire.

What you can *observe* when it works: starting a local stub MCP server and running the new
test suite, you will see baikai complete the `initialize` handshake (printing the server's
reported name, version, and capabilities) and round-trip a generic JSON-RPC `ping` request,
asserting the exact response. That proves the connection, framing, correlation, and error
mapping all work end-to-end — not merely that code compiles.

This plan deliberately stops at the *connection + generic request* layer. It does **not**
implement tool discovery or invocation (`listTools`, `callTool`, the `McpTool` type): that is
the sibling plan **C2**, `docs/plans/31-mcp-tool-discovery-and-invocation.md`, which builds
directly on the `request` mechanism delivered here. Real authentication (OAuth, token refresh)
is the sibling plan **C3**, `docs/plans/32-mcp-auth.md`; this plan ships only a minimal auth
placeholder. Resources and prompts are **C4**. The cross-repo adapters (`shinzui/shikumi`,
C5) and declaration surface (`shinzui/shikigami`, C6) also consume the `Baikai.Mcp.*` API
defined here.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Create the `baikai-mcp` package skeleton (cabal file, `cabal.project` entry,
  empty `Baikai.Mcp` module) that builds clean under `cabal build baikai-mcp`.
- [ ] M2: Implement `Baikai.Mcp.Protocol` — JSON-RPC 2.0 request/response/notification/error
  types plus the MCP `initialize`/`initialized` types, with `ToJSON`/`FromJSON` instances.
- [ ] M2: Unit tests proving JSON-RPC and `initialize` values round-trip through Aeson and
  match the wire shapes (`jsonrpc: "2.0"`, correct method names, id correlation).
- [ ] M3: Implement `Baikai.Mcp.Transport` — the Streamable HTTP transport (POST a message,
  read a single JSON or an SSE stream of responses) over `http-client` + `streamly`.
- [ ] M3: Implement the legacy HTTP+SSE transport path (GET to open the SSE stream, learn the
  POST endpoint, send messages, read responses off the stream).
- [ ] M4: Implement `Baikai.Mcp.Client` — `McpServerConfig`, `McpConnection`, `connectMcp`
  (open + handshake), `closeMcp`, generic `request` and `notify`, request-id correlation.
- [ ] M5: Map all failure paths (HTTP status, network exception, JSON-RPC `error`, decode
  failure) into `Baikai.Error.BaikaiError` with the right `ErrorCategory`.
- [ ] M6: End-to-end test against an in-process stub MCP server: complete the handshake and
  round-trip a generic `ping`, asserting the response. Tests fail before, pass after.
- [ ] Run `nix fmt` and `nix flake check`; update Surprises, Decision Log, Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the MCP core as a **new package `baikai-mcp`** rather than adding modules to
  the core `baikai` library.
  Rationale: baikai is deliberately multi-package. The core `baikai` library does *not* take
  a direct `http-client` dependency in its `library` stanza (only the `baikai-fetch-models`
  executable and provider packages do — see `baikai/baikai.cabal` and
  `baikai-claude/baikai-claude.cabal`). Putting a raw HTTP/SSE transport in the core library
  would pull `http-client`/`http-client-tls`/`http-types` into every consumer that only wants
  the provider abstraction. A separate `baikai-mcp` package mirrors the established pattern
  (`baikai-claude`, `baikai-openai`, `baikai-effectful` are all separate packages that depend
  on `baikai`) and keeps the core lean. The shared integration contract is the *module
  namespace* `Baikai.Mcp.*`, which is identical regardless of which package owns it, so
  siblings C2–C6 are unaffected.
  Date: 2026-06-27

- Decision: Use `http-client` + `http-client-tls` directly (with a `streamly` SSE reader) as
  the transport library, not `servant-client`, `req`, or `wreq`.
  Rationale: `http-client` is already a transitive and direct dependency throughout baikai
  (`baikai-claude`, `baikai-openai`, the fetch executable). The provider packages use the
  `claude`/`openai` SDKs (which wrap `servant-client`) for their *own* endpoints, but MCP is a
  different protocol with arbitrary JSON-RPC bodies and streamed SSE responses — there is no
  generated servant API to reuse. `http-client` gives direct control over POST bodies,
  request headers (`Accept`, `Mcp-Session-Id`), and incremental body reads (`brRead`), which is
  exactly what Streamable HTTP and SSE need. SSE chunk parsing reuses `streamly`
  (`Streamly.Data.Stream`), the same library baikai already uses for its event protocol in
  `baikai/src/Baikai/Stream.hs`.
  Date: 2026-06-27

- Decision: Model the JSON-RPC `id` as a dedicated `RequestId` type wrapping `Data.Aeson.Value`
  restricted to a number or a string, and correlate responses with a monotonic `IORef Int`
  counter inside `McpConnection`.
  Rationale: JSON-RPC permits a request id to be a string or a number; MCP servers commonly
  echo whatever the client sent. A monotonic integer is the simplest correct generator and
  makes correlation trivial (the next `request` increments and waits for the matching id). The
  `RequestId` wrapper keeps the type honest while still parsing server-chosen string ids.
  Date: 2026-06-27

- Decision: Keep the public client API in plain `IO` (generalised over `MonadIO m` where the
  signature naturally allows it), not the `effectful` effect.
  Rationale: The core `baikai` providers are `IO`-based; the `effectful` binding lives in the
  separate `baikai-effectful` package as a *thin wrapper over IO transport*. Following that
  layering, `baikai-mcp` exposes `IO` and a future effectful binding can wrap it without this
  plan taking an `effectful` dependency.
  Date: 2026-06-27

- Decision: Auth in this plan is a **placeholder** `McpAuth` sum (`McpAuthNone`,
  `McpAuthBearer Text`) that only sets/omits an `Authorization: Bearer` header.
  Rationale: Real auth (OAuth discovery, token refresh, the full MCP authorization flow) is
  child plan C3 (`docs/plans/32-mcp-auth.md`). C3 will extend `McpAuth` and the header logic;
  this plan must not pre-empt that design, only leave a seam.
  Date: 2026-06-27

- Decision: Pin the MCP protocol version string the client advertises to `"2025-06-18"`,
  exported as `supportedProtocolVersion`.
  Rationale: The handshake requires the client to send a `protocolVersion`. Hard-coding a
  single supported version (a named constant) keeps the foundation simple; version negotiation
  beyond "send ours, accept whatever the server echoes" is out of scope and can be revisited
  if a target server rejects it (record any such finding under Surprises).
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

You are working in the **baikai** repository, a multi-package Haskell project that provides a
unified interface to several AI providers. Read `README.md` at the repo root for the overall
shape. The relevant facts for this plan:

- **Build system.** The repo ships a Nix flake (`flake.nix`) that pins **GHC 9.12.4** and
  provides the dev shell. The language is `GHC2024` with default extensions `DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (declared per-package in a
  `common-options` stanza inside each `.cabal` file). You build and test with `cabal` inside
  `nix develop`. Formatting is `nix fmt` (fourmolu + cabal-fmt + nixpkgs-fmt). There is **no
  `Justfile`**; commands are plain `cabal` invocations.

- **Packages and `cabal.project`.** The root `cabal.project` lists the packages:

  ```text
  packages:
    baikai
    baikai-claude
    baikai-openai
    baikai-smoke
    baikai-trace-otel
    baikai-effectful
    baikai-kit
  ```

  You will add a new line, `baikai-mcp`, to this list.

- **The core library `baikai`** (`baikai/baikai.cabal`, sources under `baikai/src/Baikai/`)
  defines the provider-neutral types. Two of its modules matter here:

  - `baikai/src/Baikai/Error.hs` — the **error taxonomy**. It exports `BaikaiError(..)` (a
    record with `category :: ErrorCategory`, `message :: Text`, `httpStatus :: Maybe Int`,
    `retryAfterSeconds :: Maybe Int`, `exitCode :: Maybe Int`) and `ErrorCategory(..)` with
    members `AuthError`, `RateLimited`, `ContextOverflow`, `InvalidRequest`, `TransientError`,
    `DecodeFailure`, `ProcessFailure`, `ProviderUnavailable`, `OtherError`. `BaikaiError` is an
    `Exception`, so it can be thrown and caught. Smart constructors exist:
    `providerError` (→ `OtherError`), `invalidRequest`, `decodeError`, `processError`,
    `rateLimited`, `authError`, `providerUnavailable`. There is **no** exported constructor for
    `TransientError`; since `BaikaiError(..)` exports the constructor, build a transient error
    directly with the record constructor, or via the pure classifier `classifyHttpStatus ::
    Int -> Maybe Int -> ErrorCategory` (which returns `TransientError` for 408/5xx) and
    `classifyHttpStatusWithBody :: Int -> Maybe Int -> Text -> ErrorCategory`. Reuse these
    classifiers so MCP HTTP errors map exactly like provider HTTP errors.

  - `baikai/src/Baikai/Stream.hs` — shows the project's **`streamly` usage**. It imports
    `Streamly.Data.Stream (Stream)` and `Streamly.Data.Stream qualified as Stream`, and uses
    `Stream.concatEffect`, `Stream.fromEffect`, `Stream.fromList`, `Stream.fold`. The MCP SSE
    reader will use the same `streamly` API surface to turn an incremental HTTP body into a
    stream of parsed SSE events. (You do not need to understand baikai's *event protocol* —
    `AssistantMessageEvent` — for this plan; only that `streamly`'s `Stream IO a` is the
    project's idiom for incremental data.)

  - `baikai/src/Baikai/Auth.hs` — exports `ApiKeySource` (`ApiKeyLiteral Text` / `ApiKeyEnv
    String`) and `resolveApiKey :: MonadIO m => ApiKeySource -> m Text`, which throws an
    `authError` when an env var is missing. The MCP auth placeholder may reuse `ApiKeySource`
    for the bearer token so C3 can build on the same credential-sourcing pattern.

- **How providers do HTTP today.** The `baikai-claude` and `baikai-openai` packages wrap the
  `claude` / `openai` Hackage SDKs (which use `servant-client`) for their endpoints; the HTTP
  `Manager` is created *inside those SDKs*. Their only direct `http-client` use is in
  `*/src/Baikai/Provider/*/ErrorClass.hs`, which reads `responseBody` off an `http-client`
  `Response` and calls `Network.HTTP.Types.Status (statusCode)`. So there is no existing
  baikai helper that creates a `Manager` for raw requests — `baikai-mcp` will create its own
  with `Network.HTTP.Client.TLS.newTlsManager` (from `http-client-tls`).

- **How tests run.** Each package has a `test-suite` of type `exitcode-stdio-1.0` using
  `tasty` + `tasty-hunit` (see `baikai/baikai.cabal`'s `baikai-test`). The live smoke suite
  `baikai-smoke` *skips* (never fails) when credentials are absent — see
  `baikai-smoke/test/Smoke.hs`, which prints `[baikai-smoke] no provider keys ...` and returns
  success when nothing is configured. `baikai-mcp`'s tests follow the `tasty`+`tasty-hunit`
  pattern and run a **local in-process stub server** so they require no network and never skip.

### Terms used in this plan

- **MCP (Model Context Protocol).** An open protocol for connecting an AI application to an
  external program that supplies tools, data ("resources"), and prompt templates. The AI app
  is the *client*; the external program is the *server*.
- **JSON-RPC 2.0.** A convention for remote calls encoded as JSON. A **request** is
  `{"jsonrpc":"2.0","id":<id>,"method":<name>,"params":<value>}`. A **response** echoes the
  `id` and carries either `"result":<value>` or `"error":{"code":<int>,"message":<str>,...}`.
  A **notification** is a request with no `id` and gets no response. The `id` correlates a
  response to the request that caused it.
- **Handshake / lifecycle.** Before any other call, the client sends an `initialize` request
  (announcing its `protocolVersion`, `capabilities`, and `clientInfo`); the server replies with
  its own `protocolVersion`, `capabilities`, and `serverInfo`; the client then sends a
  `notifications/initialized` notification to signal it is ready.
- **Capabilities.** Each side advertises which feature groups it supports (e.g. the server's
  `tools`, `resources`, `prompts`; the client's `roots`, `sampling`). For this plan they are
  mostly opaque JSON objects we parse and store; later plans read specific fields.
- **Transport.** The wire mechanism that moves JSON-RPC messages between client and server.
  - **Streamable HTTP** (current): the client `POST`s each JSON-RPC message to a single
    endpoint URL. The server replies either with one `application/json` body (a single
    response) or with a `text/event-stream` body (Server-Sent Events) when it wants to stream
    multiple messages. A `Mcp-Session-Id` response header, if present, must be echoed on
    subsequent requests.
  - **HTTP+SSE** (legacy): the client opens a long-lived `GET` to an SSE endpoint; the server
    first emits an `endpoint` event giving a URL to which the client `POST`s messages, and all
    responses arrive back on the open SSE stream.
- **SSE (Server-Sent Events).** A simple streaming format over HTTP: a sequence of text
  "events" separated by blank lines, each made of `field: value` lines; the `data:` field
  carries the payload (here, a JSON-RPC message). Multiple `data:` lines in one event are
  concatenated with newlines.


## Plan of Work

The work is six milestones, each independently buildable and (from M2 on) testable. New code
lives in a new package directory `baikai-mcp/` with sources under `baikai-mcp/src/Baikai/Mcp/`
and tests under `baikai-mcp/test/`.

### Milestone 1 — Package skeleton

Scope: create the `baikai-mcp` package so the rest of the work has a home that compiles.
At the end, `cabal build baikai-mcp` succeeds and the package is part of the project.

Create `baikai-mcp/baikai-mcp.cabal` modeled on `baikai-effectful/baikai-effectful.cabal`
(same `common-options` block, `default-language: GHC2024`, same default extensions). Its
`library` stanza depends on `baikai`, `base`, `aeson`, `bytestring`, `text`, `containers`,
`http-client`, `http-client-tls`, `http-types`, `case-insensitive` (for header names),
`streamly`, `streamly-core`, `stm` (or just `base`'s `IORef` — prefer `Data.IORef` to avoid a
dep), and `unliftio-core` only if needed. Exposed modules: `Baikai.Mcp`,
`Baikai.Mcp.Protocol`, `Baikai.Mcp.Transport`, `Baikai.Mcp.Client`.

Add a `test-suite baikai-mcp-test` of type `exitcode-stdio-1.0`, `hs-source-dirs: test`,
`main-is: Main.hs`, with `tasty`, `tasty-hunit`, plus `warp` and `wai` (and `http-types`,
`bytestring`, `aeson`) for the in-process stub server used from M6. Mark it `-threaded
-with-rtsopts=-N` (Warp needs the threaded runtime).

Create the umbrella module `baikai-mcp/src/Baikai/Mcp.hs` that re-exports the public surface
(`module Baikai.Mcp.Client`, `module Baikai.Mcp.Protocol`, the transport's public types).
Create stub modules for `Baikai.Mcp.Protocol`, `Baikai.Mcp.Transport`, `Baikai.Mcp.Client`
with empty-but-valid contents so the package builds.

Add `baikai-mcp` to the `packages:` list in the root `cabal.project`.

Acceptance: `cabal build baikai-mcp` compiles with no errors or warnings (the project uses
`-Wall` and friends, so keep export lists complete — `-Wmissing-export-lists` is on).

### Milestone 2 — `Baikai.Mcp.Protocol`: JSON-RPC + handshake types

Scope: the pure data layer. At the end, JSON-RPC and `initialize` values encode/decode to the
exact wire shapes, proven by unit tests; no networking yet.

In `baikai-mcp/src/Baikai/Mcp/Protocol.hs` define:

- `newtype RequestId = RequestId Value` with `ToJSON`/`FromJSON` that pass the inner number or
  string through unchanged, plus a smart constructor `intId :: Int -> RequestId`.
- `data JsonRpcRequest = JsonRpcRequest { reqId :: RequestId, method :: Text, params :: Maybe Value }`.
  Its `ToJSON` writes `{"jsonrpc":"2.0","id":...,"method":...,"params":...}` (omitting `params`
  when `Nothing`). Use an explicit `toJSON`/`object` rather than generic deriving so the
  constant `"jsonrpc":"2.0"` and the field name `id` (a Haskell keyword-ish clash with record
  `reqId`) are exact.
- `data JsonRpcNotification = JsonRpcNotification { method :: Text, params :: Maybe Value }`
  with `ToJSON` writing `{"jsonrpc":"2.0","method":...,"params":...}` and **no** `id`.
- `data JsonRpcError = JsonRpcError { code :: Int, message :: Text, errorData :: Maybe Value }`
  with `FromJSON`/`ToJSON` mapping `errorData` ⇄ the wire field `data`.
- `data JsonRpcResponse = JsonRpcResponse { respId :: RequestId, outcome :: Either JsonRpcError Value }`
  with `FromJSON` that reads `result` into `Right` or `error` into `Left`.
- A discriminator for incoming messages: `data IncomingMessage = IncomingResponse JsonRpcResponse | IncomingNotification JsonRpcNotification` with a `FromJSON` that branches on the presence of `id` (response) vs. absence (server-initiated notification). This is needed because the legacy SSE transport interleaves both.

For the MCP handshake, define:

- `supportedProtocolVersion :: Text` = `"2025-06-18"`.
- `data Implementation = Implementation { name :: Text, version :: Text }` (used for both
  `clientInfo` and `serverInfo`).
- `data ClientCapabilities = ClientCapabilities { ... }` — for the foundation keep this minimal
  and JSON-shaped: an empty object is a valid value, so model it as
  `ClientCapabilities { roots :: Maybe Value, sampling :: Maybe Value, experimental :: Maybe Value }`
  all defaulting to `Nothing` and omitted when absent. Provide `defaultClientCapabilities`.
- `data ServerCapabilities = ServerCapabilities { tools :: Maybe Value, resources :: Maybe Value, prompts :: Maybe Value, logging :: Maybe Value, experimental :: Maybe Value }` parsed leniently (any unknown keys ignored). Later plans (C2/C4) read specific fields; here they stay opaque `Value`s.
- `data InitializeParams = InitializeParams { protocolVersion :: Text, capabilities :: ClientCapabilities, clientInfo :: Implementation }` with `ToJSON`.
- `data InitializeResult = InitializeResult { protocolVersion :: Text, capabilities :: ServerCapabilities, serverInfo :: Implementation, instructions :: Maybe Text }` with `FromJSON`.
- Constants for method names: `methodInitialize = "initialize"`,
  `methodInitialized = "notifications/initialized"`, `methodPing = "ping"`.

Tests (`baikai-mcp/test/ProtocolSpec.hs`): assert `encode (JsonRpcRequest (intId 1) "ping"
Nothing)` equals the expected JSON object (compare decoded `Value`s, not raw bytes, to avoid
key-order fragility); assert an `InitializeResult` parses from a representative server reply;
assert `IncomingMessage` correctly classifies a response vs. a notification; assert
`RequestId` round-trips both an integer and a string id.

Acceptance: `cabal test baikai-mcp` runs `ProtocolSpec` green.

### Milestone 3 — `Baikai.Mcp.Transport`: HTTP carriage

Scope: move raw JSON-RPC bytes over HTTP. At the end, the transport can POST a request body
and return the server's reply, handling both the single-JSON and the SSE-stream response
forms, plus the legacy GET-SSE form. Exercised by M6's stub; M3 itself adds a focused SSE
parser test.

In `baikai-mcp/src/Baikai/Mcp/Transport.hs`:

- `data Transport = StreamableHttp | Sse` (the two MCP transports; default `StreamableHttp`).
- An internal `data TransportConn` holding the `http-client` `Manager`, the parsed base
  `Request` (target URL), the negotiated POST endpoint (for legacy SSE), and a mutable
  `IORef (Maybe ByteString)` for the `Mcp-Session-Id` to echo.
- `openTransport :: Transport -> Manager -> Text {- url -} -> [Header] {- auth headers -} -> IO TransportConn`.
  For `StreamableHttp` this just parses the URL into a base `Request` (`parseRequest`); for
  `Sse` it additionally opens the GET SSE stream and reads the first `endpoint` event to learn
  the POST URL (record it in `TransportConn`).
- `sendMessage :: TransportConn -> ByteString {- encoded JSON-RPC -} -> IO (Maybe IncomingMessage)`
  for fire-and-correlate request sending. Implementation:
  - Build a POST to the endpoint with body = the bytes, headers `Content-Type: application/json`,
    `Accept: application/json, text/event-stream`, the auth headers, and `Mcp-Session-Id` if
    set. Use `Network.HTTP.Client.withResponse` so the body can be read incrementally.
  - On a non-2xx status, throw the mapped `BaikaiError` (see M5).
  - Capture any `Mcp-Session-Id` response header into the `IORef`.
  - Branch on the response `Content-Type`: `application/json` → read the whole body, decode one
    `IncomingMessage`, return `Just`; `text/event-stream` → parse SSE events (below) and return
    the **first** `IncomingResponse` whose payload is a response (skipping server notifications,
    which the foundation does not yet route — note this limitation in Surprises if a target
    server depends on them); `202 Accepted` with empty body (the server's ack for a
    notification) → return `Nothing`.
- `notifyMessage :: TransportConn -> ByteString -> IO ()` — POST a notification body and ignore
  the (empty/202) reply.
- An SSE parser built on `streamly`: `sseEvents :: BodyReader -> Stream IO SseEvent`, turning
  the incremental `http-client` `BodyReader` (an `IO ByteString` that yields chunks until
  empty) into a `Stream IO ByteString` (via `Stream.unfoldrM` over `brRead`), accumulating
  bytes, splitting on blank-line boundaries, and parsing each block's `data:` lines into one
  `SseEvent { eventName :: Maybe Text, eventData :: ByteString }`. Mirror the `streamly` import
  style of `baikai/src/Baikai/Stream.hs`.
- `closeTransport :: TransportConn -> IO ()` — for legacy SSE, signal the GET stream to stop
  (close the response); for Streamable HTTP this is a no-op beyond letting the `Manager` be
  collected.

Add a self-contained unit test `baikai-mcp/test/SseSpec.hs` feeding a hand-written
`text/event-stream` byte string (e.g. two events, one multi-line `data:`) into the SSE parser
and asserting the decoded events. This proves the parser without any network.

Acceptance: `cabal build baikai-mcp` clean; `cabal test baikai-mcp` runs `SseSpec` green.

### Milestone 4 — `Baikai.Mcp.Client`: handle, handshake, generic calls

Scope: the user-facing API. At the end, a caller can `connectMcp` (which opens the transport
and runs the full `initialize` → `initialized` handshake), send generic `request`/`notify`
calls, and `closeMcp`.

In `baikai-mcp/src/Baikai/Mcp/Client.hs`:

- `data McpAuth = McpAuthNone | McpAuthBearer ApiKeySource` (the placeholder; `ApiKeySource`
  from `Baikai.Auth` so a literal or env-var token both work, and C3 can extend this sum).
- `data McpServerConfig = McpServerConfig { name :: Text, url :: Text, transport :: Transport, auth :: McpAuth }`.
- `data McpConnection = McpConnection { conn :: TransportConn, config :: McpServerConfig, nextId :: IORef Int, serverInfo :: Implementation, serverCapabilities :: ServerCapabilities, serverProtocolVersion :: Text }` — opaque (export the type, not its fields; provide accessor functions `mcpServerInfo`, `mcpServerCapabilities`).
- `connectMcp :: MonadIO m => McpServerConfig -> m McpConnection`:
  1. Create a TLS `Manager` (`newTlsManager`).
  2. Resolve auth headers: `McpAuthNone` → `[]`; `McpAuthBearer src` → `resolveApiKey src`
     then `[("Authorization", "Bearer " <> token)]`.
  3. `openTransport (transport config) mgr (url config) authHeaders`.
  4. Build the `initialize` `JsonRpcRequest` (`intId 0`, `methodInitialize`,
     `InitializeParams supportedProtocolVersion defaultClientCapabilities clientInfo`, where
     `clientInfo = Implementation "baikai-mcp" <version>`), send it, decode the
     `InitializeResult` from the response's `result`. Throw a `decodeError` if the result is
     missing or malformed; throw the mapped JSON-RPC error if the server returned one.
  5. Send the `notifications/initialized` notification.
  6. Initialise `nextId` to `1` and return the assembled `McpConnection`.
- `request :: MonadIO m => McpConnection -> Text {- method -} -> Maybe Value {- params -} -> m Value`:
  atomically read-and-increment `nextId`, build a `JsonRpcRequest`, `sendMessage`, and on an
  `IncomingResponse` either return the `Right result` `Value` or throw the mapped error from
  `Left JsonRpcError`. (M6 uses `methodPing` with `Nothing` params for the round-trip.)
- `notify :: MonadIO m => McpConnection -> Text -> Maybe Value -> m ()`: build a
  `JsonRpcNotification` and `notifyMessage`.
- `closeMcp :: MonadIO m => McpConnection -> m ()`: `closeTransport`.

Re-export `McpServerConfig`, `McpConnection`, `McpAuth`, `connectMcp`, `closeMcp`, `request`,
`notify`, the accessors, and `Transport(..)` from `Baikai.Mcp`.

Acceptance: `cabal build baikai-mcp` clean. (Behavioral acceptance lands in M6.)

### Milestone 5 — Error mapping into `Baikai.Error`

Scope: every failure surfaces as a `BaikaiError` with the right category, so callers (and
later plans) can apply uniform retry/abort policy.

Add a small internal module or section mapping:

- A non-2xx HTTP status → `classifyHttpStatusWithBody status retryAfter bodyText` for the
  category, building a `BaikaiError` with `httpStatus = Just status` and, for 429, the parsed
  `Retry-After` seconds (reuse `rateLimited`). Read the body text for the `message`.
- An `http-client` `HttpException` (connection refused, timeout, TLS) → a `BaikaiError` in
  `TransientError` (network failures are retryable) with the displayed exception as `message`.
- A JSON-RPC `error` object → `BaikaiError`. Map by JSON-RPC code where meaningful: the
  standard `-32600`/`-32602`/`-32601` (invalid request / invalid params / method not found) →
  `InvalidRequest`; `-32700` (parse error) → `DecodeFailure`; anything else → `OtherError`
  (`providerError`). Put the JSON-RPC `code` and `message` into the `BaikaiError.message`.
- A response body that fails to decode into the expected shape → `decodeError`.

All of these are thrown as exceptions (`BaikaiError` is an `Exception`), matching how the rest
of baikai signals failures.

Acceptance: a unit test (`baikai-mcp/test/ErrorMapSpec.hs`) asserts the pure mappings (status
→ category, JSON-RPC code → category) without networking.

### Milestone 6 — End-to-end against a stub MCP server

Scope: prove the whole stack with observable behavior — no network, no credentials, fully
in-process.

In `baikai-mcp/test/StubServer.hs`, implement a tiny WAI application served by Warp on an
ephemeral localhost port that speaks just enough MCP for the foundation:

- On `POST /` with an `initialize` request, reply `200 application/json` with a JSON-RPC
  response echoing the `id` and a `result` of `{"protocolVersion":"2025-06-18","capabilities":
  {"tools":{}},"serverInfo":{"name":"stub","version":"0.0.1"}}`, and set a
  `Mcp-Session-Id: test-session` header.
- On `POST /` with a `notifications/initialized` notification, reply `202` empty.
- On `POST /` with a `ping` request, reply `200 application/json` with `result: {}` echoing
  the id (and assert the request carried `Mcp-Session-Id: test-session`).
- Provide a *second* variant (or a query flag) that answers `ping` with a `text/event-stream`
  body carrying the same response as one SSE `data:` event, so the SSE response path is
  exercised too.

In `baikai-mcp/test/ClientSpec.hs`:

- Start the stub on an ephemeral port (Warp's `withApplication` or `testWithApplication` gives
  you the port), then `connectMcp (McpServerConfig "stub" ("http://127.0.0.1:" <> port)
  StreamableHttp McpAuthNone)`.
- Assert `mcpServerInfo conn == Implementation "stub" "0.0.1"` and that
  `mcpServerCapabilities conn` reports a `tools` object.
- Call `request conn methodPing Nothing` and assert it returns the empty-object `Value`.
- Repeat against the SSE-response stub variant and assert the same `ping` result, proving the
  SSE path.
- Assert that a `ping` to a stub that replies with a JSON-RPC `error` throws a `BaikaiError`
  whose `category` is `InvalidRequest` (or as mapped).
- `closeMcp conn`.

Acceptance: `cabal test baikai-mcp` passes all of `ProtocolSpec`, `SseSpec`, `ErrorMapSpec`,
and `ClientSpec`. To demonstrate the change is effective beyond compilation, the
`ClientSpec` handshake+ping assertions must *fail* if you stub out `connectMcp` to skip the
handshake (try it transiently to confirm the test is real), then pass with the real
implementation.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai` inside the
dev shell. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
```

Milestone 1 — scaffold and confirm the package is wired in:

```bash
# After creating baikai-mcp/baikai-mcp.cabal, baikai-mcp/src/Baikai/Mcp*.hs,
# baikai-mcp/test/Main.hs, and adding `baikai-mcp` to cabal.project:
cabal build baikai-mcp
```

Expected (abridged):

```text
Resolving dependencies...
Build profile: -w ghc-9.12.4 -O1
...
[1 of 4] Compiling Baikai.Mcp.Protocol
...
Linking ... baikai-mcp ...
```

Milestones 2–6 — build and test as you go:

```bash
cabal build baikai-mcp
cabal test baikai-mcp
```

Expected on success (tasty summary; exact counts grow as specs are added):

```text
baikai-mcp-test
  ProtocolSpec
    json-rpc request encodes with jsonrpc 2.0 and id: OK
    initialize result decodes:                          OK
    incoming message classifies response vs notify:     OK
    request id round-trips number and string:           OK
  SseSpec
    parses two events including multi-line data:        OK
  ErrorMapSpec
    http status maps to category:                       OK
    json-rpc code maps to category:                     OK
  ClientSpec
    handshake reports server info and capabilities:     OK
    generic ping round-trips (json response):           OK
    generic ping round-trips (sse response):            OK
    json-rpc error surfaces as BaikaiError:             OK

All N tests passed
```

Format and check before committing:

```bash
nix fmt
nix flake check
```

Run a single spec while iterating (tasty's pattern filter):

```bash
cabal test baikai-mcp --test-options='-p "/generic ping/"'
```


## Validation and Acceptance

The plan is accepted when, from the repo root inside `nix develop`:

1. `cabal build baikai-mcp` compiles cleanly with the project's `-Wall`-plus warning set and
   no missing-export-list warnings.
2. `cabal test baikai-mcp` passes every spec, including `ClientSpec`, which is the
   behavioral proof: against an in-process stub MCP server it (a) completes the `initialize`
   handshake and exposes the server's reported `Implementation "stub" "0.0.1"` and its
   capabilities, (b) round-trips a generic JSON-RPC `ping` over the Streamable HTTP transport
   and asserts the exact `result` value, (c) repeats the round-trip over an SSE-formatted
   response and asserts the same result, and (d) surfaces a server `error` as a typed
   `BaikaiError` with the mapped category.
3. The same generic `request` used for `ping` is what sibling plan C2
   (`docs/plans/31-mcp-tool-discovery-and-invocation.md`) will call with method
   `"tools/list"` / `"tools/call"`; nothing in C2's surface is implemented here.

A reviewer can re-derive every step from this document alone: create the package, add the
modules with the listed types and signatures, add the stub server and specs, and run the two
`cabal` commands above.

Optional live check (not required for acceptance, and skipped when unavailable): point
`connectMcp` at a reference MCP server reachable over HTTP and confirm the handshake prints
the server's name/version. Because real servers may require auth (C3) or a specific protocol
version, treat any failure here as a *finding* to record under Surprises, not a regression of
the stub-backed acceptance.


## Idempotence and Recovery

All steps are additive and safe to re-run. Editing the new `.cabal` file, the new modules, or
`cabal.project` and re-running `cabal build` / `cabal test` simply rebuilds; there is no
migration or destructive operation. `connectMcp` allocates a fresh `Manager` and connection
each call and performs the handshake every time, so calling it repeatedly yields independent
connections; always pair it with `closeMcp`. If a build half-fails (e.g. a missing dependency
in the `.cabal` file), add the dependency and rebuild — nothing is left in a bad state. If the
stub-server port clashes in CI, use Warp's ephemeral-port helper (`testWithApplication` /
`withApplication`) which binds port 0 and reports the chosen port, avoiding fixed-port flakes.
The one place to watch is the `Mcp-Session-Id` `IORef`: it is per-`McpConnection`, so reusing a
connection across tests is fine, but do not share a single `McpConnection` between threads
without external synchronization in this foundation (note it; concurrency hardening, if
needed, is future work).


## Interfaces and Dependencies

New package: **`baikai-mcp`** (directory `baikai-mcp/`), depending on `baikai`,
`http-client`, `http-client-tls`, `http-types`, `case-insensitive`, `aeson`, `bytestring`,
`text`, `containers`, `streamly`, `streamly-core`, and `base`. Test-only deps add `tasty`,
`tasty-hunit`, `warp`, `wai`. It must be added to the root `cabal.project` `packages:` list.

Modules and the signatures that must exist at the end of each milestone (full module paths):

`baikai-mcp/src/Baikai/Mcp/Protocol.hs`:

```haskell
module Baikai.Mcp.Protocol
  ( RequestId, intId
  , JsonRpcRequest (..)
  , JsonRpcNotification (..)
  , JsonRpcError (..)
  , JsonRpcResponse (..)
  , IncomingMessage (..)
  , Implementation (..)
  , ClientCapabilities (..), defaultClientCapabilities
  , ServerCapabilities (..)
  , InitializeParams (..)
  , InitializeResult (..)
  , supportedProtocolVersion
  , methodInitialize, methodInitialized, methodPing
  ) where

supportedProtocolVersion :: Data.Text.Text         -- "2025-06-18"
intId :: Int -> RequestId
```

`baikai-mcp/src/Baikai/Mcp/Transport.hs`:

```haskell
module Baikai.Mcp.Transport
  ( Transport (..)
  , TransportConn
  , openTransport
  , sendMessage
  , notifyMessage
  , closeTransport
  , SseEvent (..)
  , sseEvents
  ) where

import Network.HTTP.Client (Manager, BodyReader)
import Network.HTTP.Types.Header (Header)
import Streamly.Data.Stream (Stream)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Baikai.Mcp.Protocol (IncomingMessage)

data Transport = StreamableHttp | Sse

openTransport  :: Transport -> Manager -> Text -> [Header] -> IO TransportConn
sendMessage    :: TransportConn -> ByteString -> IO (Maybe IncomingMessage)
notifyMessage  :: TransportConn -> ByteString -> IO ()
closeTransport :: TransportConn -> IO ()
sseEvents      :: BodyReader -> Stream IO SseEvent
```

`baikai-mcp/src/Baikai/Mcp/Client.hs`:

```haskell
module Baikai.Mcp.Client
  ( McpAuth (..)
  , McpServerConfig (..)
  , McpConnection
  , mcpServerInfo
  , mcpServerCapabilities
  , connectMcp
  , closeMcp
  , request
  , notify
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (Value)
import Data.Text (Text)
import Baikai.Auth (ApiKeySource)
import Baikai.Mcp.Protocol (Implementation, ServerCapabilities)
import Baikai.Mcp.Transport (Transport)

data McpAuth = McpAuthNone | McpAuthBearer ApiKeySource

data McpServerConfig = McpServerConfig
  { name      :: Text
  , url       :: Text
  , transport :: Transport
  , auth      :: McpAuth
  }

connectMcp :: MonadIO m => McpServerConfig -> m McpConnection
closeMcp   :: MonadIO m => McpConnection -> m ()
request    :: MonadIO m => McpConnection -> Text -> Maybe Value -> m Value
notify     :: MonadIO m => McpConnection -> Text -> Maybe Value -> m ()

mcpServerInfo         :: McpConnection -> Implementation
mcpServerCapabilities :: McpConnection -> ServerCapabilities
```

`baikai-mcp/src/Baikai/Mcp.hs` re-exports the public surface above (the umbrella module other
baikai code and the cross-repo consumers import).

Dependencies from the existing tree this plan relies on, by full path:

- `baikai/src/Baikai/Error.hs` — `BaikaiError(..)`, `ErrorCategory(..)`, `decodeError`,
  `invalidRequest`, `providerError`, `rateLimited`, `authError`, `classifyHttpStatus`,
  `classifyHttpStatusWithBody`. All error mapping in M5 routes through these.
- `baikai/src/Baikai/Auth.hs` — `ApiKeySource(..)`, `resolveApiKey`. Used by the `McpAuth`
  placeholder.
- `baikai/src/Baikai/Stream.hs` — reference for the project's `streamly` (`Streamly.Data.Stream`)
  idiom reused by the SSE reader.

Consumers / dependents of this plan (do **not** implement them here):

- **C2** `docs/plans/31-mcp-tool-discovery-and-invocation.md` — adds `listTools` / `callTool`
  / `McpTool`, calling `request` with `"tools/list"` and `"tools/call"`.
- **C3** `docs/plans/32-mcp-auth.md` — replaces the `McpAuth` placeholder with the real MCP
  authorization flow.
- **C4** — resources and prompts, also via `request`.
- Cross-repo **C5** (`shinzui/shikumi` adapter) and **C6** (`shinzui/shikigami` declaration)
  consume the `Baikai.Mcp.*` surface (`McpServerConfig`, `McpConnection`, `connectMcp`).
