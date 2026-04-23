#!/usr/bin/env bun
// Interactive CLI chat tool for generating YouTube video descriptions.
//
// Usage:
//   video-description <video_file>
//   video-description <folder>   (picks a video from the folder)

import { select, confirm, input } from '@inquirer/prompts';
import { readFileSync, appendFileSync, existsSync, readdirSync } from 'fs';
import { join, dirname, basename, extname, resolve } from 'path';
import { execSync, spawnSync } from 'child_process';
import { configDotenv } from 'dotenv';
import { statSync } from 'fs';
import { runTranscribeForVideo } from '../lib/run-transcribe';

const MODEL   = 'google/gemini-3.1-pro-preview';
const API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const SEP     = '  ' + '\u2500'.repeat(58);
const LOG_SEP = '------------------------------------------------------------';

const VIDEO_EXTS = new Set([
  '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm',
  '.m4v', '.mpg', '.mpeg', '.ts', '.mts', '.m2ts', '.flv', '.f4v',
]);

function copyReplyToClipboard(reply: string): boolean {
  if (process.platform === 'win32') {
    return spawnSync('clip', [], { input: reply, encoding: 'utf8' }).status === 0;
  }
  if (process.platform === 'darwin') {
    return spawnSync('pbcopy', [], { input: reply, encoding: 'utf8' }).status === 0;
  }
  return spawnSync('xclip', ['-selection', 'clipboard'], { input: reply, encoding: 'utf8' }).status === 0;
}

const SYSTEM_PROMPT = `You help creators turn a video transcript with timestamps into a polished, third-person YouTube description optimized for SEO from a software developer's perspective.

You will produce, in this exact order:
1) A short, keyword-rich, third-person description written for developers, summarizing what the video covers, the tech stack, problems solved, notable patterns, and who it's for. Use clear, concise language and avoid emojis.
2) A clean timestamp list using the user's timecodes with just the section titles (no emojis). If titles are missing, infer concise titles from the transcript. Keep one line per timestamp, format as "[HH:MM:SS] Title" or "[MM:SS] Title" exactly as provided.
3) A "Resources" section containing any links provided by the user. Show full URLs with human-readable labels when provided; if not provided, note "No links provided - add relevant repo, doc, and blog URLs here." Do not invent links.
4) A horizontal list of relevant hashtags (no line breaks), 8-15 max, focused on the video's stack, tools, and topic (e.g., #javascript #react #devops). No emojis.
5) Three alternative, catchy yet informative video titles tailored for developers, each under ~70 characters, avoiding clickbait and emojis. Make them distinct in angle (performance, DX, architecture, etc.).

Style and behavior:
- Write in third person from a software developer vantage point. Prioritize technical clarity, practical outcomes, and search intent (e.g., how-to, performance, setup, pitfalls). Include important keywords naturally (frameworks, libraries, versions, concepts). Avoid hype and fluff.
- Preserve technical accuracy and avoid overclaiming. If the transcript suggests uncertainty, reflect it honestly.
- Keep paragraphs short (2-3 sentences). Prefer scannable structure and strong nouns/verbs.
- Never include emojis. Avoid excessive punctuation. American English by default unless asked otherwise.
- If the user provides code blocks in the transcript, keep formatting minimal in the description; do not paste long code.
- Output order and formatting must be consistent: Description, Timestamps, Resources, Hashtags, Titles.
- Output ONLY the five sections above. No preamble, no sign-off, no meta-commentary.
- Plain text only. No markdown, no asterisks, no hashes, no bold, no italics.
- If the user asks for a revision or gives feedback, make the requested changes and output the full updated description again.

When the user provides additional context (links, corrections, tone preference), incorporate it immediately.

Personality: professional, direct, and developer-savvy. Keeps things crisp and useful for busy engineers.`;

// ---------------------------------------------------------------------------
// Load .env from repo root (two levels up: video-description -> tools -> repo)
// ---------------------------------------------------------------------------

configDotenv({ path: join(dirname(dirname(import.meta.dirname)), '.env') });

