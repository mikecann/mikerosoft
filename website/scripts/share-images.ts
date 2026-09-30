// Takes the link preview images for X, Facebook, Slack and the like: a
// screenshot of the desktop for the home page and one of each tool's window,
// saved to public/share. Run it against a running site, then commit the
// images: `npm run dev`, then `npm run share-images`, or pass a base URL.
// Tool names after the URL retake just those tools' images.

import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { SHARE_IMAGE_SIZE } from '../src/toolPages.ts';
import { tools } from '../src/tools.ts';

const base = (process.argv[2] ?? 'http://localhost:5188').replace(/\/$/, '');
const outputDir = fileURLToPath(new URL('../public/share/', import.meta.url));
// Lay the page out on a roomier screen, then shrink it to the share size, so
// the desktop looks like a desktop rather than a cramped phone.
const scale = 0.75;

const only = process.argv.slice(3);
const pages = [
  { name: 'home', path: '/' },
  ...tools.map(tool => ({ name: tool.name, path: `/tools/${tool.name}` })),
].filter(page => only.length === 0 || only.includes(page.name));

mkdirSync(outputDir, { recursive: true });
const browser = await chromium.launch();

for (const page of pages) {
  const context = await browser.newContext({
    viewport: { width: SHARE_IMAGE_SIZE.width / scale, height: SHARE_IMAGE_SIZE.height / scale },
    deviceScaleFactor: scale,
  });
  // Skip the what's-new balloon so it doesn't cover the shot.
  await context.addInitScript(() => sessionStorage.setItem('mikerosoft:updates-balloon-seen', '1'));
  const tab = await context.newPage();
  await tab.goto(`${base}${page.path}`, { waitUntil: 'networkidle' });
  await tab.evaluate('document.fonts.ready');
  // Give screenshots and videos a moment to paint.
  await tab.waitForTimeout(1500);
  await tab.screenshot({ path: `${outputDir}${page.name}.jpg`, type: 'jpeg', quality: 82 });
  await context.close();
  console.log(`Saved ${page.name}`);
}

await browser.close();
