---
id: 18
slug: redact-and-source-api-credentials-safely
title: "Redact and Source API Credentials Safely"
kind: exec-plan
created_at: 2026-06-05T02:57:11Z
master_plan: "docs/masterplans/4-initial-api-hardening-before-0-1.md"
---

# Redact and Source API Credentials Safely

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, downstream users can pass provider credentials to Baikai without risking accidental secret exposure through `Show`, JSON logging, traces, or test failure output. The current API stores `Options.apiKey` as `Maybe Text` and derives `Show` and `ToJSON` for the whole `Options` record. That means a bearer token can appear in ordinary debug output or serialized options. This plan replaces that public shape with a redacted credential source and updates providers to resolve credentials explicitly at call time.

The behavior is visible in tests: rendering `_Options` or an options value with a literal secret must show a redacted placeholder, JSON encoding must not include the raw secret, and provider calls must still support both explicit literal credentials and environment-variable fallbacks.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Audit all reads and writes of `Options.apiKey`. Completed 2026-06-05. `rg -n "apiKey|ApiKeySource|resolveApiKey" baikai baikai-openai baikai-claude baikai-smoke docs README.md` found the public field in `baikai/src/Baikai/Options.hs`, provider key resolution in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, tests in `baikai/test/Main.hs`, smoke tests in `baikai-smoke/test/`, and user docs under `docs/user/`.
- [x] Introduce the final credential source type and redacted display/JSON behavior. Completed 2026-06-05. `Baikai.Auth.ApiKeySource` now has redacted `Show` and `ToJSON` instances, `renderApiKeySourceForDebug`, and `Options.apiKey :: Maybe ApiKeySource`.
- [x] Update OpenAI and Claude providers to resolve the new credential source. Completed 2026-06-05. Both API providers now pass explicit sources through `resolveApiKey` and still fall back to `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`.
- [x] Update tests, smoke tests, docs, and examples to use the new API. Completed 2026-06-05. Core tests cover `Show` and JSON redaction, smoke tests wrap explicit keys in `ApiKeyLiteral`, and README/user docs describe explicit credentials through `ApiKeyLiteral`.
- [x] Validate with focused tests and the full package test suite. Completed 2026-06-05. `nix develop --command cabal test baikai-test baikai-openai-test baikai-claude-test` and `nix develop --command cabal test all` both completed successfully.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: `Data.ByteString.Lazy.Char8` does not export `isInfixOf` in this environment, so the JSON redaction assertion decodes the encoded bytestring as Char8 text and uses `Text.isInfixOf`.
  Evidence: the first focused test run failed at `test/Main.hs:94:48` with `Not in scope: 'LBS8.isInfixOf'`; after changing the assertion, the focused and full suites passed.
  Date: 2026-06-05
- Discovery: The full suite exercised the OpenAI smoke path with a locally available `OPENAI_API_KEY`, while Anthropic API-key-dependent smoke cases skipped because no Anthropic key was set.
  Evidence: `nix develop --command cabal test all` reported `gpt-4o-mini ok via OPENAI_API_KEY`, skipped Anthropic key cases, and ended with all test suites passing.
  Date: 2026-06-05


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat raw secret serialization as a release-blocking API flaw.
  Rationale: `Options` is a public type and currently derives both `Show` and `ToJSON`; once released, downstream users may rely on that behavior or leak credentials unintentionally.
  Date: 2026-06-05
- Decision: Keep provider environment fallbacks as call-time behavior, not construction-time behavior.
  Rationale: The existing `Baikai.Auth.ApiKeyEnv` design documents lazy lookup, and lazy lookup makes tests and long-lived applications easier to configure.
  Date: 2026-06-05
- Decision: Keep the public `Options.apiKey` field name and change its type to `Maybe ApiKeySource`.
  Rationale: The field name is already familiar to callers and keeping it minimizes migration churn, while the changed type forces explicit literal or environment-sourced credentials before the first public release.
  Date: 2026-06-05
- Decision: Re-export `Baikai.Auth` from the umbrella `Baikai` module.
  Rationale: Users who import `Baikai` should be able to write the documented `#apiKey .~ Just (ApiKeyLiteral key)` update without adding a second import solely for the credential constructor.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-06-05. `Options.apiKey` no longer accepts raw `Text`; it accepts `Maybe ApiKeySource`, whose literal constructor redacts secret material in `Show` and JSON output while still resolving to raw `Text` only inside provider call preparation. OpenAI and Claude API providers preserve call-time environment fallback behavior, smoke tests use `ApiKeyLiteral` for explicit local keys, and docs now show the safer explicit credential form. The focused provider/core test command and the full `cabal test all` command both pass.


## Context and Orientation

The core package is under `baikai/`. The public per-call options live in `baikai/src/Baikai/Options.hs`. Today that module defines:

