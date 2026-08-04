#!/usr/bin/env bash
# Backward-compatible ISO8601 status-line parsing (status-timestamp-contract).
#
# Covers bin/fm-classify-lib.sh verb/note/key parsers and the brief scaffold's
# generated status protocol. Old bare lines and new timestamp-prefixed lines
# must classify identically.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-timestamp)
BRIEF="$ROOT/bin/fm-brief.sh"

test_status_line_body_strips_iso_prefix() {
  local body
  body=$(status_line_body '2026-07-19T12:00:00Z working: setup complete')
  [ "$body" = 'working: setup complete' ] \
    || fail "body strip failed: got '$body'"
  body=$(status_line_body 'working: setup complete')
  [ "$body" = 'working: setup complete' ] \
    || fail "bare body changed: got '$body'"
  body=$(status_line_body '  2026-07-19T12:00:00Z done: PR https://x/pull/1')
  [ "$body" = 'done: PR https://x/pull/1' ] \
    || fail "leading-space ISO body strip failed: got '$body'"
  # A line that merely mentions a Z timestamp in the note must not strip.
  body=$(status_line_body 'working: saw 2026-07-19T12:00:00Z marker')
  [ "$body" = 'working: saw 2026-07-19T12:00:00Z marker' ] \
    || fail "mid-line Z incorrectly stripped: got '$body'"
  pass "status_line_body: strips leading ISO8601 UTC prefix only"
}

test_verb_note_key_parity_old_and_new() {
  local bare_verb ts_verb bare_note ts_note bare_key ts_key

  bare_verb=$(status_line_verb 'needs-decision [key=api-shape]: choose shape')
  ts_verb=$(status_line_verb '2026-07-19T12:00:00Z needs-decision [key=api-shape]: choose shape')
  [ "$bare_verb" = 'needs-decision' ] || fail "bare verb=$bare_verb"
  [ "$ts_verb" = 'needs-decision' ] || fail "ts verb=$ts_verb (ISO colon broke parse)"

  bare_note=$(status_line_note 'needs-decision [key=api-shape]: choose shape')
  ts_note=$(status_line_note '2026-07-19T12:00:00Z needs-decision [key=api-shape]: choose shape')
  [ "$bare_note" = 'choose shape' ] || fail "bare note=$bare_note"
  [ "$ts_note" = 'choose shape' ] || fail "ts note=$ts_note"

  bare_key=$(_fm_decision_key 'needs-decision [key=api-shape]: choose shape')
  ts_key=$(_fm_decision_key '2026-07-19T12:00:00Z needs-decision [key=api-shape]: choose shape')
  [ "$bare_key" = 'api-shape' ] || fail "bare key=$bare_key"
  [ "$ts_key" = 'api-shape' ] || fail "ts key=$ts_key"

  # Legacy free-text and standard terminals still work with prefixes.
  status_is_captain_relevant '2026-07-19T12:00:00Z done: PR https://x/pull/1 checks green' \
    || fail "timestamped done not captain-relevant"
  status_is_captain_relevant '2026-07-19T12:00:00Z working: setup' \
    && fail "timestamped working wrongly captain-relevant"
  status_is_paused '2026-07-19T12:00:00Z paused: waiting on upstream' \
    || fail "timestamped paused not recognized"
  status_is_terminal_verb '2026-07-19T12:00:00Z blocked: need help' \
    || fail "timestamped blocked not terminal"

  pass "status parsers: old bare and new ISO-prefixed lines agree"
}

test_open_decisions_fold_with_timestamps() {
  local status open
  mkdir -p "$TMP_ROOT"
  status="$TMP_ROOT/mixed.status"
  cat >"$status" <<'EOF'
2026-07-19T10:00:00Z needs-decision [key=a]: first
working: unrelated
2026-07-19T11:00:00Z resolved [key=a]: decided
2026-07-19T12:00:00Z needs-decision [key=b]: second
blocked: tool missing
EOF
  open=$(status_open_decisions "$status")
  printf '%s\n' "$open" | grep -q $'b\tneeds-decision\t' \
    || fail "open set missing keyed needs-decision b"$'\n'"$open"
  printf '%s\n' "$open" | grep -q $'default\tblocked\t' \
    || fail "open set missing bare blocked"$'\n'"$open"
  printf '%s\n' "$open" | grep -q $'a\t' \
    && fail "resolved key a still open"$'\n'"$open"
  pass "status_open_decisions: ISO-prefixed open/resolve fold works"
}

test_crew_state_map_path_accepts_timestamped_status() {
  # fm-crew-state.sh sources fm-classify-lib.sh and maps status-log verbs via
  # status_line_verb / status_line_note / status_is_paused. Prove that path's
  # inputs work for ISO-prefixed lines the same way bare lines do (the full
  # crew-state fixture with fakes is covered elsewhere; this pins the parse).
  local line verb note state
  for line in \
    'blocked: need captain' \
    '2026-07-19T12:00:00Z blocked: need captain'
  do
    verb=$(status_line_verb "$line")
    note=$(status_line_note "$line")
    [ "$verb" = blocked ] || fail "map path verb for '$line' -> '$verb'"
    [ "$note" = 'need captain' ] || fail "map path note for '$line' -> '$note'"
  done
  for line in \
    'done: PR https://x/pull/3 checks green' \
    '2026-07-19T12:00:00Z done: PR https://x/pull/3 checks green'
  do
    done_verb=$(status_line_verb "$line")
    [ "$done_verb" = "done" ] || fail "done verb for '$line' -> '$done_verb'"
  done
  # crew-state also greps the script for the classify source (wiring guard)
  assert_grep 'fm-classify-lib.sh' "$ROOT/bin/fm-crew-state.sh" \
    "fm-crew-state.sh must source classify-lib for status parsing"
  pass "fm-crew-state status-log path: ISO and bare verbs/notes match"
}

test_brief_documents_iso_status_protocol() {
  local home brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data" "$home/state"
  # Minimal projects registry so ship mode resolves (default when absent is fine).
  cat >"$home/data/projects.md" <<'EOF'
- firstmate: no-mistakes
EOF
  FM_HOME="$home" "$BRIEF" brief-iso-task firstmate >/dev/null \
    || fail "fm-brief ship failed"
  brief="$home/data/brief-iso-task/brief.md"
  [ -f "$brief" ] || fail "brief not written"
  assert_grep 'date -u +%Y-%m-%dT%H:%M:%SZ' "$brief" \
    "ship brief missing ISO date -u status append recipe"
  assert_grep 'status-timestamp-contract' "$brief" \
    "ship brief missing status-timestamp-contract note"
  assert_grep 'legacy bare' "$brief" \
    "ship brief missing backward-compat note for bare status lines"

  FM_HOME="$home" "$BRIEF" brief-iso-scout firstmate --scout >/dev/null \
    || fail "fm-brief scout failed"
  brief="$home/data/brief-iso-scout/brief.md"
  assert_grep 'date -u +%Y-%m-%dT%H:%M:%SZ' "$brief" \
    "scout brief missing ISO status append recipe"
  pass "fm-brief: ship and scout scaffolds require ISO8601 status prefixes"
}

test_status_line_body_strips_iso_prefix
test_verb_note_key_parity_old_and_new
test_open_decisions_fold_with_timestamps
test_crew_state_map_path_accepts_timestamped_status
test_brief_documents_iso_status_protocol
