import { defineCollection, z } from 'astro:content';

const blog = defineCollection({
  type: 'content',
  schema: z.object({
    title:   z.string(),
    date:    z.string(),
    summary: z.string(),
    adr:     z.string().optional(),
  }),
});

export const collections = { blog };
