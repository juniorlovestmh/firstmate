#!/usr/bin/env bash
# Rotate the fleet-inventory GCP reader key through the project-scoped policy exception.
# Usage: fm-fleet-inventory-rotate.sh [--help]
#
# The command owns one replacement key, Doppler vaulting, validated remote delivery,
# policy restoration, service validation, and old-key deletion.
set -Eeuo pipefail

readonly PROJECT_ID="${FLEET_INVENTORY_PROJECT_ID:-cs-host-e77ac18f45de4a3887284f}"
readonly SERVICE_ACCOUNT="${FLEET_INVENTORY_SERVICE_ACCOUNT:-fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com}"
readonly EXPECTED_CLIENT_EMAIL="${FLEET_INVENTORY_CLIENT_EMAIL:-$SERVICE_ACCOUNT}"
readonly DOPPLER_PROJECT="${FLEET_INVENTORY_DOPPLER_PROJECT:-fleet-observability}"
readonly DOPPLER_CONFIG="${FLEET_INVENTORY_DOPPLER_CONFIG:-prd}"
readonly SECRET_NAME="FLEET_INVENTORY_GCP_READER_JSON"
readonly RUNNER="${FLEET_INVENTORY_RUNNER:-ubuntu@192.168.1.120}"
readonly SSH_KEY="${FLEET_INVENTORY_SSH_KEY:-/Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key}"
readonly REMOTE_KEY="/var/lib/fleet-inventory/gcp-reader.json"
readonly KEY_POLL_ATTEMPTS="${FLEET_INVENTORY_KEY_POLL_ATTEMPTS:-10}"
readonly KEY_POLL_INTERVAL="${FLEET_INVENTORY_KEY_POLL_INTERVAL:-1}"

usage() {
  cat <<'EOF'
Usage: fm-fleet-inventory-rotate.sh [--help]

Rotate the fleet-inventory reader key without printing or writing private key material locally.
External gcloud, Doppler, jq, and ssh commands are required.
EOF
}

die() {
  printf 'fm-fleet-inventory-rotate.sh: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || die "unexpected argument: $1"

old_keys=$(gcloud iam service-accounts keys list \
  --iam-account="$SERVICE_ACCOUNT" --managed-by=user --format='value(name.basename())')
old_key_count=$(printf '%s\n' "$old_keys" | awk 'NF { count++ } END { print count + 0 }')
[ "$old_key_count" -eq 1 ] || die "expected exactly one existing user-managed key, found $old_key_count"
old_key_id=$(printf '%s\n' "$old_keys" | awk 'NF { print; exit }')

policy_changed=0
key_created=0
key_cleanup_armed=1
new_key_id=""
key_id_file=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-inventory-key-id.XXXXXX")

load_created_key_id() {
  local key_id_line
  [ -s "$key_id_file" ] || return 1
  key_id_line=$(awk 'NR == 1 { print; exit }' "$key_id_file")
  case "$key_id_line" in
    KEYID=*) new_key_id=${key_id_line#KEYID=} ;;
    *) return 1 ;;
  esac
  [ -n "$new_key_id" ]
}

replacement_is_addressable() {
  local current_keys current_key_count old_key_present replacement_present
  current_keys=$(gcloud iam service-accounts keys list \
    --iam-account="$SERVICE_ACCOUNT" --managed-by=user --format='value(name.basename())') || return 1
  current_key_count=$(printf '%s\n' "$current_keys" | awk 'NF { count++ } END { print count + 0 }')
  old_key_present=$(printf '%s\n' "$current_keys" | awk -v old="$old_key_id" '$0 == old { print "yes"; exit }')
  replacement_present=$(printf '%s\n' "$current_keys" | awk -v replacement="$new_key_id" '$0 == replacement { print "yes"; exit }')
  [ "$current_key_count" -eq 2 ] && [ "$old_key_present" = "yes" ] \
    && [ "$replacement_present" = "yes" ]
}

wait_for_replacement() {
  local attempt
  for ((attempt = 1; attempt <= KEY_POLL_ATTEMPTS; attempt++)); do
    if replacement_is_addressable; then
      return 0
    fi
    if [ "$attempt" -lt "$KEY_POLL_ATTEMPTS" ]; then
      sleep "$KEY_POLL_INTERVAL"
    fi
  done
  return 1
}

cleanup_new_key() {
  [ "$key_created" -eq 1 ] || return 0
  load_created_key_id || {
    printf 'fm-fleet-inventory-rotate.sh: cannot load the replacement key ID for cleanup\n' >&2
    return 1
  }
  wait_for_replacement || {
    printf 'fm-fleet-inventory-rotate.sh: replacement key was not addressable for cleanup\n' >&2
    return 1
  }
  gcloud iam service-accounts keys delete "$new_key_id" \
    --iam-account="$SERVICE_ACCOUNT" --quiet || return 1
  key_created=0
}

