---
id: 33
slug: mcp-resources-and-prompts
title: "MCP resources and prompts"
kind: exec-plan
created_at: 2026-06-27T17:57:46Z
intention: "intention_01kw53nf2me9jrj6816b93d7p4"
master_plan: "docs/masterplans/6-mcp-support-across-the-agent-stack.md"
---

# MCP resources and prompts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The Model Context Protocol (MCP) is a published, vendor-neutral wire protocol that lets a
program talk to an external server over JSON-RPC 2.0 to discover and use three kinds of
capability: **tools** (functions the server can run), **resources** (readable knowledge
blobs the server exposes, each addressed by a URI such as a file or a database row), and
**prompts** (named, server-authored prompt templates that, given some arguments, expand
into a list of chat messages). JSON-RPC 2.0 is a simple request/response convention where
the client sends `{"jsonrpc":"2.0","id":1,"method":"...","params":{...}}` and gets back
either a `result` or an `error`.

This plan delivers the **resources** and **prompts** halves of baikai's MCP client. After
it lands, a program that already holds a live MCP connection (built by the sibling
transport-and-core plan, see below) can: list a server's resources page by page, read a
resource by URI and get back its text or binary (blob) contents, enumerate resource
*templates* (parameterised URIs the server can fill in), optionally subscribe to a
resource and be notified when it changes, list the server's prompts, and expand a named
prompt with arguments into rendered chat messages. Crucially, it can then **map** those
MCP results into baikai's own typed content blocks (`Baikai.Content`) and messages
(`Baikai.Message`), so a host can feed a fetched resource or an expanded prompt straight
into a model request through baikai's existing `completeRequest` / `streamRequest` surface.

You can see it working without a network: the JSON decoders and the content-mapping helpers
are pure functions exercised by `cabal test baikai` against recorded MCP payloads, and an
optional end-to-end milestone drives the same functions through a live connection against a
stub MCP server.

