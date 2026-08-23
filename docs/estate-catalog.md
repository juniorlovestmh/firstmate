# Estate catalog

The home-private estate catalog is the file-based source of truth that Firstmate consults before infra-shaped planning or dispatch.
It keeps agent decisions independent of SaaS authentication and prevents existing fleet infrastructure from becoming invisible.

The real catalog lives under `data/estate-catalog/`, which remains private because `data/` is ignored as a whole.
The tracked [schema and examples](examples/estate-catalog/) define the portable contract without publishing a captain's actual estate.

## Layout

```text
data/estate-catalog/
├── declared/   # operator-authored facts that collectors cannot own
├── generated/  # collector-authored snapshots
└── compiled/
    ├── estate.json  # sole agent-facing query input
    └── estate.md    # human-readable projection
```

Every source file is one YAML document with `schema_version: 1`, one `kind`, and a non-empty `entities` array.
Every entity carries `source`, `collected_at`, and `authority` in addition to its kind-specific fields.
Files under `declared/` must use `source: declarative`, while files under `generated/` must use `source: collected`.
Entity identities must be unique across the whole catalog, and compilation refuses conflicting truth instead of choosing a winner.

| Kind | Identity | Required fields |
| --- | --- | --- |
| `system` | `id` | `id`, `owner`, `product`, `lifecycle` |
| `repository` | `id` | `id`, `github`, `delivery_mode`, `verify_cmd`, `ci`, `base_branch` |
| `host` | `id` | `id`, `provider`, optional `vmid`, `ip`, `role`, `ssh_path` |
| `service` | `id` | `id`, `system`, `host`, `url`, optional `health_url`, `deploy_path` |
| `ci` | `id` | `id`, `product`, optional `host`, `url`, `agent_labels`, `notes` |
| `dns` | `name` | `name`, `provider`, `target`, `purpose` |
| `tunnel` | `id` | `id`, `provider`, `hostname`, `backend` |
| `saas` | `product@account` | `product`, `account`, `purpose`, `limit_posture` |
| `database` | `id` | `id`, `engine`, `host_ref`, `app`, `env` |
| `secret_project` | `doppler_project` | `doppler_project`, `configs`, `apps` |

The literal string `unknown` is a legal bootstrap placeholder for a required field whose value is not established.
Compilation retains that entity and records its unknown fields, but consultation fails whenever the incomplete entity is required for the requested topic.
This makes an honest partial seed useful without turning absence into permission to invent infrastructure.

## Compile

Run the compiler after any declared or generated input changes:

```sh
bin/fm-estate-compile.sh
```

The compiler validates YAML, required fields, source ownership, UTC timestamps, and unique identities before publishing deterministically sorted JSON and Markdown.
It publishes through temporary files, so an invalid input leaves the previous compiled catalog available.
Set `FM_ESTATE_CATALOG_DIR` for an exact test or alternate catalog path, and set `FM_ESTATE_NOW` to make age evaluation reproducible.

Hosts become stale after seven days by default because compute topology is the highest-risk surprise surface.
Other kinds become stale after 30 days by default.
`--stale-days` can replace that policy for a one-off compile, and the compiled entity records the threshold used.

A failed collector keeps its last snapshot and changes the source document's top-level status:

```yaml
status:
  state: stale
  marked_at: "2026-08-09T12:00:00Z"
  reason: "collector unavailable"
```

The compiler marks every entity in that slice stale while preserving the last known facts.
Collectors named `fm-estate-collect-*` are a later stage and are not part of this slice.

## Consult

Run consultation with at least one infrastructure topic or estate kind:

```sh
bin/fm-estate-consult.sh ci
bin/fm-estate-consult.sh deploy bible-agents
bin/fm-estate-consult.sh kind:dns
```

The command reads only `compiled/estate.json` and prints an `Estate already exists` block followed by `Unknown surfaces`.
Topic words add required dependencies, so `ci` requires matching CI and host truth, while `kind:ci` checks exactly the CI kind.
Linked `host`, `host_ref`, `system`, and typed `target` references are included in the result.

Exit `0` means every matching required entity is present, current, and complete.
Exit `1` means the infrastructure consultation is invalid because a required surface is missing, stale, incomplete, or unmatched.
Exit `2` means the command could not perform the consultation because its input or invocation is invalid.
The seven-day compute threshold is re-evaluated at consultation time, so an old compiled file cannot remain falsely current merely because it was current when compiled.

## Initial seed

On a fresh home, seed the accepted known estate and registered project delivery modes with:

```sh
bin/fm-estate-seed.sh
bin/fm-estate-compile.sh
```

The seed includes `pve`, `woodpecker-ci` VM 110, `gh-runner-t1` VM 120, `pier-trackway`, Woodpecker at `https://ci.appheat.co`, the known CI DNS and tunnel names, the local Powerpipe service, Woodpecker SQLite and Doppler ownership, and every project parsed from `data/projects.md`.
The registry owns project names and delivery modes, but it does not own every GitHub slug, verify command, CI attachment, or base branch.
The seed therefore records unknown values where the registry has no established fact, and those values must be completed before affected consultations can pass.

The seed helper refuses to run when declared YAML already exists and never writes compiled output.
It does not contact Proxmox, Woodpecker, Cloudflare, GitHub, or any SaaS service.
There is no Port feed because portals are outside the agent truth path and outside this slice.

## Requirements and verification

The commands require Bash and Ruby's standard YAML and JSON libraries.
Run the colocated end-to-end suites through the repository test runner:

```sh
bin/fm-test-run.sh tests/fm-estate-compile.test.sh
bin/fm-test-run.sh tests/fm-estate-consult.test.sh
bin/fm-test-run.sh tests/fm-estate-seed.test.sh
```

These tests are the product-surface dogfood for this non-user-facing agent gate: they invoke the real scripts against home-shaped fixture catalogs and prove current, stale, missing-kind, incomplete, deterministic, and no-overwrite behavior.
