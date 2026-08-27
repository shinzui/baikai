---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Review

- [Correctness and API review of every package at 0.5](correctness-and-api-review-follow-up.md) - REV-1's findings are fixed and pinned bar the thinking-style table, but the transports, evidence surface, and baikai-agent added since carry a host parse that can misdirect an API key, error streams that break the event protocol, and a shipped binary whose timeout cannot fire, so changes are requested before the freeze.
- [Correctness and API review of every package at 0.2](correctness-and-api-review.md) - Five parallel readers found the architecture sound but error classification, extended thinking, and the compat-quirk system not working as documented, and asked for themes 1–4 to be fixed before the library is relied on for important work.

