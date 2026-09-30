import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { ContextMenu, type MenuItem } from './ContextMenu';
import { Link } from './router';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolPath } from './toolPages';
import { CATEGORY_ICON, CATEGORY_ORDER, groupToolsByCategory, tools, type Category, type Tool } from './tools';

export interface TaskbarItem {
  id: string;
  title: string;
  icon: string;
  isActive: boolean;
  isMinimised: boolean;
  isMaximised: boolean;
}

export interface WindowActions {
  onActivate: (id: string) => void;
  onRestore: (id: string) => void;
  onMinimise: (id: string) => void;
  onMaximise: (id: string) => void;
  onClose: (id: string) => void;
}

/** Re-renders on the minute (or second), lined up with the real clock. */
export function useNow(every: 'second' | 'minute' = 'minute'): Date {
  const [now, setNow] = useState(() => new Date());

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      const date = new Date();
      setNow(date);
      const wait = every === 'second' ? 1000 - date.getMilliseconds() : 60_000 - (date.getSeconds() * 1000 + date.getMilliseconds());
      timer = setTimeout(tick, wait + 5);
    };
    tick();
    return () => clearTimeout(timer);
  }, [every]);

  return now;
}

/** Arrow keys move between a menu's items, like the real Start menu. */
function moveFocus(event: KeyboardEvent<HTMLElement>) {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  const items = [...event.currentTarget.querySelectorAll<HTMLElement>('.start-item')];
  const index = items.indexOf(document.activeElement as HTMLElement);
  const next = event.key === 'ArrowDown' ? index + 1 : index - 1;
  items[(next + items.length) % items.length]?.focus();
}

