/** Reading the mikerosoft repo from GitHub, for the Internet Explorer window. */

const OWNER = 'mikecann';
const REPO = 'mikerosoft';
const BRANCH = 'main';
const REPO_URL = `https://github.com/${OWNER}/${REPO}`;
const API = `https://api.github.com/repos/${OWNER}/${REPO}`;

export interface RepoEntry {
  name: string;
  path: string;
  type: 'dir' | 'file';
  size: number;
}

export type RepoPage =
  | { kind: 'dir'; path: string; entries: RepoEntry[]; readmeHtml?: string }
  | { kind: 'file'; path: string; text?: string; html?: string; imageUrl?: string; size: number };

export function githubUrl(path: string, type: 'dir' | 'file' = 'dir'): string {
  if (!path) return REPO_URL;
  return `${REPO_URL}/${type === 'file' ? 'blob' : 'tree'}/${BRANCH}/${path}`;
}

export function rawUrl(path: string): string {
  return `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/${path}`;
}

export function parentPath(path: string): string {
  return path.split('/').slice(0, -1).join('/');
}

/** The repo path an address points at, or undefined if it's somewhere else. */
export function repoPathFromUrl(url: string): string | undefined {
  const match = new RegExp(`^(?:https?://)?(?:www\\.)?github\\.com/${OWNER}/${REPO}(?:/(?:tree|blob)/${BRANCH})?(/[^?#]*)?(?:[?#].*)?$`, 'i')
    .exec(url.trim());
  if (!match) return undefined;
  return (match[1] ?? '').replace(/^\/+|\/+$/g, '');
}

/** Follows a relative link, like `../record-it` or `docs/PLAN.md`, from a folder in the repo. */
export function resolveRepoPath(fromDir: string, href: string): string {
  const clean = href.split(/[?#]/)[0];
  const parts = clean.startsWith('/') ? [] : fromDir.split('/').filter(Boolean);
  for (const part of clean.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') parts.pop();
    else parts.push(part);
  }
  return parts.join('/');
}

const IMAGE = /\.(png|jpe?g|gif|webp|svg|ico)$/i;
const MARKDOWN = /\.(md|markdown)$/i;
const MAX_TEXT = 200_000;
const cache = new Map<string, Promise<RepoPage>>();

async function get(url: string, accept = 'application/vnd.github+json'): Promise<Response> {
  const response = await fetch(url, { headers: { Accept: accept } });
  if (response.status === 403 || response.status === 429) {
    throw new Error("GitHub says we've looked at too many pages for now. Try again in a bit, or open it on GitHub.");
  }
  if (response.status === 404) throw new Error('The page cannot be displayed. It might have been moved or renamed.');
  if (!response.ok) throw new Error(`GitHub had a problem (${response.status}).`);
  return response;
}

function contentsUrl(path: string): string {
  return `${API}/contents/${path.split('/').map(encodeURIComponent).join('/')}?ref=${BRANCH}`;
}

function decodeBase64(content: string): string {
  const bytes = Uint8Array.from(atob(content.replace(/\n/g, '')), char => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

async function loadPage(path: string): Promise<RepoPage> {
  const data = await (await get(contentsUrl(path))).json();

  if (Array.isArray(data)) {
    const entries: RepoEntry[] = data
      .map(({ name, path: entryPath, type, size }): RepoEntry => ({ name, path: entryPath, type: type === 'dir' ? 'dir' : 'file', size }))
      .sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1));
    const readme = entries.find(entry => entry.type === 'file' && /^readme\.md$/i.test(entry.name));
    const readmeHtml = readme ? await (await get(contentsUrl(readme.path), 'application/vnd.github.html')).text() : undefined;
    return { kind: 'dir', path, entries, readmeHtml };
  }

  if (IMAGE.test(path)) return { kind: 'file', path, imageUrl: rawUrl(path), size: data.size };
  if (MARKDOWN.test(path)) {
    const html = await (await get(contentsUrl(path), 'application/vnd.github.html')).text();
    return { kind: 'file', path, html, size: data.size };
  }
  if (data.encoding !== 'base64' || data.size > MAX_TEXT) return { kind: 'file', path, size: data.size };
  const text = decodeBase64(data.content);
  // A NUL byte means it's binary, like an exe or a model file.
  return { kind: 'file', path, text: text.includes('\u0000') ? undefined : text, size: data.size };
}

/** Loads a folder or file from the repo, remembering it so going back doesn't cost another request. */
export function loadRepoPage(path: string): Promise<RepoPage> {
  let page = cache.get(path);
  if (!page) {
    page = loadPage(path);
    page.catch(() => cache.delete(path));
    cache.set(path, page);
  }
  return page;
}
