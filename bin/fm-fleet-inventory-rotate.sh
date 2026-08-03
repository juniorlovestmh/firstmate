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
restore_policy() {
  if [ "$policy_changed" -eq 1 ]; then
    gcloud resource-manager org-policies delete iam.disableServiceAccountKeyCreation \
      --project="$PROJECT_ID"
    [ "$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
      --project="$PROJECT_ID" --effective --format='value(booleanPolicy.enforced)')" = "True" ] \
      || die "project key-creation policy was not restored"
    policy_changed=0
  fi
}

on_exit() {
  local status=$?
  if ! restore_policy; then
    status=1
  fi
  exit "$status"
}
trap on_exit EXIT

gcloud resource-manager org-policies disable-enforce iam.disableServiceAccountKeyCreation \
  --project="$PROJECT_ID"
policy_changed=1
[ "$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
  --project="$PROJECT_ID" --effective --format='value(booleanPolicy.enforced)')" = "False" ] \
  || die "project key-creation policy did not become disabled"

gcloud iam service-accounts keys create /dev/stdout --iam-account="$SERVICE_ACCOUNT" --format=json \
  | jq -e --arg expected "$EXPECTED_CLIENT_EMAIL" \
      'type == "object" and .type == "service_account" and .client_email == $expected' \
  | doppler secrets set "$SECRET_NAME" --project="$DOPPLER_PROJECT" \
      --config="$DOPPLER_CONFIG" --value-stdin >/dev/null

restore_policy

doppler secrets get "$SECRET_NAME" --project="$DOPPLER_PROJECT" --config="$DOPPLER_CONFIG" \
  --plain --raw \
  | ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "$RUNNER" \
      "sudo bash -c 'set -Eeuo pipefail; tmp=\"$REMOTE_KEY.next\"; trap '\''rm -f \"\$tmp\"'\'' EXIT; umask 077; cat > \"\$tmp\"; jq -e --arg expected \"$EXPECTED_CLIENT_EMAIL\" '\''type == \"object\" and .type == \"service_account\" and .client_email == \$expected'\'' \"\$tmp\" >/dev/null; chown fleet-inventory:fleet-inventory \"\$tmp\"; chmod 0600 \"\$tmp\"; mv -f \"\$tmp\" \"$REMOTE_KEY\"; trap - EXIT'"

ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "$RUNNER" \
  "sudo systemctl restart fleet-inventory.steampipe.service fleet-inventory.powerpipe.service && systemctl is-active fleet-inventory.steampipe.service fleet-inventory.powerpipe.service && curl -fsS http://127.0.0.1:9033/ >/dev/null && sudo ss -lntp | awk 'NR == 1 || /:9033|:9193/' && sudo /usr/local/sbin/gh-runner-preflight && sudo -u fleet-inventory env HOME=/var/lib/fleet-inventory STEAMPIPE_INSTALL_DIR=/var/lib/fleet-inventory/steampipe GOOGLE_APPLICATION_CREDENTIALS=$REMOTE_KEY bash -c 'while IFS= read -r query; do /usr/local/bin/steampipe query \"\$query\" --output csv; done < <(grep \"^select \" /var/lib/fleet-inventory/smoke-queries.sql)'"

gcloud iam service-accounts keys delete "$old_key_id" --iam-account="$SERVICE_ACCOUNT" --quiet
printf 'fleet-inventory key rotation: ok\n'
