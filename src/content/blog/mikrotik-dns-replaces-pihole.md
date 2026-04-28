---
title: "Pi-hole Is Gone. The Router Is the DNS Server Now."
date: "2026-04-13"
summary: "Pi-hole was causing random DNS timeouts and occasionally blacklisting my laptop without explanation. The MikroTik router has built-in adblock and static DNS entries. Removing Pi-hole simplified the stack and eliminated the problem."
adr: "ADR-018"
tags: ["networking", "dns", "mikrotik", "pihole", "decisions"]
---

The laptop losing DNS resolution at random intervals is the kind of failure that's hard to tolerate. Not a service going down — a foundational dependency becoming intermittently unreliable.

Pi-hole was the culprit. Or at least, Pi-hole was the component failing. Root cause was never conclusively identified.

## What Pi-hole was doing

The original DNS architecture (ADR-011) ran Pi-hole on `bran` (the Raspberry Pi) as the LAN DNS server with Unbound as the recursive resolver. The goals were:

- Network-wide ad blocking for all LAN devices
- Split DNS — internal hostnames resolving to internal IPs
- Recursive resolution without depending on an upstream resolver

It worked until it didn't.

## The failure modes

**Random DNS timeouts.** Queries would timeout for no apparent reason. The Pi-hole logs showed nothing — requests were being processed, or so it appeared. The Unbound logs were clean. The timeouts happened on DNS queries that the next identical query would resolve instantly.

**Unexplained laptop blacklisting.** Pi-hole blocked my laptop's queries at the IP level on two occasions. The blocklist in use shouldn't have caught a LAN device by IP address. I removed the IP from the blocklist. It appeared again a week later. Never identified why.

**Recovery required a service restart.** When the timeouts got bad, restarting the Pi-hole service on bran resolved them temporarily. This is not a sustainable operational pattern.

## Why not fix Pi-hole

The obvious response is: diagnose the root cause. I tried. The failure mode was intermittent enough that by the time I was SSH'd into bran with logs open, it had resolved itself. The options I considered:

**Add a second Pi-hole instance for redundancy.** Two unreliable nodes are worse than one. Redundancy doesn't address intermittent failure; it just means both nodes fail intermittently at different times.

**Replace Pi-hole with AdGuard Home.** A more modern DNS appliance with the same class of failure modes. Same RPi hardware, same single point of failure, different UI.

**Give up on the RPi as DNS infrastructure.** The RPi is a 1GB general-purpose computer running multiple services (Tailscale, CI runner, Pi-hole). It's not dedicated DNS hardware. The MikroTik is.

## The MikroTik solution

The router handles DNS for every device on the LAN. It's already the DHCP server. It has dedicated hardware designed to run continuously without intervention. It runs MikroTik RouterOS, which has had a DNS server since before I was thinking about homelabs.

**MikroTik built-in adblock** replaces Pi-hole's blocklists. Less granular — you can't whitelist individual domains through a UI — but the router is the right place to run network-wide blocking if you want it to be reliable.

**Static DNS entries** on the MikroTik replace split DNS:

| Pattern | IP |
|---------|-----|
| `*.kagiso.me` | `10.0.10.110` (external Traefik) |
| `*.local.kagiso.me` | `10.0.10.111` (internal Traefik) |

Wildcard static entries mean new services get correct internal resolution automatically. No Pi-hole allowlist entry required, no DNS propagation to manage.

**DNS architecture post-migration:**

```
LAN device
  │
  ▼
MikroTik (10.0.10.1:53)
  ├── Static entries checked first  →  internal IPs
  ├── Adblock domains               →  NXDOMAIN
  └── Everything else               →  1.1.1.1 (upstream)
```

## What I gave up

**DNSSEC.** Unbound validated DNSSEC. The MikroTik forwards to Cloudflare, which validates DNSSEC upstream. I trust Cloudflare's validation but I no longer control it.

**Fully recursive resolution.** Unbound resolved queries without a third-party upstream. The MikroTik forwards to `1.1.1.1`. DNS queries are now visible to Cloudflare. For a homelab, this trade is fine.

**Granular block/allowlist management.** Pi-hole's UI made it easy to review what was blocked and why. The MikroTik adblock is a binary on/off per blocklist source, with no per-domain visibility.

All three are acceptable losses. DNS reliability is not negotiable. The Raspberry Pi is not a reliable DNS server.

## The decommission

```bash
# Stop and disable Pi-hole and Unbound on bran
sudo systemctl stop pihole-FTL unbound
sudo systemctl disable pihole-FTL unbound
```

Updated the MikroTik DHCP server to hand out `10.0.10.1` as DNS Server 1 and `1.1.1.1` as DNS Server 2. DNS resolution has been stable since.

`bran` keeps its other roles: Tailscale exit node, WOL proxy, GitHub Actions runners. It's a fine machine for those jobs. DNS server wasn't one of them.

## Related

- [ADR-018: MikroTik DNS replacing Pi-hole](/decisions)
- [ADR-011: Pi-hole + Unbound (superseded)](/decisions)
