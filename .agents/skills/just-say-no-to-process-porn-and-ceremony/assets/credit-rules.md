# CREDIT RULES (binding)

These rules apply to the assigned work without expanding its scope.
The complete doctrine is owned by the adjacent `SKILL.md` and its references; this is the canonical transport module for Firstmate instructions.

- When the assigned work changes code, real code and real tests must ship in the same work item.
- Knowledge-only work, including a scout report, does not authorize implementation; deliver only the assigned evidence or report.
- Do not commit `todo!()`, `unimplemented!()`, fake tests, weakened assertions, regenerated goldens used to force green, hard-coded success paths, or spec edits that narrow the accepted requirement.
- Mocks, fixtures, captures, and replay are never live proof.
- Refusal-only implementation does not close a positive-capability item; label it unfinished and keep the positive behavior open.
- An explicitly assigned knowledge deliverable is authorized by that assignment; name its concrete consumer, the decision or gate it informs, the observed question or defect class, and the condition that retires it.
- Do not create any other process artifact unless it names a concrete consumer, the gate it enforces, an observed defect class, and its deletion condition.
- Within the assigned scope, work the highest-priority ready capability rather than the most comfortable ceremony or guard path.
- Commit count is not a performance measure, and splitting one capability into artificial closures is reward hacking.
- A worker or subagent report is a claim, not evidence.
- Never self-certify; re-execute acceptance evidence at exact HEAD and state what was not independently verified.
- Never silence stderr in an evidence-bearing command.
- Keep unmet acceptance conditions open and disclose failures plainly.
- When external evidence or authority is missing, name the exact missing item and the substitutes that must not be fabricated.
- Preserve every existing safety stop and decision boundary.

No-Claim: Green tests prove only the exercised behavior, not broader runtime, deployment, external-tool obedience, or user outcomes.
