#!/usr/bin/env bash
# Behavior tests for the read-only fm-muster.sh unrecorded-work scan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MUSTER="$ROOT/bin/fm-muster.sh"
TMP_ROOT=$(fm_test_tmproot fm-muster)

make_treehouse_worktree() {
  local case_dir=$1 name=$2 branch=$3 source worktree
  source="$case_dir/sources/$name"
  worktree="$case_dir/treehouse/pool/1/$name"
  fm_git_worktree "$source" "$worktree" "$branch"
  printf '%s\n' "$worktree"
}

test_dirty_worktree_prints_one_line() {
  local case_dir worktree out
  case_dir="$TMP_ROOT/dirty-case"
  worktree=$(make_treehouse_worktree "$case_dir" dirty dirty-branch)
  printf 'dirty\n' >> "$worktree/README.md"
  out=$(FM_TREEHOUSE_ROOT_OVERRIDE="$case_dir/treehouse" "$MUSTER")
  [ "$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] \
    || fail "dirty worktree should print exactly one finding, got: $out"
  assert_contains "$out" "$worktree" "dirty finding omitted the worktree path"
  assert_contains "$out" "dirty" "dirty finding omitted its reason"
  pass "fm-muster.sh: dirty worktree prints one line"
}

test_clean_pushed_worktree_is_silent() {
  local case_dir worktree source bare out
  case_dir="$TMP_ROOT/pushed-case"
  source="$case_dir/sources/pushed"
  worktree="$case_dir/treehouse/pool/1/pushed"
  bare="$case_dir/remotes/pushed.git"
  fm_git_worktree "$source" "$worktree" pushed-branch
  git init -q --bare "$bare"
  git -C "$worktree" remote add origin "$bare"
  git -C "$worktree" push -q -u origin pushed-branch
  out=$(FM_TREEHOUSE_ROOT_OVERRIDE="$case_dir/treehouse" "$MUSTER")
  [ -z "$out" ] || fail "clean pushed worktree should be silent, got: $out"
  pass "fm-muster.sh: clean pushed worktree is silent"
}

test_local_only_branch_prints_one_line() {
  local case_dir worktree bare out
  case_dir="$TMP_ROOT/local-case"
  worktree=$(make_treehouse_worktree "$case_dir" local-only experiment)
  bare="$case_dir/remotes/local-only.git"
  git init -q --bare "$bare"
  git -C "$worktree" remote add origin "$bare"
  out=$(FM_TREEHOUSE_ROOT_OVERRIDE="$case_dir/treehouse" "$MUSTER")
  [ "$(printf '%s\n' "$out" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] \
    || fail "local-only branch should print exactly one finding, got: $out"
  assert_contains "$out" "$worktree" "local-only finding omitted the worktree path"
  assert_contains "$out" "no origin/experiment" "local-only finding omitted the branch reason"
  pass "fm-muster.sh: local-only branch prints one line"
}

test_dirty_worktree_prints_one_line
test_clean_pushed_worktree_is_silent
test_local_only_branch_prints_one_line
