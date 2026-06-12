/**
 * Run repo transcribe CLI: Windows prefers C:\dev\tools\transcribe.bat; else `transcribe` on PATH (macOS/Linux).
 */

import { existsSync } from 'fs';
import { execFileSync, execSync } from 'child_process';

const WINDOWS_TRANSCRIBE_BAT = 'C:\\dev\\tools\\transcribe.bat';

type RunTranscribeOptions = {
  platform?: string;
  transcribeBat?: string;
  exists?: (path: string) => boolean;
  execFile?: typeof execFileSync;
  execCommand?: typeof execSync;
};

function quoteForCmd(value: string): string {
  return `"${value.replace(/"/g, '""').replace(/%/g, '%%')}"`;
}

export function buildWindowsTranscribeCommand(
  videoPath: string,
  transcribeBat = WINDOWS_TRANSCRIBE_BAT,
): string {
  return `call ${quoteForCmd(transcribeBat)} ${quoteForCmd(videoPath)}`;
}

export function runTranscribeForVideo(
  videoPath: string,
  options: RunTranscribeOptions = {},
): void {
  const platform = options.platform ?? process.platform;
  const transcribeBat = options.transcribeBat ?? WINDOWS_TRANSCRIBE_BAT;
  const exists = options.exists ?? existsSync;
  const execFile = options.execFile ?? execFileSync;
  const execCommand = options.execCommand ?? execSync;

  if (platform === 'win32' && exists(transcribeBat)) {
    execCommand(buildWindowsTranscribeCommand(videoPath, transcribeBat), { stdio: 'inherit' });
    return;
  }

  execFile('transcribe', [videoPath], { stdio: 'inherit', env: process.env });
}