**Priority note.** Within the MCP initiative, resources and prompts are deliberately the
*lowest-priority* child. For an autonomous agent, **tools** are what matter — they let the
agent *act* — and they are covered by the sibling plan `docs/plans/31-mcp-tool-discovery-and-invocation.md`.
Resources and prompts are knowledge/context conveniences that *complete* the MCP surface but
are not on the critical path for agent behaviour. This plan is nonetheless specified to be
complete and shippable on its own once the core lands.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Baikai.Mcp.Resource` and `Baikai.Mcp.Prompt` modules created with the resource,
  template, prompt, and content types and their `FromJSON`/`ToJSON` instances; pure decoders
  unit-tested against recorded payloads.
- [ ] M2: `listResources` (paginated) + `listAllResources`, `listResourceTemplates`, and
  `readResource` (text + blob) implemented over the C1 connection.
- [ ] M3 (optional): `subscribeResource` / `unsubscribeResource` and the `resources/updated`
  notification hook.
- [ ] M4: `listPrompts` (paginated) + `listAllPrompts` and `getPrompt`.
- [ ] M5: content-mapping helpers (resource contents -> `UserContent`/`ToolResultContent`,
  prompt messages -> `Baikai.Message.Message`) with tests.
- [ ] M6 (optional): end-to-end test driving list/read/get against a stub MCP server over a
  real `McpConnection`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement resources **and** prompts now rather than deferring them.
  Rationale: The MasterPlan's vision (`docs/masterplans/6-mcp-support-across-the-agent-stack.md`)
  explicitly includes "the server's resources (readable knowledge blobs) and prompts
  (server-provided prompt templates)" as part of the MCP surface. They are low priority
  relative to tools but small and self-contained; shipping them with the core avoids a
  second pass over the same JSON-RPC plumbing. The Progress list marks subscriptions (M3)
  and the live stub test (M6) as optional so the plan can land its core value first.
  Date: 2026-06-27

- Decision: `readResource` returns a single `McpResourceContents` value that wraps a
  *vector* of content blocks, not a bare block.
  Rationale: The MCP `resources/read` reply is `{"contents":[ ... ]}` — a list, because one
  URI (especially a directory-like resource) can yield several text/blob parts. Honouring
  the task's `readResource :: McpConnection -> Uri -> m McpResourceContents` signature while
  keeping the list means `McpResourceContents` carries `contents :: Vector McpResourceContent`.
  Date: 2026-06-27

- Decision: Map MCP resource/prompt content onto the **existing** `Baikai.Content` and
  `Baikai.Message` types rather than inventing new content blocks.
  Rationale: The whole point of mapping is to let a host feed MCP knowledge into a model
  request, and baikai already has `TextContent`, `ImageContent`, `UserContent`,
  `ToolResultContent`, and `Message`. Text resource contents map to `TextContent`; a blob
  whose `mimeType` is an image maps to `ImageContent` (baikai stores image bytes decoded);
  blobs of other media types have no model-facing representation and the mapping returns
  `Nothing` for them (the caller can still read the raw bytes). Prompt messages map to
  `Baikai.Message.user` / `assistant`.
  Date: 2026-06-27

- Decision: Subscription support is **best-effort and capability-gated**.
  Rationale: MCP subscriptions (`resources/subscribe` + the `notifications/resources/updated`
  push) only work when the server advertises `resources.subscribe` in its initialize result.
  baikai is a client; we expose `subscribeResource` and an `onResourceUpdated` hook that ride
  on C1's notification dispatch, but we do not poll or simulate updates. If the server does
  not advertise the capability the call surfaces a `BaikaiError` rather than hanging.
  Date: 2026-06-27

- Decision: Reuse C1's connection + generic request and C2's pagination types verbatim; do
  not redefine `McpConnection`, `Cursor`, or `Page` here.
  Rationale: The MasterPlan fixes a single shared contract under `Baikai.Mcp.*`. Redefining
  these would fork the surface. This plan imports them (see Interfaces and Dependencies) and
  only adds resource/prompt-specific types.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section assuming you know nothing about this repository.

**Where the code lives.** This is a multi-package Haskell repository. The core library is
the `baikai` package, whose Cabal file is `baikai/baikai.cabal` and whose source tree is
`baikai/src/`. Library modules are named `Baikai.*` and live under `baikai/src/Baikai/`
(for example `baikai/src/Baikai/Content.hs` is module `Baikai.Content`). The test suite is
`test-suite baikai-test` in the same Cabal file; its sources are under `baikai/test/`, it
uses the `tasty` + `tasty-hunit` test frameworks, and `baikai/test/Main.hs` aggregates each
spec module's `tests :: TestTree`. The project builds with **Cabal** under a **Nix** dev
shell pinned to **GHC 9.12.4**, language edition **GHC2024**, with the default extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` and a
strict warning set that includes `-Wall` and `-Wmissing-export-lists` (so every module
**must** have an explicit export list).

**The two sibling plans this one depends on.** This initiative is decomposed in
`docs/masterplans/6-mcp-support-across-the-agent-stack.md`. Two siblings matter here and are
checked into the repo:

- `docs/plans/30-mcp-transport-and-json-rpc-client-core.md` — call it **C1**. It builds the
  transport (streamable-HTTP and SSE), the JSON-RPC framing, the `initialize` handshake, and
  the client lifecycle. It owns the opaque connection handle `McpConnection` and the generic
  request primitive every higher-level method is built on. **Hard dependency:** nothing in
  this plan runs without C1's connection and request function.
- `docs/plans/31-mcp-tool-discovery-and-invocation.md` — call it **C2**. It implements
  tool discovery (`tools/list`) and invocation (`tools/call`) and establishes the
  **pagination** convention (cursor + page) that this plan mirrors exactly for resources and
  prompts. This plan **parallels** C2: same shapes, different methods.

At the time this plan was authored, C1 and C2 are skeletons (their prose is not yet filled
in). This plan therefore states, in *Interfaces and Dependencies* below, the exact C1/C2
contract it consumes. **When you implement, first read C1 and C2 as they then stand and make
the signatures here match theirs to the letter.** If a name differs (for example C1 names the
request function `mcpRequest` rather than `request`), follow C1 and update this plan's
*Decision Log* with the correction.

