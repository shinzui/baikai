---
type: Improvement Request
title: Let a kit item choose tool-only or shared visibility
description: >-
  Make where an installed kit item is visible a declared, per-item choice: tool-only, seen only
  in sessions the owning tool launches, or shared, seen in every Claude Code and Codex session.
  The choice applies in user and project scope. Make both providers honour it, or report
  honestly when one cannot. Today Claude Code items are always tool-only, and Codex items are
  always shared.
timestamp: 2026-10-02T04:15:00Z
requestId: IR-12
status: completed
origin: mori://shinzui/rei
---

# Improvement Request: Let a Kit Item Choose Tool-Only or Shared Visibility

## Status

Completed on 2026-10-02 by
[plan 88](../plans/88-let-a-kit-item-choose-tool-only-or-shared-visibility.md),
implemented as `baikai-kit 0.4.0.0` (publication remains outside this work).
The visibility tests in `baikai-kit/test/Main.hs` and the recorded offline
check establish the seven acceptance criteria:

1. `a manifest item without visibility installs tool-only` checks the
   default Claude placement, absence of a shared link, and sidecar intent.
2. `a shared item links into ~/.claude/skills`, `a project-scope shared item
   uses a relative link`, and `update changes linked content without touching
   the link` cover user/project discovery and unchanged link inode/mtime.
   `shared multi-file agents link the body and resources` covers subagents.
3. `a tool-only Codex skill adds one disabled config entry` and
   `codexSessionArgs re-enables exactly this tool's hidden skills` cover
   hiding and launching. The isolated codex-cli 0.160.0 check in plan 88
   prints zero `vis-check` mentions in a plain session and one with the exact
   returned arguments, without an API call. `a tool-only agent with Codex
   is refused without acceptance` and the acceptance flag/callback test
   cover custom agents, which remain effectively shared.
4. `status reports requested and effective visibility`, the legacy-note
   test, and the status golden cover both output formats and the
   `visibility-broken` condition. `formatVersion` stays 1.
5. The foreign shared directory, owner-naming dangling link, foreign Codex
   skill, and project-name/foreign-agent tests verify refusals before
   provider writes and unchanged foreign bytes.
6. The link-removal test, config text/permission round trip, reused-entry
   test, deleted-link/config repair tests (also with local edits), and
   foreign-asset uninstall test establish ownership and reconciliation.
   Pending-removal and post-content failure tests cover retry recovery.
7. Met with the explicit narrowing recorded in plan 88: a consumer built
   from `kitConfig`, `kitCommandParser`, and `runKit` needs the package bound
   bump only for kit verbs and Claude launches. A consumer that launches
   Codex must also append `codexSessionArgs` to `extraArgs`; without it,
   tool-only skills are hidden in its own sessions. The user guide and
   changelog prominently document this step and list every changed
   constructor. Consumer migrations and Hackage publication are separate.

The original request came from `mori://shinzui/rei` for its
`rei-capture-session` skill. [ADR 0025](../adr/0025-kit-visibility-is-honoured-per-provider-or-refused.md)
records the durable visibility and ownership contract.

## Context

`Baikai.Kit.Config.providerAgentsBase` fixes where each provider's files go:

```haskell
providerAgentsBase config InteractiveClaude scope = resolveAgentsBase config scope  -- ~/.config/<tool>/agents, <root>/.<tool>/agents
providerAgentsBase _config InteractiveCodex UserScope = getHomeDirectory           -- ~/.agents/skills, ~/.codex/agents
providerAgentsBase config InteractiveCodex ProjectScope = config ^. #projectRoot     -- <root>/.agents/skills, <root>/.codex/agents
```

The result is that the two providers get **opposite visibility** for the same install:

| Scope | Claude Code | Codex |
|---|---|---|
| User | Tool-only. Visible only when the tool launches Claude with `--add-dir ~/.config/<tool>/agents` (`Baikai.Kit.Session.agentDirsForSession`). | Shared. `$HOME/.agents/skills` is read by **every** Codex session. |
| Project | Tool-only. `<root>/.<tool>/agents` needs the same `--add-dir`. | Shared. `<root>/.agents/skills` is read by every Codex session in that repository. |

Neither result was chosen by the kit author or the user, and `kit status` does not show it. On
2026-10-01 the user-scope installs of `rei-bookmark-url` and `rei-note-from-url-markdown` sat in
`~/.agents/skills/`, so every Codex session on the machine saw them. Their Claude Code copies were
visible only inside `rei agent assist`. A skill meant for every session, such as
`rei-capture-session`, has the opposite problem: no install makes it visible in an ordinary
Claude Code session.

### What each agent can do

These were checked against current documentation on 2026-10-01.

- **Claude Code** discovers skills in `~/.claude/skills/`, the project's `.claude/skills/`, and
  `<dir>/.claude/skills/` for each `--add-dir`. The `permissions.additionalDirectories` setting
  grants file access only and does not load skills. There is no setting for extra skill search
  paths. **Symlinked skill folders are supported** (Claude Code skills documentation). Every
  combination is achievable: tool-only through `--add-dir` as today, and shared through a link
  in `~/.claude/skills/` or `<root>/.claude/skills/`.
