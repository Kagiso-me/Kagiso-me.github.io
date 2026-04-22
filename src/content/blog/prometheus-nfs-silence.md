---
title: "Prometheus Was Running. The Data Wasn't."
date: "2026-03-28"
summary: "I moved the monitoring stack to k3s, put the Prometheus TSDB on NFS like every other PVC, and spent weeks looking at graphs with unexplained gaps. The flag I'd set to 'fix' it was the thing that buried the real problem."
adr: "ADR-006"
---

There's a specific kind of bad where everything looks fine.

Grafana dashboards were up. Prometheus targets were green. 55 alert rules configured across four files. The monitoring stack felt solid — maybe even a bit excessive for a homelab. Then there were the gaps.

## The graphs that didn't make sense

Small ones at first. A 5-minute window where node CPU metrics would drop to zero and then resume like nothing happened. The kind of thing that's easy to dismiss as a scrape timeout, a network blip, the cluster being briefly busy. I dismissed it for weeks.

When I finally looked at the Prometheus logs — actually looked, not just confirmed the process was running — the error was `stale NFS file handle`.

The TSDB, the time-series database where every scraped metric gets written, was stored on NFS. Every PVC in the cluster was backed by NFS (the TrueNAS box Ned), so it felt natural to put the Prometheus PVC there too. When I moved the monitoring stack from the Docker host to k3s, I didn't think twice about the storage class.

What NFS gives you is a share across machines. What it doesn't give you is the kind of write consistency that a database writing thousands of data points per second actually needs. Any hiccup on Ned's NFS export — a brief network interruption, a pool scrub running, anything — and Prometheus couldn't write to its data directory. The scrapes were still happening. The targets were still marked healthy. The data for that window was just gone.

## The flag that buried the problem

Here's the embarrassing part: I'd already known, at some level, that NFS and Prometheus didn't get along.

There was a `--storage.tsdb.no-lockfile` flag in the Prometheus configuration. This flag exists specifically for NFS environments — it tells Prometheus not to use a lockfile, because NFS handles lockfiles badly. It's in the documentation. Setting it had fixed some earlier startup crash and I'd moved on.

What it doesn't fix is stale file handles. It just removes one failure mode while leaving the real one intact. The flag was a workaround dressed as a solution, and because the startup crash went away, I stopped thinking about it.

The gaps in the graphs were the bill coming due on that decision.

## The actual fix

Move the TSDB to `local-path`. The local SSD on tywin, the control-plane node. Not elegant — if tywin dies, that historical data is gone — but for a homelab, losing metric history is a much less bad outcome than silently losing metric data while everything appears healthy.

Grafana and Alertmanager stayed on NFS. Their write patterns are completely different: Grafana writes dashboard state occasionally, Alertmanager writes alert history. Neither is doing the constant high-frequency writes across thousands of time series that Prometheus does. NFS handles both of them fine.

After the move: no more gaps. No more stale file handle errors. The `--storage.tsdb.no-lockfile` flag came out.

## What this actually cost

The real cost wasn't the debugging time. It was the weeks of metric history that looked complete but wasn't. The 55 alert rules I'd been confident in were operating on data that had silent holes in it.

The thing that should have caught this — Prometheus itself — is also the thing that can't report its own write failures in a way that's visible when it's struggling to write. If Prometheus fires an alert about its own health, it has to successfully write that alert first.

The lesson I'd rather have learned earlier: a workaround that makes something stop crashing isn't the same as understanding why it was crashing. The `no-lockfile` flag made the immediate symptom go away, so I stopped looking. The underlying problem kept quietly eating data.

That's the specific kind of bad where everything looks fine.

---

*Based on [ADR-006](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-006-prometheus-local-storage.md) — why Prometheus TSDB lives on local storage and not NFS.*
