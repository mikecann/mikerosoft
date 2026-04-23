#!/usr/bin/env bun
// Interactive CLI chat tool for brainstorming YouTube video titles.
//
// Usage:
//   video-titles <video_file>

import { confirm, input } from '@inquirer/prompts';
import { readFileSync, appendFileSync, existsSync } from 'fs';
import { join, dirname, basename, extname, resolve } from 'path';
import { execSync } from 'child_process';
import { configDotenv } from 'dotenv';
import { runTranscribeForVideo } from '../lib/run-transcribe';

const MODEL   = 'google/gemini-3.1-pro-preview';
const API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const SEP     = '  ' + '\u2500'.repeat(58);
const LOG_SEP = '------------------------------------------------------------';

const SYSTEM_PROMPT = `You are an expert YouTube title ideation assistant for developer-focused content.
Use the framework below to generate and refine titles through conversation.

### The Compelling Title Matrix

A great title usually combines two or more of these four pillars: The Hook, The Conflict, The Quantitative Payoff, and The Authority.

#### 1. The "Open Loop" Hook (Curiosity Gap)
- Pattern: [Action] until [Unforeseen Consequence] or [Subject] is [Strong Opinion]
- Examples:
  - I liked this backend until I ran React Doctor
  - Claude Code has a big problem
  - Why did the world's biggest IDE disappear?

#### 2. The "Death & Survival" Conflict
- Pattern: [Technology] is DEAD or [New Tech] just KILLED [Old Tech]
- Examples:
  - Stack Overflow is Dead
  - OpenAI just dropped their Cursor killer
  - The end of the GPU era

#### 3. The Quantitative Payoff (10x Efficiency)
- Pattern: [Action] is [Number]x easier or Build [Complex Thing] in [Short Time]
- Examples:
  - Convex just made dev onboarding 10x easier
  - Build Your Own Vibe Coding Platform in 5 Minutes
  - GLM-5 is unbelievable (Opus for 20% the cost?)

#### 4. The Authority / "Top 1%" Frame
- Pattern: The Top 1% of [Role] are using [X] or The ONLY [X] you'll ever need
- Examples:
  - The Top 1% of Devs Are Using These 5 Agent Skills
  - This Is The Only Claude Code Plugin You'll EVER Need
  - 99% of Developers Are STILL Coding Wrong in 2026

### Framework: The 3-Step Title Builder
1. Identify the Antagonist - what is the problem?
2. Add a Power Word - Unbelievable, Finally, Only, Dead, Toxic, Dangerous, Game-changing.
3. Create the Gap - explain the result or feeling, not the full mechanism.

Output rules (strictly enforced):
- Output ONLY the numbered list of titles. Nothing else. No preamble, no commentary, no sign-off.
- Format: 1. Title Here
- Plain text only. No markdown, no asterisks, no hashes, no bold, no italics, no bullet points.
- If the user asks a clarifying question or gives feedback, respond in one short plain-text sentence then immediately output the new list.
- Keep each title concise and punchy - one line each.`;

// ---------------------------------------------------------------------------
// Load .env from repo root (two levels up: video-titles -> tools -> repo)
// ---------------------------------------------------------------------------

configDotenv({ path: join(dirname(dirname(import.meta.dirname)), '.env') });

