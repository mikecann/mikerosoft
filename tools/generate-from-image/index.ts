#!/usr/bin/env bun
// AI image generation CLI - right-click any image, pick your settings, describe what you want.

import { select, input } from '@inquirer/prompts';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, extname, basename, dirname, resolve } from 'path';
import { exec } from 'child_process';
import { configDotenv } from 'dotenv';

const MODEL   = 'google/gemini-3.1-flash-image-preview';
const API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const SEP     = '  ' + '\u2500'.repeat(58);

// ---------------------------------------------------------------------------
// Load .env from repo root (two levels up: generate-from-image -> tools -> repo)
// ---------------------------------------------------------------------------

configDotenv({ path: join(dirname(dirname(import.meta.dirname)), '.env') });

const apiKey = process.env.OPENROUTER_API_KEY;
if (!apiKey) {
  console.error('\n  ERROR: OPENROUTER_API_KEY is not set.');
  console.error('  Add it to .env in the repo root.\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Resolve image path from argv
// ---------------------------------------------------------------------------

const rawArg = (process.argv[2] ?? '').replace(/^"|"$/g, '');
if (!rawArg || !existsSync(rawArg)) {
  console.error(`\n  ERROR: File not found: ${rawArg || '(no path given)'}\n`);
  process.exit(1);
}

const imagePath = resolve(rawArg);
const imageDir  = dirname(imagePath);
const imageName = basename(imagePath, extname(imagePath));
const imageExt  = extname(imagePath).toLowerCase();

const mimeMap: Record<string, string> = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.png': 'image/png',  '.webp': 'image/webp',
  '.gif': 'image/gif',  '.bmp':  'image/bmp',
};
const mimeType = mimeMap[imageExt] ?? 'image/jpeg';

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

console.log('');
console.log('\x1b[36m  GENERATE FROM IMAGE\x1b[0m');
console.log(SEP);
console.log(`  Input : ${imageName}${imageExt}`);
console.log(`\x1b[90m  Dir   : ${imageDir}\x1b[0m`);
console.log(`\x1b[90m  Model : ${MODEL}\x1b[0m`);
console.log(SEP);
console.log('');

// ---------------------------------------------------------------------------
// Interactive setup via Inquirer
// ---------------------------------------------------------------------------

// Ctrl+C during setup should exit cleanly
process.on('uncaughtException', (err: Error & { name?: string }) => {
  if (err.name === 'ExitPromptError') { console.log('\n  Bye.\n'); process.exit(0); }
  throw err;
});

const variationsStr = await select({
  message: 'Variations per prompt',
  default: '1',
  choices: [
    { name: '1  (single)',           value: '1' },
    { name: '2  (two variations)',   value: '2' },
    { name: '3  (three variations)', value: '3' },
    { name: '4  (four variations)',  value: '4' },
  ],
});

const aspectRatio = await select({
  message: 'Aspect ratio',
  default: 'auto',
  choices: [
    { name: 'auto    (let the model decide)', value: 'auto' },
    { name: '1:1     (square)',               value: '1:1'  },
    { name: '16:9    (widescreen)',           value: '16:9' },
    { name: '9:16    (portrait / vertical)',  value: '9:16' },
    { name: '4:3',                            value: '4:3'  },
    { name: '3:4',                            value: '3:4'  },
    { name: '3:2',                            value: '3:2'  },
    { name: '2:3',                            value: '2:3'  },
    { name: '4:5',                            value: '4:5'  },
    { name: '5:4',                            value: '5:4'  },
    { name: '21:9    (ultra-wide)',           value: '21:9' },
  ],
});

const imageSize = await select({
  message: 'Image size',
  default: 'auto',
  choices: [
    { name: 'auto    (let the model decide)', value: 'auto' },
    { name: '1K      (standard)',             value: '1K'   },
    { name: '2K',                             value: '2K'   },
    { name: '4K      (highest resolution)',   value: '4K'   },
  ],
});

const cfg = {
  variations: parseInt(variationsStr),
  aspectRatio,
  imageSize,
};

console.log('');
console.log(SEP);
console.log('\x1b[90m  Type a prompt and press Enter.  open | folder | quit\x1b[0m');
console.log(SEP);
console.log('');

// ---------------------------------------------------------------------------
// Generation helpers
// ---------------------------------------------------------------------------

let genCount    = 0;
let lastOutPath: string | null = null;

function nextOutputPath(): string {
  genCount++;
  return join(imageDir, `${imageName}-generated-${String(genCount).padStart(3, '0')}.png`);
}

async function generateOne(prompt: string, dataUrl: string): Promise<void> {
  const imageConfig: Record<string, string> = {};
  if (cfg.aspectRatio !== 'auto') imageConfig.aspect_ratio = cfg.aspectRatio;
  if (cfg.imageSize   !== 'auto') imageConfig.image_size   = cfg.imageSize;

  const body: Record<string, unknown> = {
    model:      MODEL,
    modalities: ['image', 'text'],
    messages: [
      {
        role:    'user',
        content: [
          { type: 'image_url', image_url: { url: dataUrl } },
          { type: 'text',      text: prompt                },
        ],
      },
    ],
  };
  if (Object.keys(imageConfig).length > 0) body.image_config = imageConfig;

  const res = await fetch(API_URL, {
    method:  'POST',
    headers: {
      Authorization:  `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://github.com/mikecann/mikerosoft',
      'X-Title':      'mikerosoft/generate-from-image',
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);

  const data    = await res.json() as any;
  const message = data.choices[0].message;
  const images  = message.images as Array<{ image_url: { url: string } }> | undefined;

  if (!images?.length) {
    console.error('  \x1b[31mERROR: No image in response.\x1b[0m');
    if (message.content) console.log(`  Model said: ${message.content}`);
    return;
  }

  const b64Data = images[0].image_url.url.split(',', 2)[1];
  const outPath = nextOutputPath();
  writeFileSync(outPath, Buffer.from(b64Data, 'base64'));

  lastOutPath = outPath;
  console.log(`  \x1b[32mSaved : ${basename(outPath)}\x1b[0m`);
  if (cfg.variations === 1 && message.content?.trim()) {
    console.log(`\x1b[90m  Model : ${message.content.trim()}\x1b[0m`);
  }
}

async function generate(prompt: string): Promise<void> {
  const varLabel = cfg.variations > 1 ? ` (${cfg.variations} variations)` : '';
  console.log(`\x1b[90m  Generating${varLabel}...\x1b[0m`);
  console.log('');

  const dataUrl = `data:${mimeType};base64,${readFileSync(imagePath).toString('base64')}`;

  for (let i = 1; i <= cfg.variations; i++) {
    if (cfg.variations > 1) console.log(`\x1b[90m  Variation ${i} of ${cfg.variations}...\x1b[0m`);
    try {
      await generateOne(prompt, dataUrl);
    } catch (err) {
      console.error(`  \x1b[31mERROR (variation ${i}): ${err}\x1b[0m`);
    }
  }

  console.log('');
  console.log(SEP);
  console.log('');
}

// ---------------------------------------------------------------------------
// Prompt loop
// ---------------------------------------------------------------------------

while (true) {
  let userInput: string;
  try {
    userInput = await input({ message: 'You' });
  } catch {
    console.log('\n  Bye.\n');
    break;
  }

  const cmd = userInput.trim();
  if (!cmd) continue;

  if (['quit', 'exit', 'q', ':q'].includes(cmd.toLowerCase())) {
    console.log('\n  Bye.\n');
    break;
  }

  if (cmd.toLowerCase() === 'open') {
    if (lastOutPath && existsSync(lastOutPath)) exec(`start "" "${lastOutPath}"`);
    else console.log('  No image generated yet.\n');
    continue;
  }

  if (cmd.toLowerCase() === 'folder') {
    exec(`explorer "${imageDir}"`);
    continue;
  }

  await generate(cmd);
}
