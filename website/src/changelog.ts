import { changesTool, parseGitLog } from './gitHistory';

export interface ChangelogEntry {
  hash: string;
  /** ISO 8601 commit time. */
  date: string;
  title: string;
  /** The commit body, which says why it changed, split into paragraphs. */
  paragraphs: string[];
}

const TRAILER = /^(Co-Authored-By|Signed-off-by|Change-Id):/i;

function squash(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]/g, '');
}

/**
 * "Tandem app: a quieter UI" reads as "A quieter UI" on Tandem's own page.
 * Pass every name the tool has had, so older commits lose their prefix too.
 */
export function cleanTitle(subject: string, ...names: string[]): string {
  const match = /^([^:]{1,30}):\s+(.+)$/.exec(subject);
  if (!match || !names.some(name => squash(match[1]).startsWith(squash(name)))) return subject;
  return match[2][0].toUpperCase() + match[2].slice(1);
}

const LIST_ITEM = /^([-*]|\d+[.)])\s/;

/** Joins lines git wrapped at 72 columns, keeping each list item on its own line. */
function unwrap(paragraph: string): string {
  const lines: string[] = [];
  for (const raw of paragraph.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (lines.length === 0 || LIST_ITEM.test(line)) lines.push(line);
    else lines[lines.length - 1] += ` ${line}`;
  }
  return lines.join('\n');
}

function paragraphsOf(body: string): string[] {
  return body
    .split('\n')
    .filter(line => !TRAILER.test(line.trim()))
    .join('\n')
    .split(/\n\s*\n/)
    .map(unwrap)
    .filter(Boolean);
}

/**
 * Newest-first changes to one tool, from the `git log` of its own repo (see
 * LOG_FORMAT). Skips commits that only touched its docs, and the commit that
 * split it into its own repo. `names` is the tool's name, then any old ones.
 */
export function changelogFromGitLog(log: string, ...names: string[]): ChangelogEntry[] {
  return parseGitLog(log)
    .filter(changesTool)
    .map(commit => ({
      hash: commit.hash,
      date: new Date(commit.date).toISOString(),
      title: cleanTitle(commit.subject, ...names),
      paragraphs: paragraphsOf(commit.body),
    }))
    .sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
}
