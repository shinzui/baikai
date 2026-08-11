---
title: "Usage and cost accounting with an opt-in JSONL call log"
type: Capability
description: "Read a disjoint token breakdown and a computed USD cost off every successful call, total them with Monoid instances, and optionally append one JSONL record per call to disk through a background writer that never pads the apparent latency of the call itself."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-7
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai.Usage
  - Baikai.Cost
  - Baikai.Cost.Pricing
  - Baikai.Cost.Log
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/UsageSpec.hs
    proves: "Usage is a lawful monoid whose numeric fields add and whose reasoningTokens combine presence-wins, and totalTokens sums the disjoint billed classes without double-counting reasoning tokens."
  - kind: test
    resource: baikai/test/CostSpec.hs
    proves: "computeCost is deterministic for a catalogued model, bills cache-read and cache-write tokens exactly once each, yields zero for an unknown model, and the call log writes one JSONL record per call, skips disk I/O when disabled, and still returns from closeCallLog when the log path is unwritable."
  - kind: module
    resource: baikai/src/Baikai/Cost/Log.hs
    proves: "The call-log lifecycle: withCallLog, the Chan-plus-worker design that keeps disk latency off the request path, and the single-warning failure policy."
---

# Usage and cost accounting with an opt-in JSONL call log

Every successful call returns a `Usage` carrying input, output, cache-read,
cache-write, and reasoning token counts, plus a `Cost` computed from the
`Model`'s per-million-token rates. The token classes are **disjoint** by
convention: a host that reports OpenAI-style inclusive prompt counts has its
cached tokens subtracted out of `inputTokens` on the way in, so summing the
classes never double-counts.

`Usage`, `Cost`, and `CostBreakdown` are monoids that add field by field, and
`sumUsage` totals a `Foldable` of them, so per-call values roll up to a session
or a tenant without a hand-written fold.

`Baikai.Cost.Log` adds an opt-in JSONL sink: each open handle owns a channel and
a worker thread, `appendEntry` is a cheap channel push, and the worker drains to
disk. Disk latency therefore never pads the apparent latency of
`completeRequest`, and a log file that cannot be opened or written produces one
stderr warning on close rather than masking the request or hanging the release.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
withCallLog (CallLogConfig "/tmp/baikai.jsonl" True) $ \h ->
  runRequestWithLog h model ctx opts
```

## Limits

- **A cost of zero now means zero, not "unpriced".** Before 0.5.0.0 a
  zero-valued cost was omitted, which made "this call was free" and "baikai could
  not price this call" indistinguishable. A dashboard written against the old
  behaviour will now count subscription-backed CLI calls as costing zero rather
  than treating them as unpriced.
- An uncatalogued model prices at zero. Cost is computed from the `Model` record
  you passed, so a hand-rolled model with no rates silently produces no cost.
- Prices come from the catalog snapshot ([CAP-3](generated-model-catalog.md)) and
  are an accounting estimate. The provider's invoice is the authority.
- The `claude -p` transport is the only one that reports a vendor-computed cost
  (`total_cost_usd`); everywhere else the USD figure is baikai's own
  multiplication.
- Before 0.5.0.0 both subprocess providers hardcoded zero usage. Totals over
  historical data collected on an older release will not reconcile with totals
  over new data.
- The log is append-only JSONL with no rotation, no size bound, and no schema
  version. Operating the file is the consumer's job.
