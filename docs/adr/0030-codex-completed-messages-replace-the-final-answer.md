---
title: Codex completed messages replace the final answer
status: accepted
date: 2026-11-13
---

# Codex completed messages replace the final answer

## Context

`codex exec --json` can emit several complete `agent_message` bodies in one
run. Each is an independent message. Concatenating them corrupts structured
output when commentary and the final answer are independently valid JSON.
[BUG-2](../bug-reports/codex-concatenates-complete-agent-messages.md) and
[plan 103](../plans/103-return-only-the-final-codex-agent-message.md) capture the
reproduction and acceptance criteria. This is distinct from pipe byte chunks,
which can split a single JSONL event across reads.

## Decision

The shared Codex parser keeps the last completed agent message as the answer.
A modern `item` envelope is eligible only when its outer type is
`item.completed` and its item type is `agent_message`. Recognized legacy flat
and `msg`-nested agent messages remain complete messages and follow the same
replacement rule. Started or updated items, reasoning, and tool events cannot
replace the answer.

Selection does not inspect the answer's contents. An empty or malformed final
body replaces earlier valid text. Baikai neither selects an earlier valid JSON
object nor extracts a JSON substring. Schema enforcement belongs to the CLI;
the adapter retains its existing outer-whitespace trim.

Thread identity and token usage are collected independently across the whole
stream. Missing observations remain absent under
[0002](0002-requested-translated-observed-are-never-collapsed.md).
A nonzero exit remains a failure even after an answer was emitted. Completion
and synthetic streaming share this final-answer rule and success evidence
commits to the selected body.

## Consequences

Keep one answer candidate instead of retaining all preceding messages. Preserve
the line assembly algorithm and its bounded copying across byte chunks. No
second answer file, command-line flag, or process scope is needed, so the
[batch cancellation ownership](0026-batch-cli-cancellation-owns-process-groups-and-reader-workers.md)
contract remains in force.

Parser and public-provider tests must include multiple complete messages;
single-message recordings cannot distinguish replacement from concatenation.
Malformed inner answer text must be tested separately from malformed outer
JSONL, whose best-effort skip policy is unchanged.
