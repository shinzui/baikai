---
title: Structured answer evidence is content and survives independently of call evidence
status: accepted
date: 2026-10-25
---

# Structured answer evidence is content and survives independently of call evidence

## Context

Judgment responses contain chosen values, distributions and provider-reported confidence. A cache may remove the original call's evidence without changing the answer. Generative transports cannot replay these blocks faithfully as text.

## Decision

`AssistantData DataContent` carries the JSON value and optional probability, confidence and method fields. These fields belong to content, independently of `Response.evidence`. Individual probabilities and confidences must be finite and within [0,1]; distributions are never normalized. `UserData` is canonical UTF-8 JSON text on generative transports. They refuse assistant data history before dispatch with an `InvalidRequest` and typed `UnsupportedFeature` path. `UnsupportedModel` uses the same category; neither is retryable.

Structured stream blocks are atomic `DataStart`/`DataEnd` pairs. An unfinished block invents no data; completed blocks survive an error. Trace terminals, call logs and the OpenTelemetry `baikai.response.structured_data` canonical JSON attribute preserve the ordered structured payloads without requiring evidence opt-in.

Full-response persistence uses the named `Baikai.Response.JSON` functions. Core adds no global instances for response, assistant payload, usage or cost, avoiding conflicts with existing consumer codecs. The codec preserves supplied evidence, uses existing header redaction and decimal cost precision, and promises stable canonical bytes for its own representation rather than exact arbitrary rational reconstruction.

## Consequences

Consumers can remove call evidence while retaining answer evidence. Persistent public records and sums gain fields or constructors and require PVP major version preparation. The evidence schema's additive version is 2.6; the digest algorithm and old data-free commitments remain unchanged. Consumers that store prompt or response content must account for structured payloads in their existing content retention policy.