restore_policy() {
  if [ "$policy_changed" -eq 1 ]; then
    if ! gcloud resource-manager org-policies delete iam.disableServiceAccountKeyCreation \
      --project="$PROJECT_ID"; then
      printf 'fm-fleet-inventory-rotate.sh: project key-creation policy removal failed\n' >&2
      return 1
    fi
    if [ "$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
      --project="$PROJECT_ID" --effective --format='value(booleanPolicy.enforced)')" != "True" ]; then
      printf 'fm-fleet-inventory-rotate.sh: project key-creation policy was not restored\n' >&2
      return 1
    fi
    policy_changed=0
  fi
}

on_exit() {
  local status=$?
  if ! restore_policy; then
    status=1
  fi
  if [ "$key_cleanup_armed" -eq 1 ] && ! cleanup_new_key; then
    status=1
  fi
  rm -f "$key_id_file"
  exit "$status"
}
trap on_exit EXIT

gcloud resource-manager org-policies disable-enforce iam.disableServiceAccountKeyCreation \
  --project="$PROJECT_ID"
policy_changed=1
[ "$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
  --project="$PROJECT_ID" --effective --format='value(booleanPolicy.enforced)')" = "False" ] \
  || die "project key-creation policy did not become disabled"

key_created=1
gcloud iam service-accounts keys create /dev/stdout --iam-account="$SERVICE_ACCOUNT" --format=json \
  | jq -e --arg expected "$EXPECTED_CLIENT_EMAIL" \
      'select(type == "object" and .type == "service_account" and .client_email == $expected and (.private_key_id | type == "string")) | (.private_key_id | "KEYID=" + .) as $id | (($id | stderr) as $ignored | .)' \
      2>"$key_id_file" \
  | doppler secrets set "$SECRET_NAME" --project="$DOPPLER_PROJECT" \
      --config="$DOPPLER_CONFIG" --value-stdin >/dev/null
load_created_key_id || die "key creation did not return a replacement key ID"
wait_for_replacement || die "replacement key did not become an addressable distinct second key"

restore_policy

doppler secrets get "$SECRET_NAME" --project="$DOPPLER_PROJECT" --config="$DOPPLER_CONFIG" \
  --plain --raw \
  | ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "$RUNNER" \
      "sudo bash -c 'set -Eeuo pipefail; tmp=\"$REMOTE_KEY.next\"; trap '\''rm -f \"\$tmp\"'\'' EXIT; umask 077; cat > \"\$tmp\"; jq -e --arg expected \"$EXPECTED_CLIENT_EMAIL\" '\''type == \"object\" and .type == \"service_account\" and .client_email == \$expected'\'' \"\$tmp\" >/dev/null; chown fleet-inventory:fleet-inventory \"\$tmp\"; chmod 0600 \"\$tmp\"; mv -f \"\$tmp\" \"$REMOTE_KEY\"; trap - EXIT'"

ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "$RUNNER" \
  "sudo bash -s -- '$REMOTE_KEY'" <<'REMOTE_VALIDATE'
set -Eeuo pipefail
remote_key=$1

sudo systemctl restart fleet-inventory.steampipe.service fleet-inventory.powerpipe.service
sudo systemctl is-active fleet-inventory.steampipe.service fleet-inventory.powerpipe.service
curl -fsS http://127.0.0.1:9033/ >/dev/null
sudo ss -H -lnt | awk '
BEGIN {
  expected["127.0.0.1:9033"] = 1
  expected["127.0.0.1:9193"] = 1
  expected["[::1]:9193"] = 1
}
{
  local_address = $4
  if (local_address in expected) {
    seen[local_address]++
  } else if (local_address ~ /:9033$/ || local_address ~ /:9193$/) {
    invalid = 1
  }
}
END {
  if (invalid || seen["127.0.0.1:9033"] != 1 || seen["127.0.0.1:9193"] != 1 || seen["[::1]:9193"] != 1) {
    exit 1
  }
}'
sudo /usr/local/sbin/gh-runner-preflight
mapfile -t queries < <(sudo grep -E '^[[:space:]]*select[[:space:]]' /var/lib/fleet-inventory/smoke-queries.sql)
[ "${#queries[@]}" -eq 4 ]
executed=0
for query in "${queries[@]}"; do
  sudo -u fleet-inventory env \
      HOME=/var/lib/fleet-inventory \
      STEAMPIPE_INSTALL_DIR=/var/lib/fleet-inventory/steampipe \
      GOOGLE_APPLICATION_CREDENTIALS="$remote_key" \
      /usr/local/bin/steampipe query "$query" --output csv
  executed=$((executed + 1))
done
[ "$executed" -eq 4 ]
REMOTE_VALIDATE

key_cleanup_armed=0
gcloud iam service-accounts keys delete "$old_key_id" --iam-account="$SERVICE_ACCOUNT" --quiet
printf 'fleet-inventory key rotation: ok\n'
