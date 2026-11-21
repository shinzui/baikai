# GPT-6.2 stateless Responses replay after the adapter fix

2026-11-20. Both models ran through the public stream worker at
`https://api.openai.com/v1/responses`. Each used the same initial request
for both follow-ups in a comparison. Each made two synthetic function
calls and returned the final tool result.

| Model | Cache request | Reasoning submitted, rounds 2 and 3 | Adapter removals | Original-item removals |
| --- | --- | --- | --- | --- |
| GPT-6.2 Astra | Default | 1, 2 | 0, 0 | 0, 0 |
| GPT-6.2 Astra | 30-minute TTL with breakpoint | 1, 2 | 0, 0 | 0, 0 |
| GPT-6.2 Sol | Default | 1, 2 | 0, 0 | 0, 0 |
| GPT-6.2 Sol | 30-minute TTL with breakpoint | 1, 2 | 0, 0 | 0, 0 |

Every terminal included an interpretable `input_transformations` array.
On each follow-up, the unchanged input prefix and full input matched the
original-item branch. The comparison checked item count, type order, item
IDs, content parts, phase, exact argument strings and encrypted reasoning
items. All four runs verified the expected synthetic answer.

The provider reported the following cache-read counters for the adapter
branch. The initial request in each run reported 2,337 total input tokens.

| Model | Cache request | Round 2 input / cached | Round 3 input / cached |
| --- | --- | ---: | ---: |
| GPT-6.2 Astra | Default | 2,531 / 2,334 | 2,696 / 2,528 |
| GPT-6.2 Astra | 30-minute TTL with breakpoint | 2,557 / 2,334 | 2,735 / 2,554 |
| GPT-6.2 Sol | Default | 2,547 / 2,334 | 2,858 / 2,544 |
| GPT-6.2 Sol | 30-minute TTL with breakpoint | 2,557 / 2,334 | 2,808 / 2,554 |
