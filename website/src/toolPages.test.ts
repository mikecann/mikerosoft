import assert from 'node:assert/strict';
import test from 'node:test';
import { makeItYoursPrompt, parseRoute, readmeUrl, toolPath, withToolMeta } from './toolPages.ts';
import { toolDetails } from './toolDetails.ts';
import { tools, type Tool } from './tools.ts';

const fixture: Tool = {
  name: 'record-it',
  desc: 'Native "screen" recorder',
  icon: 'https://example.com/icon.png',
  header: 'https://example.com/header.webp',
  screenshots: [],
  url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/record-it',
  platforms: ['macos'],
};

test('every tool gets its own page path', () => {
  assert.equal(toolPath('record-it'), '/tools/record-it');
});

test('parses the home page, tool pages and unknown paths', () => {
  assert.deepEqual(parseRoute('/'), { kind: 'home' });
  assert.deepEqual(parseRoute(''), { kind: 'home' });
  assert.deepEqual(parseRoute('/tools/record-it'), { kind: 'tool', name: 'record-it' });
  assert.deepEqual(parseRoute('/tools/record-it/'), { kind: 'tool', name: 'record-it' });
  assert.deepEqual(parseRoute('/tools/nope'), { kind: 'not-found' });
  assert.deepEqual(parseRoute('/somewhere'), { kind: 'not-found' });
});

test('the copy prompt asks an agent to copy the source and make it yours', () => {
  const prompt = makeItYoursPrompt(fixture);

  assert.match(prompt, /record-it/);
  assert.ok(prompt.includes(fixture.url));
  assert.match(prompt, /make it my own/i);
});

test('links to the tool README on GitHub', () => {
  assert.equal(
    readmeUrl(fixture),
    'https://github.com/mikecann/mikerosoft/blob/main/tools/record-it/README.md',
  );
});

test('every published tool has friendly page copy', () => {
  for (const tool of tools) {
    const details = toolDetails[tool.name];
    assert.ok(details, `${tool.name} has no details`);
    assert.ok(details.tagline.length > 0, `${tool.name} has no tagline`);
    assert.ok(details.intro.length > 0, `${tool.name} has no intro`);
    assert.ok(details.howToUse.length >= 2, `${tool.name} needs usage steps`);
  }
});

test('page copy never uses em or en dashes', () => {
  const text = JSON.stringify(toolDetails);
  assert.doesNotMatch(text, /[–—]/);
});

test('tool pages get their own title, description and share image', () => {
  const html = [
    '<html><head>',
    '<title>Mikerosoft</title>',
    '<meta name="description" content="home" />',
    '<meta property="og:title" content="Mikerosoft" />',
    '<meta property="og:description" content="home" />',
    '<meta property="og:image" content="https://mikerosoft.app/logo.png" />',
    '<meta property="og:url" content="https://mikerosoft.app/" />',
    '<meta name="twitter:title" content="Mikerosoft" />',
    '<meta name="twitter:description" content="home" />',
    '<meta name="twitter:image" content="https://mikerosoft.app/logo.png" />',
    '<link rel="canonical" href="https://mikerosoft.app/" />',
    '</head></html>',
  ].join('\n');

  const page = withToolMeta(html, fixture, 'Records your "screen" & camera');

  assert.match(page, /<title>record-it · Mikerosoft<\/title>/);
  assert.match(page, /<meta name="description" content="Records your &quot;screen&quot; &amp; camera" \/>/);
  assert.match(page, /<meta property="og:image" content="https:\/\/example.com\/header.webp" \/>/);
  assert.match(page, /<meta property="og:url" content="https:\/\/mikerosoft.app\/tools\/record-it" \/>/);
  assert.match(page, /<link rel="canonical" href="https:\/\/mikerosoft.app\/tools\/record-it" \/>/);
  assert.doesNotMatch(page, /content="home"/);
});
