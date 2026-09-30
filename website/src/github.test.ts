import assert from 'node:assert/strict';
import test from 'node:test';
import { githubUrl, parentPath, rawUrl, repoPathFromUrl, resolveRepoPath } from './github.ts';

test('builds GitHub addresses for the repo, folders and files', () => {
  assert.equal(githubUrl(''), 'https://github.com/mikecann/mikerosoft');
  assert.equal(githubUrl('tools/tandem'), 'https://github.com/mikecann/mikerosoft/tree/main/tools/tandem');
  assert.equal(githubUrl('tools/tandem/README.md', 'file'), 'https://github.com/mikecann/mikerosoft/blob/main/tools/tandem/README.md');
});

test('reads a repo path back out of a GitHub address', () => {
  assert.equal(repoPathFromUrl('https://github.com/mikecann/mikerosoft'), '');
  assert.equal(repoPathFromUrl('https://github.com/mikecann/mikerosoft/'), '');
  assert.equal(repoPathFromUrl('github.com/mikecann/mikerosoft/tree/main/tools/tandem'), 'tools/tandem');
  assert.equal(repoPathFromUrl('https://github.com/mikecann/mikerosoft/blob/main/tools/a.md#usage'), 'tools/a.md');
  assert.equal(repoPathFromUrl('https://github.com/someone/else'), undefined);
  assert.equal(repoPathFromUrl('https://example.com'), undefined);
});

test('resolves relative links from inside a folder', () => {
  assert.equal(resolveRepoPath('tools/tandem', 'docs/PLAN.md'), 'tools/tandem/docs/PLAN.md');
  assert.equal(resolveRepoPath('tools/tandem', './docs/header.jpg'), 'tools/tandem/docs/header.jpg');
  assert.equal(resolveRepoPath('tools/tandem', '../record-it'), 'tools/record-it');
  assert.equal(resolveRepoPath('tools/tandem', '/AGENTS.md'), 'AGENTS.md');
  assert.equal(resolveRepoPath('', 'tools/'), 'tools');
  assert.equal(resolveRepoPath('tools', 'x.md?raw=1#top'), 'tools/x.md');
});

test('finds the parent folder and raw file addresses', () => {
  assert.equal(parentPath('tools/tandem/README.md'), 'tools/tandem');
  assert.equal(parentPath('tools'), '');
  assert.equal(rawUrl('tools/tandem/docs/ss1.jpg'), 'https://raw.githubusercontent.com/mikecann/mikerosoft/main/tools/tandem/docs/ss1.jpg');
});
