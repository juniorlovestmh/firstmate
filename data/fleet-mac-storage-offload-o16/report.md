# Mac mini storage offload — report

Task: fleet-mac-storage-offload-o16
Branch: fm/fleet-mac-storage-offload-o16
Date: 2026-08-03

## Why

The internal data volume hit 100% today (293 MB free), causing silent write
failures that looked like unrelated bugs, and damaged the Colima container
VM's virtual disk. An emergency reclaim earlier today (`fleet-machine-cleanup-o15`)
got free space back to ~50 GiB, but the structural cause remained: heavy,
fully regenerable caches live on the internal disk while the attached CodeSSD
(1.8 TB, ~1.2 TB free at task start) sits mostly idle. This task moves the
regenerable heavy items to CodeSSD using durable, supported relocation
settings (not raw symlinks) wherever the tool provides one, following the
`~/.cache/wayne-manor` precedent's rigor: copy, checksum-verify, smoke-test,
then remove the source only after verification passes.

## Before / after free space

| Volume | Before | After | Change |
|---|---|---|---|
| Internal Data volume (`/System/Volumes/Data`) | 50 GiB free (148 GiB used) | 59 GiB free (139 GiB used) | +9 GiB freed |
| CodeSSD (`/Volumes/CodeSSD`) | 1.2 TiB free (608 GiB used) | 1.2 TiB free (611 GiB used) | +3 GiB used (net, after undoing a bad copy — see Colima section) |

Internal free space is modest because the two safely-movable candidates
(Colima, Go module cache) were already fairly small at task start — most of
the emergency damage from today's incident was already reclaimed by the
prior cleanup task. pnpm's cache was also already empty from that same
reclaim. The real structural fix here is that all three are now configured
to land on CodeSSD **going forward**, so future growth no longer threatens
the internal disk.

## What moved and how

### 1. Colima (container VM) — MOVED, via the supported `COLIMA_HOME` setting

Colima (0.10.3) reads a `COLIMA_HOME` environment variable that relocates its
entire state directory (`_lima/`, per-profile dirs, docker/containerd
sockets, VM disk images) — this is the "supported setting" the task asked me
to prefer over a symlink, and it is genuinely supported: verified by reading
the `colima` binary's embedded strings and by directly testing it.

**Method:**
1. Confirmed Colima was stopped (see "Discovery: stale hung Colima process" below — it needed a clean stop first).
2. Copied `~/.colima` → `/Volumes/CodeSSD/Caches/colima-home/colima-live`.
   - **First attempt used `ditto` and was wrong**: Colima's VM disk images
     (`_lima/colima/disk`, `_lima/_disks/colima/datadisk`) are sparse files —
     6.9 GB physical, ~141 GB logical. `ditto` does not preserve sparse
     holes across volumes on this system, and materialized the destination
     to the full 141 GB logical size, wasting ~134 GB of CodeSSD space for
     nothing. Caught by comparing `du` (physical) vs `ls -la` (logical) on
     both sides before trusting the copy.
   - **Fixed by re-copying with `rsync -aH --sparse`**, which detects the
     zero runs and creates real holes on the destination. Result: 7.9 GB
     physical on CodeSSD, matching the source.
   - This is worth remembering for any future large-sparse-file relocation
     on this machine (VM disks, disk images): **use `rsync --sparse`, not
     `ditto`, for anything backed by a sparse file.**
