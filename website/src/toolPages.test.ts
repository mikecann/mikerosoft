import assert from 'node:assert/strict';
import test from 'node:test';
import { makeItYoursPrompt, parseRoute, readmeUrl, shareImageFor, toolPath, withRedirect, withToolMeta } from './toolPages.ts';
import { toolDetails } from './toolDetails.ts';
import { RENAMED_TOOLS, tools, type Tool } from './tools.ts';

const fixture: Tool = {
  name: 'record-it',
  desc: 'Native "screen" recorder',
  icon: 'https://example.com/icon.png',
  header: 'https://example.com/header.webp',
  screenshots: [],
  url: 'https://github.com/mikecann/record-it',
  platforms: ['macos'],
  category: 'Video & recording',
};

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

test('the copy prompt asks an agent to clone the tool repo and make it yours', () => {
  assert.equal(
    makeItYoursPrompt(fixture),
    "Clone https://github.com/mikecann/record-it and make it my own. It's one of Mike Cann's personal tools, "
      + 'so read the README first, change anything specific to his setup to suit mine, then help me get it running.',
  );
});

test('links to the tool README on GitHub', () => {
  assert.equal(readmeUrl(fixture), 'https://github.com/mikecann/record-it/blob/main/README.md');
});

test('old links to renamed tools open the tool under its new name', () => {
  assert.deepEqual(parseRoute('/tools/removebg'), { kind: 'tool', name: 'cutout' });
  assert.deepEqual(parseRoute('/tools/worktrees/'), { kind: 'tool', name: 'worktree-tidy' });
  assert.deepEqual(parseRoute('/tools/cutout'), { kind: 'tool', name: 'cutout' });
});

test('every renamed tool points at a tool that exists under a new name', () => {
  for (const [oldName, newName] of Object.entries(RENAMED_TOOLS)) {
    assert.notEqual(oldName, newName);
    assert.ok(tools.some(tool => tool.name === newName), `${oldName} points at missing ${newName}`);
    assert.ok(!tools.some(tool => tool.name === oldName), `${oldName} is still a tool`);
    assert.deepEqual(parseRoute(`/tools/${oldName}`), { kind: 'tool', name: newName });
  }
});

test('every published tool has friendly page copy', () => {
  for (const tool of tools) {
    const details = toolDetails[tool.name];
    assert.ok(details, `${tool.name} has no details`);
    assert.ok(details.tagline.length > 0, `${tool.name} has no tagline`);
    assert.ok(details.intro.length > 0, `${tool.name} has no intro`);
  }
});

test('page copy never uses em or en dashes', () => {
  const text = JSON.stringify(toolDetails);
  assert.doesNotMatch(text, /[–—]/);
});

test('tool pages get their own title, description and share image', () => {

  const page = withToolMeta(html, fixture, 'Records your "screen" & camera', 'https://example.com/share.jpg');

  assert.match(page, /<title>record-it · Mikerosoft<\/title>/);
  assert.match(page, /<meta name="description" content="Records your &quot;screen&quot; &amp; camera" \/>/);
  assert.match(page, /<meta property="og:image" content="https:\/\/example.com\/share.jpg" \/>/);
  assert.match(page, /<meta name="twitter:image" content="https:\/\/example.com\/share.jpg" \/>/);
  assert.match(page, /<meta property="og:url" content="https:\/\/mikerosoft.app\/tools\/record-it" \/>/);
  assert.match(page, /<link rel="canonical" href="https:\/\/mikerosoft.app\/tools\/record-it" \/>/);
  assert.doesNotMatch(page, /content="home"/);
});

test('share images use the screenshot of the tool window, or its header art until there is one', () => {
  assert.equal(shareImageFor(fixture, true), 'https://mikerosoft.app/share/record-it.jpg');
  assert.equal(shareImageFor(fixture, false), 'https://example.com/header.webp');
  assert.equal(shareImageFor({ ...fixture, header: undefined }, false), 'https://mikerosoft.app/share/home.jpg');
});

test('an old link previews the renamed tool and sends the browser to its new address', () => {
  const tool = { ...fixture, name: 'cutout', url: 'https://github.com/mikecann/cutout' };

  const page = withRedirect(html, tool, 'Removes backgrounds', 'https://example.com/share.jpg');

  assert.match(page, /<title>cutout · Mikerosoft<\/title>/);
  assert.match(page, /<link rel="canonical" href="https:\/\/mikerosoft.app\/tools\/cutout" \/>/);
  assert.match(page, /<meta property="og:url" content="https:\/\/mikerosoft.app\/tools\/cutout" \/>/);
  assert.match(page, /<meta http-equiv="refresh" content="0; url=\/tools\/cutout" \/>\n<\/head>/);
});
