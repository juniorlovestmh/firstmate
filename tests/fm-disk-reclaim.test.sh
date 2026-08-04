#!/usr/bin/env bash
# tests/fm-disk-reclaim.test.sh - end-to-end behavior tests for
# bin/fm-disk-reclaim.sh (fleet-local-disk-guard-o14): dry-run vs --apply,
# the do-not-touch-dirty-slot rule enforced through the real executable, and
# graceful degradation when treehouse/jq/docker are unavailable.
#
# treehouse and docker are faked via PATH shims so the suite never depends on
# or mutates this host's real fleet or container state. git, jq, du, find,
# and awk are the real system tools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECLAIM="$ROOT/bin/fm-disk-reclaim.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-disk-reclaim)

# make_pushed_clean_repo <dir>: an idle, clean, fully-pushed fixture worktree.
make_pushed_clean_repo() {
  local dir=$1 bare
  bare="${dir}.bare.git"
  fm_git_identity
  fm_git_init_commit "$dir"
  fm_git_add_origin "$dir" "$bare"
  # Push to a deterministic destination, then set the upstream explicitly.
  # GitHub's Linux Git rejects `push -u HEAD:main` when the local branch has
  # a different name (for example master).
  git -C "$dir" push -q origin HEAD:refs/heads/main
  git -C "$dir" branch --set-upstream-to=origin/main "$(git -C "$dir" branch --show-current)" >/dev/null
}

# fake_treehouse <fakebin> <json>: a treehouse stub whose `status --json`
# always answers with the given fixed JSON, regardless of cwd - callers
# probe from inside one fixture slot, matching the real CLI's own cwd-based
# pool resolution without needing a real pool.
fake_treehouse() {
  local fakebin=$1 json=$2
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\$1" = status ] && [ "\$2" = --json ]; then
  cat <<'JSON'
$json
JSON
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/treehouse"
}

# --- pool fixture: one safe slot, one dirty slot, one in-use slot ----------

build_pool_fixture() {
  local case_dir=$1 pool fakebin json
  pool="$case_dir/pool/proj-abc123"
  mkdir -p "$pool/1" "$pool/2" "$pool/3"

  make_pushed_clean_repo "$pool/1/proj"
  mkdir -p "$pool/1/proj/node_modules/some-pkg"
  echo x > "$pool/1/proj/node_modules/some-pkg/index.js"
  printf 'node_modules/\n' > "$pool/1/proj/.gitignore"
  git -C "$pool/1/proj" add .gitignore
  git -C "$pool/1/proj" commit -q -m "add gitignore"
  git -C "$pool/1/proj" push -q origin HEAD:refs/heads/main

  make_pushed_clean_repo "$pool/2/proj"
  echo draft > "$pool/2/proj/unpublished-draft.md"
  mkdir -p "$pool/2/proj/node_modules/other-pkg"

  make_pushed_clean_repo "$pool/3/proj"

  fakebin=$(fm_fakebin "$case_dir")
  json=$(cat <<JSON
[{"name":"1","path":"$pool/1/proj","status":"available","lease_id":"","lease_holder":"","leased_at":null,"processes":[]},
{"name":"2","path":"$pool/2/proj","status":"available","lease_id":"","lease_holder":"","leased_at":null,"processes":[]},
{"name":"3","path":"$pool/3/proj","status":"in-use","lease_id":"","lease_holder":"","leased_at":null,"processes":[{"pid":1,"name":"zsh"}]}]
JSON
)
  fake_treehouse "$fakebin" "$json"
  printf '%s\n' "$pool"
}

test_dry_run_never_deletes_and_reports_would_free() {
  local case_dir pool fakebin out
  case_dir="$TMP_ROOT/dry-run"
  mkdir -p "$case_dir"
  pool=$(build_pool_fixture "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --treehouse-root "$case_dir/pool" 2>&1)

  case "$out" in
    *"dry-run"*) ;;
    *) fail "dry-run manifest header missing 'dry-run', got: $out" ;;
  esac
  case "$out" in
    *"WOULD-FREE"*"proj-abc123/1"*"node_modules"*) ;;
    *) fail "dry-run should list slot 1's node_modules as WOULD-FREE, got: $out" ;;
  esac
  case "$out" in
    *"SKIP"*"proj-abc123/2"*"skip:uncommitted-or-untracked-changes"*) ;;
    *) fail "dry-run should skip the dirty slot 2, got: $out" ;;
  esac
  case "$out" in
    *"SKIP"*"proj-abc123/3"*"skip:in-use"*) ;;
    *) fail "dry-run should skip the in-use slot 3, got: $out" ;;
  esac
  [ -d "$pool/1/proj/node_modules" ] || fail "dry-run must never delete anything, but slot 1's node_modules is gone"
  [ -d "$pool/2/proj/node_modules" ] || fail "dry-run must never delete anything, but slot 2's node_modules is gone"
  pass "fm-disk-reclaim.sh: dry-run reports candidates and skips without deleting anything"
}