**Terms of art used in this plan.**

- *MCP (Model Context Protocol)*: a published JSON-RPC 2.0 protocol for a client to use an
  external server's tools, resources, and prompts. baikai is a **client only** — we never
  host a server.
- *JSON-RPC 2.0*: the request/response convention described in Purpose. A *request* has an
  `id` and expects a reply; a *notification* has no `id` and expects no reply (the server
  uses notifications to push events like "this resource changed").
- *Resource*: a readable blob the server exposes, addressed by a *URI* (a string like
  `file:///notes/todo.md` or `db://customers/42`). Listing a resource returns metadata
  (uri, name, optional mimeType); *reading* it returns the actual contents.
- *Resource template*: a parameterised URI such as `file:///{path}` that the server can fill
  in. `resources/templates/list` enumerates them. We list them but do not (in this plan)
  expand a template client-side; reading still goes through a concrete URI.
- *Resource contents*: the body returned by `resources/read`. Each part is either **text**
  (a `text` string) or a **blob** (base64-encoded binary under `blob`), with an optional
  `mimeType`.
- *Subscription*: `resources/subscribe` asks the server to notify the client when a named
  URI changes; the server then sends `notifications/resources/updated` notifications. Gated
  on the server advertising the `resources.subscribe` capability.
- *Prompt*: a named, server-authored template. `prompts/list` enumerates prompts and their
  declared arguments; `prompts/get` takes a name plus an arguments map and returns a list of
  *prompt messages* (each a role — user or assistant — plus content).
- *Pagination / cursor*: MCP list methods return at most one page plus an optional opaque
  `nextCursor` string; passing that cursor back fetches the next page. "Drain all pages"
  means loop until `nextCursor` is absent.

**baikai types this plan maps onto (already exist).** From `baikai/src/Baikai/Content.hs`:
`TextContent { text :: Text }`; `ImageContent { imageData :: ByteString, mimeType :: Text }`
(bytes stored **decoded**, base64 only on the wire); the per-role sums `UserContent`
(`UserText`/`UserImage`) and `ToolResultContent` (`ToolResultText`/`ToolResultImage`). From
`baikai/src/Baikai/Message.hs`: the `Message` sum with smart constructors `user :: Text ->
Message` and `assistant :: Text -> Message`. From `baikai/src/Baikai/Error.hs`: `BaikaiError`
with smart constructors `decodeError`, `invalidRequest`, and `providerError` — MCP failures
in this plan are surfaced as `BaikaiError` so callers handle them uniformly with the rest of
baikai. The Aeson convention in this codebase is snake_case field names via
`Data.Aeson.camelTo2 '_'` and tagged-object sum encoding (`{"type":...,"data":...}`); the
MCP wire, however, uses `camelCase` keys (`uriTemplate`, `mimeType`, `nextCursor`), so the
resource/prompt instances here use **camelCase-preserving** Aeson options, not the snake_case
helper used elsewhere — match the MCP spec, not baikai's internal convention, for anything
that crosses the MCP wire.


## Plan of Work

The work is six milestones. M1, M2, M4, and M5 are required and together deliver the full
resources-and-prompts surface plus the content mapping. M3 (subscriptions) and M6 (live stub
test) are optional refinements that depend on C1 features and can be skipped if C1 has not
exposed them yet; the plan still delivers observable value without them because every decoder
and mapper is pure and tested against recorded payloads.

All new library code goes in two new modules — `Baikai.Mcp.Resource`
(`baikai/src/Baikai/Mcp/Resource.hs`) and `Baikai.Mcp.Prompt`
(`baikai/src/Baikai/Mcp/Prompt.hs`) — both added to the `exposed-modules` list of the
`library` stanza in `baikai/baikai.cabal`. New tests go in `baikai/test/McpResourceSpec.hs`
and `baikai/test/McpPromptSpec.hs`, added to the `other-modules` of `test-suite baikai-test`
and wired into `baikai/test/Main.hs`.


