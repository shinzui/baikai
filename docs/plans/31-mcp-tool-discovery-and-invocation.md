---
id: 31
slug: mcp-tool-discovery-and-invocation
title: "MCP tool discovery and invocation"
kind: exec-plan
created_at: 2026-06-27T17:57:46Z
intention: "intention_01kw53net1etwansn72shv92s9"
master_plan: "docs/masterplans/6-mcp-support-across-the-agent-stack.md"
---

# MCP tool discovery and invocation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a baikai program that already holds an open connection to a
**Model Context Protocol (MCP) server** can ask that server which tools it offers,
turn each one into a tool the local language model can be told about, let the model
choose to call one, run that call against the server, and feed the result back into
the conversation. Concretely, a developer will be able to write:

```haskell
conn  <- connectMcp serverConfig            -- from the sibling C1 plan (see below)
tools <- listTools conn                      -- this plan: discover the server's tools
let offered = map toBaikaiTool tools         -- this plan: convert to baikai's wire Tool
-- ... hand `offered` to a model via Baikai.Context; the model picks one ...
result <- callTool conn (McpToolCall "search" args)   -- this plan: invoke it
-- ... `result` becomes a Baikai.Message.ToolResult appended to the next turn ...
```

"MCP" is an open JSON-RPC protocol (a request/response convention where each message
is a small JSON object with a method name and parameters) that lets a host program
talk to external "servers" which expose **tools** (callable functions), **resources**
(readable documents), and **prompts** (reusable prompt templates). This plan covers
only the **tools** half: *discovery* (listing what a server can do) and *invocation*
(running one tool and collecting its output). The value to a user is that any
MCP-compatible server — a filesystem server, a GitHub server, a database server —
becomes a set of tools their model can use, without baikai hand-coding each one.

The observable end state: against a small stub MCP server that advertises its tools
across two pages, `listTools` returns every tool from both pages in order; `callTool`
on a known tool returns that tool's output content; and `callTool` on a tool that
reports failure returns a result whose `isError` flag is `True` (rather than throwing).
All of this is proven by an automated test suite that fails before the work and passes
after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `McpTool` type with JSON decoding and the `toBaikaiTool` mapping helper exist and round-trip in tests.
- [ ] M2: `listTools` calls `tools/list`, follows `cursor` pagination to completion with a cycle guard, and aggregates across pages.
- [ ] M3: `callTool` / `McpToolCall` / `McpToolResult` exist; `tools/call` is invoked; content blocks and `isError` are mapped; transport/protocol errors map into the `BaikaiError` taxonomy; `outputSchema` is validated when present.
- [ ] M4: `tools/list_changed` notification hook lets a long-lived connection refresh its tool list.
- [ ] Module `Baikai.Mcp.Tool` is added to the MCP package's `exposed-modules`, the project builds, and `cabal test` passes including the new `McpToolSpec`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Map `McpTool` onto baikai's existing `Baikai.Tool.Tool` rather than inventing a
  new wire tool type. `inputSchema` (an MCP JSON Schema object) becomes `Tool.parameters`
  verbatim, `name` maps straight across, and a missing MCP `description` collapses to the
  empty `Text` that `_Tool` already uses.
  Rationale: `Tool.parameters` is already an untyped `Data.Aeson.Value` carrying raw JSON
  Schema that providers forward unchanged (see the module header of `baikai/src/Baikai/Tool.hs`).
  MCP tool input schemas are also raw JSON Schema, so the mapping is lossless and needs no
  schema translation layer. Keeping one `Tool` type means MCP tools flow through the existing
  `Baikai.Context` / provider machinery with zero new plumbing.
  Date: 2026-06-27

- Decision: `listTools` follows pagination by looping on the response's `nextCursor`, passing
  it back as the `cursor` request parameter, and stops when `nextCursor` is absent. Guard
  against a misbehaving server with both a *seen-cursor set* (stop and raise a `DecodeFailure`
  `BaikaiError` if a cursor repeats) and a hard iteration cap (default 10000 pages).
  Rationale: MCP cursors are opaque and a buggy or hostile server could return the same cursor
  forever, hanging the client. A cycle guard plus a cap bounds the work and turns the failure
  into an explainable error rather than an infinite loop.
  Date: 2026-06-27

