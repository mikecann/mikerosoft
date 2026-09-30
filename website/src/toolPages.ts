import { RENAMED_TOOLS, tools, type Tool } from './tools';

export const SITE_URL = 'https://mikerosoft.app';

/** The size X, Facebook and Slack show link previews at. */
export const SHARE_IMAGE_SIZE = { width: 1200, height: 630 };

export type Route =
  | { kind: 'home' }
  | { kind: 'tool'; name: string }
  | { kind: 'not-found' };

export function toolPath(name: string): string {
  return `/tools/${name}`;
}

export function parseRoute(pathname: string): Route {
  const path = pathname.replace(/\/+$/, '');
  if (path === '') return { kind: 'home' };

  const match = /^\/tools\/([^/]+)$/.exec(path);
  const requested = match && decodeURIComponent(match[1]);
  // Old links to a renamed tool open it under its new name.
  const name = requested && (RENAMED_TOOLS[requested] ?? requested);
  if (name && tools.some(tool => tool.name === name)) return { kind: 'tool', name };

  return { kind: 'not-found' };
}

export function readmeUrl(tool: Tool): string {
  return `${tool.url}/blob/main/README.md`;
}

/** The same prompt as the Get it section of each tool repo's README. */
export function makeItYoursPrompt(tool: Tool): string {
  return `Clone ${tool.url} and make it my own. `
    + "It's one of Mike Cann's personal tools, so read the README first, change anything specific to his setup to suit mine, "
    + 'then help me get it running.';
}

function escapeAttr(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * The link preview for a tool: a screenshot of its window from
 * scripts/share-images.ts, or its header art until one's been taken.
 */
export function shareImageFor(tool: Tool, hasScreenshot: boolean): string {
  if (hasScreenshot) return `${SITE_URL}/share/${tool.name}.jpg`;
  return tool.header ?? `${SITE_URL}/share/home.jpg`;
}

/**
 * Rewrites the built index.html for one tool, so a shared link previews that
 * tool rather than the home page. The React app takes over once it loads.
 */
export function withToolMeta(html: string, tool: Tool, description: string, image: string): string {
  const title = `${tool.name} · Mikerosoft`;
  const url = `${SITE_URL}${toolPath(tool.name)}`;

  const setMeta = (source: string, attr: 'name' | 'property', key: string, value: string) =>
    source.replace(
      new RegExp(`<meta ${attr}="${key}" content="[^"]*" />`),
      `<meta ${attr}="${key}" content="${escapeAttr(value)}" />`,
    );

  let page = html.replace(/<title>[^<]*<\/title>/, `<title>${escapeAttr(title)}</title>`);
  page = setMeta(page, 'name', 'description', description);
  page = setMeta(page, 'property', 'og:title', title);
  page = setMeta(page, 'property', 'og:description', description);
  page = setMeta(page, 'property', 'og:image', image);
  page = setMeta(page, 'property', 'og:url', url);
  page = setMeta(page, 'name', 'twitter:title', title);
  page = setMeta(page, 'name', 'twitter:description', description);
  page = setMeta(page, 'name', 'twitter:image', image);
  return page.replace(/<link rel="canonical" href="[^"]*" \/>/, `<link rel="canonical" href="${url}" />`);
}

/**
 * The page for a renamed tool's old link: the new tool's preview, plus a
 * refresh to its new address for anything that doesn't run the app.
 */
export function withRedirect(html: string, tool: Tool, description: string, image: string): string {
  return withToolMeta(html, tool, description, image).replace(
    '</head>',
    `<meta http-equiv="refresh" content="0; url=${toolPath(tool.name)}" />\n</head>`,
  );
}
