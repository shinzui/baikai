---
type: Improvement Request
title: Ship the MCP client tool and authentication contracts
description: >-
  Complete and release Baikai's planned MCP transport, tool discovery/invocation, and credential
  contracts so authorized runtimes can connect without inventing a private protocol client.
timestamp: 2026-07-30T14:36:35Z
requestId: IR-2
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: Ship the MCP Client, Tool, and Authentication Contracts

## Status

Proposed. This is the Baikai-owned blocker for Shikigami plan 12 runtime milestones 3–5 and
Shikumi's MCP adapter.

## Context

The accepted MCP MasterPlan and plans 30–32 define transport/JSON-RPC, tool discovery and
invocation, and authentication, but the current released source has no public `Baikai.Mcp.*`
modules. Shikigami can add inert declaration schema now; it must not guess a client API, embed raw
tokens in declarations, or connect to servers until the owned implementation is released.

## Requested Change

Implement the existing C1–C3 plans as one coherent public package family: current streamable HTTP
and documented legacy SSE behavior, initialized session lifecycle, typed tool list/call operations,
bounded protocol errors, and opaque credential resolution for headers/tokens/OAuth. Connection
cleanup must be bracket-safe and raw credentials must not gain `Show` or JSON instances.

## Acceptance

1. A local stub MCP server proves initialize, list-tools, call-tool, session handling, error
   classification, and cleanup without live network access.
2. Authentication tests prove credential references resolve only at the client boundary and never
   appear in rendered configuration or errors.
3. Public APIs cover the contracts referenced by Baikai plans 30–32 without internal imports.
4. A tagged release exposes stable bounds for Shikumi and Shikigami.

## Requested Deliverables

- MCP package/modules and hermetic conformance tests.
- Security/redaction documentation.
- Tagged release and changelog.
