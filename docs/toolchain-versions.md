# Fleet toolchain version manifest and recovery

This manifest records the fleet-critical CLI installation observed on 2026-07-29 on Darwin arm64.
It is an evidence snapshot, not an update request.
No tool version was changed while producing it.

## Installed versions

| Tool | Live version | Installed source | Current update mechanism |
| --- | --- | --- | --- |
| `tasks-axi` | `0.2.3` | Global npm package under `/opt/homebrew/lib/node_modules/tasks-axi` | `npm update -g tasks-axi` |
| `gh-axi` | `0.1.27` | Global npm package under `/opt/homebrew/lib/node_modules/gh-axi` | `npm update -g gh-axi` |
| `lavish-axi` | `0.1.42` | Global npm package under `/opt/homebrew/lib/node_modules/lavish-axi` | `npm update -g lavish-axi` |
| `quota-axi` | `0.1.6` | Global npm package under `/opt/homebrew/lib/node_modules/quota-axi` | `npm update -g quota-axi` |
| `chrome-devtools-axi` | `0.1.26` | Global npm package under `/opt/homebrew/lib/node_modules/chrome-devtools-axi` | `npm update -g chrome-devtools-axi` |
| `no-mistakes` | `v1.40.3` (`d873960`, built `2026-07-22T01:41:55Z`) | Self-contained binary at `~/.no-mistakes/bin/no-mistakes`, reached through `~/.local/bin/no-mistakes` | `no-mistakes update`, which also resets the shared daemon |
| `herdr` | `0.7.5` | Homebrew core bottle at `/opt/homebrew/Cellar/herdr/0.7.5/bin/herdr` | `brew upgrade herdr`; the binary also exposes `herdr update` |
| `treehouse` | `v2.1.0` | Direct Mach-O arm64 binary at `/opt/homebrew/bin/treehouse`; no installed Homebrew keg was present | `treehouse update` |

The five npm package versions were also matched against their installed `package.json` files.
Their package metadata points to the corresponding `kunchenguid/*-axi` repositories.

## Live evidence commands

The following commands were run from the Firstmate task worktree.

```sh
for tool in tasks-axi gh-axi lavish-axi quota-axi chrome-devtools-axi no-mistakes herdr treehouse; do
  command -v "$tool"
  "$tool" --version
done
npm prefix -g
npm root -g
npm list -g --depth=0
brew list --versions herdr treehouse
brew info --json=v2 herdr treehouse
```

The exact `--version` outputs were:

```text
tasks-axi: 0.2.3
gh-axi: 0.1.27
lavish-axi: 0.1.42
quota-axi: 0.1.6
chrome-devtools-axi: 0.1.26
no-mistakes: no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:55Z
herdr: herdr 0.7.5
treehouse: v2.1.0
```

The live mirror acceptance run completed on 2026-07-29 local time, or 2026-07-30 UTC.
`bin/fm-toolchain-mirror.sh snapshot` created snapshot `20260730T030202Z-Darwin-arm64` with eight artifacts.
`bin/fm-toolchain-mirror.sh verify` checked all eight artifacts successfully.
An isolated-prefix restore then reproduced every version output above.
The local mirror occupied 67 MiB, and its `manifest.tsv` SHA-256 was `34985504ab51d5eee5b36ba4582dbc9204d816c3eebee5a2976ff5e60e1d422d`.

## Local offline mirror

[`bin/fm-toolchain-mirror.sh`](../bin/fm-toolchain-mirror.sh) snapshots the eight installed tools without contacting an upstream or changing their versions.
Its default destination is `$FM_HOME/data/toolchain-mirror`.
The repository already ignores `data/`, so the large platform-specific package trees and binaries remain local.
Set `FM_TOOLCHAIN_MIRROR` or pass `--mirror` to use another operator-controlled volume.

Each snapshot contains:

- The complete installed directory for each npm package, including its installed dependencies.
- Exact binary bytes for `no-mistakes`, `herdr`, and `treehouse`.
- Raw `--version` output for every tool.
- A TSV manifest with versions, install sources, update mechanisms, and SHA-256 checksums.
- The operating system and architecture required by the captured binaries.

Create and verify a snapshot:

```sh
bin/fm-toolchain-mirror.sh snapshot
bin/fm-toolchain-mirror.sh verify
```

Restore the current snapshot offline into a new, isolated prefix:

```sh
recovery_prefix="$FM_HOME/data/toolchain-recovery/$(date -u +%Y%m%dT%H%M%SZ)"
bin/fm-toolchain-mirror.sh restore --prefix "$recovery_prefix"
export PATH="$recovery_prefix/bin:$PATH"
```

Restore one tool by adding `--tool <name>`.
The restore refuses an existing prefix, verifies every selected checksum before writing, and verifies the restored `--version` before publishing the new prefix.

## Upstream break or disappearance recovery

1. Stop issuing update commands and preserve the broken installation for diagnosis.
2. Run `bin/fm-toolchain-mirror.sh verify` against the last known-good local snapshot.
3. Restore that snapshot to a new prefix and place its `bin/` first on `PATH`.
4. Re-run the live evidence commands above and the affected Firstmate bootstrap or task path.
5. Resume fleet work only after the pinned commands match the mirror manifest.

Do not restart or update the shared `no-mistakes` daemon while any lane has an active pipeline.
If the restored CLI and running daemon are incompatible, drain active lanes and let the Firstmate operator own the daemon recovery.

The mirror does not disable any updater.
That preserves normal update notices and operator choice, but it also means a later manual update can still introduce breaking bytes.
After every deliberate, verified tool upgrade, create a new snapshot and retain the previous known-good snapshot until fleet validation passes.