const apiKey = process.env.OPENROUTER_API_KEY;
if (!apiKey) {
  console.error('\n  ERROR: OPENROUTER_API_KEY is not set.');
  console.error('  Copy .env.example to .env in the repo root and set the key.\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Resolve video path - supports a direct file or a folder
// ---------------------------------------------------------------------------

process.on('uncaughtException', (err: Error & { name?: string }) => {
  if (err.name === 'ExitPromptError') { console.log('\n  Bye.\n'); process.exit(0); }
  throw err;
});

const rawArg = (process.argv[2] ?? '').replace(/^"|"$/g, '');
if (!rawArg || !existsSync(rawArg)) {
  console.error(`\n  ERROR: Path not found: ${rawArg || '(no path given)'}\n`);
  process.exit(1);
}

const resolvedArg = resolve(rawArg);
let videoPath: string;

if (statSync(resolvedArg).isDirectory()) {
  const dir = resolvedArg;
  const videos = readdirSync(dir).filter(f => VIDEO_EXTS.has(extname(f).toLowerCase()));

  if (videos.length === 0) {
    console.error(`\n  ERROR: No video files found in: ${dir}\n`);
    process.exit(1);
  }

  if (videos.length === 1) {
    videoPath = join(dir, videos[0]!);
  } else {
    console.log('');
    console.log('\x1b[36m  VIDEO DESCRIPTION\x1b[0m');
    console.log(SEP);
    videoPath = join(dir, await select({
      message: 'Multiple videos found - pick one',
      choices: videos.map(v => ({ name: v, value: v })),
    }));
  }
} else {
  videoPath = resolvedArg;
}

const videoDir  = dirname(videoPath);
const videoName = basename(videoPath, extname(videoPath));
const srtPath   = join(videoDir, `${videoName}.srt`);
const logPath   = join(videoDir, `${videoName}-description.txt`);

// ---------------------------------------------------------------------------
// SRT parsing - keep timestamps so the AI can build the timestamp section
// ---------------------------------------------------------------------------

function parseSrtWithTimestamps(content: string): string {
  const lines  = content.replace(/\r\n/g, '\n').split('\n');
  const output: string[] = [];
  let   i      = 0;

  while (i < lines.length) {
    const line = lines[i]!.trim();

    // Skip sequence numbers (bare integers)
    if (/^\d+$/.test(line)) { i++; continue; }

    // Timestamp line: convert "HH:MM:SS,mmm --> HH:MM:SS,mmm" to "[HH:MM:SS]"
    const tsMatch = line.match(/^(\d{2}:\d{2}:\d{2}),\d{3}\s*-->/);
    if (tsMatch) {
      const ts = tsMatch[1];
      i++;
      // Collect text lines that follow this timestamp
      const textParts: string[] = [];
      while (i < lines.length && lines[i]!.trim() !== '') {
        textParts.push(lines[i]!.trim());
        i++;
      }
      if (textParts.length) output.push(`[${ts}] ${textParts.join(' ')}`);
      continue;
    }

    i++;
  }

  return output.join('\n');
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

console.clear();
console.log('');
console.log('\x1b[36m  VIDEO DESCRIPTION\x1b[0m');
console.log(SEP);
console.log(`  Video : ${videoName}`);
console.log(`\x1b[90m  Log   : ${logPath}\x1b[0m`);

// ---------------------------------------------------------------------------
// SRT detection
// ---------------------------------------------------------------------------

let transcript = '';

if (existsSync(srtPath)) {
  transcript = parseSrtWithTimestamps(readFileSync(srtPath, 'utf-8'));
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
      transcript = parseSrtWithTimestamps(readFileSync(srtPath, 'utf-8'));
      const wordCount = transcript.split(/\s+/).filter(Boolean).length;
      console.log(`\x1b[32m  SRT   : loaded (${wordCount} words)\x1b[0m`);
    } else {
      console.log('\x1b[33m  SRT   : not found after transcribe - continuing without.\x1b[0m');
    }
  } else {
    console.log('\x1b[90m  SRT   : skipped - paste transcript directly in chat.\x1b[0m');
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
      result.push({ role: 'user',      content: userMatch[1]!.trim()      });
      result.push({ role: 'assistant', content: assistantMatch[1]!.trim() });
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
      content: `Here is the transcript with timestamps. Use it as context for the whole conversation:\n\n${transcript}`,
    });
    messages.push({
      role:    'assistant',
      content: 'Got it - transcript loaded. Ready to generate the description.',
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
        'X-Title':      'mikerosoft/video-description',
      },
      body: JSON.stringify({ model: MODEL, messages, temperature: 0.7, max_tokens: 8000 }),
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

    if (copyReplyToClipboard(reply)) {
      console.log('\x1b[90m  Copied to clipboard.\x1b[0m');
    } else {
      console.log('\x1b[33m  Could not copy to clipboard.\x1b[0m');
    }
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

  const lastUser      = loaded[loaded.length - 2]!.content;
  const lastAssistant = loaded[loaded.length - 1]!.content;
  console.log(`\x1b[36m  You: ${lastUser}\x1b[0m`);
  console.log('');
  console.log('\x1b[32m  Gemini:\x1b[0m');
  console.log('');
  for (const line of lastAssistant.split('\n')) console.log(`  ${line}`);
  console.log('');
  console.log(SEP);
  console.log('');
} else {
  const opener = 'Please generate a YouTube description for this video.';
  console.log(`\x1b[36m  You: \x1b[90m${opener}\x1b[0m`);
  await sendMessage(opener);
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
