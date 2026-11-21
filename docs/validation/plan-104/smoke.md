# GPT-6.2 generated binding smoke tests

2026-11-20. Each named invocation returned exactly one result with
`ran=true` and `status=passed`. All six calls used
`https://api.openai.com/v1/responses`, reported the expected model, and
used Standard token rates with no estimate reasons.

| Selector | Observed model | Calls | Tool dispatches | Reasoning blocks |
| --- | --- | ---: | ---: | ---: |
| [astra62-text](astra62-text.json) | `gpt-6.2-astra` | 1 | 0 | 0 |
| [astra62-tools](astra62-tools.json) | `gpt-6.2-astra` | 2 | 1 | 1 |
| [sol62-text](sol62-text.json) | `gpt-6.2-sol` | 1 | 0 | 0 |
| [sol62-tools](sol62-tools.json) | `gpt-6.2-sol` | 2 | 1 | 1 |

The text cases streamed a strict JSON object whose `answer` value was
`pong`. The high-effort tool cases included a leading system prompt,
dispatched the synthetic clock once, and returned its timestamp. Each
first tool response included one replayable reasoning item.

The JSON summaries retain verification fields and costs. Response and
provider request identifiers are redacted.
