import assert from 'node:assert/strict';
import test from 'node:test';
import {
  closeWindow,
  defaultGeometry,
  dialogGeometry,
  focusedWindow,
  focusWindow,
  maximiseWindow,
  minimiseAll,
  minimiseWindow,
  moveWindow,
  openWindow,
  pathForWindow,
  restoreWindow,
  restoreWindows,
  toggleMaximise,
  windowForPath,
  type Desktop,
} from './windowManager.ts';

const box = { x: 10, y: 10, width: 400, height: 300 };
const empty: Desktop = { windows: [] };

function ids(desktop: Desktop): string[] {
  return desktop.windows.map(window => window.id);
}

test('opening a window puts it on top, and opening it again just focuses it', () => {
  let desktop = openWindow(empty, 'home', box);
  desktop = openWindow(desktop, 'tool:tandem', box);
  assert.deepEqual(ids(desktop), ['home', 'tool:tandem']);
  assert.equal(focusedWindow(desktop)?.id, 'tool:tandem');

  desktop = openWindow(desktop, 'home', { ...box, x: 999 });
  assert.deepEqual(ids(desktop), ['tool:tandem', 'home']);
  assert.equal(desktop.windows[1].x, 10, 'reopening keeps where you left it');
});

test('focusing brings a window forward and restores it if minimised', () => {
  let desktop = openWindow(openWindow(empty, 'home', box), 'tool:tandem', box);
  desktop = minimiseWindow(desktop, 'home');
  assert.equal(focusedWindow(desktop)?.id, 'tool:tandem');

  desktop = focusWindow(desktop, 'home');
  assert.equal(focusedWindow(desktop)?.id, 'home');
  assert.equal(desktop.windows.find(window => window.id === 'home')?.minimised, false);
});

test('minimising the top window hands focus to the next one down', () => {
  let desktop = openWindow(openWindow(empty, 'home', box), 'tool:tandem', box);
  desktop = minimiseWindow(desktop, 'tool:tandem');

  assert.equal(focusedWindow(desktop)?.id, 'home');
  desktop = minimiseWindow(desktop, 'home');
  assert.equal(focusedWindow(desktop), undefined);
});

test('closing removes the window', () => {
  const desktop = closeWindow(openWindow(openWindow(empty, 'home', box), 'tool:tandem', box), 'tool:tandem');
  assert.deepEqual(ids(desktop), ['home']);
});

test('moving and maximising change only that window', () => {
  let desktop = openWindow(openWindow(empty, 'home', box), 'tool:tandem', box);
  desktop = moveWindow(desktop, 'home', { x: 50, y: 60, width: 500, height: 400 });
  desktop = toggleMaximise(desktop, 'tool:tandem');

  assert.deepEqual(desktop.windows[0], { id: 'home', x: 50, y: 60, width: 500, height: 400, maximised: false, minimised: false });
  assert.equal(desktop.windows[1].maximised, true);
  assert.equal(toggleMaximise(desktop, 'tool:tandem').windows[1].maximised, false);
});

test('each window has a URL, and each URL has a window', () => {
  assert.equal(pathForWindow('home'), '/');
  assert.equal(pathForWindow('tool:record-it'), '/tools/record-it');
  assert.equal(windowForPath('/'), 'home');
  assert.equal(windowForPath('/tools/record-it'), 'tool:record-it');
  assert.equal(windowForPath('/tools/nope'), undefined);
});

test('new windows open centred between the desktop icons and cascade', () => {
  const area = { width: 1600, height: 900 };
  const first = defaultGeometry(area, 0);
  const second = defaultGeometry(area, 1);

  assert.ok(first.width <= 1100 && first.width >= 600);
  assert.equal(first.x, Math.round((area.width - first.width) / 2));
  assert.ok(first.y >= 0 && first.y + first.height <= area.height);
  assert.ok(second.x > first.x && second.y > first.y);
});

test('on a small screen windows fill it', () => {
  assert.deepEqual(defaultGeometry({ width: 390, height: 800 }, 3), { x: 0, y: 0, width: 390, height: 800 });
});

test('restore brings a window back to normal size and to the front', () => {
  let desktop = openWindow(openWindow(empty, 'home', box), 'tool:tandem', box);
  desktop = toggleMaximise(desktop, 'home');
  desktop = minimiseWindow(desktop, 'home');
  desktop = restoreWindow(desktop, 'home');

  const home = desktop.windows.find(window => window.id === 'home');
  assert.equal(focusedWindow(desktop)?.id, 'home');
  assert.equal(home?.maximised, false);
  assert.equal(home?.minimised, false);
});

test('maximise from the taskbar also brings the window forward', () => {
  let desktop = openWindow(openWindow(empty, 'home', box), 'tool:tandem', box);
  desktop = maximiseWindow(minimiseWindow(desktop, 'home'), 'home');

  assert.equal(focusedWindow(desktop)?.id, 'home');
  assert.equal(focusedWindow(desktop)?.maximised, true);
});

test('Show Desktop minimises everything, and a second press puts it all back', () => {
  let desktop = openWindow(openWindow(openWindow(empty, 'home', box), 'tool:a', box), 'tool:b', box);
  desktop = minimiseWindow(desktop, 'tool:a');

  const { desktop: hidden, hiddenIds } = minimiseAll(desktop);
  assert.equal(focusedWindow(hidden), undefined);
  assert.deepEqual(hiddenIds, ['home', 'tool:b'], 'only windows that were showing');

  const back = restoreWindows(hidden, hiddenIds);
  assert.equal(focusedWindow(back)?.id, 'tool:b');
  assert.equal(back.windows.find(window => window.id === 'tool:a')?.minimised, true);
});

test('app windows like Date and Time have no URL of their own', () => {
  assert.equal(pathForWindow('app:datetime'), undefined);
});

test('small windows open centred at their own size', () => {
  const geometry = dialogGeometry({ width: 1600, height: 900 }, { width: 480, height: 400 });
  assert.deepEqual(geometry, { x: 560, y: 250, width: 480, height: 400 });
  assert.deepEqual(dialogGeometry({ width: 390, height: 800 }, { width: 480, height: 400 }), { x: 0, y: 0, width: 390, height: 800 });
});