### Milestone 1 — Types and pure codecs

Scope: define every resource/prompt data type and its JSON instances, plus exported pure
decoder helpers, with no dependency on a live connection. At the end, `cabal build baikai`
compiles the two new modules and `cabal test baikai` passes new tests that decode recorded
MCP payloads into the typed values and re-encode request params correctly.

In `baikai/src/Baikai/Mcp/Resource.hs` define: `newtype Uri = Uri Text`; `McpResource`
(uri, name, optional title/description/mimeType/size); `McpResourceTemplate` (uriTemplate,
name, optional title/description/mimeType); `McpResourceContent = ResourceText { mimeType,
text } | ResourceBlob { mimeType, blob :: ByteString }`; and `McpResourceContents { uri ::
Uri, contents :: Vector McpResourceContent }`. Give each a `FromJSON` (and `ToJSON` where it
crosses the wire) using camelCase-preserving options. A `ResourceText` is recognised by the
presence of a `text` key and `ResourceBlob` by a `blob` key (base64 → decoded bytes via
`Data.ByteString.Base64`, mirroring how `Baikai.Content.ImageContent` decodes). Export a pure
helper `decodeResourcePage :: Value -> Either Text (Page McpResource)` and the analogous
`decodeResourceTemplatePage` and `decodeResourceContents` so tests can feed a `Value` (or a
fixture `ByteString`) directly without any network. ("`Page`" is C2's pagination wrapper; see
Interfaces.)

In `baikai/src/Baikai/Mcp/Prompt.hs` define: `newtype PromptName = PromptName Text`;
`type Arguments = Map Text Text` (MCP prompt arguments are string-valued name→value pairs);
`McpPromptArgument { name, description :: Maybe Text, required :: Bool }`; `McpPrompt {
name :: PromptName, title :: Maybe Text, description :: Maybe Text, arguments :: Vector
McpPromptArgument }`; `data McpRole = McpUser | McpAssistant`; `data McpPromptContent =
PromptText Text | PromptImage { imageData :: ByteString, mimeType :: Text } | PromptResource
McpResourceContents` (a prompt message may embed a resource); and `McpPromptMessage { role ::
McpRole, content :: McpPromptContent }`. Export pure decoders `decodePromptPage :: Value ->
Either Text (Page McpPrompt)` and `decodePromptMessages :: Value -> Either Text [McpPromptMessage]`.

Acceptance: new unit tests in `McpResourceSpec`/`McpPromptSpec` decode literal JSON matching
the MCP spec and assert the resulting Haskell values; encoding the request params for
`resources/read` (`{"uri": ...}`) and `prompts/get` (`{"name":...,"arguments":{...}}`)
produces exactly the expected `Value`.


### Milestone 2 — Resource listing, templates, and read over a connection

Scope: wire the M1 types to C1's connection and generic request. At the end, given an
`McpConnection`, a program can page through resources, drain all pages, list templates, and
read a URI to text or blob.

Add to `Baikai.Mcp.Resource`:

- `listResources :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpResource)` —
  sends `resources/list` with optional `{"cursor": ...}` params and decodes the reply.
- `listAllResources :: MonadIO m => McpConnection -> m (Vector McpResource)` — drains every
  page using C2's `paginate` helper.
- `listResourceTemplates :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpResourceTemplate)`
  — sends `resources/templates/list`.
- `readResource :: MonadIO m => McpConnection -> Uri -> m McpResourceContents` — sends
  `resources/read` with `{"uri": ...}` and decodes `{"contents":[...]}`.

Each calls C1's generic request, then runs the matching M1 decoder; a decode failure becomes
`decodeError` and a JSON-RPC error from the server is already a `BaikaiError` from C1.

Acceptance: with a stub request function (a pure `Method -> Value -> IO Value` passed to a
test connection, or recorded fixtures), `listResources` returns the expected first page with
a `nextCursor`, a second call with that cursor returns the final page with no cursor, and
`listAllResources` returns the concatenation; `readResource` on a text URI yields a
`ResourceText` block and on a binary URI yields a `ResourceBlob` whose decoded bytes match.


