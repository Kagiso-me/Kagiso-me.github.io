import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}

function esc(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Naive word-wrap into at most `max` lines of roughly `width` characters.
function wrap(text: string, width: number, max: number) {
  const words = text.split(/\s+/);
  const lines: string[] = [];
  let line = '';
  for (const w of words) {
    if ((line + ' ' + w).trim().length > width) {
      lines.push(line.trim());
      line = w;
      if (lines.length === max - 1) break;
    } else {
      line = (line + ' ' + w).trim();
    }
  }
  const used = lines.join(' ').split(/\s+/).length;
  let rest = words.slice(used).join(' ');
  if (rest.length > width) rest = rest.slice(0, width - 1).trimEnd() + '…';
  if (rest) lines.push(rest);
  return lines.slice(0, max);
}

export const GET: APIRoute = ({ props }) => {
  const post = (props as any).post;
  const date = new Date(post.data.date).toLocaleDateString('en-ZA', { year: 'numeric', month: 'long', day: 'numeric' });
  const eyebrow = [String(date).toUpperCase(), post.data.adr ? String(post.data.adr).toUpperCase() : '']
    .filter(Boolean)
    .join('   ·   ');
  const lines = wrap(post.data.title, 22, 3);
  const titleSvg = lines
    .map((ln: string, i: number) => `<text x="90" y="${262 + i * 96}" font-family="Georgia, 'Cormorant Garamond', serif" font-size="82" font-weight="500" letter-spacing="-2" fill="#F3EFE7">${esc(ln)}</text>`)
    .join('\n  ');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="#151210"/>
  <rect x="0" y="0" width="1200" height="6" fill="#D5743E"/>
  <text x="96" y="140" font-family="Manrope, sans-serif" font-size="20" font-weight="600" letter-spacing="4" fill="#A79F92">${esc(eyebrow)}</text>
  ${titleSvg}
  <rect x="96" y="556" width="96" height="3" fill="#D5743E"/>
  <text x="96" y="540" font-family="Georgia, serif" font-size="30" font-weight="500" fill="#F3EFE7">kagiso<tspan fill="#D5743E">.</tspan></text>
  <text x="1104" y="540" text-anchor="end" font-family="Manrope, sans-serif" font-size="18" letter-spacing="3" fill="#6E665B">THE JOURNAL</text>
</svg>`;

  return new Response(svg, {
    headers: { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'public, max-age=3600' },
  });
};
