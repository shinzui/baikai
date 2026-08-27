---
title: "Provider-neutral structured output"
type: Capability
description: "Set one ResponseFormat on Options — plain JSON-object mode or a named JSON schema — and have it map onto Anthropic's output_config and OpenAI's response_format, so a caller gets schema-constrained JSON back from either vendor without writing per-provider request shaping."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.1.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.ResponseFormat
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "The 'responseFormat JsonSchema maps onto OpenAI response_format' case asserts the schema Value, the schema name, and strict: true land in the OpenAI request exactly as given."
  - kind: test
    resource: baikai-claude/test/Main.hs
    proves: "responseFormatMappingTest asserts a JsonSchema on Options.responseFormat maps onto Anthropic's native output_config with the schema Value forwarded verbatim."
  - kind: example
    resource: baikai-smoke/test/StructuredSmoke.hs
    proves: "Against a live provider, a request carrying only a JSON schema — with no formatting instruction in the prompt — comes back as a JSON object of exactly the described shape, which is the proof the host is enforcing the schema server-side."
  - kind: module
    resource: baikai/src/Baikai/ResponseFormat.hs
    proves: "The ResponseFormat vocabulary: the JSON-object mode and the named-schema mode both providers map."
---

# Provider-neutral structured output

`Options.responseFormat` takes a `ResponseFormat`: either plain JSON-object mode,
or a named schema carrying a JSON Schema `Value`. Each API provider maps it onto
its vendor's own primitive — Anthropic's `output_config`, OpenAI's
`response_format` with `strict: true` — so the caller writes the constraint once
and switches models without touching it.

The schema travels verbatim in both directions. baikai does not translate between
schema dialects or normalise the document; whatever the vendor accepts is what
you can send.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
let opts = emptyOptions
      & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "person" personSchema))
```

## Limits

- **API providers only.** The subprocess CLI providers have no structured-output
  flag and ignore the option.
- baikai ships **no JSON Schema validator**, deliberately. It does not check that
  the returned text validates against the schema you sent; enforcement is the
  host's. `StructuredSmoke` compensates by asserting the exact shape it asked
  for, which is a shape check rather than schema validation.
- The two vendors are not byte-equivalent. Anthropic's `output_config` requires a
  schema, so plain JSON-object mode downgrades to a permissive
  `{"type":"object"}` schema there; and because Anthropic's structured outputs
  are always schema-enforcing, baikai's `strict` flag has no wire analog and is
  dropped. Both are documented in `mkAnthropicOutputConfig`, but a caller
  comparing request bytes across vendors will see the difference.
- Since baikai 0.6.0.0 the schema, its name and the `strict` flag live on a
  `JsonSchemaFormat` record inside the `JsonSchema` constructor rather than
  directly on it. As fields of a sum they were partial selectors: `name f` on a
  `JsonObject` crashed instead of failing to typecheck. Build one with
  `jsonSchemaFormat name schema` (which sets `strict = False`) and set `strict`
  by record update; the JSON encoding is unchanged.
- Schema support varies by host. Every OpenAI-compatible host reachable through
  [CAP-14](openai-chat-completions-backend.md) accepts the field syntactically;
  whether it *enforces* the schema is the host's business and is not something
  baikai can report.
