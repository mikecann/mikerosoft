import { useEffect, useRef, useState } from 'react';
import { Link } from './router';
import { toolPath } from './toolPages';
import { CATEGORY_ORDER, groupToolsByCategory, type Category, type Tool } from './tools';
import { TitleBar } from './win95';

export type PlatformFilter = 'all' | 'windows' | 'macos';

const PLATFORM_FILTERS: { value: PlatformFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'windows', label: 'Windows' },
  { value: 'macos', label: 'macOS' },
];

export function PlatformButtons({
  value,
  onChange,
}: {
  value: PlatformFilter;
  onChange: (value: PlatformFilter) => void;
}) {
  return (
    <div className="seg" role="group" aria-label="Platform">
      {PLATFORM_FILTERS.map(filter => (
        <button
          key={filter.value}
          type="button"
          className="btn btn-small"
          aria-pressed={value === filter.value}
          onClick={() => onChange(filter.value)}
        >
          {filter.label}
        </button>
      ))}
    </div>
  );
}

/** The always-open window listing every tool, so the whole suite is one glance away. */
export function Sidebar({
  tools,
  totalCount,
  query,
  onQueryChange,
  platform,
  onPlatformChange,
  activeName,
}: {
  tools: Tool[];
  totalCount: number;
  query: string;
  onQueryChange: (query: string) => void;
  platform: PlatformFilter;
  onPlatformChange: (platform: PlatformFilter) => void;
  activeName?: string;
}) {
  const [closed, setClosed] = useState<Set<Category>>(new Set());
  const treeRef = useRef<HTMLDivElement>(null);
  const groups = groupToolsByCategory(tools);

  useEffect(() => {
    treeRef.current?.querySelector('[aria-current="page"]')?.scrollIntoView({ block: 'nearest' });
  }, [activeName]);

  function toggle(category: Category) {
    setClosed(current => {
      const next = new Set(current);
      if (next.has(category)) next.delete(category);
      else next.add(category);
      return next;
    });
  }

  return (
    <nav className="window desktop-sidebar" aria-label="All tools">
      <TitleBar icon="/logo.png" title="Mikerosoft" inactive={Boolean(activeName)} />
      <div className="sidebar-controls">
        <input
          className="field"
          type="search"
          placeholder={`Find one of ${totalCount} tools...`}
          aria-label="Find a tool"
          value={query}
          onChange={event => onQueryChange(event.target.value)}
        />
        <PlatformButtons value={platform} onChange={onPlatformChange} />
      </div>
      <div className="tree sunken scroll" ref={treeRef}>
        <ul>
          <li>
            <Link href="/" className="node" aria-current={activeName ? undefined : 'page'}>
              <img src="/logo.png" alt="" />
              <span className="node-label">My Tools</span>
              <span className="node-count">({tools.length})</span>
            </Link>
            <ul>
              {CATEGORY_ORDER.map(category => {
                const group = groups.find(candidate => candidate.category === category);
                const isOpen = !closed.has(category);
                return (
                  <li key={category}>
                    <div className="node">
                      <button
                        type="button"
                        className="toggle"
                        onClick={() => toggle(category)}
                        aria-label={`${isOpen ? 'Collapse' : 'Expand'} ${category}`}
                        aria-expanded={isOpen}
                      >
                        {isOpen ? '−' : '+'}
                      </button>
                      <span className="folder" data-open={isOpen || undefined} />
                      <span className="node-label">{category}</span>
                      <span className="node-count">({group?.tools.length ?? 0})</span>
                    </div>
                    {isOpen && group && (
                      <ul>
                        {group.tools.map(tool => (
                          <li key={tool.name}>
                            <Link
                              href={toolPath(tool.name)}
                              className="node"
                              aria-current={tool.name === activeName ? 'page' : undefined}
                              title={tool.desc}
                            >
                              <img src={tool.icon} alt="" />
                              <span className="node-label">{tool.name}</span>
                            </Link>
                          </li>
                        ))}
                      </ul>
                    )}
                  </li>
                );
              })}
            </ul>
          </li>
        </ul>
        {tools.length === 0 && <p className="tree-empty">Nothing matches that. Try another word.</p>}
      </div>
    </nav>
  );
}
