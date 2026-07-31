---
name: mobile-mode
description: >-
  Shape captain-facing Firstmate messages and review handoffs for a phone, especially when Moshi is the active surface.
user-invocable: false
metadata:
  internal: true
---

# mobile-mode

Load this skill when the captain says they are in mobile mode or identifies Moshi as the active surface.
Continue following it until the captain says they are back on desktop or requests normal mode.

This is a presentation profile over the same host-side Firstmate session.
It does not create a Moshi runtime backend, supervision path, authority channel, or webhook integration.
The always-loaded [`i-have-adhd`](../i-have-adhd/SKILL.md) contract remains the owner of general captain-facing presentation, and `AGENTS.md` section 9 remains the owner of outcome translation and approval escalation.
This skill owns only the mobile delta and the review-surface choice.

## Message shape

- Apply the `i-have-adhd` outcome-first rule, then keep the outcome, consequence, evidence, and requested action within one ordinary phone scroll whenever the required facts fit.
- Make choices answerable with one low-typing reply such as `1`, `2`, `yes`, `merge`, or `hold`.
- Number choices, put the recommendation first, and end with the exact short reply that will select it.
- Keep full `https://...` pull-request links under section 9's existing rule so the captain can open the review directly.
- Put long logs and secondary evidence in the existing private report, then summarize the consequence in chat.
- Do not require terminal copy mode, pane navigation, punctuation-heavy commands, or multi-step text entry to answer a decision.

## Review-surface choice

Use plain chat for a simple decision or whenever a rich surface is unnecessary or unavailable.
Use a host-local Lavish surface through Moshi Pro Browser Preview when several options or structured feedback benefit from a touch-friendly review.
Follow the operator runbook in [`docs/moshi-mobile-review.md`](../../../docs/moshi-mobile-review.md).

After Lavish starts on the host, tell the captain to open Browser Preview in Moshi and choose the Lavish server.
Never present a raw `127.0.0.1`, `localhost`, `file://`, or desktop-only LAN URL as if the phone can open it directly.
If Browser Preview is unavailable, restate the complete decision in chat with numbered replies instead of suggesting public sharing.

Use Moshi Pro Diff to inspect the connected working tree, while keeping a full HTTPS pull-request link in chat for a hosted PR review.
Use Chat View only when Moshi recognizes the active agent and session, and treat the terminal as the source of truth for unsupported prompts or incomplete cards.

Private fleet reviews stay host-local.
Never invoke or suggest `lavish-axi share` for private fleet state, even with a password.
Public sharing of separately sanitized public material requires an explicit request and the ordinary outward-facing consent boundary.

## `moshi-hook` authority

The already-installed `moshi-hook` may surface the running agent's native inbox events and approvals in Moshi or Apple Watch.
An approval button may answer only the exact native agent prompt that Moshi can map safely to the same live session.
It never authorizes a Firstmate merge, product or scope decision, destructive or irreversible action, credential use, permission change, or security-sensitive choice.
Route those decisions through Firstmate chat under the existing authority contract.

Do not add a Firstmate-to-Moshi webhook, change hook configuration, or place secrets in notification summaries.
When an approval is unavailable, ambiguous, or unsupported, return to the terminal or ask through Firstmate chat without weakening the underlying boundary.
