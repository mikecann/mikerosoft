import { useEffect, useMemo, useRef, useState, type FormEvent, type MouseEvent } from 'react';
import { githubUrl, loadRepoPage, parentPath, rawUrl, repoPathFromUrl, resolveRepoPath, type RepoPage } from './github';

/** Something outside the window asking it to show a page, like a tool's "View the source" link. */
export interface BrowseRequest {
  path: string;
  /** Changes on every request, so asking for the same page twice still goes there. */
  id: number;
}

type Load = { status: 'loading' } | { status: 'error'; message: string } | { status: 'done'; page: RepoPage };

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/**
 * Cleans GitHub's rendered Markdown and points its relative images at the raw
 * files. GitHub already sanitises it, this is belt and braces.
 */
function prepareHtml(html: string, baseDir: string): string {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  doc.querySelectorAll('script, iframe, object, embed, form, style, link, meta').forEach(node => node.remove());
  doc.querySelectorAll('*').forEach(element => {
    for (const attribute of [...element.attributes]) {
      if (attribute.name.startsWith('on')) element.removeAttribute(attribute.name);
    }
  });
  doc.querySelectorAll('img').forEach(image => {
    const src = image.getAttribute('src') ?? '';
    if (src && !/^(https?:|data:)/i.test(src)) image.setAttribute('src', rawUrl(resolveRepoPath(baseDir, src)));
    image.setAttribute('loading', 'lazy');
  });
  doc.querySelectorAll('.anchor, svg.octicon').forEach(node => node.remove());
  return doc.body.innerHTML;
}

function Html({ html, baseDir, onNavigate }: { html: string; baseDir: string; onNavigate: (path: string) => void }) {
  const prepared = useMemo(() => prepareHtml(html, baseDir), [html, baseDir]);

  // Links inside the repo stay in the window. Everything else opens a real tab.
  function handleClick(event: MouseEvent<HTMLDivElement>) {
    const anchor = (event.target as Element).closest('a');
    const href = anchor?.getAttribute('href');
    if (!anchor || !href || href.startsWith('#')) return;
    event.preventDefault();
    if (/^(https?:)?\/\//i.test(href) || href.startsWith('mailto:')) {
      const repoPath = repoPathFromUrl(href);
      if (repoPath !== undefined) onNavigate(repoPath);
      else window.open(href, '_blank', 'noopener');
      return;
    }
    onNavigate(resolveRepoPath(baseDir, href));
  }

  return <div className="markdown" onClick={handleClick} dangerouslySetInnerHTML={{ __html: prepared }} />;
}

