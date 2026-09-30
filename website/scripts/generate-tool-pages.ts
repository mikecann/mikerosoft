// Writes dist/tools/<name>.html after `vite build`, one per tool, each with
// that tool's title, description and share image. Cloudflare serves
// /tools/<name> from it, so shared links preview the right tool.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { toolDetails } from '../src/toolDetails.ts';
import { shareImageFor, withToolMeta } from '../src/toolPages.ts';
import { tools } from '../src/tools.ts';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const html = readFileSync(`${dist}index.html`, 'utf8');

mkdirSync(`${dist}tools`, { recursive: true });
for (const tool of tools) {
  const description = toolDetails[tool.name]?.tagline ?? tool.desc;
  const image = shareImageFor(tool, existsSync(`${dist}share/${tool.name}.jpg`));
  writeFileSync(`${dist}tools/${tool.name}.html`, withToolMeta(html, tool, description, image));
}

console.log(`Wrote ${tools.length} tool pages`);
