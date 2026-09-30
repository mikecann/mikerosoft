import './xp.css';
import { useEffect, useState } from 'react';
import { Desktop, type DesktopItem } from './Desktop';
import { categoryId, HOME_SEARCH_ID, HomeContent, type PlatformFilter } from './HomeContent';
import { navigate, replacePath, useNavigation } from './router';
import { Taskbar } from './Taskbar';
import { ToolContent } from './ToolContent';
import { toolPath } from './toolPages';
import {
  CATEGORY_ORDER,
  filterToolsByPlatforms,
  groupToolsByCategory,
  PLATFORM_ORDER,
  searchTools,
  tools,
  type Category,
  type Tool,
} from './tools';
import {
  closeWindow,
  defaultGeometry,
  dialogGeometry,
  focusedWindow,
  focusWindow,
  maximiseWindow,
  minimiseAll,
  minimiseWindow,
  moveWindow,
  openWindow,
  pathForWindow,
  restoreWindow,
  restoreWindows,
  SMALL_SCREEN,
  toggleMaximise,
  windowForPath,
  type Desktop as DesktopState,
  type WindowId,
} from './windowManager';
import { DateTimeContent, MessageDialog, PowerScreen, RunDialog, TurnOffDialog, type PowerChoice } from './XpDialogs';
import { XpWindow } from './XpWindow';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';
const TASKBAR_HEIGHT = 36;
// Tools down the left edge of the desktop. The rest go down the right.
const LEFT_CATEGORIES: readonly Category[] = ['Video & recording', 'Images'];
const RECENT_KEY = 'mikerosoft:recent-tools';
const RECENT_COUNT = 6;
// What the Start menu shows before you've opened anything.
const DEFAULT_RECENT = ['tandem', 'record-it', 'voice-type', 'taskbar', 'task-stats', 'telemprompit'];

type Dialog = 'help' | 'log-off' | 'turn-off' | 'not-found' | 'run' | null;

const DATE_TIME: WindowId = 'app:datetime';

function geometryFor(id: WindowId, openCount: number) {
  const area = desktopArea();
  return id === DATE_TIME ? dialogGeometry(area, { width: 500, height: 470 }) : defaultGeometry(area, openCount);
}

function desktopArea() {
  return { width: window.innerWidth, height: window.innerHeight - TASKBAR_HEIGHT };
}

function toolFor(id: WindowId): Tool | undefined {
  return id === 'home' ? undefined : tools.find(tool => `tool:${tool.name}` === id);
}

/** Opens the Mikerosoft window, plus the tool in the address bar on top of it. */
function initialDesktop(): { desktop: DesktopState; dialog: Dialog } {
  const area = desktopArea();
  let desktop = openWindow({ windows: [] }, 'home', defaultGeometry(area, 0));
  const id = windowForPath(window.location.pathname);
  if (id && id !== 'home') desktop = openWindow(desktop, id, defaultGeometry(area, 1));
  return { desktop, dialog: id ? null : 'not-found' };
}

function readRecent(): string[] {
  try {
    const saved = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]') as string[];
    const known = saved.filter(name => tools.some(tool => tool.name === name));
    return [...known, ...DEFAULT_RECENT.filter(name => !known.includes(name))].slice(0, RECENT_COUNT);
  } catch {
    return DEFAULT_RECENT;
  }
}

function useArea() {
  const [area, setArea] = useState(desktopArea);
  useEffect(() => {
    const handle = () => setArea(desktopArea());
    window.addEventListener('resize', handle);
    return () => window.removeEventListener('resize', handle);
  }, []);
  return area;
}

const grouped = groupToolsByCategory(tools);
const desktopItems: DesktopItem[] = [
  { id: 'home', label: 'Mikerosoft', icon: '/logo.png', href: '/' },
  { id: 'github', label: 'GitHub', icon: '/xp/github.png', href: REPO_URL, external: true },
  ...grouped.flatMap(group => group.tools).map(tool => ({
    id: tool.name,
    label: tool.name,
    icon: tool.icon,
    href: toolPath(tool.name),
    sourceUrl: tool.url,
  })),
];
const leftIds = ['home', 'github', ...grouped.filter(g => LEFT_CATEGORIES.includes(g.category)).flatMap(g => g.tools.map(t => t.name))];
const rightIds = grouped.filter(g => !LEFT_CATEGORIES.includes(g.category)).flatMap(g => g.tools.map(t => t.name));

