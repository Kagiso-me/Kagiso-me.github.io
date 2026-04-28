import type { APIRoute } from 'astro';
import { readFileSync } from 'fs';
import { join } from 'path';

export const GET: APIRoute = ({ site }) => {
  // Try to read live data at build time for the OG image
  let nodes = '3/3';
  let pods = '—';
  let flux = '—';
  let updatedLabel = 'live data';

  try {
    const liveRaw = readFileSync(join(process.cwd(), 'public/data/live.json'), 'utf-8');
    const live = JSON.parse(liveRaw);
    if (live.nodes) {
      const ready = live.nodes.filter((n: any) => n.status === 'ok').length;
      const total = live.nodes.length;
      const podCount = live.nodes.reduce((s: number, n: any) => s + (parseInt(n.pods) || 0), 0);
      nodes = `${ready}/${total}`;
      pods = String(podCount);
    }
    if (live.flux) {
      flux = String(live.flux.ready ?? live.flux.total ?? '—');
    }
    if (live.updated) {
      const mins = Math.round((Date.now() - new Date(live.updated).getTime()) / 60000);
      updatedLabel = mins < 60 ? `updated ${mins}m ago` : 'live data';
    }
  } catch {
    // live.json not available at build time — use placeholder values
  }

  function esc(s: string) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#09090e"/>
      <stop offset="100%" stop-color="#0f1118"/>
    </linearGradient>
    <linearGradient id="grad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#fab387"/>
      <stop offset="100%" stop-color="#cba6f7"/>
    </linearGradient>
    <linearGradient id="gradV" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#fab387"/>
      <stop offset="100%" stop-color="#cba6f7"/>
    </linearGradient>
    <radialGradient id="orb1" cx="15%" cy="25%" r="55%">
      <stop offset="0%" stop-color="#fab387" stop-opacity="0.15"/>
      <stop offset="100%" stop-color="#fab387" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="orb2" cx="85%" cy="75%" r="50%">
      <stop offset="0%" stop-color="#cba6f7" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="#cba6f7" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="orb3" cx="50%" cy="100%" r="40%">
      <stop offset="0%" stop-color="#74c7ec" stop-opacity="0.07"/>
      <stop offset="100%" stop-color="#74c7ec" stop-opacity="0"/>
    </radialGradient>
    <pattern id="dots" x="0" y="0" width="28" height="28" patternUnits="userSpaceOnUse">
      <circle cx="1" cy="1" r="1" fill="rgba(255,255,255,0.035)"/>
    </pattern>
  </defs>

  <!-- Background -->
  <rect width="1200" height="630" fill="url(#bg)"/>
  <rect width="1200" height="630" fill="url(#dots)"/>
  <rect width="1200" height="630" fill="url(#orb1)"/>
  <rect width="1200" height="630" fill="url(#orb2)"/>
  <rect width="1200" height="630" fill="url(#orb3)"/>

  <!-- Outer frame -->
  <rect x="24" y="24" width="1152" height="582" rx="16" fill="none"
        stroke="rgba(255,255,255,0.06)" stroke-width="1"/>

  <!-- Vertical accent line -->
  <rect x="80" y="100" width="3" height="340" rx="2" fill="url(#gradV)"/>

  <!-- Eyebrow path -->
  <text x="100" y="150" font-family="'JetBrains Mono',monospace" font-size="18"
        fill="#fab387" letter-spacing="2" opacity="0.9">~/kagiso.me</text>

  <!-- Main title -->
  <text x="100" y="260" font-family="'Inter','Space Grotesk',system-ui,sans-serif"
        font-size="96" font-weight="800" fill="#e6e1cf" letter-spacing="-4">Living</text>
  <text x="100" y="360" font-family="'Inter','Space Grotesk',system-ui,sans-serif"
        font-size="96" font-weight="800" letter-spacing="-4">
    <tspan fill="url(#grad)">Homelab</tspan>
  </text>

  <!-- Tagline -->
  <text x="100" y="415" font-family="'JetBrains Mono',monospace" font-size="20"
        fill="#6b7280">Corporate exec by day. Self-taught engineer by night.</text>

  <!-- Divider -->
  <rect x="100" y="440" width="80" height="2" rx="1" fill="url(#grad)"/>

  <!-- Live stat strip — right side -->
  <!-- Stat box background -->
  <rect x="760" y="160" width="360" height="300" rx="14"
        fill="rgba(30,37,52,0.7)" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>
  <rect x="760" y="160" width="360" height="2" rx="1" fill="url(#grad)" opacity="0.7"/>

  <!-- Stat header -->
  <text x="940" y="200" font-family="'JetBrains Mono',monospace" font-size="13"
        fill="#a6e3a1" text-anchor="middle" letter-spacing="2">● CLUSTER · LIVE</text>

  <!-- Divider inside box -->
  <rect x="780" y="215" width="320" height="1" fill="rgba(255,255,255,0.06)"/>

  <!-- Stat: nodes -->
  <text x="870" y="278" font-family="'Inter',system-ui,sans-serif"
        font-size="52" font-weight="800" fill="#e6e1cf" letter-spacing="-2" text-anchor="middle">${esc(nodes)}</text>
  <text x="870" y="306" font-family="'JetBrains Mono',monospace" font-size="12"
        fill="#6b7280" text-anchor="middle" letter-spacing="1">NODES READY</text>

  <!-- Vertical divider inside stat box -->
  <rect x="940" y="245" width="1" height="80" fill="rgba(255,255,255,0.07)"/>

  <!-- Stat: pods -->
  <text x="1010" y="278" font-family="'Inter',system-ui,sans-serif"
        font-size="52" font-weight="800" fill="#e6e1cf" letter-spacing="-2" text-anchor="middle">${esc(pods)}</text>
  <text x="1010" y="306" font-family="'JetBrains Mono',monospace" font-size="12"
        fill="#6b7280" text-anchor="middle" letter-spacing="1">PODS RUNNING</text>

  <!-- Divider row 2 -->
  <rect x="780" y="328" width="320" height="1" fill="rgba(255,255,255,0.06)"/>

  <!-- Stat: flux releases -->
  <text x="940" y="388" font-family="'Inter',system-ui,sans-serif"
        font-size="52" font-weight="800" fill="#e6e1cf" letter-spacing="-2" text-anchor="middle">${esc(flux)}</text>
  <text x="940" y="416" font-family="'JetBrains Mono',monospace" font-size="12"
        fill="#6b7280" text-anchor="middle" letter-spacing="1">FLUX RELEASES</text>

  <!-- Updated label -->
  <text x="940" y="446" font-family="'JetBrains Mono',monospace" font-size="11"
        fill="rgba(107,114,128,0.7)" text-anchor="middle">${esc(updatedLabel)}</text>

  <!-- Bottom manifesto -->
  <text x="100" y="500" font-family="'Inter',system-ui,sans-serif"
        font-size="22" font-weight="700" fill="rgba(107,114,128,0.7)">No demos.</text>
  <text x="216" y="500" font-family="'Inter',system-ui,sans-serif"
        font-size="22" fill="rgba(61,70,99,0.8)">·</text>
  <text x="234" y="500" font-family="'Inter',system-ui,sans-serif"
        font-size="22" font-weight="700" fill="rgba(107,114,128,0.7)">No staging.</text>
  <text x="390" y="500" font-family="'Inter',system-ui,sans-serif"
        font-size="22" fill="rgba(61,70,99,0.8)">·</text>
  <text x="408" y="500" font-family="'Inter',system-ui,sans-serif"
        font-size="22" font-weight="700">
    <tspan fill="url(#grad)">Built in public.</tspan>
  </text>

  <!-- Domain badge -->
  <rect x="80" y="540" width="200" height="40" rx="8"
        fill="rgba(250,179,135,0.08)" stroke="rgba(250,179,135,0.2)" stroke-width="1"/>
  <text x="180" y="566" font-family="'JetBrains Mono',monospace" font-size="16"
        fill="#fab387" text-anchor="middle">kagiso.me</text>

  <!-- Live pulse indicator -->
  <circle cx="1120" cy="568" r="6" fill="#a6e3a1"/>
  <circle cx="1120" cy="568" r="12" fill="#a6e3a1" opacity="0.15"/>
  <text x="1138" y="573" font-family="'JetBrains Mono',monospace" font-size="14"
        fill="#6b7280">live</text>
</svg>`;

  return new Response(svg, {
    headers: {
      'Content-Type': 'image/svg+xml',
      'Cache-Control': 'public, max-age=3600',
    },
  });
};
