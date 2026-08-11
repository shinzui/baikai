---
okf_version: "0.2"
---

# baikai capabilities

What the **baikai** family provides to a consumer today: what a Haskell project
can depend on, adopt, and verify against evidence it can open. Each record is one
capability — one thing a consumer adopts *and* verifies independently — backed by
at least one artifact (a test, a worked example, a module, or a guide) that a
reader can open. There is no roadmap here: a capability that does not yet exist
is an improvement request, not a record.

baikai is a unified Haskell interface for working with multiple AI providers. It
ships as eight packages that version independently, so `since` below names **the
version of the first package listed in that record** — the one whose release
gates availability. Comparing `since` across records is only meaningful within a
package; the package column says which one.

## Reading `stability`

Most records are `stable`, which here means exactly what the profile defines:
**breaking changes arrive with a PVP-major bump.** It does not mean the surface
is settled. baikai is pre-1.0 and every release train since 0.1 has carried
breaking changes to the core — they are enumerated in `CHANGELOG.md` and each one
took a major bump. A consumer should expect to read the changelog on every
upgrade and should pin accordingly.

Four records are `experimental` because their surface is genuinely outside that
promise: `baikai-agent` (CAP-17, CAP-18) is at 0.1.0.0 and has not been through a
compatibility cycle, `baikai-kit` (CAP-21) is at 0.1.0.x, and model-call evidence
(CAP-19) rests substantially on `Baikai.Provider.Cli.Internal`, which is
documented as outside the PVP contract.

## What baikai provides

| Capability | Handle | Package | Since | Provides |
|---|---|---|---|---|
| [Provider-neutral model calls with registry dispatch](unified-provider-calls.md) | CAP-1 | `baikai` | 0.1.0.0 | One blocking call routed by the `Model`'s `Api` tag |
| [Typed incremental streaming](typed-streaming.md) | CAP-2 | `baikai` | 0.1.0.0 | The `AssistantMessageEvent` algebra with exactly one terminal |
| [Generated model catalog and its refresh pipeline](generated-model-catalog.md) | CAP-3 | `baikai` | 0.1.0.0 | A ready-made `Model` per shipped model, regenerable and pinned |
| [Typed tool calling and the two-turn round trip](tool-calling.md) | CAP-4 | `baikai` | 0.1.0.0 | Verbatim JSON Schema tools, `ToolChoice`, and `runToolLoop` |
| [Provider-neutral structured output](structured-output.md) | CAP-5 | `baikai` | 0.1.1.0 | One `ResponseFormat` onto both vendors' schema primitives |
| [Text embeddings over an OpenAI-compatible endpoint](text-embeddings.md) | CAP-6 | `baikai` | 0.1.1.0 | A small policy-free `/v1/embeddings` client |
| [Usage and cost accounting with an opt-in JSONL call log](usage-and-cost-accounting.md) | CAP-7 | `baikai` | 0.1.0.0 | Disjoint token classes, computed cost, off-path disk logging |
| [Categorised error model with retry classification](categorised-error-model.md) | CAP-8 | `baikai` | 0.2.0.0 | Nine categories, status, `Retry-After`, `isRetryable` |
| [Call tracing through a pluggable TraceSink](call-tracing.md) | CAP-9 | `baikai` | 0.1.0.0 | A composable streamly-fold sink over the call lifecycle |
| [OpenTelemetry span export](opentelemetry-span-export.md) | CAP-10 | `baikai-trace-otel` | 0.1.0.0 | One OTel span per call with GenAI semantic-convention attributes |
| [Cross-provider reasoning-effort control](reasoning-effort-control.md) | CAP-11 | `baikai` | 0.1.0.0 | One canonical level translated per transport, clamps recorded |
| [Prompt-cache retention control and cache accounting](prompt-cache-retention.md) | CAP-12 | `baikai` | 0.1.0.0 | A retention preference with host-aware downgrade and cache token split |
| [Anthropic Messages API backend](anthropic-messages-backend.md) | CAP-13 | `baikai-claude` | 0.1.0.0 | The Anthropic Messages provider over SSE |
| [OpenAI Chat Completions backend, including any OpenAI-compatible host](openai-chat-completions-backend.md) | CAP-14 | `baikai-openai` | 0.1.0.0 | One handler for OpenAI and every compatible host, quirks auto-detected |
| [Subscription-backed batch CLI backends](subscription-cli-backends.md) | CAP-15 | `baikai-claude`, `baikai-openai` | 0.1.0.0 | `claude -p` and `codex exec` as subprocess providers |
| [Interactive agent-session launches](interactive-launches.md) | CAP-16 | `baikai` | 0.1.0.0 | Real Claude Code / Codex sessions, inexpressible safety refused |
| [Unattended coding-agent runs](unattended-agent-runs.md) | CAP-17 | `baikai-agent` | 0.1.0.0 | No terminal, no human: capability profile, ceiling, process runner |
| [The `baikai agent` command and layered KDL job configuration](baikai-agent-command.md) | CAP-18 | `baikai-agent` | 0.1.0.0 | One stable command; provider and policy live in KDL, not the script |
| [Verifiable model-call evidence](model-call-evidence.md) | CAP-19 | `baikai` | 0.5.0.0 | What actually crossed the boundary, with two digests and honest strength |
| [effectful binding for the transport](effectful-binding.md) | CAP-20 | `baikai-effectful` | 0.1.0.0 | A dynamic `Baikai` effect with three operations and swappable interpreters |
| [Kit installer for agent skills and subagents](kit-installer.md) | CAP-21 | `baikai-kit` | 0.1.0.1 | The shared `kit` command lifecycle for git-hosted agent assets |
| [Provider-native agent-asset layouts](agent-asset-layouts.md) | CAP-22 | `baikai` | 0.1.0.0 | Pure path rules for where each tool discovers skills and agents |

