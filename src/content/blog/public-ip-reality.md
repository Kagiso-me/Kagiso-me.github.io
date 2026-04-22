---
title: "What the Internet Does to a Homelab with a Public IP"
date: "2026-03-30"
summary: "The day the wildcard certificate came through was the day the scanning started. About 2,000 requests per day looking for WordPress installations, exposed .env files, and admin panels. My cluster has none of those. The scanners don't care."
adr: "ADR-017"
---

The day the wildcard cert came through for `*.kagiso.me` was the day the cluster had a real public-facing presence. Traefik sitting on `10.0.10.110`, a Cloudflare DNS record pointed at the home IP, Let's Encrypt certificate issued and trusted. Everything I'd built for months was actually accessible.

Within a few hours, something was probing `/wp-admin`.

## What the logs showed

The cluster runs no WordPress. It never has. The scanner didn't know that. It wasn't targeting this homelab specifically — it was targeting every IP that responds on port 443. The cluster just became the newest entry in the rotation.

Over the following weeks, Traefik logs accumulated the same pattern on repeat: `/wp-admin/`, `/.env`, `/phpmyadmin`, `/admin.php`, `/.git/config`. Different source IPs, same paths, constant cadence. About 2,000 requests a day that had nothing to do with me personally and everything to do with the automated scanning infrastructure that runs across the entire internet at all times.

This is what a public IP means in practice. The probing isn't targeted — it's ambient. Every time a new IP starts responding on 443, something finds it within hours and starts walking down the standard list of exposed-credential endpoints. If anything on the cluster had a misconfigured default password or an admin panel with no authentication, the scanner would have found it before I noticed the traffic.

## The first response (and why it wasn't enough)

The initial approach was to block the most obvious paths at the Traefik level — explicit rules returning 403 for `/wp-admin`, `/.env`, and a handful of others on external IngressRoutes. This works for paths you've thought to list. It does nothing for the ones you haven't, for IPs with known bad reputation, or for anything more sophisticated than a path scan.

What I didn't have was anything that could learn from patterns rather than just block paths I'd already anticipated.

## CrowdSec

CrowdSec's model is different from a traditional blocklist. The agent parses Traefik logs and compares behaviour against a community threat intelligence feed — a shared database built from what other CrowdSec deployments have seen across the internet. When an IP was flagged six months ago for scanning someone else's cluster, that reputation arrives at this cluster before the IP ever sends a request. The Traefik bouncer drops it at the connection level.

The dashboard it produces was striking the first time I saw it. A world map with pins for request origins. A persistent offenders table: specific IPs, hit counts, which rule they triggered. Real numbers: 1,847 IPs currently blocked at the bouncer. 12 new bans in the last 24 hours.

None of these are sophisticated attacks. They're automated. Running constantly, at scale, looking for anything misconfigured. Which is exactly what makes them worth taking seriously — the skill threshold to participate in them is essentially zero, and the volume is constant.

## What changed and what didn't

The `/wp-admin` and `/.env` hits are still arriving. They show in the logs. What changed is that the known-bad IPs get blocked before the request reaches any application, the blocking list keeps updating as the community feed refreshes, and the CrowdSec bouncer middleware now sits globally on all external IngressRoutes — not just the ones I'd specifically thought to protect.

The separate step of blocking admin paths on Vaultwarden and Authentik's external ingress also went in around this time. Belt and braces.

## The thing I got backwards

The assumption I'd carried into the homelab was that security is something you add when you're ready — after the core infrastructure is stable, after the applications are deployed and working, once there's bandwidth to think about hardening.

That's exactly backwards. The moment a cluster has a public IP, it's participating in a global internet where scanning is constant and automated. "Not ready yet" isn't a posture that the internet respects. The cluster had a real IP and a trusted cert for about four hours before the first scan hit.

I'm not saying this to be dramatic about homelab security. The threats are automated and unsophisticated. But "automated and unsophisticated" is precisely the threat model that catches misconfigured default passwords and exposed admin panels — the things that are most likely to be present in a homelab that's still being built.

The security layer should go in before the applications, not after them.

---

*Based on [ADR-017](https://github.com/Kagiso-me/homelab-infrastructure/blob/main/docs/adr/ADR-017-crowdsec.md) — why CrowdSec sits in front of every external ingress.*
