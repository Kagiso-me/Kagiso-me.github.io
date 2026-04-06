# kagiso.me — Living Homelab Site

> **Status:** In progress — 2026-04-06
> **URL:** https://kagiso-me.github.io (custom domain: kagiso.me — TBD)
> **Repo:** https://github.com/Kagiso-me/kagiso-me.github.io

---

## Stack

- **Framework:** Astro 4 (static output)
- **Styling:** Tailwind CSS 4 + custom design tokens (Ayu Dark + Catppuccin accents)
- **Fonts:** Inter (prose) + JetBrains Mono (metrics, terminal)
- **Deploy:** GitHub Actions → GitHub Pages

---

## Pages

| Route | Purpose | Status |
|-------|---------|--------|
| `/` | Command Center — hero, live cards, cluster health, recent digest, active project | ✅ scaffold |
| `/status` | Live dashboard — nodes, services, terminal widget, evolution map | 🔲 pending |
| `/digest` | Ops log feed — chronological entries with tags | 🔲 pending |
| `/docs` | Infrastructure docs — guides, architecture, synced from homelab-infrastructure | 🔲 pending |
| `/projects` | Visual project tracker — timeline / Gantt-style | 🔲 pending |
| `/decisions` | ADR decision log — cards from docs/adr/ | 🔲 pending |

---

## Data Architecture

### Static content (synced from homelab-infrastructure on push)
- `docs/guides/**` → `/docs/guides/`
- `docs/adr/**` → `/decisions/`
- `docs/ops-log/**` → `/digest/`

### Live data (scheduled GitHub Action every 5 min)
```
public/data/
  live.json      ← Plex streams, SABnzbd speed, Flux sync, last backup
  status.json    ← node health, service uptime
  digest.json    ← latest ops-log entries (index)
  projects.json  ← project tracker data
  metrics.json   ← CPU/memory per node from Prometheus
```

---

## Special Features

1. **Live Terminal** — read-only WebSocket terminal on `/status`, runs whitelisted kubectl/flux/velero commands via a lightweight API on varys
2. **Infrastructure Evolution Map** — interactive D3 timeline on `/status` showing homelab growth over time
3. **ADR Decision Log** — `/decisions` renders all ADRs as cards with relationship links
4. **"What's Running Right Now"** — live cards on home page, refreshed every 30s from `live.json`

---

## Design Tokens

| Token | Value | Purpose |
|-------|-------|---------|
| `--color-base` | `#0d1117` | Page background |
| `--color-surface` | `#1e2534` | Cards |
| `--color-peach` | `#fab387` | Primary accent, links |
| `--color-mauve` | `#cba6f7` | Secondary accent, hover |
| `--color-gold` | `#e6b450` | Active state, warnings |
| `--color-ok` | `#a6e3a1` | Healthy status |
| `--color-crit` | `#f38ba8` | Critical status |
