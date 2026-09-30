// Writes public/changelog/<tool>.json, each tool's changes and why, from the
// history of each tool's own repo. Runs before `npm run dev` and
// `npm run build`. The tool page fetches its file, so the changelogs don't
// bloat the main bundle.

import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { changelogFromGitLog } from '../src/changelog.ts';
import { formerNames } from '../src/tools.ts';
import { repoLog, syncToolRepos } from './toolRepos.ts';

const outputDir = fileURLToPath(new URL('../public/changelog/', import.meta.url));

const repos = await syncToolRepos();
rmSync(outputDir, { recursive: true, force: true });
mkdirSync(outputDir, { recursive: true });
for (const { tool, dir } of repos) {
  const changelog = changelogFromGitLog(await repoLog(dir), tool.name, ...formerNames(tool.name));
  writeFileSync(`${outputDir}${tool.name}.json`, JSON.stringify(changelog));
}

console.log(`Wrote changelogs for ${repos.length} tools.`);
