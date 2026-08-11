#!/usr/bin/env bash
# Behavior tests for the home-scoped Woodpecker creation-error poll.
#
# The API and Doppler boundary are both mocked.
# These tests make no live network or secret-store calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh disable=SC1091
. "$ROOT/bin/fm-supervision-lib.sh"

POLL="$ROOT/bin/fm-woodpecker-errors-poll.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-woodpecker-errors)

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/state" "$dir/home/config"
  chmod 0700 "$dir/home/state"
  printf 'appheat/bible-agents\n' > "$dir/home/config/woodpecker-error-repos"

  cat > "$fakebin/doppler" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_DOPPLER_LOG"
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  shift
done
[ "${1:-}" = -- ] || exit 2
shift
exec env WOODPECKER_ADMIN_TOKEN="${FM_TEST_WOODPECKER_TOKEN:-}" "$@"
SH

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
[ "${FM_TEST_CURL_FAIL:-0}" = 0 ] || exit 7
url=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --url ]; then
    url=${2:-}
    break
  fi
  shift
done
case "$url" in
  */api/repos/lookup/appheat/bible-agents) body=${FM_TEST_LOOKUP_BODY:-'{"id":77}'} ;;
  */api/repos/77/pipelines?perPage=10) body=${FM_TEST_PIPELINES_BODY:-'[]'} ;;
  *) body='{"message":"unexpected test URL"}' ;;
esac
printf '%s\n%s' "$body" "${FM_TEST_API_CODE:-200}"
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

test_error_pipeline_wakes_once() {
  local dir body out rc
  dir=$(make_case error-once)
  body='[{"number":40,"status":"error","errors":[{"message":"Insufficient trust level to use volumes"}]}]'

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=$'synthetic-test-token\n' \
    FM_TEST_PIPELINES_BODY="$body"); rc=$?
  expect_code 0 "$rc" "new error pipeline poll exit"
  [ "$out" = 'woodpecker-error appheat/bible-agents pipeline=40 Insufficient trust level to use volumes' ] \
    || fail "new error pipeline must print one compact line (got: $out)"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY="$body"); rc=$?
  expect_code 0 "$rc" "duplicate error pipeline poll exit"
  [ -z "$out" ] || fail "already-seen error pipeline must stay silent (got: $out)"

  assert_grep 'run -p fleet-ci -c prd --only-secrets WOODPECKER_ADMIN_TOKEN' "$dir/doppler.log" \
    "poll must inject only the Woodpecker token from fleet-ci/prd"
  assert_grep 'https://ci.appheat.co/api/repos/lookup/appheat/bible-agents' "$dir/curl.log" \
    "poll must resolve the configured repository through the GET lookup endpoint"
  assert_grep 'https://ci.appheat.co/api/repos/77/pipelines?perPage=10' "$dir/curl.log" \
    "poll must request the latest ten pipelines through GET"
  assert_grep '--request GET' "$dir/curl.log" "poll must use GET for every Woodpecker request"
  if grep -R -F 'synthetic-test-token' "$dir/home/state" "$dir/doppler.log" "$dir/curl.log" >/dev/null 2>&1; then
    fail "the Woodpecker token reached private state or command logs"
  fi
  pass "new Woodpecker error pipeline wakes once and duplicate observations stay silent"
}

test_non_error_statuses_stay_silent() {
  local dir body out rc
  dir=$(make_case non-errors)
  body='[{"number":41,"status":"failure","errors":[{"message":"step failed"}]},{"number":42,"status":"success"},{"number":43,"status":"killed"}]'

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY="$body"); rc=$?
  expect_code 0 "$rc" "non-error pipeline poll exit"
  [ -z "$out" ] || fail "failure, success, and killed pipelines must stay silent (got: $out)"
  pass "only creation-error status wakes; failure, success, and killed are planted negatives"
}

test_missing_doppler_and_token_report_once() {
  local dir out rc
  dir=$(make_case missing-dependencies)

  out=$(PATH="$BASE_PATH" FM_HOME="$dir/home" "$POLL"); rc=$?
  expect_code 0 "$rc" "missing Doppler poll exit"
  [ "$out" = 'woodpecker-poll-error Doppler access unavailable for fleet-ci/prd' ] \
    || fail "missing Doppler must print one diagnostic (got: $out)"
  out=$(PATH="$BASE_PATH" FM_HOME="$dir/home" "$POLL"); rc=$?
  expect_code 0 "$rc" "repeated missing Doppler poll exit"
  [ -z "$out" ] || fail "repeated missing Doppler must stay silent (got: $out)"

  rm -rf "$dir/home/state/woodpecker-errors.diagnostics"
  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=''); rc=$?
  expect_code 0 "$rc" "missing token poll exit"
  [ "$out" = 'woodpecker-poll-error missing WOODPECKER_ADMIN_TOKEN' ] \
    || fail "missing token must print one diagnostic (got: $out)"
  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=''); rc=$?
  expect_code 0 "$rc" "repeated missing token poll exit"
  [ -z "$out" ] || fail "repeated missing token must stay silent (got: $out)"
  pass "missing Doppler and token diagnostics are deduped and non-fatal"
}

