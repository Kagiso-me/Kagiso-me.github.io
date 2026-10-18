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
    '/photos': '/stills-and-motion',
    '/photography': '/stills-and-motion',
    '/film': '/stills-and-motion',
    '/work': '/stills-and-motion',
    '/about': '/',
    '/status': '/',
    '/cost': '/',
    '/security': '/',
    '/projects': '/',
    '/digest': '/',
    '/blog': '/',
  },
});