const apiKey = process.env.OPENROUTER_API_KEY;
if (!apiKey) {
  console.error('\n  ERROR: OPENROUTER_API_KEY is not set.');
  console.error('  Copy .env.example to .env in the repo root and set the key.\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Resolve video path
// ---------------------------------------------------------------------------

const rawArg = (process.argv[2] ?? '').replace(/^"|"$/g, '');
if (!rawArg || !existsSync(rawArg)) {
  console.error(`\n  ERROR: File not found: ${rawArg || '(no path given)'}\n`);
  process.exit(1);
}

const videoPath = resolve(rawArg);
const videoDir  = dirname(videoPath);
const videoName = basename(videoPath, extname(videoPath));
const srtPath   = join(videoDir, `${videoName}.srt`);
const logPath   = join(videoDir, `${videoName}-titles.txt`);

// ---------------------------------------------------------------------------
// SRT parsing - strip sequence numbers and timestamps, return plain text
// ---------------------------------------------------------------------------

function parseSrt(content: string): string {
  return content
    .replace(/\r\n/g, '\n')
    .split('\n')
    .filter(line => {
      const t = line.trim();
      return t && !/^\d+$/.test(t) && !/\d{2}:\d{2}:\d{2},\d{3}/.test(t);
    })
    .map(l => l.trim())
    .join('\n');
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

process.on('uncaughtException', (err: Error & { name?: string }) => {
  if (err.name === 'ExitPromptError') { console.log('\n  Bye.\n'); process.exit(0); }
  throw err;
});

console.clear();
console.log('');
console.log('\x1b[36m  VIDEO TITLES\x1b[0m');
console.log(SEP);
console.log(`  Video : ${videoName}`);
console.log(`\x1b[90m  Log   : ${logPath}\x1b[0m`);

// ---------------------------------------------------------------------------
// SRT detection
// ---------------------------------------------------------------------------

let transcript = '';

if (existsSync(srtPath)) {
  transcript = parseSrt(readFileSync(srtPath, 'utf-8'));
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  console.log(`\x1b[32m  SRT   : ${basename(srtPath)} (${wordCount} words loaded)\x1b[0m`);
} else {
  console.log('\x1b[33m  SRT   : not found\x1b[0m');
  console.log('');

  const runTranscribe = await confirm({
    message: 'Run transcribe to generate a transcript?',
    default: false,
  });

  if (runTranscribe) {
    console.log('');
    console.log(SEP);
    console.log('');
    runTranscribeForVideo(videoPath);
    console.log('');
    console.log(SEP);

    if (existsSync(srtPath)) {
      transcript = parseSrt(readFileSync(srtPath, 'utf-8'));
      const wordCount = transcript.split(/\s+/).filter(Boolean).length;
      console.log(`\x1b[32m  SRT   : loaded (${wordCount} words)\x1b[0m`);
    } else {
      console.log('\x1b[33m  SRT   : not found after transcribe - continuing without.\x1b[0m');
    }
  } else {
    console.log('\x1b[90m  SRT   : skipped - paste context directly in chat.\x1b[0m');
  }
}

console.log(SEP);
console.log('\x1b[90m  Type your message and press Enter. Ctrl+C to exit.\x1b[0m');
console.log(SEP);
console.log('');

// ---------------------------------------------------------------------------
// Chat history
// ---------------------------------------------------------------------------

type Message = { role: 'user' | 'assistant' | 'system'; content: string };

const history: Message[] = [];

function importChatLog(path: string): Message[] {
  if (!existsSync(path)) return [];
  const blocks = readFileSync(path, 'utf-8').split(LOG_SEP);
  const result: Message[] = [];
  for (const block of blocks) {
    const userMatch      = block.match(/^You: (.+)$/m);
    const assistantMatch = block.match(/Gemini:\n([\s\S]+)/);
    if (userMatch && assistantMatch) {
      result.push({ role: 'user',      content: userMatch[1].trim()      });
      result.push({ role: 'assistant', content: assistantMatch[1].trim() });
    }
  }
  return result;
}

function appendToLog(userInput: string, reply: string): void {
  const ts    = new Date().toISOString().replace('T', ' ').slice(0, 19);
  const entry = `\n[${ts}]\nYou: ${userInput}\n\nGemini:\n${reply}\n\n${LOG_SEP}\n`;
  appendFileSync(logPath, entry, 'utf-8');
}

// ---------------------------------------------------------------------------
// API call
// ---------------------------------------------------------------------------

async function sendMessage(userInput: string): Promise<void> {
  const messages: Message[] = [{ role: 'system', content: SYSTEM_PROMPT }];

  if (transcript) {
    messages.push({
      role:    'user',
      content: `Use this transcript as context for the full conversation:\n\n${transcript}`,
    });
  }

  for (const m of history) messages.push(m);
  messages.push({ role: 'user', content: userInput });

  console.log('');
  console.log('\x1b[90m  Thinking...\x1b[0m');

  try {
    const res = await fetch(API_URL, {
      method:  'POST',
      headers: {
        Authorization:  `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/mikecann/mikerosoft',
        'X-Title':      'mikerosoft/video-titles',
      },
      body: JSON.stringify({ model: MODEL, messages, temperature: 0.8, max_tokens: 8000 }),
    });

    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);

    const data  = await res.json() as any;
    const reply = data.choices[0].message.content as string;

    history.push({ role: 'user',      content: userInput });
    history.push({ role: 'assistant', content: reply     });

    console.log('');
    console.log('\x1b[32m  Gemini:\x1b[0m');
    console.log('');
    for (const line of reply.split('\n')) console.log(`  ${line}`);
    console.log('');
    console.log(SEP);
    console.log('');

    appendToLog(userInput, reply);

  } catch (err) {
    console.error(`\n  \x1b[31mERROR: ${err}\x1b[0m\n`);
  }
}

// ---------------------------------------------------------------------------
// Load previous session or auto-fire opener
// ---------------------------------------------------------------------------

const loaded = importChatLog(logPath);

if (loaded.length > 0) {
  for (const m of loaded) history.push(m);

  const exchangeCount = loaded.length / 2;
  console.log(`\x1b[90m  Resumed: ${exchangeCount} previous exchange(s) loaded.\x1b[0m`);
  console.log('');

  const lastUser      = loaded[loaded.length - 2].content;
  const lastAssistant = loaded[loaded.length - 1].content;
  console.log(`\x1b[36m  You: ${lastUser}\x1b[0m`);
  console.log('');
  console.log('\x1b[32m  Gemini:\x1b[0m');
  console.log('');
  for (const line of lastAssistant.split('\n')) console.log(`  ${line}`);
  console.log('');
  console.log(SEP);
  console.log('');
} else {
  console.log('\x1b[36m  You: \x1b[90mPlease give me 10 options\x1b[0m');
  await sendMessage('Please give me 10 options');
}

// ---------------------------------------------------------------------------
// Chat loop
// ---------------------------------------------------------------------------

while (true) {
  let userInput: string;
  try {
    userInput = await input({ message: 'You' });
  } catch {
    console.log('\n  Bye.\n');
    break;
  }

  const trimmed = userInput.trim();
  if (!trimmed) continue;

  if (['quit', 'exit', 'q', ':q'].includes(trimmed.toLowerCase())) {
    console.log('\n  Bye.\n');
    break;
  }

  await sendMessage(trimmed);
}
