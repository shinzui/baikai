# Bundle Update Log

## 2026-11-14

* **Update**: FRIC-7 resolved: Complete isolated adapter verification against signed Hackage sources after diagnosing primary-index lag and the HTTP mirror failure.


* **Update**: FRIC-7 resolved: Complete isolated adapter verification against signed Hackage sources after diagnosing primary-index lag and the HTTP mirror failure.


* **Update**: FRIC-6 accepted: Recover registry discovery and registration through the existing native PostgreSQL socket; the original inherited connection remains unchanged.


* **Addition**: FRIC-7 records detour environment friction with https://hackage.haskell.org: Hackage primary index lagged a successful upload

* **Update**: FRIC-6 accepted: Accept the registry discovery outage for this run with scoped fallback; do not claim registry registration succeeded.

## 2026-11-13
* **Addition**: FRIC-6 records blocked environment friction with mori://shinzui/mori: Mori registry unavailable during final-message correction

## 2026-11-03
* **Update**: FRIC-5 resolved: Record both cohort versions reaching the signed index and retain the official HTTPS refresh workaround for downstream consumers.
* **Update**: FRIC-5 resolved: Resolve publication-to-index lag through signed HTTPS refresh, preserving credentials, package bounds and published tags.
* **Addition**: FRIC-5 records detour environment friction with https://hackage.haskell.org/: Hackage index refresh lags the published core package
* **Update**: FRIC-4 resolved: Replace isolated validation advice with full-context strict diagnostic classification without changing historical review provenance.
* **Addition**: FRIC-4 records detour documentation friction with mori://shinzui/baikai/plans/102-deliver-aborted-call-evidence-through-the-effectful-binding: Isolated capability validation loses required concept context

## 2026-10-25
* **Update**: FRIC-3 resolved: Credits restored; replace the accepted quota limitation with successful funded endpoint evidence.
* **Update**: FRIC-3 accepted: Keep endpoint acceptance and live cache reuse unverified after the bounded quota failure; no retries added.
* **Addition**: FRIC-3 records blocked environment friction with https://developers.openai.com/api/docs/guides/prompt-caching: OpenAI cache verification exhausted account quota
* **Update**: FRIC-1 records a readiness-based repair of both lifecycle fixtures
during release preparation; the full offline gate passes.
* **Update**: FRIC-2 accepted: Triage the pre-existing strict-metadata baseline separately from TypeSafe acceptance.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/baikai: Capability strict validation encounters pre-existing missing review metadata
* **Update**: FRIC-1 accepted: Triage after EP-83: serial full-suite verification passes; retain the observed startup-race cost.
* **Addition**: FRIC-1 records detour tooling friction with mori://shinzui/baikai: Claude cancellation fixture races fixed startup delay under build load
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