### Milestone 3 (optional) — Subscriptions and the updated hook

Scope: opt-in change notifications, gated on server capability. At the end, a program can
subscribe to a URI and register a callback fired when the server pushes
`notifications/resources/updated`.

Add `subscribeResource :: MonadIO m => McpConnection -> Uri -> m ()` and
`unsubscribeResource` (sending `resources/subscribe` / `resources/unsubscribe`), and
`onResourceUpdated :: MonadIO m => McpConnection -> (Uri -> IO ()) -> m ()` which registers a
handler on C1's notification dispatch for the `notifications/resources/updated` method,
decoding its `{"uri": ...}` params and invoking the callback. If C1 has not yet exposed a
notification-handler registry, this milestone is deferred (note it in Progress) — the
required milestones do not depend on it.

Acceptance: a test feeds a synthetic `notifications/resources/updated` payload through C1's
dispatch and asserts the registered callback receives the right `Uri`.


### Milestone 4 — Prompt listing and get

Scope: the prompts surface, mirroring M2. Add to `Baikai.Mcp.Prompt`:

- `listPrompts :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpPrompt)` — sends
  `prompts/list`.
- `listAllPrompts :: MonadIO m => McpConnection -> m (Vector McpPrompt)` — drains pages via
  `paginate`.
- `getPrompt :: MonadIO m => McpConnection -> PromptName -> Arguments -> m [McpPromptMessage]`
  — sends `prompts/get` with `{"name": ..., "arguments": {...}}` and decodes the returned
  `{"messages":[...]}`.

Acceptance: with a stub request function, `listPrompts` paginates like `listResources`, and
`getPrompt "greet" (fromList [("name","Ada")])` returns the rendered messages (e.g. a single
user message whose text contains "Ada").


### Milestone 5 — Content mapping into baikai

Scope: the bridge that makes resources/prompts usable in a model request. Export from the
respective modules:

- `resourceContentToUserContent :: McpResourceContent -> Maybe UserContent` — `ResourceText`
  → `UserText (TextContent t)`; `ResourceBlob` with an image `mimeType` → `UserImage
  (ImageContent bytes mime)`; any other blob → `Nothing`.
- `resourceContentsToUserContent :: McpResourceContents -> Vector UserContent` — maps and
  drops the `Nothing`s.
- `resourceContentToToolResultContent :: McpResourceContent -> Maybe ToolResultContent` — the
  same mapping into `ToolResultText` / `ToolResultImage`, for feeding a fetched resource back
  as a tool result.
- `promptMessageToMessage :: McpPromptMessage -> Maybe Message` — `McpUser` + text →
  `Baikai.Message.user t`; `McpAssistant` + text → `assistant t`; image/resource contents map
  through the resource helpers where a representation exists, else `Nothing`.
- `promptMessagesToMessages :: [McpPromptMessage] -> Vector Message` — maps and drops the
  unmappable.

Acceptance: tests assert a text resource maps to `UserText`, a `image/png` blob maps to
`UserImage` with the right decoded bytes and mime, a `application/zip` blob maps to `Nothing`,
and a two-message prompt (user + assistant text) maps to the corresponding `Message`s.


### Milestone 6 (optional) — End-to-end against a stub MCP server

Scope: prove the whole path over a real `McpConnection`. Using whatever in-memory or
loopback connection constructor C1 exposes for testing (the MasterPlan anticipates one), or a
minimal local HTTP handler if C1 only ships HTTP, stand up a stub server that answers
`resources/list`, `resources/read`, `prompts/list`, and `prompts/get`, connect to it, and run
the public functions end to end. If C1 exposes no test connection, this milestone is deferred
and the pure + stub-function tests from M2/M4 stand as the acceptance evidence.

Acceptance: a single test connects, calls `listAllResources`, `readResource`,
`listAllPrompts`, and `getPrompt`, and asserts the values match what the stub served.


## Concrete Steps

