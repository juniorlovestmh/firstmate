#!/usr/bin/env bash
# Public-interface behavior tests for the fleet-inventory connection deployment command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIGURE="$ROOT/bin/fm-fleet-inventory-configure.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-inventory-configure)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/commands.log"
CALL_COUNT="$TMP_ROOT/call-count"
KEY="$TMP_ROOT/ci-access-key"

cat >"$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
count=0
if [ -f "$FM_CONFIGURE_CALL_COUNT" ]; then
  count=$(cat "$FM_CONFIGURE_CALL_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FM_CONFIGURE_CALL_COUNT"
printf 'ssh %s\n' "$*" >>"$FM_CONFIGURE_LOG"
cat >"$FM_CONFIGURE_TMP/stdin-$count"
SH
chmod +x "$FAKEBIN/ssh"
: >"$KEY"

test_help_is_public() {
  local out
  out=$("$CONFIGURE" --help) || fail "configure help failed"
  assert_contains "$out" "atomically deploy" "configure help is incomplete"
  assert_contains "$out" "restarts only the fleet-inventory services" "service boundary is missing from help"
  pass "configure exposes its deployment and service boundary"
}

test_check_lists_the_complete_inventory() {
  local out
  out=$("$CONFIGURE" --check) || fail "config validation failed"
  assert_contains "$out" "fleet-inventory config: 9 projects" "project count is incomplete"
  assert_contains "$out" "fleet-inventory config: disabled APIs ignored" "disabled APIs can break aggregate inventory"
  for project in \
    appheat-billing-export \
    bible-agents-stg-15d299 \
    cs-hc-4cb97f9cdd7c417d89bb6e1e \
    cs-hc-c097fcc6a9674f5e941dda5d \
    cs-host-e77ac18f45de4a3887284f \
    cs-poc-ihtrpvjwhfhjcgbdxnvrggc \
    gen-lang-client-0716059536 \
    google-mpf-74jsxkcveyfq \
    tab-agent-stg-21d842; do
    assert_contains "$out" "fleet-inventory config project: $project" "missing project: $project"
  done
  pass "configure validates all confirmed active fleet projects"
}

test_check_rejects_incomplete_aggregator() {
  local config out
  config="$TMP_ROOT/incomplete.spc"
  sed '/^    "gcp_tab_stg"$/d' "$ROOT/docs/examples/fleet-inventory-gcp.spc" >"$config"
  if out=$("$CONFIGURE" --check --config "$config" 2>&1); then
    fail "incomplete gcp_all aggregator was accepted"
  fi
  assert_contains "$out" "gcp_all aggregator must include every project connection" \
    "incomplete aggregator diagnostic is missing"
  pass "configure rejects incomplete aggregators"
}

test_deploy_streams_config_and_limits_the_restart() {
  local remote_program
  : >"$LOG"
  : >"$CALL_COUNT"
  FM_CONFIGURE_CALL_COUNT="$CALL_COUNT" FM_CONFIGURE_LOG="$LOG" FM_CONFIGURE_TMP="$TMP_ROOT" \
    FLEET_INVENTORY_SSH_KEY="$KEY" PATH="$FAKEBIN:$PATH" "$CONFIGURE" >"$TMP_ROOT/out" 2>&1 \
    || fail "mocked config deployment failed: $(cat "$TMP_ROOT/out")"
  cmp -s "$ROOT/docs/examples/fleet-inventory-gcp.spc" "$TMP_ROOT/stdin-1" \
    || fail "deployment did not stream the tracked config unchanged"
  remote_program=$(cat "$TMP_ROOT/stdin-2")
  assert_contains "$remote_program" "assert_no_orphan_plugin_manager" "competing Steampipe process guard is missing"
  assert_contains "$remote_program" "systemctl stop fleet-inventory.powerpipe.service" "Powerpipe dependency stop is missing"
  assert_contains "$remote_program" "systemctl restart fleet-inventory.steampipe.service" "Steampipe restart is missing"
  assert_contains "$remote_program" "wait_for_steampipe" "Steampipe stability check is missing"
  assert_contains "$remote_program" "assert_loopback_listeners" "exact listener validation is missing"
  assert_contains "$remote_program" "127.0.0.1:9033" "Powerpipe loopback listener is not enforced"
  assert_contains "$remote_program" "[::1]:9193" "IPv6 Steampipe loopback listener is not enforced"
  assert_contains "$remote_program" "systemctl start fleet-inventory.powerpipe.service" "Powerpipe reattachment start is missing"
  assert_contains "$remote_program" "gcp_insights.dashboard.project_report" "dashboard verification is missing"
  if printf '%s\n' "$remote_program" | grep -Fq '/usr/local/bin/steampipe query'; then fail "deployment launched a competing Steampipe query process"; fi
  if printf '%s\n' "$remote_program" | grep -Eq 'actions\.runner|gh-runner-preflight'; then fail "deployment crossed into CI runner services"; fi
  [ "$(cat "$CALL_COUNT")" -eq 2 ] || fail "deployment did not use the expected two SSH phases"
  pass "deploy streams the tracked config and touches only inventory services"
}

test_help_is_public
test_check_lists_the_complete_inventory
test_check_rejects_incomplete_aggregator
test_deploy_streams_config_and_limits_the_restart
