import { Link } from './router';
import { toolDetails } from './toolDetails';
import { toolPath } from './toolPages';
import { CATEGORY_ICON, groupToolsByCategory, type Tool } from './tools';

export type PlatformFilter = 'all' | 'windows' | 'macos';

export const HOME_SEARCH_ID = 'home-search';

export function categoryId(category: string): string {
  return `category-${category.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
}

/** The Mikerosoft window: what this is, then every tool, grouped. */
export function HomeContent({
  tools,
  totalCount,
  query,
  onQueryChange,
  platform,
  onPlatformChange,
  onSurprise,
}: {
  tools: Tool[];
  totalCount: number;
  query: string;
  onQueryChange: (query: string) => void;
  platform: PlatformFilter;
  onPlatformChange: (platform: PlatformFilter) => void;
  onSurprise: () => void;
}) {
  return (
    <>
      <div className="xp-toolbar">
        <label className="xp-toolbar-field">
          <img src="/xp/search.png" alt="" />
          <span className="sr-only">Find a tool</span>
          <input
            id={HOME_SEARCH_ID}
            type="search"
            placeholder={`Search ${totalCount} tools`}
            value={query}
            onChange={event => onQueryChange(event.target.value)}
          />
        </label>
        <label className="xp-toolbar-field">
          Runs on
          <select value={platform} onChange={event => onPlatformChange(event.target.value as PlatformFilter)}>
            <option value="all">Windows and macOS</option>
            <option value="windows">Windows</option>
            <option value="macos">macOS</option>
          </select>
        </label>
        <button type="button" onClick={onSurprise}>Surprise me</button>
      </div>

      <div className="doc scroll-area">
        {!query && (
          <header className="home-hero">
            <img src="/logo.png" alt="Mikerosoft logo" className="home-logo" />
            <div>
              <h1>Mikerosoft</h1>
              <p className="lead">
                A collection of personalised desktop tools for Mike Cann (and is in no way affiliated with
                Microsoft... please don't sue me!)
              </p>
              <p>
                I build these for my own Windows and Mac machines whenever something bugs me. There are {totalCount} of
                them so far. Open any one to see what it does, and if you like it, it comes with a prompt you can
                paste into your AI coding agent to copy it over and make it your own.
              </p>
            </div>
          </header>
        )}

        {tools.length === 0 && (
          <p className="empty">Nothing matches that. Try another word, or set Runs on back to both.</p>
        )}

        {groupToolsByCategory(tools).map(group => (
          <section key={group.category} className="directory" id={categoryId(group.category)} aria-label={group.category}>
            <h2 className="task-pane-head">
              <img src={CATEGORY_ICON[group.category]} alt="" />
              {group.category}
              <span className="count">{group.tools.length} tools</span>
            </h2>
            <div className="directory-grid">
              {group.tools.map(tool => (
                <Link key={tool.name} href={toolPath(tool.name)} className="directory-item">
                  <img src={tool.icon} alt="" />
                  <span>
                    <strong>{tool.name}</strong>
                    <small>{toolDetails[tool.name]?.tagline ?? tool.desc}</small>
                  </span>
                </Link>
              ))}
            </div>
          </section>
        ))}
      </div>
    </>
  );
}
