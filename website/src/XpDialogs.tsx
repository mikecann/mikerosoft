import { useEffect, type ReactNode } from 'react';

function useKeys(handlers: Record<string, () => void>) {
  useEffect(() => {
    const handle = (event: KeyboardEvent) => handlers[event.key]?.();
    window.addEventListener('keydown', handle);
    return () => window.removeEventListener('keydown', handle);
  }, [handlers]);
}

function Overlay({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  return (
    <div className="overlay" onPointerDown={event => event.target === event.currentTarget && onClose()}>
      {children}
    </div>
  );
}

export function MessageDialog({
  title,
  icon = '/xp/help.png',
  children,
  onClose,
}: {
  title: string;
  icon?: string;
  children: ReactNode;
  onClose: () => void;
}) {
  useKeys({ Escape: onClose });

  return (
    <Overlay onClose={onClose}>
      <div className="window dialog" role="alertdialog" aria-modal="true" aria-label={title}>
        <div className="title-bar">
          <div className="title-bar-text"><span>{title}</span></div>
          <div className="title-bar-controls">
            <button type="button" aria-label="Close" onClick={onClose} />
          </div>
        </div>
        <div className="window-body dialog-body">
          <img src={icon} alt="" />
          <div>{children}</div>
        </div>
        <div className="dialog-buttons">
          <button type="button" onClick={onClose} autoFocus>OK</button>
        </div>
      </div>
    </Overlay>
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
  const step = (by: number) => onIndexChange((index + by + images.length) % images.length);
  useKeys({ Escape: onClose, ArrowLeft: () => step(-1), ArrowRight: () => step(1) });

  return (
    <Overlay onClose={onClose}>
      <div className="window viewer" role="dialog" aria-modal="true" aria-label="Picture viewer">
        <div className="title-bar">
          <div className="title-bar-text">
            <img src="/xp/search.png" alt="" />
            <span>{images[index].split('/').pop()} - Windows Picture and Fax Viewer</span>
          </div>
          <div className="title-bar-controls">
            <button type="button" aria-label="Close" onClick={onClose} />
          </div>
        </div>
        <div className="viewer-image">
          <img src={images[index]} alt="" />
        </div>
        {images.length > 1 && (
          <div className="viewer-nav">
            <button type="button" onClick={() => step(-1)}>‹ Previous</button>
            <span>{index + 1} of {images.length}</span>
            <button type="button" onClick={() => step(1)}>Next ›</button>
          </div>
        )}
      </div>
    </Overlay>
  );
}
