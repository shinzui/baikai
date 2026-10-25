# Bundle Update Log

## 2026-10-25

* **Update**: FRIC-1 records a readiness-based repair of both lifecycle fixtures
  during release preparation; the full offline gate passes.
* **Update**: FRIC-2 accepted: Triage the pre-existing strict-metadata baseline separately from TypeSafe acceptance.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/baikai: Capability strict validation encounters pre-existing missing review metadata
* **Update**: FRIC-1 accepted: Triage after EP-83: serial full-suite verification passes; retain the observed startup-race cost.
* **Addition**: FRIC-1 records detour tooling friction with mori://shinzui/baikai: Claude cancellation fixture races fixed startup delay under build load
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
