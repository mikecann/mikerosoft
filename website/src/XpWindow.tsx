import { useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react';
import { ContextMenu } from './ContextMenu';
import type { Geometry, WindowState } from './windowManager';

const MIN_WIDTH = 360;
const MIN_HEIGHT = 240;
// Always leave this much of a window on screen so it can be dragged back.
const KEEP_VISIBLE = 80;

type Edge = 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw';
const EDGES: Edge[] = ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'];

type Drag = { edge: Edge | 'move'; startX: number; startY: number; start: Geometry };

/** Works out a window's new box while it's moved or resized from an edge. */
function dragGeometry(drag: Drag, dx: number, dy: number, area: { width: number; height: number }): Geometry {
  const { start, edge } = drag;
  if (edge === 'move') {
    return {
      ...start,
      x: Math.min(area.width - KEEP_VISIBLE, Math.max(KEEP_VISIBLE - start.width, start.x + dx)),
      y: Math.min(area.height - 30, Math.max(0, start.y + dy)),
    };
  }
  let { x, y, width, height } = start;
  if (edge.includes('e')) width = Math.max(MIN_WIDTH, start.width + dx);
  if (edge.includes('s')) height = Math.max(MIN_HEIGHT, start.height + dy);
  if (edge.includes('w')) {
    width = Math.max(MIN_WIDTH, start.width - dx);
    x = start.x + start.width - width;
  }
  if (edge.includes('n')) {
    height = Math.max(MIN_HEIGHT, start.height - dy);
    y = Math.max(0, start.y + start.height - height);
    height = start.y + start.height - y;
  }
  return { x, y, width, height };
}

/** A Windows XP window that moves by its title bar and resizes from any edge. */
export function XpWindow({
  window: state,
  title,
  icon,
  zIndex,
  isFocused,
  isSmallScreen,
  area,
  statusBar,
  kind = 'document',
  children,
  onFocus,
  onMinimise,
  onToggleMaximise,
  onClose,
  onGeometryChange,
}: {
  window: WindowState;
  title: string;
  icon: string;
  zIndex: number;
  isFocused: boolean;
  isSmallScreen: boolean;
  area: { width: number; height: number };
  statusBar?: ReactNode;
  /** Documents are white and resizable. Dialogs are grey, fixed size and can't maximise, like Date and Time. */
  kind?: 'document' | 'dialog';
  children: ReactNode;
  onFocus: () => void;
  onMinimise: () => void;
  onToggleMaximise: () => void;
  onClose: () => void;
  onGeometryChange: (geometry: Geometry) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const drag = useRef<Drag | null>(null);
  const live = useRef<Geometry>(state);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const isFullScreen = state.maximised || isSmallScreen;
  const isDialog = kind === 'dialog';

  function begin(edge: Drag['edge'], event: ReactPointerEvent<HTMLElement>) {
    if (isFullScreen || event.button !== 0) return;
    if ((event.target as Element).closest('button')) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { edge, startX: event.clientX, startY: event.clientY, start: { ...state } };
    live.current = { ...state };
    ref.current?.setAttribute('data-dragging', '');
  }

  function track(event: ReactPointerEvent<HTMLElement>) {
    const current = drag.current;
    const element = ref.current;
    if (!current || !element) return;
    live.current = dragGeometry(current, event.clientX - current.startX, event.clientY - current.startY, area);
    // Style the element directly while dragging, so React only re-renders once at the end.
    element.style.left = `${live.current.x}px`;
    element.style.top = `${live.current.y}px`;
    element.style.width = `${live.current.width}px`;
    element.style.height = `${live.current.height}px`;
  }

  function end() {
    if (!drag.current) return;
    drag.current = null;
    ref.current?.removeAttribute('data-dragging');
    onGeometryChange(live.current);
  }

  const dragHandlers = { onPointerMove: track, onPointerUp: end, onPointerCancel: end };
  const style = isFullScreen
    ? { left: 0, top: 0, width: area.width, height: area.height, zIndex }
    : { left: state.x, top: state.y, width: state.width, height: state.height, zIndex };

  return (
    <section
      ref={ref}
      className="window xp-window"
      style={style}
      data-minimised={state.minimised || undefined}
      data-full={isFullScreen || undefined}
      data-focused={isFocused || undefined}
      data-kind={kind}
      aria-label={title}
      onPointerDownCapture={() => {
        if (!isFocused) onFocus();
      }}
    >
      <div
        className="title-bar"
        data-inactive={!isFocused || undefined}
        onPointerDown={event => begin('move', event)}
        {...dragHandlers}
        onDoubleClick={event => {
          if (!(event.target as Element).closest('button') && !isSmallScreen && !isDialog) onToggleMaximise();
        }}
        onContextMenu={event => {
          event.preventDefault();
          setMenu({ x: event.clientX, y: event.clientY });
        }}
      >
        <div className="title-bar-text">
          <img src={icon} alt="" />
          <span>{title}</span>
        </div>
        <div className="title-bar-controls">
          <button type="button" aria-label="Minimize" onClick={onMinimise} />
          {!isSmallScreen && !isDialog && (
            <button type="button" aria-label={state.maximised ? 'Restore' : 'Maximize'} onClick={onToggleMaximise} />
          )}
          <button type="button" aria-label="Close" onClick={onClose} />
        </div>
      </div>
      <div className="xp-window-body">{children}</div>
      {statusBar && <div className="status-bar">{statusBar}</div>}
      {!isFullScreen && !isDialog && EDGES.map(edge => (
        <div
          key={edge}
          className="xp-resize"
          data-edge={edge}
          aria-hidden="true"
          onPointerDown={event => begin(edge, event)}
          {...dragHandlers}
        />
      ))}
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onClose={() => setMenu(null)}
          items={[
            { label: 'Restore', onSelect: onToggleMaximise, disabled: !state.maximised },
            { label: 'Minimize', onSelect: onMinimise },
            { label: 'Maximize', onSelect: onToggleMaximise, disabled: state.maximised || isSmallScreen || isDialog },
            { kind: 'separator' },
            { label: 'Close', bold: true, onSelect: onClose },
          ]}
        />
      )}
    </section>
  );
}