All commands assume you are at the repository root
`/Users/shinzui/Keikaku/bokuno/baikai` and inside the Nix dev shell. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop          # or: direnv allow, if you use direnv
```

Confirm the toolchain and that the project builds before you start:

```bash
cabal build baikai
```

Expected (abbreviated) output on a clean tree:

```text
Up to date
```

Create the two library modules and register them in the Cabal file. After creating
`baikai/src/Baikai/Mcp/Resource.hs` and `baikai/src/Baikai/Mcp/Prompt.hs`, add both to the
`exposed-modules` list of the `library` stanza in `baikai/baikai.cabal` (the list is
alphabetised; insert `Baikai.Mcp.Prompt` and `Baikai.Mcp.Resource` after `Baikai.Message`).
Add any new build dependency you need (`containers` for `Data.Map`, `base64-bytestring` for
blob decoding, `vector`, `aeson`, `text`, `bytestring` — all already listed for the library,
so likely no change). Rebuild:

```bash
cabal build baikai
```

A missing module registration shows up as:

```text
<no location info>: error:
    module 'Baikai.Mcp.Resource' is listed in hs-source-dirs but not in exposed-modules
```

Create the test modules `baikai/test/McpResourceSpec.hs` and
`baikai/test/McpPromptSpec.hs`, each exporting `tests :: TestTree`, following the shape of
`baikai/test/ErrorSpec.hs`. Add `McpPromptSpec` and `McpResourceSpec` to the `other-modules`
list of `test-suite baikai-test` in `baikai/baikai.cabal`, and import + add
`McpResourceSpec.tests` and `McpPromptSpec.tests` to the `testGroup` list in
`baikai/test/Main.hs` (mirror how `ErrorSpec.tests` is wired there).

Run the test suite for the core package:

```bash
cabal test baikai
```

Expected output (abbreviated), once the specs are in place:

```text
baikai
  ...
  Baikai.Mcp.Resource
    decode resources/list page:           OK
    readResource text + blob:             OK
    resource content -> UserContent:      OK
  Baikai.Mcp.Prompt
    decode prompts/list page:             OK
    getPrompt renders messages:           OK
    prompt messages -> Message:           OK

