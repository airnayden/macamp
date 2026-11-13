import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { Globe, Heart, Sparkles } from 'lucide-react';
import { Logo } from '@/components/brand';
import { githubUrl, site } from './shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: <Logo />,
      url: '/docs/',
    },
    // PLACEHOLDER repository — see `githubUrl` in lib/shared.ts.
    githubUrl,
    // The site is dark-only (forced in the provider), so the toggle would do nothing.
    themeSwitch: { enabled: false },
    links: [
      { text: 'Website', url: site('/'), icon: <Globe />, external: true },
      { text: 'Features', url: site('/features/'), icon: <Sparkles />, external: true },
      { text: 'Support', url: site('/support/'), icon: <Heart />, external: true },
    ],
  };
}
