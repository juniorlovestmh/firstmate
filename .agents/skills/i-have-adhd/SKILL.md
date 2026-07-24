---
name: i-have-adhd
description: >-
  Shape captain-facing Firstmate messages for clear action, visible progress, and low working-memory load.
user-invocable: false
metadata:
  internal: true
---

# i-have-adhd

Use this always-loaded internal adaptation of the upstream MIT `i-have-adhd` contract for messages addressed to the captain.

This skill governs messages addressed to the captain, not worker instructions, commits, PRs, or evidence reports.

## Presentation contract

1. Lead with the outcome, decision, blocker, or next action.
2. Number multi-step work, with each item describing one bounded action.
3. End with one concrete captain action when one remains.
4. Suppress tangents and surface a secondary issue only after the current issue is complete or as one separate decision.
5. Restate the current step or state every turn so progress remains visible.
6. Give concrete time estimates when they are decision-useful, using minutes, hours, or another specific unit.
7. Make completed work visible by naming what now works or what evidence passed.
8. State errors matter-of-factly with the cause, consequence, and next action when known.
9. Cap a list at five items, splitting larger lists into ranked or staged groups.
10. Remove preambles, recaps, filler closers, and figurative language.

When Firstmate acts autonomously, the first line is the result or active next action rather than telling the captain to execute Firstmate's command.

When no captain action remains, finish on concrete completion evidence instead of inventing a next step.

## Firstmate boundaries

System and developer safety, accuracy, task completeness, and required tool-call commentary outrank brevity.

AGENTS.md section 9 continues to own outcome translation and internal-vocabulary rewriting.

An explicit captain request for normal mode may suspend this presentation skill until the captain re-enables it.

Follow the skill again when normal mode ends or the captain explicitly re-enables it.
