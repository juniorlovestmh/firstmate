# Fleet Powerpipe inventory

This runbook owns the standing internal-only Powerpipe and Steampipe inventory on `gh-runner-t1` at `192.168.1.120`.
The AGPL tooling is approved for internal operations only and must not be embedded in a shipped product or exposed publicly.

## Current layout

- The dedicated `fleet-inventory` system user owns `/var/lib/fleet-inventory` and runs both services.
- The `ghrunner` identity, its groups, the GitHub Actions services, and `/usr/local/sbin/gh-runner-preflight` remain separate.
- Powerpipe `v1.5.2` listens on `127.0.0.1:9033` through `fleet-inventory.powerpipe.service`.
- Steampipe `v2.4.4` listens on `127.0.0.1:9193` and `[::1]:9193` through `fleet-inventory.steampipe.service`.
- The GCP plugin is installed in `/var/lib/fleet-inventory/steampipe` and the `gcp_insights` mod is installed in `/var/lib/fleet-inventory/powerpipe-workspace`.
- [`examples/fleet-inventory-gcp.spc`](examples/fleet-inventory-gcp.spc) defines every confirmed active fleet project connection and the `gcp_all` aggregator.
- `/var/lib/fleet-inventory/steampipe/config/gcp.spc` is the deployed copy of that tracked configuration.
- `/var/lib/fleet-inventory/gcp-reader.json` is mode `0600`, owned by `fleet-inventory:fleet-inventory`, and never belongs in Git.
- Doppler project `fleet-observability`, config `prd`, owns the credential as `FLEET_INVENTORY_GCP_READER_JSON`.
- `fleet-inventory-reader@cs-host-e77ac18f45de4a3887284f.iam.gserviceaccount.com` has organization-level `roles/viewer` and no mutation role.

Both systemd units use `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, and `NoNewPrivileges=true`.
The Steampipe unit must include `--database-listen local` because Steampipe `v2.4.4` defaults to a network listener.
The Powerpipe unit must include `--listen local`.

## Install or reconcile

The original installation was hand-provisioned from a private adoption package and had no tracked connection-config owner.
The repository now owns connection reconciliation through [`fm-fleet-inventory-configure.sh`](../bin/fm-fleet-inventory-configure.sh) and [`examples/fleet-inventory-gcp.spc`](examples/fleet-inventory-gcp.spc).
The runner keeps the reviewed adoption package at `/var/lib/fleet-inventory/adoption-package`, and its stored Steampipe unit includes the required explicit loopback flag.

Validate the tracked inventory without contacting the runner:

```sh
bin/fm-fleet-inventory-configure.sh --check
```

Deploy the tracked configuration atomically, restart Steampipe and Powerpipe in dependency order, and verify the loopback Powerpipe root and multi-project dashboard endpoints:

```sh
bin/fm-fleet-inventory-configure.sh
```

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

For dashboard proof, open the report for the configured project connection under review.
For each project, select its connection, wait for all panels to render, confirm the project identifier in the page, and capture a screenshot showing the dashboard and selected project.
Save task-record screenshots under `.captain-evidence/fleet-powerpipe/<connection>.png` at the worktree root.
Screenshots are untracked evidence for the captain's archive and must not be committed.

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
    curl -fsS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9033/gcp_insights.dashboard.project_report
    sudo ss -lntp | awk "NR == 1 || /:9033|:9193/"
    sudo /usr/local/sbin/gh-runner-preflight
  '
```

The only accepted inventory listeners are `127.0.0.1:9033`, `127.0.0.1:9193`, and `[::1]:9193`.
The runner admission command must return `PREFLIGHT_OK=true` without changing its policy or the `ghrunner` groups.

Do not run `steampipe query` as a second process while `fleet-inventory.steampipe.service` is running.
During a restart its plugin processes report transient reattachment errors, and a competing process may attempt to bind the service port.
Use the running dashboard endpoints and systemd service state for standing-service verification.
The repository reconcile command refuses to restart when it detects a Steampipe plugin manager outside the inventory service cgroup.
If that guard fires, stop the competing Steampipe command and rerun the reconcile; do not kill the service-owned plugin manager.

Exercise the service restart path through the repository reconcile, then repeat the service, dashboard, listener, and admission checks:

```sh
bin/fm-fleet-inventory-configure.sh
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

Run the repository-owned executable, which records the current key ID without printing private material, installs an EXIT trap, disables and restores only the host-project policy, creates exactly one replacement key, validates `type=service_account` and the expected `client_email` before vaulting, delivers the vaulted value through a pipe, validates it remotely before an atomic mode-0600 replacement, restarts both services, runs smoke and admission checks, and deletes the old key only after green validation:

```sh
bin/fm-fleet-inventory-rotate.sh
```

The script's policy restoration runs both on success and failure, and its post-restore check requires the effective project policy to report `True`.
Do not reproduce the rotation sequence manually or place a key in a command argument, local file, log, or report.

Use names-only Doppler output to confirm presence:

```sh
doppler secrets --project fleet-observability --config prd --only-names --json \
  | jq -e 'has("FLEET_INVENTORY_GCP_READER_JSON")'
```

The executable uses `set -Eeuo pipefail` for both credential pipelines, so a failed Doppler read, SSH delivery, or JSON validation cannot atomically replace the active credential.

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
