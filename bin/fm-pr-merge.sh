#!/usr/bin/env bash
# Merge a task's PR only after its actual base ref matches the expected base,
# then record pr= and any available pr_head= through bin/fm-pr-check.sh so
# teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Expected base authority is, in order: an explicit --expect-base, the task's
# single intended_base= metadata value, or the repository default branch read
# from the GitHub API. The PR's actual base is always read fresh from that API.
# Any unreadable or mismatched value refuses before PR metadata is recorded.
#
# GitLab URLs remain refused before any forge call because this script has no
# GitLab merge path: its argument forwarding and merge invocation are explicitly
# gh-axi-specific. The GitLab watch documented in docs/gitlab-merge-watch.md is
# not a merge path, so there is no GitLab merge here on which to skip this guard.
# A future GitLab merge path must compare the API's target_branch by the same
# authority order before invoking glab.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--expect-base <branch>] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

EXPLICIT_EXPECTED_BASE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-base)
      [ -z "$EXPLICIT_EXPECTED_BASE" ] && [ "$#" -ge 2 ] || {
        echo "error: invalid --expect-base argument" >&2
        exit 2
      }
      EXPLICIT_EXPECTED_BASE=$2
      shift 2
      ;;
    --expect-base=*)
      [ -z "$EXPLICIT_EXPECTED_BASE" ] || {
        echo "error: invalid --expect-base argument" >&2
        exit 2
      }
      EXPLICIT_EXPECTED_BASE=${1#--expect-base=}
      shift
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done
[ -z "$EXPLICIT_EXPECTED_BASE" ] || fm_pr_base_ref_valid "$EXPLICIT_EXPECTED_BASE" || {
  echo "error: invalid --expect-base argument" >&2
  exit 2
}

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

normalize_api_scalar() {
  local value=$1
  case "$value" in
    \"*\")
      value=${value#\"}
      value=${value%\"}
      case "$value" in *\\*) return 1 ;; esac
      ;;
  esac
  fm_pr_base_ref_valid "$value" || return 1
  printf '%s\n' "$value"
}

github_pr_base() {
  local response value
  response=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER") || return 1
  value=$(printf '%s\n' "$response" | awk '
    $0 == "base:" { in_base = 1; next }
    in_base && /^  ref: / { sub(/^  ref: /, ""); print; exit }
  ')
  [ -n "$value" ] || return 1
  normalize_api_scalar "$value"
}

github_default_base() {
  local response value
  response=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO") || return 1
  value=$(printf '%s\n' "$response" | awk '/^default_branch: / { sub(/^default_branch: /, ""); print; exit }')
  [ -n "$value" ] || return 1
  normalize_api_scalar "$value"
}

print_guarded_rerun() {
  local arg
  printf '  %q %q %q --expect-base %q' "$0" "$ID" "$URL" "$EXPECTED_BASE" >&2
  if [ "$#" -gt 0 ]; then
    printf ' --' >&2
    for arg in "$@"; do
      printf ' %q' "$arg" >&2
    done
  fi
  printf '\n' >&2
}

EXPECTED_BASE=
EXPECTED_SOURCE=
if [ -n "$EXPLICIT_EXPECTED_BASE" ]; then
  EXPECTED_BASE=$EXPLICIT_EXPECTED_BASE
  EXPECTED_SOURCE='explicit --expect-base'
else
  INTENDED_BASE_COUNT=$(awk '/^intended_base=/ { count++ } END { print count + 0 }' "$META")
  if [ "$INTENDED_BASE_COUNT" -gt 1 ]; then
    echo "REFUSED: task metadata has multiple intended_base values; expected-base authority is ambiguous." >&2
    exit 1
  fi
  if [ "$INTENDED_BASE_COUNT" -eq 1 ]; then
    EXPECTED_BASE=$(awk '/^intended_base=/ { sub(/^intended_base=/, ""); print; exit }' "$META")
    fm_pr_base_ref_valid "$EXPECTED_BASE" || {
      echo "REFUSED: task metadata has an invalid intended_base value; expected-base authority is ambiguous." >&2
      exit 1
    }
    EXPECTED_SOURCE='task intended_base metadata'
  else
    EXPECTED_BASE=$(github_default_base) || {
      echo "REFUSED: could not read a valid repository default branch from the GitHub API; expected base is ambiguous." >&2
      exit 1
    }
    EXPECTED_SOURCE='repository default branch'
  fi
fi

ACTUAL_BASE=$(github_pr_base) || {
  echo "REFUSED: could not read a valid actual PR base from the GitHub API; no merge was attempted." >&2
  exit 1
}

if [ "$ACTUAL_BASE" != "$EXPECTED_BASE" ]; then
  echo "REFUSED: PR base mismatch; no merge was attempted." >&2
  echo "  actual base: $ACTUAL_BASE" >&2
  echo "  expected base: $EXPECTED_BASE ($EXPECTED_SOURCE)" >&2
  echo "Retarget the PR to the expected base, then rerun exactly:" >&2
  print_guarded_rerun "$@"
  exit 1
fi

if [ -n "$EXPLICIT_EXPECTED_BASE" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" --intended-base "$EXPLICIT_EXPECTED_BASE"
else
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
fi
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
