/** Nav title shown in the docs header. */
export const appName = 'MacAMP';

/** Full site name, used for page metadata. */
export const siteName = 'MacAMP Docs';

export const siteDescription =
  'The MacAMP user guide: install, import, playback, the AI assistant, YouTube downloads, karaoke, listening stats and every setting.';

/** Base route the documentation is mounted at: the site root, since the guide has its own subdomain. */
export const docsRoute = '/';

/** Where these docs are deployed (canonical URLs, Open Graph). */
export const docsUrl = 'https://docs.macamp.si';

/** The marketing site. Keep in sync with `SITE.url` in macamp-website. */
export const websiteUrl = 'https://macamp.si';

/** The public source repository. */
export const githubUrl = 'https://github.com/airnayden/macamp';

/** Author credit (GPLv3 + NOTICE attribution). */
export const author = { name: 'Nayden Panchev', url: 'https://drpanchev.com' } as const;

/** Builds a link into the marketing site. */
export const site = (path = '/') => `${websiteUrl}${path}`;
