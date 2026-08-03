# Fleet Powerpipe inventory

This runbook owns the standing internal-only Powerpipe and Steampipe inventory on `gh-runner-t1` at `192.168.1.120`.
The AGPL tooling is approved for internal operations only and must not be embedded in a shipped product or exposed publicly.

## Current layout

- The dedicated `fleet-inventory` system user owns `/var/lib/fleet-inventory` and runs both services.
- The `ghrunner` identity, its groups, the GitHub Actions services, and `/usr/local/sbin/gh-runner-preflight` remain separate.
- Powerpipe `v1.5.2` listens on `127.0.0.1:9033` through `fleet-inventory.powerpipe.service`.
- Steampipe `v2.4.4` listens on `127.0.0.1:9193` and `[::1]:9193` through `fleet-inventory.steampipe.service`.
- The GCP plugin is installed in `/var/lib/fleet-inventory/steampipe` and the `gcp_insights` mod is installed in `/var/lib/fleet-inventory/powerpipe-workspace`.
- `/var/lib/fleet-inventory/steampipe/config/gcp.spc` defines the three project connections and the `gcp_all` aggregator.
- `/var/lib/fleet-inventory/gcp-reader.json` is mode `0600`, owned by `fleet-inventory:fleet-inventory`, and never belongs in Git.
- Doppler project `fleet-observability`, config `prd`, owns the credential as `FLEET_INVENTORY_GCP_READER_JSON`.
- `fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com` has organization-level `roles/viewer` and no mutation role.

Both systemd units use `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, and `NoNewPrivileges=true`.
The Steampipe unit must include `--database-listen local` because Steampipe `v2.4.4` defaults to a network listener.
The Powerpipe unit must include `--listen local`.

## Install or reconcile

The runner keeps the reviewed adoption package at `/var/lib/fleet-inventory/adoption-package`.
The stored Steampipe unit includes the required explicit loopback flag.

Before running the installer, confirm the credential file exists without reading it:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 \
  "sudo stat -c '%U:%G %a %n' /var/lib/fleet-inventory/gcp-reader.json"
```

The expected result is `fleet-inventory:fleet-inventory 600 /var/lib/fleet-inventory/gcp-reader.json`.
Run the idempotent installer from the runner copy:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 \
  'sudo bash /var/lib/fleet-inventory/adoption-package/install-on-gh-runner-t1.sh'
```

Always confirm that a reconcile retained both loopback flags before accepting the result:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 \
  'systemctl show fleet-inventory.steampipe.service -p ExecStart --value; systemctl show fleet-inventory.powerpipe.service -p ExecStart --value'
```

## Captain access

Open the local forward with this exact command:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key -o IdentitiesOnly=yes -L 9033:127.0.0.1:9033 ubuntu@192.168.1.120
```

Leave that session open and visit `http://127.0.0.1:9033`.
The multi-project report is `http://127.0.0.1:9033/gcp_insights.dashboard.project_report`.
Do not use Tailscale Serve, a public bind, a reverse proxy, or a firewall exception for this service.

## Validation

Verify service state, HTTP health, and listener scope on the runner:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 '
    set -eu
    systemctl is-enabled fleet-inventory.steampipe.service fleet-inventory.powerpipe.service
    systemctl is-active fleet-inventory.steampipe.service fleet-inventory.powerpipe.service
    curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9033/
    sudo ss -lntp | awk "NR == 1 || /:9033|:9193/"
    sudo /usr/local/sbin/gh-runner-preflight
  '
```

The only accepted inventory listeners are `127.0.0.1:9033`, `127.0.0.1:9193`, and `[::1]:9193`.
The runner admission command must return `PREFLIGHT_OK=true` without changing its policy or the `ghrunner` groups.

The package smoke file contains four independent SQL statements, so run each statement separately through the service identity:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 '
    set -eu
    while IFS= read -r query; do
      sudo -u fleet-inventory env \
        HOME=/var/lib/fleet-inventory \
        STEAMPIPE_INSTALL_DIR=/var/lib/fleet-inventory/steampipe \
        GOOGLE_APPLICATION_CREDENTIALS=/var/lib/fleet-inventory/gcp-reader.json \
        /usr/local/bin/steampipe query "$query" --output csv
    done < <(sudo grep "^select " /var/lib/fleet-inventory/smoke-queries.sql)
  '
```

Simulate reboot survival with a systemd restart, then repeat the health, listener, SQL, and admission checks:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 \
  'sudo systemctl restart fleet-inventory.steampipe.service fleet-inventory.powerpipe.service'