All N tests passed
```

Format and lint before committing (the repo enforces fourmolu):

```bash
nix fmt
```

Commit per milestone using Conventional Commits, for example:

```text
feat(mcp): add resource listing, read, and content mapping
feat(mcp): add prompt listing and get with message mapping
```

Update the *Progress* checklist in this file at every stopping point.


## Validation and Acceptance

Validation rests on observable behaviour, not compilation alone.

**Pure decoder behaviour (always available).** In `McpResourceSpec`, decode a literal
`resources/list` reply with two resources and a `nextCursor`, and assert
`decodeResourcePage` yields a `Page` whose `items` has length 2 and whose `nextCursor` is
`Just`. Decode a `resources/read` reply that contains one text part and one base64 blob part
and assert `readResource`'s decoder returns an `McpResourceContents` with a `ResourceText`
carrying the exact text and a `ResourceBlob` whose decoded bytes equal the original (encode a
known byte string to base64 in the fixture so the round-trip is checkable). In `McpPromptSpec`,
decode a `prompts/list` reply and a `prompts/get` reply (`{"messages":[{"role":"user",
"content":{"type":"text","text":"Hi Ada"}}]}`) and assert the rendered message text.

**Pagination behaviour.** Provide a stub request function that returns page one (with a
cursor) for `{"cursor":null}` and page two (no cursor) for the page-one cursor; assert
`listAllResources` returns both pages concatenated, in order, and that exactly two requests
were issued (count calls in the stub).

**Read behaviour.** Through the stub, `readResource (Uri "file:///a.txt")` returns a text
block; `readResource (Uri "file:///logo.png")` returns a blob block whose `mimeType` is
`image/png` and whose bytes decode correctly.

**Get behaviour.** Through the stub, `getPrompt (PromptName "greet") (Map.fromList
[("name","Ada")])` returns a non-empty `[McpPromptMessage]` whose first message is a user
text mentioning "Ada".

**Mapping behaviour (the user-visible payoff).** Assert that
`resourceContentsToUserContent` of a text-plus-image read yields
`[UserText (TextContent "..."), UserImage (ImageContent <bytes> "image/png")]`, that a
non-image blob is dropped, and that `promptMessagesToMessages` of a user+assistant prompt
yields the matching `Baikai.Message` values. This is what lets a host splice MCP context into
a model request.

The concrete success signal is `cabal test baikai` printing `All N tests passed` with the new
groups present. The optional M6 test additionally prints a passing
`Baikai.Mcp end-to-end` group when a live stub connection is available.


## Idempotence and Recovery

Every step here is additive and safe to repeat. Re-running `cabal build baikai` and
`cabal test baikai` is idempotent. Creating the modules is a one-time `Write`; re-editing the
Cabal `exposed-modules`/`other-modules` lists is safe as long as you do not duplicate an
entry (Cabal errors loudly on duplicates, which is the recovery signal — remove the dup).
`nix fmt` is idempotent. None of the work is destructive: it adds two library modules, two
test modules, and a handful of Cabal/`Main.hs` lines; to back out entirely, delete the four
new files and revert the Cabal and `Main.hs` edits, then `cabal build baikai` returns to the
prior `Up to date` state.

The MCP operations themselves are read-only with one exception: `subscribeResource` (M3,
optional) creates server-side state. It is paired with `unsubscribeResource`, and a dropped
connection (C1's lifecycle) tears down all subscriptions, so a re-run cannot leak a
subscription. If a stub or live server returns an unexpected shape, the decoders fail with a
`decodeError` carrying the offending context rather than throwing a partial-pattern crash;
re-running after fixing the fixture/server is safe.


## Interfaces and Dependencies

**Libraries.** `aeson` (JSON), `base64-bytestring` (blob/image byte decoding, as in
`Baikai.Content`), `bytestring`, `text`, `vector`, `containers` (`Data.Map` for `Arguments`)
— all already declared for the `baikai` library. `unliftio-core` (already a dependency)
supplies `MonadIO` for the function signatures. Tests use `tasty` + `tasty-hunit` (already in
the test stanza).

**Consumed from C1 — `docs/plans/30-mcp-transport-and-json-rpc-client-core.md`.** This plan
assumes the following from the core; **verify against C1 when you implement and match its
exact names**:

```haskell
-- Opaque connection handle (lives in C1's Baikai.Mcp.Client or Baikai.Mcp.Connection).
data McpConnection

-- Generic JSON-RPC request: send `method` with optional params, block for the
-- matching response, return its `result` field, or throw a BaikaiError on a
-- JSON-RPC error / transport failure.
mcpRequest :: MonadIO m => McpConnection -> Text -> Maybe Value -> m Value

-- (M3, optional) notification dispatch registry for server-pushed messages.
onNotification :: McpConnection -> Text -> (Value -> IO ()) -> IO ()
```

If C1 names the request function `request` rather than `mcpRequest`, or returns a richer
result wrapper, adapt the call sites and record the adaptation in the Decision Log.

**Consumed from C2 — `docs/plans/31-mcp-tool-discovery-and-invocation.md`.** The pagination
contract, mirrored exactly for resources and prompts (these types live in a shared module —
C1's `Baikai.Mcp.Pagination` or wherever C2 places them; import, do not redefine):

```haskell
newtype Cursor = Cursor Text

data Page a = Page
  { items      :: Vector a
  , nextCursor :: Maybe Cursor
  }

-- Drain every page by following nextCursor until it is absent.
paginate :: MonadIO m => (Maybe Cursor -> m (Page a)) -> m (Vector a)
```

**Defined by this plan.** New module `Baikai.Mcp.Resource` (`baikai/src/Baikai/Mcp/Resource.hs`):

```haskell
newtype Uri = Uri Text

data McpResource = McpResource
  { uri         :: Uri
  , name        :: Text
  , title       :: Maybe Text
  , description :: Maybe Text
  , mimeType    :: Maybe Text
  , size        :: Maybe Int
  }

data McpResourceTemplate = McpResourceTemplate
  { uriTemplate :: Text
  , name        :: Text
  , title       :: Maybe Text
  , description :: Maybe Text
  , mimeType    :: Maybe Text
  }

data McpResourceContent
  = ResourceText { mimeType :: Maybe Text, text :: Text }
  | ResourceBlob { mimeType :: Maybe Text, blob :: ByteString }   -- bytes stored decoded

data McpResourceContents = McpResourceContents
  { uri      :: Uri
  , contents :: Vector McpResourceContent
  }

-- Pure decoders (for tests; no connection needed).
decodeResourcePage         :: Value -> Either Text (Page McpResource)
decodeResourceTemplatePage :: Value -> Either Text (Page McpResourceTemplate)
decodeResourceContents     :: Value -> Either Text McpResourceContents

-- Connection-backed operations.
listResources         :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpResource)
listAllResources      :: MonadIO m => McpConnection -> m (Vector McpResource)
listResourceTemplates :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpResourceTemplate)
readResource          :: MonadIO m => McpConnection -> Uri -> m McpResourceContents

