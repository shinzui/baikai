---
okf_version: "0.2"
---

# Bug Report

- [Cancelling a batch CLI provider leaves its child process alive](batch-cli-cancellation-leaves-child-alive.md) - Both batch CLI adapters through 0.7.1.0 leave an owned fake executable's five-second child alive after cancellation is requested; fixed in 0.7.1.1 with core 0.8.0.0.
- [Codex batch transport concatenates complete messages and corrupts structured output](codex-concatenates-complete-agent-messages.md) - The Codex CLI adapter joins intermediate and final agent messages, turning individually valid schema-shaped JSON objects into invalid adjacent JSON and causing downstream MissingField failures.
