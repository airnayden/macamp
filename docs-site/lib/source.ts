import { loader } from 'fumadocs-core/source';
import { defineDocs } from 'fumadocs-mdx/macro';
import { applyMdxPreset } from 'fumadocs-mdx/config';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { docsRoute } from './shared';

const docs = defineDocs({
  dir: 'content/docs',
  docs: {
    schema: pageSchema,
    // Collection-level `mdxOptions` replaces the defaults outright, so re-apply
    // the standard preset and only override the image handling.
    mdxOptions: applyMdxPreset({
      remarkImageOptions: {
        // Keeps `/assets/…` srcs pointing at `public/` instead of re-bundling
        // each screenshot as a hashed copy; dimensions are still read from disk.
        useImport: false,
      },
    }),
  },
  meta: {
    schema: metaSchema,
  },
});

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: docsRoute,
  source: docs.toFumadocsSource(),
  plugins: [],
});
