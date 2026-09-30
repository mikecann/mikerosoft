import './win95.css';
import { useEffect, useRef, useState } from 'react';
import { HomeWindow, type HomeView } from './HomeWindow';
import { navigate, useRoute } from './router';
import { Sidebar, type PlatformFilter } from './Sidebar';
import { Taskbar } from './Taskbar';
import { toolPath } from './toolPages';
import { ToolWindow } from './ToolWindow';
import { filterToolsByPlatforms, PLATFORM_ORDER, searchTools, tools } from './tools';
import { MessageBox, TitleBar } from './win95';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';

type Dialog = 'about' | 'shutdown' | 'not-found' | null;

export default function App() {
  const route = useRoute();
  const tool = route.kind === 'tool' ? tools.find(candidate => candidate.name === route.name) : undefined;
  const [query, setQuery] = useState('');
  const [platform, setPlatform] = useState<PlatformFilter>('all');
  const [view, setView] = useState<HomeView>('icons');
  const [isMinimised, setIsMinimised] = useState(false);
  const [dialog, setDialog] = useState<Dialog>(route.kind === 'not-found' ? 'not-found' : null);
  const paneRef = useRef<HTMLDivElement>(null);

  const visibleTools = searchTools(
    filterToolsByPlatforms(tools, platform === 'all' ? PLATFORM_ORDER : [platform]),
    query,
  );

  useEffect(() => {
    paneRef.current?.scrollTo(0, 0);
    setIsMinimised(false);
    document.title = tool ? `${tool.name} - Mikerosoft` : 'Mikerosoft';
  }, [tool]);

  function surprise() {
    const others = tools.filter(candidate => candidate !== tool);
    navigate(toolPath(others[Math.floor(Math.random() * others.length)].name));
  }

  function search(value: string) {
    setQuery(value);
    // Searching from inside a tool takes you back to the list, where the results are.
    if (tool && value) navigate('/');
  }

  const windowTitle = tool ? tool.name : 'My Tools';
  const windowIcon = tool ? tool.icon : '/logo.png';

  return (
    <>
      <div className="desktop">
        <Sidebar
          tools={visibleTools}
          totalCount={tools.length}
          query={query}
          onQueryChange={search}
          platform={platform}
          onPlatformChange={setPlatform}
          activeName={tool?.name}
        />

        <main className="window desktop-main" data-minimised={isMinimised || undefined} aria-label={windowTitle}>
          <TitleBar
            icon={windowIcon}
            title={tool ? `${tool.name} - Mikerosoft` : 'My Tools'}
            onMinimise={() => setIsMinimised(true)}
            onClose={tool ? () => navigate('/') : () => setDialog('about')}
            closeLabel={tool ? `Close ${tool.name}` : 'Close'}
          />
          <nav className="menubar" aria-label="Menu">
            <a href="/" onClick={event => { event.preventDefault(); navigate('/'); }}><u>M</u>y Tools</a>
            <button type="button" onClick={surprise}><u>S</u>urprise me</button>
            <a href={REPO_URL} target="_blank" rel="noopener"><u>G</u>itHub</a>
            <button type="button" onClick={() => setDialog('about')}><u>H</u>elp</button>
            {!tool && (
              <>
                <span className="grow" />
                <div className="seg hide-small" role="group" aria-label="View">
                  <button type="button" className="btn btn-small" aria-pressed={view === 'icons'} onClick={() => setView('icons')}>
                    Large Icons
                  </button>
                  <button type="button" className="btn btn-small" aria-pressed={view === 'details'} onClick={() => setView('details')}>
                    Details
                  </button>
                </div>
              </>
            )}
          </nav>
          <div className="pane sunken scroll" ref={paneRef}>
            {tool ? (
              <ToolWindow key={tool.name} tool={tool} />
            ) : (
              <HomeWindow
                tools={visibleTools}
                totalCount={tools.length}
                view={view}
                onSurprise={surprise}
                onClearFilters={() => {
                  setQuery('');
                  setPlatform('all');
                }}
              />
            )}
          </div>
          <div className="statusbar">
            <div>{tool ? tool.desc : `${visibleTools.length} of ${tools.length} object(s)`}</div>
            <div>{platform === 'all' ? 'All platforms' : platform === 'windows' ? 'Windows only' : 'macOS only'}</div>
          </div>
        </main>
      </div>

      <Taskbar
        tools={visibleTools}
        query={query}
        onQueryChange={search}
        platform={platform}
        onPlatformChange={setPlatform}
        windowTitle={windowTitle}
        windowIcon={windowIcon}
        isMinimised={isMinimised}
        onToggleWindow={() => setIsMinimised(value => !value)}
        onShutDown={() => setDialog('shutdown')}
      />

      {dialog === 'about' && (
        <MessageBox title="About Mikerosoft" onClose={() => setDialog(null)}>
          <p><strong>Mikerosoft 95</strong><br />{tools.length} tools installed.</p>
          <p>
            These are the little desktop tools I (Mike Cann) have built for myself on Windows and macOS. Pick one,
            hit Copy prompt, and let your AI agent do the setup.
          </p>
          <p className="muted">Not affiliated with Microsoft in any way. Please don't sue me!</p>
        </MessageBox>
      )}
      {dialog === 'shutdown' && (
        <MessageBox title="Shut Down Mikerosoft" onClose={() => setDialog(null)}>
          <p>It is now safe to close this tab.</p>
          <p>Or stay a while, there are {tools.length} tools to poke at.</p>
        </MessageBox>
      )}
      {dialog === 'not-found' && (
        <MessageBox title="Mikerosoft" onClose={() => { setDialog(null); navigate('/'); }}>
          <p>Hmm, I couldn't find that one. Maybe the tool got renamed?</p>
          <p>Every tool is in the list on the left, or in the Start menu.</p>
        </MessageBox>
      )}
    </>
  );
}
