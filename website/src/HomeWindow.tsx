import { useState } from 'react';
import { Link } from './router';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolDetails } from './toolDetails';
import { toolPath } from './toolPages';
import { groupToolsByCategory, PLATFORM_LABEL, sortPlatforms, type Tool } from './tools';
import { TitleBar } from './win95';

const WELCOME_KEY = 'mikerosoft:welcome-closed';

function readWelcomeClosed(): boolean {
  try {
    return localStorage.getItem(WELCOME_KEY) === '1';
  } catch {
    return false;
  }
}

function Welcome({ toolCount, onBrowse, onSurprise, onClose }: {
  toolCount: number;
  onBrowse: () => void;
  onSurprise: () => void;
  onClose: () => void;
}) {
  return (
    <section className="window welcome" aria-labelledby="welcome-title">
      <TitleBar title="Welcome" onClose={onClose} closeLabel="Close the welcome" />
      <div className="welcome-body">
        <div className="welcome-logo"><img src="/logo.png" alt="Mikerosoft logo" /></div>
        <div className="welcome-text">
          <h1 id="welcome-title">Welcome to <b>Mikerosoft</b></h1>
          <p>
            A collection of personalised desktop tools for Mike Cann (and is in no way affiliated with
            Microsoft... please don't sue me!)
          </p>
          <p>
            I build these for my own Windows and Mac machines whenever something bugs me. There are {toolCount} of
            them so far, and you're welcome to take any of them and make them your own.
          </p>
          <div className="tip">
            <strong>Did you know...</strong>
            Every tool has a prompt you can paste into your AI coding agent. It copies the code over and sets it
            up for your machine.
          </div>
        </div>
        <div className="welcome-buttons">
          <button type="button" className="btn btn-default" onClick={onBrowse}>Browse tools</button>
          <button type="button" className="btn" onClick={onSurprise}>Surprise me</button>
          <button type="button" className="btn" onClick={onClose}>Close</button>
        </div>
      </div>
    </section>
  );
}

type DetailsSort = 'name' | 'updated';

function DetailsView({ tools }: { tools: Tool[] }) {
  const [sort, setSort] = useState<DetailsSort>('name');
  const sorted = sort === 'name'
    ? tools
    : [...tools].sort((a, b) => Date.parse(TOOL_DATES[b.name]?.updated ?? '0') - Date.parse(TOOL_DATES[a.name]?.updated ?? '0'));

  return (
    <table className="details">
      <thead>
        <tr>
          <th><button type="button" onClick={() => setSort('name')}>Name</button></th>
          <th className="hide-small"><button type="button" onClick={() => setSort('name')}>What it does</button></th>
          <th className="hide-small"><button type="button" onClick={() => setSort('name')}>Runs on</button></th>
          <th><button type="button" onClick={() => setSort('updated')}>Modified</button></th>
        </tr>
      </thead>
      <tbody>
        {sorted.map(tool => (
          <tr key={tool.name}>
            <td><Link href={toolPath(tool.name)}><img src={tool.icon} alt="" />{tool.name}</Link></td>
            <td className="hide-small muted">{toolDetails[tool.name]?.tagline ?? tool.desc}</td>
            <td className="hide-small muted">{sortPlatforms(tool.platforms).map(id => PLATFORM_LABEL[id]).join(', ')}</td>
            <td className="muted" style={{ whiteSpace: 'nowrap' }}>
              {TOOL_DATES[tool.name] ? formatToolDate(TOOL_DATES[tool.name].updated) : ''}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function IconsView({ tools }: { tools: Tool[] }) {
  return (
    <>
      {groupToolsByCategory(tools).map(group => (
        <section key={group.category} className="icon-group" aria-label={group.category}>
          <div className="icon-group-head">
            {group.category} <small>{group.tools.length} object(s)</small>
          </div>
          <div className="icons">
            {group.tools.map(tool => (
              <Link key={tool.name} href={toolPath(tool.name)} className="desk-icon" title={toolDetails[tool.name]?.tagline}>
                <img src={tool.icon} alt="" />
                <span>{tool.name}</span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </>
  );
}

export type HomeView = 'icons' | 'details';

export function HomeWindow({
  tools,
  totalCount,
  view,
  onSurprise,
  onClearFilters,
}: {
  tools: Tool[];
  totalCount: number;
  view: HomeView;
  onSurprise: () => void;
  onClearFilters: () => void;
}) {
  const [welcomeClosed, setWelcomeClosed] = useState(readWelcomeClosed);

  function closeWelcome() {
    setWelcomeClosed(true);
    try {
      localStorage.setItem(WELCOME_KEY, '1');
    } catch {
      // Private windows can refuse storage. The welcome just comes back next time.
    }
  }

  function browse() {
    document.getElementById('all-tools')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  return (
    <div className="home">
      {!welcomeClosed && (
        <Welcome toolCount={totalCount} onBrowse={browse} onSurprise={onSurprise} onClose={closeWelcome} />
      )}
      <div id="all-tools">
        {tools.length === 0 ? (
          <div className="empty">
            <p>No tools match that.</p>
            <button type="button" className="btn" onClick={onClearFilters}>Clear the filter</button>
          </div>
        ) : view === 'details' ? (
          <DetailsView tools={tools} />
        ) : (
          <IconsView tools={tools} />
        )}
      </div>
    </div>
  );
}
