# Claude Fable 5.2 live smoke results

On 2026-11-20, each selector produced one result for
`anthropic_claude_fable_5_2`. All five responses reported
`claude-fable-5-2` at `https://api.anthropic.com/v1/messages` and used
standard token rates with no estimate reasons. Each request allowed 4,096
output tokens and a 120-second timeout. The tool loop allowed four calls.

| Attempt | Effort | Result | Calls | Tool dispatches | Cost |
| --- | --- | --- | ---: | ---: | ---: |
| [fable52-text](2026-11-20-fable52-text.json) | Low | Passed | 1 | 0 | $0.000304 |
| [fable52-tools](2026-11-20-fable52-tools.json) | Low | Signed replay missing | 2 | 1 | $0.008360 |
| [fable52-tools retry](2026-11-20-fable52-tools-high.json) | High | Passed | 2 | 1 | $0.054168 |

The low-effort tool run returned the test timestamp with zero signed blocks
on its `ToolUse` response. The retry added the synthetic counting task
before the clock call. Its `ToolUse` response included one signed thinking
block. At the driver boundary, the follow-up request contained the same
thinking text and signature at the same content position, immediately
before the matching tool result. The follow-up ended with `Stop` and
returned `2041-03-17T09:26:53Z`.

The JSON preserves model, endpoint, cost, and comparison results. Response
and provider request identifiers are redacted.