-- Subscriptions (M3, optional).
subscribeResource   :: MonadIO m => McpConnection -> Uri -> m ()
unsubscribeResource :: MonadIO m => McpConnection -> Uri -> m ()
onResourceUpdated   :: MonadIO m => McpConnection -> (Uri -> IO ()) -> m ()

-- Content mapping into baikai (M5).
resourceContentToUserContent       :: McpResourceContent -> Maybe UserContent
resourceContentsToUserContent      :: McpResourceContents -> Vector UserContent
resourceContentToToolResultContent :: McpResourceContent -> Maybe ToolResultContent
```

New module `Baikai.Mcp.Prompt` (`baikai/src/Baikai/Mcp/Prompt.hs`):

```haskell
newtype PromptName = PromptName Text

type Arguments = Map Text Text   -- MCP prompt arguments are string-valued

data McpPromptArgument = McpPromptArgument
  { name        :: Text
  , description :: Maybe Text
  , required    :: Bool
  }

data McpPrompt = McpPrompt
  { name        :: PromptName
  , title       :: Maybe Text
  , description :: Maybe Text
  , arguments   :: Vector McpPromptArgument
  }

data McpRole = McpUser | McpAssistant

data McpPromptContent
  = PromptText Text
  | PromptImage { imageData :: ByteString, mimeType :: Text }
  | PromptResource McpResourceContents

data McpPromptMessage = McpPromptMessage
  { role    :: McpRole
  , content :: McpPromptContent
  }

-- Pure decoders.
decodePromptPage     :: Value -> Either Text (Page McpPrompt)
decodePromptMessages :: Value -> Either Text [McpPromptMessage]

-- Connection-backed operations.
listPrompts    :: MonadIO m => McpConnection -> Maybe Cursor -> m (Page McpPrompt)
listAllPrompts :: MonadIO m => McpConnection -> m (Vector McpPrompt)
getPrompt      :: MonadIO m => McpConnection -> PromptName -> Arguments -> m [McpPromptMessage]

-- Content mapping into baikai (M5).
promptMessageToMessage  :: McpPromptMessage -> Maybe Message
promptMessagesToMessages :: [McpPromptMessage] -> Vector Message
```

**baikai types reused (no change to them):** `Baikai.Content.{TextContent, ImageContent,
UserContent(UserText,UserImage), ToolResultContent(ToolResultText,ToolResultImage)}`;
`Baikai.Message.{Message, user, assistant}`; `Baikai.Error.{BaikaiError, decodeError,
invalidRequest, providerError}`. Every module needs an explicit export list (the build sets
`-Wmissing-export-lists` as an error-class warning under `-Wall`), and field names follow the
project's no-prefix convention enabled by `DuplicateRecordFields`. Anything crossing the MCP
wire uses camelCase Aeson keys to match the MCP spec, not baikai's internal snake_case helper.