- Decision: Represent `tools/call` output as `McpToolResult { content :: Vector McpContentBlock,
  isError :: Bool, structuredContent :: Maybe Value }`, preserving MCP content fidelity, and
  provide `toToolResult :: McpToolResult -> Baikai.Message.ToolResult` that lowers it into
  baikai's existing tool-result content blocks (text and image), preserving the `isError` flag.
  Rationale: MCP content blocks (text, image, audio, embedded resource) are a superset of
  baikai's `Baikai.Content.ToolResultContent` (text, image). Keeping a faithful `McpContentBlock`
  in `McpToolResult` and lowering at the boundary means no information is silently dropped at
  parse time, and the consumer (C5) decides how to render unsupported block kinds.
  Date: 2026-06-27

- Decision: A tool-level failure (the JSON-RPC call *succeeds* but the result carries
  `isError: true`) is returned as a normal `McpToolResult` with `isError = True`; only
  transport, protocol, or decode failures (the JSON-RPC call itself errors, or the response
  shape is wrong) throw a `Baikai.Error.BaikaiError`. `tools/call` JSON-RPC error responses map
  via the error code: method-not-found / invalid-params → `invalidRequest`, anything else →
  `providerError`; a malformed result → `decodeError`.
  Rationale: This mirrors baikai's own tool round-trip, where `Baikai.Message.ToolResult` carries
  an `isError` flag for recoverable tool failure that the model is meant to see, distinct from
  exceptions for infrastructure failure. The MCP spec deliberately separates "the tool ran and
  failed" (`isError` in the result) from "the request was rejected" (a JSON-RPC error), and we
  honor that split.
  Date: 2026-06-27

- Decision: Tools keep their **native** server-side names here (e.g. `search`); this plan does
  **not** apply the `mcp__<server>__<tool>` surfacing convention. The connection exposes the
  server's name (via the C1 `McpConnection`) so the downstream consumer can build the prefix.
  Rationale: The prefixing is a presentation concern owned by the shikumi adapter (C5,
  `shinzui/shikumi:docs/plans/30-...`), which must guarantee global uniqueness across multiple
  servers. Prefixing here would force every caller to strip it back off before calling
  `tools/call`, since the wire protocol expects native names. C5 is the primary consumer of this
  module and the right place to namespace.
  Date: 2026-06-27

