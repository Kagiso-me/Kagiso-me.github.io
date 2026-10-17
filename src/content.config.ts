import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// The Work room — one file per SERIES (a body of work), frames as an ordered
// array where array order IS the edit (never sorted). Stills and motion live as
// frame types inside a series, not as separate rooms. Image fields are public
// path strings written by the CMS; a branded placeholder renders until one is set
// (the `tag` label shows in its place during the placeholder phase).
const work = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/work' }),
  schema: z.object({
    order: z.number().default(10), // index sequence — CURATED, not by date
    number: z.string(), // displayed "No." e.g. "01"
    title: z.string(),
    years: z.string(),
    place: z.string().optional(),
    role: z.string().default('Photographer'),
    cover: z.string().optional(),
    coverAspect: z.enum(['3/2', '4/5']).default('3/2'),
    coverAlt: z.string().default(''),
    coverTag: z.string().optional(),
    statement: z.string(),
    teaser: z.string().optional(),
    mediumLabel: z.string().optional(),
    creditNote: z.string().optional(),
    gear: z.string().optional(),
    showFrameNumbers: z.boolean().default(false),
    draft: z.boolean().default(false),
    frames: z
      .array(
        z.object({
          type: z.enum(['still', 'film']).default('still'),
          span: z.enum(['full', 'wide', 'single', 'offset', 'pair', 'tall']).default('single'),
          image: z.string().optional(),
          imageB: z.string().optional(),
          video: z.string().optional(),
          runtime: z.string().optional(),
          alt: z.string().default(''),
          altB: z.string().optional(),
          side: z.enum(['left', 'right']).default('right'),
          caption: z.string().optional(),
          captionB: z.string().optional(),
          minvh: z.number().optional(),
          tag: z.string().optional(), // placeholder label until an image is set
          tagB: z.string().optional(),
        }),
      )
      .default([]),
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

export const collections = { work, cycling };
