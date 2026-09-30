import { useRef, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react';
import type { Geometry, WindowState } from './windowManager';

const MIN_WIDTH = 360;
const MIN_HEIGHT = 240;
// Always leave this much of a window on screen so it can be dragged back.
const KEEP_VISIBLE = 80;

type Drag = { kind: 'move' | 'resize'; startX: number; startY: number; start: Geometry };

/** A Windows XP window that can be dragged by its title bar and resized from its corner. */
export function XpWindow({
  window: state,
  title,
  icon,
  zIndex,
  isFocused,
  isSmallScreen,
  area,
  statusBar,
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
  const isFullScreen = state.maximised || isSmallScreen;

  function begin(kind: Drag['kind'], event: ReactPointerEvent<HTMLElement>) {
    if (isFullScreen || event.button !== 0) return;
    if ((event.target as Element).closest('button')) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { kind, startX: event.clientX, startY: event.clientY, start: { ...state } };
    live.current = { ...state };
    ref.current?.setAttribute('data-dragging', '');
  }

  function track(event: ReactPointerEvent<HTMLElement>) {
    const current = drag.current;
    const element = ref.current;
    if (!current || !element) return;
    const dx = event.clientX - current.startX;
    const dy = event.clientY - current.startY;
    const { start } = current;

    // Style the element directly while dragging, so React only re-renders once at the end.
    if (current.kind === 'move') {
      live.current = {
        ...start,
        x: Math.min(area.width - KEEP_VISIBLE, Math.max(KEEP_VISIBLE - start.width, start.x + dx)),
        y: Math.min(area.height - 30, Math.max(0, start.y + dy)),
      };
    } else {
      live.current = {
        ...start,
        width: Math.max(MIN_WIDTH, start.width + dx),
        height: Math.max(MIN_HEIGHT, start.height + dy),
      };
    }
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
      aria-label={title}
      onPointerDownCapture={() => {
        if (!isFocused) onFocus();
      }}
    >
      <div
        className="title-bar"
        data-inactive={!isFocused || undefined}
        onPointerDown={event => begin('move', event)}
        onPointerMove={track}
        onPointerUp={end}
        onPointerCancel={end}
        onDoubleClick={event => {
          if (!(event.target as Element).closest('button') && !isSmallScreen) onToggleMaximise();
        }}
      >
        <div className="title-bar-text">
          <img src={icon} alt="" />
          <span>{title}</span>
        </div>
        <div className="title-bar-controls">
          <button type="button" aria-label="Minimize" onClick={onMinimise} />
          {!isSmallScreen && (
            <button type="button" aria-label={state.maximised ? 'Restore' : 'Maximize'} onClick={onToggleMaximise} />
          )}
          <button type="button" aria-label="Close" onClick={onClose} />
        </div>
      </div>
      <div className="xp-window-body">{children}</div>
      {statusBar && <div className="status-bar">{statusBar}</div>}
      {!isFullScreen && (
        <div
          className="xp-resize"
          aria-hidden="true"
          onPointerDown={event => begin('resize', event)}
          onPointerMove={track}
          onPointerUp={end}
          onPointerCancel={end}
        />
      )}
    </section>
  );
}
