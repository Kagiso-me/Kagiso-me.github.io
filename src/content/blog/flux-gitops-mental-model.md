---
title: "The Hardest Part of GitOps Is Unlearning kubectl"
date: "2026-04-10"
summary: "The first week with Flux, the cluster kept 'undoing' my changes. It wasn't broken. It was working exactly as designed. That gap between what I expected and what was actually happening took about three weeks to fully close."
adr: "ADR-002"
---

The first week with Flux, the cluster kept undoing things.

Not really — Flux was reconciling the cluster state to match the repository. That's exactly what it's supposed to do. But coming from Docker Compose, where `docker compose up -d` is the entire deployment model and the compose file is a reference document you can freely diverge from, the GitOps mental model doesn't arrive complete. It has to be earned.

## How Docker taught me to think about infrastructure

With Docker Compose, the relationship between the file and the running state is loose. The compose file describes what you want to run, but once things are running, you can modify them: change an environment variable, restart a container with a flag, update a bind mount path — the file and the runtime diverge and that's fine. Nobody reverts you.

This is a reasonable model when you're the only operator, the changes are small, and you can hold the full state of the system in your head. I ran Docker Compose for a year before building the k3s cluster. The muscle memory ran deep.

Flux treats the repository as the only truth. What's in Git is what the cluster should be running. Not what it was running when you last committed. Not what you modified with `kubectl edit` to test something five minutes ago. Git, current state, is the desired state — and Flux reconciles toward it continuously.

## The kubectl reflex

The first time I patched a ConfigMap directly with `kubectl edit` to test a config value, Flux reverted it within a minute. I thought something was wrong. I edited it again. Same result. It took longer than I'd like to admit to realize the cluster wasn't misbehaving — it was doing exactly what I'd configured it to do.

The `kubectl apply` reflex is strong, especially when something's broken and the fix is obvious. You have the YAML in front of you, the cluster is waiting, and the direct apply takes 30 seconds. The Git commit, push, and Flux reconcile cycle takes two to three minutes. When something's on fire, two minutes is a long time.

What I wasn't accounting for: those two minutes are producing something. The commit message is the incident log. The diff is the change record. The Flux reconciliation event is the audit trail. A direct `kubectl apply` is invisible to all of that — no history, no way to diff the live cluster against the repository, no rollback path except manually reversing what you did.

## The rule that eventually stuck

There are still cases where I'll make a temporary change directly — debugging a failing pod, testing a new config value, investigating an error. The direct apply is for exploration. The commit is the thing that actually exists.

The rule I settled on: anything that turns out to be correct goes into a commit before anything else happens. If I edit a ConfigMap directly and it fixes the problem, the next thing I do is write that change into the repository. Not later. Not after the thing it was fixing is stable. Right then, before I move on to something else. Otherwise it disappears the moment Flux reconciles again — which is every minute.

This sounds obvious written out. In practice it's a discipline that took weeks to internalize, because the Docker model trained me to treat the running state as the authoritative one.

## The moment it clicked

The mental shift happened during an auto-upgrade. Flux had applied a new chart version via the image update policy, and something broke. Before GitOps, that recovery path would have been: figure out what changed, find what version it was on before, apply the old version manually, hope nothing else changed in the window.

With Flux, the path was: `git revert <commit>`, push. Flux reconciled back to the previous state in 90 seconds.

The Git history wasn't just a log. It was the rollback mechanism. The two minutes spent writing a commit message instead of applying directly weren't overhead — they were the entire reason recovery was fast.

After that it stopped feeling like friction. The gravitational pull shifted toward the repository. Not fully — there are still moments when the kubectl reflex fires and I act on it. But now I notice it when it happens, and the follow-up commit comes quickly.

That took about three weeks to become automatic. For what it's worth, I think that's about the right amount of time. GitOps is a different operating model, not just a different tool. The gap between reading about it and actually running a cluster that enforces it on you is where the model actually gets learned.

---

*Based on [ADR-002](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-002-flux-over-argocd.md) — FluxCD over ArgoCD, and [ADR-009](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-009-pr-validation-pipeline.md) — the PR validation pipeline that reinforces the model.*
