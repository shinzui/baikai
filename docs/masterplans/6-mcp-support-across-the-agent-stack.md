---
id: 6
slug: mcp-support-across-the-agent-stack
title: "MCP support across the agent stack"
kind: master-plan
created_at: 2026-06-27T17:57:38Z
intention: "intention_01kw53nehwen9v95r1bw217p8n"
---

# MCP support across the agent stack

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

When this initiative is complete, an agent in the portfolio can reach the entire external
Model Context Protocol (MCP) ecosystem — the standardized tool, knowledge, and prompt servers
that the wider industry already publishes — through a single declared connection, without any
bespoke per-server Haskell glue. A `shikigami` agent author lists an MCP server in the agent's
Dhall declaration; at run time the runner connects, discovers that server's tools, and surfaces
them into the same `ToolRegistry` the agent already uses, so they are indistinguishable from
hand-written `shikumi` `Tool`s to the ReAct loop and the model. The same connection exposes the
server's resources (readable knowledge blobs) and prompts (server-provided prompt templates).

The user-visible behaviors enabled are: (1) an agent calls a remote MCP tool (e.g. a GitHub,
Notion, or filesystem MCP server) mid-run and the result flows back into the conversation; (2)
those tools appear under a stable, collision-free name `mcp__<server>__<tool>`; (3) authed
servers work — static bearer tokens and headers now, interactive OAuth where the server requires
it; (4) an agent can pull an MCP resource or server-defined prompt into context.

This MasterPlan covers the protocol and transport **core in `baikai`** under a new `Baikai.Mcp`
namespace (transport, JSON-RPC + initialize handshake, client lifecycle, auth, tool
discovery/invocation, resources/prompts), the **adapter in `shikumi`** that turns an
`McpConnection` into registered `Tool`s, and the **per-agent declaration in `shikigami`**
(`Agent.dhall` `mcpServers` + runner wiring). Explicitly out of scope: building or hosting an
MCP **server** (we are a client only); the stdio/local-process transport (we ship streamable-HTTP
and SSE remote transports only); sampling/elicitation server-to-client callbacks; and any change
to `baikai`'s model-provider boundary — MCP is a tool/knowledge source, orthogonal to the LLM
provider abstraction it lives beside.

All six child exec-plans carry **deferred / future** intentions: this is a planned, decomposed
initiative whose implementation has not been scheduled. The MasterPlan exists to fix the
decomposition and the shared contract now, so the waves can be picked up independently later.


## Decomposition Strategy

The initiative splits into two waves along the natural seam between *speaking the protocol* and
*wiring it into the agent stack*.

**Wave 1 — the `baikai` core (C1–C4).** MCP is, at bottom, a JSON-RPC 2.0 protocol carried over
HTTP/SSE with an `initialize` handshake. That transport-and-protocol substrate is a single
cohesive concern (C1) on which three independent capability surfaces sit: tool discovery and
invocation (C2), authentication (C3), and resources and prompts (C4). Each is a distinct
functional concern with its own verifiable behavior — C2 lists and calls tools, C3 attaches
credentials and runs OAuth, C4 reads resources and gets prompts — and after C1 ships they have
no code dependency on one another, so they can be implemented in parallel by different sessions.
We kept C1 separate rather than folding the handshake into C2 because C3 and C4 need the same
connection lifecycle; merging would have forced every downstream stream to re-derive it.

**Wave 2 — the integration (C5–C6).** Once `baikai` can connect and call tools, `shikumi` gains
an adapter (C5) that consumes an `McpConnection` plus `listTools`/`callTool` and emits
`shikumi` `Tool`s into the existing `ToolRegistry` — this is where MCP becomes usable by the
ReAct loop. Then `shikigami` (C6) makes it declarative: an `mcpServers` field on the agent Dhall
schema, and runner wiring that connects and registers before a behavior runs.

Principles applied: **functional-concern boundaries**, not file boundaries — each plan owns one
capability end to end. **Dependency minimization** — C2/C3/C4 deliberately do not depend on each
other so the core wave parallelizes. **Independent verifiability** — every plan has a
demonstrable outcome testable in isolation (C1 against a reference MCP server's handshake, C5
against an in-memory fake `McpConnection`). **Balanced scope** — the protocol core (C1) is the
heaviest plan and is isolated so the others stay light.

