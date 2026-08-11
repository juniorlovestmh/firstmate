#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's warn-only durable-backlog preflight.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-backlog-warning)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:) printf '0.2.2\n' ;;
  update:--help) printf 'usage: tasks-axi update <id> [flags]\n  --archive-body\n' ;;
  mv:--help) printf 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>\n' ;;
  show:*) [ "$PWD" = "${FM_FAKE_TASK_HOME:-}" ] && [ "${FM_FAKE_TASK_EXISTS:-0}" = 1 ] ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/tools")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  printf '%s|%s|%s|%s\n' "$home" "$project" "$worktree" "$fakebin"
}

run_case() {
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5 exists=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$worktree" FM_FAKE_TASK_HOME="$home" FM_FAKE_TASK_EXISTS="$exists" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" 2>&1
}

test_missing_record_warns_without_blocking_spawn() {
  local id record home project worktree fakebin out status
  id=missing-backlog-z1
  record=$(make_case missing "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
  out=$(run_case "$home" "$project" "$worktree" "$fakebin" "$id" 0)
  status=$?
  expect_code 0 "$status" "missing backlog record must not block spawn"
  assert_contains "$out" "WARNING: task '$id' has no durable backlog record" \
    "missing backlog entry did not produce the loud warning"
  assert_contains "$out" "tasks-axi add" "warning did not name the durable repair command"
  assert_contains "$out" "spawned $id" "warn-only preflight prevented the spawn"
  pass "fm-spawn.sh: missing backlog record warns and the spawn still succeeds"
}

test_existing_record_is_silent_and_spawn_succeeds() {
  local id record home project worktree fakebin out status
  id=existing-backlog-z2
  record=$(make_case existing "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
  out=$(run_case "$home" "$project" "$worktree" "$fakebin" "$id" 1)
  status=$?
  expect_code 0 "$status" "existing backlog record must permit spawn"
  assert_not_contains "$out" "no durable backlog record" \
    "existing backlog entry produced a false warning"
  assert_contains "$out" "spawned $id" "existing backlog entry did not reach spawn success"
  pass "fm-spawn.sh: existing backlog record stays silent and spawn succeeds"
}

test_manual_backend_is_silent_and_spawn_succeeds() {
  local id record home project worktree fakebin out status
  id=manual-backlog-z3
  record=$(make_case manual "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
  printf 'manual\n' > "$home/config/backlog-backend"
  out=$(run_case "$home" "$project" "$worktree" "$fakebin" "$id" 0)
  status=$?
  expect_code 0 "$status" "manual backlog backend must permit spawn"
  assert_not_contains "$out" "no durable backlog record" \
    "manual backend produced a tasks-axi backlog warning"
  assert_contains "$out" "spawned $id" "manual backend did not reach spawn success"
  pass "fm-spawn.sh: manual backlog backend stays silent and spawn succeeds"
}

test_missing_record_warns_without_blocking_spawn
test_existing_record_is_silent_and_spawn_succeeds
test_manual_backend_is_silent_and_spawn_succeeds
