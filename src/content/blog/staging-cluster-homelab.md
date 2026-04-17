---
title: "Why a Staging Cluster in a Homelab Gives False Confidence"
date: "2026-04-17"
summary: "Staging sounds like best practice. In a homelab with one operator and limited hardware, it becomes a maintenance burden that validates almost nothing. Here's what we replaced it with."
adr: "ADR-004"
---

For a few months, the homelab CI/CD pipeline had a staging cluster. A dedicated k3s VM on Proxmox, a `main` → `prod` promotion flow, automated health checks before anything reached production. It looked solid on paper.

It wasn't.

## What staging was supposed to do

The idea was standard: merge to `main`, Flux reconciles staging, a GitHub Actions job checks that the cluster is healthy, then `main` gets promoted to a `prod` branch that the production cluster watches. Any bad manifest or broken Helm values would get caught in staging before it ever reached the real cluster.

This is how staging works in a team environment and it makes sense there. Multiple engineers, parallel PRs, dedicated infra team to maintain the environments — staging earns its keep.

## What staging actually did

**It validated that Traefik was running.**

In practice, only the platform layer was deployed to staging — cert-manager, Flux, Traefik, MetalLB. The actual applications (Nextcloud, Immich, Authentik, n8n) were never deployed there. Maintaining a full duplicate set of SOPS-encrypted secrets, database credentials, and external service configs for a second environment was too much overhead for a single operator.

So a "passing" staging health check meant: the ingress controller is up and the cluster hasn't crashed. That's it.

Every real bug that made it to production was caught by something else — Flux failing to reconcile a HelmRelease, `kubeconform` rejecting a malformed manifest, or the post-merge production health check. Never by staging.

## The maintenance cost was real

The staging cluster diverged from production over time. When Proxmox snapshots left the k3s node in an inconsistent state (which happened), every PR was blocked waiting on a broken staging environment that had nothing to do with the change being tested. I'd spend 20 minutes debugging staging before I could merge a 3-line change.

Then the NUC running Proxmox was repurposed as a bare-metal Docker host. The staging VM ceased to exist. This forced the decision — but in hindsight it should have been made earlier.

## What replaced it

Two things: **broader static validation at PR time**, and **honest post-merge production health checks**.

Every PR now runs `kubeconform` against all manifests, `flux-local diff` to preview what would actually change in the cluster, and `helm template` to catch values schema mismatches before merge. This runs in under 2 minutes and covers every file in the repo — not just the subset that was deployed to staging.

After merge, a production health check runs against the real cluster. If something is broken, the cluster is already affected — that's the honest trade-off. But in practice, schema validation catches the class of errors that staging was supposed to catch, and does it faster.

## The actual lesson

Staging is most valuable when your environments are meaningfully different and you have the capacity to keep them in sync. In a homelab, you have one operator, constrained hardware, and environments that will inevitably diverge. A staging cluster that runs 20% of your production workload doesn't validate the other 80% — it just adds 80% of the maintenance burden for 20% of the coverage.

The bet we made — schema validation and diff previews over a live staging environment — has held up. No production outage has been caused by a change that passed PR validation since the migration.

That's not to say staging is always wrong. It's to say: be honest about what your staging environment actually validates before deciding its cost is worth paying.

---

*This post is based on [ADR-004](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-004-staging-to-pr-validation.md) and [ADR-009](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-009-pr-validation-pipeline.md) from the homelab infrastructure repo.*