- Decision: `outputSchema` validation, when an `McpTool` declares one and a result carries
  `structuredContent`, is performed with a minimal structural JSON Schema check (type, required
  keys) rather than pulling in a full JSON Schema library. A validation failure throws a
  `DecodeFailure` `BaikaiError`.
  Rationale: A full JSON Schema validator is a heavy dependency for a feature most servers do not
  yet use. A minimal check catches the common contract violations and can be upgraded later
  without changing the public signatures. (Revisit if a validator dependency is already pulled in
  by C1.)
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan adds to **baikai**, a multi-package Haskell project that gives one
provider-neutral interface over several AI providers. The repository root is the
baikai checkout; the core library package lives under `baikai/` (note the doubled
path: `baikai/baikai/src/...`), declared by `baikai/baikai.cabal`. The toolchain is
GHC 9.12.4 with `default-language: GHC2024` and the project-wide default extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`
(see the `common-options` stanza in `baikai/baikai.cabal` and the "Develop" section of
`README.md`). A Nix flake pins everything; you enter the dev shell with `nix develop`.

The types this plan maps onto already exist and you must read them before editing:

- `baikai/baikai/src/Baikai/Tool.hs` — the wire tool record
  `Tool { name :: !Text, description :: !Text, parameters :: !Value }` plus the empty
  base `_Tool`. `parameters` holds raw JSON Schema as a `Data.Aeson.Value`; the module
  header states the provider encoders forward it unchanged. This is the target of the
  `McpTool -> Tool` mapping.
- `baikai/baikai/src/Baikai/Content.hs` — typed content blocks. Relevant here:
  `TextContent { text :: Text }`, `ImageContent { imageData :: ByteString, mimeType :: Text }`,
  and the per-role sum `ToolResultContent = ToolResultText !TextContent | ToolResultImage !ImageContent`.
  These are the lowering target for MCP content blocks.
- `baikai/baikai/src/Baikai/Message.hs` — `ToolResult { content :: !(Vector ToolResultContent),
  isError :: !Bool }` and its smart constructors `toolResultText`, `toolResultErrorText`,
  `toolResultImage`. An `McpToolResult` lowers into this `ToolResult` so it can be appended to a
  conversation via `Baikai.Context.appendToolResult`.
- `baikai/baikai/src/Baikai/Error.hs` — `BaikaiError { category :: ErrorCategory, message :: Text,
  ... }` with `ErrorCategory` members `AuthError`, `RateLimited`, `ContextOverflow`,
  `InvalidRequest`, `TransientError`, `DecodeFailure`, `ProcessFailure`, `ProviderUnavailable`,
  `OtherError`, and smart constructors `providerError`, `invalidRequest`, `decodeError`,
  `processError`, `rateLimited`, `authError`, `providerUnavailable`. `BaikaiError` is an
  `Exception`. This is the taxonomy MCP transport/protocol failures map into.

This plan **builds on the sibling C1 plan**,
`baikai/docs/plans/30-mcp-transport-and-json-rpc-client-core.md`, which is a hard
dependency. C1 delivers the connection and the generic JSON-RPC layer: a `McpConnection`
value, `connectMcp :: ... -> m McpConnection` to open one, and generic
`request :: McpConnection -> Text -> Value -> m Value` (send a method name + params,
get the JSON-RPC `result` back or throw a `BaikaiError`) and
`notify :: McpConnection -> Text -> Value -> m ()` (send a one-way notification). C1 also
decides where the MCP code lives — most likely a dedicated package `baikai-mcp` with the
module `Baikai.Mcp.Connection` exporting the above. **This plan adds the module
`Baikai.Mcp.Tool` to that same package** and adds it to the package's `exposed-modules`.
If C1 placed the connection in the core `baikai` library instead, add `Baikai.Mcp.Tool`
there; the only requirement is that `Baikai.Mcp.Tool` can import `Baikai.Mcp.Connection`,
`Baikai.Tool`, `Baikai.Content`, `Baikai.Message`, and `Baikai.Error`. Confirm the exact
package/component and the precise C1 signatures from plan 30 before writing imports; the
signatures named above are the contract this plan was written against, and if C1 settled on
slightly different shapes (for example `request` returning `Either BaikaiError Value`, or a
`MonadIO m` constraint), adapt the wrappers below to match and record the adjustment in the
Decision Log.

Three terms used throughout, defined here so nothing is assumed:

- **Discovery**: asking the server, via the `tools/list` JSON-RPC method, for the set of
  tools it offers. Each tool comes back as an object with a `name`, an optional
  `description`, an `inputSchema` (JSON Schema for its arguments), and optionally an
  `outputSchema`.
- **Invocation**: running one tool, via the `tools/call` JSON-RPC method, by sending its
  `name` and an `arguments` object. The response is a list of content blocks plus an
  `isError` boolean, and optionally a `structuredContent` value.
- **Pagination**: `tools/list` may return only part of the tool set plus an opaque
  `nextCursor` string. To get the rest you call `tools/list` again with `{ "cursor":
  <nextCursor> }`. You repeat until the response has no `nextCursor`. "Opaque" means the
  cursor's contents are meaningless to the client — you only ever echo it back.


## Plan of Work

All edits land in the new module `baikai/<mcp-package>/src/Baikai/Mcp/Tool.hs` (the
`<mcp-package>` directory is whatever C1 created; this plan assumes `baikai-mcp`) plus the
package's `.cabal` `exposed-modules` list, and a new test module
`baikai/<mcp-package>/test/McpToolSpec.hs` wired into that package's test `Main.hs`. The
work splits into four independently verifiable milestones, in dependency order. Build the
whole thing on top of C1's `Baikai.Mcp.Connection`.

### Milestone 1 — `McpTool` type and the baikai `Tool` mapping

Scope: define the data type that represents a discovered tool and the helper that turns it
into baikai's wire `Tool`. At the end of this milestone the type parses from a real MCP
`tools/list` tool object and converts to a `Baikai.Tool.Tool` whose `parameters` is the
untouched input schema. No network calls yet.

In `Baikai.Mcp.Tool`, define:

```haskell
data McpTool = McpTool
  { name :: !Text,
    description :: !(Maybe Text),
    inputSchema :: !Value,          -- raw JSON Schema object
    outputSchema :: !(Maybe Value)  -- raw JSON Schema object, when advertised
  }
  deriving stock (Eq, Show, Generic)
