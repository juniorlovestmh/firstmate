---
name: secrets-management
description: >-
  Agent-only policy for Firstmate-managed secrets.
  Use before project intake or initialization and before work that handles credentials or adds secret access to CI or deployment.
  Owns Doppler defaults, secretless identity preference, naming, least privilege, owned-runner injection, local use, redaction, rotation, offboarding, break-glass, exceptions, and migration.
user-invocable: false
metadata:
  internal: true
---

# secrets-management

Use this procedure before project intake or initialization and before work that handles credentials or adds secret access to CI or deployment.
This skill is the single owner of Firstmate's secrets-management policy.
The tracked schemas and rollout data are validated by `bin/fm-secrets-check.sh`.

## Authority and precedence

Prefer no stored secret when a workload can prove its identity directly to the provider.
Google Cloud Workload Identity Federation, GitHub's job-scoped token, and trusted publishing are preferred over creating a vault entry that must later be protected and rotated.

When a real secret is required, Doppler is the default source of truth for project and CI secrets.
Do not add a second general-purpose vault or use a platform store as an undocumented alternative source of truth.
A platform-mandated secret store may receive the value needed by that platform at deploy time, but the project manifest must document why that copy exists and which system is authoritative.

1Password is only the sealed break-glass store for platform-root and recovery credentials.
Agents receive no ambient 1Password access and never use 1Password as the normal project or CI path.
Changing that boundary requires the captain's explicit decision.

Anything that rotates, transfers, moves, or exposes a real credential requires escalation before the value is handled.
Anything that commits the captain to a paid Doppler tier also requires escalation.

## Project and environment names

Use the repository or stable product slug as the Doppler project name.
Record any legacy name and its migration reason in the project manifest instead of creating an undocumented alias.

Use `dev`, `stg`, and `prd` as the canonical configs.
Local development uses `dev`, persistent pre-production uses `stg`, and production uses `prd`.
A pull-request preview may inherit `stg` only when it is isolated from production data and the manifest documents that choice.
An ephemeral config uses `pr-<number>`, has no production values, and is removed when the pull request closes.
Do not point a production GitHub Environment at `dev` or `stg`.

The committed project manifest is `docs/secrets-policy.json`.
It contains names, scopes, identity modes, exceptions, and review metadata only.
It never contains a secret value, token fingerprint, encoded credential, or reversible derivative.
Validate it with `bin/fm-secrets-check.sh manifest <path>`.

## Least-privilege access

Grant humans individual Doppler access only to the projects and environments required by their role.
Normal local development access is read-only for `dev`.
Staging or production access is granted only for a named task and is removed when that task or role ends.

Agents use the human-approved local Doppler session only for the named project, config, and command in scope.
Agents do not create tokens, broaden project membership, download an environment, enumerate values, or fall back to 1Password.
If the required project or config is unavailable, stop and escalate rather than borrowing access from another environment.

CI uses one identity per project and environment.
Config-scoped read-only service tokens are the shipped CI default.
Each token is scoped to exactly one Doppler project config.
Store the service token as the matching GitHub Environment secret named `DOPPLER_TOKEN`.
Never use one service token across projects or across `dev`, `stg`, and `prd`.
Never grant a CI token write access.

## Owned-runner injection

The runner host remains credential-free.
`/usr/local/sbin/gh-runner-preflight` must find no Doppler token, Doppler project selection, 1Password token, GitHub token, cloud key, credential file, or secret-bearing shell profile in the runner service environment or home before a job is admitted.
A standing token on the runner is prohibited even if file permissions are restrictive.

GitHub sends the credential only after the job is admitted.
The workflow attaches the matching GitHub Environment to the secret-consuming job.
The `DOPPLER_TOKEN` secret is passed only to the pinned Doppler Secrets Fetch action step, never at workflow, job, runner-service, or shell-profile scope.
The action fetches the exact config, registers fetched values for GitHub log masking, and exposes them only to later steps in that job.
Every secret in Doppler must use masked visibility.
The job must not persist the action output or a Doppler CLI configuration under the runner home.

