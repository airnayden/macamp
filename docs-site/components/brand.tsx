import { ArrowUpRight, Download } from 'lucide-react';
import { author, site } from '@/lib/shared';

/** Header wordmark: app icon + “MacAMP” in the site's neon gradient + a Docs tag. */
export function Logo() {
  return (
    <span className="mac-logo">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/brand/app-icon.png" alt="" width={30} height={30} className="mac-logo-icon" />
      <span className="mac-logo-word">
        Mac<span>AMP</span>
      </span>
      <span className="mac-logo-tag">Docs</span>
    </span>
  );
}

/** Top-of-sidebar card that leads back to the marketing site. */
export function SidebarBanner() {
  return (
    <a href={site('/download/')} className="mac-banner">
      <span className="mac-banner-sun" aria-hidden="true" />
      <span className="mac-banner-text">
        <strong>Get MacAMP for Mac</strong>
        <small>Free · macOS 14 or later</small>
      </span>
      <Download className="mac-banner-icon" size={16} aria-hidden="true" />
    </a>
  );
}

/** Bottom-of-sidebar links. */
export function SidebarFooter() {
  return (
    <nav className="mac-side-foot" aria-label="MacAMP website">
      <a href={site('/features/')}>
        Features <ArrowUpRight size={12} aria-hidden="true" />
      </a>
      <a href={site('/faq/')}>
        FAQ <ArrowUpRight size={12} aria-hidden="true" />
      </a>
      <a href={site('/support/')}>
        Support <ArrowUpRight size={12} aria-hidden="true" />
      </a>
      <span className="mac-side-credit">
        Made by <a href={author.url}>{author.name}</a> · GPL v3
      </span>
    </nav>
  );
}
