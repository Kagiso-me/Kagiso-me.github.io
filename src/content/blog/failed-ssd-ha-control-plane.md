---
title: "The R590 SSD That Failed, and Why I Didn't Care"
date: "2026-05-03"
summary: "The SSD on tywin — one of my three control plane nodes — died after two years. The cluster has only been live a few months. No downtime. No panic. Here's what failed, how I diagnosed it, and why the lab was built to survive this without breaking a sweat."
tags: ["homelab", "kubernetes", "ha", "ansible", "hardware"]
---

The alert came through on a Saturday morning. Tywin — one of my three Kubernetes control plane nodes — was reporting disk errors. Not a warning about space, actual read/write failures. The SSD was dying.

My first reaction wasn't panic. It was closer to: "OK, let's see if what I built actually works."

## The hardware that failed

Tywin runs a Rougeware SSD. R590 for a 256GB drive — one of those moments where the cheaper option seemed fine. I bought it about two years ago, before this cluster even existed. The other nodes (tyrion and jaime) are running Intel SSDs. Also bought second-hand, also older. Both fine.

I won't buy Rougeware again.

## How I diagnosed it

The first sign was the node flipping to `NotReady` in the cluster. That alone doesn't tell you why — it could be network, could be the kubelet crashing, could be the OS hanging under load.

I SSH'd into tywin and started there:

```bash
dmesg | grep -i error
```

The output was loud. A wall of `blk_update_request: I/O error` lines against `/dev/sda`. The kernel was logging read failures at the block device level — not a filesystem issue, not a corrupted partition, the drive itself was returning errors.

Confirmed it with `smartctl`:

```bash
sudo smartctl -a /dev/sda
```

The SMART data showed a high `Reallocated_Sector_Ct` count and pending uncorrectable sectors. The drive was actively failing. At that point the diagnosis was done — this wasn't recoverable, it needed replacing.

## Why there was no downtime

Kubernetes control plane HA is one of those things that feels theoretical until it isn't.

I run three control plane nodes — tywin, tyrion, and jaime. etcd (the cluster's state store) requires a quorum of nodes to be available to keep operating. With three nodes, you need two. Tywin going offline meant I still had two. The cluster kept running.

While tywin was sitting there with a dying drive, the other two nodes were serving the API server, the workloads kept running, Flux kept reconciling, nothing paged. The failure was entirely contained to the hardware that failed.

This is exactly the scenario HA is designed for. It's just easy to forget that until a drive actually dies on you.

## The recovery

New SSD arrived. Swapped it in. Then:

```bash
ansible-playbook -i inventory/homelab site.yml --limit tywin
```

That's it. The Ansible playbook handles everything — base OS config, Kubernetes dependencies, joining the node back to the cluster. No wiki page to follow. No mental reconstruction of "what did I install on this thing a few months ago." The playbook is the source of truth and it doesn't forget.

Tywin was back in the cluster within the hour.

## The actual lesson

The lab has only been live for a few months and already the honest reflection is: the value of the automation isn't obvious until you need it under pressure. When the drive failed on a Saturday morning, I wasn't scrambling to remember package names or node-join tokens. I ran a playbook.

The HA control plane and the Ansible setup weren't expensive to build relative to the complexity of the cluster overall. They were just deliberate choices made early. Those two things turned what should have been a stressful incident into an inconvenience that cost me an hour and a new SSD.

Buy better SSDs. Build for failure anyway.