```

Give it a hand-written `FromJSON` (so the wire keys `name`, `description`, `inputSchema`,
`outputSchema` map exactly, with `description`/`outputSchema` optional) and a matching
`ToJSON` for test round-tripping. Then the mapping helper:

```haskell
toBaikaiTool :: McpTool -> Baikai.Tool.Tool
toBaikaiTool t =
  Baikai.Tool._Tool
    { Baikai.Tool.name = name t,
      Baikai.Tool.description = fromMaybe Text.empty (description t),
      Baikai.Tool.parameters = inputSchema t
    }
```

Commands: `cabal build <mcp-package>`. Acceptance: a unit test decodes a sample tool
object (name, description, an `inputSchema` with `type: object` and a `properties` map) and
asserts `toBaikaiTool` produces a `Tool` whose `parameters` equals the original schema
`Value` and whose `description` is the text (and the empty string when the MCP description
is absent).

### Milestone 2 — `listTools` with cursor pagination and a cycle guard

Scope: implement discovery end to end, including following `nextCursor` across pages. At
the end, `listTools conn` returns every tool the server advertises, in page-then-position
order, and refuses to loop forever on a repeating cursor.

```haskell
listTools :: McpConnection -> IO [McpTool]
```

(Use the same monad/return convention C1 chose for `request`; if C1 uses `MonadIO m`, write
`MonadIO m => McpConnection -> m [McpTool]`.) Internally, loop: call
`request conn "tools/list" params` where `params` is `{}` on the first page and
`{ "cursor": <c> }` afterward; decode the result object's `tools` array into `[McpTool]` and
its optional `nextCursor` string; accumulate; if `nextCursor` is present and not already in
the seen-cursor `Set`, recurse with it; if it repeats, throw `decodeError` describing the
cycle; cap total iterations at 10000 and throw `decodeError` if exceeded. A result that is
not an object, or whose `tools` field is missing or not an array, throws `decodeError`.

Commands: `cabal build <mcp-package>` then `cabal test <mcp-package>`. Acceptance: against an
in-process stub `McpConnection` (a fake whose `request` returns page one with a `nextCursor`
then page two without one), `listTools` returns the concatenation of both pages in order.
A stub that returns the same `nextCursor` twice causes `listTools` to throw a `BaikaiError`
with `category = DecodeFailure`.

### Milestone 3 — `callTool`, the result type, content mapping, and error taxonomy

Scope: implement invocation, the result representation, lowering to baikai's `ToolResult`,
mapping protocol failures into `BaikaiError`, and optional `outputSchema` validation.

Define:

```haskell
data McpToolCall = McpToolCall
  { name :: !Text,
    arguments :: !Value   -- a JSON object of arguments; use `object []` for none
  }
  deriving stock (Eq, Show, Generic)

data McpContentBlock
  = McpText !Text
  | McpImage { imageData :: !ByteString, mimeType :: !Text }
  | McpAudio { audioData :: !ByteString, mimeType :: !Text }
  | McpEmbeddedResource !Value   -- preserved verbatim; lowered to text by C5's choice
  | McpUnknownBlock !Value       -- forward-compat: any block kind we do not model
  deriving stock (Eq, Show, Generic)

data McpToolResult = McpToolResult
  { content :: !(Vector McpContentBlock),
    isError :: !Bool,
    structuredContent :: !(Maybe Value)
  }
  deriving stock (Eq, Show, Generic)