test_apply_removes_only_the_safe_slot() {
  local case_dir pool fakebin out
  case_dir="$TMP_ROOT/apply"
  mkdir -p "$case_dir"
  pool=$(build_pool_fixture "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --apply --treehouse-root "$case_dir/pool" 2>&1)

  case "$out" in
    *"FREED"*"proj-abc123/1"*"node_modules"*) ;;
    *) fail "--apply should report slot 1's node_modules as FREED, got: $out" ;;
  esac
  [ -d "$pool/1/proj/node_modules" ] \
    && fail "--apply must remove the safe slot's node_modules, but it is still present"
  [ -d "$pool/2/proj/node_modules" ] \
    || fail "THE do-not-touch rule: --apply must NEVER remove the dirty slot's node_modules, but it is gone"
  [ -f "$pool/2/proj/unpublished-draft.md" ] \
    || fail "THE do-not-touch rule: --apply must never remove untracked content from a dirty slot"
  pass "fm-disk-reclaim.sh --apply: removes only the safe idle slot, never the dirty or in-use ones"
}

test_missing_treehouse_skips_gracefully() {
  local case_dir out
  case_dir="$TMP_ROOT/no-treehouse"
  mkdir -p "$case_dir"
  out=$(env PATH="$BASE_PATH" "$RECLAIM" --treehouse-root "$case_dir/pool" 2>&1)
  case "$out" in
    *"treehouse not found on PATH"*) ;;
    *) fail "a PATH with no treehouse should report the exact skip reason, got: $out" ;;
  esac
  pass "fm-disk-reclaim.sh: skips pool slot reclaim cleanly when treehouse is not installed"
}

test_unknown_pool_root_skips_gracefully() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/unknown-root"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  fake_treehouse "$fakebin" '[]'

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --treehouse-root "$case_dir/does-not-exist" 2>&1)
  case "$out" in
    *"no pool at"*) ;;
    *) fail "a nonexistent treehouse root should report the exact skip reason, got: $out" ;;
  esac
  pass "fm-disk-reclaim.sh: skips cleanly when the treehouse root does not exist"
}

test_docker_not_installed_is_reported() {
  local case_dir pool fakebin out
  case_dir="$TMP_ROOT/no-docker"
  mkdir -p "$case_dir"
  pool=$(build_pool_fixture "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --treehouse-root "$case_dir/pool" 2>&1)
  case "$out" in
    *"docker not installed - skipped"*) ;;
    *) fail "with no docker on PATH the manifest should say so, got: $out" ;;
  esac
  pass "fm-disk-reclaim.sh: reports Docker as skipped when it is not installed"
}

test_docker_daemon_unreachable_is_reported() {
  local case_dir pool fakebin out
  case_dir="$TMP_ROOT/docker-unreachable"
  mkdir -p "$case_dir"
  pool=$(build_pool_fixture "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/docker" <<'SH'
#!/usr/bin/env bash
[ "$1" = info ] && exit 1
exit 1
SH
  chmod +x "$fakebin/docker"

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --treehouse-root "$case_dir/pool" 2>&1)
  case "$out" in
    *"docker daemon not reachable - skipped"*) ;;
    *) fail "an unreachable docker daemon should be reported, got: $out" ;;
  esac
  pass "fm-disk-reclaim.sh: reports Docker as skipped when the daemon is unreachable"
}

test_docker_apply_never_touches_volumes_or_containers() {
  local case_dir pool fakebin out log
  case_dir="$TMP_ROOT/docker-apply"
  mkdir -p "$case_dir"
  pool=$(build_pool_fixture "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/docker.log"
  : > "$log"
  cat > "$fakebin/docker" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\$1" in
  info) exit 0 ;;
  images) exit 0 ;;
  image) [ "\$2" = prune ] && { echo "Total reclaimed space: 0B"; exit 0; }; exit 1 ;;
  builder) [ "\$2" = prune ] && { echo "Total reclaimed space: 0B"; exit 0; }; exit 1 ;;
  volume|container) echo "REFUSED: this stub should never be called for \$1" >&2; exit 9 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/docker"

  out=$(PATH="$fakebin:$BASE_PATH" "$RECLAIM" --apply --docker-age 12h --treehouse-root "$case_dir/pool" 2>&1)
  case "$out" in
    *"image prune (until=12h)"*) ;;
    *) fail "--docker-age should thread through to the image prune filter, got: $out" ;;
  esac
  if grep -qE '^(volume|container)' "$log"; then
    fail "fm-disk-reclaim.sh invoked docker volume/container - volumes and containers must never be touched"
  fi
  if ! grep -q '^image prune' "$log"; then
    fail "expected 'docker image prune' to have been invoked under --apply, log: $(cat "$log")"
  fi
  if ! grep -q '^builder prune' "$log"; then
    fail "expected 'docker builder prune' to have been invoked under --apply, log: $(cat "$log")"
  fi
  pass "fm-disk-reclaim.sh --apply: only prunes dangling images and build cache, never volumes or containers"
}

test_help_and_unknown_argument() {
  local out rc=0
  out=$("$RECLAIM" --help 2>&1)
  case "$out" in
    *"Usage: fm-disk-reclaim.sh"*) ;;
    *) fail "--help should print usage, got: $out" ;;
  esac
  out=$("$RECLAIM" --bogus-flag 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "an unknown argument should exit 2, got rc=$rc"
  pass "fm-disk-reclaim.sh: --help prints usage; an unknown argument is a usage error"
}

test_dry_run_never_deletes_and_reports_would_free
test_apply_removes_only_the_safe_slot
test_missing_treehouse_skips_gracefully
test_unknown_pool_root_skips_gracefully
test_docker_not_installed_is_reported
test_docker_daemon_unreachable_is_reported
test_docker_apply_never_touches_volumes_or_containers
test_help_and_unknown_argument
