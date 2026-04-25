import { afterEach, describe, expect, it } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { listDirtyWorktrees } from './dirty-worktrees';

const tempDirs: string[] = [];

function runGit({ cwd, args }: { cwd: string; args: string[] }): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Test User',
      GIT_AUTHOR_EMAIL: 'test@example.com',
      GIT_COMMITTER_NAME: 'Test User',
      GIT_COMMITTER_EMAIL: 'test@example.com',
    },
  });
}

function createRepoWithWorktrees(): { mainPath: string; cleanPath: string; dirtyPath: string } {
  const root = mkdtempSync(join(tmpdir(), 'worktrees-it-'));
  tempDirs.push(root);

  const mainPath = join(root, 'main');
  const cleanPath = join(root, 'wt-clean');
  const dirtyPath = join(root, 'wt-dirty');

  runGit({ cwd: root, args: ['init', '--initial-branch=main', mainPath] });
  writeFileSync(join(mainPath, 'tracked.txt'), 'baseline\n');
  runGit({ cwd: mainPath, args: ['add', '.'] });
  runGit({ cwd: mainPath, args: ['commit', '-m', 'initial'] });

  runGit({ cwd: mainPath, args: ['branch', 'clean'] });
  runGit({ cwd: mainPath, args: ['branch', 'dirty'] });
  runGit({ cwd: mainPath, args: ['worktree', 'add', cleanPath, 'clean'] });
  runGit({ cwd: mainPath, args: ['worktree', 'add', dirtyPath, 'dirty'] });

  return { mainPath, cleanPath, dirtyPath };
}

afterEach(() => {
  for (const tempDir of tempDirs.splice(0, tempDirs.length)) rmSync(tempDir, { force: true, recursive: true });
});

describe('listDirtyWorktrees integration', () => {
  it('returns only dirty linked worktrees', () => {
    const { cleanPath, dirtyPath } = createRepoWithWorktrees();

    writeFileSync(join(dirtyPath, 'tracked.txt'), 'updated\n');
    writeFileSync(join(dirtyPath, 'new-untracked.txt'), 'new file\n');

    const dirty = listDirtyWorktrees({ paths: [cleanPath, dirtyPath] });
    expect(dirty).toHaveLength(1);
    expect(dirty[0]?.path).toBe(dirtyPath);
    expect(dirty[0]?.changes.some((line) => line.endsWith('tracked.txt'))).toBe(true);
    expect(dirty[0]?.changes.some((line) => line.endsWith('new-untracked.txt'))).toBe(true);
  });

  it('returns untracked files when status config hides them', () => {
    const { cleanPath, dirtyPath, mainPath } = createRepoWithWorktrees();

    runGit({ cwd: mainPath, args: ['config', 'status.showUntrackedFiles', 'no'] });
    writeFileSync(join(dirtyPath, 'new-untracked.txt'), 'new file\n');

    const dirty = listDirtyWorktrees({ paths: [cleanPath, dirtyPath] });
    expect(dirty).toHaveLength(1);
    expect(dirty[0]?.path).toBe(dirtyPath);
    expect(dirty[0]?.changes.some((line) => line.endsWith('new-untracked.txt'))).toBe(true);
  });

  it('returns an empty list when every worktree is clean', () => {
    const { cleanPath, dirtyPath } = createRepoWithWorktrees();
    const dirty = listDirtyWorktrees({ paths: [cleanPath, dirtyPath] });
    expect(dirty).toEqual([]);
  });
});
