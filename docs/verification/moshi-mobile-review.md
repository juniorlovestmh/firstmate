# Moshi mobile review verification

Audience: maintainer verification.

This record covers the current Firstmate-owned mobile presentation and review handoff boundary.
Moshi product behavior was checked against its official Browser Preview, Diff, Chat View, and Hooks documentation on 2026-07-31.
The operator contract is [`docs/moshi-mobile-review.md`](../moshi-mobile-review.md), and the agent contract is [`mobile-mode`](../../.agents/skills/mobile-mode/SKILL.md).

## Test boundary

The natural-language trigger and captain-facing message shape are agent behavior, not a shell executable.
That is an explicit agent-behavior test exception: do not add a test that parses or asserts instruction source bytes.
Deterministic validation covers the maintained-prose inventory, local links, repository lint surface, and changed-file-selected behavior suite.
Fresh-context dogfood covers whether an agent loads the public `AGENTS.md` trigger and produces the required mobile handoff.

## Moshi facts in scope

The official [Browser Preview documentation](https://getmoshi.app/docs/browser-preview) says host-local HTTP servers are detected by `moshi-hook` and reached in-app through the active SSH-capable session without a public tunnel.
The official [Diff documentation](https://getmoshi.app/docs/diff-viewer) says Diff reads the connected host's staged, unstaged, and untracked working-tree state and keeps diff contents host-local.
The official [Chat View documentation](https://getmoshi.app/docs/chat-view) says Chat View renders the same live agent session, currently lists Claude Code, Codex CLI, OpenCode, and Pi, and requires tmux or Herdr.
The official [Hooks documentation](https://getmoshi.app/docs/hooks) says hook support is broader than Chat View support and that inbox summaries and approval routing are separate from host-local transcript, diff, source-file, and terminal traffic.

## Supported harness review

The supported Firstmate harness list comes from [`harness-adapters`](../../.agents/skills/harness-adapters/SKILL.md).

| Firstmate harness | Mobile presentation | Existing Moshi hook surface | Chat View | Firstmate adapter change |
| --- | --- | --- | --- | --- |
| Claude | Applies through the shared agent contract. | Official Moshi hooks support exists; configuration is external and unchanged. | Listed by Moshi. | None. |
| Codex | Applies through the shared agent contract. | Official Moshi hooks support exists; configuration is external and unchanged. | Listed by Moshi. | None. |
| OpenCode | Applies through the shared agent contract. | Official Moshi hooks support exists; configuration is external and unchanged. | Listed by Moshi. | None. |
| Pi | Applies through the shared agent contract. | Official Moshi hooks support exists, but Firstmate's Pi has no permission system, so approval authority is not applicable. | Listed by Moshi. | None. |
| pi-signed | Applies through the shared agent contract. | It uses the Pi engine, but wrapper-specific Moshi detection is not independently verified. | Use concise numbered Firstmate chat in the same Moshi/Firstmate session unless Moshi recognizes it as Pi. | None. |
| Grok | Applies through the shared agent contract. | Official Moshi hooks support exists; configuration is external and unchanged. | Not in the current official Chat View list, so use concise numbered Firstmate chat in the same Moshi/Firstmate session. | None. |
| Kimi | Applies through the shared agent contract. | Official Moshi hooks support exists; configuration is external and unchanged. | Not in the current official Chat View list, so use concise numbered Firstmate chat in the same Moshi/Firstmate session. | None. |

The repository's Claude, Codex, OpenCode, Pi, Grok, and Kimi hook or extension surfaces were inspected for ownership overlap.
This slice changes none of them and makes no compatibility claim about the captain's external Moshi-managed hook configuration.

## Supported runtime backend review

The supported spawn backend list comes from `FM_BACKEND_SPAWN` in [`bin/fm-backend.sh`](../../bin/fm-backend.sh).

| Firstmate backend | Moshi mobile path | Applicability to this slice |
| --- | --- | --- |
| tmux | Moshi Chat View currently supports tmux; Browser Preview and Diff use the host gateway. | No backend behavior changes. |
| Herdr | Selected Firstmate mobile path; Moshi Chat View currently supports Herdr; Browser Preview and Diff use the host gateway. | No backend behavior changes. |
| Zellij | Moshi can detect Zellij for terminal context, but current Chat View requirements exclude it. | Terminal, Browser Preview, and Diff may remain usable; Chat View falls back to concise numbered Firstmate chat in the same Moshi/Firstmate session; no backend behavior changes. |
| Orca | No Firstmate-to-Moshi session integration is claimed. | Not applicable to the selected Herdr workflow; no backend behavior changes. |
| cmux | No Firstmate-to-Moshi session integration is claimed. | Not applicable to the selected Herdr workflow; no backend behavior changes. |
| Codex App | Firstmate does not accept it as a runtime backend. | Not applicable. |

Moshi remains absent from the backend registry by design.
The mobile contract changes presentation and review handoff only, so spawn, supervision, recovery, cleanup, and backend metadata need no new branch.

## Verification entry points

Run the focused maintained-prose check and the repository's changed-file-selected canonical behavior entrypoint:

```sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh --changed
```

If shell surfaces change in a future extension, also run `bin/fm-lint.sh` and the relevant focused test script.
This slice changes no shell surface, but the delivery pipeline still owns its canonical lint gate.
