#!/usr/bin/env bash
# Behavior tests for the home-scoped Better Stack incident poll.
#
# The API and Doppler boundary are both mocked.
# These tests make no live network or secret-store calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
. "$ROOT/bin/fm-supervision-lib.sh"

POLL="$ROOT/bin/fm-better-stack-incidents-poll.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-better-stack-incidents)

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/state" "$dir/home/config"
  chmod 0700 "$dir/home/state"

  cat > "$fakebin/doppler" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DOPPLER_LOG"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  shift
done
[ "${1:-}" = -- ] || exit 2
shift
exec env BETTER_STACK_API_TOKEN="${FM_TEST_BETTER_STACK_TOKEN:-}" "$@"
SH

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
[ "${FM_TEST_CURL_FAIL:-0}" = 0 ] || exit 7
printf '%s\n%s' "${FM_TEST_API_BODY:-}" "${FM_TEST_API_CODE:-200}"
SH
  chmod +x "$fakebin/doppler" "$fakebin/curl"
  : > "$dir/doppler.log"
  : > "$dir/curl.log"
  printf '%s\n' "$dir"
}

run_poll() {
  local dir=$1
  shift
  PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_TEST_DOPPLER_LOG="$dir/doppler.log" \
    FM_TEST_CURL_LOG="$dir/curl.log" \
    "$@" "$POLL"
}

incident_body() {
  local id=$1 name=${2:-api-production} started=${3:-2026-08-01T12:00:00.000Z}
  jq -cn --arg id "$id" --arg name "$name" --arg started "$started" \
    '{data: [{id: $id, type: "incident", attributes: {name: $name, started_at: $started, resolved_at: null, status: "Started"}}]}'
}

test_new_incident_and_duplicate_suppression() {
  local dir body out rc
  dir=$(make_case new-and-duplicate)
  body=$(incident_body 25 api-production)

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY="$body" FM_TEST_API_CODE=200); rc=$?
  expect_code 0 "$rc" "new incident poll exit"
  [ "$out" = 'better-stack-incident opened id=25 name=api-production started=2026-08-01T12:00:00.000Z' ] \
    || fail "new incident must print one compact identity line (got: $out)"
  assert_present "$dir/home/state/better-stack-incidents.seen/25" \
    "new incident must claim a private seen marker"

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY="$body" FM_TEST_API_CODE=200); rc=$?
  expect_code 0 "$rc" "duplicate incident poll exit"
  [ -z "$out" ] || fail "an already-seen incident must stay silent (got: $out)"

  assert_grep '--project fleet-observability --config prd' "$dir/doppler.log" \
    "poll must select the fleet-observability/prd Doppler scope"
  assert_grep '--no-fallback' "$dir/doppler.log" \
    "poll must prohibit Doppler fallback files"
  assert_grep '--only-secrets BETTER_STACK_API_TOKEN' "$dir/doppler.log" \
    "poll must inject only the Better Stack token"
  assert_grep 'https://uptime.betterstack.com/api/v3/incidents?resolved=false&per_page=50' \
    "$dir/curl.log" "poll must query unresolved Better Stack incidents"
  if grep -R -F 'synthetic-test-token' "$dir/home/state" "$dir/doppler.log" "$dir/curl.log" >/dev/null 2>&1; then
    fail "the Better Stack token reached private state or command logs"
  fi
  pass "new Better Stack incident wakes once and duplicate observations stay silent"
}

test_api_error_reports_once_and_recovers() {
  local dir out rc
  dir=$(make_case api-error)

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY='{"error":"unavailable"}' FM_TEST_API_CODE=503); rc=$?
  expect_code 0 "$rc" "API error poll exit"
  [ "$out" = 'better-stack-error API returned HTTP 503' ] \
    || fail "API error must produce one visible diagnostic (got: $out)"

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY='{"error":"unavailable"}' FM_TEST_API_CODE=503); rc=$?
  expect_code 0 "$rc" "repeated API error poll exit"
  [ -z "$out" ] || fail "repeated API failure must not produce a wake storm (got: $out)"

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY='{"data":[]}' FM_TEST_API_CODE=200); rc=$?
  expect_code 0 "$rc" "recovered API poll exit"
  [ -z "$out" ] || fail "successful recovery must stay silent (got: $out)"
  assert_absent "$dir/home/state/better-stack-incidents.diagnostics/error" \
    "successful API access must clear the diagnostic marker"

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_CURL_FAIL=1); rc=$?
  expect_code 0 "$rc" "unreachable API poll exit"
  [ "$out" = 'better-stack-error Better Stack API unreachable' ] \
    || fail "unreachable API must produce one visible diagnostic (got: $out)"
  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_CURL_FAIL=1); rc=$?
  expect_code 0 "$rc" "repeated unreachable API poll exit"
  [ -z "$out" ] || fail "repeated unreachable API failure must stay quiet (got: $out)"
  pass "Better Stack API failures surface once and recovery clears the diagnostic"
}

