#!/usr/bin/env bash
# Reclaim regenerable disk artifacts (fleet-local-disk-guard-o14): node_modules
# and Rust target/ dirs in IDLE treehouse pool slots only, plus an age-filtered
# Docker prune of dangling images and build cache.
#
# Usage: fm-disk-reclaim.sh [--apply] [--treehouse-root <dir>] [--docker-age <duration>]
#   Dry-run by default: prints the manifest of what WOULD be reclaimed and by
#   how much, with nothing removed or pruned. --apply performs the removal and
#   Docker prune and prints the same manifest annotated with what was actually
#   freed.
#   --treehouse-root overrides the treehouse pool root (default ~/.treehouse);
#   mainly useful for tests.
#   --docker-age overrides the Docker prune age filter (docker's own duration
#   syntax, e.g. 24h, 168h; default 24h).
#
# Safety - the do-not-touch-dirty-slot rule (2026-08-03 learnings.md: an
# unpublished captain article was found in an idle appheat pool slot during an
# earlier manual sweep):
#   A pool slot is reclaimed ONLY when treehouse itself reports it "available"
#   (no live process, no lease) AND it is a real git worktree with a fully
#   clean `git status --porcelain` (no uncommitted OR untracked content) AND
#   zero commits ahead of a configured upstream. Any other case - in-use,
#   dirty, untracked files, no upstream, unpushed commits - is skipped and
#   reported in the manifest, never removed. bin/fm-disk-lib.sh's
#   fm_disk_slot_verdict is the single owner of that predicate; it is
#   unit-tested directly in tests/fm-disk-reclaim.test.sh.
#   Docker reclaim is scoped to `docker image prune` (dangling/untagged images
#   only, never -a/all-unused) and `docker builder prune` (build cache), both
#   filtered by --docker-age. Volumes and containers are never touched - see
#   data/learnings.md's Neo4j volume protection note for why that boundary
#   matters on this shared host.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-disk-lib.sh
. "$SCRIPT_DIR/fm-disk-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

APPLY=0
TREEHOUSE_ROOT="${HOME:-}/.treehouse"
DOCKER_AGE=24h
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --treehouse-root)
      [ "$#" -ge 2 ] || { echo "error: --treehouse-root requires a value" >&2; exit 2; }
      TREEHOUSE_ROOT=$2
      shift 2
      ;;
    --treehouse-root=*) TREEHOUSE_ROOT=${1#--treehouse-root=}; shift ;;
    --docker-age)
      [ "$#" -ge 2 ] || { echo "error: --docker-age requires a value" >&2; exit 2; }
      DOCKER_AGE=$2
      shift 2
      ;;
    --docker-age=*) DOCKER_AGE=${1#--docker-age=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TREEHOUSE_ROOT" ] || { echo "error: --treehouse-root must not be empty" >&2; exit 2; }

TOTAL_KIB=0
RECLAIMED_KIB=0

manifest_line() { printf '%s\n' "$1"; }

kib_to_human() {
  local kib=$1
  if [ "$kib" -ge 1048576 ]; then
    awk -v k="$kib" 'BEGIN { printf "%.1fGiB", k / 1048576 }'
  elif [ "$kib" -ge 1024 ]; then
    awk -v k="$kib" 'BEGIN { printf "%.1fMiB", k / 1024 }'
  else
    printf '%sKiB' "$kib"
  fi
}

# --- pool slot reclaim -------------------------------------------------------

# Every regenerable candidate directory under one slot: node_modules anywhere,
# and a Rust target/ dir whose parent holds Cargo.toml (so an unrelated
# directory that happens to be named "target" is never touched).
slot_candidate_dirs() {
  local slot=$1 d
  find "$slot" -xdev -type d -name node_modules -prune -print 2>/dev/null
  find "$slot" -xdev -type d -name target -prune 2>/dev/null | while IFS= read -r d; do
    [ -f "${d%/target}/Cargo.toml" ] && printf '%s\n' "$d"
  done
}

reclaim_slot_candidates() {
  local slot=$1 label=$2 dir kib human
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    kib=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    case "$kib" in ''|*[!0-9]*) kib=0 ;; esac
    TOTAL_KIB=$((TOTAL_KIB + kib))
    human=$(kib_to_human "$kib")
    if [ "$APPLY" -eq 1 ]; then
      if rm -rf -- "$dir"; then
        RECLAIMED_KIB=$((RECLAIMED_KIB + kib))
        manifest_line "  FREED       $label  $dir  ($human)"
      else
        manifest_line "  ERROR       $label  $dir  (removal failed)"
      fi
    else
      manifest_line "  WOULD-FREE  $label  $dir  ($human)"
    fi
  done < <(slot_candidate_dirs "$slot")
}

