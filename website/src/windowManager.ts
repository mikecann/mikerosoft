import { parseRoute, toolPath } from './toolPages';

/** The Mikerosoft window is `home`; every tool gets `tool:<name>`. */
export type WindowId = 'home' | `tool:${string}`;

export interface Geometry {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WindowState extends Geometry {
  id: WindowId;
  maximised: boolean;
  minimised: boolean;
}

/** Windows in stacking order, the last one on top. */
export interface Desktop {
  windows: WindowState[];
}

/** Below this width every window fills the screen. */
export const SMALL_SCREEN = 760;

function without(desktop: Desktop, id: WindowId): WindowState[] {
  return desktop.windows.filter(window => window.id !== id);
}

function update(desktop: Desktop, id: WindowId, change: Partial<WindowState>): Desktop {
  return { windows: desktop.windows.map(window => (window.id === id ? { ...window, ...change } : window)) };
}

export function focusWindow(desktop: Desktop, id: WindowId): Desktop {
  const window = desktop.windows.find(candidate => candidate.id === id);
  if (!window) return desktop;
  return { windows: [...without(desktop, id), { ...window, minimised: false }] };
}

/** Opens a window on top, or brings it forward where it was if it's already open. */
export function openWindow(desktop: Desktop, id: WindowId, geometry: Geometry): Desktop {
  if (desktop.windows.some(window => window.id === id)) return focusWindow(desktop, id);
  return { windows: [...desktop.windows, { id, ...geometry, maximised: false, minimised: false }] };
}

export function closeWindow(desktop: Desktop, id: WindowId): Desktop {
  return { windows: without(desktop, id) };
}

export function minimiseWindow(desktop: Desktop, id: WindowId): Desktop {
  const window = desktop.windows.find(candidate => candidate.id === id);
  if (!window) return desktop;
  // Minimised windows drop to the bottom so focus falls to the next one down.
  return { windows: [{ ...window, minimised: true }, ...without(desktop, id)] };
}

export function toggleMaximise(desktop: Desktop, id: WindowId): Desktop {
  const window = desktop.windows.find(candidate => candidate.id === id);
  return window ? update(desktop, id, { maximised: !window.maximised }) : desktop;
}

/** Back to its normal size, in front. */
export function restoreWindow(desktop: Desktop, id: WindowId): Desktop {
  return update(focusWindow(desktop, id), id, { maximised: false });
}

export function maximiseWindow(desktop: Desktop, id: WindowId): Desktop {
  return update(focusWindow(desktop, id), id, { maximised: true });
}

/** Show Desktop: hides every window that's showing, and says which ones, so they can come back. */
export function minimiseAll(desktop: Desktop): { desktop: Desktop; hiddenIds: WindowId[] } {
  const hiddenIds = desktop.windows.filter(window => !window.minimised).map(window => window.id);
  return { desktop: { windows: desktop.windows.map(window => ({ ...window, minimised: true })) }, hiddenIds };
}

/** Brings windows back in their old stacking order. */
export function restoreWindows(desktop: Desktop, ids: readonly WindowId[]): Desktop {
  return ids.reduce((current, id) => focusWindow(current, id), desktop);
}

export function moveWindow(desktop: Desktop, id: WindowId, geometry: Geometry): Desktop {
  return update(desktop, id, geometry);
}

export function focusedWindow(desktop: Desktop): WindowState | undefined {
  return [...desktop.windows].reverse().find(window => !window.minimised);
}

export function pathForWindow(id: WindowId): string {
  return id === 'home' ? '/' : toolPath(id.slice('tool:'.length));
}

export function windowForPath(pathname: string): WindowId | undefined {
  const route = parseRoute(pathname);
  if (route.kind === 'home') return 'home';
  if (route.kind === 'tool') return `tool:${route.name}`;
  return undefined;
}

/**
 * Where a new window opens: centred, wide enough to read comfortably, leaving
 * the desktop icons down each side visible, and nudged along for each window
 * already open so they cascade.
 */
export function defaultGeometry(area: { width: number; height: number }, openCount: number): Geometry {
  if (area.width < SMALL_SCREEN) return { x: 0, y: 0, width: area.width, height: area.height };

  const width = Math.round(Math.min(1100, Math.max(600, area.width - 420)));
  const height = Math.round(Math.min(area.height - 40, Math.max(420, area.height * 0.9)));
  const step = (openCount % 6) * 28;
  return {
    x: Math.round((area.width - width) / 2) + step,
    y: Math.max(0, Math.round((area.height - height) / 2)) + step,
    width,
    height,
  };
}
