---
title: "Batch cancellation with owned subprocess cleanup"
type: Capability
description: "Cancel a running batch CLI request and have owned POSIX process-group members stopped, pipe readers joined, and direct children reaped before the original asynchronous exception propagates."
generated:
  by: codex/gpt-6
  at: "2026-10-10T23:26:03Z"
capabilityId: CAP-25
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.7.1.1"
packages:
  - baikai-claude
  - baikai-openai
  - baikai
interface:
  - Baikai.Provider.Claude.Cli
  - Baikai.Provider.OpenAI.Cli
requires:
  - CAP-15
evidence:
  - kind: test
    resource: baikai/test/CliProcessSpec.hs
    proves: "Owned-group escalation, leader and anchor reaping, joined readers, repeated cancellation, and version-probe timeout."
  - kind: test
    resource: baikai-claude/test/CliCancellationSpec.hs
    proves: "Public Claude complete, active synthetic-stream consumption, and evidence probes acknowledge cancellation only after owned descendants stop."
  - kind: test
    resource: baikai-openai/test/CliCancellationSpec.hs
    proves: "Public Codex cancellation, repeated cancellation, active streams, and evidence probes stop descendants; the schema remains available through cleanup."
  - kind: guide
    resource: docs/user/cli-providers.md
    proves: "The runtime requirements, cancellation operation, release versions, and platform limits."
---

# Batch cancellation with owned subprocess cleanup

This extends [CAP-15 — subscription-backed batch CLI backends](subscription-cli-backends.md).
Both adapters first provide this guarantee at 0.7.1.1, using `baikai 0.8.0.0`.
Earlier adapters can run a batch request but leave descendants running after
cancellation ([BUG-1](../bug-reports/batch-cli-cancellation-leaves-child-alive.md)).

## Shape

```haskell
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (throwIO)

ClaudeCli.register
finished <- newEmptyMVar
worker <- forkFinally (completeRequest modelWithCliTag ctx opts) (putMVar finished)
killThread worker
result <- takeMVar finished
either throwIO pure result
```

`killThread` requests cancellation; the completion callback records the outcome
after cleanup. Joining that outcome is the completion boundary.

Cancellation during an active complete call or synthetic-stream consumption
stops inherited process-group members, joins readers, and reaps direct children
before propagating the first asynchronous exception. Version evidence probes
use the same scope. Codex deletes its temporary schema after cleanup.

## Limits

- Darwin and Linux cover inherited group members; a process deliberately
  creating another group or session can escape. Windows covers the direct child.
- Adopted descendant zombies have stopped running; their parent or the operating
  system owns their exit statuses. Uninterruptible kernel I/O prevents an
  unconditional reaping time bound.
- POSIX cleanup requires `/bin/ps` and a threaded Haskell runtime.
- An unevaluated synthetic stream starts no batch process. Cancelling a running
  consumer is the verified operation, rather than merely dropping a stream value.
- The five-second version-probe timeout is followed by cleanup, which can take
  additional time. This is a lifecycle guarantee rather than a deadline.