- **Codex** discovers skills in `.agents/skills` (from the working directory up to the repository
  root), `$HOME/.agents/skills`, `/etc/codex/skills`, and its built-in skills. It documents no
  flag or environment variable that adds a skill directory. `codex --add-dir` (codex-cli 0.159.3)
  means "additional directories that should be writable", not a skill mount. So **Codex cannot
  isolate a skill to one tool's sessions the way Claude Code can.** This is a Codex limitation,
  not a baikai-kit bug. The baikai-kit bug is that it turns "tool-only" into "shared" for Codex
  without saying so.
- **A possible Codex workaround, unverified.** Codex can disable a skill in
  `~/.codex/config.toml` with `[[skills.config]] path = "…/SKILL.md" enabled = false`, and
  `codex -c key=value` overrides configuration for one launch. If a tool-only item installed into
  a Codex discovery root were disabled in the user's config and re-enabled by the tool's own
  launcher with `-c`, Codex would approximate tool-only visibility. One risk needs a spike:
  overriding `skills.config` with `-c` may replace the whole array, including the user's other
  entries.

## Requested contract

Visibility becomes a second setting, independent of scope:

|  | Tool-only (default) | Shared |
|---|---|---|
| **User scope** | (1) Seen only in sessions the tool launches, on any project | (3a) Seen in every session on the machine |
| **Project scope** | (2) Seen only in sessions the tool launches in that project | (3b) Seen in every session in that project |

1. **Declared by the kit author, overridable by the user.** A `kit.json` item may declare its
   default visibility, for example `"visibility": "shared"`. When absent the default is
   tool-only, which matches today's Claude Code behaviour. `kit install` accepts a flag that
   overrides the declared default for that install.
2. **Shared on Claude Code** places a symlink at `~/.claude/skills/<name>` (user) or
   `<root>/.claude/skills/<name>` (project) that targets the tool-namespaced install, so
   `kit update` needs no second copy. Subagents get the matching `.claude/agents/<name>.md` link.
3. **Tool-only on Codex** is either delivered or refused honestly:
   - if the configuration workaround above holds up, install into the Codex discovery root,
     register a `[[skills.config]] enabled = false` entry, and make
     `Baikai.Kit.Session` and the Codex launcher re-enable it for the tool's own sessions;
   - otherwise, report Codex tool-only as unsupported. `kit install` says that the Codex copy
     will be visible to every Codex session and asks for confirmation (or `--accept-shared-codex`).
     It is never shared silently.
4. **The kit tracks and manages every link and config entry.** The kit's `.<tool>-kit.json`
   records each one. `kit status` shows each provider copy's effective visibility, including a
   provider that cannot honour the requested one. `kit uninstall` removes the links and config
   entries. `kit update` repairs a missing or broken one.
5. **Never take over a shared name.** `~/.claude/skills/`, `.claude/skills/`, and the Codex roots
   are shared by every tool and by the user. A shared install refuses when the destination name
   exists and was not created by this kit, and names the owner when it can tell. It never
   overwrites.
6. **Existing installs keep working.** Items installed before this change keep their current
   placement. `kit status` reports existing Codex user-scope items as shared so the user can see
   it, and offers a way to move them to tool-only where that is supported.

## Acceptance

1. With no visibility declared, a user-scope install is visible to a Claude Code session the tool
   launches and not to a plain `claude` session, as today.
2. An item declared `"visibility": "shared"` is visible in a plain `claude` session through a
   symlink in `~/.claude/skills/`, and in a project-scope install through
   `<root>/.claude/skills/`. `kit update` changes the linked content without touching the link.
3. For Codex, either a tool-only item is visible in the tool's launched Codex session and hidden
   in a plain `codex` session (a spike decides whether this is possible), or the install refuses
   without explicit acceptance of shared visibility and `kit status` marks the copy as shared.
4. `kit status`, including its JSON output, reports the requested and effective visibility for
   every provider copy.
5. A shared install refuses to replace an existing `~/.claude/skills/<name>` or Codex skill
   directory that the kit did not create, and leaves it untouched.
6. `kit uninstall` removes every link and config entry it created and nothing else. `kit update`
   recreates a deleted link.
7. Consumers (Rei, Mori, OKF, notion-hub) need only a version bump to get the behaviour. Their kit
   repositories opt in per item through `kit.json`.

## Non-goals

- No change to which tool owns a kit, or to how a kit repository is fetched or cached.
- No global skill search path for Claude Code; Claude Code offers none. Shared visibility is
  delivered through its standard locations.
- No selective visibility for built-in, admin (`/etc/codex/skills`), or user-authored skills that
  no kit installed.

## References

- `docs/user/kit.md` ("Codex assets install into Codex-native discovery roots")
- `docs/plans/15-add-agent-asset-layout-helpers-for-kits.md` (the original Codex discovery-path
  evidence)
- `docs/user/interactive-launches.md` (the two meanings of `--add-dir`)
- `mori://shinzui/rei` — `rei-capture-session` in the `shinzui/rei-kit` kit repository, which is
  not registered in Mori
- Claude Code skills documentation, <https://code.claude.com/docs/en/skills>; Codex skills
  documentation, <https://learn.chatgpt.com/docs/build-skills>
