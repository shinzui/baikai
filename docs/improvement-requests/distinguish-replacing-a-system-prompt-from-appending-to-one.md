---
type: Improvement Request
title: Distinguish replacing a system prompt from appending to one
description: >-
  Give the neutral systemPrompt field an explicit replace-or-append mode, so one value stops
  meaning "displace the agent's own system prompt" on Claude surfaces and "prepend a labelled
  block to the user turn" on Codex surfaces.
timestamp: 2026-08-11T19:03:59Z
requestId: IR-4
status: proposed
origin: mori://shinzui/okf
---

# Improvement Request: Distinguish Replacing a System Prompt from Appending to One

## Status

Proposed. Not a blocker: the assist refactor in
`mori://shinzui/okf/plans/56-configure-the-assist-agent-per-command-including-reasoning-effort`
ships without it by bypassing the neutral field. It is a request to remove the reason that
bypass exists, before a second consumer invents a second one.

## Context

Baikai's subprocess surfaces carry one neutral system-prompt field: `systemPrompt` on
`Baikai.Interactive.InteractiveLaunchRequest` for the interactive launchers, and
`systemPrompt` on the completion `Context` for the batch providers. Four renderers consume
it, and they divide cleanly in two:

- `Baikai.Provider.Claude.Interactive` and `Baikai.Provider.Claude.Cli` both render
  `["--system-prompt", text]`.
- `Baikai.Provider.OpenAI.Interactive` (through `codexInteractivePrompt`) and
  `Baikai.Provider.OpenAI.Cli` both render nothing, and instead route the text through
  `Baikai.Provider.Cli.Internal.wrapSystemPrompt`, which prepends
  `"System instructions:\n<text>\n\nUser request:\n"` to the prompt body.

Both renderings are correct for their vendor. Verified against installed binaries:
`claude --help` exposes `--system-prompt <prompt>` ("System prompt to use for the session")
*and* `--append-system-prompt <prompt>` ("Append a system prompt to the default system
prompt"); `codex --help` exposes neither, only a positional `[PROMPT]`. The Codex wrap is
the only thing that surface can do, and its docstring says so.

The problem is what the two correct renderings mean *to a caller who set one field*. Both
vendors ship a substantial default system prompt — the agent harness that makes
`claude` and `codex` coding agents rather than bare chat loops. On the Claude surfaces,
`--system-prompt` **displaces** that harness prompt. On the Codex surfaces, the wrap
**leaves it fully intact** and prepends a labelled block to the user's first turn. So a
caller who sets `systemPrompt = Just "be concise"` and switches provider does not get a
milder or stronger version of the same thing; they get two materially different sessions,
one of which has had its agent harness removed. Nothing in the type says which they will
get.

This is the same class of problem ADR 0002 addresses for model identity: a caller reading
a single field reasonably believes it means one thing, and the value they are reading was
produced by a different rule than they assumed. Here the divergence is in the request
direction rather than the response direction, and it is invisible rather than merely
unrecorded.

There is also a capability gap on the Claude side. Claude exposes an append flag; the
neutral type cannot express it, so a caller who wants to *add* to the agent harness prompt
— the common case for a tool layering domain instructions onto a general coding agent —
has no way to ask for it. `mori://shinzui/okf` has appended since its assist command
shipped, and its Baikai adoption therefore has to smuggle `["--append-system-prompt", text]`
through `extraArgs` and set the neutral field to `Nothing`, which defeats the point of the
abstraction and silently breaks the moment a second provider is added.

## Requested contract

Make the mode explicit in the type. The public shape may follow Baikai conventions, but it
must preserve a distinction equivalent to:

```haskell
data SystemPromptMode
  = ReplaceSystemPrompt  -- displace the agent CLI's own default system prompt
  | AppendSystemPrompt   -- add to it, leaving the vendor's default in place

data SystemPromptSpec = SystemPromptSpec
  { mode :: SystemPromptMode,
    text :: Text
  }
```

carried by the interactive launch request and by the completion `Context`, in place of a
bare `Maybe Text`. The mode must be supplied at construction rather than defaulted
silently, so no existing call site changes meaning without an edit.

Rendering per surface:

- **Claude interactive and batch** — `ReplaceSystemPrompt` renders `--system-prompt`,
  which is the current behavior; `AppendSystemPrompt` renders `--append-system-prompt`.
- **Codex interactive and batch** — `AppendSystemPrompt` renders through
  `wrapSystemPrompt`, which is the current behavior and is an honest approximation of
  appending, since the harness prompt survives.
- **Codex, `ReplaceSystemPrompt`** — Codex cannot displace its own system prompt, so this
  is a request the provider cannot express. The launchers already have the right mechanism
  for that case: both return `Either AgentRenderError`, and both already refuse a safety
  policy they cannot honor with `SafetyNotExpressible` rather than dropping it. Refusing
  here would be consistent with that precedent and with the never-silently-downgrade
  principle. The alternative — approximate it with `wrapSystemPrompt` and document the
  approximation — is defensible for a prompt where it is not for a sandbox policy. This
  request does not presume the answer; it asks that the choice be made explicitly and be
  visible to the caller either way, rather than resolved by accident as it is today.

## Acceptance

This request is complete when:

1. A caller can express append and replace independently of provider, on both the
   interactive launch surface and the batch completion surface.
2. Tests pin the rendered argument vector for each mode on each of the four subprocess
   renderers, including that `AppendSystemPrompt` on Claude emits `--append-system-prompt`
   and never `--system-prompt`.
3. `ReplaceSystemPrompt` against a Codex surface has one defined, tested outcome — a
   refusal carrying the provider and the reason, or a documented approximation — and not
   an undocumented one.
4. No existing caller's rendered argument vector changes without an explicit mode change
   at the call site, or the change is called out as breaking in the release notes with the
   migration named.
5. The user documentation states, per provider and per surface, what each mode does to the
   vendor's own default system prompt — specifically that replace on Claude removes the
   coding-agent harness prompt, which is the fact most likely to surprise.

## Non-goals

This request does not cover the HTTP API providers. There the caller supplies the entire
system message and there is no vendor-side default to append to, so the distinction has no
referent and `systemPrompt` already means one unambiguous thing.

It does not ask for the file-valued variants (`--system-prompt-file`,
`--append-system-prompt-file`), for Codex's `AGENTS.md` or configuration-file instruction
mechanisms, or for any change to `wrapSystemPrompt`'s textual format, which is stable and
shared by two providers.

## References

- `mori://shinzui/baikai/packages/baikai` — `Baikai.Interactive.InteractiveLaunchRequest`,
  `Baikai.Provider.Cli.Internal.wrapSystemPrompt`
- `mori://shinzui/baikai/packages/baikai-claude` — `Baikai.Provider.Claude.Interactive`,
  `Baikai.Provider.Claude.Cli`
- `mori://shinzui/baikai/packages/baikai-openai` — `Baikai.Provider.OpenAI.Interactive`,
  `Baikai.Provider.OpenAI.Cli`
- `mori://shinzui/okf/plans/56-configure-the-assist-agent-per-command-including-reasoning-effort`
  — the consumer, and the current `extraArgs` workaround
- `docs/adr/0002-requested-translated-observed-are-never-collapsed.md` — the neighbouring
  principle for response-direction facts