callTool :: McpConnection -> McpToolCall -> IO McpToolResult
toToolResult :: McpToolResult -> Baikai.Message.ToolResult
```

`callTool` sends `request conn "tools/call" { "name": ..., "arguments": ... }`. It decodes
the `result` object's `content` array into `Vector McpContentBlock` (text blocks → `McpText`,
image/audio with base64 `data` + `mimeType` → decoded bytes, `resource` → `McpEmbeddedResource`,
anything else → `McpUnknownBlock` holding the raw value), reads the optional `isError`
(defaulting to `False`), and the optional `structuredContent`. A malformed result throws
`decodeError`. If the JSON-RPC layer surfaces an error response (C1 either throws or returns
it), map by code: `-32601` method-not-found and `-32602` invalid-params → `invalidRequest`;
everything else → `providerError`; carry the server's message text. When the called tool's
`McpTool` declares an `outputSchema` and the result has `structuredContent`, run the minimal
structural check (top-level `type`, `required` keys present) and throw `decodeError` on a
mismatch. (`callTool` takes only the call; pass the discovered `McpTool` to a variant such as
`callToolChecked :: McpConnection -> McpTool -> McpToolCall -> IO McpToolResult` for schema
validation, leaving `callTool` schema-agnostic.)

`toToolResult` lowers each block: `McpText` → `ToolResultText`, `McpImage` → `ToolResultImage`,
and audio/resource/unknown blocks → a `ToolResultText` carrying a short JSON-rendered
placeholder (so nothing is dropped), preserving `isError`. This yields a
`Baikai.Message.ToolResult` ready for `Baikai.Context.appendToolResult`.

Commands: `cabal test <mcp-package>`. Acceptance: against a stub whose `tools/call` returns a
single text block with `isError` absent, `callTool` returns a one-block `McpToolResult` with
`isError = False` and `toToolResult` yields `ToolResult` with one `ToolResultText` and
`isError = False`. A stub returning `isError: true` yields `isError = True`. A stub returning a
JSON-RPC `-32602` error makes `callTool` throw a `BaikaiError` with `category = InvalidRequest`.

### Milestone 4 — `tools/list_changed` notification hook

Scope: let a long-lived connection react to the server announcing that its tool set changed.
MCP servers that support it send a one-way `notifications/tools/list_changed` notification;
the correct client response is to re-run `tools/list`.

Provide a small hook that registers a callback for that notification using whatever
notification-dispatch mechanism C1 exposes on `McpConnection`. If C1 exposes a way to
register handlers:

```haskell
onToolsListChanged :: McpConnection -> (IO ()) -> IO (IO ())
-- returns an unregister action
```

The callback typically calls `listTools` again and updates the caller's cache. If C1 does not
yet expose notification dispatch, implement the minimal piece needed (document the exact C1
hook used) or provide `refreshTools :: McpConnection -> IO [McpTool]` (an alias for
`listTools`) plus the method-name constant `toolsListChangedMethod = "notifications/tools/list_changed"`,
and note the hook is best-effort pending C1's dispatch surface.

Commands: `cabal test <mcp-package>`. Acceptance: a stub that fires the notification triggers
the registered callback exactly once; after the callback runs, a second `listTools` reflects
the server's new tool set. If C1 lacks dispatch, the test instead asserts `refreshTools`
re-queries and the method-name constant has the spec-exact value.


## Concrete Steps

All commands run from the repository root unless noted. Enter the pinned toolchain first:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
```

Confirm C1's surface and package home before writing imports:

```bash
sed -n '1,200p' docs/plans/30-mcp-transport-and-json-rpc-client-core.md
ls baikai-mcp 2>/dev/null || echo "C1 package dir name differs — locate it"
grep -rn "module Baikai.Mcp.Connection" --include='*.hs' .
grep -rn "connectMcp\|McpConnection\|^request \|^notify " --include='*.hs' .
```

Create the module file (path assumes C1's package is `baikai-mcp`; adjust to C1's actual dir):

```bash
mkdir -p baikai-mcp/src/Baikai/Mcp
$EDITOR baikai-mcp/src/Baikai/Mcp/Tool.hs
```

