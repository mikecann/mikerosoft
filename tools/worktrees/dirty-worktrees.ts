import { execFileSync } from 'node:child_process';

export type DirtyWorktree = {
  path: string;
  changes: string[];
};

function gitStatusPorcelain({ worktreePath }: { worktreePath: string }): string[] {
  const status = execFileSync('git', ['status', '--short'], {
    encoding: 'utf8',
    cwd: worktreePath,
  }).trim();

  if (!status) return [];
  return status.split('\n');
}

export function listDirtyWorktrees({ paths }: { paths: string[] }): DirtyWorktree[] {
  return paths
    .map((path) => ({ path, changes: gitStatusPorcelain({ worktreePath: path }) }))
    .filter(({ changes }) => changes.length > 0);
}
