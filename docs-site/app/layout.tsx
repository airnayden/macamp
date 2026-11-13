import type { Metadata, Viewport } from 'next';
import localFont from 'next/font/local';
import { Provider } from '@/components/provider';
import { author, docsUrl, siteDescription, siteName } from '@/lib/shared';
import './global.css';

// Same self-hosted, latin-only variable fonts as the marketing site.
const display = localFont({
  src: './fonts/archivo-latin-standard-normal.woff2',
  variable: '--font-display',
  weight: '100 900',
  declarations: [{ prop: 'font-stretch', value: '62% 125%' }],
  display: 'swap',
});
const body = localFont({
  src: './fonts/inter-latin-wght-normal.woff2',
  variable: '--font-body',
  weight: '100 900',
  display: 'swap',
});
const mono = localFont({
  src: './fonts/jetbrains-mono-latin-wght-normal.woff2',
  variable: '--font-code',
  weight: '100 800',
  display: 'swap',
});
const script = localFont({
  src: './fonts/mr-dafoe-latin-400-normal.woff2',
  variable: '--font-script',
  weight: '400',
  display: 'swap',
});

export const metadata: Metadata = {
  metadataBase: new URL(docsUrl),
  title: {
    default: `${siteName}: the MacAMP user guide`,
    template: `%s · ${siteName}`,
  },
  description: siteDescription,
  authors: [{ name: author.name, url: author.url }],
  creator: author.name,
  openGraph: { siteName, type: 'website' },
  twitter: { card: 'summary_large_image' },
};

export const viewport: Viewport = {
  themeColor: '#0D0221',
  colorScheme: 'dark',
};

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html
      lang="en"
      className={`dark ${display.variable} ${body.variable} ${mono.variable} ${script.variable}`}
      suppressHydrationWarning
    >
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