## Deliberately excluded

These surfaces exist in the repository but are **not** capability records, with
the reason under the three rules (evidence; provision-not-composition; one
independently-adopted-and-verified thing):

- **`baikai-smoke`** — the live smoke suite is internal, unpublished, and
  consumed here as *evidence* for other capabilities rather than as something a
  consumer adopts. The README describes it as useful worked examples, which is
  how the records cite it.
- **`Baikai.Prelude`** — a convenience re-export of `lens` + `generic-lens`,
  explicitly documented as outside the PVP stability contract. It is an ergonomic
  shortcut inside CAP-1, not a capability.
- **`.Internal` modules** (`Baikai.Provider.Cli.Internal`,
  `Baikai.Provider.*.Internal.*`) — exposed for provider tests and debugging with
  no compatibility guarantee. They are cited as evidence and named in limits, but
  a consumer does not adopt them.
- **`baikai-fetch-models` / `baikai-gen-models`** — not separate records. They are
  the refresh pipeline *of* CAP-3 and nobody adopts them without the catalog.
- **Composition claims** — anything true only when baikai cooperates with a
  separate repository (`mori://shinzui/seihou`'s launch integration, for
  instance) belongs to the consuming repository as a use-case feature, not here
  (rule 2).

## Evidence discipline

`evidence[].resource` paths are repository-wide and are not checked by `okf`;
every path in this bundle was confirmed to exist at authoring time. The strongest
evidence is the offline test surface, which is substantial: request shaping,
event reassembly, error classification, policy algebra, and argument-vector
rendering are all proven without contacting a provider or spawning a coding
agent.

Two honest weaknesses run through the catalog and are repeated in the records
that own them:

- **Live behaviour is under-proven by construction.** Everything that requires a
  real provider lives in `baikai-smoke`, which skips when API keys are absent, or
  in gated cases like `EmbeddingSpec`'s `BAIKAI_EMBEDDING_LIVE`. A default
  `cabal test all` proves the mappings, not the round trips.
- **CAP-6 (text embeddings) is the weakest record here.** One hermetic
  request-mapping test, a live test that does not run by default, no smoke case,
  and no user guide — the module header is its documentation. The record says so.
