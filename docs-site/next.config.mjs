import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  reactStrictMode: true,
  // Don't generate AGENTS.md on `next dev`.
  agentRules: false,
  // Emit `out/<route>/index.html` so the export works on any plain static host,
  // and so relative in-page links (`./install`) resolve against `/docs/…`.
  trailingSlash: true,
  images: {
    // `next/image` optimization needs a server; the export must stay serverless.
    unoptimized: true,
  },
};

export default withMDX(config);
