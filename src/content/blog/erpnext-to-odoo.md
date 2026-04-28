---
title: "ERPNext Is Gone. Here's Why Odoo Won."
date: "2026-04-15"
summary: "I ran ERPNext for a few months on the cluster. It was unstable, opaque, and the Helm chart was a maintenance nightmare. Odoo isn't simpler, but it's more predictable — and the community charts are considerably better maintained."
tags: ["homelab", "selfhosted", "kubernetes", "helm", "erp"]
---

ERPNext had a MariaDB subchhart with a broken values path. The Redis configuration had been deprecated and then removed upstream without a migration note in the chart README. Getting it to deploy required patching values that the chart documentation didn't mention.

That's the kind of problem that tells you something about a project's operational maturity.

## What I was trying to do

Running an ERP in a homelab isn't a common use case. The motivation wasn't accounting or inventory management — it was operational discipline. An ERP forces you to think about data models, workflow, and integration in ways that media servers and monitoring stacks don't.

ERPNext is a legitimate production ERP. Used by real businesses. The self-hosted path is genuinely possible. But the Kubernetes story is not good.

## The ERPNext problems

**The Helm chart is a monolith.** ERPNext's architecture requires MariaDB, Redis (for two different roles), a background worker, and a scheduler — all coordinating through a shared filesystem. The community Helm chart bundles this into a single release with subchart dependencies that have their own versioning.

When MariaDB's subchart updated its values schema, the top-level chart values stopped working without a migration. Renovate opened the PR, CI passed (kustomize build and kubeconform don't catch Helm values schema drift), and the chart deployed with MariaDB using defaults instead of my configured values.

The database came up clean. The ERPNext application layer failed to connect. Flux showed the HelmRelease as Ready. The problem was invisible to every automated check.

**The application itself is opaque.** When ERPNext fails, the error messages are in Python stack traces buried in a worker process. There's no structured logging. Tracing a connection failure from the application layer back to the database configuration required reading source code.

This is a legitimate product for teams with ERPNext expertise. For a solo operator running it as a learning exercise, the debugging surface area is too large.

## Why Odoo

Odoo has the same architectural complexity — PostgreSQL, a web worker, and background workers. But the Helm chart situation is better maintained, the error surfaces are cleaner, and the community around Kubernetes deployments is larger.

The honest reason: I found a well-maintained `odoo` Helm chart with proper schema documentation and a straightforward values structure. That was the deciding factor.

The values migration when upgrading Odoo charts is documented. The subchart dependencies (PostgreSQL via Bitnami) are stable. Renovate can upgrade it without schema drift risk.

## What the migration looked like

```bash
# Remove ERPNext HelmRelease and namespace
git rm -r clusters/prod/apps/erpnext/
git commit -m "chore: remove ERPNext"
flux reconcile kustomization apps --with-source

# Verify ERPNext namespace cleaned up
kubectl get ns
```

No data migration — I hadn't committed anything meaningful to ERPNext that I wanted to keep. The cluster cleaned up the namespace after Flux reconciled the removal.

The Odoo deployment is in a separate PR, bootstrapped from the Helm chart documentation. It came up cleanly on the first deploy.

## What I learned

Complex applications expose the limits of generic Kubernetes tooling. `kustomize build` and `kubeconform` validate manifest structure — they don't validate that your application's configuration is internally consistent.

The Helm chart quality gap between well-maintained charts (Bitnami, official Prometheus stack) and community charts is large. Before committing to a self-hosted application on Kubernetes, the right question isn't "does a Helm chart exist" but "what does the chart's upgrade story look like over the past 12 months."

ERPNext's chart had 47 open issues when I removed it. Odoo's had 12. Not a perfect signal, but a better one than I was using.
