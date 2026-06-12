import { expect, test } from 'bun:test';
import {
  buildWindowsTranscribeCommand,
  runTranscribeForVideo,
} from './run-transcribe';

test('windows transcribe invocation preserves video paths with spaces', () => {
  const command = buildWindowsTranscribeCommand(
    'C:\\videos\\v1.40.0\\v1.40.0 update .mp4',
    'C:\\dev\\tools\\transcribe.bat',
  );

  expect(command).toBe(
    'call "C:\\dev\\tools\\transcribe.bat" "C:\\videos\\v1.40.0\\v1.40.0 update .mp4"',
  );
});

test('windows transcribe runner uses cmd instead of shell-splitting batch args', () => {
  const calls: string[] = [];

  runTranscribeForVideo('C:\\videos\\clip with spaces.mp4', {
    platform: 'win32',
    transcribeBat: 'C:\\dev\\tools\\transcribe.bat',
    exists: () => true,
    execCommand: ((command: string) => {
      calls.push(command);
      return Buffer.from('');
    }) as any,
  });

  expect(calls).toEqual([
    'call "C:\\dev\\tools\\transcribe.bat" "C:\\videos\\clip with spaces.mp4"',
  ]);
});
