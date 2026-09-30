import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react';
import { ContextMenu, type MenuItem } from './ContextMenu';
import {
  arrangeInColumns,
  defaultLayout,
  fitLayout,
  iconsInRect,
  moveIcons,
  nextIcon,
  type Direction,
  type Layout,
} from './desktopLayout';

export interface DesktopItem {
  id: string;
  label: string;
  icon: string;
  href: string;
  external?: boolean;
  /** Where the source lives, for the right-click menu. */
  sourceUrl?: string;
}

const CELL = { width: 90, height: 92 };
const PADDING = 8;
const DRAG_THRESHOLD = 4;
const STORAGE_KEY = 'mikerosoft:desktop-layout';

const ARROWS: Record<string, Direction> = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };

type Drag = { ids: string[]; startX: number; startY: number; dx: number; dy: number; moved: boolean };
type Band = { startX: number; startY: number; x: number; y: number; width: number; height: number; additive: Set<string> };
type Menu = { x: number; y: number; items: MenuItem[] };

function readSavedLayout(): Layout {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') as Layout;
  } catch {
    return {};
  }
}

function saveLayout(layout: Layout) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(layout));
  } catch {
    // Private windows can refuse storage. The icons just go back home next visit.
  }
}

/**
 * The desktop behind the windows. Icons select on a click and open on a double
 * click, and can be dragged around, alone or as a selection, like Windows XP.
 */
