import Link from 'next/link';
import { docsRoute, siteName } from '@/lib/shared';

// This site is documentation-only: `/` hands off to the guide immediately.
// A meta refresh keeps that working under `output: 'export'` (no server
// redirects) and without JavaScript; the markup below is the visible fallback.
export default function RootPage() {
  return (
    <>
      <meta httpEquiv="refresh" content={`0; url=${docsRoute}`} />
      <main className="mac-redirect flex flex-1 flex-col items-center justify-center gap-4 px-6 text-center">
        <h1 className="text-3xl text-fd-foreground">{siteName}</h1>
        <p className="text-fd-muted-foreground">Redirecting you to the user guide…</p>
        <Link
          href={docsRoute}
          className="mac-btn mac-btn-primary"
        >
          Open the user guide
        </Link>
      </main>
    </>
  );
}
