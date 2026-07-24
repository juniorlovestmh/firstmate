# Fleet promotion-ladder standard

Every fleet project with a deployable application needs a real promotion ladder from code to production, never work-branch-merge-equals-prod.
This is the durable contract; a project's own `AGENTS.md` or deploy docs hold its concrete commands, gated by this doc rather than restating it.

## Environments

**dev / preview** - an ephemeral per-PR preview where the platform provides one cheaply, local dev otherwise.
It never shares state, secrets, or data with production.

**staging** - one persistent environment, deployed automatically on merge to the integration branch.
It owns its own secrets/config and its own data stores; it never reads or writes production data.
It must stay launchable at a stable URL or equivalent entry point that the captain can open for review.

**production** - the deployment represented by protected `main`, reached only by an explicit promotion from staging.
The promotion may be a reviewed `staging`-to-`main` PR, a release tag, or a manually-approved deploy job, according to the platform.
It is never reached as an automatic side effect of merging a work branch.
The project's own docs must name the exact promotion command or flow and the exact rollback path; a ladder without a documented rollback is incomplete.

## Default model: fleet branch ladder

The fleet default is short-lived `dev/*` work branches into the persistent `staging` integration branch, then explicit promotion from `staging` to protected `main` as production.
Preview deploys per work PR, merging to `staging` auto-deploys staging, and a reviewed `staging`-to-`main` PR or equivalent approved action promotes production.
Prefer promoting the exact artifact that passed the staging smoke gate over rebuilding for production; a rebuild can drift from what was actually verified.
`beta` branches are retired: no new fleet work targets `beta`, and existing `beta` lines must migrate into this ladder. Firstmate's own current beta delivery base is a temporary exception; migrating Firstmate itself to `dev/*` -> `staging` -> protected `main` is separate planned future work.

Boostin (`juniorlovestmh/boostin`) is the fleet's worked example: `dev/*` work branches merge into `staging`, which explicitly promotes into production `main` through a reviewed PR (see PRs #3 and #5).
If the platform does not deploy production from protected `main`, the project must retain a separate protected manual or tag deployment after that branch promotion.
Its CI (`.github/workflows/verify.yml`) runs on PRs and on push to `staging`/`main`/`dev/**`, so every branch in the chain is validated.
A 2026-07-22 audit found that its documented ladder was social, not mechanical: `main` and `staging` had no branch protection or rulesets, so a direct push could bypass the PR-and-green-check path entirely.
The ladder is not real until its branch and promotion gates enforce required PRs, required green checks, and no direct pushes.

## Non-deployable exception

Pure libraries and templates with no deployable application may keep protected `main` with short-lived work branches.
The exception ends as soon as the project gains a deployable app or persistent cloud environment.

## Secrets separation

Each environment's secrets and config stay separate: dev/preview, staging, and production never share a secret set or a data store.
Use Doppler where the project has adopted it; use the platform's native secret store otherwise (GitHub Environments secrets, `wrangler secret`, OpenTofu's provider-native secret backend, and so on).
No secret value ever lands in the repo, in a committed `tfvars`/`wrangler.toml`, or in a workflow file.

## Smoke gate

A smoke or health check runs against staging before production promotion is considered ready. Promotion must refuse a failing or skipped check; this prerequisite is mandatory and not bypassable except for an explicit captain-approved emergency, with the approval and bypass recorded.
The check must exercise the real staging deployment (a health endpoint, a scripted smoke path, or the platform's own health check).

## Rollback documentation

Every project's own docs must state the exact rollback path for its production environment: the command or flow that reverts to the last known-good release (redeploy a prior tag, roll back an OpenTofu apply to the prior state, revert-and-redeploy, or the platform's native rollback).
Keep that detail in the project, not duplicated here; this doc owns the contract that a rollback path must exist and be documented, not the project-specific mechanics.

## Per-platform appendix

**Cloudflare Workers** - use Wrangler environments (`[env.staging]`, `[env.production]` in `wrangler.toml`) for the staging and production tiers.
Deploy staging with `wrangler deploy --env staging` on merge to `staging`; gate production behind a separate `wrangler deploy --env production` step after the reviewed promotion to `main`.
Set secrets per environment with `wrangler secret put --env <env>` (or Doppler injection into the deploy job), never inline in `wrangler.toml`.

**Cloudflare Pages** - use Pages preview deployments for ephemeral previews and a dedicated Pages project for persistent staging, with staging-specific secrets, bindings, and data stores; a preview branch alias is not an isolated staging environment, and Pages does not use Workers' named `--env staging` deployment flow.
On merge to `staging`, deploy the built output to the dedicated staging project with `wrangler pages deploy <output-directory> --project-name <staging-project>`, then run the staging smoke check against that stable URL. Publish the built output as a durable CI artifact keyed to the staging commit and record its digest.
After it passes, explicit promotion to `main` must retrieve that exact artifact, verify its recorded digest and staging-commit provenance, and deploy it with `wrangler pages deploy <output-directory> --project-name <production-project>`; do not rebuild between staging and production.
Deploy an ephemeral preview with `wrangler pages deploy <output-directory> --branch <preview-branch>` when the platform's preview flow is needed.
Set Pages secrets and environment-specific configuration through the Pages project settings or the platform's supported secret store, never inline in committed configuration.

**OpenTofu-managed infra** - keep a separate state per environment (a workspace or state file per env), never a shared state across dev/staging/production.
Auto-apply staging's plan on merge to `staging`; promote the reviewed configuration or commit, then generate a production-specific plan against production state and apply it only after the explicit promotion to `main`.
Never apply a staging plan artifact to production or apply a fresh unreviewed plan.
Inject variables and secrets via Doppler or the cloud provider's native secret store, never as committed `tfvars`.

**GitHub Actions deploy jobs** - use GitHub Environments (`staging`, `production`) with environment-scoped secrets.
Give the `production` environment required reviewers where the reviewed `staging`-to-`main` PR is not itself the platform's approval gate.
Run the `staging` deploy job automatically on push to `staging`, and run production only after explicit promotion to `main`.

**Static publishing** (docs sites, marketing pages, and similar) - use the host's per-PR preview deploy where available (Cloudflare Pages, Netlify, and similar), else build and serve locally for the preview tier.
Map the `staging` branch to a stable staging subdomain the captain can open; publish production only after explicit promotion to `main`.