export function Desktop({
  items,
  leftIds,
  rightIds,
  area,
  isSmallScreen,
  onOpen,
  onActivate,
  onProperties,
}: {
  items: DesktopItem[];
  leftIds: string[];
  rightIds: string[];
  area: { width: number; height: number };
  isSmallScreen: boolean;
  onOpen: (item: DesktopItem, inNewTab?: boolean) => void;
  onActivate: () => void;
  onProperties: () => void;
}) {
  const layerRef = useRef<HTMLDivElement>(null);
  const grid = {
    cols: Math.max(1, Math.floor((area.width - PADDING * 2) / CELL.width)),
    rows: Math.max(1, Math.floor((area.height - PADDING * 2) / CELL.height)),
  };
  const [stored, setStored] = useState<Layout>(() => {
    const saved = readSavedLayout();
    const defaults = defaultLayout(leftIds, rightIds, grid);
    // Saved spots win, and any tool added since gets its default spot or the nearest free one.
    const known = Object.fromEntries(Object.entries(saved).filter(([id]) => id in defaults));
    return { ...known, ...Object.fromEntries(Object.entries(defaults).filter(([id]) => !(id in known))) };
  });
  const layout = useMemo(() => fitLayout(stored, grid), [stored, grid.cols, grid.rows]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [drag, setDrag] = useState<Drag | null>(null);
  const [band, setBand] = useState<Band | null>(null);
  const [menu, setMenu] = useState<Menu | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const suppressClick = useRef(false);

  function commit(next: Layout) {
    setStored(next);
    saveLayout(next);
  }

  function focusIcon(id: string) {
    layerRef.current?.querySelector<HTMLElement>(`[data-icon="${CSS.escape(id)}"]`)?.focus();
  }

  // Icon dragging and the selection box both track the pointer across the whole page.
  useEffect(() => {
    if (!drag && !band) return;
    const layerRect = layerRef.current?.getBoundingClientRect();
    const handleMove = (event: PointerEvent) => {
      if (drag) {
        const dx = event.clientX - drag.startX;
        const dy = event.clientY - drag.startY;
        const moved = drag.moved || Math.hypot(dx, dy) > DRAG_THRESHOLD;
        setDrag({ ...drag, dx, dy, moved });
      } else if (band && layerRect) {
        const x = event.clientX - layerRect.left;
        const y = event.clientY - layerRect.top;
        const rect = {
          x: Math.min(x, band.startX),
          y: Math.min(y, band.startY),
          width: Math.abs(x - band.startX),
          height: Math.abs(y - band.startY),
        };
        setBand({ ...band, ...rect });
        const inside = iconsInRect(layout, { ...rect, x: rect.x - PADDING, y: rect.y - PADDING }, CELL);
        setSelected(new Set([...band.additive, ...inside]));
      }
    };
    const handleUp = () => {
      if (drag?.moved) {
        suppressClick.current = true;
        const by = { cols: Math.round(drag.dx / CELL.width), rows: Math.round(drag.dy / CELL.height) };
        if (by.cols !== 0 || by.rows !== 0) commit(moveIcons(layout, drag.ids, by, grid));
      }
      setDrag(null);
      setBand(null);
    };
    window.addEventListener('pointermove', handleMove);
    window.addEventListener('pointerup', handleUp);
    window.addEventListener('pointercancel', handleUp);
    return () => {
      window.removeEventListener('pointermove', handleMove);
      window.removeEventListener('pointerup', handleUp);
      window.removeEventListener('pointercancel', handleUp);
    };
  });

  function startIconDrag(item: DesktopItem, event: ReactPointerEvent) {
    onActivate();
    if (isSmallScreen || event.button !== 0) return;
    event.preventDefault();
    focusIcon(item.id);
    let ids: string[];
    if (event.ctrlKey || event.metaKey) {
      const next = new Set(selected);
      if (next.has(item.id)) next.delete(item.id);
      else next.add(item.id);
      setSelected(next);
      ids = [...next];
    } else if (selected.has(item.id)) {
      ids = [...selected];
    } else {
      setSelected(new Set([item.id]));
      ids = [item.id];
    }
    if (ids.includes(item.id)) setDrag({ ids, startX: event.clientX, startY: event.clientY, dx: 0, dy: 0, moved: false });
  }

  function startBand(event: ReactPointerEvent) {
    if (event.target !== event.currentTarget || event.button !== 0) return;
    onActivate();
    layerRef.current?.focus();
    const rect = event.currentTarget.getBoundingClientRect();
    const additive = event.ctrlKey || event.metaKey || event.shiftKey ? new Set(selected) : new Set<string>();
    if (!additive.size) setSelected(new Set());
    setBand({ startX: event.clientX - rect.left, startY: event.clientY - rect.top, x: 0, y: 0, width: 0, height: 0, additive });
  }

  function arrange(ids: string[]) {
    commit(arrangeInColumns(ids, grid));
  }

  function openDesktopMenu(event: React.MouseEvent) {
    event.preventDefault();
    if (event.target === event.currentTarget) setSelected(new Set());
    setMenu({
      x: event.clientX,
      y: event.clientY,
      items: [
        { label: 'Arrange Icons by Name', onSelect: () => arrange([...items].sort((a, b) => a.label.localeCompare(b.label)).map(item => item.id)) },
        { label: 'Arrange Icons by Type', onSelect: () => commit(defaultLayout(leftIds, rightIds, grid)) },
        { kind: 'separator' },
        {
          label: 'Refresh',
          onSelect: () => {
            setRefreshing(true);
            setTimeout(() => setRefreshing(false), 150);
          },
        },
        { label: 'Select All', onSelect: () => setSelected(new Set(items.map(item => item.id))) },
        { kind: 'separator' },
        { label: 'Properties', onSelect: onProperties },
      ],
    });
  }

  function openIconMenu(item: DesktopItem, event: React.MouseEvent) {
    event.preventDefault();
    event.stopPropagation();
    if (!selected.has(item.id)) setSelected(new Set([item.id]));
    setMenu({
      x: event.clientX,
      y: event.clientY,
      items: [
        { label: 'Open', bold: true, onSelect: () => onOpen(item) },
        ...(!item.external ? [{ label: 'Open in New Tab', onSelect: () => onOpen(item, true) }] : []),
        ...(item.sourceUrl ? [{ kind: 'separator' as const }, { label: 'View Source', onSelect: () => window.open(item.sourceUrl, '_blank', 'noopener') }] : []),
        { kind: 'separator' },
        { label: 'Properties', onSelect: onProperties },
      ],
    });
  }

  function handleKeyDown(event: KeyboardEvent) {
    const current = (document.activeElement as HTMLElement | null)?.dataset.icon ?? [...selected][0];
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') {
      event.preventDefault();
      setSelected(new Set(items.map(item => item.id)));
    } else if (event.key === 'Escape') {
      setSelected(new Set());
    } else if (event.key === 'Enter' && selected.size > 0) {
      event.preventDefault();
      items.filter(item => selected.has(item.id)).forEach(item => onOpen(item));
    } else if (ARROWS[event.key]) {
      event.preventDefault();
      const next = current ? nextIcon(layout, current, ARROWS[event.key]) : items[0]?.id;
      if (!next) return;
      setSelected(new Set([next]));
      focusIcon(next);
    }
  }

  if (isSmallScreen) {
    // Phones have no double click, so a tap opens and the icons sit in a simple grid.
    return (
      <nav className="desktop-phone" aria-label="Desktop">
        {items.map(item => (
          <button key={item.id} type="button" className="plain desktop-icon" onClick={() => onOpen(item)}>
            <img src={item.icon} alt="" />
            <span>{item.label}</span>
          </button>
        ))}
      </nav>
    );
  }

  return (
    <div
      ref={layerRef}
      className="desktop-layer"
      tabIndex={-1}
      aria-label="Desktop"
      role="listbox"
      aria-multiselectable="true"
      data-refreshing={refreshing || undefined}
      onPointerDown={startBand}
      onContextMenu={openDesktopMenu}
      onKeyDown={handleKeyDown}
    >
      {items.map(item => {
        const cell = layout[item.id];
        if (!cell) return null;
        const isSelected = selected.has(item.id);
        const isDragging = Boolean(drag?.moved && drag.ids.includes(item.id));
        return (
          <button
            key={item.id}
            type="button"
            role="option"
            aria-selected={isSelected}
            data-icon={item.id}
            className="plain desktop-icon"
            data-dragging={isDragging || undefined}
            title={item.label}
            style={{
              left: PADDING + cell.col * CELL.width,
              top: PADDING + cell.row * CELL.height,
              width: CELL.width,
              transform: isDragging ? `translate(${drag!.dx}px, ${drag!.dy}px)` : undefined,
            }}
            onPointerDown={event => startIconDrag(item, event)}
            onClick={() => {
              suppressClick.current = false;
            }}
            onDoubleClick={() => {
              if (suppressClick.current) return;
              onOpen(item);
            }}
            onContextMenu={event => openIconMenu(item, event)}
          >
            <img src={item.icon} alt="" draggable={false} />
            <span>{item.label}</span>
          </button>
        );
      })}
      {band && band.width + band.height > 2 && (
        <div className="selection-band" style={{ left: band.x, top: band.y, width: band.width, height: band.height }} />
      )}
      {menu && <ContextMenu x={menu.x} y={menu.y} items={menu.items} onClose={() => setMenu(null)} />}
    </div>
  );
}
