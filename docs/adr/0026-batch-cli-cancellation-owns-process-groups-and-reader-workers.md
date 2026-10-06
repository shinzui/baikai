---
title: Batch CLI cancellation owns process groups and reader workers until cleanup finishes
status: accepted
date: 2026-10-06
---

# Batch CLI cancellation owns process groups and reader workers until cleanup finishes

## Context

`claudeCliProvider` and `codexCliProvider` turn one subprocess invocation into a
model response. Their synthetic stream runs the same blocking invocation before
replaying events. Cancelling the thread executing either call previously left
background children alive and could block closing a pipe held by a reader. The
optional executable-version probe is another subprocess owned by that call.
[BUG-1](../bug-reports/batch-cli-cancellation-leaves-child-alive.md) records the
released defect; [plan 90](../plans/90-terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation.md)
records its implementation and verification.

The process library's `cleanupProcess` terminates only the direct child and forks
a reaper. It neither stops descendants nor joins that reaper. A saved numeric
process-group identifier is also insufficient ownership: after the leader is
reaped and all members disappear, the identifier can be reused by another group.

## Decision

Core's internal `Baikai.Provider.Cli.Process.Internal` owns the process lifecycle
for both batch adapters and executable-version probes. Each POSIX invocation
starts in a new group. Before giving its process handle to a callback, a small C
helper forks an anchor and the parent establishes its membership with `setpgid`.
The child uses only async-signal-safe operations after fork, ignores SIGINT and
SIGTERM, closes inherited descriptors, and parks. No Haskell code runs in that
child. This avoids the multi-capability restrictions of Haskell `forkProcess`.

The anchor stays unreaped through every group signal and final observation. Even
a killed anchor retains group membership as a zombie until it is reaped, so the
callback can collect the CLI leader's exit status without losing group ownership.
Once signalling is finished, the scope synchronously reaps both direct children.

Reader workers live in nested owned scopes. Each publishes its result or exception,
and release cancels and joins an unfinished worker before outer pipe closure.
Reader failures propagate through the join; they cannot become empty stderr.
Process and worker release run in private masked workers that always publish
completion, including on failure. The caller joins them while remembering the
first asynchronous exception and ignoring subsequent cancellation attempts until
cleanup has finished. The callback itself remains interruptible. Cancellation
arriving after callback success still propagates after cleanup.

Group cleanup sends SIGINT, SIGTERM, then SIGKILL, with monotonic grace periods of
100 and 500 milliseconds and a one-second settling allowance after SIGKILL.
Darwin and Linux `/bin/ps` process states distinguish live members from zombies.
A zombie has stopped running even if a null signal still reports existence.
Observation errors, permission errors, and unexpected live survivors are cleanup
failures. If cancellation was already received, its original asynchronous
exception is retained and a cleanup failure is diagnosed on stderr. Otherwise
cleanup failure propagates synchronously. Darwin can report permission errors
when signalling a zombie-only group: after verified termination, cleanup reaps
rather than signalling the dead group again.

## Consequences

Ordinary cancellation finishes only after owned group members have stopped,
reader workers have finished, and both direct children have been reaped. This
also covers active consumption of the synthetic stream and version-probe timeout.
It adds one private anchor process per POSIX scope and requires `/bin/ps`.

Descendants that deliberately change group or session escape this scope. It is
lifecycle ownership, not process confinement. Baikai cannot reap adopted
grandchildren; their parent or the operating system does that. A process stuck
in uninterruptible kernel I/O prevents an unconditional time bound on reaping.
Windows retains explicit direct-child cleanup and has no descendant guarantee.

Callers cancel a running complete call or actively consuming stream; simply
abandoning an unevaluated stream starts no subprocess. Applications retain the
[threaded-runtime requirement](0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md)
and [explicit byte encoding](0007-text-crossing-a-process-boundary-is-encoded-explicitly.md).
[The stream cancellation decision](0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md)
covers HTTP workers separately. Foreground interactive launchers and the
unattended agent runner remain separate lifecycle surfaces.
