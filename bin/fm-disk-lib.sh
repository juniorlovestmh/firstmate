#!/usr/bin/env bash
# Shared disk free-space floor check for the Mac-mini disk guard
# (fleet-local-disk-guard-o14). Sourced by bin/fm-spawn.sh (refuse),
# bin/fm-bootstrap.sh (warn), and bin/fm-disk-guard-poll.sh (registered
# watcher check) so the measured volume, floor resolution, and refusal
# wording cannot drift across the three call sites.
# docs/configuration.md "Disk floor and reclaim" is the single owner of the
# config/disk-floor contract and default; this file is the single owner of
# the check mechanics.

FM_DISK_DEFAULT_FLOOR_GIB=10
FM_DISK_DEFAULT_VOLUME=/System/Volumes/Data

# fm_disk_free_gib [volume]: whole GiB free on the given volume (default the
# Mac data volume). Uses POSIX `df -Pk` (1024-byte blocks, one line of
# output) rather than BSD-only `df -g`, so the same function reads correctly
# on both macOS crewmates and the Linux CI/no-mistakes runners that also
# source this file. Prints nothing and returns 1 when the volume cannot be
# read (unmounted, unknown path, or a non-Mac host with no such mount) -
# callers treat that as "cannot verify" and fail OPEN rather than refusing
# work on every host that isn't this Mac mini.
fm_disk_free_gib() {
  local volume=${1:-$FM_DISK_DEFAULT_VOLUME} kib
  kib=$(df -Pk "$volume" 2>/dev/null | awk 'NR==2 { print $4 }') || return 1
  case "$kib" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$((kib / 1048576))"
}

# fm_disk_floor_gib <config-dir>: the configured floor in whole GiB. Reads
# the first line of config/disk-floor when it is an ordinary, non-symlink
# file holding a plain positive integer; any other content, or an absent
# file, silently keeps the default rather than guessing at malformed input.
fm_disk_floor_gib() {
  local config_dir=$1 file val
  file="$config_dir/disk-floor"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    val=$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')
    case "$val" in
      ''|0|*[!0-9]*) val= ;;
    esac
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf '%s\n' "$FM_DISK_DEFAULT_FLOOR_GIB"
}

# fm_disk_floor_message <free> <floor> <volume>: the one-line body shared by
# every caller, so the current free space, the floor, and the reclaim
# command never drift between fm-spawn.sh, fm-bootstrap.sh, and the
# registered watcher check.
fm_disk_floor_message() {
  local free=$1 floor=$2 volume=$3
  printf '%sGiB free on %s is below the %sGiB floor - reclaim with: bin/fm-disk-reclaim.sh --apply' \
    "$free" "$volume" "$floor"
}

# fm_disk_floor_breach <config-dir> [volume]: prints the shared message and
# returns 1 when free space is below the configured floor. Prints nothing
# and returns 0 both when free space is at or above the floor and when it
# cannot be read at all - a df failure is not proof of low disk, so it must
# never itself block a spawn or spam a false warning.
fm_disk_floor_breach() {
  local config_dir=$1 volume=${2:-$FM_DISK_DEFAULT_VOLUME} free floor
  free=$(fm_disk_free_gib "$volume") || return 0
  floor=$(fm_disk_floor_gib "$config_dir")
  [ "$free" -lt "$floor" ] || return 0
  fm_disk_floor_message "$free" "$floor" "$volume"
  return 1
}

# fm_disk_slot_verdict <slot-dir> <in-use 0|1>: the do-not-touch-dirty-slot
# safety predicate for bin/fm-disk-reclaim.sh. Prints "safe" and returns 0
# only when the slot is idle (per the caller's own treehouse status query,
# passed in as <in-use>) AND it is a real git worktree with a fully clean
# `git status --porcelain` (no uncommitted OR untracked content - the
# 2026-08-03 precedent that found an unpublished captain article in an idle
# slot demands nothing less) AND zero commits ahead of a configured upstream.
# Any other case prints one "skip:<reason>" line and returns 1; the caller
# must skip and report that slot, never reclaim it.
fm_disk_slot_verdict() {
  local slot=$1 in_use=$2 porcelain ahead
  if [ "$in_use" != 0 ]; then
    printf 'skip:in-use\n'
    return 1
  fi
  if [ ! -d "$slot" ] || ! git -C "$slot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'skip:not-a-git-worktree\n'
    return 1
  fi
  porcelain=$(git -C "$slot" status --porcelain 2>/dev/null) || {
    printf 'skip:git-status-failed\n'
    return 1
  }
  if [ -n "$porcelain" ]; then
    printf 'skip:uncommitted-or-untracked-changes\n'
    return 1
  fi
  git -C "$slot" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || {
    printf 'skip:no-upstream-configured\n'
    return 1
  }
  ahead=$(git -C "$slot" rev-list --count '@{u}..HEAD' 2>/dev/null)
  case "$ahead" in
    ''|*[!0-9]*)
      printf 'skip:cannot-verify-unpushed-commits\n'
      return 1
      ;;
  esac
  if [ "$ahead" != 0 ]; then
    printf 'skip:unpushed-commits\n'
    return 1
  fi
  printf 'safe\n'
}
