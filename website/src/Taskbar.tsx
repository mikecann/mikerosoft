import { useEffect, useRef, useState } from 'react';
import { Link } from './router';
import { PlatformButtons, type PlatformFilter } from './Sidebar';
import { toolPath } from './toolPages';
import { groupToolsByCategory, type Tool } from './tools';

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
  tools,
  query,
  onQueryChange,
  platform,
  onPlatformChange,
  onClose,
  onShutDown,
}: {
  tools: Tool[];
  query: string;
  onQueryChange: (query: string) => void;
  platform: PlatformFilter;
  onPlatformChange: (platform: PlatformFilter) => void;
  onClose: () => void;
  onShutDown: () => void;
}) {
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    menuRef.current?.querySelector<HTMLInputElement>('input')?.focus();
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    const handleClick = (event: MouseEvent) => {
      const target = event.target as Element;
      if (!menuRef.current?.contains(target) && !target.closest('.start-button')) onClose();
    };
    window.addEventListener('keydown', handleKey);
    window.addEventListener('mousedown', handleClick);
    return () => {
      window.removeEventListener('keydown', handleKey);
      window.removeEventListener('mousedown', handleClick);
    };
  }, [onClose]);

  return (
    <div className="window start-menu" role="dialog" aria-label="Start menu" ref={menuRef}>
      <div className="start-band"><span>Mikerosoft<b>95</b></span></div>
      <div className="start-main">
        <div className="start-head">
          <input
            className="field"
            type="search"
            placeholder="Find a tool..."
            aria-label="Find a tool"
            value={query}
            onChange={event => onQueryChange(event.target.value)}
          />
          <PlatformButtons value={platform} onChange={onPlatformChange} />
        </div>
        <div className="start-list scroll">
          {groupToolsByCategory(tools).map(group => (
            <div key={group.category}>
              <div className="start-category">{group.category}</div>
              {group.tools.map(tool => (
                <Link key={tool.name} href={toolPath(tool.name)} className="start-item" onClick={onClose} title={tool.desc}>
                  <img src={tool.icon} alt="" />
                  <span>{tool.name}</span>
                </Link>
              ))}
            </div>
          ))}
          {tools.length === 0 && <p className="tree-empty">Nothing matches that. Try another word.</p>}
        </div>
        <div className="start-foot">
          <Link href="/" className="start-item" onClick={onClose}>
            <img src="/logo.png" alt="" />
            My Tools
          </Link>
          <button type="button" className="start-item" onClick={onShutDown}>
            <span className="power" />
            Shut Down...
          </button>
        </div>
      </div>
    </div>
  );
}

export function Taskbar({
  tools,
  query,
  onQueryChange,
  platform,
  onPlatformChange,
  windowTitle,
  windowIcon,
  isMinimised,
  onToggleWindow,
  onShutDown,
}: {
  tools: Tool[];
  query: string;
  onQueryChange: (query: string) => void;
  platform: PlatformFilter;
  onPlatformChange: (platform: PlatformFilter) => void;
  windowTitle: string;
  windowIcon: string;
  isMinimised: boolean;
  onToggleWindow: () => void;
  onShutDown: () => void;
}) {
  const [startOpen, setStartOpen] = useState(false);
  const time = useClock();

  return (
    <>
      {startOpen && (
        <StartMenu
          tools={tools}
          query={query}
          onQueryChange={onQueryChange}
          platform={platform}
          onPlatformChange={onPlatformChange}
          onClose={() => setStartOpen(false)}
          onShutDown={() => {
            setStartOpen(false);
            onShutDown();
          }}
        />
      )}
      <div className="taskbar">
        <button
          type="button"
          className="btn start-button"
          aria-pressed={startOpen}
          aria-expanded={startOpen}
          onClick={() => setStartOpen(open => !open)}
        >
          <img src="/logo.png" alt="" />
          Start
        </button>
        <button type="button" className="btn task-button" aria-pressed={!isMinimised} onClick={onToggleWindow}>
          <img src={windowIcon} alt="" />
          <span>{windowTitle}</span>
        </button>
        <div className="taskbar-spacer" />
        <div className="tray">{time}</div>
      </div>
    </>
  );
}
