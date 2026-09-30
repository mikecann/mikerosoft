import { useEffect, type ReactNode } from 'react';

// The pixel X from a Windows 95 close button, one rect per run of pixels.
const CLOSE_RUNS = [[0, 0, 2], [6, 0, 2], [1, 1, 2], [5, 1, 2], [2, 2, 4], [3, 3, 2], [2, 4, 4], [1, 5, 2], [5, 5, 2], [0, 6, 2], [6, 6, 2]];

export function CloseGlyph() {
  return (
    <svg width="8" height="7" viewBox="0 0 8 7" aria-hidden="true">
      {CLOSE_RUNS.map(([x, y, w]) => <rect key={`${x}-${y}`} x={x} y={y} width={w} height="1" />)}
    </svg>
  );
}

export function MinimiseGlyph() {
  return (
    <svg width="8" height="7" viewBox="0 0 8 7" aria-hidden="true">
      <rect x="0" y="5" width="6" height="2" />
    </svg>
  );
}

export function TitleBar({
  icon,
  title,
  inactive,
  onMinimise,
  onClose,
  closeLabel = 'Close',
}: {
  icon?: string;
  title: ReactNode;
  inactive?: boolean;
  onMinimise?: () => void;
  onClose?: () => void;
  closeLabel?: string;
}) {
  return (
    <div className="titlebar" data-inactive={inactive || undefined}>
      {icon && <img src={icon} alt="" />}
      <span className="titlebar-text">{title}</span>
      {(onMinimise || onClose) && (
        <div className="titlebar-buttons">
          {onMinimise && (
            <button type="button" className="tbtn" onClick={onMinimise} aria-label="Minimise">
              <MinimiseGlyph />
            </button>
          )}
          {onClose && (
            <button type="button" className="tbtn" data-close onClick={onClose} aria-label={closeLabel}>
              <CloseGlyph />
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function useEscape(onEscape: () => void) {
  useEffect(() => {
    const handle = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onEscape();
    };
    window.addEventListener('keydown', handle);
    return () => window.removeEventListener('keydown', handle);
  }, [onEscape]);
}

export function MessageBox({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  useEscape(onClose);

  return (
    <div className="overlay" onClick={event => event.target === event.currentTarget && onClose()}>
      <div className="window message" role="alertdialog" aria-modal="true" aria-label={title}>
        <TitleBar title={title} onClose={onClose} />
        <div className="message-body">
          <img src="/logo.png" alt="" />
          <div>{children}</div>
        </div>
        <div className="message-foot">
          <button type="button" className="btn btn-default" onClick={onClose} autoFocus>OK</button>
        </div>
      </div>
    </div>
  );
}

export function ImageViewer({
  images,
  index,
  onIndexChange,
  onClose,
}: {
  images: string[];
  index: number;
  onIndexChange: (index: number) => void;
  onClose: () => void;
}) {
  useEscape(onClose);
  const step = (by: number) => onIndexChange((index + by + images.length) % images.length);

  useEffect(() => {
    const handle = (event: KeyboardEvent) => {
      if (images.length < 2) return;
      if (event.key === 'ArrowLeft') onIndexChange((index - 1 + images.length) % images.length);
      if (event.key === 'ArrowRight') onIndexChange((index + 1) % images.length);
    };
    window.addEventListener('keydown', handle);
    return () => window.removeEventListener('keydown', handle);
  }, [images.length, index, onIndexChange]);

  return (
    <div className="overlay" onClick={event => event.target === event.currentTarget && onClose()}>
      <div className="window viewer" role="dialog" aria-modal="true" aria-label="Image viewer">
        <TitleBar title={`Image Viewer - ${images[index].split('/').pop()}`} onClose={onClose} />
        <div className="viewer-image">
          <img src={images[index]} alt="" />
        </div>
        {images.length > 1 && (
          <div className="viewer-nav">
            <button type="button" className="btn btn-small" onClick={() => step(-1)}>‹ Previous</button>
            <span>{index + 1} of {images.length}</span>
            <button type="button" className="btn btn-small" onClick={() => step(1)}>Next ›</button>
          </div>
        )}
      </div>
    </div>
  );
}