test_missing_token_reports_once() {
  local dir out rc
  dir=$(make_case missing-token)

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN='' \
    FM_TEST_API_BODY='{"data":[]}' FM_TEST_API_CODE=200); rc=$?
  expect_code 0 "$rc" "missing-token poll exit"
  [ "$out" = 'better-stack-error missing BETTER_STACK_API_TOKEN' ] \
    || fail "missing token must produce one visible diagnostic (got: $out)"

  out=$(run_poll "$dir" env \
    FM_TEST_BETTER_STACK_TOKEN='' \
    FM_TEST_API_BODY='{"data":[]}' FM_TEST_API_CODE=200); rc=$?
  expect_code 0 "$rc" "repeated missing-token poll exit"
  [ -z "$out" ] || fail "repeated missing-token failure must stay quiet (got: $out)"
  pass "missing Better Stack token produces one diagnostic without a wake storm"
}

test_registered_check_delivers_check_wake() {
  local dir state shim body out rc
  dir=$(make_case watcher-delivery)
  state="$dir/home/state"
  shim="$state/better-stack-incidents.check.sh"
  body=$(incident_body 91 web-production)
  cat > "$shim" <<SH
#!/usr/bin/env bash
export FM_HOME=$(printf '%q' "$dir/home")
exec $(printf '%q' "$POLL")
SH
  chmod 0700 "$shim"
  FM_HOME="$dir/home" "$REGISTER" better-stack-incidents >/dev/null \
    || fail "could not register Better Stack custom check"

  out=$(PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_DOPPLER_LOG="$dir/doppler.log" FM_TEST_CURL_LOG="$dir/curl.log" \
    FM_TEST_BETTER_STACK_TOKEN=synthetic-test-token \
    FM_TEST_API_BODY="$body" FM_TEST_API_CODE=200 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    "$WATCH"); rc=$?
  expect_code 0 "$rc" "watcher incident delivery exit"
  assert_contains "$out" "check: $shim: better-stack-incident opened id=91" \
    "registered poll output must become a check wake with the incident identity"
  [ "$(grep -c 'better-stack-incident opened id=91' "$state/.wake-queue")" -eq 1 ] \
    || fail "new incident must create exactly one durable wake record"
  pass "registered Better Stack poll delivers exactly one authenticated check wake"
}

test_bootstrap_arms_and_retires_home_check() {
  local dir home out sum1 sum2
  dir=$(make_case bootstrap)
  home="$dir/home"
  : > "$home/config/better-stack-incidents"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" 'BETTER_STACK: incident monitoring on' \
    "bootstrap must announce Better Stack incident monitoring"
  assert_present "$home/state/better-stack-incidents.check.sh" \
    "bootstrap must materialize the home-scoped custom check"
  assert_present "$home/state/better-stack-incidents.check-trust" \
    "bootstrap must register the custom check bytes"
  [ -x "$home/state/better-stack-incidents.check.sh" ] \
    || fail "Better Stack custom check must be executable"
  assert_grep 'fm-better-stack-incidents-poll.sh' "$home/state/better-stack-incidents.check.sh" \
    "custom check shim must invoke the tracked poll"

  sum1=$(cat "$home/state/better-stack-incidents.check.sh" \
    "$home/state/better-stack-incidents.check-trust" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/better-stack-incidents.check.sh" \
    "$home/state/better-stack-incidents.check-trust" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap incident activation must be idempotent"

  rm "$home/config/better-stack-incidents"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" 'BETTER_STACK: incident monitoring off' \
    "bootstrap must announce removal of an armed incident poll"
  assert_absent "$home/state/better-stack-incidents.check.sh" \
    "opt-out must remove the Better Stack custom check"
  assert_absent "$home/state/better-stack-incidents.check-trust" \
    "opt-out must remove the custom-check trust binding"
  pass "bootstrap idempotently arms and retires the home-scoped incident check"
}

test_incident_check_keeps_home_supervised() {
  local dir state
  dir=$(make_case supervision-need)
  state="$dir/home/state"
  : > "$state/better-stack-incidents.check.sh"

  fm_supervision_needed "$state" 300 \
    || fail "Better Stack incident monitoring must keep an otherwise-idle home supervised"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] \
    || fail "incident monitoring must not count as a project task"
  [ "$FM_SUP_NEEDED" = true ] \
    || fail "incident monitoring must set the home supervision need"
  pass "Better Stack incident polling remains supervised with no project work in flight"
}

test_new_incident_and_duplicate_suppression
test_api_error_reports_once_and_recovers
test_missing_token_reports_once
test_registered_check_delivers_check_wake
test_bootstrap_arms_and_retires_home_check
test_incident_check_keeps_home_supervised
