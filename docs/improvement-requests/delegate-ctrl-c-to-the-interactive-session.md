---
type: Improvement Request
title: Delegate Ctrl-C to the interactive session
description: >-
  Make the interactive launchers ignore SIGINT in the calling process for the duration of
  the session, so the terminal's Ctrl-C reaches the agent it was aimed at instead of
  killing the launching tool and orphaning the agent.
timestamp: 2026-08-11T19:22:02Z
requestId: IR-5
status: proposed
origin: mori://shinzui/okf
---

# Improvement Request: Delegate Ctrl-C to the Interactive Session

## Status

Proposed. It is a blocker for the abstraction, not for the feature: the assist refactor in
`mori://shinzui/okf/plans/56-configure-the-assist-agent-per-command-including-reasoning-effort`
adopts Baikai's command *builders* and keeps its own `System.Process` spawn, because
adopting the launchers as they stand would regress a behaviour okf has shipped since its
assist command existed. Every vendor flag now lives in Baikai, which is the part that
matters; process control is the one thing okf still cannot delegate.

## Context

`Baikai.Provider.Claude.Interactive.launchClaudeInteractive` and
`Baikai.Provider.OpenAI.Interactive.launchCodexInteractive` exist to start a real terminal
session and return when it exits. Both inherit the calling process's stdin, stdout, and
stderr, so the agent owns the terminal. Neither arranges for the calling process to stop
owning the terminal's signals.

- The Claude launcher runs through `Cradle.run`. `Cradle.ProcessConfiguration` carries a
  `delegateCtlc` field that defaults to `False`, and cradle exports
  `setDelegateCtrlC` to flip it — but `launchClaudeInteractive` composes only `addArgs`
  and `setWorkingDir`, so the default stands and the caller has no seam to change it.
- The Codex launcher builds a `System.Process.proc` spec, sets `std_in`, `std_out`,
  `std_err` to `Inherit` and `cwd`, and does not set `delegate_ctlc`, which also defaults
  to `False`.

A terminal sends SIGINT to every process in the foreground process group, which is the
launching program *and* the agent it started. With delegation off, GHC's runtime turns
that signal into an asynchronous `UserInterrupt` in the launching program's main thread.
The launching program dies; the agent, which handles SIGINT itself and treats it as
"interrupt the current turn", survives with no parent and still attached to the terminal.

This is not a theoretical reading of the flag. Measured with a stand-in child that traps
SIGINT and keeps running, spawned by a Haskell parent under a group-directed
`kill -INT`, varying nothing but `delegate_ctlc`:

```text
$ mode=nodelegate
CHILD: got SIGINT, staying alive
PARENT exit status: 130          # parent killed, child orphaned

$ mode=delegate
CHILD: got SIGINT, staying alive
CHILD: exiting normally
PARENT: child exited with ExitSuccess
PARENT exit status: 0
```

The failure is worst in exactly the case the launchers are for. Interrupting a turn is
routine in an interactive coding session — it is how a user redirects an agent that has
started down the wrong path. Under the current behaviour the first such interrupt destroys
the launching process, so a tool that wraps a session cannot do anything after it: no exit
status to propagate, no cleanup, no "session ended" summary. `System.Process`'s own
documentation names this case directly, recommending `delegate_ctlc` "for interactive
console processes".

## Requested contract

The interactive launchers must, for the duration of the session, leave SIGINT to the
session:

1. SIGINT and SIGQUIT are ignored in the calling process while the child runs, and the
   prior handlers are restored when it exits. Setting `delegate_ctlc = True` on the Codex
   spawn and composing cradle's `setDelegateCtrlC` on the Claude one both achieve this;
   this request does not prescribe which, only that both launchers agree.
2. A child that is itself terminated by SIGINT is reported to the caller as an interrupt
   rather than silently as a plain non-zero exit — the behaviour `System.Process` already
   provides, which raises `UserInterrupt` in the parent once the child has died of it.
3. The behaviour is the default. A caller who wants a session to own the terminal has
   already said so by choosing an interactive launcher; making them opt in again would
   mean every consumer independently rediscovers this, which is how okf found it.

If a caller with a genuine need to keep its own SIGINT handling must be served, that is an
opt-*out* on the launcher's config record, not an opt-in.

## Acceptance

This request is complete when:

1. Both interactive launchers ignore SIGINT in the calling process while the session runs
   and restore the previous disposition afterwards.
2. A test demonstrates that a group-directed SIGINT during a launched session leaves the
   launching process alive and able to observe the child's exit status — the
   `nodelegate`/`delegate` comparison above, as an automated check.
3. The user documentation for the interactive surface states that the session, not the
   caller, receives Ctrl-C, because a caller that has installed its own handler needs to
   know it will not fire.
4. `mori://shinzui/okf` can delete its own `System.Process` spawn and call
   `launchClaudeInteractive` / `launchCodexInteractive` with no change in observable
   behaviour.

## Non-goals

This request does not cover the batch completion providers (`claude -p`, `codex exec`) or
the unattended agent surface. Those do not hand the terminal to a child, and a caller
interrupting them reasonably means "stop the whole run", which is what happens today.

It does not ask for SIGTERM, SIGHUP, or window-resize forwarding, for process-group or
session-leader control (`setsid`), or for any change to how the launchers report a
non-zero exit code.

## References

- `mori://shinzui/baikai/packages/baikai-claude` — `Baikai.Provider.Claude.Interactive.launchClaudeInteractive`
- `mori://shinzui/baikai/packages/baikai-openai` — `Baikai.Provider.OpenAI.Interactive.launchCodexInteractive`
- `mori://garnix-io/cradle` — `Cradle.ProcessConfiguration.delegateCtlc` (defaults to
  `False`), `Cradle.ProcessConfiguration.Helpers.setDelegateCtrlC`
- `mori://shinzui/okf/plans/56-configure-the-assist-agent-per-command-including-reasoning-effort`
  — the consumer, and the `System.Process` spawn it retains because of this gap
- [IR-4](./distinguish-replacing-a-system-prompt-from-appending-to-one.md) — the other gap
  the same adoption surfaced, also worked around rather than absorbed
