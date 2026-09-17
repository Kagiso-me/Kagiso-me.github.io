import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// The journal — real incident write-ups and decision records. Preserved from the
// old site; the crown jewel. Route stays /blog so existing URLs and RSS guids hold.
const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    date: z.string(),
    summary: z.string(),
    adr: z.string().optional(),
    tags: z.array(z.string()).optional(),
  }),
});

// Image fields are stored as public path strings (e.g. /media/frame.jpg) written
// by the CMS on upload, so the room renders a real <img> when present and a
// branded placeholder when not. The optimization pipeline (astro:assets for
// in-repo, or R2 + Cloudflare Images for scale) is a media decision layered on
// top — swapping a string for an R2 URL is a per-entry change, nothing structural.
const photography = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/photography' }),
  schema: z.object({
    order: z.number().default(0),
    kind: z.enum(['fullbleed', 'single', 'diptych', 'offset', 'wide']).default('single'),
    image: z.string().optional(),
    imageB: z.string().optional(),
    alt: z.string().default(''),
    tag: z.string().optional(),
    tagB: z.string().optional(),
    title: z.string().optional(),
    titleB: z.string().optional(),
    place: z.string().optional(),
    year: z.string().optional(),
    yearB: z.string().optional(),
    side: z.enum(['left', 'right']).default('right'),
    minvh: z.number().optional(),
  }),
});

const films = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/films' }),
  schema: z.object({
    order: z.number().default(0),
    featured: z.boolean().default(false),
    title: z.string(),
    year: z.string(),
    role: z.string().optional(),
    runtime: z.string().optional(),
    info: z.string().optional(),
    poster: z.string().optional(),
    video: z.string().url().optional(),
    alt: z.string().default(''),
  }),
});

const cycling = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/cycling' }),
  schema: z.object({
    order: z.number().default(0),
    date: z.string(),
    issue: z.string().optional(),
    dek: z.string().optional(),
    lead: z.string().optional(),
    leadTag: z.string().optional(),
    leadCap: z.string().optional(),
    distance: z.string(),
    climb: z.string(),
    moving: z.string(),
    summitLabel: z.string().optional(),
    profile: z.string(),
    profileFill: z.string().optional(),
    summitX: z.number().default(470),
    summitY: z.number().default(40),
    intro: z.string(),
    figure: z.string().optional(),
    figureTag: z.string().optional(),
    figureCap: z.string().optional(),
    quote: z.string(),
    body: z.string().default(''),
    tall: z.string().optional(),
    tallTag: z.string().optional(),
    strip: z.array(z.object({ image: z.string().optional(), tag: z.string().optional() })).default([]),
  }),
});

export const collections = { blog, photography, films, cycling };
