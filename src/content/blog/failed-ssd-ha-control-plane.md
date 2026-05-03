---
title: "The R590 SSD That Failed, and Why I Didn't Care"
date: "2026-05-03"
summary: "The SSD on tywin — one of my three control plane nodes — died after two years. The cluster has only been live a few months. No downtime. No panic. Here's what failed, how I diagnosed it, and why the lab was built to survive this without breaking a sweat."
tags: ["homelab", "kubernetes", "ha", "ansible", "hardware"]
---

The alert came through on a Saturday morning. Tywin — one of my three Kubernetes control plane nodes — was reporting disk errors. Not a warning about space, actual read/write failures. The SSD was dying.

My first reaction wasn't panic. It was closer to: "OK, let's see if what I built actually works."

## How the lab was built

When I set up the cluster, running three control plane nodes was a deliberate choice, not the path of least resistance. A single control plane is simpler to set up. It's also a single point of failure — and I knew from the start that hardware in a homelab is cheap, second-hand, and eventually going to let you down.

The three nodes — tywin, tyrion, and jaime — all run both the control plane and workloads. On top of that, kube-vip runs as a DaemonSet across all three and holds a virtual IP at `10.0.10.100`. That's the address everything uses to talk to the Kubernetes API. No single node owns it — kube-vip elects a leader and the VIP moves if that node goes down.

The Ansible playbooks encode how all of this is set up, step by step. The assumption baked into that work was: at some point, I'll need to rebuild a node. That assumption paid off sooner than expected.

## The hardware that failed

Tywin runs a Rougeware SSD. R590 for a 256GB drive — I bought it about two years ago, before this cluster even existed. The other nodes (tyrion and jaime) are running Intel SSDs. Both fine.

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

With tywin down, the VIP moved. Tyrion picked up `10.0.10.100`. kubectl kept working. Flux kept reconciling. Every workload running on tywin was rescheduled onto the remaining nodes automatically.

The etcd state store is where it gets interesting. etcd requires a quorum to keep operating — with three nodes, you need two. Tywin going offline left me with two. The cluster stayed writable, stayed healthy, and nothing paged.

This is exactly the scenario HA is designed for. The failure was contained entirely to the node with the dying drive.

## The recovery

New SSD arrived. Swapped it in. Then:

```bash
ansible-playbook -i inventory/homelab playbooks/lifecycle/rejoin-server.yml --limit tywin
```

One command. Here's what it actually does:

**Purge.** It deletes the node object from Kubernetes, kills any remaining k3s processes, runs the uninstall script, and wipes all k3s directories. The node is cleaned to bare metal state.

**Rejoin.** It reads the join token from a healthy node automatically, installs k3s, and rejoins tywin as an additional control plane server. It verifies the etcd peer port and API port are reachable before attempting the join, and waits for the node to show `Ready` before moving on.

**Restore config.** It recreates the etcd snapshot configuration — snapshots run every 6 hours to MinIO on TrueNAS (10.0.10.80), with 7 snapshots retained. This gets restored because it lives in a config file that doesn't survive the wipe.

**Verify.** It prints final cluster node status. You know it worked before the playbook exits.

Tywin was back in the cluster within 7 hours of the drive failing — most of that was waiting for a new SSD to be delivered. The actual rebuild took under an hour. No wiki page to follow. No manual reconstruction of what was installed. The playbook is the operational knowledge — written down once, executable on demand.

## The actual lesson

The lab has only been live for a few months and already the honest reflection is: the value of the automation isn't obvious until you need it under pressure. When the drive failed on a Saturday morning, I wasn't scrambling to remember package names or node-join tokens. I ran a playbook.

The HA setup and the Ansible work weren't expensive to build relative to the overall complexity of the cluster. They were deliberate choices made early. And because the etcd snapshots go to MinIO, even a total loss of all three nodes isn't unrecoverable — the SSD failure was the easy case, but the harder case is covered too.

Buy better SSDs. Build for failure anyway.
