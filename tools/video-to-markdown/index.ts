#!/usr/bin/env bun
// Convert a YouTube URL to a markdown image link and copy it to clipboard.
//
// Usage:
//   video-to-markdown                      # prompt for URL (pre-fills clipboard if YouTube URL)
//   video-to-markdown <url>                # convert URL directly
//   video-to-markdown <file.url>           # read URL from a Windows Internet Shortcut

import { input } from '@inquirer/prompts';
import { readFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';

const API_URL = 'https://quirky-squirrel-220.convex.site/api/markdown';
const SEP     = '  ' + '\u2500'.repeat(58);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readClipboardText(): string {
  try {
    if (process.platform === 'win32') {
      return execSync('powershell -NoProfile -Command "Get-Clipboard"', { encoding: 'utf8' }).trim();
    }
    if (process.platform === 'darwin') {
      return execSync('pbpaste', { encoding: 'utf8' }).trim();
    }
  } catch {
    return '';
  }
  return '';
}

function setClipboard(text: string): void {
  if (process.platform === 'win32') {
    execSync('clip', { input: text, stdio: ['pipe', 'ignore', 'ignore'] });
    return;
  }
  if (process.platform === 'darwin') {
    execSync('pbcopy', { input: text, stdio: ['pipe', 'ignore', 'ignore'] });
    return;
  }
  try {
    execSync('xclip', ['-selection', 'clipboard'], { input: text, stdio: ['pipe', 'ignore', 'ignore'] });
  } catch {
    throw new Error('Clipboard: install xclip on Linux, or copy from the terminal output.');
  }
}

async function convertUrl(url: string): Promise<{ markdown: string; title?: string }> {
  const res = await fetch(API_URL, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ url }),
  });

  if (!res.ok) {
    const text = await res.text();
    let msg = `HTTP ${res.status}`;
    try { msg = (JSON.parse(text) as any).error ?? msg; } catch {}
    throw new Error(msg);
  }

  const data = await res.json() as any;
  if (!data.markdown) throw new Error('API returned an empty markdown field.');
  return data;
}

function readUrlFile(filePath: string): string {
  const content = readFileSync(filePath, 'utf8');
  const match   = content.match(/^URL=(.+)$/m);
  if (!match) throw new Error(`No URL= line found in: ${filePath}`);
  return match[1].trim();
}

async function run(url: string): Promise<void> {
  console.log('\x1b[90m  Converting...\x1b[0m');
  const result = await convertUrl(url);
  setClipboard(result.markdown);
  const title = result.title ?? 'YouTube Video';
  console.log('');
  console.log(`  \x1b[32mCopied to clipboard!\x1b[0m  \x1b[90m${title}\x1b[0m`);
  console.log('');
  console.log(`\x1b[90m  ${result.markdown}\x1b[0m`);
  console.log('');
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

process.on('uncaughtException', (err: Error & { name?: string }) => {
  if (err.name === 'ExitPromptError') { console.log('\n  Bye.\n'); process.exit(0); }
  throw err;
});

console.log('');
console.log('\x1b[36m  VIDEO TO MARKDOWN\x1b[0m');
console.log(SEP);
console.log('');

const rawArg = (process.argv[2] ?? '').replace(/^"|"$/g, '').trim();
let url: string;

if (!rawArg) {
  // Interactive mode - pre-fill from clipboard if it already holds a YouTube URL
  let preset = '';
  const clip = readClipboardText();
  if (/youtube\.com|youtu\.be/i.test(clip)) preset = clip;

  url = (await input({
    message: 'YouTube URL',
    default: preset || undefined,
  })).trim();

  if (!url) { console.log('\n  Bye.\n'); process.exit(0); }

} else if (/^https?:\/\//i.test(rawArg)) {
  url = rawArg;

} else if (existsSync(rawArg) && rawArg.toLowerCase().endsWith('.url')) {
  url = readUrlFile(rawArg);

} else {
  console.error(`  \x1b[31mERROR: Not a valid URL or .url file: ${rawArg}\x1b[0m\n`);
  process.exit(1);
}

if (!/youtube\.com|youtu\.be/i.test(url)) {
  console.error('  \x1b[31mERROR: Not a YouTube URL.\x1b[0m\n');
  process.exit(1);
}

try {
  await run(url);
} catch (err) {
  console.error(`  \x1b[31mERROR: ${err}\x1b[0m\n`);
  process.exit(1);
}