```

From another machine on the LAN, both direct probes must fail:

```sh
nc -z -w 2 192.168.1.120 9033
nc -z -w 2 192.168.1.120 9193
```

## Credential scope and rotation

Organization `750670751950` enforces the legacy boolean constraint `iam.disableServiceAccountKeyCreation`.
That organization policy remains enabled.
No project override remains during normal operation.

Key creation uses a temporary override only on project `cs-host-e77ac18f45de4a3887284f`, which hosts the dedicated inventory service account.
The operator creates one replacement key, deletes the project override immediately, and verifies that the project again inherits `enforce: true` before delivering the key.
Never disable the organization-level policy.

Rotate in this order:

1. Record the current user-managed key ID without printing private material.
2. Install an EXIT trap that deletes any temporary project policy.
3. Create a project policy at `projects/1096421561730/policies/iam.disableServiceAccountKeyCreation` with `enforce: false`.
4. Wait until the effective project policy reports `false`, then allow a short propagation interval.
5. Create exactly one replacement key and pipe its private data directly into Doppler secret `FLEET_INVENTORY_GCP_READER_JSON`.
6. Delete the project override and verify that the effective policy is `true` before continuing.
7. Stream the Doppler value to `/var/lib/fleet-inventory/gcp-reader.json.next`, set owner `fleet-inventory:fleet-inventory` and mode `0600`, then atomically replace the active file.
8. Restart both services and repeat the complete validation section.
9. Delete the old GCP key only after validation passes.

Use names-only Doppler output to confirm presence:

```sh
doppler secrets --project fleet-observability --config prd --only-names --json \
  | jq -e 'has("FLEET_INVENTORY_GCP_READER_JSON")'
```

Stream the vaulted value without placing it in a command argument or local file:

```sh
doppler secrets get FLEET_INVENTORY_GCP_READER_JSON \
  --project fleet-observability \
  --config prd \
  --plain \
  --raw \
  | ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
      -o IdentitiesOnly=yes \
      ubuntu@192.168.1.120 '
        set -eu
        sudo sh -c "umask 077; cat > /var/lib/fleet-inventory/gcp-reader.json.next"
        sudo chown fleet-inventory:fleet-inventory /var/lib/fleet-inventory/gcp-reader.json.next
        sudo chmod 0600 /var/lib/fleet-inventory/gcp-reader.json.next
        sudo mv /var/lib/fleet-inventory/gcp-reader.json.next /var/lib/fleet-inventory/gcp-reader.json
      '
```

## Teardown

Teardown requires explicit captain authority because it revokes credentials and removes a standing service.
Stop and disable the dedicated units first:

```sh
ssh -i /Users/fox/Code/firstmate/data/gh-runner-t1/ci_access_key \
  -o IdentitiesOnly=yes \
  ubuntu@192.168.1.120 '
    sudo systemctl disable --now fleet-inventory.powerpipe.service fleet-inventory.steampipe.service
    sudo install -d -m 0700 -o root -g root /var/lib/fleet-inventory-teardown
    sudo mv /etc/systemd/system/fleet-inventory.powerpipe.service /var/lib/fleet-inventory-teardown/
    sudo mv /etc/systemd/system/fleet-inventory.steampipe.service /var/lib/fleet-inventory-teardown/
    sudo mv /var/lib/fleet-inventory /var/lib/fleet-inventory-teardown/data
    sudo systemctl daemon-reload
  '
```

Confirm ports `9033` and `9193` are absent before revoking the GCP key and deleting `FLEET_INVENTORY_GCP_READER_JSON` from Doppler.
Remove the organization-level `roles/viewer` binding and delete the dedicated service account only when no other inventory consumer uses it.
Keep the recoverable runner backup until IAM revocation and the final admission-gate check both pass.

Use these commands only inside that approved teardown:

```sh
gcloud iam service-accounts keys list \
  --iam-account=fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com \
  --managed-by=user

gcloud iam service-accounts keys delete KEY_ID \
  --iam-account=fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com

doppler secrets delete FLEET_INVENTORY_GCP_READER_JSON \
  --project fleet-observability \
  --config prd

gcloud organizations remove-iam-policy-binding 750670751950 \
  --member=serviceAccount:fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com \
  --role=roles/viewer

gcloud iam service-accounts delete \
  fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com \
  --project=cs-host-e77ac18f45de4a3887284f
```
