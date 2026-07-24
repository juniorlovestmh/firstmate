# Fleet promotion-ladder standard

Every fleet project with deployable cloud assets needs a real promotion ladder from code to production, never trunk-merge-equals-prod.
This is the durable contract; a project's own `AGENTS.md` or deploy docs hold its concrete commands, gated by this doc rather than restating it.

## Environments

**dev / preview** - an ephemeral per-PR preview where the platform provides one cheaply, local dev otherwise.
It never shares state, secrets, or data with production.

**staging** - one persistent environment, deployed automatically on merge to the integration branch.
It owns its own secrets/config and its own data stores; it never reads or writes production data.

**production** - promoted explicitly, by a release tag or a manually-approved deploy job.
It is never reached as an automatic side effect of a trunk merge.
The project's own docs must name the exact promotion command or flow and the exact rollback path; a ladder without a documented rollback is incomplete.

## Default model: single trunk, environment promotion

The default is one protected trunk with environment promotion, not a chain of long-lived branches.
Preview deploys per PR, merge to trunk auto-deploys staging, and a separate explicit action (tag or approved job) promotes the already-built staging artifact to production.
Prefer promoting the exact artifact that passed the staging smoke gate over rebuilding for production; a rebuild can drift from what was actually verified.

## When a branch-based ladder is acceptable

A branch-based ladder - separate persistent `dev`/`staging`/`main` branches instead of one trunk - is the exception, used only where the platform demands branch-name mapping (for example, a PaaS that ties an environment to a specific branch rather than a tag or manual dispatch).
Do not adopt it for convenience or habit; it costs more merge overhead than trunk promotion for no benefit when the platform does not require it.

Boostin (`juniorlovestmh/boostin`) is the fleet's worked branch-based example: `dev/*` work branches merge into the `staging` integration branch, which promotes into the `main` production branch via a reviewed PR (see PRs #3 and #5).
Its CI (`.github/workflows/verify.yml`) runs on PRs and on push to `staging`/`main`/`dev/**`, so every branch in the chain is validated.
A 2026-07-22 audit of that project found the documented ladder was social, not mechanical: `main` and `staging` had no branch protection or rulesets, so a direct push could bypass the PR-and-green-check path entirely.
Whichever shape a project uses, the ladder is not real until the branches or promotion gates are actually enforced (required PR, required green check, no direct push), not merely described.

## Secrets separation

Each environment's secrets and config stay separate: dev/preview, staging, and production never share a secret set or a data store.
Use Doppler where the project has adopted it; use the platform's native secret store otherwise (GitHub Environments secrets, `wrangler secret`, OpenTofu's provider-native secret backend, and so on).
No secret value ever lands in the repo, in a committed `tfvars`/`wrangler.toml`, or in a workflow file.

## Smoke gate

A smoke or health check runs against staging before production promotion is considered ready.
The check must exercise the real staging deployment (a health endpoint, a scripted smoke path, or the platform's own health check), and the promotion step should refuse to proceed on a failing or skipped check.

## Rollback documentation

Every project's own docs must state the exact rollback path for its production environment: the command or flow that reverts to the last known-good release (redeploy a prior tag, roll back an OpenTofu apply to the prior state, revert-and-redeploy, or the platform's native rollback).
Keep that detail in the project, not duplicated here; this doc owns the contract that a rollback path must exist and be documented, not the project-specific mechanics.

## Per-platform appendix

**Cloudflare Workers/Pages** - use Wrangler environments (`[env.staging]`, `[env.production]` in `wrangler.toml`) or Pages branch/preview deployments for the preview tier.
Deploy staging with `wrangler deploy --env staging` on trunk merge; gate production behind a separate `wrangler deploy --env production` step tied to a tag or an approved job.
Set secrets per environment with `wrangler secret put --env <env>` (or Doppler injection into the deploy job), never inline in `wrangler.toml`.

**OpenTofu-managed infra** - keep a separate state per environment (a workspace or state file per env), never a shared state across dev/staging/production.
Auto-apply staging's plan on trunk merge; promote production by applying the same reviewed plan artifact under a manually-approved job, never a fresh unreviewed plan.
Inject variables and secrets via Doppler or the cloud provider's native secret store, never as committed `tfvars`.

**GitHub Actions deploy jobs** - use GitHub Environments (`staging`, `production`) with environment-scoped secrets.
Give the `production` environment required reviewers so its job pauses for manual approval; run the `staging` deploy job automatically on push to trunk, and the `production` job only on a tag push or an approved `workflow_dispatch`.

**Static publishing** (docs sites, marketing pages, and similar) - use the host's per-PR preview deploy where available (Cloudflare Pages, Netlify, and similar), else build and serve locally for the preview tier.
Auto-publish trunk merges to a staging subdomain; promote to production by an explicit publish step that ships the already-built, already-smoke-tested staging artifact rather than a fresh rebuild.