```haskell
data Options = Options
  { maxTokens :: !(Maybe Natural)
  , temperature :: !(Maybe Double)
  , apiKey :: !(Maybe Text)
  , timeoutMs :: !(Maybe Int)
  , headers :: !(Map Text Text)
  , metadata :: !(Map Text Value)
  , toolChoice :: !(Maybe ToolChoice)
  , cacheRetention :: !(Maybe CacheRetention)
  , thinking :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)
```

The provider packages read this field in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Each provider has a `resolveKey` helper that currently uses the raw `Text` when present and otherwise calls `Baikai.Auth.resolveApiKey` with an environment variable name.

`baikai/src/Baikai/Auth.hs` already defines `ApiKeySource = ApiKeyLiteral Text | ApiKeyEnv String` and `resolveApiKey`. The module documentation says providers accept an `ApiKeySource`, but the public `Options` type does not yet use it. This plan should reconcile those modules into one public credential story.

Smoke tests currently set explicit credentials by updating `#apiKey` with `Just (Text.pack key)`. Relevant files include `baikai-smoke/test/Smoke.hs`, `baikai-smoke/test/ToolsSmoke.hs`, and `baikai-smoke/test/MultiHostSmoke.hs`.


## Plan of Work

Milestone 1 defines the credential type. In `baikai/src/Baikai/Auth.hs`, keep or refine `ApiKeySource` as the public source type. Add safe instances or helper functions so literal secrets never appear in `Show` output and never appear in JSON output. A reasonable target is:

```haskell
data ApiKeySource
  = ApiKeyLiteral !Text
  | ApiKeyEnv !String

renderApiKeySourceForDebug :: ApiKeySource -> Text
```

The exact JSON policy should be conservative. If `Options` keeps a `ToJSON` instance, encode only `"literal-redacted"` for literal credentials and the environment variable name for env credentials, or omit the field entirely when a credential is present. Do not encode the secret text.

Milestone 2 changes `Options`. In `baikai/src/Baikai/Options.hs`, replace `apiKey :: Maybe Text` with `apiKey :: Maybe ApiKeySource` or a more explicitly named field such as `apiKeySource :: Maybe ApiKeySource`. If the field is renamed, provide an intentional migration path and update every use. Replace derived `Show` or `ToJSON` for `Options` with manual instances if deriving would reveal secrets.

Milestone 3 updates providers. In `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, update `resolveKey` to accept `Options` with the new credential source. Existing environment-variable fallback behavior must remain: OpenAI falls back to `OPENAI_API_KEY`, Claude falls back to `ANTHROPIC_API_KEY`.

Milestone 4 updates tests and docs. Update core tests in `baikai/test/Main.hs` or add a focused `AuthSpec`/`OptionsSpec` proving that secret values do not appear in `show` or `Aeson.encode`. Update smoke tests to use `ApiKeyLiteral (Text.pack key)` or the final constructor. Update user docs that mention `apiKey`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
```

Find every call site before editing:

```bash
rg -n "apiKey|ApiKeySource|resolveApiKey" baikai baikai-openai baikai-claude baikai-smoke docs README.md
```

After implementing the type and provider changes, run focused tests first:

```bash
nix develop --command cabal test baikai-test baikai-openai-test baikai-claude-test
```

Then run the full suite:

```bash
nix develop --command cabal test all
```

Expected success is that all unit tests pass and smoke tests either pass or skip based on the caller's local environment.


## Validation and Acceptance

Acceptance requires all of the following:

An options value with a literal secret does not reveal that secret through `show`. Add a test that constructs an options value with a recognizable string such as `"sk-baikai-secret-never-print"` and asserts that the string is not contained in `show opts`.

An options value with a literal secret does not reveal that secret through `Aeson.encode`. The test should assert that the encoded bytes do not contain the recognizable secret string.

OpenAI and Claude provider key resolution still works for explicit literal credentials. This can be unit-tested at the `resolveKey` helper level if it is made testable, or exercised through existing smoke tests when keys are present.

OpenAI and Claude environment-variable fallbacks still work. The provider behavior should remain documented: OpenAI falls back to `OPENAI_API_KEY`; Claude falls back to `ANTHROPIC_API_KEY`.

The command:

```bash
nix develop --command cabal test all
```

must complete successfully.


## Idempotence and Recovery

All edits are source-level and can be repeated safely. If the migration becomes too broad, first introduce the new credential type alongside the old field, update providers and tests, then remove the old field in a final commit. Do not remove environment fallback behavior while refactoring; that fallback is part of the current public behavior.


## Interfaces and Dependencies

This plan uses only existing dependencies: `text`, `aeson`, and the provider packages already in the Cabal files. It should not add new packages.

At the end, `baikai/src/Baikai/Auth.hs` must expose a credential source type with redacted display/serialization behavior. `baikai/src/Baikai/Options.hs` must no longer expose `apiKey :: Maybe Text` with derived `Show`/`ToJSON` that can leak secrets. `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs` must resolve credentials through the new source type.
