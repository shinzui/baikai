---
type: Friction Entry
title: "OpenAI cache verification exhausted account quota"
description: "OpenAI rejected the bounded 12h endpoint probe before cache behavior could be observed."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T16:28:31Z"
frictionId: FRIC-3
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/baikai"
affects: "https://developers.openai.com/api/docs/guides/prompt-caching"
plan: "docs/plans/101-cache-shared-openai-prompt-prefixes-with-catalog-gated-controls-and-truthful-accounting.md"
resolution: "The user replenished OpenAI credits; both funded Short shared-prefix checks passed and the Responses 12h probe completed with duration-specific usage."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T16:34:58Z"
    change: "Keep endpoint acceptance and live cache reuse unverified after the bounded quota failure; no retries added."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T16:43:19Z"
    change: "Credits restored; replace the accepted quota limitation with successful funded endpoint evidence."
---
# OpenAI cache verification exhausted account quota

## Attempted

One bounded gpt-6-luna Responses request with request-level 12h TTL and an explicit developer-prefix breakpoint.

## Encountered

HTTP 429 credit_balance_exhausted; no endpoint acceptance or usage was returned.

```text
You have no credits remaining. Add credits to continue using the API.
```