test_empty_repo_config_reports_once() {
  local dir out rc
  dir=$(make_case empty-repos)
  : > "$dir/home/config/woodpecker-error-repos"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token); rc=$?
  expect_code 0 "$rc" "empty repository config poll exit"
  [ "$out" = 'woodpecker-poll-error config/woodpecker-error-repos has no repositories' ] \
    || fail "empty repository config must print one diagnostic (got: $out)"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token); rc=$?
  expect_code 0 "$rc" "repeated empty repository config poll exit"
  [ -z "$out" ] || fail "repeated empty repository config must stay silent (got: $out)"
  assert_present "$dir/home/state/woodpecker-errors.diagnostics/error" \
    "empty repository diagnostic must remain published"
  pass "empty repository configuration diagnostics are deduped"
}

test_invalid_receipt_reports_once() {
  local dir state out rc
  dir=$(make_case invalid-receipt)
  state="$dir/home/state"
  mkdir -p "$state/woodpecker-errors.receipts"
  printf 'not-a-woodpecker-receipt\n' \
    > "$state/woodpecker-errors.receipts/repo-77-pipeline-40"
  chmod 0600 "$state/woodpecker-errors.receipts/repo-77-pipeline-40"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY='[{"number":40,"status":"error","errors":[{"message":"blocked"}]}]'); rc=$?
  expect_code 0 "$rc" "invalid receipt poll exit"
  [ "$out" = 'woodpecker-poll-error invalid Woodpecker wake receipt' ] \
    || fail "invalid receipt must print one diagnostic (got: $out)"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY='[{"number":40,"status":"error","errors":[{"message":"blocked"}]}]'); rc=$?
  expect_code 0 "$rc" "repeated invalid receipt poll exit"
  [ -z "$out" ] || fail "repeated invalid receipt must stay silent (got: $out)"
  assert_absent "$state/woodpecker-errors.seen/repo-77-pipeline-40" \
    "invalid receipt must not fabricate a seen marker"
  assert_absent "$state/.wake-queue" \
    "invalid receipt direct poll must not fabricate a durable wake"
  pass "invalid Woodpecker receipts produce one deduplicated diagnostic"
}

test_short_timeout_fails_fast_once() {
  local dir start elapsed out rc
  dir=$(make_case short-timeout)

  start=$SECONDS
  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_CHECK_TIMEOUT=1); rc=$?
  elapsed=$((SECONDS - start))
  expect_code 0 "$rc" "short timeout poll exit"
  [ "$out" = 'woodpecker-poll-error Woodpecker API poll timed out' ] \
    || fail "short timeout must print one timeout diagnostic (got: $out)"
  [ "$elapsed" -le 1 ] || fail "short timeout poll exceeded its one-second budget"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_CHECK_TIMEOUT=1); rc=$?
  expect_code 0 "$rc" "repeated short timeout poll exit"
  [ -z "$out" ] || fail "repeated short timeout must stay silent (got: $out)"
  pass "short timeout fails fast and deduplicates its diagnostic"
}

test_registered_check_delivers_one_wake_per_pipeline() {
  local dir state shim body rc wake_count
  dir=$(make_case watcher-delivery)
  state="$dir/home/state"
  shim="$state/woodpecker-errors.check.sh"
  body='[{"number":40,"status":"error","errors":[{"message":"first error"}]},{"number":41,"status":"error","errors":[{"message":"second error"}]}]'
  cat > "$shim" <<SH
#!/usr/bin/env bash
export FM_HOME=$(printf '%q' "$dir/home")
exec $(printf '%q' "$POLL")
SH
  chmod 0700 "$shim"
  FM_HOME="$dir/home" "$REGISTER" woodpecker-errors >/dev/null \
    || fail "could not register Woodpecker custom check"

  PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_DOPPLER_LOG="$dir/doppler.log" FM_TEST_CURL_LOG="$dir/curl.log" \
    FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY="$body" \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    "$WATCH" >/dev/null; rc=$?
  expect_code 0 "$rc" "watcher Woodpecker delivery exit"
  assert_grep 'pipeline=40 first error' "$state/.wake-queue" \
    "the first pipeline must become a durable check wake"
  assert_grep 'pipeline=41 second error' "$state/.wake-queue" \
    "the second pipeline must become a durable check wake"
  wake_count=$(awk -F '\t' '$3 == "check" { count++ } END { print count + 0 }' "$state/.wake-queue")
  [ "$wake_count" -eq 2 ] \
    || fail "two error pipelines must create two durable wake records (got: $wake_count)"
  pass "registered Woodpecker poll delivers one durable wake per new pipeline"
}

