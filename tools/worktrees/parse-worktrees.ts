export type ParsedWorktree = {
  path: string;
  head: string;
  branch: string | null;
};

export function parseWorktreePorcelain(output: string): ParsedWorktree[] {
  const trimmed = output.trim();
  if (!trimmed) return [];

  const blocks = trimmed.split(/\n\n+/);
  const result: ParsedWorktree[] = [];

  for (const block of blocks) {
    const lines = block.trim().split('\n');
    let path = '';
    let head = '';
    let branch: string | null = null;

    for (const line of lines) {
      if (line.startsWith('worktree ')) path = line.slice('worktree '.length).trim();
      else if (line.startsWith('HEAD ')) head = line.slice('HEAD '.length).trim();
      else if (line.startsWith('branch ')) branch = line.slice('branch '.length).trim();
      else if (line === 'detached') branch = null;
    }

    if (path) result.push({ path, head, branch });
  }

  return result;
}

/** True when this checkout is a linked worktree (safe target for `git worktree remove`). */
export function isLinkedWorktreeGitDir(gitDir: string): boolean {
  const normalized = gitDir.replace(/\\/g, '/');
  return /\.git\/worktrees\//i.test(normalized);
}
