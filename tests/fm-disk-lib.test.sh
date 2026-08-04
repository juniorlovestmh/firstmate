#!/usr/bin/env bash
# tests/fm-disk-lib.test.sh - the shared disk free-space floor and pool-slot
# safety predicate (bin/fm-disk-lib.sh) for the Mac-mini disk guard
# (fleet-local-disk-guard-o14).
#
# fm_disk_slot_verdict is the do-not-touch-dirty-slot rule that
# bin/fm-disk-reclaim.sh relies on to never remove regenerable artifacts from
# a slot holding uncommitted, untracked, or unpushed work - the precedent is
# the 2026-08-03 sweep that found an unpublished captain article in an idle
# pool slot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-disk-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-disk-lib)

# --- fm_disk_free_gib ---------------------------------------------------

test_free_gib_reads_a_real_volume() {
  local free
  free=$(fm_disk_free_gib /)
  case "$free" in
    ''|*[!0-9]*) fail "fm_disk_free_gib should print a whole non-negative number, got '$free'" ;;
  esac
  pass "fm_disk_free_gib: reads a whole-GiB number for a real, mounted volume"
}

test_free_gib_fails_open_on_unknown_volume() {
  if fm_disk_free_gib "/no/such/volume/$$" >/dev/null 2>&1; then
    fail "fm_disk_free_gib should fail on a volume path that does not exist"
  fi
  pass "fm_disk_free_gib: returns nonzero (never a guessed number) for an unreadable volume"
}

# --- fm_disk_floor_gib ---------------------------------------------------

test_floor_gib_defaults_to_ten() {
  local dir out
  dir="$TMP_ROOT/floor-default"
  mkdir -p "$dir"
  out=$(fm_disk_floor_gib "$dir")
  [ "$out" = 10 ] || fail "an absent config/disk-floor should default to 10, got '$out'"
  pass "fm_disk_floor_gib: defaults to 10GiB when config/disk-floor is absent"
}

test_floor_gib_reads_a_valid_override() {
  local dir out
  dir="$TMP_ROOT/floor-override"
  mkdir -p "$dir"
  printf '25\n' > "$dir/disk-floor"
  out=$(fm_disk_floor_gib "$dir")
  [ "$out" = 25 ] || fail "a valid config/disk-floor override should be honored, got '$out'"
  pass "fm_disk_floor_gib: honors a valid positive-integer override"
}

test_floor_gib_ignores_malformed_override() {
  local dir out
  dir="$TMP_ROOT/floor-malformed"
  mkdir -p "$dir"
  printf 'not-a-number\n' > "$dir/disk-floor"
  out=$(fm_disk_floor_gib "$dir")
  [ "$out" = 10 ] || fail "a malformed override should silently keep the default, got '$out'"
  pass "fm_disk_floor_gib: falls back to the default on non-numeric content"
}

test_floor_gib_ignores_zero_override() {
  local dir out
  dir="$TMP_ROOT/floor-zero"
  mkdir -p "$dir"
  printf '0\n' > "$dir/disk-floor"
  out=$(fm_disk_floor_gib "$dir")
  [ "$out" = 10 ] || fail "a zero override should not disable the floor, got '$out'"
  pass "fm_disk_floor_gib: a zero override falls back to the default rather than disabling the floor"
}

test_floor_gib_ignores_symlinked_override() {
  local dir out
  dir="$TMP_ROOT/floor-symlink"
  mkdir -p "$dir"
  ln -s /etc/hosts "$dir/disk-floor"
  out=$(fm_disk_floor_gib "$dir")
  [ "$out" = 10 ] || fail "a symlinked disk-floor must never be trusted, got '$out'"
  pass "fm_disk_floor_gib: refuses a symlinked config/disk-floor and keeps the default"
}

# --- fm_disk_floor_breach ---------------------------------------------------

test_floor_breach_detected_and_message_shaped() {
  local dir out rc=0
  dir="$TMP_ROOT/breach"
  mkdir -p "$dir"
  printf '999999\n' > "$dir/disk-floor"
  out=$(fm_disk_floor_breach "$dir" /) || rc=$?
  [ "$rc" = 1 ] || fail "an impossible 999999GiB floor must be reported as a breach"
  case "$out" in
    *"GiB free on / is below the 999999GiB floor - reclaim with: bin/fm-disk-reclaim.sh --apply") ;;
    *) fail "breach message must state free space, the floor, and the reclaim command, got '$out'" ;;
  esac
  pass "fm_disk_floor_breach: detects a breach and states free space, floor, and the reclaim command"
}

test_floor_breach_silent_when_above_floor() {
  local dir out rc=0
  dir="$TMP_ROOT/no-breach"
  mkdir -p "$dir"
  printf '1\n' > "$dir/disk-floor"
  out=$(fm_disk_floor_breach "$dir" /) || rc=$?
  [ "$rc" = 0 ] || fail "a trivially low 1GiB floor should not breach on a real volume"
  [ -z "$out" ] || fail "no breach should print nothing, got '$out'"
  pass "fm_disk_floor_breach: prints nothing and returns 0 when free space is at or above the floor"
}

