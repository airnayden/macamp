import type { ComponentProps } from 'react';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import type { source } from '@/lib/source';

type Source = typeof source;
type Page = Source['$inferPage'];

/**
 * The guide cross-links pages with extension-less relative paths (`./install`,
 * `./lyrics#troubleshooting-lyrics`). `source.resolveHref` only matches real
 * file paths, so those fall through untouched and the browser then resolves
 * them against the *current* page — `/docs/settings/importing` instead of
 * `/docs/importing`. Retrying with the `.mdx` extension resolves them properly
 * and keeps the migrated MDX byte-identical to its previous location.
 */
export function createDocsLink(source: Source, page: Page) {
  const RelativeLink = createRelativeLink(source, page);

  return function DocsLink({ href, ...props }: ComponentProps<'a'>) {
    return <RelativeLink href={href ? asResolvableHref(source, page, href) : href} {...props} />;
  };
}

function asResolvableHref(source: Source, page: Page, href: string): string {
  if (!href.startsWith('./') && !href.startsWith('../')) return href;
  if (source.resolveHref(href, page) !== href) return href;

  const hashIndex = href.indexOf('#');
  const path = hashIndex === -1 ? href : href.slice(0, hashIndex);
  const hash = hashIndex === -1 ? '' : href.slice(hashIndex);
  if (path.slice(path.lastIndexOf('/') + 1).includes('.')) return href;

  const candidate = `${path}.mdx${hash}`;
  return source.resolveHref(candidate, page) === candidate ? href : candidate;
}
