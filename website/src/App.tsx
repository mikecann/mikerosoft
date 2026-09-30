import 'xp.css/dist/XP.css';
import './xp.css';
import { useEffect, useState } from 'react';
import { categoryId, HomeContent, type PlatformFilter } from './HomeContent';
import { Link, navigate, replacePath, useNavigation } from './router';
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
  focusedWindow,
  focusWindow,
  minimiseWindow,
  moveWindow,
  openWindow,
  pathForWindow,
  SMALL_SCREEN,
  toggleMaximise,
  windowForPath,
  type Desktop,
  type WindowId,
} from './windowManager';
import { MessageDialog } from './XpDialogs';
import { XpWindow } from './XpWindow';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';
const TASKBAR_HEIGHT = 34;
// Tools listed down the left edge of the desktop. The rest go down the right.
const LEFT_CATEGORIES: readonly Category[] = ['Video & recording', 'Images'];

type Dialog = 'help' | 'log-off' | 'turn-off' | 'not-found' | null;

function desktopArea() {
  return { width: window.innerWidth, height: window.innerHeight - TASKBAR_HEIGHT };
}

function toolFor(id: WindowId): Tool | undefined {
  return id === 'home' ? undefined : tools.find(tool => `tool:${tool.name}` === id);
}

/** Opens the Mikerosoft window, plus the tool in the address bar on top of it. */
function initialDesktop(): { desktop: Desktop; dialog: Dialog } {
  const area = desktopArea();
  let desktop = openWindow({ windows: [] }, 'home', defaultGeometry(area, 0));
  const id = windowForPath(window.location.pathname);
  if (id && id !== 'home') desktop = openWindow(desktop, id, defaultGeometry(area, 1));
  return { desktop, dialog: id ? null : 'not-found' };
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

function DesktopIcon({ href, icon, label, external }: { href: string; icon: string; label: string; external?: boolean }) {
  const content = (
    <>
      <img src={icon} alt="" />
      <span>{label}</span>
    </>
  );
  return external ? (
    <a className="desktop-icon" href={href} target="_blank" rel="noopener">{content}</a>
  ) : (
    <Link className="desktop-icon" href={href}>{content}</Link>
  );
}

export default function App() {
  const area = useArea();
  const isSmallScreen = area.width < SMALL_SCREEN;
  const [{ desktop: initial, dialog: initialDialog }] = useState(initialDesktop);
  const [desktop, setDesktop] = useState<Desktop>(initial);
  const [dialog, setDialog] = useState<Dialog>(initialDialog);
  const [query, setQuery] = useState('');
  const [platform, setPlatform] = useState<PlatformFilter>('all');

  const focused = focusedWindow(desktop);
  const focusedTool = focused && toolFor(focused.id);
  const visibleTools = searchTools(
    filterToolsByPlatforms(tools, platform === 'all' ? PLATFORM_ORDER : [platform]),
    query,
  );

  function open(id: WindowId) {
    setDesktop(current => openWindow(current, id, defaultGeometry(desktopArea(), current.windows.length)));
  }

  useNavigation(pathname => {
    const id = windowForPath(pathname);
    if (id) open(id);
    else setDialog('not-found');
  });

  // The address bar always shows the window in front, so it can be shared.
  useEffect(() => {
    if (focused) replacePath(pathForWindow(focused.id));
    document.title = focusedTool ? `${focusedTool.name} - Mikerosoft` : 'Mikerosoft';
  }, [focused, focusedTool]);

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

  function taskbarClick(id: string) {
    const windowId = id as WindowId;
    setDesktop(current => (focusedWindow(current)?.id === windowId ? minimiseWindow(current, windowId) : focusWindow(current, windowId)));
  }

  const grouped = groupToolsByCategory(tools);
  const leftTools = grouped.filter(group => LEFT_CATEGORIES.includes(group.category)).flatMap(group => group.tools);
  const rightTools = grouped.filter(group => !LEFT_CATEGORIES.includes(group.category)).flatMap(group => group.tools);
  // Taskbar buttons stay in the order the windows were opened, like XP.
  const [openOrder, setOpenOrder] = useState<WindowId[]>(() => initial.windows.map(window => window.id));
  useEffect(() => {
    const ids = desktop.windows.map(window => window.id);
    setOpenOrder(current => [...current.filter(id => ids.includes(id)), ...ids.filter(id => !current.includes(id))]);
  }, [desktop.windows]);

  return (
    <div className="xp-desktop">
      <nav className="desktop-icons-wrap" aria-label="Desktop">
        <div className="desktop-icons desktop-icons-left">
          <DesktopIcon href="/" icon="/logo.png" label="Mikerosoft" />
          <DesktopIcon href={REPO_URL} icon="/xp/github.png" label="GitHub" external />
          {leftTools.map(tool => <DesktopIcon key={tool.name} href={toolPath(tool.name)} icon={tool.icon} label={tool.name} />)}
        </div>
        <div className="desktop-icons desktop-icons-right">
          {rightTools.map(tool => <DesktopIcon key={tool.name} href={toolPath(tool.name)} icon={tool.icon} label={tool.name} />)}
        </div>
      </nav>

      {desktop.windows.map((state, index) => {
        const tool = toolFor(state.id);
        return (
          <XpWindow
            key={state.id}
            window={state}
            title={tool ? `${tool.name} - Mikerosoft` : 'Mikerosoft'}
            icon={tool ? tool.icon : '/logo.png'}
            zIndex={index + 1}
            isFocused={state.id === focused?.id}
            isSmallScreen={isSmallScreen}
            area={area}
            statusBar={
              <>
                <p className="status-bar-field">{tool ? tool.desc : `${visibleTools.length} of ${tools.length} tools`}</p>
                {tool && <p className="status-bar-field status-bar-link"><a href={tool.url} target="_blank" rel="noopener">tools/{tool.name}</a></p>}
              </>
            }
            onFocus={() => setDesktop(current => focusWindow(current, state.id))}
            onMinimise={() => setDesktop(current => minimiseWindow(current, state.id))}
            onToggleMaximise={() => setDesktop(current => toggleMaximise(current, state.id))}
            onClose={() => setDesktop(current => closeWindow(current, state.id))}
            onGeometryChange={geometry => setDesktop(current => moveWindow(current, state.id, geometry))}
          >
            {tool ? (
              <ToolContent tool={tool} />
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
          const tool = toolFor(id);
          return { id, title: tool ? tool.name : 'Mikerosoft', icon: tool ? tool.icon : '/logo.png', isActive: id === focused?.id };
        })}
        onItemClick={taskbarClick}
        onOpenHome={() => navigate('/')}
        onShowCategory={showCategory}
        onSurprise={surprise}
        onHelp={() => setDialog('help')}
        onLogOff={() => setDialog('log-off')}
        onTurnOff={() => setDialog('turn-off')}
      />

      {dialog === 'help' && (
        <MessageDialog title="Help and Support" onClose={() => setDialog(null)}>
          <p><strong>Mikerosoft</strong>, {tools.length} tools installed.</p>
          <p>
            These are the little desktop tools I (Mike Cann) have built for myself on Windows and macOS. Open one,
            hit Copy prompt, and let your AI agent do the setup.
          </p>
          <p>There are {CATEGORY_ORDER.length} folders of them in the Start menu, or just click the icons on the desktop.</p>
          <p className="muted">Not affiliated with Microsoft in any way. Please don't sue me!</p>
        </MessageDialog>
      )}
      {dialog === 'log-off' && (
        <MessageDialog title="Log Off Mikerosoft" icon="/xp/logoff.png" onClose={() => setDialog(null)}>
          <p>You can't log off, there's nobody logged on. It's just a website.</p>
        </MessageDialog>
      )}
      {dialog === 'turn-off' && (
        <MessageDialog title="Turn off computer" icon="/xp/shutdown.png" onClose={() => setDialog(null)}>
          <p>It is now safe to close this tab.</p>
          <p>Or stay a while, there are {tools.length} tools to poke at.</p>
        </MessageDialog>
      )}
      {dialog === 'not-found' && (
        <MessageDialog title="Mikerosoft" icon="/xp/help.png" onClose={() => { setDialog(null); navigate('/'); }}>
          <p>Hmm, I couldn't find that one. Maybe the tool got renamed?</p>
          <p>Every tool is on the desktop, or in Start, All Programs.</p>
        </MessageDialog>
      )}
    </div>
  );
}