function AllPrograms({ onClose }: { onClose: () => void }) {
  const [openCategory, setOpenCategory] = useState<Category | null>(null);

  return (
    <div className="all-programs-menu" role="menu" aria-label="All Programs" onKeyDown={moveFocus}>
      {groupToolsByCategory(tools).map(group => (
        <div
          key={group.category}
          className="cascade"
          onPointerEnter={() => setOpenCategory(group.category)}
        >
          <button
            type="button"
            className="plain start-item cascade-item"
            role="menuitem"
            aria-haspopup="menu"
            aria-expanded={openCategory === group.category}
            onClick={() => setOpenCategory(group.category)}
            onFocus={() => setOpenCategory(group.category)}
          >
            <img src={CATEGORY_ICON[group.category]} alt="" />
            <span>{group.category}</span>
            <span className="cascade-arrow" aria-hidden="true">▶</span>
          </button>
          {openCategory === group.category && (
            <div className="cascade-menu" role="menu" aria-label={group.category} onKeyDown={moveFocus}>
              {group.tools.map(tool => (
                <Link key={tool.name} href={toolPath(tool.name)} className="start-item" role="menuitem" onClick={onClose}>
                  <img src={tool.icon} alt="" />
                  <span>{tool.name}</span>
                </Link>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function StartMenu({
  recent,
  onClose,
  onOpenHome,
  onOpenGithub,
  onShowCategory,
  onSearch,
  onSurprise,
  onRun,
  onHelp,
  onLogOff,
  onTurnOff,
}: {
  recent: Tool[];
  onClose: () => void;
  onOpenHome: () => void;
  onOpenGithub: () => void;
  onShowCategory: (category: Category) => void;
  onSearch: () => void;
  onSurprise: () => void;
  onRun: () => void;
  onHelp: () => void;
  onLogOff: () => void;
  onTurnOff: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [allPrograms, setAllPrograms] = useState(false);
  const hoverTimer = useRef<ReturnType<typeof setTimeout>>();

  useEffect(() => {
    ref.current?.querySelector<HTMLElement>('.start-item')?.focus();
    const handleKey = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    const handleDown = (event: PointerEvent) => {
      const target = event.target as Element;
      if (!ref.current?.contains(target) && !target.closest('.start-button')) onClose();
    };
    window.addEventListener('keydown', handleKey);
    window.addEventListener('pointerdown', handleDown);
    return () => {
      window.removeEventListener('keydown', handleKey);
      window.removeEventListener('pointerdown', handleDown);
      clearTimeout(hoverTimer.current);
    };
  }, [onClose]);

  // Like XP, All Programs opens when you rest on it, and closes when you move to something else.
  const hover = (open: boolean) => () => {
    clearTimeout(hoverTimer.current);
    hoverTimer.current = setTimeout(() => setAllPrograms(open), open ? 250 : 400);
  };

  const then = (action: () => void) => () => {
    onClose();
    action();
  };

  return (
    <div className="start-menu" ref={ref} role="dialog" aria-label="Start menu">
      <div className="start-head">
        <img src="/logo.png" alt="" />
        <span>Mike Cann</span>
      </div>
      <div className="start-columns">
        <div className="start-left" onKeyDown={moveFocus} onPointerEnter={hover(false)}>
          <button type="button" className="plain start-item start-item-big" onClick={then(onOpenHome)}>
            <img src="/logo.png" alt="" />
            <span><strong>Mikerosoft</strong><small>Every tool in one place</small></span>
          </button>
          <button type="button" className="plain start-item start-item-big" onClick={then(onOpenGithub)}>
            <img src="/xp/github.png" alt="" />
            <span><strong>GitHub</strong><small>All the source code</small></span>
          </button>
          <hr />
          {recent.map(tool => (
            <Link key={tool.name} href={toolPath(tool.name)} className="start-item" onClick={onClose}>
              <img src={tool.icon} alt="" />
              <span>{tool.name}</span>
            </Link>
          ))}
          <hr />
          <button
            type="button"
            className="plain start-item all-programs"
            aria-expanded={allPrograms}
            aria-haspopup="menu"
            onClick={() => setAllPrograms(open => !open)}
            onPointerEnter={hover(true)}
            onKeyDown={event => {
              if (event.key === 'ArrowRight') {
                setAllPrograms(true);
                setTimeout(() => ref.current?.querySelector<HTMLElement>('.all-programs-menu .start-item')?.focus());
              }
            }}
          >
            <span>All Programs</span>
            <img src="/xp/all-programs.ico" alt="" />
          </button>
        </div>
        <div className="start-right" onKeyDown={moveFocus} onPointerEnter={hover(false)}>
          <button type="button" className="plain start-item start-item-bold" onClick={then(onOpenHome)}>
            <img src="/xp/folder.png" alt="" />
            <span>My Tools</span>
          </button>
          {CATEGORY_ORDER.map(category => (
            <button key={category} type="button" className="plain start-item" onClick={then(() => onShowCategory(category))}>
              <img src={CATEGORY_ICON[category]} alt="" />
              <span>{category}</span>
            </button>
          ))}
          <hr />
          <button type="button" className="plain start-item" onClick={then(onSurprise)}>
            <img src="/icons/ui-get.png" alt="" />
            <span>Surprise me</span>
          </button>
          <button type="button" className="plain start-item" onClick={then(onHelp)}>
            <img src="/xp/help.png" alt="" />
            <span>Help and Support</span>
          </button>
          <button type="button" className="plain start-item" onClick={then(onSearch)}>
            <img src="/xp/search.png" alt="" />
            <span>Search</span>
          </button>
          <button type="button" className="plain start-item" onClick={then(onRun)}>
            <img src="/xp/run.png" alt="" />
            <span>Run...</span>
          </button>
        </div>
        {allPrograms && (
          <div onPointerEnter={() => clearTimeout(hoverTimer.current)}>
            <AllPrograms onClose={onClose} />
          </div>
        )}
      </div>
      <div className="start-foot">
        <button type="button" className="plain start-foot-button" onClick={then(onLogOff)}>
          <img src="/xp/logoff.png" alt="" />
          Log Off
        </button>
        <button type="button" className="plain start-foot-button" onClick={then(onTurnOff)}>
          <img src="/xp/shutdown.png" alt="" />
          Turn Off Computer
        </button>
      </div>
    </div>
  );
}

const BALLOON_SEEN_KEY = 'mikerosoft:updates-balloon-seen';

/** The tray icon for what's new. Like XP, its balloon pops up once by itself, then only when you click. */
function TrayUpdates() {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const latest = [...tools]
    .filter(tool => TOOL_DATES[tool.name])
    .sort((a, b) => Date.parse(TOOL_DATES[b.name].updated) - Date.parse(TOOL_DATES[a.name].updated))
    .slice(0, 3);

  useEffect(() => {
    let seen = false;
    try {
      seen = sessionStorage.getItem(BALLOON_SEEN_KEY) === '1';
      sessionStorage.setItem(BALLOON_SEEN_KEY, '1');
    } catch {
      // No storage means it just shows again next time.
    }
    if (seen) return;
    const show = setTimeout(() => setOpen(true), 2500);
    const hide = setTimeout(() => setOpen(false), 14_000);
    return () => {
      clearTimeout(show);
      clearTimeout(hide);
    };
  }, []);

  useEffect(() => {
    if (!open) return;
    const handleDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener('pointerdown', handleDown);
    return () => window.removeEventListener('pointerdown', handleDown);
  }, [open]);

  return (
    <div className="tray-updates" ref={ref}>
      <button
        type="button"
        className="plain tray-icon"
        title="What's new"
        aria-label="What's new"
        aria-expanded={open}
        onClick={() => setOpen(value => !value)}
      >
        <img src="/icons/ui-changes.png" alt="" />
      </button>
      {open && (
        <div className="balloon" role="status">
          <button type="button" className="plain balloon-close" aria-label="Close" onClick={() => setOpen(false)}>×</button>
          <p className="balloon-title"><img src="/icons/ui-changes.png" alt="" />Recently updated</p>
          <ul>
            {latest.map(tool => (
              <li key={tool.name}>
                <Link href={toolPath(tool.name)} onClick={() => setOpen(false)}>
                  <img src={tool.icon} alt="" />
                  <span><strong>{tool.name}</strong> {formatToolDate(TOOL_DATES[tool.name].updated)}</span>
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function Clock({ onOpen }: { onOpen: () => void }) {
  const now = useNow();
  const time = now.toLocaleTimeString('en-AU', { hour: 'numeric', minute: '2-digit' }).toUpperCase();
  const date = now.toLocaleDateString('en-AU', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });

  return (
    <button type="button" className="plain tray-clock" title={date} onDoubleClick={onOpen} onClick={onOpen}>
      <time dateTime={now.toISOString()}>{time}</time>
    </button>
  );
}

export function Taskbar({
  items,
  actions,
  recent,
  startOpen,
  onStartOpenChange,
  onShowDesktop,
  onOpenHome,
  onOpenGithub,
  onShowCategory,
  onSearch,
  onSurprise,
  onRun,
  onHelp,
  onLogOff,
  onTurnOff,
  onOpenClock,
}: {
  items: TaskbarItem[];
  actions: WindowActions;
  recent: Tool[];
  startOpen: boolean;
  onStartOpenChange: (open: boolean) => void;
  onShowDesktop: () => void;
  onOpenHome: () => void;
  onOpenGithub: () => void;
  onShowCategory: (category: Category) => void;
  onSearch: () => void;
  onSurprise: () => void;
  onRun: () => void;
  onHelp: () => void;
  onLogOff: () => void;
  onTurnOff: () => void;
  onOpenClock: () => void;
}) {
  const [menu, setMenu] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);

  function windowMenu(item: TaskbarItem, x: number, y: number) {
    setMenu({
      x,
      y,
      items: [
        { label: 'Restore', onSelect: () => actions.onRestore(item.id), disabled: !item.isMinimised && !item.isMaximised },
        { label: 'Minimize', onSelect: () => actions.onMinimise(item.id), disabled: item.isMinimised },
        { label: 'Maximize', onSelect: () => actions.onMaximise(item.id), disabled: item.isMaximised && !item.isMinimised },
        { kind: 'separator' },
        { label: 'Close', bold: true, onSelect: () => actions.onClose(item.id) },
      ],
    });
  }

  return (
    <>
      {startOpen && (
        <StartMenu
          recent={recent}
          onClose={() => onStartOpenChange(false)}
          onOpenHome={onOpenHome}
          onOpenGithub={onOpenGithub}
          onShowCategory={onShowCategory}
          onSearch={onSearch}
          onSurprise={onSurprise}
          onRun={onRun}
          onHelp={onHelp}
          onLogOff={onLogOff}
          onTurnOff={onTurnOff}
        />
      )}
      <footer className="taskbar" onContextMenu={event => event.preventDefault()}>
        <button
          type="button"
          className="plain start-button"
          aria-expanded={startOpen}
          aria-pressed={startOpen}
          onClick={() => onStartOpenChange(!startOpen)}
        >
          <img src="/logo.png" alt="" />
          start
        </button>
        <div className="quick-launch" role="toolbar" aria-label="Quick Launch">
          <button type="button" className="plain quick-launch-button" title="Show Desktop" aria-label="Show Desktop" onClick={onShowDesktop}>
            <img src="/icons/ui-desktop.png" alt="" />
          </button>
          <button type="button" className="plain quick-launch-button" title="Mikerosoft" aria-label="Mikerosoft" onClick={onOpenHome}>
            <img src="/logo.png" alt="" />
          </button>
          <button type="button" className="plain quick-launch-button" title="GitHub" aria-label="GitHub" onClick={onOpenGithub}>
            <img src="/xp/github.png" alt="" />
          </button>
        </div>
        <div className="task-buttons">
          {items.map(item => (
            <button
              key={item.id}
              type="button"
              className="plain task-button"
              aria-pressed={item.isActive}
              title={item.title}
              onClick={() => actions.onActivate(item.id)}
              onAuxClick={event => {
                if (event.button === 1) actions.onClose(item.id);
              }}
              onContextMenu={event => {
                event.preventDefault();
                windowMenu(item, event.clientX, event.clientY);
              }}
            >
              <img src={item.icon} alt="" />
              <span>{item.title}</span>
            </button>
          ))}
        </div>
        <div className="tray">
          <TrayUpdates />
          <Clock onOpen={onOpenClock} />
        </div>
      </footer>
      {menu && <ContextMenu x={menu.x} y={menu.y} items={menu.items} onClose={() => setMenu(null)} />}
    </>
  );
}
