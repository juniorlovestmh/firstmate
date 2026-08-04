#!/usr/bin/env bash
# Behavior tests for bin/fm-analytics-export.sh Slice 1.
#
# Fixture home in, golden snapshot fields out. The exporter is read-only on
# inputs, mutates only data/analytics/, and is idempotent per day.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPORT="$ROOT/bin/fm-analytics-export.sh"
TMP_ROOT=$(fm_test_tmproot fm-analytics-export)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fixture_home() {
  local home=$TMP_ROOT/home
  mkdir -p "$home/data" "$home/state"
  cat >"$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] ship-alpha - Ship Alpha (repo: alpha) (kind: ship) (since 2026-07-20)
- [ ] scout-beta - Scout Beta data/scout-beta/report.md (repo: beta) (kind: scout) (since 2026-07-21)

## Queued
- [ ] queued-gamma - Queued Gamma (repo: gamma) (kind: ship) (since 2026-07-22)

## Done
- [x] done-delta - Done Delta https://github.com/example/r/pull/9 (repo: delta) (kind: ship) (merged 2026-07-18)
EOF

  cat >"$home/data/done-archive.md" <<'EOF'
# Done archive
- [x] archived-old - Archived Old (repo: old) (kind: ship) (done 2026-07-01)
EOF

  # Mixed legacy bare lines and ISO8601-prefixed lines (status-timestamp-contract).
  cat >"$home/state/ship-alpha.status" <<'EOF'
working: setup complete
2026-07-20T10:00:00Z needs-decision [key=api]: choose shape
2026-07-20T11:00:00Z resolved [key=api]: go with option a
2026-07-20T12:00:00Z working: implementing
blocked: tool missing
resolved: tool installed
working: resuming after block
done: PR https://github.com/example/r/pull/12 checks green
EOF

  cat >"$home/state/scout-beta.status" <<'EOF'
working: scouting
failed: could not reproduce
working: retried after failure
done: report written
EOF

  # Residual status with no backlog row still exports.
  cat >"$home/state/orphan-epsilon.status" <<'EOF'
working: leftover
EOF

  cat >"$home/state/mismatch-zeta.status" <<'EOF'
needs-decision [key=alpha]: choose alpha
resolved [key=beta]: chose beta
EOF

  cat >"$home/state/reopened-eta.status" <<'EOF'
failed: first attempt failed
working: retrying
EOF

  cat >"$home/data/learnings.md" <<'EOF'
# Learnings

## 2026-07-10 - Stale no-mistakes stored base lands on wrong branch
First occurrence of the stale base theme.

## 2026-08-02 - Stale no-mistakes stored base lands on wrong branch
Second incident of the same root-cause class.

## 2026-08-03 - A full local disk is the fleet's silent corrupter
Unique class once.

## Not a dated header
Body text that must never appear in the export.
secret-token-should-not-leak
EOF

  printf '%s\n' "$home"
}

assert_json() {  # <file> <jq-expr> <expected>
  local file=$1 expr=$2 expected=$3 got
  # Use tostring so boolean false does not trip jq -e (false is a valid value).
  got=$(jq -r "$expr | tostring" "$file") || fail "jq failed on $expr for $file"
  [ "$got" = "$expected" ] || fail "$expr: expected '$expected', got '$got'"
}

