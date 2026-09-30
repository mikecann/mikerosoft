// Writes dist/tools/<name>.html after `vite build`, one per tool, each with
// that tool's title, description and share image. Cloudflare serves
// /tools/<name> from it, so shared links preview the right tool. Renamed
// tools also get a page at their old name that previews the tool and sends
// the browser on to its new address.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { toolDetails } from '../src/toolDetails.ts';
import { shareImageFor, withRedirect, withToolMeta } from '../src/toolPages.ts';
import { RENAMED_TOOLS, tools, type Tool } from '../src/tools.ts';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const html = readFileSync(`${dist}index.html`, 'utf8');

function metaFor(tool: Tool) {
  const description = toolDetails[tool.name]?.tagline ?? tool.desc;
  const image = shareImageFor(tool, existsSync(`${dist}share/${tool.name}.jpg`));
  return { description, image };
}

mkdirSync(`${dist}tools`, { recursive: true });
for (const tool of tools) {
  const { description, image } = metaFor(tool);
  writeFileSync(`${dist}tools/${tool.name}.html`, withToolMeta(html, tool, description, image));
}

for (const [oldName, newName] of Object.entries(RENAMED_TOOLS)) {
  const tool = tools.find(candidate => candidate.name === newName);
  if (!tool) throw new Error(`${oldName} was renamed to ${newName}, which isn't in tools.ts`);
  const { description, image } = metaFor(tool);
  writeFileSync(`${dist}tools/${oldName}.html`, withRedirect(html, tool, description, image));
}

console.log(`Wrote ${tools.length} tool pages and ${Object.keys(RENAMED_TOOLS).length} redirects`);