test_floor_breach_fails_open_on_unreadable_volume() {
  local dir out rc=0
  dir="$TMP_ROOT/unreadable"
  mkdir -p "$dir"
  out=$(fm_disk_floor_breach "$dir" "/no/such/volume/$$") || rc=$?
  [ "$rc" = 0 ] || fail "an unreadable volume must fail OPEN (never block a spawn), got rc=$rc"
  [ -z "$out" ] || fail "an unreadable volume should print nothing, got '$out'"
  pass "fm_disk_floor_breach: fails open (no breach) when the volume cannot be measured at all"
}

# --- fm_disk_slot_verdict: the do-not-touch-dirty-slot rule -----------------

make_pushed_clean_repo() {
  local dir=$1 bare
  bare="$TMP_ROOT/bare-$(basename "$dir").git"
  fm_git_identity
  fm_git_init_commit "$dir"
  fm_git_add_origin "$dir" "$bare"
  git -C "$dir" push -q -u origin HEAD:main
}

test_slot_verdict_safe_when_idle_clean_and_pushed() {
  local dir out
  dir="$TMP_ROOT/slot-safe"
  make_pushed_clean_repo "$dir"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = safe ] || fail "an idle, clean, fully-pushed slot must verdict safe, got '$out'"
  pass "fm_disk_slot_verdict: safe only for an idle, clean, fully-pushed slot"
}

test_slot_verdict_skips_in_use() {
  local dir out
  dir="$TMP_ROOT/slot-in-use"
  make_pushed_clean_repo "$dir"
  out=$(fm_disk_slot_verdict "$dir" 1)
  [ "$out" = "skip:in-use" ] || fail "an in-use slot must be skipped regardless of git state, got '$out'"
  pass "fm_disk_slot_verdict: THE do-not-touch rule - an in-use slot is always skipped"
}

test_slot_verdict_skips_uncommitted_changes() {
  local dir out
  dir="$TMP_ROOT/slot-dirty-tracked"
  make_pushed_clean_repo "$dir"
  printf 'edited\n' >> "$dir/README.md"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = "skip:uncommitted-or-untracked-changes" ] \
    || fail "an idle slot with an uncommitted edit must be skipped, got '$out'"
  pass "fm_disk_slot_verdict: THE do-not-touch rule - uncommitted tracked edits are skipped"
}

test_slot_verdict_skips_untracked_content() {
  local dir out
  dir="$TMP_ROOT/slot-dirty-untracked"
  make_pushed_clean_repo "$dir"
  printf 'draft\n' > "$dir/unpublished-draft.md"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = "skip:uncommitted-or-untracked-changes" ] \
    || fail "an idle slot with untracked content must be skipped, got '$out'"
  pass "fm_disk_slot_verdict: THE do-not-touch rule - untracked content is skipped (the unpublished-draft precedent)"
}

test_slot_verdict_skips_unpushed_commits() {
  local dir out
  dir="$TMP_ROOT/slot-unpushed"
  make_pushed_clean_repo "$dir"
  fm_git_identity
  git -C "$dir" commit -q --allow-empty -m "local-only work"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = "skip:unpushed-commits" ] \
    || fail "an idle slot ahead of its upstream must be skipped, got '$out'"
  pass "fm_disk_slot_verdict: THE do-not-touch rule - commits ahead of upstream are skipped"
}

test_slot_verdict_skips_no_upstream() {
  local dir out
  dir="$TMP_ROOT/slot-no-upstream"
  fm_git_identity
  fm_git_init_commit "$dir"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = "skip:no-upstream-configured" ] \
    || fail "a slot with no upstream (freshly detached HEAD) cannot prove nothing is unpushed, got '$out'"
  pass "fm_disk_slot_verdict: THE do-not-touch rule - no upstream means unprovable, so it is skipped"
}

test_slot_verdict_skips_non_git_directory() {
  local dir out
  dir="$TMP_ROOT/slot-not-git"
  mkdir -p "$dir"
  out=$(fm_disk_slot_verdict "$dir" 0)
  [ "$out" = "skip:not-a-git-worktree" ] || fail "a non-git directory must be skipped, got '$out'"
  pass "fm_disk_slot_verdict: skips a directory that is not a git worktree at all"
}

test_free_gib_reads_a_real_volume
test_free_gib_fails_open_on_unknown_volume
test_floor_gib_defaults_to_ten
test_floor_gib_reads_a_valid_override
test_floor_gib_ignores_malformed_override
test_floor_gib_ignores_zero_override
test_floor_gib_ignores_symlinked_override
test_floor_breach_detected_and_message_shaped
test_floor_breach_silent_when_above_floor
test_floor_breach_fails_open_on_unreadable_volume
test_slot_verdict_safe_when_idle_clean_and_pushed
test_slot_verdict_skips_in_use
test_slot_verdict_skips_uncommitted_changes
test_slot_verdict_skips_untracked_content
test_slot_verdict_skips_unpushed_commits
test_slot_verdict_skips_no_upstream
test_slot_verdict_skips_non_git_directory
