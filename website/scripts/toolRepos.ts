// Every tool lives in its own repo at github.com/mikecann/<name>. The dates
// and changelog on the site come from those repos' histories, so the build
// keeps a blob-less mirror of each one in website/.repo-cache (git-ignored):
// full commit history and file lists, without the file contents.

import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { LOG_FORMAT } from '../src/gitHistory.ts';
import { tools, type Tool } from '../src/tools.ts';

const run = promisify(execFile);
const cacheDir = fileURLToPath(new URL('../.repo-cache/', import.meta.url));
// `npm run dev` runs the dates and then the changelog, so the second one can
// skip fetching what the first just fetched.
const FRESH_MS = 10 * 60 * 1000;
const PARALLEL = 8;

export interface ToolRepo {
  tool: Tool;
  dir: string;
}

function git(...args: string[]) {
  return run('git', ['-c', 'core.quotePath=false', ...args], { maxBuffer: 256 * 1024 * 1024 });
}

async function sync(tool: Tool): Promise<ToolRepo> {
  const dir = `${cacheDir}${tool.name}.git`;
  const url = `${tool.url}.git`;
  const synced = `${dir}/mikerosoft-synced`;

  if (!existsSync(dir)) {
    await git('clone', '--mirror', '--filter=blob:none', '--quiet', url, dir);
  } else if (existsSync(synced) && Date.now() - statSync(synced).mtimeMs < FRESH_MS) {
    return { tool, dir };
  } else {
    try {
      await git('-C', dir, 'remote', 'set-url', 'origin', url);
      await git('-C', dir, 'fetch', '--prune', '--quiet', 'origin');
    } catch (error) {
      // Offline, most likely. The last copy is better than no dates at all.
      console.warn(`Couldn't fetch ${url}, using the cached copy: ${(error as Error).message.trim()}`);
      return { tool, dir };
    }
  }
  writeFileSync(synced, new Date().toISOString());
  return { tool, dir };
}

/** Clones or updates every tool's repo, a few at a time. */
export async function syncToolRepos(): Promise<ToolRepo[]> {
  mkdirSync(cacheDir, { recursive: true });
  const repos: ToolRepo[] = [];
  const queue = [...tools];
  async function worker() {
    for (let tool = queue.shift(); tool; tool = queue.shift()) repos.push(await sync(tool));
  }
  await Promise.all(Array.from({ length: PARALLEL }, worker));
  return tools.map(tool => repos.find(repo => repo.tool === tool)!);
}

/** The repo's history in the shape parseGitLog reads. */
export async function repoLog(dir: string): Promise<string> {
  const { stdout } = await git(
    '-C',
    dir,
    'log',
    '--no-merges',
    '--no-renames',
    '--name-only',
    `--format=${LOG_FORMAT}`,
    'HEAD',
  );
  return stdout;
}
