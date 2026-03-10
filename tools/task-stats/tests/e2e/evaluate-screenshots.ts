#!/usr/bin/env bun

import { configDotenv } from 'dotenv';
import { readdirSync, readFileSync, existsSync } from 'fs';
import { join, resolve } from 'path';

const API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const repoRoot = resolve(import.meta.dirname, '..', '..', '..', '..');
const artifactsDir = resolve(process.argv[2] ?? join(import.meta.dirname, 'artifacts'));

configDotenv({ path: join(repoRoot, '.env'), quiet: true });
const DEFAULT_MODEL = process.env.TASK_STATS_VISION_MODEL || 'google/gemini-2.5-flash-lite';

const apiKey = process.env.OPENROUTER_API_KEY;
if (!apiKey) {
  console.error('\n  ERROR: OPENROUTER_API_KEY is not set.');
  console.error('  Add it to .env in the repo root.\n');
  process.exit(1);
}

if (!existsSync(artifactsDir)) {
  console.error(`\n  ERROR: Artifacts directory not found: ${artifactsDir}\n`);
  process.exit(1);
}

const manifestPaths = readdirSync(artifactsDir)
  .filter((name) => name.endsWith('.json'))
  .map((name) => join(artifactsDir, name));

if (manifestPaths.length === 0) {
  console.error(`\n  ERROR: No manifest files found in ${artifactsDir}\n`);
  process.exit(1);
}

type Manifest = {
  scenario: string;
  image: string;
  expectation: string;
};

type VisionResult = {
  passed: boolean;
  summary: string;
  checks?: Array<{ name: string; passed: boolean; notes: string }>;
};

function stripCodeFence(text: string): string {
  return text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
}

async function evaluateManifest(manifest: Manifest): Promise<VisionResult> {
  const imagePath = resolve(manifest.image);
  const imageData = readFileSync(imagePath).toString('base64');

  const prompt = [
    `Scenario: ${manifest.scenario}`,
    `Expectation: ${manifest.expectation}`,
    'Judge only what is visible in this screenshot.',
    'Important: "aggregate CPU" means there is a single CPU panel with one numeric percentage, not a per-core bar grid. Do not expect the literal words "aggregate CPU" to appear in the UI.',
    'Do not fail just because a value is shown as a percentage like 42% instead of longer explanatory text.',
    'Return strict JSON with this exact shape:',
    '{"passed":true,"summary":"short summary","checks":[{"name":"check name","passed":true,"notes":"short note"}]}',
    'Mark passed=false if the expected sections are missing, badly overlapped, unreadable, or clearly not the right layout.'
  ].join('\n');

  const res = await fetch(API_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://github.com/mikecann/mikerosoft',
      'X-Title': 'mikerosoft/task-stats-visual-tests',
    },
    body: JSON.stringify({
      model: DEFAULT_MODEL,
      messages: [
        {
          role: 'system',
          content: 'You are a strict but practical UI screenshot reviewer. Reply with JSON only.',
        },
        {
          role: 'user',
          content: [
            { type: 'text', text: prompt },
            { type: 'image_url', image_url: { url: `data:image/png;base64,${imageData}` } },
          ],
        },
      ],
    }),
  });

  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  }

  const data = await res.json() as any;
  const content = data?.choices?.[0]?.message?.content;
  const text = Array.isArray(content)
    ? content.map((part: any) => part?.text ?? '').join('\n')
    : String(content ?? '');

  return JSON.parse(stripCodeFence(text)) as VisionResult;
}

let failures = 0;

console.log('');
console.log(`  Evaluating task-stats screenshots with ${DEFAULT_MODEL}`);
console.log('');

for (const manifestPath of manifestPaths) {
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Manifest;
  const result = await evaluateManifest(manifest);

  if (result.passed) {
    console.log(`  PASS ${manifest.scenario}: ${result.summary}`);
  } else {
    failures++;
    console.log(`  FAIL ${manifest.scenario}: ${result.summary}`);
    for (const check of result.checks ?? []) {
      console.log(`    - ${check.name}: ${check.passed ? 'pass' : 'fail'} - ${check.notes}`);
    }
  }
}

console.log('');
if (failures > 0) {
  console.error(`  ${failures} screenshot evaluation(s) failed.\n`);
  process.exit(1);
}

console.log('  Screenshot evaluation passed.\n');