Add `Baikai.Mcp.Tool` to the MCP package's `library` `exposed-modules` and ensure its
`build-depends` includes `baikai`, `aeson`, `text`, `bytestring`, `containers`, `vector`,
and `base64-bytestring` (mirroring the core library's deps used for content encoding):

```bash
$EDITOR baikai-mcp/baikai-mcp.cabal
```

Create the test module and wire it into the package's test `Main.hs`:

```bash
$EDITOR baikai-mcp/test/McpToolSpec.hs
$EDITOR baikai-mcp/test/Main.hs   # import McpToolSpec qualified; add McpToolSpec.tests
```

Build and test, iterating per milestone:

```bash
cabal build baikai-mcp
cabal test baikai-mcp
```

Expected test transcript once complete (tasty + tasty-hunit, the project's test framework,
as seen in `baikai/baikai/test/Main.hs`):

```text
Baikai.Mcp.Tool
  McpTool / toBaikaiTool
    decodes a tools/list tool object:        OK
    toBaikaiTool preserves inputSchema:      OK
    missing description becomes empty text:  OK
  listTools pagination
    aggregates two pages in order:           OK
    repeating cursor -> DecodeFailure:       OK
  callTool / result mapping
    text result, isError defaults False:     OK
    isError true is carried through:         OK
    -32602 JSON-RPC error -> InvalidRequest: OK
    toToolResult lowers blocks + isError:    OK
  tools/list_changed
    notification fires callback once:        OK

All N tests passed
```

Finally, format and run the repo-wide checks before committing:

```bash
nix fmt
cabal build all
cabal test all
nix flake check
```

This section must be updated with the real package directory name and any signature
adjustments once C1 is read.


## Validation and Acceptance

Validation is behavioral and runs against an **in-process stub MCP server** — a fake
`McpConnection` whose generic `request`/`notify` are backed by a table of canned JSON
responses keyed by method name (and, for `tools/list`, by the incoming `cursor`). This
avoids spawning a real subprocess while exercising the exact code paths. Build the stub in
the test module using whatever constructor or record-of-functions C1 exposes for
`McpConnection`; if C1's `McpConnection` is opaque, add a tiny test-only constructor in C1
or drive a loopback transport. Record the chosen approach in the Decision Log.

Acceptance criteria, each an automated test that fails before the work and passes after:

1. Discovery across pages: the stub answers `tools/list` with no cursor by returning two
   tools and `nextCursor: "p2"`, and answers `tools/list` with `cursor: "p2"` by returning
   one more tool and no `nextCursor`. `listTools conn` returns exactly those three tools in
   order. This proves pagination is followed to completion and aggregated.
2. Cycle guard: the stub always returns `nextCursor: "loop"`. `listTools conn` throws a
   `BaikaiError` whose `category` is `DecodeFailure` (not an infinite loop / hang).
3. Mapping: `toBaikaiTool` on a decoded tool yields a `Baikai.Tool.Tool` whose `parameters`
   is byte-for-byte the tool's `inputSchema` `Value` and whose `description` matches (empty
   when absent).
4. Invocation success: the stub answers `tools/call` for `name = "echo"` with one text
   content block and no `isError`. `callTool conn (McpToolCall "echo" args)` returns an
   `McpToolResult` with one `McpText` block and `isError = False`; `toToolResult` of it is a
   `Baikai.Message.ToolResult` with one `ToolResultText` and `isError = False`.
5. Tool-level error: the stub answers `tools/call` with `isError: true` and a text block.
   `callTool` returns `McpToolResult { isError = True }` — it does **not** throw. This is the
   behavior the model is meant to observe and recover from.
6. Protocol error: the stub answers `tools/call` with a JSON-RPC error `-32602`. `callTool`
   throws a `BaikaiError` with `category = InvalidRequest`.
7. Refresh: firing `notifications/tools/list_changed` invokes the registered callback once,
   and a subsequent `listTools` reflects the stub's updated tool table.

Run `cabal test baikai-mcp` to execute all of the above. Success is the tasty summary
reporting all tests passed; failure prints the offending assertion with expected/actual.


## Idempotence and Recovery

