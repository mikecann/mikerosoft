export interface ChangelogEntry {
  hash: string;
  /** ISO 8601 commit time. */
  date: string;
  title: string;
  /** The commit body, which says why it changed, split into paragraphs. */
  paragraphs: string[];
}

/** `git log --no-merges --name-only --format=<LOG_FORMAT>` feeds changelogsFromGitLog. */
export const LOG_FORMAT = '%x00%H%x1f%cI%x1f%s%x1f%b%x1f';

const TOOL_PATH = /^tools\/([^/]+)\//;
// Header images, screenshots and the README describe a tool rather than change it.
const DOC_FILES = /^tools\/[^/]+\/(docs\/|README\.md$)/;
const TRAILER = /^(Co-Authored-By|Signed-off-by|Change-Id):/i;

function squash(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** "Tandem app: a quieter UI" reads as "A quieter UI" on Tandem's own page. */
export function cleanTitle(subject: string, tool: string): string {
  const match = /^([^:]{1,30}):\s+(.+)$/.exec(subject);
  if (!match || !squash(match[1]).startsWith(squash(tool))) return subject;
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

/** Newest-first changes per tool, skipping commits that only touched its docs. */
export function changelogsFromGitLog(log: string): Record<string, ChangelogEntry[]> {
  const changelogs: Record<string, ChangelogEntry[]> = {};

  for (const commit of log.split('\0')) {
    const [hash, date, subject, body, files] = commit.split('\x1f');
    if (!hash || files === undefined) continue;

    const tools = new Set<string>();
    for (const file of files.split('\n')) {
      const tool = TOOL_PATH.exec(file.trim())?.[1];
      if (tool && !DOC_FILES.test(file.trim())) tools.add(tool);
    }

    for (const tool of tools) {
      (changelogs[tool] ??= []).push({
        hash: hash.trim(),
        date: new Date(date).toISOString(),
        title: cleanTitle(subject.trim(), tool),
        paragraphs: paragraphsOf(body),
      });
    }
  }

  for (const entries of Object.values(changelogs)) {
    entries.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
  }
  return changelogs;
}
