#!/usr/bin/env bash
# Public-interface behavior tests for the fleet-inventory credential rotation command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROTATE="$ROOT/bin/fm-fleet-inventory-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-inventory-rotate)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/commands.log"
VAULT="$TMP_ROOT/vault.json"
DELIVERED="$TMP_ROOT/delivered.json"
KEY_LIST_COUNT="$TMP_ROOT/key-list-count"

cat >"$FAKEBIN/gcloud" <<'SH'
#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >>"$FM_ROTATE_LOG"
case "$*" in
  *"keys list"*)
    count=0
    if [ -f "$FM_KEY_LIST_COUNT" ]; then count=$(cat "$FM_KEY_LIST_COUNT"); fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$FM_KEY_LIST_COUNT"
    if [ "${FM_STALE_KEY_LIST:-0}" -eq 1 ] || [ "$count" -eq 1 ]; then printf 'old-key\n'; else printf 'old-key\nnew-key\n'; fi
    ;;
  *"keys create"*) printf '%s\n' '{"type":"service_account","private_key_id":"new-key","client_email":"fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com"}' ;;
  *"booleanPolicy.enforced"*) if [ -e "$FM_POLICY_MARKER" ]; then printf 'True\n'; else printf 'False\n'; fi ;;
  *"org-policies delete"*)
    [ "${FM_FAIL_POLICY_RESTORE:-0}" -eq 0 ] || exit 1
    : >"$FM_POLICY_MARKER"
    ;;
  *"keys delete new-key"*)
    [ "${FM_FAIL_NEW_KEY_DELETE:-0}" -eq 0 ] || exit 1
    ;;
esac
SH
cat >"$FAKEBIN/doppler" <<'SH'
#!/usr/bin/env bash
printf 'doppler %s\n' "$*" >>"$FM_ROTATE_LOG"
case "$*" in
  *"secrets set"*)
    cat >"$FM_VAULT"
    [ "${FM_FAIL_DOPPLER_SET:-0}" -eq 0 ]
    ;;
  *"secrets get"*) cat "$FM_VAULT" ;;
esac
SH
cat >"$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$FM_ROTATE_LOG"
if [[ "$*" == *"gcp-reader.json.next"* ]]; then
  cat >"$FM_DELIVERED"
elif [ "${FM_FAIL_REMOTE:-0}" -eq 1 ]; then
  exit 1
else
  cat >>"$FM_ROTATE_LOG"
fi
SH
cat >"$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
exec /usr/bin/jq "$@"
SH
chmod +x "$FAKEBIN"/{gcloud,doppler,ssh,jq}

test_help_is_public() {
  local out
  out=$("$ROTATE" --help) || fail "rotation help failed"
  assert_contains "$out" "Rotate the fleet-inventory reader key" "rotation help is incomplete"
  pass "rotation exposes a public help entrypoint"
}

test_rotation_orders_restore_delivery_validation_and_deletion() {
  local out
  : >"$LOG"
  FM_ROTATE_LOG="$LOG" FM_VAULT="$VAULT" FM_DELIVERED="$DELIVERED" FM_POLICY_MARKER="$TMP_ROOT/restored" FM_KEY_LIST_COUNT="$KEY_LIST_COUNT" FLEET_INVENTORY_KEY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$ROTATE" >"$TMP_ROOT/out" 2>&1 \
    || fail "mocked rotation failed: $(cat "$TMP_ROOT/out")"
  out=$(cat "$TMP_ROOT/out")
  assert_contains "$out" "fleet-inventory key rotation: ok" "rotation did not report success"
  [ "$(wc -l <"$VAULT" | tr -d ' ')" -gt 0 ] || fail "vault did not receive credential stream"
  cmp -s "$VAULT" "$DELIVERED" || fail "delivered credential differs from vaulted credential"
  jq -e '.type == "service_account" and .private_key_id == "new-key" and .client_email == "fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com"' "$VAULT" >/dev/null \
    || fail "vault did not receive the complete validated credential object"
  [ -e "$TMP_ROOT/restored" ] || fail "policy restoration was not executed"
  [ "$(grep -c 'keys create' "$LOG")" -eq 1 ] || fail "rotation did not create exactly one replacement key"
  [ "$(grep -c 'keys delete' "$LOG")" -eq 1 ] || fail "old key was not deleted once"
  grep -q 'systemctl restart' "$LOG" || fail "service restart validation was not requested"
  pass "rotation restores policy, validates delivery, restarts services, then deletes old key"
}

