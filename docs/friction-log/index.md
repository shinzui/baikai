---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Claude cancellation fixture races fixed startup delay under build load](1-claude-cancellation-fixture-races-fixed-startup-delay-under-build-load.md) - The existing Claude lifecycle cancellation fixture failed twice during parallel suite builds and passed when its suite ran serially.
- [Capability strict validation encounters pre-existing missing review metadata](2-capability-strict-validation-encounters-pre-existing-missing-review-metadata.md) - Strict capability-bundle validation reports missing recommended reviews on older records unrelated to TypeSafe.
- [OpenAI cache verification exhausted account quota](3-openai-cache-verification-exhausted-account-quota.md) - OpenAI rejected the bounded 12h endpoint probe before cache behavior could be observed.
- [Isolated capability validation loses required concept context](4-isolated-capability-validation-loses-required-concept-context.md) - The plan-recommended isolated strict capability check cannot resolve CAP-32 requirements or body links without the rest of the bundle.
- [Hackage index refresh lags the published core package](5-hackage-index-refresh-lags-the-published-core-package.md) - The default HTTP Cabal index refresh omits a core version already published on Hackage, preventing the dependent binding archive from resolving.
- [Mori registry unavailable during final-message correction](6-mori-registry-unavailable-during-final-message-correction.md) - The Mori PostgreSQL socket refused connections, preventing dependency and consumer registry discovery.
- [Hackage primary index lagged a successful upload](7-hackage-primary-index-lagged-a-successful-upload.md) - Hackage published the core package and docs while its primary signed index still predated the release, blocking dependent archive verification.