The secret lifetime on the machine is the job lifetime.
The runner process discards the job environment and GitHub removes runner-managed job temporary files when the job ends.
The next job passes the same credential-free preflight before receiving work.
If a workflow creates an additional secret-bearing temporary file, it must use a `0700` directory under `RUNNER_TEMP`, install an `if: always()` cleanup step, and prove absence without printing contents.

Copy the shipped job shape from `docs/examples/doppler-service-token-job.yml`.
The OIDC file at `docs/examples/doppler-oidc-job.yml` is an optional reference only after the captain approves a paid-plan change.
Both templates pin Doppler's v1.3.0 Secrets Fetch action to commit `cd2efbf9a404504316435873eff298b82f7e0562`.
Both also pin actions/checkout v6.0.2 to commit `de0fac2e4500dabe0009e67214ff5f5447ce83dd` before secret injection.

Install actions and tools before injecting secrets whenever possible.
Check out only trusted code before injection.
Never expose Doppler or provider credentials to pull requests from forks, Dependabot, or another untrusted event.

The sanctioned `waku-agent` hosted-runner exception remains documented because it is a public fork whose untrusted pull requests must not run on captain-owned hardware.
That runner exception does not authorize secrets on untrusted events.

## Captain decision record for optional Doppler OIDC

The 2026-07-27 owned-runner pilot proves that GitHub job OIDC works from the fleet runner and that the runner can keep its host environment credential-free.
Doppler Service Account Identities can exchange that GitHub OIDC assertion for a short-lived Doppler token without storing `DOPPLER_TOKEN`.
Doppler currently limits that feature to Team and Enterprise plans.
As checked on 2026-07-27, Doppler lists Team at $21 per user per month and Enterprise at custom pricing.

The recommendation for the captain is to consider Doppler OIDC for secret-bearing GitHub Actions environments because it removes the stored Doppler CI token and its rotation burden.
Whether that benefit justifies the paid plan is the captain's decision.
This recommendation does not authorize a purchase, trial, plan change, or OIDC rollout.

If the captain approves a paid plan and a separate implementation, each identity should be read-only, scoped to one Doppler project and environment, and bound with exact audience and subject claims plus immutable repository identity, GitHub Environment, workflow identity, and `runner_environment=self-hosted` where supported.
Avoid wildcard claim rules.
Store the Doppler identity ID as a non-secret GitHub Environment variable.
Grant `id-token: write` only to the job that fetches secrets.

Do not upgrade the plan as part of routine implementation.
The shipped standard does not require OIDC, a service account, or a paid plan.
Project/config-scoped read-only service tokens with per-job injection remain the official CI implementation unless the captain separately approves the plan and migration.
That service-token default never permits a token to persist on the runner.

Official references:

- [Doppler pricing](https://www.doppler.com/pricing)
- [Doppler Service Tokens](https://docs.doppler.com/docs/service-tokens)
- [Doppler Service Account Identities](https://docs.doppler.com/docs/service-account-identities)
- [Doppler GitHub OIDC examples](https://docs.doppler.com/docs/github-oidc-examples)
- [GitHub OIDC claims](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub self-hosted runner network requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)

## Local use

Humans authenticate the Doppler CLI with their own identity.
Scope project selection to the repository directory and select `dev` by default.
Do not paste a token into a command, prompt, script, dotfile, shell profile, or committed environment file.

Run the consuming process through `doppler run --project <project> --config <config> -- <command>`.
Use environment variables or standard input when a downstream tool needs a value.
Do not put a secret in a command argument because process listings, audit events, and shell history may retain it.
Production local access is exceptional and requires the named task to authorize it.

## Redaction and evidence

Never print a secret value to prove that it exists.
Presence checks report only the secret name, boolean presence, source project/config, and command exit status.
Do not run `printenv`, `env`, `set -x`, an unredacted Compose render, `doppler secrets download`, or `doppler secrets get --plain` in captured output.
Do not paste a value into a prompt, issue, report, pull request, commit, test fixture, or status message.

Logs and reports may contain secret names, project names, config names, rotation dates, and opaque decision identifiers.
They must not contain values, partial values, fingerprints derived from values, or screenshots that reveal them.
When a command fails, sanitize its output before retaining evidence.

Run `bin/fm-secrets-check.sh leak-scan <paths...>` against every tracked artifact produced by secret-management work.
The scanner reports only the file, line, and matched rule.
It never echoes the matching text.
A clean scan is supporting evidence, not proof that an untracked or external system contains no secret.

## Rotation and incident response

Set Doppler service-token expiry to no more than 90 days when the current plan supports the required expiry.
Review every project manifest at least every 90 days.
Rotate sooner when a provider requires it, access changes, the token scope changes, or exposure is suspected.

Perform a normal rotation in this order:

1. Create a replacement with the same or narrower scope through an approved interactive path.
2. Update only the matching GitHub Environment secret.
3. Run a presence-only canary on the intended environment and owned runner.
4. Revoke the old token after the canary passes.
5. Record the identity name, scope, timestamps, evidence URL, and operator without recording either value.

On suspected exposure, revoke first, stop affected jobs, rotate downstream credentials the token could read, and preserve only sanitized evidence.
Do not wait for a normal canary before revoking a credential believed exposed.

OIDC removes Doppler service-token rotation but not rotation of provider credentials stored in Doppler.
Keep provider rotation independent and follow the provider's shorter limit when one exists.

## Offboarding

Remove the person's Doppler membership and project roles.
Revoke personal CLI sessions and any service token created for that person's task.
Remove GitHub Environment access and any local project authorization.
Rotate each shared provider credential the person could retrieve.
Verify with name-only inventory and audit events that access is gone.
Do not add agents as Doppler users, so an agent shutdown normally requires no vault offboarding.

## Break-glass

Break-glass covers Doppler workplace recovery, cloud or forge root recovery, and another platform-root credential whose normal identity path cannot recover itself.
The sealed 1Password item remains captain-controlled and unavailable to agents.
Use requires a named incident, explicit captain authority, the minimum credential, and a bounded recovery window.
After use, rotate the recovered root credential, re-seal the replacement, revoke temporary access, and record value-free evidence.
Do not copy a platform-root credential into a normal Doppler project.

## Exceptions

Every exception lives in `docs/secrets-policy.json` with a narrow scope, owner, review cadence, and non-empty reason.
An exception without a reason is invalid.

Allowed exception kinds are:

- `secretless` for a project or job that has no secret and therefore needs no Doppler project.
- `provider-oidc` for direct short-lived identity such as GCP Workload Identity Federation.
- `platform-mandated` for a provider store or job token the platform requires.
- `break-glass` for the sealed root recovery boundary.
- `hosted-runner` for the named public-fork safety exception.
- `shared-nonproduction-config` for an isolated preview that intentionally shares `stg`, never production data.
- `temporary-migration` for a time-bounded incompatibility with an explicit removal step.

Every `temporary-migration` exception records a `reviewBy` date no more than 90 days away and a non-empty `removalCondition`.
Cost, convenience, an existing unscoped token, or a token already present on a machine is not a valid exception.

## Project intake and migration

During project intake, run `bin/fm-secrets-check.sh inventory <project-dir>`.
The inventory reads tracked filenames and reference classes only.
It never reads untracked environment files or prints matched lines.

If `docs/secrets-policy.json` is absent, the first project ship copies `docs/examples/project-secrets-policy.json` from Firstmate, replaces the example fields, and validates it.
Firstmate does not hand-write that file in a project clone.
A secretless project still records the reason it needs no Doppler project.

Migrate without exposing or silently moving a real value:

1. Inventory names, consumers, environments, owners, and current stores without reading values into logs.
2. Classify every credential as unnecessary identity, Doppler-managed, platform-mandated, bootstrap root, or break-glass.
3. Create the canonical Doppler project and `dev`, `stg`, and `prd` configs without values.
4. Ask the captain or approved operator to transfer real values through a secure interactive path.
5. Configure the per-environment CI identity and per-job injection.
6. Run presence-only and real consumer canaries without value output.
7. Remove the old read path only after the new path passes.
8. Revoke or rotate the old credential and update the manifest.

Never use a general export, bulk environment dump, prompt, report, or shell-history command as a migration transport.
Do not delete the old path until rollback evidence exists.
