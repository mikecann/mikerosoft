import assert from 'node:assert/strict';
import test from 'node:test';
import {
  arrangeInColumns,
  defaultLayout,
  fitLayout,
  iconsInRect,
  moveIcons,
  nextIcon,
  type Layout,
} from './desktopLayout.ts';

const grid = { cols: 10, rows: 4 };

test('the default layout fills columns down the left, and the rest down the right', () => {
  const layout = defaultLayout(['a', 'b', 'c', 'd', 'e'], ['x', 'y'], grid);

  assert.deepEqual(layout.a, { col: 0, row: 0 });
  assert.deepEqual(layout.d, { col: 0, row: 3 });
  assert.deepEqual(layout.e, { col: 1, row: 0 });
  assert.deepEqual(layout.x, { col: 9, row: 0 });
  assert.deepEqual(layout.y, { col: 9, row: 1 });
});

test('moving icons keeps their shape and snaps to the grid', () => {
  const layout: Layout = { a: { col: 0, row: 0 }, b: { col: 0, row: 1 }, c: { col: 5, row: 0 } };
  const moved = moveIcons(layout, ['a', 'b'], { cols: 2, rows: 1 }, grid);

  assert.deepEqual(moved.a, { col: 2, row: 1 });
  assert.deepEqual(moved.b, { col: 2, row: 2 });
  assert.deepEqual(moved.c, { col: 5, row: 0 }, 'icons not being moved stay put');
});

test('an icon dropped on another one goes to the nearest free cell', () => {
  const layout: Layout = { a: { col: 0, row: 0 }, b: { col: 3, row: 0 } };
  const moved = moveIcons(layout, ['a'], { cols: 3, rows: 0 }, grid);

  assert.deepEqual(moved.b, { col: 3, row: 0 });
  assert.notDeepEqual(moved.a, { col: 3, row: 0 });
  assert.equal(Math.abs(moved.a.col - 3) + Math.abs(moved.a.row - 0), 1);
});

test('icons dragged off the edge stay on the desktop', () => {
  const moved = moveIcons({ a: { col: 1, row: 1 } }, ['a'], { cols: -5, rows: 9 }, grid);
  assert.deepEqual(moved.a, { col: 0, row: 3 });
});

test('a smaller desktop pulls icons back on screen without stacking them', () => {
  const layout: Layout = { a: { col: 9, row: 3 }, b: { col: 8, row: 3 }, c: { col: 0, row: 0 } };
  const fitted = fitLayout(layout, { cols: 5, rows: 2 });
  const cells = Object.values(fitted).map(cell => `${cell.col},${cell.row}`);

  assert.equal(new Set(cells).size, 3);
  for (const cell of Object.values(fitted)) {
    assert.ok(cell.col < 5 && cell.row < 2);
  }
  assert.deepEqual(fitted.c, { col: 0, row: 0 });
});

test('the selection box picks every icon it touches', () => {
  const layout: Layout = { a: { col: 0, row: 0 }, b: { col: 1, row: 1 }, c: { col: 4, row: 3 } };
  const cell = { width: 100, height: 100 };

  assert.deepEqual(iconsInRect(layout, { x: 50, y: 50, width: 80, height: 80 }, cell).sort(), ['a', 'b']);
  assert.deepEqual(iconsInRect(layout, { x: 250, y: 250, width: 10, height: 10 }, cell), []);
});

test('arranging lines icons up in the order given', () => {
  const layout = arrangeInColumns(['c', 'a', 'b'], { cols: 3, rows: 2 });
  assert.deepEqual(layout, { c: { col: 0, row: 0 }, a: { col: 0, row: 1 }, b: { col: 1, row: 0 } });
});

test('arrow keys move to the nearest icon in that direction', () => {
  const layout: Layout = { a: { col: 0, row: 0 }, b: { col: 0, row: 1 }, c: { col: 1, row: 0 }, far: { col: 8, row: 0 } };

  assert.equal(nextIcon(layout, 'a', 'down'), 'b');
  assert.equal(nextIcon(layout, 'a', 'right'), 'c');
  assert.equal(nextIcon(layout, 'c', 'right'), 'far');
  assert.equal(nextIcon(layout, 'a', 'up'), 'a');
});