Why core-in-`baikai` and not the gap doc's lean? The gap analysis
(`agent-infrastructure-gaps.md`, gap #6) leaned toward putting MCP entirely in `shikumi-tools`,
reasoning that MCP is a tool *source* and execution lives one layer up from the provider
boundary. The user overrode this: the MCP **transport and protocol client** is a reusable wire
capability — HTTP/SSE framing, JSON-RPC, the handshake, auth, pagination — with the same
character as `baikai`'s existing provider clients, and `baikai` already carries `http-client`,
`http-client-tls`, and `streamly`. Putting the core there lets any runtime (not just `shikumi`)
reuse it, and keeps the split clean: `baikai` speaks MCP; `shikumi` runs MCP tools; `shikigami`
declares MCP servers. The adapter and declaration stay exactly where the gap doc placed them.

Alternatives rejected: a single monolithic plan (would be >5 milestones across three repos —
exactly what a MasterPlan is for); splitting tool discovery from invocation (they share schema
and result mapping and would only couple two plans on the same code); and deferring
resources/prompts entirely (kept in scope as C4 because they share the C1 connection and are
cheap once it exists, though sequenced after the tool path which is the must-have).


## Exec-Plan Registry

Six child exec-plans across three repositories. C1–C4 live in **`baikai`** (this repo; relative
paths resolve). C5 lives in **`shinzui/shikumi`** and C6 in **`shinzui/shikigami`** — these are
**other repos**, so they are referenced with the repo-qualified path form (a bare relative path
will not resolve from `baikai`). All intentions are **deferred / future**.

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| C1 | baikai #30 — MCP transport + JSON-RPC client core (transport, JSON-RPC 2.0, `initialize` handshake) — THE CORE | `docs/plans/30-mcp-transport-and-json-rpc-client-core.md` | None | None | Not Started |
| C2 | baikai #31 — MCP tool discovery + invocation (`listTools` w/ cursor pagination, `callTool`, schema/result mapping, errors) | `docs/plans/31-mcp-tool-discovery-and-invocation.md` | C1 | None | Not Started |
| C3 | baikai #32 — MCP authentication (static headers/tokens + OAuth interactive flow) | `docs/plans/32-mcp-authentication-headers-tokens-and-oauth.md` | C1 | None | Not Started |
| C4 | baikai #33 — MCP resources + prompts (list/read resources, list/get prompts) | `docs/plans/33-mcp-resources-and-prompts.md` | C1 | None | Not Started |
| C5 | shikumi #30 — MCP→Tool adapter, surfacing MCP tools into the registry **(repo: `shinzui/shikumi`)** | `shinzui/shikumi:docs/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md` | C1, C2 | None | Not Started |
| C6 | shikigami #12 — per-agent MCP server declaration in `Agent.dhall` + runner wiring **(repo: `shinzui/shikigami`)** | `shinzui/shikigami:docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` | C2, C5 | C3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., C1, C2).

For the cross-repo children, the local-path forms are
`../shikumi/docs/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md` (C5) and
`../shikigami/docs/plans/12-per-agent-mcp-server-declaration-in-agent-dhall.md` (C6) when working
from a checkout where the sibling repos are present; the repo-qualified `shinzui/<repo>:...` form
in the table is the canonical reference because it resolves regardless of working tree layout.


## Dependency Graph

The shape is a fan-out from the core, then a join into the integration wave:

```text
                  C1 (baikai #30: transport + JSON-RPC + handshake — THE CORE)
                 /          |            \
                v           v             v
   C2 (baikai #31:    C3 (baikai #32:   C4 (baikai #33:
   tools)             auth)             resources/prompts)
        \               .
         \               . (soft)
          v               .
   C5 (shikumi #30:        .
   MCP→Tool adapter)        .
          \                  .
           \                  v
            +-----------> C6 (shikigami #12: Agent.dhall mcpServers + runner wiring)

Repos:  C1–C4 = shinzui/baikai   |   C5 = shinzui/shikumi   |   C6 = shinzui/shikigami
```

**C1 is the root and blocks everything.** It defines `McpConnection`, the `connectMcp`
lifecycle, the JSON-RPC request/response plumbing, and the `initialize` handshake. C2, C3, and C4
each issue MCP method calls over a live `McpConnection`, so none of them can compile or be
exercised until C1 exists. These three are **hard** dependencies on C1 and are otherwise
**mutually independent** — once C1 lands, C2/C3/C4 can be implemented in parallel by separate
sessions, since tool calls, auth handshakes, and resource reads touch different methods and types
on the shared connection without overlapping code.

**C5 (shikumi) hard-depends on C1 + C2.** The adapter consumes the `McpConnection` handle (C1) and
calls `listTools`/`callTool` (C2) to enumerate tools and translate invocations; without the tool
surface there is nothing to adapt. It does not need C3 or C4 — an unauthenticated server's tools
suffice to build and verify the adapter against an in-memory fake connection.

**C6 (shikigami) hard-depends on C2 + C5, soft-depends on C3.** It wires per-agent declarations:
it must connect (C1, transitively via C2/C5) and register tools through the C5 adapter, so C5 is
a hard dependency and C2 is a hard dependency for the tool methods. C3 is **soft**: agents can
declare and use *unauthenticated* MCP servers before OAuth/token support exists, so C6 can begin
against open servers and integrate auth when C3 is ready. C4 is not on C6's path; surfacing
resources/prompts to agents is a follow-on beyond this MasterPlan's wiring milestone.

**Parallelism summary.** Critical path is C1 → C2 → C5 → C6. C3 and C4 run fully parallel to C2
after C1. The earliest cross-repo work (C5) cannot start until both C1 and C2 are complete, which
is the main serialization cost; C6 is last because it depends on the adapter it wires.


## Integration Points

The shared contract below is the spine that keeps all six plans coherent. Names are normative:
plans must use these exact module paths, type names, and signatures so that downstream plans
compile against upstream artifacts without renegotiation.

**The `Baikai.Mcp` module layout (defined across C1–C4; consumed by C5/C6).** The core lives
under a single new namespace in `baikai`:

```haskell
Baikai.Mcp.Transport   -- HTTP/SSE transport: streamable-http and sse framing      (C1)
Baikai.Mcp.Protocol    -- JSON-RPC 2.0 envelopes + the MCP `initialize` handshake   (C1)
Baikai.Mcp.Client      -- McpConnection handle + connection lifecycle               (C1)
Baikai.Mcp.Auth        -- credentials: static headers/tokens + OAuth flow           (C3)
Baikai.Mcp.Tool        -- McpTool, listTools, callTool                              (C2)
Baikai.Mcp.Resource    -- resources + prompts: list/read/get                        (C4)
```

`Baikai.Mcp.Transport`, `.Protocol`, and `.Client` are **defined by C1** and are the foundation
every other module imports.

**`McpConnection` + `McpServerConfig` (defined by C1).** The connection handle and its config are
the central shared types. The connection is opened via:

```haskell
connectMcp :: McpServerConfig -> {- env/effect context -} -> m McpConnection
```

`McpServerConfig` carries the server `name`, the `url`, the `transport`
(`streamable-http | sse`), and the `auth` settings. C2/C3/C4 all take an `McpConnection`; C5
takes an `McpConnection` it received from a `connectMcp` call; C6 builds `McpServerConfig` values
from the agent's Dhall declaration. C1 owns these definitions; downstream plans consume them
without modification (auth fields on `McpServerConfig` are populated by C3's vocabulary).

**Tool discovery and invocation surface (defined by C2; consumed by C5).** The tool path is:

```haskell
listTools :: McpConnection -> m [McpTool]          -- cursor pagination handled internally
callTool  :: McpConnection -> McpToolCall -> m McpToolResult
```

`McpTool`, `McpToolCall`, and `McpToolResult` are owned by `Baikai.Mcp.Tool` (C2). C5 maps each
`McpTool` (name + JSON-Schema parameters) to a `baikai` `Baikai.Tool.Tool` record / `shikumi`
`Tool i o`, and routes the model's `ToolCall` arguments through `callTool`, translating
`McpToolResult` back into a `shikumi` tool result.

**Surfaced-tool naming convention `mcp__<server>__<tool>` (defined by C5; declared by C6).** When
the adapter registers an MCP server's tools into the existing `ToolRegistry`, each tool is named
`mcp__<server>__<tool>` — the `<server>` segment is the `name` from `McpServerConfig`, the
`<tool>` segment is the `McpTool` name. This guarantees collision-free coexistence of multiple
MCP servers and hand-written tools in one registry, and gives the model a stable, legible handle.
C6's `mcpServers` declaration supplies the `<server>` namespace via each entry's name.

**`shikumi` `SomeTool` / `Tool i o` + `ToolRegistry` (owned by `shikumi`; extended by C5).** The
adapter (C5) does not introduce a new registry — it produces `SomeTool` / `Tool i o` values and
registers them into `shikumi`'s **existing** `ToolRegistry`, so the ReAct loop dispatches MCP
tools through the same path as native ones. C5 owns the bridge; C6 invokes it.

**`shikigami` `Agent` Dhall schema `mcpServers` field (defined by C6).** C6 adds an `mcpServers`
field to the Dhall `Agent` schema — a list of server declarations (name, url, transport, auth) —
and runner wiring that, before executing a behavior, calls `connectMcp` for each declared server
and registers its tools via the C5 adapter. This is the only integration point that touches a
configuration schema; it is the user-facing entry to the whole stack.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] C1 (baikai #30): HTTP/SSE transport for streamable-http and sse
- [ ] C1 (baikai #30): JSON-RPC 2.0 envelopes + `initialize` handshake + `McpConnection` lifecycle
- [ ] C2 (baikai #31): `listTools` with cursor pagination
- [ ] C2 (baikai #31): `callTool` + schema/result mapping + error handling
- [ ] C3 (baikai #32): static headers/token auth
- [ ] C3 (baikai #32): OAuth interactive flow
- [ ] C4 (baikai #33): list/read resources
- [ ] C4 (baikai #33): list/get prompts
- [ ] C5 (shikumi #30): MCP→Tool adapter producing `SomeTool`/`Tool i o`
- [ ] C5 (shikumi #30): register surfaced tools as `mcp__<server>__<tool>` into `ToolRegistry`
- [ ] C6 (shikigami #12): `mcpServers` field on the `Agent` Dhall schema
- [ ] C6 (shikigami #12): runner wiring — connect + register before behavior run

(Milestone names are indicative; the authoritative milestone list lives in each child ExecPlan.)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Put the MCP transport/protocol **core in `baikai`** (new `Baikai.Mcp` namespace),
  not in `shikumi-tools` only.
  Rationale: The gap analysis (`agent-infrastructure-gaps.md`, gap #6) leaned toward MCP living
  entirely in `shikumi-tools`, treating MCP purely as a tool *source* whose execution sits one
  layer above the provider boundary. The user overrode this for the **client core**: HTTP/SSE
  framing, JSON-RPC 2.0, the `initialize` handshake, auth, and pagination are a reusable wire
  capability with the same character as `baikai`'s existing provider clients, and `baikai` already
  depends on `http-client`, `http-client-tls`, and `streamly`. Placing the core in `baikai` lets
  any runtime reuse it, while the *execution/adaptation* (turning MCP tools into runnable
  `Tool`s) still lives in `shikumi` and the *declaration* in `shikigami` — preserving the
  "baikai speaks, shikumi runs, shikigami declares" split.
  Date: 2026-06-27

- Decision: Lay out the core as the `Baikai.Mcp.{Transport, Protocol, Client, Auth, Tool,
  Resource}` modules.
  Rationale: One module per functional concern lets C1 (Transport/Protocol/Client) ship the
  foundation and C2/C3/C4 each own exactly one downstream module (Tool / Auth / Resource) with no
  cross-module coupling, so the core wave parallelizes after C1. Mirrors `baikai`'s existing
  per-concern module style.
  Date: 2026-06-27

- Decision: Surface MCP tools under the naming convention `mcp__<server>__<tool>`.
  Rationale: A flat namespace would collide when two MCP servers expose a same-named tool, or
  when an MCP tool shadows a native one. Prefixing with `mcp__` and the server name (from
  `McpServerConfig.name`, declared in `shikigami`'s `mcpServers`) guarantees collision-free
  coexistence in one `ToolRegistry` and gives the model a stable, legible handle.
  Date: 2026-06-27

- Decision: Decompose into two waves — baikai core [C1–C4] then integration [C5–C6] — with
  C2/C3/C4 mutually independent after C1.
  Rationale: Functional-concern boundaries with minimized cross-plan coupling; isolating the
  heavy protocol core (C1) keeps the other plans light and independently verifiable, and lets
  the three core capability surfaces proceed in parallel. Rejected a monolithic single plan
  (>5 milestones across 3 repos) and rejected splitting tool discovery from invocation (they
  share schema/result mapping).
  Date: 2026-06-27

- Decision: Include resources + prompts (C4) in scope rather than deferring them.
  Rationale: They share the C1 `McpConnection` and are cheap to add once it exists, so they ride
  the core wave. They are sequenced *after* the tool path (C2) which is the must-have for agent
  usefulness, and they are intentionally **not** on C6's wiring critical path (surfacing
  resources/prompts to agents is a follow-on beyond this MasterPlan's milestone). Building or
  hosting an MCP server, stdio transport, and sampling/elicitation callbacks remain out of scope.
  Date: 2026-06-27

- Decision: Coordinate the cross-repo children (C5 in `shinzui/shikumi`, C6 in
  `shinzui/shikigami`) via mori + `agent-plans.dhall` and rei intention-deps.
  Rationale: A bare relative path from `baikai` will not resolve into sibling repos, so the
  registry and dependency graph reference C5/C6 with the repo-qualified `shinzui/<repo>:...`
  form. The actual cross-repo dependency edges (C5 hard-depends on baikai C1+C2; C6 on C2+C5,
  soft on C3) are mirrored as machine-readable links in `mori`/`agent-plans.dhall` and enforced
  through rei intention-dependencies via the `mina rei dependency` mechanism, so that scheduling
  the deferred intentions later respects the ordering across repositories.
  Date: 2026-06-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
