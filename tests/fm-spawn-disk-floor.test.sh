#!/usr/bin/env bash
# tests/fm-spawn-disk-floor.test.sh - bin/fm-spawn.sh's disk floor preflight
# (fleet-local-disk-guard-o14): a spawn must refuse, stating current free
# space, the floor, and the reclaim command, before any backend or treehouse
# work begins - and must proceed normally once the volume is above the floor.
#
# The predicate itself (bin/fm-disk-lib.sh) is unit-tested in
# tests/fm-disk-lib.test.sh; this proves the wiring into the real executable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-disk-floor)

make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config" "$dir/projects"
  printf '%s\n' "$dir"
}

test_spawn_refuses_below_the_floor() {
  local home out rc=0
  home=$(make_home "$TMP_ROOT/below-floor")
  printf '999999\n' > "$home/config/disk-floor"

  out=$(FM_HOME="$home" "$SPAWN" some-task "$home/projects" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh must refuse (nonzero exit) when free space is below the configured floor"
  case "$out" in
    *"error: refuse:"*"GiB free on"*"is below the 999999GiB floor"*"bin/fm-disk-reclaim.sh --apply"*) ;;
    *) fail "refusal must state current free space, the floor, and the reclaim command, got: $out" ;;
  esac
  pass "fm-spawn.sh: refuses below the configured disk floor and states free space, floor, and the reclaim command"
}

test_spawn_disk_check_runs_before_treehouse_or_tmux() {
  local home out rc=0
  home=$(make_home "$TMP_ROOT/no-tools-on-path")
  printf '999999\n' > "$home/config/disk-floor"

  # No tmux/treehouse/gh on this PATH at all - if the disk refusal is not the
  # very first gate, the spawn would fail later with a missing-tool error
  # instead of the disk refusal, and this assertion would catch that drift.
  out=$(env PATH=/usr/bin:/bin FM_HOME="$home" "$SPAWN" some-task "$home/projects" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a nonzero refusal exit"
  case "$out" in
    *"error: refuse:"*"below the 999999GiB floor"*) ;;
    *) fail "the disk refusal should fire before any backend/tool dependency is checked, got: $out" ;;
  esac
  pass "fm-spawn.sh: the disk floor preflight runs before any backend or treehouse work begins"
}

test_spawn_proceeds_past_the_disk_check_above_the_floor() {
  local home out rc=0
  home=$(make_home "$TMP_ROOT/above-floor")
  printf '1\n' > "$home/config/disk-floor"

  # Above a trivially low 1GiB floor, the spawn must get past the disk check
  # and fail later for an unrelated reason (no real backend/session tools on
  # a minimal PATH) rather than the disk refusal - proving the check does not
  # false-positive when space is fine.
  out=$(env PATH=/usr/bin:/bin FM_HOME="$home" "$SPAWN" some-task "$home/projects" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "expected this minimal-PATH spawn to still fail for an unrelated reason"
  case "$out" in
    *"error: refuse:"*"below the"*"GiB floor"*)
      fail "a 1GiB floor should not breach on a real volume, but the spawn was refused for disk anyway: $out"
      ;;
  esac
  pass "fm-spawn.sh: does not false-positive the disk refusal when free space is above the floor"
}

test_spawn_refuses_below_the_floor
test_spawn_disk_check_runs_before_treehouse_or_tmux
test_spawn_proceeds_past_the_disk_check_above_the_floor
