import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

export type MenuItem =
  | { kind: 'separator' }
  | { kind?: 'item'; label: string; onSelect: () => void; disabled?: boolean; bold?: boolean; checked?: boolean };

/** A Windows XP right-click menu. It keeps itself on screen and closes on Escape or a click elsewhere. */
export function ContextMenu({
  x,
  y,
  items,
  onClose,
}: {
  x: number;
  y: number;
  items: MenuItem[];
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: x, top: y });

  useLayoutEffect(() => {
    const rect = ref.current?.getBoundingClientRect();
    if (!rect) return;
    setPosition({
      left: Math.max(0, Math.min(x, window.innerWidth - rect.width - 2)),
      top: Math.max(0, Math.min(y, window.innerHeight - rect.height - 2)),
    });
    ref.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
  }, [x, y]);

  useEffect(() => {
    const handleDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) onClose();
    };
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
      if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
      event.preventDefault();
      const buttons = [...(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])];
      const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
      const next = event.key === 'ArrowDown' ? index + 1 : index - 1;
      buttons[(next + buttons.length) % buttons.length]?.focus();
    };
    window.addEventListener('pointerdown', handleDown, true);
    window.addEventListener('keydown', handleKey);
    window.addEventListener('blur', onClose);
    return () => {
      window.removeEventListener('pointerdown', handleDown, true);
      window.removeEventListener('keydown', handleKey);
      window.removeEventListener('blur', onClose);
    };
  }, [onClose]);

  // Rendered on the page itself so it sits above every window, wherever it was opened from.
  return createPortal(
    <div
      ref={ref}
      className="context-menu"
      role="menu"
      style={position}
      onContextMenu={event => event.preventDefault()}
    >
      {items.map((item, i) => (
        item.kind === 'separator' ? (
          <hr key={i} />
        ) : (
          <button
            key={item.label}
            type="button"
            role="menuitem"
            className="plain context-menu-item"
            disabled={item.disabled}
            data-bold={item.bold || undefined}
            onClick={() => {
              onClose();
              item.onSelect();
            }}
          >
            <span className="context-menu-check">{item.checked ? '✓' : ''}</span>
            {item.label}
          </button>
        )
      ))}
    </div>,
    document.body,
  );
}