export default function App() {
  const area = useArea();
  const isSmallScreen = area.width < SMALL_SCREEN;
  const [{ desktop: initial, dialog: initialDialog }] = useState(initialDesktop);
  const [desktop, setDesktop] = useState<DesktopState>(initial);
  const [dialog, setDialog] = useState<Dialog>(initialDialog);
  const [power, setPower] = useState<PowerChoice | null>(null);
  const [startOpen, setStartOpen] = useState(false);
  // Clicking the desktop greys out every title bar, like XP.
  const [desktopActive, setDesktopActive] = useState(false);
  const [hiddenByShowDesktop, setHiddenByShowDesktop] = useState<WindowId[]>([]);
  const [recent, setRecent] = useState<string[]>(readRecent);
  const [query, setQuery] = useState('');
  const [platform, setPlatform] = useState<PlatformFilter>('all');

  /** The title and icon each window shows in its title bar and on the taskbar. */
  function windowInfo(id: WindowId): { title: string; taskTitle: string; icon: string } {
    const tool = toolFor(id);
    if (tool) return { title: `${tool.name} - Mikerosoft`, taskTitle: tool.name, icon: tool.icon };
    if (id === DATE_TIME) return { title: 'Date and Time Properties', taskTitle: 'Date and Time Properties', icon: '/icons/ui-calendar.png' };
    return { title: 'Mikerosoft', taskTitle: 'Mikerosoft', icon: '/logo.png' };
  }

  const topWindow = focusedWindow(desktop);
  const focused = desktopActive ? undefined : topWindow;
  const focusedTool = topWindow && toolFor(topWindow.id);
  const visibleTools = searchTools(
    filterToolsByPlatforms(tools, platform === 'all' ? PLATFORM_ORDER : [platform]),
    query,
  );

  function change(update: (current: DesktopState) => DesktopState) {
    setDesktopActive(false);
    setHiddenByShowDesktop([]);
    setDesktop(update);
  }

  function open(id: WindowId) {
    change(current => openWindow(current, id, geometryFor(id, current.windows.length)));
    const tool = toolFor(id);
    if (!tool) return;
    setRecent(current => {
      const next = [tool.name, ...current.filter(name => name !== tool.name)].slice(0, RECENT_COUNT);
      try {
        localStorage.setItem(RECENT_KEY, JSON.stringify(next));
      } catch {
        // Storage can be off. The Start menu just forgets.
      }
      return next;
    });
  }

  useNavigation(pathname => {
    const id = windowForPath(pathname);
    if (id) open(id);
    else setDialog('not-found');
  });

  // The address bar shows the page window in front, so it can be shared. App windows leave it alone.
  const topPath = topWindow && pathForWindow(topWindow.id);
  useEffect(() => {
    if (topPath) replacePath(topPath);
    document.title = focusedTool ? `${focusedTool.name} - Mikerosoft` : 'Mikerosoft';
  }, [topPath, focusedTool]);

  function openGithub() {
    window.open(REPO_URL, '_blank', 'noopener');
  }

  // Ctrl+Esc opens the Start menu, as it always has.
  useEffect(() => {
    const handle = (event: KeyboardEvent) => {
      if (event.ctrlKey && event.key === 'Escape') {
        event.preventDefault();
        setStartOpen(open => !open);
      }
    };
    window.addEventListener('keydown', handle);
    return () => window.removeEventListener('keydown', handle);
  }, []);

  function surprise() {
    const others = tools.filter(tool => tool !== focusedTool);
    navigate(toolPath(others[Math.floor(Math.random() * others.length)].name));
  }

  function showCategory(category: Category) {
    setQuery('');
    open('home');
    // Wait for the window to render before scrolling to the category.
    setTimeout(() => document.getElementById(categoryId(category))?.scrollIntoView({ behavior: 'smooth' }), 50);
  }

  function search() {
    open('home');
    setTimeout(() => document.getElementById(HOME_SEARCH_ID)?.focus(), 50);
  }

  function showDesktop() {
    if (hiddenByShowDesktop.length > 0) {
      const ids = hiddenByShowDesktop;
      setDesktop(current => restoreWindows(current, ids));
      setHiddenByShowDesktop([]);
      return;
    }
    const { desktop: hidden, hiddenIds } = minimiseAll(desktop);
    setDesktop(hidden);
    setHiddenByShowDesktop(hiddenIds);
  }

  function openDesktopItem(item: DesktopItem, inNewTab?: boolean) {
    if (item.external || inNewTab) window.open(item.href, '_blank', 'noopener');
    else navigate(item.href);
  }

  function choosePower(choice: PowerChoice) {
    setDialog(null);
    setPower(choice);
  }

  function wake() {
    if (power === 'restart') {
      // A fresh boot: just the Mikerosoft window, like when you first arrive.
      setDesktop(openWindow({ windows: [] }, 'home', defaultGeometry(desktopArea(), 0)));
      replacePath('/');
    }
    setPower(null);
  }

  const windowActions = {
    onActivate: (id: string) => {
      const windowId = id as WindowId;
      const isFront = focused?.id === windowId;
      change(current => (isFront ? minimiseWindow(current, windowId) : focusWindow(current, windowId)));
    },
    onRestore: (id: string) => change(current => restoreWindow(current, id as WindowId)),
    onMinimise: (id: string) => change(current => minimiseWindow(current, id as WindowId)),
    onMaximise: (id: string) => change(current => maximiseWindow(current, id as WindowId)),
    onClose: (id: string) => change(current => closeWindow(current, id as WindowId)),
  };

  // Taskbar buttons stay in the order the windows were opened, like XP.
  const [openOrder, setOpenOrder] = useState<WindowId[]>(() => initial.windows.map(window => window.id));
  useEffect(() => {
    const ids = desktop.windows.map(window => window.id);
    setOpenOrder(current => [...current.filter(id => ids.includes(id)), ...ids.filter(id => !current.includes(id))]);
  }, [desktop.windows]);

  return (
    <div className="xp-desktop">
      <Desktop
        items={desktopItems}
        leftIds={leftIds}
        rightIds={rightIds}
        area={area}
        isSmallScreen={isSmallScreen}
        onOpen={openDesktopItem}
        onActivate={() => setDesktopActive(true)}
        onProperties={() => setDialog('help')}
      />

      {desktop.windows.map((state, index) => {
        const tool = toolFor(state.id);
        const info = windowInfo(state.id);
        const isPage = pathForWindow(state.id) !== undefined;
        return (
          <XpWindow
            key={state.id}
            window={state}
            title={info.title}
            icon={info.icon}
            kind={state.id === DATE_TIME ? 'dialog' : 'document'}
            zIndex={index + 1}
            isFocused={state.id === focused?.id}
            isSmallScreen={isSmallScreen}
            area={area}
            statusBar={isPage && (
              <>
                <p className="status-bar-field">{tool ? tool.desc : `${visibleTools.length} of ${tools.length} tools`}</p>
                {tool && (
                  <p className="status-bar-field status-bar-link">
                    <a href={tool.url} target="_blank" rel="noopener">tools/{tool.name}</a>
                  </p>
                )}
              </>
            )}
            onFocus={() => change(current => focusWindow(current, state.id))}
            onMinimise={() => windowActions.onMinimise(state.id)}
            onToggleMaximise={() => change(current => toggleMaximise(current, state.id))}
            onClose={() => windowActions.onClose(state.id)}
            onGeometryChange={geometry => setDesktop(current => moveWindow(current, state.id, geometry))}
          >
            {tool ? (
              <ToolContent tool={tool} />
            ) : state.id === DATE_TIME ? (
              <DateTimeContent onClose={() => windowActions.onClose(DATE_TIME)} />
            ) : (
              <HomeContent
                tools={visibleTools}
                totalCount={tools.length}
                query={query}
                onQueryChange={setQuery}
                platform={platform}
                onPlatformChange={setPlatform}
                onSurprise={surprise}
              />
            )}
          </XpWindow>
        );
      })}

      <Taskbar
        items={openOrder.map(id => {
          const info = windowInfo(id);
          const state = desktop.windows.find(window => window.id === id);
          return {
            id,
            title: info.taskTitle,
            icon: info.icon,
            isActive: id === focused?.id,
            isMinimised: Boolean(state?.minimised),
            isMaximised: Boolean(state?.maximised),
          };
        })}
        actions={windowActions}
        recent={recent.map(name => tools.find(tool => tool.name === name)).filter(tool => tool !== undefined)}
        startOpen={startOpen}
        onStartOpenChange={setStartOpen}
        onShowDesktop={showDesktop}
        onOpenHome={() => navigate('/')}
        onOpenGithub={openGithub}
        onShowCategory={showCategory}
        onSearch={search}
        onSurprise={surprise}
        onRun={() => setDialog('run')}
        onHelp={() => setDialog('help')}
        onLogOff={() => setDialog('log-off')}
        onTurnOff={() => setDialog('turn-off')}
        onOpenClock={() => open(DATE_TIME)}
      />

      {dialog === 'help' && (
        <MessageDialog title="Help and Support" onClose={() => setDialog(null)}>
          <p><strong>Mikerosoft</strong>, {tools.length} tools installed.</p>
          <p>
            These are the little desktop tools I (Mike Cann) have built for myself on Windows and macOS. Double-click
            one to open it, hit Copy prompt, and let your AI agent do the setup.
          </p>
          <p>They're also sorted into {CATEGORY_ORDER.length} folders in Start, All Programs.</p>
          <p className="muted">Not affiliated with Microsoft in any way. Please don't sue me!</p>
        </MessageDialog>
      )}
      {dialog === 'log-off' && (
        <MessageDialog title="Log Off Mikerosoft" icon="/xp/logoff.png" onClose={() => setDialog(null)}>
          <p>You can't log off, there's nobody logged on. It's just a website.</p>
        </MessageDialog>
      )}
      {dialog === 'turn-off' && <TurnOffDialog onChoose={choosePower} onClose={() => setDialog(null)} />}
      {dialog === 'run' && (
        <RunDialog
          names={tools.map(tool => tool.name)}
          onClose={() => setDialog(null)}
          onRun={name => {
            if (name === 'mikerosoft' || name === 'explorer') {
              navigate('/');
              return true;
            }
            const tool = tools.find(candidate => candidate.name === name);
            if (tool) navigate(toolPath(tool.name));
            return Boolean(tool);
          }}
        />
      )}
      {dialog === 'not-found' && (
        <MessageDialog title="Mikerosoft" icon="/xp/help.png" onClose={() => { setDialog(null); navigate('/'); }}>
          <p>Hmm, I couldn't find that one. Maybe the tool got renamed?</p>
          <p>Every tool is on the desktop, or in Start, All Programs.</p>
        </MessageDialog>
      )}
      {power && <PowerScreen choice={power} onWake={wake} />}
    </div>
  );
}
