---
title: Judgments are a provider-neutral core protocol with catalog-owned capability facts
status: accepted
date: 2026-10-25
---

# Judgments are a provider-neutral core protocol with catalog-owned capability facts

## Context

Closed-set judgment dialects share predicates, choices and ordered scores, while differing in their wire layouts and supported input parts. Routing and schema validation must be consistent across adapters.

## Decision

`Baikai.Judgment` owns closed-set schema compilation, context-shape checks, the generation-control audit and answer validation. `prepareJudgment` checks context, options and schema in that order. Adapters own input parts, content encoding, wire numbers and protocol-specific reply checks. Only the neutral validator builds judgment `DataContent`. Provider-reported selection, confidence and expected score are preserved. Probabilities need not sum to one; there is no normalization. A dialect without an expected score uses the largest-probability level, with ties resolved to the lowest index.

Question order is a complete, unique schema `required` array when present, otherwise ascending property key. Score levels are ordered numerically regardless of schema order. The compiler rejects unsupported validation keywords rather than claiming to enforce them. Instructions and descriptions remain JSON values so a dialect can refuse narrower content shapes by path.

`Model.outputKind` is a catalog fact, queried by `isJudgmentOnly`; it is never inferred from provider names, API tags or model prefixes. Missing output kind in legacy JSON defaults to generative. `InputData` is an explicit modality. Unknown catalog limits remain zero (unknown) and unknown token prices retain unavailable estimates.

Every explicit generation, reasoning, speed and tool-choice control is refused before dispatch. Absent controls and explicit `CacheRetentionNone` pass. Transport, local metadata and evidence options remain available. A routing consumer clears its generation defaults for judgment-only models before calling.

## Consequences

A second judgment adapter adds wire mapping and transport without duplicating the compiler or validator. The public core API grows sums, model fields and a new module, requiring a PVP major increment. Provider response refusals remain content refusals, separate from typed unsupported request features.