function Page({ page, onNavigate }: { page: RepoPage; onNavigate: (path: string) => void }) {
  if (page.kind === 'dir') {
    return (
      <>
        <table className="ie-files">
          <thead>
            <tr><th>Name</th><th>Size</th></tr>
          </thead>
          <tbody>
            {page.path && (
              <tr>
                <td>
                  <button type="button" className="plain ie-file" onClick={() => onNavigate(parentPath(page.path))}>
                    <img src="/xp/folder.png" alt="" />..
                  </button>
                </td>
                <td />
              </tr>
            )}
            {page.entries.map(entry => (
              <tr key={entry.path}>
                <td>
                  <button type="button" className="plain ie-file" onClick={() => onNavigate(entry.path)}>
                    <img src={entry.type === 'dir' ? '/xp/folder.png' : '/icons/ui-changes.png'} alt="" />
                    {entry.name}
                  </button>
                </td>
                <td className="ie-size">{entry.type === 'file' ? formatSize(entry.size) : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {page.readmeHtml && (
          <section className="ie-readme" aria-label="README">
            <p className="ie-readme-head">README.md</p>
            <Html html={page.readmeHtml} baseDir={page.path} onNavigate={onNavigate} />
          </section>
        )}
      </>
    );
  }

  const baseDir = parentPath(page.path);
  if (page.imageUrl) return <div className="ie-image"><img src={page.imageUrl} alt={page.path} /></div>;
  if (page.html) return <div className="ie-readme"><Html html={page.html} baseDir={baseDir} onNavigate={onNavigate} /></div>;
  if (page.text !== undefined) {
    return (
      <pre className="ie-code">
        {page.text.split('\n').map((line, i) => (
          <span key={i}><b>{i + 1}</b>{line}{'\n'}</span>
        ))}
      </pre>
    );
  }
  return (
    <p className="ie-message">
      This file is {formatSize(page.size)} and can't be shown here.{' '}
      <a href={githubUrl(page.path, 'file')} target="_blank" rel="noopener">Open it on GitHub</a>.
    </p>
  );
}

/** A little Internet Explorer that can only visit one website: this repo on GitHub. */
export function InternetExplorer({
  request,
  onTitleChange,
}: {
  request: BrowseRequest;
  onTitleChange: (title: string) => void;
}) {
  const [history, setHistory] = useState<{ paths: string[]; index: number }>({ paths: [request.path], index: 0 });
  const [load, setLoad] = useState<Load>({ status: 'loading' });
  const [address, setAddress] = useState(githubUrl(request.path));
  const bodyRef = useRef<HTMLDivElement>(null);
  const path = history.paths[history.index];

  function navigate(next: string) {
    setHistory(current => {
      if (current.paths[current.index] === next) return current;
      const paths = [...current.paths.slice(0, current.index + 1), next];
      return { paths, index: paths.length - 1 };
    });
  }

  useEffect(() => navigate(request.path), [request.id]);

  useEffect(() => {
    let cancelled = false;
    setLoad({ status: 'loading' });
    loadRepoPage(path).then(
      page => {
        if (cancelled) return;
        setLoad({ status: 'done', page });
        setAddress(githubUrl(path, page.kind === 'file' ? 'file' : 'dir'));
        bodyRef.current?.scrollTo(0, 0);
      },
      (error: Error) => {
        if (!cancelled) setLoad({ status: 'error', message: error.message });
      },
    );
    setAddress(githubUrl(path));
    onTitleChange(path ? `${path.split('/').pop()} - mikerosoft` : 'mikecann/mikerosoft');
    return () => {
      cancelled = true;
    };
  }, [path]);

  function go(event: FormEvent) {
    event.preventDefault();
    const repoPath = repoPathFromUrl(address);
    if (repoPath !== undefined) navigate(repoPath);
    else window.open(/^https?:/i.test(address) ? address : `https://${address}`, '_blank', 'noopener');
  }

  const step = (by: number) => setHistory(current => ({ ...current, index: current.index + by }));
  const pageUrl = load.status === 'done' ? githubUrl(path, load.page.kind === 'file' ? 'file' : 'dir') : githubUrl(path);

  return (
    <div className="ie">
      <div className="ie-toolbar">
        <button type="button" className="plain ie-nav" disabled={history.index === 0} onClick={() => step(-1)}>
          <span className="ie-arrow" aria-hidden="true">◀</span> Back
        </button>
        <button type="button" className="plain ie-nav" disabled={history.index >= history.paths.length - 1} onClick={() => step(1)} aria-label="Forward">
          <span className="ie-arrow" aria-hidden="true">▶</span>
        </button>
        <button type="button" className="plain ie-nav" disabled={!path} onClick={() => navigate(parentPath(path))}>
          <img src="/xp/folder.png" alt="" /> Up
        </button>
        <button type="button" className="plain ie-nav" onClick={() => navigate('')}>
          <img src="/logo.png" alt="" /> Home
        </button>
        <span className="ie-toolbar-gap" />
        <a className="ie-nav" href={pageUrl} target="_blank" rel="noopener">
          <img src="/xp/github.png" alt="" /> Open on GitHub
        </a>
      </div>
      <form className="ie-address" onSubmit={go}>
        <label htmlFor="ie-address">Address</label>
        <span className="ie-address-field">
          <img src="/xp/ie.png" alt="" />
          <input id="ie-address" value={address} onChange={event => setAddress(event.target.value)} spellCheck={false} />
        </span>
        <button type="submit" className="plain ie-go"><span aria-hidden="true">➜</span> Go</button>
      </form>
      <div className="ie-body scroll-area" ref={bodyRef}>
        {load.status === 'loading' && <p className="ie-message">Opening page {pageUrl}...</p>}
        {load.status === 'error' && (
          <div className="ie-message">
            <h2>The page cannot be displayed</h2>
            <p>{load.message}</p>
            <p><a href={pageUrl} target="_blank" rel="noopener">Open it on GitHub instead</a></p>
          </div>
        )}
        {load.status === 'done' && <Page page={load.page} onNavigate={navigate} />}
      </div>
      <div className="status-bar ie-status">
        <p className="status-bar-field">{load.status === 'loading' ? 'Opening page...' : load.status === 'error' ? 'Error on page.' : 'Done'}</p>
        <p className="status-bar-field ie-zone"><img src="/xp/ie.png" alt="" /> Internet</p>
      </div>
    </div>
  );
}
