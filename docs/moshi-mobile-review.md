# Moshi mobile review

Audience: operator current.

Moshi is the phone interface into the same host-side Firstmate session, not a second agent or control plane.
This runbook covers a Firstmate session reached through an existing Moshi host connection, with Moshi Pro and the already-installed `moshi-hook` available for host-gateway features.
Moshi's own documentation remains the setup owner for the app, subscription, connection, and hook service.
Use Moshi's current [Browser Preview](https://getmoshi.app/docs/browser-preview), [Diff](https://getmoshi.app/docs/diff-viewer), [Chat View](https://getmoshi.app/docs/chat-view), and [Hooks](https://getmoshi.app/docs/hooks) documentation when product UI or requirements change.
Firstmate does not install, update, pair, or configure Moshi through this workflow.

## Choose the review surface

| Need | Preferred mobile surface | Fallback |
| --- | --- | --- |
| Several options or structured feedback | Host-local Lavish through Moshi Pro Browser Preview | Numbered Firstmate chat |
| Current working-tree changes | Moshi Pro Diff | Full HTTPS PR link or compact chat summary |
| A phone-native view of the live agent conversation | Moshi Chat View when the current agent and session are supported | The same Moshi terminal session |
| A simple approval or decision | Firstmate chat, or the agent's exact native approval when `moshi-hook` exposes it | The same Moshi terminal session |

Browser Preview, Diff, and Chat View all preserve the host session as the source of truth.
They do not replace Firstmate supervision, approval authority, merge rules, or credential boundaries.

## Review a Lavish surface through Browser Preview

1. Build the review under `.lavish/` using the current Lavish design guidance and every applicable playbook.
   Use the `input` playbook when the review collects structured feedback.
2. Keep the artifact host-local and start it with `lavish-axi <review-file>`.
3. Give the captain a phone-ready handoff such as: `Captain, the review is ready. Open Browser Preview in Moshi and choose the Lavish server. Reply here if Preview is unavailable.`
4. In Moshi, open the existing saved host connection, attach to the same Firstmate session, tap Browser Preview, and choose the detected Lavish HTTP server.
5. Keep `lavish-axi poll <review-file>` attached through the current supervised Lavish workflow while feedback is expected.
6. If Preview is unavailable, stop depending on the visual surface and restate the complete decision in chat with numbered low-typing replies.

Do not send the host's raw local URL as the mobile handoff.
Moshi discovers the host-local HTTP listener and forwards it inside the active SSH-capable session, so no public URL or manual tunnel is required.
Closing the Moshi session retires that phone-side forward without changing the host-side Firstmate session.

Private fleet state must never be moved to `lavish-axi share` as a fallback.
A password does not turn third-party publication into a host-local private review.

## Make the Lavish review touch-friendly

- Prefer a single-column decision flow with the recommendation visible first.
- Use large labeled controls and short option text that can be tapped without zooming.
- Prevent horizontal overflow in tables, code, badges, and nested layouts.
- Keep the decision summary and send action within one phone scroll when practical.
- Preserve a complete plain-text fallback so the captain can answer without the review surface.

## Review changes with Diff

Open Moshi Pro Diff from the active session while its current directory is inside the repository to review staged, unstaged, and untracked working-tree changes.
Diff is a host-local working-tree view, not proof of the hosted pull request's current head or checks.
When a pull request exists, Firstmate still sends its full `https://...` URL in chat so the captain can open the authoritative hosted review.

## Use Chat View without forking the session

Chat View is a presentation layer over the same live agent process and transcript.
It does not start a second agent, copy the session into a new protocol, or move Firstmate authority into Moshi.
Current Moshi documentation lists Claude Code, Codex CLI, OpenCode, and Pi as supported and requires the agent to run inside tmux or Herdr.
When the agent, multiplexer, prompt, or approval card is unsupported, close Chat View and continue in the terminal without a handoff protocol.

## Authority and privacy boundaries

The [`mobile-mode` skill](../.agents/skills/mobile-mode/SKILL.md) owns the full agent authority contract for these surfaces, while `AGENTS.md` section 9 remains the underlying approval owner.
The operator safety rule is that a Moshi control may answer only the exact native agent prompt it represents, while every Firstmate merge, scope, destructive, credential, permission, or security-sensitive choice returns to Firstmate chat.

Do not put secret values in Lavish artifacts, notification summaries, screenshots, or chat examples.
Do not build or suggest a Firstmate webhook bridge for this workflow.

## Fallbacks

| Failure | Firstmate response |
| --- | --- |
| Browser Preview does not detect Lavish | Present the full decision in numbered chat and keep the private artifact host-local. |
| Diff is unavailable or points at the wrong directory | Send the full HTTPS PR link when one exists, or summarize the local changes in chat. |
| Chat View does not recognize the session | Continue in the same Moshi terminal session. |
| A card cannot answer an agent prompt safely | Return to the native terminal prompt. |
| The hook is unavailable | Use Firstmate chat or the native terminal without changing authority. |

## Captain dogfood from Moshi

Run this checklist against a harmless private review with no secret values.

1. Open the saved host connection in Moshi and attach to the Firstmate Herdr session used on desktop.
2. Ask for a simple status update and confirm the result, consequence, and action fit within one scroll.
3. Ask a harmless two-option question and confirm that replying `1` selects the recommended option without terminal navigation.
4. Have Firstmate open a private Lavish decision surface, then use Browser Preview to choose the detected Lavish server and send one feedback prompt.
5. Open Diff from a repository session and confirm it shows the local working tree, then open the full HTTPS PR link from Firstmate chat when a PR exists.
6. Open Chat View when Moshi recognizes the active agent, send one short prompt, then return to the terminal and confirm it is the same uninterrupted session.
7. Disable or leave Preview once and confirm Firstmate provides the complete numbered chat fallback without a raw local URL or a public share suggestion.

Maintainer compatibility evidence and the agent-behavior test exception live in [`verification/moshi-mobile-review.md`](verification/moshi-mobile-review.md).
