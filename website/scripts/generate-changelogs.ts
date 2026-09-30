// Writes public/changelog/<tool>.json, each tool's changes and why, from git
// history. Runs before `npm run dev` and `npm run build`. The tool page
// fetches its file, so the changelogs don't bloat the main bundle.

import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { changelogsFromGitLog, LOG_FORMAT } from '../src/changelog.ts';
import { tools } from '../src/tools.ts';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const outputDir = fileURLToPath(new URL('../public/changelog/', import.meta.url));

const log = execFileSync(
  'git',
  ['-C', repoRoot, '-c', 'core.quotePath=false', 'log', '--no-merges', '--name-only', `--format=${LOG_FORMAT}`, '--', 'tools'],
  { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 },
);
const changelogs = changelogsFromGitLog(log);

rmSync(outputDir, { recursive: true, force: true });
mkdirSync(outputDir, { recursive: true });
for (const tool of tools) {
  writeFileSync(`${outputDir}${tool.name}.json`, JSON.stringify(changelogs[tool.name] ?? []));
}

console.log(`Wrote changelogs for ${tools.length} tools.`);
