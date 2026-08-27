---
title: Text crossing a process boundary is encoded explicitly as UTF-8, never through the locale
status: accepted
date: 2026-08-27
---

# Text crossing a process boundary is encoded explicitly as UTF-8, never through the locale

## Context

A Haskell `Handle` carries an encoding. By default it is the *locale
encoding*: whatever the environment's `LANG` and `LC_*` variables say the
character set is. `Data.Text.IO.hPutStr` and `getContents` go through it,
so what those functions do with a non-ASCII character depends on the
environment the program was started in rather than on the program.

That is the wrong dependency for everything baikai reads or writes at a
process boundary. A prompt contains whatever a user wrote. A coding
agent's answer contains whatever the model produced. An unattended run
happens where nobody chose the environment on purpose — a cron entry, a
systemd unit, a container — and those give a process `LANG=C`, whose
character set is US-ASCII. Encoding through it turns one accented
character into an `invalid argument` exception, thrown *after* the work
is done, so the result is lost and the exit code is a failure that has
nothing to do with the run.

The read side of `baikai-agent` was already explicit for exactly this
reason: `Baikai.Agent.Cli.readPromptSource` reads bytes and decodes them
with `Data.Text.Encoding.decodeUtf8'`, and `Baikai.Agent.Run.writePromptAsync`
encodes with `encodeUtf8` and writes bytes. The command's own output was
not, which the 2026-08-27 review recorded as item F.9
(`docs/reviews/correctness-and-api-review-follow-up.md`).

## Decision

Text that crosses a process boundary — into or out of this repository's
executables, and to or from a child process — is converted between
`Text` and `ByteString` explicitly, with `Data.Text.Encoding`, and moved
with `Data.ByteString`'s handle operations. `Data.Text.IO` and the
`String` handle functions are not used for such a boundary, and
`hSetEncoding` is not the fix: it moves the choice rather than removing
the dependency on a handle's encoding at all.

Where a byte sequence from outside may not be valid UTF-8, the decode is
deliberate and total: `decodeUtf8Lenient` where a replacement character
is better than a failure — a coding agent's captured output, which is
reported rather than parsed — and `decodeUtf8'` where the caller should
be told, as `readPromptSource` tells them which source failed to decode.

## Consequences

`baikai` writes valid UTF-8 whatever the environment says, and cannot
throw while writing a result it has already computed. Anything that
decoded leniently on the way in is already free of invalid sequences by
the time it is encoded again, so the encode is total in practice as well
as in type.

The rule is easy to violate by reflex, because `Data.Text.IO.hPutStr` is
the obvious function to reach for and works on a developer's machine.
Two things make a violation visible: `baikai-agent/test/BinaryTests.hs`
runs the built command under `LANG=C` and asserts the exact bytes, and
this record explains why that case exists.

That case cannot fail on macOS. GHC on Darwin reports UTF-8 as the
locale encoding whatever `LANG` says — checked directly against 9.12.4
with `C`, `POSIX`, `en_US.ISO8859-1` and `C.UTF-8` — so the defect this
record prevents is observable on Linux and not here. The case is kept
because it costs nothing on the platform where it cannot fail and pins
the behaviour on the platform where unattended runs actually happen.

This says nothing about text inside a process, where `Text` is already
the representation and no encoding is involved, and nothing about the
HTTP transports, where the provider SDKs own the bytes.
