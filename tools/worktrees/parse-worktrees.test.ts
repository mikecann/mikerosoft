import { describe, expect, it } from 'bun:test';
import { isLinkedWorktreeGitDir, parseWorktreePorcelain } from './parse-worktrees';

describe('parseWorktreePorcelain', () => {
  it('parses multiple records', () => {
    const sample = `
worktree /repo/main
HEAD abcdef
branch refs/heads/main

worktree /repo/wt1
HEAD abcdef
branch refs/heads/feature

`.trim();

    const rows = parseWorktreePorcelain(sample);
    expect(rows).toEqual([
      { path: '/repo/main', head: 'abcdef', branch: 'refs/heads/main' },
      { path: '/repo/wt1', head: 'abcdef', branch: 'refs/heads/feature' },
    ]);
  });

  it('handles detached', () => {
    const sample = `
worktree /repo/detached
HEAD deadbeef
detached
`.trim();

    expect(parseWorktreePorcelain(sample)).toEqual([
      { path: '/repo/detached', head: 'deadbeef', branch: null },
    ]);
  });
});

describe('isLinkedWorktreeGitDir', () => {
  it('detects linked layout on posix paths', () => {
    expect(isLinkedWorktreeGitDir('/Users/me/proj/.git/worktrees/foo')).toBe(true);
  });

  it('detects linked layout on Windows paths', () => {
    expect(isLinkedWorktreeGitDir(String.raw`C:\dev\repo\.git\worktrees\3qwv`)).toBe(true);
  });

  it('returns false for primary .git dir', () => {
    expect(isLinkedWorktreeGitDir('/Users/me/proj/.git')).toBe(false);
  });
});
