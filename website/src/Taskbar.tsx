import { useEffect, useRef, useState } from 'react';
import { Link } from './router';
import { toolPath } from './toolPages';
import { CATEGORY_ORDER, groupToolsByCategory, tools, type Category } from './tools';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';
// Pinned to the top of the Start menu, like the programs XP put there.
const PINNED = ['tandem', 'record-it', 'voice-type', 'taskbar', 'task-stats', 'telemprompit'];

export interface TaskbarItem {
  id: string;
  title: string;
  icon: string;
  isActive: boolean;
}

function useClock(): string {
  const format = () => new Date().toLocaleTimeString('en-AU', { hour: 'numeric', minute: '2-digit' }).toUpperCase();
  const [time, setTime] = useState(format);

  useEffect(() => {
    const id = setInterval(() => setTime(format()), 10_000);
    return () => clearInterval(id);
  }, []);

  return time;
}

function StartMenu({
  onClose,
  onOpenHome,
  onShowCategory,
  onSurprise,
  onHelp,
  onLogOff,
  onTurnOff,
}: {
  onClose: () => void;
  onOpenHome: () => void;
  onShowCategory: (category: Category) => void;
  onSurprise: () => void;
  onHelp: () => void;
  onLogOff: () => void;
  onTurnOff: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [allPrograms, setAllPrograms] = useState(false);
  const pinned = PINNED.map(name => tools.find(tool => tool.name === name)).filter(tool => tool !== undefined);

  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
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
    };
  }, [onClose]);

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
        <div className="start-left">
          <button type="button" className="plain start-item start-item-big" onClick={then(onOpenHome)}>
            <img src="/logo.png" alt="" />
            <span><strong>Mikerosoft</strong><small>Every tool in one place</small></span>
          </button>
          <a className="start-item start-item-big" href={REPO_URL} target="_blank" rel="noopener" onClick={onClose}>
            <img src="/xp/github.png" alt="" />
            <span><strong>GitHub</strong><small>All the source code</small></span>
          </a>
          <hr />
          {pinned.map(tool => (
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
            onClick={() => setAllPrograms(open => !open)}
          >
            <span>All Programs</span>
            <img src="/xp/all-programs.ico" alt="" />
          </button>
        </div>
        <div className="start-right">
          {CATEGORY_ORDER.map(category => (
            <button key={category} type="button" className="plain start-item" onClick={then(() => onShowCategory(category))}>
              <img src="/xp/folder.png" alt="" />
              <span>{category}</span>
            </button>
          ))}
          <hr />
          <button type="button" className="plain start-item" onClick={then(onSurprise)}>
            <img src="/xp/run.png" alt="" />
            <span>Surprise me</span>
          </button>
          <button type="button" className="plain start-item" onClick={then(onHelp)}>
            <img src="/xp/help.png" alt="" />
            <span>Help and Support</span>
          </button>
        </div>
        {allPrograms && (
          <div className="all-programs-menu" role="menu" aria-label="All programs">
            {groupToolsByCategory(tools).map(group => (
              <div key={group.category}>
                <p className="all-programs-category">{group.category}</p>
                {group.tools.map(tool => (
                  <Link key={tool.name} href={toolPath(tool.name)} className="start-item" onClick={onClose} role="menuitem">
                    <img src={tool.icon} alt="" />
                    <span>{tool.name}</span>
                  </Link>
                ))}
              </div>
            ))}
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

export function Taskbar({
  items,
  onItemClick,
  onOpenHome,
  onShowCategory,
  onSurprise,
  onHelp,
  onLogOff,
  onTurnOff,
}: {
  items: TaskbarItem[];
  onItemClick: (id: string) => void;
  onOpenHome: () => void;
  onShowCategory: (category: Category) => void;
  onSurprise: () => void;
  onHelp: () => void;
  onLogOff: () => void;
  onTurnOff: () => void;
}) {
  const [startOpen, setStartOpen] = useState(false);
  const time = useClock();

  return (
    <>
      {startOpen && (
        <StartMenu
          onClose={() => setStartOpen(false)}
          onOpenHome={onOpenHome}
          onShowCategory={onShowCategory}
          onSurprise={onSurprise}
          onHelp={onHelp}
          onLogOff={onLogOff}
          onTurnOff={onTurnOff}
        />
      )}
      <footer className="taskbar">
        <button
          type="button"
          className="plain start-button"
          aria-expanded={startOpen}
          aria-pressed={startOpen}
          onClick={() => setStartOpen(open => !open)}
        >
          <img src="/logo.png" alt="" />
          start
        </button>
        <div className="task-buttons">
          {items.map(item => (
            <button
              key={item.id}
              type="button"
              className="plain task-button"
              aria-pressed={item.isActive}
              onClick={() => onItemClick(item.id)}
            >
              <img src={item.icon} alt="" />
              <span>{item.title}</span>
            </button>
          ))}
        </div>
        <div className="tray">
          <img src="/xp/ie.png" alt="" />
          <span>{time}</span>
        </div>
      </footer>
    </>
  );
}
