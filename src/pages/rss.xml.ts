import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

const SITE = 'https://kagiso.me';
const TITLE = 'kagiso.me — Living Homelab';
const DESCRIPTION = 'Architecture decisions, homelab learnings, and honest operational retrospectives.';

function escapeXml(str: string) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export const GET: APIRoute = async () => {
  const posts = (await getCollection('blog'))
    .sort((a, b) => new Date(b.data.date).getTime() - new Date(a.data.date).getTime());

  const items = posts.map(post => `
    <item>
      <title>${escapeXml(post.data.title)}</title>
      <link>${SITE}/blog/${post.id}</link>
      <guid isPermaLink="true">${SITE}/blog/${post.id}</guid>
      <description>${escapeXml(post.data.summary)}</description>
      <pubDate>${new Date(post.data.date).toUTCString()}</pubDate>
      ${post.data.adr ? `<category>${escapeXml(post.data.adr)}</category>` : ''}
    </item>`).join('');

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${escapeXml(TITLE)}</title>
    <link>${SITE}</link>
    <description>${escapeXml(DESCRIPTION)}</description>
    <language>en-ZA</language>
    <atom:link href="${SITE}/rss.xml" rel="self" type="application/rss+xml"/>
    <lastBuildDate>${new Date().toUTCString()}</lastBuildDate>
    ${items}
  </channel>
</rss>`;

  return new Response(xml, {
    headers: {
      'Content-Type': 'application/rss+xml; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    },
  });
};
