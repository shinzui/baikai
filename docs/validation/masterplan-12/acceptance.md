# MasterPlan 12 acceptance audit

Audit date: 2026-09-07. Implementation inspected at commit `5ba0ef5`.
The initiative is **not complete**: Fable live text and tool acceptance needs
Anthropic credentials. This record distinguishes offline protocol proof from
live account access and does not treat skipped cases as successes.

Paths below are relative to the repository root. Test names refer to executable
assertions, not only fixture declarations.

| Requirement | Inspected proof | Result |
|---|---|---|
| Catalog preserves endpoint facts and older model routes | `baikai/test/CatalogSpec.hs` checks the Astra Responses override and explicit Anthropic facts; its byte comparison checks generated bindings against catalog data. Fetch/generator normalization tests run in the core suite. | Offline passed |
| Reject unsupported Chat tools before complete/stream dispatch; use facts rather than model names | `baikai-openai/test/TransportSpec.hs`, “endpoint capability rejection precedes network on complete and stream,” uses a renamed restricted model. | Offline passed |
| Preserve low through max, translate minimal with evidence, reject strict downgrades, omit unsupported sampling | `ShapeSpec.hs`, `ResponsesSpec.hs` and `ResponsesEvidenceSpec.hs` in the OpenAI tests assert wire values and strict refusal before the transport runs. | Offline passed |
| Native Responses request, text/images, tools, JSON output, cache policy | OpenAI `ResponsesSpec.hs` checks stateless text/image/system/cap/metadata, function choices, `text.format`, cache TTL and unsupported-option errors. `ResponsesTransportSpec.hs` checks POST `/v1/responses`, normalization, headers, body and no redirects. | Offline passed |
| Opaque continuation, persistence, provenance and function call identity | OpenAI request, assembler and stream tests preserve empty-summary encrypted items; reject foreign/malformed/duplicate replay; and run the public two-turn tool loop with exact next-request reasoning and call identity. Core content/evidence tests cover legacy JSON and commitments. | Offline passed |
| Ordered streaming and terminal truthfulness | `ResponsesAssemblerSpec.hs` checks parallel calls, independent buffers, snapshot reconciliation, cut-off arguments, partial prefixes and malformed terminals. Stream/evidence tests check EOF, failed responses, duplicate terminals and retained partial usage. | Offline passed |
| Bounded workers, slow consumers, cancellation and strict evidence | OpenAI `ResponsesStreamSpec.hs` and `ResponsesEvidenceSpec.hs` assert worker release on terminal/cancellation, continued service to a slow active consumer, byte fragmentation, one abort record, actual request commitments and absent observations remaining absent. | Offline passed |
| Fable forced-choice and history contracts | Claude `FableContractsSpec.hs` checks complete/stream rejection before the driver for required/named choices, renamed models, auto/none, older compatibility defaults, two consecutive signed/redacted tool rounds and error cleanup. | Offline passed |
| Exact context-tier arithmetic and cache duration | `baikai/test/PricingPolicySpec.hs` checks 271999/272000/272001 thresholds, whole-request $5.44752, cache reads/writes crossing the threshold, Fable read/short/long rates, flat compatibility and invalid policy data. Claude stream tests verify actual shaped duration, including downgraded long requests. | Offline passed |
| Missing versus zero usage, cumulative snapshots and one shared cost calculation | OpenAI `BillingSpec.hs`, core pricing/usage tests and both provider stream tests assert missing-category estimates, explicit zero, no duplicate accumulation, reasoning as an output subset, observed service facts and the resolved-rate seam. | Offline passed |
| Evidence, trace, logs and OpenTelemetry retain billing on success/failure | Core `EvidenceSpec.hs` and `TraceSpec.hs`, provider stream evidence tests, and `baikai-trace-otel/test/Main.hs` compare response usage/cost with emitted facts, including failed calls. | Offline passed |
| Focused selection, required-key failure, ordinary behavior and bounded useful cases | `SmokeOptionsSpec.hs` has 12 pure checks. Executable keyless checks returned four skips or four failures with zero calls. `Smoke.hs` retains its ordinary suite branch. `NewModelsSmoke.hs` uses explicit options, four-call tool bounds, per-call timeouts, real dispatcher counting and exact timestamp matching. Isolated Astra selection succeeded despite absent Anthropic keys. | Implemented and checked |
| Redacted structured results and endpoint observations | Committed JSON artifacts contain requested/observed models, call/dispatch counts, identifiers, cost basis and thinking translation. The initial text result exposed a base-only endpoint; the transport-derived path fix is covered by provider tests and both subsequent live tool responses record `/v1/responses`. Original evidence was preserved unchanged. | Passed, initial artifact limitation retained |
| Astra live text and deterministic tool conversation | `2026-09-07-astra-text.json` records one successful call. `2026-09-07-astra-tools.json` records two successful calls and one tool dispatch; runner success also requires the exact returned timestamp. | Live passed |
| Fable live text and deterministic tool conversation; both models passing the full focused command | `2026-09-07-required-credentials.json` records the missing Anthropic credential alternatives and zero calls. The workspace environment was checked again during this audit and still lacks both alternatives. | **Outstanding** |
| Reproduction docs, capability examples and durable decisions | `docs/user/models-and-providers.md` and `agents/skills/update-models/SKILL.md` contain the implemented commands. CAP-7/CAP-12 compiled twins expose cost basis; doc-shapes passes. ADRs 0019/0020 retain dispatch/replay and pricing decisions. Unreleased changelog identifies public compatibility changes without cutting a release. | Implemented and checked |
| Build, generated catalog, documentation gates and clean diff | Final `cabal build all` exited 0 at this audit. The prior generation check left `Generated.hs` byte-identical; the unchanged catalog remains covered by core tests. Doc-shapes passed after the endpoint fix. Capability validation previously passed all 22 concepts. | Passed |

Validation logs retained locally (not committed):

- `/tmp/baikai-mp12-focused-offline.log`: 708 core, 276 OpenAI, 335 Claude and doc-shapes passed.
- `/tmp/baikai-mp12-selection-tests.log`: 12 option/credential checks passed.
- `/tmp/baikai-mp12-endpoint-gate.log`: 276 OpenAI, 335 Claude and doc-shapes passed after the endpoint fix.
- `/tmp/baikai-mp12-audit-build.log`: final workspace build passed.
- Earlier EP-4 accounting validation, recorded in plan 76, includes all 10 OpenTelemetry tests and capability/generator gates.

The three live Astra requests total $0.00355 by local standard-token calculation;
this is not invoice verification. They returned no reasoning blocks. Therefore
live encrypted replay is not claimed: the scripted public tool-loop fixture is
the evidence for that contract. No expensive live context-threshold request,
automatic retry, unrelated model run, release or publication was used.

Resume Fable validation only after its credential chain is available, preserve
its dated results separately, and re-evaluate the outstanding row before marking
the master plan complete. Successful Astra cases need not be charged again.
