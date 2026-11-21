---
type: Friction Entry
title: "Inherited OPENAI_KEY causes an offline embedding test to print its value"
description: "The core offline gate needs a clean OpenAI environment because the embedding assertion can render the inherited credential on failure."
generated:
  by: "codex-cli/gpt-6.2-sol"
  at: "2026-11-21T04:24:08Z"
frictionId: FRIC-10
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/baikai"
affects: "mori://shinzui/baikai"
plan: "docs/plans/105-guard-unsupported-assistant-prefills-on-claude-messages-and-enable-fable-5-2.md"
workaround: "Run the offline Cabal gate with env -u OPENAI_KEY -u OPENAI_API_KEY and keep console output limited to suite status."
---
# Inherited OPENAI_KEY causes an offline embedding test to print its value

## Attempted

Run cabal test baikai:baikai-test baikai-claude:baikai-claude-test from the development shell.

## Encountered

An embedding test sets OPENAI_API_KEY to a fixture value, but resolution prefers the inherited OPENAI_KEY. The failure printed the resolved value.

```text
EmbeddingSpec.hs:80 expected its fixture key and received the inherited credential [redacted].
```

## Workaround

Run the offline Cabal gate with env -u OPENAI_KEY -u OPENAI_API_KEY and keep console output limited to suite status.
