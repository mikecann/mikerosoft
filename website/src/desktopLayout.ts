/** Where desktop icons sit, as cells on a grid. */
export interface Cell {
  col: number;
  row: number;
}

export type Layout = Record<string, Cell>;

export interface Grid {
  cols: number;
  rows: number;
}

export type Direction = 'up' | 'down' | 'left' | 'right';

function key(cell: Cell): string {
  return `${cell.col},${cell.row}`;
}

function clamp(value: number, max: number): number {
  return Math.min(Math.max(value, 0), Math.max(max - 1, 0));
}

/** Every cell on the grid, nearest to `target` first. */
function cellsNearest(target: Cell, grid: Grid): Cell[] {
  const cells: Cell[] = [];
  for (let col = 0; col < grid.cols; col += 1) {
    for (let row = 0; row < grid.rows; row += 1) cells.push({ col, row });
  }
  const distance = (cell: Cell) => Math.abs(cell.col - target.col) + Math.abs(cell.row - target.row);
  return cells.sort((a, b) => distance(a) - distance(b) || a.col - b.col || a.row - b.row);
}

function nearestFree(target: Cell, taken: Set<string>, grid: Grid): Cell {
  return cellsNearest(target, grid).find(cell => !taken.has(key(cell))) ?? target;
}

/** Fills columns top to bottom, left to right. */
export function arrangeInColumns(ids: readonly string[], grid: Grid): Layout {
  const rows = Math.max(grid.rows, 1);
  return Object.fromEntries(ids.map((id, i) => [id, { col: Math.floor(i / rows), row: i % rows }]));
}

/** The first set of icons go down the left edge, the second down the right. */
export function defaultLayout(left: readonly string[], right: readonly string[], grid: Grid): Layout {
  const layout = arrangeInColumns(left, grid);
  const rows = Math.max(grid.rows, 1);
  right.forEach((id, i) => {
    layout[id] = { col: Math.max(grid.cols - 1 - Math.floor(i / rows), 0), row: i % rows };
  });
  return fitLayout(layout, grid);
}

/** Moves the given icons together by a number of cells, keeping them on the grid and off each other. */
export function moveIcons(layout: Layout, ids: readonly string[], by: { cols: number; rows: number }, grid: Grid): Layout {
  const moving = new Set(ids);
  const next: Layout = {};
  const taken = new Set<string>();
  for (const [id, cell] of Object.entries(layout)) {
    if (moving.has(id)) continue;
    next[id] = cell;
    taken.add(key(cell));
  }
  for (const id of ids) {
    const from = layout[id];
    if (!from) continue;
    const target = { col: clamp(from.col + by.cols, grid.cols), row: clamp(from.row + by.rows, grid.rows) };
    const cell = nearestFree(target, taken, grid);
    next[id] = cell;
    taken.add(key(cell));
  }
  return next;
}

/** Pulls icons back onto a smaller grid, giving any that land on each other a free cell nearby. */
export function fitLayout(layout: Layout, grid: Grid): Layout {
  const next: Layout = {};
  const taken = new Set<string>();
  // Icons already on the grid keep their place first.
  const entries = Object.entries(layout).sort(([, a], [, b]) => {
    const offA = a.col >= grid.cols || a.row >= grid.rows ? 1 : 0;
    const offB = b.col >= grid.cols || b.row >= grid.rows ? 1 : 0;
    return offA - offB;
  });
  for (const [id, cell] of entries) {
    const target = { col: clamp(cell.col, grid.cols), row: clamp(cell.row, grid.rows) };
    const placed = taken.has(key(target)) ? nearestFree(target, taken, grid) : target;
    next[id] = placed;
    taken.add(key(placed));
  }
  return next;
}

/** Icons whose cell overlaps a rectangle drawn in pixels. */
export function iconsInRect(
  layout: Layout,
  rect: { x: number; y: number; width: number; height: number },
  cell: { width: number; height: number },
): string[] {
  return Object.entries(layout)
    .filter(([, { col, row }]) => {
      const left = col * cell.width;
      const top = row * cell.height;
      return left < rect.x + rect.width && left + cell.width > rect.x && top < rect.y + rect.height && top + cell.height > rect.y;
    })
    .map(([id]) => id);
}

/** The closest icon in a direction, or the same icon when there's nothing that way. */
export function nextIcon(layout: Layout, from: string, direction: Direction): string {
  const start = layout[from];
  if (!start) return from;
  const ahead = ([, cell]: [string, Cell]) => {
    if (direction === 'up') return cell.row < start.row;
    if (direction === 'down') return cell.row > start.row;
    if (direction === 'left') return cell.col < start.col;
    return cell.col > start.col;
  };
  // Distance along the direction counts less than drifting sideways from it.
  const cost = ([, cell]: [string, Cell]) => {
    const along = direction === 'up' || direction === 'down' ? Math.abs(cell.row - start.row) : Math.abs(cell.col - start.col);
    const across = direction === 'up' || direction === 'down' ? Math.abs(cell.col - start.col) : Math.abs(cell.row - start.row);
    return along + across * 3;
  };
  const best = Object.entries(layout).filter(ahead).sort((a, b) => cost(a) - cost(b))[0];
  return best ? best[0] : from;
}