3. Verified content equality with the precedent's method:
   `rsync -rcln --delete` (checksum dry-run) between source and destination
   — zero content differences (only expected warnings about stale unix
   sockets, which aren't real content and get recreated on start).
4. Set `COLIMA_HOME=/Volumes/CodeSSD/Caches/colima-home/colima-live` in two
   places so every invocation path picks it up:
   - `~/.zshenv` (covers interactive shells, scripts, and anything invoked
     through zsh — `.zshenv` is sourced for every zsh invocation, not just
     login/interactive ones).
   - The `homebrew.mxcl.colima` LaunchAgent plist's `EnvironmentVariables`
     (covers auto-start at login). Original plist backed up to
     `/Volumes/CodeSSD/Caches/colima-home/homebrew.mxcl.colima.plist.orig-backup`
     is **not present** — see rollback note below; the plist was regenerated
     by `brew services start colima` rather than hand-copied, so the
  "original" is whatever `brew`'s colima formula template produces, not a
  literal file backup. The final patched plist is captured in this report's
  rollback section; the pre-migration stock plist is not separately archived.
5. Smoke-tested: `docker run --rm busybox:latest` succeeded against the
   relocated VM (`COLIMA_RELOCATED_OK` / `COLIMA_RELOCATED_OK_FINAL`), and
   `docker context ls` correctly shows the CodeSSD socket path.
6. Only after the smoke test passed did I remove the internal `~/.colima`
   (5.6 GB reclaimed). Re-verified `colima start` + `docker run` once more
   **after** the internal copy was gone, to prove nothing silently depended
   on the old path.

**Degraded/detached-drive behavior:** for a manual `colima start`, if CodeSSD
is detached, Colima will fail cleanly because it cannot find its VM disk,
rather than corrupting anything. The auto-start path is different: the
`homebrew.mxcl.colima` LaunchAgent invokes `colima start -f`, which remains
subject to the pre-existing silent launchd hang documented above. A detached
drive may therefore produce that same apparent hang during auto-start instead
of a clean surfaced error; check whether CodeSSD is mounted when diagnosing
it. Any containers that were running (this machine's Neo4j/Postgres
containers used by other projects) would stop being reachable until the drive
is reattached and Colima is restarted. This does **not** block firstmate's own
boot or supervision — firstmate's own data/state/config always stay internal
and have no dependency on Docker or Colima being available.

**Rollback:** keep the relocated copy as the recovery path until the internal
rebuild has succeeded. The documented rollback order is:

1. Remove the `COLIMA_HOME` lines from `~/.zshenv` and from
   `~/Library/LaunchAgents/homebrew.mxcl.colima.plist`'s
   `EnvironmentVariables` dict (or delete the plist and let
   `brew services start colima` regenerate the stock one).
2. Run `colima start` to rebuild a fresh VM at the default internal
   `~/.colima` location.
3. Smoke-test the internal rebuild with
   `docker run --rm busybox:latest echo OK`.
4. Only after that smoke test succeeds, optionally delete
   `/Volumes/CodeSSD/Caches/colima-home/` to reclaim CodeSSD space; keeping it
   costs nothing and is not required to complete rollback.

This is a full rebuild, not a restore of prior container state — the old
containers/images were already regenerable by design, per the task's own
framing. The sequence preserves a recovery path throughout; a documented
rollback with a no-recovery window is exactly the kind of instruction that
gets followed during a 2am incident and loses data. The pre-migration stock
plist was not separately archived. To regenerate it, delete the plist and
run `brew services start colima`; the formula recreates its stock template,
and `COLIMA_HOME` must be re-added by hand if relocating again. The final
patched plist captured after this migration was:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>COLIMA_HOME</key>
		<string>/Volumes/CodeSSD/Caches/colima-home/colima-live</string>
	</dict>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<true/>
	</dict>
	<key>Label</key>
	<string>homebrew.mxcl.colima</string>
	<key>LimitLoadToSessionType</key>
	<array>
		<string>Aqua</string>
		<string>Background</string>
		<string>LoginWindow</string>
		<string>StandardIO</string>
		<string>System</string>
	</array>
	<key>ProgramArguments</key>
	<array>
		<string>/opt/homebrew/opt/colima/bin/colima</string>
		<string>start</string>
		<string>-f</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/opt/homebrew/var/log/colima.log</string>
	<key>StandardOutPath</key>
	<string>/opt/homebrew/var/log/colima.log</string>
	<key>WorkingDirectory</key>
	<string>/Users/fox</string>
</dict>
</plist>
```

### Discovery: stale hung Colima process (pre-existing, unrelated to this migration)

Before touching anything, `colima status` reported "not running," but the
`homebrew.mxcl.colima` LaunchAgent showed a live, tracked process
(`colima start -f`) that had been running for **over 2 days** doing nothing
— no VM, no hostagent, no docker socket, 0% CPU, ~11 MB RSS. I reproduced
this hang twice more independently while testing the LaunchAgent reload
(waited up to 90 seconds each time with zero log output), including once
after the migration was already correct and verified via manual `colima
start` (which reliably works in under 20 seconds every time it was tried,
outside of launchd).

**This is a pre-existing bug independent of the storage location** — the
very first hang was against the untouched internal path. `colima start -f`
appears to reliably hang under launchd in this environment, while plain
`colima start` (used manually, or by `brew services` before the `-f`
foreground handoff) works. I did not attempt to fix this — changing the
LaunchAgent's foreground/`KeepAlive` behavior safely needs more investigation
than belongs in a storage-migration task (dropping `-f` without also
reworking `KeepAlive.SuccessfulExit` would likely cause a restart loop).

**Practical consequence:** auto-start of Colima at login is currently
unreliable — the LaunchAgent may hang silently instead of starting Docker.
`COLIMA_HOME` is correctly wired into the plist for whenever this gets
fixed, but until then, starting Colima manually (`colima start`, no `-f`)
is the reliable path. Recommend filing this as a follow-up if Colima's
auto-start matters going forward.

### 2. pnpm store — REDIRECTED (nothing to physically move)

The brief described `~/Library/Caches/pnpm` as large; it was already empty
(0 B) — today's earlier emergency cleanup (`fleet-machine-cleanup-o15`) had
already cleared it (was 1.44 GiB then). The actual content-addressable pnpm
store lives at `~/Library/pnpm/store/v11` (also emptied by that cleanup).

**Method:** used the supported setting rather than a symlink:
`pnpm config set store-dir /Volumes/CodeSSD/Caches/pnpm-store --location=global`.
Verified with `pnpm store path` (correctly resolves to the new location) and
a real install smoke test (`pnpm add left-pad`, `pnpm add is-odd` in a scratch
project) — packages landed in the new store, not the old one.

**Degraded/detached-drive behavior:** pnpm is drive-required while
`store-dir` points at CodeSSD. If CodeSSD is detached, `pnpm add` and
`pnpm install` fail with a clear `ENOENT`/`EACCES` error while trying to use
the configured store path; pnpm does not fall back to a local store. Nothing
is corrupted because the store is 100% re-downloadable. Recovery with the
drive detached is `pnpm config set store-dir <local path> --location=global`;
pnpm works again after it is pointed at an internal path.

**Rollback:** `pnpm config set store-dir <original path> --location=global`,
or delete the config to fall back to pnpm's default.

### 3. Go module cache — MOVED, via the supported `GOMODCACHE`/`GOCACHE` settings

`~/go/pkg/mod` was 1.5 GB; `~/Library/Caches/go-build` (GOCACHE) was already
empty.

**Method:**
1. Copied with plain `rsync -a` (no sparse-file concerns here — regular
   small files, not VM disk images) to `/Volumes/CodeSSD/Caches/go/mod-live`.
2. Verified with `rsync -rcln --delete` checksum dry-run — zero differences.
3. `go env -w GOMODCACHE=/Volumes/CodeSSD/Caches/go/mod-live` and
   `go env -w GOCACHE=/Volumes/CodeSSD/Caches/go/build-cache` (redirecting
   the build cache proactively too, since it's the same class of
   regenerable artifact and was already empty — no reason to let it refill
   internally).
4. Smoke-tested with a real `go run` of a trivial program — succeeded, and
   the build cache populated at the new location.
5. Removed only the internal copy with
   `GOMODCACHE=/Users/fox/go/pkg/mod go clean -modcache` (not `rm -rf` — Go
   marks module cache contents read-only, and `go clean -modcache` is the
   supported way to remove it correctly). The explicit environment override
   targeted the internal source despite the persisted CodeSSD `GOMODCACHE`
   setting; it did not clean the relocated copy.
6. Fresh post-removal verification confirmed
   `/Volumes/CodeSSD/Caches/go/mod-live` was still present and intact (1.5 GB,
   with all module directories present), `go env GOMODCACHE GOCACHE` still
   resolved to CodeSSD, and a new trivial `go run` smoke test succeeded.

**Degraded/detached-drive behavior:** if CodeSSD is detached, `go build`/`go
run`/`go get` will fail with a clear "no such file or directory" pointing at
the configured cache path, rather than silently corrupting anything. Running
`go env -u GOMODCACHE GOCACHE` (or pointing them back internally) recovers
immediately; all content is re-downloadable/rebuildable.

**Rollback:** `go env -w GOMODCACHE=$(go env GOPATH)/pkg/mod` and
`go env -u GOCACHE`, then delete `/Volumes/CodeSSD/Caches/go/`.

### 4. `~/.treehouse` pool worktrees — NOT MOVED (left internal, deliberately)

Size: 5.7 GB across 162 separate git worktrees (many projects, many slots
per project — e.g. `bible-agents-84d8db` alone has 3 concurrently checked
out slots at ~680–880 MB each).

**Why left alone:** the brief's own bar for this candidate was explicit —
"only consider if you can prove no live worker and no uncommitted/unpushed
work in any slot; if in doubt, do NOT move it." I could not clear that bar:

- This very task is *itself* running from one such slot
  (`firstmate-38131b/2/firstmate`) as a live crewmate, which alone proves the
  pool has live occupants at the time of writing.
- A sweep of all 162 worktrees for uncommitted/unpushed changes (`git
  status --porcelain`) repeatedly hung/timed out partway through, which is
  itself consistent with concurrent write activity or lock contention
  elsewhere in the pool, not just slowness.
- The pool is managed by an external tool (treehouse) that hands slots to
  concurrently-running agents across potentially multiple firstmate homes I
  have no visibility into from this worktree. A raw copy-and-relink of a
  directory other live processes may be actively writing into is a
  categorically different (and much less reversible) risk than relocating a
  static, idle cache — a mid-copy write from another agent could produce a
  corrupted or half-migrated worktree with no clean rollback.

**Recommendation instead of moving it:** if this pool's steady-state size
becomes a real problem, the safe fix is tightening whatever prune/GC job
the treehouse pool already runs (the brief mentions "~10GB+ after tonight's
prune," implying one exists), not an external raw relocation of a directory
under active multi-agent write access.

### Not present / nothing to do

- **Cargo** (`~/.cargo/registry`, `~/.cargo/git`): 0 B, empty. Nothing to
  move or configure.
- **`~/Library/Caches/go-build`**: already empty before this task (see Go
  section) — `GOCACHE` was redirected proactively anyway.

## What stayed internal, and why

- **Firstmate's own `data/`, `state/`, `config/`, `projects/`** — never
  touched, per the task's own hard requirement. Nothing in this task's
  changes affects firstmate's ability to boot or supervise itself.
- **`~/.treehouse` pool** — see above; left in place because safety could
  not be proven.
- **`~/.colima/amd64` docker context entry**: a pre-existing, apparently
  unused stale context registration (`colima-amd64`, pointing at
  `~/.colima/amd64/docker.sock`) is left as-is. The `amd64` Colima profile
  itself was never actually initialized (12 KB, no VM disk ever created for
  it) — this is debris from some earlier `--profile amd64` attempt, unrelated
  to this migration, and low-risk/low-value to clean up here.

## Rollback summary (all items)

| Item | Rollback |
|---|---|
| Colima | Remove `COLIMA_HOME` from `~/.zshenv` and the LaunchAgent plist (or delete the plist and let `brew services start colima` regenerate the stock one), run `colima start`, and smoke-test with `docker run --rm busybox:latest echo OK`. Only after success may the relocated copy at `/Volumes/CodeSSD/Caches/colima-home/colima-live` be optionally deleted; keeping it preserves recovery. |
| pnpm | `pnpm config set store-dir <old-path> --location=global` (or unset). |
| Go | `go env -w GOMODCACHE=$(go env GOPATH)/pkg/mod && go env -u GOCACHE`. |

## Verification evidence

- Colima: `rsync -rcln --delete` checksum dry-run showed zero content
  diffs; `docker run --rm busybox:latest` succeeded before *and* after the
  internal copy was deleted.
- pnpm: `pnpm store path` resolved to the new location; a real `pnpm add`
  populated it, not the old path.
- Go: `rsync -rcln --delete` checksum dry-run showed zero content diffs;
  `GOMODCACHE=/Users/fox/go/pkg/mod go clean -modcache` removed only the
  internal source; the CodeSSD module cache remained intact, `go env` still
  pointed both caches at CodeSSD, and a fresh trivial `go run` succeeded.
- Disk free space measured with `df -h` before and after each step (see
  table above).
