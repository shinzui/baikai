# GPT-6.2 stateless Responses replay before the adapter fix

2026-11-20. Both `gpt-6.2-astra` and `gpt-6.2-sol` ran through the public
Responses worker at `https://api.openai.com/v1/responses`. Both used a marked
leading developer item, fixed tools, high reasoning effort, `store=false`,
and no `previous_response_id`. Each model emitted one reasoning item, one
message and one function call on each of the first two rounds.

| Model | Follow-up | Reasoning submitted | Projected removals | Original removals |
| --- | --- | ---: | --- | --- |
| GPT-6.2 Astra | Round 2 | 1 | 0 | 0 |
| GPT-6.2 Astra | Round 3 | 2 | 1 (`prefix_mismatch`) | 0 |
| GPT-6.2 Sol | Round 2 | 1 | 0 | 0 |
| GPT-6.2 Sol | Round 3 | 2 | 1 (`prefix_mismatch`) | 0 |

The terminal response included `input_transformations` for every call.
The reported removal matched a submitted reasoning item. Input counts,
function argument strings and encrypted reasoning items matched on both
follow-ups. The original item types, item IDs, message content parts and
phase did not match Baikai's projections. The round-three original
branches both returned the expected synthetic answer.