test_failed_vaulting_cleans_only_replacement_key() {
  local rc
  : >"$LOG"
  rc=0
  FM_ROTATE_LOG="$LOG" FM_VAULT="$VAULT" FM_DELIVERED="$DELIVERED" FM_POLICY_MARKER="$TMP_ROOT/restored-failure" FM_KEY_LIST_COUNT="$TMP_ROOT/key-list-count-failure" FM_FAIL_DOPPLER_SET=1 FLEET_INVENTORY_KEY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$ROTATE" >"$TMP_ROOT/failure-out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "failed vaulting unexpectedly succeeded"
  grep -q 'keys delete new-key' "$LOG" || fail "replacement key was not cleaned up"
  ! grep -q 'keys delete old-key' "$LOG" || fail "original key was deleted during cleanup"
  [ -e "$TMP_ROOT/restored-failure" ] || fail "policy was not restored after vaulting failure"
  pass "failed vaulting cleans only the replacement key"
}

test_failed_remote_validation_cleans_only_replacement_key() {
  local rc
  : >"$LOG"
  rc=0
  FM_ROTATE_LOG="$LOG" FM_VAULT="$VAULT" FM_DELIVERED="$DELIVERED" FM_POLICY_MARKER="$TMP_ROOT/restored-remote-failure" FM_KEY_LIST_COUNT="$TMP_ROOT/key-list-count-remote-failure" FM_FAIL_REMOTE=1 FLEET_INVENTORY_KEY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$ROTATE" >"$TMP_ROOT/remote-failure-out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "failed remote validation unexpectedly succeeded"
  grep -q 'keys delete new-key' "$LOG" || fail "replacement key was not cleaned up after remote failure"
  ! grep -q 'keys delete old-key' "$LOG" || fail "original key was deleted after remote failure"
  pass "failed remote validation cleans only the replacement key"
}

test_stale_key_listing_never_deletes_original() {
  local rc
  : >"$LOG"
  rc=0
  FM_ROTATE_LOG="$LOG" FM_VAULT="$VAULT" FM_DELIVERED="$DELIVERED" FM_POLICY_MARKER="$TMP_ROOT/restored-stale" FM_KEY_LIST_COUNT="$TMP_ROOT/key-list-count-stale" FM_STALE_KEY_LIST=1 FLEET_INVENTORY_KEY_POLL_ATTEMPTS=2 FLEET_INVENTORY_KEY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$ROTATE" >"$TMP_ROOT/stale-out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "stale key listing unexpectedly succeeded"
  ! grep -q 'keys delete old-key' "$LOG" || fail "original key was deleted after stale listing"
  pass "stale key listing preserves the original key"
}

test_restore_and_cleanup_failures_are_both_attempted() {
  local rc
  : >"$LOG"
  rc=0
  FM_ROTATE_LOG="$LOG" FM_VAULT="$VAULT" FM_DELIVERED="$DELIVERED" FM_POLICY_MARKER="$TMP_ROOT/restored-double-failure" FM_KEY_LIST_COUNT="$TMP_ROOT/key-list-count-double-failure" FM_FAIL_REMOTE=1 FM_FAIL_POLICY_RESTORE=1 FM_FAIL_NEW_KEY_DELETE=1 FLEET_INVENTORY_KEY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$ROTATE" >"$TMP_ROOT/double-failure-out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "combined restore and cleanup failures unexpectedly succeeded"
  grep -q 'org-policies delete' "$LOG" || fail "policy restoration was not attempted"
  grep -q 'keys delete new-key' "$LOG" || fail "replacement cleanup was not attempted after restore failure"
  ! grep -q 'keys delete old-key' "$LOG" || fail "original key was deleted during combined failure"
  pass "restore and replacement cleanup failures are both attempted"
}

test_help_is_public
test_rotation_orders_restore_delivery_validation_and_deletion
test_failed_vaulting_cleans_only_replacement_key
test_failed_remote_validation_cleans_only_replacement_key
test_stale_key_listing_never_deletes_original
test_restore_and_cleanup_failures_are_both_attempted
