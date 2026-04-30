---
title: "The Night Flux Was Right and I Was Wrong"
date: "2026-04-28"
summary: "I spent two hours debugging why my config changes weren't sticking. Flux was silently rolling them back on every reconcile. This is what GitOps actually feels like when you forget how it works."
tags: ["incident", "flux", "gitops", "kubernetes", "homelab"]
---

At 22:14 on a Tuesday, I pushed a Helm values change to the cluster directly with `helm upgrade`. By 22:44 it had silently reverted. By 23:20 I had done it three times and was questioning whether Kubernetes itself was broken.

It wasn't. Flux was doing exactly what I built it to do.

---

## What happened

I was tuning Authentik's session cookie lifetime — a small change, one value in a `values.yaml`. I was tired and I didn't want to wait for a PR and a pipeline. So I ran the upgrade directly against the cluster.

It worked. The pod restarted. The value was there. I went to get water.

When I came back, the session timeout had reverted to the old value.

I upgraded again. Same result. I checked my terminal history to make sure I'd run the right command. I had. I checked the running pod's environment — the new value wasn't there. I exec'd into the pod and looked at the mounted config. Old value.

My first hypothesis was that the Helm release state was corrupted. I deleted the release secret and reapplied. Same result — reverted within 30 minutes.

My second hypothesis was that there was a second copy of the values somewhere causing a conflict. I grepped the entire repo. There wasn't.

My third hypothesis — reached at around 23:15, after I opened the Flux dashboard to look at something unrelated — was correct.

The HelmRelease CRD was reconciling every 30 minutes. It was reading the values from Git. It was applying them. My manual `helm upgrade` was overwriting Git state with local state, and Flux was then overwriting local state with Git state. Every 30 minutes, on schedule, faithfully, Flux was correcting what it perceived as drift.

Flux was not broken. Flux was right. I had forgotten what I built.

---

## The actual cost

Two hours. One reboot of the Authentik pod that was unnecessary. A 15-minute window where session management was misconfigured in a direction I didn't intend because I applied the wrong values in my second attempt.

I also left a `helm upgrade --dry-run` sitting in my terminal history for three days, which meant I spent a few confused minutes later in the week wondering why there was a dry-run command I didn't remember running.

---

## What I changed

Nothing architectural. The fix was: edit the file in Git, open a PR, merge it, wait for Flux.

That's the process. I built it. It works. I undermined it because I was impatient.

I did add one thing: a comment in my personal notes that now reads **"helm upgrade directly = wasted time, do it in Git"**. I've read it once since.

---

## What this actually taught me

GitOps has a hidden cost that nobody talks about in the launch posts: it requires you to fully trust the system you built, even when you're in a hurry and the system feels slower than your hands.

The moment you bypass the pipeline — even once, even for something small — you've created two sources of truth. The system doesn't know you did it. It will correct you. If you don't know why it's correcting you, you'll spend two hours debugging a thing that isn't broken.

The Flux mental model post I wrote earlier covers how reconciliation works. I understood it when I wrote it. I forgot it at 22:14 on a Tuesday when I was tired and impatient.

That's the honest version of what happened.

---

## Postmortem (actual)

**What failed:** Human process. I bypassed Git to make a config change directly.

**Why:** Impatience. I didn't want to wait for the PR pipeline.

**How it was caught:** By accident, while looking at the Flux dashboard for something else.

**Time to resolution:** ~2 hours from first noticing the revert.

**Impact:** Zero — Authentik continued working on the old session config throughout. The change I was making was a preference, not a fix.

**Follow-up actions taken:** None to the system. One note in my personal ops doc.

**What I'd do differently:** Open the PR. The pipeline takes 4 minutes. It's worth 4 minutes.
