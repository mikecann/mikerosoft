export interface ToolDates {
  /** ISO 8601 time of the commit that first added the tool's oldest file. */
  added: string;
  /** ISO 8601 time of the latest commit that changed the tool, not just its docs. */
  updated: string;
}

const TOOL_PATH = /^tools\/([^/]+)\//;
// Header images, screenshots and the README describe a tool rather than change it.
const DOC_FILES = /^tools\/[^/]+\/(docs\/|README\.md$)/;

function toolOf(path: string): string | undefined {
  return TOOL_PATH.exec(path)?.[1];
}

/**
 * Works out when each tool folder was added and when it last changed.
 *
 * `log` is the output of
 * `git log --topo-order --reverse -M --name-status --format=%x00%cI`, and
 * `currentFiles` is `git ls-files tools`. A tool's added date is the earliest
 * origin of any file it contains today. Origins follow renames, so tools that
 * moved from the repo root into tools/, or were renamed, keep their real age.
 */
export function toolDatesFromGitLog(
  log: string,
  currentFiles: readonly string[],
): Record<string, ToolDates> {
  const origins = new Map<string, number>();
  const updated = new Map<string, number>();

  for (const commit of log.split('\0')) {
    const [header = '', ...changes] = commit.split('\n');
    const time = Date.parse(header.trim());
    if (Number.isNaN(time)) continue;

    for (const change of changes) {
      if (!change.trim()) continue;

      const [status = '', ...paths] = change.split('\t');
      const kind = status[0];
      if (kind === 'R' && paths.length === 2) {
        const [from, to] = paths;
        origins.set(to, origins.get(from) ?? time);
        origins.delete(from);
      } else if (kind === 'D') {
        origins.delete(paths[0]);
      } else {
        const path = paths[paths.length - 1];
        const origin = origins.get(path);
        origins.set(path, origin === undefined ? time : Math.min(origin, time));
      }

      for (const path of paths) {
        const tool = DOC_FILES.test(path) ? undefined : toolOf(path);
        if (tool) updated.set(tool, Math.max(updated.get(tool) ?? time, time));
      }
    }
  }

  const added = new Map<string, number>();
  for (const file of currentFiles) {
    const tool = toolOf(file);
    const origin = origins.get(file);
    if (!tool || origin === undefined) continue;
    added.set(tool, Math.min(added.get(tool) ?? origin, origin));
  }

  const dates: Record<string, ToolDates> = {};
  for (const [tool, addedTime] of added) {
    const updatedTime = Math.max(updated.get(tool) ?? addedTime, addedTime);
    dates[tool] = {
      added: new Date(addedTime).toISOString(),
      updated: new Date(updatedTime).toISOString(),
    };
  }
  return dates;
}
