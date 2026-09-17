// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://kagiso.me',
  integrations: [sitemap()],
  markdown: {
    shikiConfig: { theme: 'min-light', wrap: false },
  },
  redirects: {
    '/photos': '/photography',
    '/about': '/',
    '/status': '/lab',
    '/cost': '/lab',
    '/security': '/lab',
    '/projects': '/lab',
    '/digest': '/blog',
  },
});
