import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map(post => ({ params: { slug: post.id }, props: { post } }));
}

function wrapText(text: string, maxChars: number): string[] {
  const words = text.split(' ');
  const lines: string[] = [];
  let current = '';
  for (const word of words) {
    if ((current + ' ' + word).trim().length > maxChars) {
      if (current) lines.push(current.trim());
      current = word;
    } else {
      current = current ? current + ' ' + word : word;
    }
  }
  if (current) lines.push(current.trim());
  return lines.slice(0, 3);
}

export const GET: APIRoute = ({ props }) => {
  const { post } = props as { post: any };
  const title = post.data.title as string;
  const date = new Date(post.data.date).toLocaleDateString('en-ZA', {
    year: 'numeric', month: 'long', day: 'numeric',
  });
  const adr = post.data.adr as string | undefined;
  const words = (post.body as string).trim().split(/\s+/).length;
  const readingTime = Math.ceil(words / 200);

  const lines = wrapText(title, 36);
  const lineHeight = 82;
  const titleY = lines.length === 1 ? 310 : lines.length === 2 ? 270 : 240;

  const titleSvg = lines
    .map((line, i) =>
      `<text x="80" y="${titleY + i * lineHeight}" font-family="'Inter',system-ui,sans-serif"
        font-size="68" font-weight="800" fill="#e6e1cf" letter-spacing="-2">${
          line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
        }</text>`
    )
    .join('\n  ');

  const metaY = titleY + lines.length * lineHeight + 28;
  const adrText = adr ? `${adr} · ` : '';

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0d1117"/>
      <stop offset="100%" stop-color="#10141c"/>
    </linearGradient>
    <linearGradient id="grad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#fab387"/>
      <stop offset="100%" stop-color="#cba6f7"/>
    </linearGradient>
    <radialGradient id="orb1" cx="10%" cy="20%" r="50%">
      <stop offset="0%" stop-color="#fab387" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="#fab387" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="orb2" cx="90%" cy="80%" r="45%">
      <stop offset="0%" stop-color="#cba6f7" stop-opacity="0.10"/>
      <stop offset="100%" stop-color="#cba6f7" stop-opacity="0"/>
    </radialGradient>
    <pattern id="dots" x="0" y="0" width="28" height="28" patternUnits="userSpaceOnUse">
      <circle cx="1" cy="1" r="1" fill="rgba(255,255,255,0.04)"/>
    </pattern>
  </defs>

  <rect width="1200" height="630" fill="url(#bg)"/>
  <rect width="1200" height="630" fill="url(#dots)"/>
  <rect width="1200" height="630" fill="url(#orb1)"/>
  <rect width="1200" height="630" fill="url(#orb2)"/>

  <!-- Accent line -->
  <rect x="80" y="120" width="3" height="300" rx="2" fill="url(#grad)"/>

  <!-- Border frame -->
  <rect x="24" y="24" width="1152" height="582" rx="16" fill="none"
        stroke="rgba(255,255,255,0.06)" stroke-width="1"/>

  <!-- Eyebrow -->
  <text x="100" y="160" font-family="'JetBrains Mono',monospace" font-size="20"
        fill="#fab387" letter-spacing="2">kagiso.me/blog</text>

  <!-- Title lines -->
  ${titleSvg.split('\n').map(l => '  ' + l.trim()).join('\n  ')}

  <!-- Meta row -->
  <text x="100" y="${metaY}" font-family="'JetBrains Mono',monospace" font-size="18"
        fill="#6b7280">${adrText}${date} · ${readingTime} min read</text>

  <!-- Divider -->
  <rect x="100" y="${metaY + 28}" width="100" height="2" rx="1" fill="url(#grad)"/>

  <!-- Domain badge -->
  <rect x="80" y="555" width="220" height="40" rx="8"
        fill="rgba(250,179,135,0.08)" stroke="rgba(250,179,135,0.2)" stroke-width="1"/>
  <text x="190" y="581" font-family="'JetBrains Mono',monospace" font-size="16"
        fill="#fab387" text-anchor="middle">kagiso.me</text>

  <!-- Live indicator -->
  <circle cx="1100" cy="580" r="6" fill="#a6e3a1"/>
  <circle cx="1100" cy="580" r="12" fill="#a6e3a1" opacity="0.15"/>
  <text x="1118" y="585" font-family="'JetBrains Mono',monospace" font-size="14"
        fill="#6b7280">live</text>
</svg>`;

  return new Response(svg, {
    headers: {
      'Content-Type': 'image/svg+xml',
      'Cache-Control': 'public, max-age=86400',
    },
  });
};
