#!/usr/bin/env bun
// Interactive git worktree manager (macOS + Windows).
//
// Usage:
//   worktrees              # run from any directory inside the repo
//   worktrees --force      # pass --force to git worktree remove

import { checkbox, confirm, select } from '@inquirer/prompts';
import { execFileSync } from 'node:child_process';

import { listDirtyWorktrees } from './dirty-worktrees';
import { isLinkedWorktreeGitDir, parseWorktreePorcelain } from './parse-worktrees';

function exhaustiveCheck(param: never): never {
  throw new Error(`Exhaustive check failed: ${String(param)}`);
}

function readArgForce(argv: string[]): boolean {
  return argv.includes('--force') || argv.includes('-f');
}

function gitTopLevel(cwd: string): string {
  return execFileSync('git', ['rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    cwd,
  }).trim();
}

function gitWorktreePorcelain(cwd: string): string {
  return execFileSync('git', ['worktree', 'list', '--porcelain'], {
    encoding: 'utf8',
    cwd,
  });
}

function gitCommonDir(cwd: string): string {
  return execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], {
    encoding: 'utf8',
    cwd,
  }).trim();
}

function gitDirForWorktree(worktreePath: string): string {
  return execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-dir'], {
    encoding: 'utf8',
    cwd: worktreePath,
  }).trim();
}

function formatBranch(branch: string | null): string {
  if (!branch) return 'detached';
  if (branch.startsWith('refs/heads/')) return branch.slice('refs/heads/'.length);
  return branch;
}

function removeWorktrees(paths: string[], cwd: string, force: boolean): void {
  for (const path of paths) {
    const args = ['worktree', 'remove', path];
    if (force) args.push('--force');
    execFileSync('git', args, { stdio: 'inherit', cwd });
  }
}

type Action = 'selected' | 'all' | 'exit';

async function main(): Promise<void> {
  const force = readArgForce(process.argv.slice(2));
  const cwd = process.cwd();

  let topLevel: string;
  try {
    topLevel = gitTopLevel(cwd);
  } catch {
    console.error('Not a git repository (run this from inside a checkout).');
    process.exitCode = 1;
    return;
  }

  const commonDir = gitCommonDir(topLevel);
  const parsed = parseWorktreePorcelain(gitWorktreePorcelain(topLevel));

  const rows = parsed.map((row) => {
    const gitDir = gitDirForWorktree(row.path);
    return {
      ...row,
      gitDir,
      isLinked: isLinkedWorktreeGitDir(gitDir),
    };
  });

  console.log(`Common git dir: ${commonDir}`);
  console.log(`Current checkout: ${topLevel}\n`);
  console.log('Worktrees:');
  for (const row of rows) {
    const label = row.isLinked ? 'linked' : 'primary';
    console.log(`  [${label}] ${row.path}`);
    console.log(`          ${formatBranch(row.branch)}`);
  }
  console.log('');

  const linked = rows.filter((r) => r.isLinked);
  if (linked.length === 0) {
    console.log('No linked worktrees to remove.');
    return;
  }

  const action = await select<Action>({
    message: 'What do you want to do?',
    choices: [
      { name: 'Remove selected linked worktrees', value: 'selected' },
      { name: `Remove all linked worktrees (${linked.length})`, value: 'all' },
      { name: 'Exit', value: 'exit' },
    ],
  });

  if (action === 'exit') return;

  let targets: string[] = [];
  if (action === 'all') targets = linked.map((r) => r.path);
  else if (action === 'selected') {
    const picked = await checkbox({
      message: 'Choose worktrees to remove',
      choices: linked.map((r) => ({
        name: `${r.path} (${formatBranch(r.branch)})`,
        value: r.path,
      })),
      required: true,
    });
    targets = picked;
  } else exhaustiveCheck(action);

  if (targets.length === 0) {
    console.log('Nothing selected.');
    return;
  }

  const dirtyWorktrees = listDirtyWorktrees({ paths: targets });
  if (dirtyWorktrees.length > 0) {
    console.log('These worktrees have local changes that would be deleted:');
    for (const worktree of dirtyWorktrees) {
      console.log(`\n${worktree.path}`);
      for (const change of worktree.changes) console.log(`  ${change}`);
    }
    console.log('');

    const acceptDirtyDelete = await confirm({
      message: `Delete the changes shown above and force-remove ${dirtyWorktrees.length} dirty worktree(s)?`,
      default: false,
    });

    if (!acceptDirtyDelete) {
      console.log('Cancelled.');
      return;
    }
  }

  const shouldForce = force || dirtyWorktrees.length > 0;
  const forceNote = shouldForce ? 'with --force' : 'without --force';
  const ok = await confirm({
    message: `Remove ${targets.length} worktree(s) ${forceNote}?\n${targets.join('\n')}`,
    default: false,
  });

  if (!ok) {
    console.log('Cancelled.');
    return;
  }

  removeWorktrees(targets, topLevel, shouldForce);
  console.log('Done.');
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
