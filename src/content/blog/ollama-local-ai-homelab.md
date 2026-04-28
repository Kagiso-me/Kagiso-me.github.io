---
title: "Running Local AI on a NUC: Ollama, Open WebUI, and Why This Changes the Homelab"
date: "2026-04-20"
summary: "Bronn (the Intel NUC Docker host) now runs Ollama with qwen2.5-coder:7b and a 13b general model, fronted by Open WebUI. No API keys, no usage limits, no data leaving the LAN. Here's what the setup looks like and what it's actually good for."
tags: ["ai", "ollama", "docker", "homelab", "selfhosted"]
---

The Intel NUC sitting on the shelf as a Docker host was underutilised. 32GB DDR4, an i3, and a 256GB NVMe — not a GPU workstation, but enough to run a 7b parameter model at reasonable inference speed.

The addition: Ollama as the model server, Open WebUI as the frontend, both running as Docker containers in the misc-stack on Bronn.

## The stack

```yaml
# Simplified from docker/compose/misc-stack.yml
ollama:
  image: ollama/ollama
  volumes:
    - ollama_data:/root/.ollama
  ports:
    - "11434:11434"

open-webui:
  image: ghcr.io/open-webui/open-webui:main
  environment:
    - OLLAMA_BASE_URL=http://ollama:11434
  volumes:
    - open-webui_data:/app/backend/data
```

Open WebUI is proxied through Traefik on the internal entrypoint (`*.local.kagiso.me`), so it's LAN-accessible without being exposed to the internet. No auth proxy in front of it right now — the MikroTik split DNS means it only resolves inside the LAN.

## Models running

| Model | Size | Use |
|-------|------|-----|
| `qwen2.5-coder:7b` | ~4.5GB VRAM | Code generation, config review |
| `llama3.1:8b` | ~5GB VRAM | General Q&A, summarisation |

The NUC has no GPU, so inference runs on CPU via Ollama's built-in CPU backend. A 7b model generates at roughly 8–12 tokens/second on the i3. Acceptable for interactive use, not competitive with cloud APIs for speed.

The plan is to bump to a 32b model (qwen2.5:32b) after a RAM upgrade later in the year. At 32GB the 32b model at Q4 quantisation sits at about 20GB — tight but feasible.

## What it's actually useful for

**Config review.** Pasting a Helm values file and asking "what will this do to Traefik's entrypoints" is genuinely useful. The model isn't perfect but it catches obvious problems.

**Explaining log output.** Prometheus alert output, Loki log lines, Kubernetes events — the model is good at parsing structured log formats and explaining what they mean in plain language.

**Drafting.** This blog post was outlined with local AI assistance. The drafting happened locally, no data left the LAN.

**What it's not useful for:** anything that requires current knowledge. The model's training cutoff means it doesn't know about chart schema changes introduced last month. For anything time-sensitive, the model is confidently wrong.

## What local AI doesn't replace

The instinct to reach for a local model when cloud AI is available needs calibrating. Local AI wins on:
- Privacy-sensitive content (config files with hostnames, internal architecture)
- High-volume low-stakes tasks (reformatting, summarising logs)
- Availability (no network dependency, no rate limits)

Cloud AI wins on:
- Speed (a lot faster at inference)
- Model quality (larger models, better reasoning)
- Current knowledge

The framing I've settled on: local AI is a first-pass tool. If the local model gives a good answer, done. If it's uncertain or wrong, escalate to a cloud model with the context scrubbed.

## Why this belongs in the homelab

The homelab exists to close the gap between knowing how systems work and actually operating them. Running AI inference locally is the same philosophy applied to the AI layer — don't just use the API, understand what's happening underneath it.

Knowing that a 7b model at Q4 quantisation requires ~5GB of memory, generates at 10 tok/s on a CPU, and degrades gracefully under memory pressure is the kind of operational knowledge that doesn't come from using ChatGPT.
