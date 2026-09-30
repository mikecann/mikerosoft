export interface ToolDates {
  /** ISO 8601 time of the tool's first commit. */
  added: string;
  /** ISO 8601 time of the latest commit that changed the tool, not just its docs. */
  updated: string;
}

/** One commit from a tool repo's history, as read by parseGitLog. */
export interface Commit {
  hash: string;
  /** ISO 8601 commit time, as git wrote it. */
  date: string;
  subject: string;
  body: string;
  /** The files it touched, relative to the root of the tool's repo. */
  files: string[];
}

/**
 * `git log --no-merges --no-renames --name-only --format=<LOG_FORMAT>` in a
 * tool's repo feeds parseGitLog. `--no-renames` keeps git from diffing file
 * contents, which a blob-less clone would have to download.
 */
export const LOG_FORMAT = '%x00%H%x1f%cI%x1f%s%x1f%b%x1f';

// The header, screenshots, README, agent notes, licence and CI describe or
// check a tool rather than change it.
const NOT_THE_TOOL = /^(docs\/|\.github\/|README\.md$|AGENTS\.md$|LICENSE$)/;

// Each tool's repo starts with a commit that split it out of the old
// mikerosoft monorepo. It set the repo up rather than changing the tool.
const SPLIT_COMMIT = /^Standalone repo:/;

export function parseGitLog(log: string): Commit[] {
  const commits: Commit[] = [];
  for (const chunk of log.split('\0')) {
    const [hash, date, subject, body, files] = chunk.split('\x1f');
    if (!hash?.trim() || files === undefined) continue;
    commits.push({
      hash: hash.trim(),
      date: date.trim(),
      subject: subject.trim(),
      body,
      files: files.split('\n').map(file => file.trim()).filter(Boolean),
    });
  }
  return commits;
}

/** A file that's part of the tool itself, not its docs or repo housekeeping. */
export function isToolFile(path: string): boolean {
  return !NOT_THE_TOOL.test(path);
}

/** A commit that changed the tool: it touched a tool file and wasn't the split. */
export function changesTool(commit: Commit): boolean {
  return !SPLIT_COMMIT.test(commit.subject) && commit.files.some(isToolFile);
}

/**
 * When a tool was added and last changed, from its own repo's history. The
 * repos kept the monorepo history of their files, so the first commit is when
 * the tool first appeared, even if it started out under another name.
 */
export function toolDatesFromCommits(commits: readonly Commit[]): ToolDates | undefined {
  const times = commits.map(commit => Date.parse(commit.date)).filter(time => !Number.isNaN(time));
  if (times.length === 0) return undefined;

  const added = Math.min(...times);
  const changes = commits.filter(changesTool).map(commit => Date.parse(commit.date));
  const updated = Math.max(added, ...changes.filter(time => !Number.isNaN(time)));
  return { added: new Date(added).toISOString(), updated: new Date(updated).toISOString() };
}
