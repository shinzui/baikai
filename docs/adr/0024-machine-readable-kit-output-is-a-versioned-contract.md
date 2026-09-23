---
title: Machine-readable kit output is a versioned contract written by explicit encoders, and stdout carries only the document
status: accepted
date: 2026-09-23
---

# Machine-readable kit output is a versioned contract written by explicit encoders, and stdout carries only the document

## Context

`kit list`, `kit status`, and `kit update` printed only column-aligned
text. A script, an agent, or another tool that wanted the same facts had
to scrape the columns, or read the cached `kit.json` directly and bypass
the engine's manifest-version and path checks. Improvement request IR-9
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-9`), raised
from `mori://shinzui/mori`, asked for a machine-readable form with a
format version.

Two properties decide whether such output can be relied on. Its shape
must not change by accident — a derived `ToJSON` instance changes the
wire format whenever someone renames a Haskell record field — and a
consumer must be able to parse stdout without first separating it from
warnings. `runKitCommand` printed `Fetched <tool>-kit.` to stdout after a
first clone, which would have corrupted a document on exactly the run a
new user makes first.

## Decision

**The documents are written by explicit encoders in `Baikai.Kit.Json`
(`listDocument`, `statusDocument`, `updateDocument`), which return aeson
`Value`s built key by key, never by `ToJSON` instances derived from the
Haskell types.** Library callers get the same values the command prints.

**Every document carries `formatVersion` and a `document` name.** Adding a
key keeps the version; removing or renaming a key, or changing what a
value means, increments it. Every documented key is always present, with
`null` for an absent value, so a consumer can test a value without first
testing for the key. Condition strings come from
`Baikai.Kit.Status.conditionLabel`, the same function the table uses.

**In JSON mode stdout carries exactly one document on success and nothing
on failure.** Every warning and notice, including the first-clone notice,
goes to stderr; a failure is `Error: …` on stderr and exit 1 from
`runKit`, with no error document. The document is written as UTF-8 bytes
(`Data.ByteString.Lazy.hPut` of `Data.Aeson.encode`), never through the
locale ([ADR 0007](0007-text-crossing-a-process-boundary-is-encoded-explicitly.md)).

## Consequences

Golden files in `baikai-kit/test/golden/` pin the three shapes over a
fixture that covers every status condition, both scopes, both providers,
and both kinds. They are compared as decoded values, so key order and
whitespace are not part of the contract. A golden that changes is a
contract change and needs a `formatVersion` decision before it is
accepted with `BAIKAI_KIT_ACCEPT_GOLDEN=1`.

A new field on a Haskell type does not reach the JSON until someone adds
it to an encoder, and a renamed field cannot silently rename a key. Tests
capture stdout under a stale cache, an unreachable repository, a failed
pull, and a first clone, and require it to be one document or empty.
