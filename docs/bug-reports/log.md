# Bundle Update Log

## 2026-10-10
* **Release**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). Name core
  0.8.0.0 and both adapters 0.7.1.1 as the fixed releases; consumer qualification
  remains required before its guard can be removed.
* **Fixed**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). Verify the fix committed in 87996dd on master: core and adapter cancellation suites pass, and the reproduction no longer reproduces for either adapter. Set status `fixed` with `fixedVersion: unreleased`; no fixed release is on Hackage yet.

## 2026-10-06
* **Implementation**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). Implement ExecPlan 90 ownership anchors, group termination, joined readers, and positive cancellation regressions; fixed release remains pending.
* **Review**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). Reflect ExecPlan 90 changes-requested self-review: require ownership safe from group identifier reuse and concrete Darwin/Linux live-versus-zombie completion checks before implementation.
* **Confirmed**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). Reproduced both adapters in the owning repository and reran published-package consumer probes; correct the Cabal test filter, clarify acknowledgement and reaping, and link ExecPlan 90.
* **Created**: [BUG-1](batch-cli-cancellation-leaves-child-alive.md). File the reported cancellation lifecycle defect in both released batch adapters, backed by bounded consumer probes from mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai; no owning-repository confirmation or fix is claimed.