test_woodpecker_receipt_recovers_after_poll_boundary() {
  local dir state shim body out rc
  dir=$(make_case receipt-recovery)
  state="$dir/home/state"
  shim="$state/woodpecker-errors.check.sh"
  body='[{"number":40,"status":"error","errors":[{"message":"boundary error"}]}]'
  cat > "$shim" <<SH
#!/usr/bin/env bash
export FM_HOME=$(printf '%q' "$dir/home")
exec $(printf '%q' "$POLL")
SH
  chmod 0700 "$shim"
  FM_HOME="$dir/home" "$REGISTER" woodpecker-errors >/dev/null \
    || fail "could not register receipt-recovery custom check"

  out=$(run_poll "$dir" env FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY="$body"); rc=$?
  expect_code 0 "$rc" "receipt-recovery direct poll exit"
  [ "$out" = 'woodpecker-error appheat/bible-agents pipeline=40 boundary error' ] \
    || fail "direct poll must emit the new error before watcher recovery (got: $out)"
  assert_present "$state/woodpecker-errors.receipts/repo-77-pipeline-40" \
    "direct poll must leave a wake receipt for the watcher"

  out=$(PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_DOPPLER_LOG="$dir/doppler.log" FM_TEST_CURL_LOG="$dir/curl.log" \
    FM_TEST_WOODPECKER_TOKEN=synthetic-test-token \
    FM_TEST_PIPELINES_BODY="$body" FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 "$WATCH"); rc=$?
  expect_code 0 "$rc" "receipt-recovery watcher exit"
  [ "$(grep -c 'woodpecker-error:repo-77-pipeline-40' "$state/.wake-queue")" -eq 1 ] \
    || fail "receipt recovery must append exactly one durable Woodpecker wake"
  assert_absent "$state/woodpecker-errors.receipts/repo-77-pipeline-40" \
    "receipt recovery must retire the committed wake receipt"
  pass "Woodpecker receipt recovers a wake across the poll-to-watcher boundary"
}

test_bootstrap_arms_and_retires_home_check() {
  local dir home out sum1 sum2
  dir=$(make_case bootstrap)
  home="$dir/home"
  : > "$home/config/woodpecker-error-poll"

  out=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" 'WOODPECKER_ERRORS: monitoring on' \
    "bootstrap must announce Woodpecker error monitoring"
  assert_present "$home/state/woodpecker-errors.check.sh" \
    "bootstrap must materialize the home-scoped custom check"
  assert_present "$home/state/woodpecker-errors.check-trust" \
    "bootstrap must register the custom check bytes"
  [ -x "$home/state/woodpecker-errors.check.sh" ] \
    || fail "Woodpecker custom check must be executable"
  sum1=$(cat "$home/state/woodpecker-errors.check.sh" \
    "$home/state/woodpecker-errors.check-trust" | shasum)
  PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null
  sum2=$(cat "$home/state/woodpecker-errors.check.sh" \
    "$home/state/woodpecker-errors.check-trust" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap activation must be idempotent"

  rm "$home/config/woodpecker-error-poll"
  out=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" 'WOODPECKER_ERRORS: monitoring off' \
    "bootstrap must announce removal of an armed Woodpecker poll"
  assert_absent "$home/state/woodpecker-errors.check.sh" \
    "opt-out must remove the Woodpecker custom check"
  assert_absent "$home/state/woodpecker-errors.check-trust" \
    "opt-out must remove the custom-check trust binding"
  pass "bootstrap idempotently arms and retires the Woodpecker error check"
}

test_woodpecker_check_keeps_home_supervised() {
  local dir state
  dir=$(make_case supervision-need)
  state="$dir/home/state"
  : > "$state/woodpecker-errors.check.sh"

  fm_supervision_needed "$state" 300 \
    || fail "Woodpecker error monitoring must keep an otherwise-idle home supervised"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] \
    || fail "Woodpecker monitoring must not count as a project task"
  [ "$FM_SUP_NEEDED" = true ] \
    || fail "Woodpecker monitoring must set the home supervision need"
  pass "Woodpecker error polling remains supervised with no project work in flight"
}

test_error_pipeline_wakes_once
test_non_error_statuses_stay_silent
test_missing_doppler_and_token_report_once
test_empty_repo_config_reports_once
test_invalid_receipt_reports_once
test_short_timeout_fails_fast_once
test_registered_check_delivers_one_wake_per_pipeline
test_woodpecker_receipt_recovers_after_poll_boundary
test_bootstrap_arms_and_retires_home_check
test_woodpecker_check_keeps_home_supervised
