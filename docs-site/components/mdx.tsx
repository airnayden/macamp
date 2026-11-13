import defaultMdxComponents from 'fumadocs-ui/mdx';
import type { MDXComponents } from 'mdx/types';
import { GuideHero } from '@/components/guide-hero';

export function getMDXComponents(components?: MDXComponents) {
  return {
    ...defaultMdxComponents,
    GuideHero,
    ...components,
  } satisfies MDXComponents;
}

export const useMDXComponents = getMDXComponents;

declare global {
  type MDXProvidedComponents = ReturnType<typeof getMDXComponents>;
}