# Find one existing slot's project dir within a pool to run `treehouse status`
# from - the CLI resolves the current pool from cwd's git identity, not from a
# pool-name flag, so any live worktree in the pool works as the probe.
pool_status_probe() {
  local pool=$1 slot_dir proj
  for slot_dir in "$pool"/*/; do
    [ -d "$slot_dir" ] || continue
    case "$(basename "$slot_dir")" in
      ''|*[!0-9]*) continue ;;
    esac
    for proj in "$slot_dir"*/; do
      [ -e "${proj}.git" ] || continue
      printf '%s\n' "${proj%/}"
      return 0
    done
  done
  return 1
}

reclaim_pool_slots() {
  local pool probe status_json name path pstatus in_use verdict
  local pool_count=0 slot_count=0 safe_count=0 skip_count=0

  if ! command -v treehouse >/dev/null 2>&1; then
    manifest_line "  treehouse not found on PATH - pool slot reclaim skipped"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    manifest_line "  jq not found on PATH - pool slot reclaim skipped"
    return 0
  fi
  if [ ! -d "$TREEHOUSE_ROOT" ]; then
    manifest_line "  no pool at $TREEHOUSE_ROOT - skipped"
    return 0
  fi

  for pool in "$TREEHOUSE_ROOT"/*/; do
    [ -d "$pool" ] || continue
    pool=${pool%/}
    pool_count=$((pool_count + 1))
    probe=$(pool_status_probe "$pool") || continue
    status_json=$(cd "$probe" 2>/dev/null && treehouse status --json 2>/dev/null)
    [ -n "$status_json" ] || continue

    while IFS=$'\t' read -r name path pstatus; do
      [ -n "$path" ] || continue
      slot_count=$((slot_count + 1))
      in_use=1
      [ "$pstatus" = available ] && in_use=0
      verdict=$(fm_disk_slot_verdict "$path" "$in_use")
      if [ "$verdict" != safe ]; then
        skip_count=$((skip_count + 1))
        manifest_line "  SKIP        $(basename "$pool")/$name  $verdict"
        continue
      fi
      safe_count=$((safe_count + 1))
      reclaim_slot_candidates "$path" "$(basename "$pool")/$name"
    done < <(printf '%s' "$status_json" | jq -r '.[] | [.name, .path, .status] | @tsv' 2>/dev/null)
  done
  manifest_line "  $pool_count pool(s), $slot_count slot(s) scanned, $safe_count reclaimable, $skip_count skipped"
}

# --- Docker (age-filtered, never volumes or containers) ---------------------

reclaim_docker() {
  local dangling_count prune_out

  if ! command -v docker >/dev/null 2>&1; then
    manifest_line "  docker not installed - skipped"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    manifest_line "  docker daemon not reachable - skipped"
    return 0
  fi

  dangling_count=$(docker images -f dangling=true -f "until=$DOCKER_AGE" -q 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$dangling_count" in ''|*[!0-9]*) dangling_count=0 ;; esac

  if [ "$APPLY" -eq 1 ]; then
    prune_out=$(docker image prune -f --filter "until=$DOCKER_AGE" 2>&1)
    manifest_line "  image prune (until=$DOCKER_AGE): $(printf '%s' "$prune_out" | tail -1)"
    prune_out=$(docker builder prune -f --filter "until=$DOCKER_AGE" 2>&1)
    manifest_line "  build cache prune (until=$DOCKER_AGE): $(printf '%s' "$prune_out" | tail -1)"
  else
    manifest_line "  $dangling_count dangling image(s) older than $DOCKER_AGE WOULD be pruned"
    manifest_line "  build cache older than $DOCKER_AGE WOULD be pruned"
    manifest_line "  (dry-run; pass --apply to act)"
  fi
  manifest_line "  volumes and containers are never touched (data/learnings.md: Neo4j volume protection)"
}

# --- main ---------------------------------------------------------------

FREE_BEFORE=$(fm_disk_free_gib 2>/dev/null) || FREE_BEFORE=unknown
if [ "$APPLY" -eq 1 ]; then
  manifest_line "Disk reclaim manifest (--apply)"
else
  manifest_line "Disk reclaim manifest (dry-run; pass --apply to act)"
fi
manifest_line "Data volume free before: ${FREE_BEFORE}GiB"
manifest_line ""
manifest_line "Pool slots (treehouse root: $TREEHOUSE_ROOT):"
reclaim_pool_slots
manifest_line ""
manifest_line "Docker:"
reclaim_docker
manifest_line ""
if [ "$APPLY" -eq 1 ]; then
  manifest_line "Reclaimed from pool slots: $(kib_to_human "$RECLAIMED_KIB")"
else
  manifest_line "Would reclaim from pool slots: $(kib_to_human "$TOTAL_KIB")"
fi
FREE_AFTER=$(fm_disk_free_gib 2>/dev/null) || FREE_AFTER=unknown
manifest_line "Data volume free after: ${FREE_AFTER}GiB"
