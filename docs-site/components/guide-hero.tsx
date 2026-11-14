import { Download, Sparkles } from 'lucide-react';
import { site } from '@/lib/shared';

/** Synthwave banner at the top of the guide's home page. */
export function GuideHero() {
  return (
    <section className="mac-hero not-prose" aria-label="MacAMP user guide">
      <span className="mac-hero-sun" aria-hidden="true" />
      <p className="mac-hero-kicker">User guide</p>
      <h2 className="mac-hero-title">
        Everything MacAMP
        <span className="mac-hero-script">after dark</span>
      </h2>
      <p className="mac-hero-text">
        How to install it, bring your music in, and get the most out of the assistant, downloads, karaoke, stats and
        every setting in between.
      </p>
      <div className="mac-hero-actions">
        <a className="mac-btn mac-btn-primary" href="/install/">
          <Download size={16} aria-hidden="true" /> Start with install
        </a>
        <a className="mac-btn mac-btn-ghost" href={site('/features/')}>
          <Sparkles size={16} aria-hidden="true" /> Feature tour
        </a>
      </div>
    </section>
  );
}
