#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-translation)

test_captain_facing_scout_path_preserves_evidence_and_action() {
  local home id report
  home="$TMP_ROOT/home"
  id="captain-translation"

  FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null 2>&1 \
    || fail "scout brief generation failed"
  report="$home/data/$id/brief.md"
  assert_present "$report" "scout brief was not generated"
  assert_grep '# Definition of done' "$report" "scout brief lacks a completion contract"
  assert_grep 'what you did, what you found, the evidence' "$report" \
    "scout brief does not require concrete evidence in its report"
  assert_grep 'what you recommend' "$report" \
    "scout brief does not require a concrete recommendation"
  pass "captain-facing scout work preserves evidence and recommendation handoff"
}

test_captain_facing_scout_path_preserves_evidence_and_action
