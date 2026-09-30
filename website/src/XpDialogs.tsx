import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { useNow } from './Taskbar';

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

function DialogFrame({
  title,
  icon,
  className,
  onClose,
  children,
}: {
  title: string;
  icon?: string;
  className?: string;
  onClose: () => void;
  children: ReactNode;
}) {
  useKeys({ Escape: onClose });

  return (
    <Overlay onClose={onClose}>
      <div className={`window dialog ${className ?? ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="title-bar">
          <div className="title-bar-text">
            {icon && <img src={icon} alt="" />}
            <span>{title}</span>
          </div>
          <div className="title-bar-controls">
            <button type="button" aria-label="Close" onClick={onClose} />
          </div>
        </div>
        {children}
      </div>
    </Overlay>
  );
}

function AnalogClock({ now }: { now: Date }) {
  const seconds = now.getSeconds();
  const minutes = now.getMinutes() + seconds / 60;
  const hours = (now.getHours() % 12) + minutes / 60;
  const hand = (turns: number, length: number, width: number, colour: string) => (
    <line
      x1="50"
      y1="50"
      x2={50 + Math.sin(turns * 2 * Math.PI) * length}
      y2={50 - Math.cos(turns * 2 * Math.PI) * length}
      stroke={colour}
      strokeWidth={width}
      strokeLinecap="round"
    />
  );

  return (
    <svg viewBox="0 0 100 100" className="analog-clock" role="img" aria-label={now.toLocaleTimeString('en-AU')}>
      <circle cx="50" cy="50" r="46" fill="#fff" stroke="#7f9db9" strokeWidth="2" />
      {Array.from({ length: 12 }, (_, i) => (
        <circle
          key={i}
          cx={50 + Math.sin((i / 12) * 2 * Math.PI) * 40}
          cy={50 - Math.cos((i / 12) * 2 * Math.PI) * 40}
          r={i % 3 === 0 ? 2.6 : 1.4}
          fill={i % 3 === 0 ? '#0a246a' : '#6b7fb8'}
        />
      ))}
      {hand(hours / 12, 22, 4, '#0a246a')}
      {hand(minutes / 60, 32, 3, '#0a246a')}
      {hand(seconds / 60, 36, 1.2, '#d42a2a')}
      <circle cx="50" cy="50" r="3" fill="#0a246a" />
    </svg>
  );
}

function Calendar({ now }: { now: Date }) {
  const year = now.getFullYear();
  const month = now.getMonth();
  const firstDay = (new Date(year, month, 1).getDay() + 6) % 7;
  const days = new Date(year, month + 1, 0).getDate();
  const cells = [...Array.from({ length: firstDay }, () => 0), ...Array.from({ length: days }, (_, i) => i + 1)];

  return (
    <div className="calendar">
      <p className="calendar-month">{now.toLocaleDateString('en-AU', { month: 'long', year: 'numeric' })}</p>
      <div className="calendar-grid">
        {['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((day, i) => <b key={i}>{day}</b>)}
        {cells.map((day, i) => (
          <span key={i} data-today={day === now.getDate() || undefined}>{day || ''}</span>
        ))}
      </div>
    </div>
  );
}

export function DateTimeDialog({ onClose }: { onClose: () => void }) {
  const now = useNow('second');
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  return (
    <DialogFrame title="Date and Time Properties" icon="/icons/ui-calendar.png" className="datetime" onClose={onClose}>
      <div className="window-body">
        <menu role="tablist">
          <li role="tab" aria-selected="true"><a href="#date-time">Date &amp; Time</a></li>
        </menu>
        <div className="window" role="tabpanel" id="date-time">
          <div className="window-body datetime-body">
            <fieldset>
              <legend>Date</legend>
              <Calendar now={now} />
            </fieldset>
            <fieldset>
              <legend>Time</legend>
              <AnalogClock now={now} />
              <p className="datetime-digital">{now.toLocaleTimeString('en-AU')}</p>
            </fieldset>
          </div>
        </div>
        <p className="datetime-zone">Current time zone: {zone.replace(/_/g, ' ')}</p>
      </div>
      <div className="dialog-buttons">
        <button type="button" onClick={onClose} autoFocus>OK</button>
      </div>
    </DialogFrame>
  );
}

export function RunDialog({
  names,
  onRun,
  onClose,
}: {
  names: string[];
  onRun: (name: string) => boolean;
  onClose: () => void;
}) {
  const [value, setValue] = useState('');
  const [error, setError] = useState('');

  function submit(event: FormEvent) {
    event.preventDefault();
    const name = value.trim().toLowerCase().replace(/\.exe$/, '');
    if (!name) return;
    if (onRun(name)) onClose();
    else setError(`Windows cannot find '${value.trim()}'. Make sure you typed the name correctly, and then try again.`);
  }

  return (
    <DialogFrame title="Run" icon="/xp/run.png" className="run" onClose={onClose}>
      <form className="window-body run-body" onSubmit={submit}>
        <div className="run-intro">
          <img src="/xp/run.png" alt="" />
          <p>Type the name of a tool, and Mikerosoft will open it for you.</p>
        </div>
        <div className="field-row">
          <label htmlFor="run-input">Open:</label>
          <input
            id="run-input"
            list="run-tools"
            autoFocus
            value={value}
            onChange={event => {
              setValue(event.target.value);
              setError('');
            }}
          />
          <datalist id="run-tools">
            {names.map(name => <option key={name} value={name} />)}
          </datalist>
        </div>
        {error && <p className="run-error" role="alert">{error}</p>}
        <div className="dialog-buttons">
          <button type="submit">OK</button>
          <button type="button" onClick={onClose}>Cancel</button>
        </div>
      </form>
    </DialogFrame>
  );
}

export type PowerChoice = 'stand-by' | 'turn-off' | 'restart';

export function TurnOffDialog({ onChoose, onClose }: { onChoose: (choice: PowerChoice) => void; onClose: () => void }) {
  useKeys({ Escape: onClose });

  return (
    <Overlay onClose={onClose}>
      <div className="turn-off" role="dialog" aria-modal="true" aria-label="Turn off computer">
        <div className="turn-off-head">
          <span>Turn off computer</span>
          <img src="/logo.png" alt="" />
        </div>
        <div className="turn-off-body">
          <button type="button" className="plain turn-off-choice" data-choice="stand-by" onClick={() => onChoose('stand-by')}>
            <span className="turn-off-orb" aria-hidden="true">☾</span>
            Stand By
          </button>
          <button type="button" className="plain turn-off-choice" data-choice="turn-off" onClick={() => onChoose('turn-off')} autoFocus>
            <span className="turn-off-orb" aria-hidden="true">⏻</span>
            Turn Off
          </button>
          <button type="button" className="plain turn-off-choice" data-choice="restart" onClick={() => onChoose('restart')}>
            <span className="turn-off-orb" aria-hidden="true">↻</span>
            Restart
          </button>
        </div>
        <div className="turn-off-foot">
          <button type="button" onClick={onClose}>Cancel</button>
        </div>
      </div>
    </Overlay>
  );
}

/** The black screens after Stand By or Turn Off. Any click or key brings the desktop back. */
export function PowerScreen({ choice, onWake }: { choice: PowerChoice; onWake: () => void }) {
  useEffect(() => {
    // Restart just blinks, then comes back by itself.
    if (choice === 'restart') {
      const id = setTimeout(onWake, 1800);
      return () => clearTimeout(id);
    }
    const handle = () => onWake();
    const id = setTimeout(() => {
      window.addEventListener('keydown', handle);
      window.addEventListener('pointerdown', handle);
    }, 300);
    return () => {
      clearTimeout(id);
      window.removeEventListener('keydown', handle);
      window.removeEventListener('pointerdown', handle);
    };
  }, [choice, onWake]);

  return (
    <div className="power-screen" data-choice={choice} role="status">
      {choice === 'turn-off' && <p>It's now safe to turn off<br />your computer.</p>}
      {choice === 'restart' && (
        <div className="boot">
          <img src="/logo.png" alt="" />
          <p>Mikerosoft<sup>®</sup></p>
          <div className="boot-bar"><span /><span /><span /></div>
        </div>
      )}
      {choice !== 'restart' && <small>Click anywhere to come back</small>}
    </div>
  );
}