test_export_golden_fixture() {
  local home snap tsv
  home=$(make_fixture_home)
  FM_HOME="$home" \
    FM_ANALYTICS_DATE=2026-07-22 \
    FM_ANALYTICS_NOW=2026-07-22T15:30:00Z \
    "$EXPORT" >/dev/null || fail "exporter exited non-zero"

  snap="$home/data/analytics/snapshots/2026-07-22.json"
  tsv="$home/data/analytics/snapshots/2026-07-22.tsv"
  [ -f "$snap" ] || fail "missing JSON snapshot"
  [ -f "$tsv" ] || fail "missing TSV snapshot"
  [ -f "$home/data/analytics/SCHEMA_VERSION" ] || fail "missing SCHEMA_VERSION"
  assert_grep 'fm-analytics.v1' "$home/data/analytics/SCHEMA_VERSION" "schema version file"

  assert_json "$snap" '.schema' 'fm-analytics.v1'
  assert_json "$snap" '.day' '2026-07-22'
  assert_json "$snap" '.exported_at' '2026-07-22T15:30:00Z'
  assert_json "$snap" '.backlog.in_flight' '2'
  assert_json "$snap" '.backlog.queued' '1'
  assert_json "$snap" '.backlog.done_kept' '1'
  assert_json "$snap" '.backlog.done_archived' '1'

  # ship-alpha: 8 events, 1 needs-decision, 2 resolved, 1 blocked, 2 respawns
  # (working after resolved, twice), done_with_pr true
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .events' '8'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .verbs["needs-decision"]' '1'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .verbs.resolved' '2'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .decision_pairs' '1'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .respawns' '2'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .done_with_pr' 'true'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .failed_terminal' 'false'
  assert_json "$snap" '.tasks[] | select(.id=="ship-alpha") | .last_verb' 'done'

  # scout-beta: working after failed counts as respawn; last done is not PR
  assert_json "$snap" '.tasks[] | select(.id=="scout-beta") | .respawns' '1'
  assert_json "$snap" '.tasks[] | select(.id=="scout-beta") | .done_with_pr' 'false'
  assert_json "$snap" '.tasks[] | select(.id=="scout-beta") | .verbs.failed' '1'

  # orphan residual status included
  assert_json "$snap" '.tasks[] | select(.id=="orphan-epsilon") | .events' '1'

  # Keyed decision folding must not pair unrelated keys.
  assert_json "$snap" '.tasks[] | select(.id=="mismatch-zeta") | .decision_pairs' '0'
  assert_json "$snap" '.tasks[] | select(.id=="mismatch-zeta") | .failed_terminal' 'false'

  # A later progress event reopens a task after failure.
  assert_json "$snap" '.tasks[] | select(.id=="reopened-eta") | .failed_terminal' 'false'

  # queued-gamma has no status file: still listed with zero events
  assert_json "$snap" '.tasks[] | select(.id=="queued-gamma") | .events' '0'

  # Repeat-incident: one class appears twice
  assert_json "$snap" '.repeat_incidents.repeated_class_count' '1'
  assert_json "$snap" '.repeat_incidents.learnings_entries' '3'

  # Privacy: no free-form notes, secrets, or absolute home path in the snapshot
  if grep -E 'choose shape|secret-token|tool missing|could not reproduce' "$snap" >/dev/null; then
    fail "snapshot leaked free-form status/learnings body text"
  fi
  if grep -F "$home" "$snap" >/dev/null; then
    fail "snapshot leaked absolute FM_HOME path"
  fi

  # TSV header and ship-alpha row (fixed-string assert_grep; match without anchors)
  assert_grep $'id\tevents\tworking\tneeds_decision' "$tsv" "TSV header"
  assert_grep $'ship-alpha\t8\t' "$tsv" "ship-alpha TSV row"
  assert_grep $'mismatch-zeta\t2\t0\t1\t1\t0\t0\t0\t0\t0\t0\t0\t0\tresolved' "$tsv" "keyed decision TSV row"
  assert_grep $'reopened-eta\t2\t1\t0\t0\t0\t0\t1\t0\t1\t0\t0\t0\tworking' "$tsv" "reopened failure TSV row"

  pass "fm-analytics-export: golden fixture snapshot matches expected counts"
}

test_idempotent_per_day() {
  local home snap1 snap2
  home=$(make_fixture_home)
  FM_HOME="$home" FM_ANALYTICS_DATE=2026-07-22 FM_ANALYTICS_NOW=2026-07-22T10:00:00Z \
    "$EXPORT" >/dev/null || fail "first export failed"
  snap1=$(cat "$home/data/analytics/snapshots/2026-07-22.json")
  FM_HOME="$home" FM_ANALYTICS_DATE=2026-07-22 FM_ANALYTICS_NOW=2026-07-22T18:00:00Z \
    "$EXPORT" >/dev/null || fail "second export failed"
  snap2=$(cat "$home/data/analytics/snapshots/2026-07-22.json")
  # Same day path overwritten; exported_at updates but day and counts stable.
  echo "$snap2" | jq -e '.day == "2026-07-22"' >/dev/null \
    || fail "day changed on re-export"
  echo "$snap2" | jq -e '.exported_at == "2026-07-22T18:00:00Z"' >/dev/null \
    || fail "exported_at not updated on re-export"
  echo "$snap1" | jq -e --argjson a "$(echo "$snap2" | jq '.summary')" '.summary == $a' >/dev/null \
    || fail "summary drifted on re-export of unchanged inputs"
  # Only one snapshot file for the day
  count=$(find "$home/data/analytics/snapshots" -name '2026-07-22.*' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected one json + one tsv for the day, got $count paths"
  pass "fm-analytics-export: re-run overwrites same-day snapshot (idempotent path)"
}

test_does_not_mutate_inputs() {
  local home before after
  home=$(make_fixture_home)
  before=$(find "$home/data/backlog.md" "$home/data/done-archive.md" \
    "$home/data/learnings.md" "$home/state" -type f -exec cksum {} \; | sort)
  FM_HOME="$home" FM_ANALYTICS_DATE=2026-07-22 FM_ANALYTICS_NOW=2026-07-22T15:30:00Z \
    "$EXPORT" >/dev/null || fail "export failed"
  after=$(find "$home/data/backlog.md" "$home/data/done-archive.md" \
    "$home/data/learnings.md" "$home/state" -type f -exec cksum {} \; | sort)
  [ "$before" = "$after" ] || fail "exporter mutated durable inputs"
  pass "fm-analytics-export: inputs unchanged after export"
}

test_export_golden_fixture
test_idempotent_per_day
test_does_not_mutate_inputs
