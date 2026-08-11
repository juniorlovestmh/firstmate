#!/usr/bin/env bash
# Read-only scan for unrecorded work in ~/.treehouse/*/*/<repo> worktrees.
# Usage: fm-muster.sh
# Prints one line per worktree that is dirty, has no origin counterpart for its
# checked-out branch, or is ahead of that origin branch. Clean pushed worktrees
# produce no output. FM_TREEHOUSE_ROOT_OVERRIDE is a test-only root override.
set -u

case "${1:-}" in
  -h|--help)
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) echo "usage: fm-muster.sh" >&2; exit 2 ;;
esac

treehouse_root=${FM_TREEHOUSE_ROOT_OVERRIDE:-$HOME/.treehouse}
[ -d "$treehouse_root" ] || exit 0

for worktree in "$treehouse_root"/*/*/*; do
  [ -d "$worktree" ] || continue
  [ "$(git -C "$worktree" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] || continue

  reasons=
  if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null || true)" ]; then
    reasons=dirty
  fi

  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    if ! git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      [ -z "$reasons" ] || reasons="$reasons; "
      reasons="${reasons}no origin/$branch"
    else
      ahead=$(git -C "$worktree" rev-list --count "origin/$branch..HEAD" 2>/dev/null || true)
      if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
        [ -z "$reasons" ] || reasons="$reasons; "
        reasons="${reasons}ahead of origin/$branch by $ahead"
      fi
    fi
  fi

  [ -z "$reasons" ] || printf '%s: %s\n' "$worktree" "$reasons"
done