Every step is safe to repeat. Creating the module and editing the `.cabal`/`Main.hs` are
ordinary file edits; re-running `cabal build` / `cabal test` is idempotent and only
recompiles what changed. The new code adds files and one module entry — it does not modify
or delete existing modules, so re-running the plan from a partial state cannot corrupt
prior work. If a build fails midway, fix the reported module and re-run `cabal build
baikai-mcp`; nothing external is mutated. There are no migrations, no network writes, and no
destructive operations: discovery and invocation are read/execute calls against a server the
caller already connected to. If C1's signatures turn out to differ from the contract assumed
here, adjust only the thin wrappers in `Baikai.Mcp.Tool` and re-run the tests; the
data types and the stub-based acceptance suite remain valid. To back out entirely, delete
`Baikai/Mcp/Tool.hs` and `McpToolSpec.hs` and remove their two registration lines.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Baikai.Mcp.Connection` (from C1, hard dependency,
  `baikai/docs/plans/30-mcp-transport-and-json-rpc-client-core.md`): provides `McpConnection`,
  `connectMcp`, generic `request :: McpConnection -> Text -> Value -> m Value`,
  `notify :: McpConnection -> Text -> Value -> m ()`, the server-name accessor on the
  connection, and (ideally) a notification-dispatch hook. This plan's functions are thin
  JSON-RPC method wrappers over `request`/`notify`.
- `Baikai.Tool` (`Tool`, `_Tool`): the wire tool record that `toBaikaiTool` produces.
- `Baikai.Content` (`TextContent`, `ImageContent`, `ToolResultContent`): the lowering target
  for `toToolResult`.
- `Baikai.Message` (`ToolResult`, `toolResultText`, `toolResultErrorText`, `toolResultImage`):
  the conversation-facing result type `toToolResult` builds.
- `Baikai.Error` (`BaikaiError`, `ErrorCategory`, `invalidRequest`, `providerError`,
  `decodeError`): the taxonomy MCP transport/protocol failures map into.
- `aeson` (`Value`, `FromJSON`, `ToJSON`, object accessors), `text`, `bytestring` +
  `base64-bytestring` (decoding image/audio `data`), `containers` (`Set` for the cursor
  guard), `vector` (`Vector` for content blocks).

The shared integration contract that siblings depend on — exported by
`Baikai.Mcp.Tool` and matching the names mandated by the MasterPlan
(`baikai/docs/masterplans/6-mcp-support-across-the-agent-stack.md`):

```haskell
module Baikai.Mcp.Tool
  ( McpTool (..),
    McpToolCall (..),
    McpToolResult (..),
    McpContentBlock (..),
    listTools,
    callTool,
    toBaikaiTool,
    toToolResult,
    onToolsListChanged,   -- or refreshTools, per C1's notification surface
  ) where

data McpTool        -- name, description (Maybe), inputSchema :: Value, outputSchema :: Maybe Value
data McpToolCall     -- name :: Text, arguments :: Value
data McpToolResult   -- content :: Vector McpContentBlock, isError :: Bool, structuredContent :: Maybe Value

listTools    :: McpConnection -> IO [McpTool]
callTool     :: McpConnection -> McpToolCall -> IO McpToolResult
toBaikaiTool :: McpTool -> Baikai.Tool.Tool
toToolResult :: McpToolResult -> Baikai.Message.ToolResult
```

Per-milestone "must exist" gates:

- End of M1: `McpTool`, its `FromJSON`/`ToJSON`, and `toBaikaiTool` compile; mapping test
  passes.
- End of M2: `listTools` exists with the signature above and paginates; pagination + cycle
  tests pass.
- End of M3: `McpToolCall`, `McpToolResult`, `McpContentBlock`, `callTool`, `toToolResult`
  exist; success / `isError` / protocol-error / lowering tests pass.
- End of M4: the `tools/list_changed` hook (or `refreshTools` + method constant) exists; the
  refresh test passes.

Dependents (do not implement here, but keep the contract stable for them): the **shikumi
adapter C5** (`shinzui/shikumi:docs/plans/30-...`) is the **primary consumer** — it calls
`listTools`/`callTool`, applies the `mcp__<server>__<tool>` name prefix using the server name
from `McpConnection`, and renders `McpToolResult` into shikumi's tool surface. The **C4
resources/prompts** plan (`baikai/docs/plans/33-mcp-resources-and-prompts.md`) parallels this
module with `resources/*` and `prompts/*`, reusing the same `Baikai.Mcp.Connection` core. The
shared tool-name convention is explicitly **not** applied here; native names stay on the wire.
