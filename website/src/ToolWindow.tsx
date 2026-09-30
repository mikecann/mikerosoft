import { Fragment, useEffect, useRef, useState } from 'react';
import type { ChangelogEntry } from './changelog';
import { Link } from './router';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolDetails } from './toolDetails';
import { makeItYoursPrompt, toolPath } from './toolPages';
import { PLATFORM_LABEL, sortPlatforms, tools, type Tool } from './tools';
import { versionedAsset } from './versionedAsset';
import { ImageViewer } from './win95';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';
const CHANGES_SHOWN = 5;

/** Turns `backticked` bits of copy into inline code. */
function RichText({ text }: { text: string }) {
  return (
    <>
      {text.split(/(`[^`]+`)/).map((part, i) => (
        part.length > 2 && part.startsWith('`') && part.endsWith('`')
          ? <code key={i}>{part.slice(1, -1)}</code>
          : <Fragment key={i}>{part}</Fragment>
      ))}
    </>
  );
}

/** Copies with the clipboard API, falling back to the old execCommand route where it's blocked. */
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    const copied = document.execCommand('copy');
    textarea.remove();
    return copied;
  }
}

function GetIt({ tool }: { tool: Tool }) {
  const prompt = makeItYoursPrompt(tool);
  const promptRef = useRef<HTMLDivElement>(null);
  const [status, setStatus] = useState('');

  useEffect(() => {
    if (!status) return;
    const id = setTimeout(() => setStatus(''), 5000);
    return () => clearTimeout(id);
  }, [status]);

  async function copy() {
    if (await copyText(prompt)) {
      setStatus('Copied! Now paste it into your agent.');
      return;
    }
    // No clipboard access, so select it and let them copy it themselves.
    const selection = window.getSelection();
    if (promptRef.current && selection) selection.selectAllChildren(promptRef.current);
    setStatus('Selected. Press Ctrl+C or Cmd+C to copy it.');
  }

  return (
    <fieldset className="groupbox get-it">
      <legend>Get it</legend>
      <p>
        Paste this into your AI coding agent. It'll copy the code over and set it up for your machine. Anything
        else, just ask it.
      </p>
      <button type="button" className="btn copy-button" onClick={copy}>
        <span className="copy-button-icon" aria-hidden="true" />
        Copy prompt
      </button>
      <span className="copy-status" role="status">{status}</span>
      <div className="prompt sunken scroll" ref={promptRef}>{prompt}</div>
      <div className="get-it-links">
        <a className="btn btn-small" href={tool.url} target="_blank" rel="noopener">View source on GitHub</a>
      </div>
    </fieldset>
  );
}

type MediaItem = { kind: 'video' | 'image'; src: string };

function Media({ tool }: { tool: Tool }) {
  const items: MediaItem[] = [
    ...(tool.video ? [{ kind: 'video' as const, src: versionedAsset(tool.video) }] : []),
    ...tool.screenshots.map(shot => ({ kind: 'image' as const, src: versionedAsset(shot) })),
  ];
  const images = items.filter(item => item.kind === 'image').map(item => item.src);
  const [active, setActive] = useState(0);
  const [viewing, setViewing] = useState<number | null>(null);

  if (items.length === 0) {
    return (
      <fieldset className="groupbox">
        <legend>Screenshots</legend>
        {tool.header && (
          <div className="frame" data-art>
            <img src={versionedAsset(tool.header)} alt={`Artwork for ${tool.name}`} />
          </div>
        )}
        <p className="media-note">This is artwork I made for the tool, not a screenshot. Real ones are coming soon.</p>
      </fieldset>
    );
  }

  const current = items[Math.min(active, items.length - 1)];

  return (
    <fieldset className="groupbox">
      <legend>{tool.video ? 'See it in action' : 'Screenshots'}</legend>
      <div className="frame">
        {current.kind === 'video' ? (
          <video key={current.src} src={current.src} controls autoPlay muted loop playsInline />
        ) : (
          <button type="button" onClick={() => setViewing(images.indexOf(current.src))} aria-label="Open full size">
            <img src={current.src} alt={`Screenshot of ${tool.name}`} />
          </button>
        )}
      </div>
      {items.length > 1 && (
        <div className="thumbs" role="group" aria-label="Media">
          {items.map((item, i) => (
            <button
              key={item.src}
              type="button"
              className="thumb"
              aria-pressed={i === active}
              aria-label={item.kind === 'video' ? 'Play the video' : `Screenshot ${i + 1}`}
              onClick={() => setActive(i)}
            >
              {item.kind === 'video' ? <span className="thumb-video">Video</span> : <img src={item.src} alt="" />}
            </button>
          ))}
        </div>
      )}
      {current.kind === 'image' && <p className="media-note">Click the screenshot to see it full size.</p>}
      {viewing !== null && (
        <ImageViewer images={images} index={viewing} onIndexChange={setViewing} onClose={() => setViewing(null)} />
      )}
    </fieldset>
  );
}

function Change({ entry }: { entry: ChangelogEntry }) {
  const [open, setOpen] = useState(false);
  const [why, ...more] = entry.paragraphs;

  return (
    <li className="change">
      <div className="change-date">{formatToolDate(entry.date)}</div>
      <div>
        <p className="change-title">{entry.title}</p>
        {why && <p className="change-body">{why}</p>}
        {open && more.map((paragraph, i) => <p key={i} className="change-body">{paragraph}</p>)}
        <div className="change-links">
          {more.length > 0 && (
            <button type="button" className="link-button" onClick={() => setOpen(value => !value)}>
              {open ? 'Less' : 'More detail'}
            </button>
          )}
          <a href={`${REPO_URL}/commit/${entry.hash}`} target="_blank" rel="noopener">{entry.hash.slice(0, 7)}</a>
        </div>
      </div>
    </li>
  );
}

function Changes({ tool }: { tool: Tool }) {
  const [entries, setEntries] = useState<ChangelogEntry[] | null>(null);
  const [showAll, setShowAll] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetch(`/changelog/${tool.name}.json`)
      .then(response => (response.ok ? response.json() : []))
      .then((data: ChangelogEntry[]) => {
        if (!cancelled) setEntries(data);
      })
      .catch(() => {
        if (!cancelled) setEntries([]);
      });
    return () => {
      cancelled = true;
    };
  }, [tool.name]);

  if (!entries || entries.length === 0) return null;
  const shown = showAll ? entries : entries.slice(0, CHANGES_SHOWN);

  return (
    <fieldset className="groupbox">
      <legend>What's changed ({entries.length})</legend>
      <ol className="changes">
        {shown.map(entry => <Change key={entry.hash} entry={entry} />)}
      </ol>
      {entries.length > CHANGES_SHOWN && (
        <div className="changes-footer">
          <button type="button" className="btn btn-small" onClick={() => setShowAll(value => !value)}>
            {showAll ? 'Show fewer' : `Show all ${entries.length} changes`}
          </button>
        </div>
      )}
    </fieldset>
  );
}

export function ToolWindow({ tool }: { tool: Tool }) {
  const details = toolDetails[tool.name];
  const dates = TOOL_DATES[tool.name];
  const index = tools.indexOf(tool);
  const previous = tools[(index - 1 + tools.length) % tools.length];
  const next = tools[(index + 1) % tools.length];

  return (
    <article className="tool">
      <header className="tool-head">
        <img src={tool.icon} alt="" />
        <div>
          <h1>{tool.name}</h1>
          <p className="tool-tagline">{details.tagline}</p>
          <div className="chips">
            {sortPlatforms(tool.platforms).map(id => <span key={id} className="chip">{PLATFORM_LABEL[id]}</span>)}
            <span className="chip">{tool.category}</span>
            {dates && <span className="chip">Updated {formatToolDate(dates.updated)}</span>}
          </div>
        </div>
      </header>

      <div className="tool-top">
        <Media tool={tool} />
        <div className="tool-side">
          <fieldset className="groupbox about">
            <legend>What is it?</legend>
            {details.intro.map((paragraph, i) => <p key={i}><RichText text={paragraph} /></p>)}
          </fieldset>
          <GetIt tool={tool} />
        </div>
      </div>

      <Changes tool={tool} />

      <nav className="tool-neighbours" aria-label="More tools">
        <Link href={toolPath(previous.name)} className="btn">
          ‹ <img src={previous.icon} alt="" /> {previous.name}
        </Link>
        <Link href={toolPath(next.name)} className="btn">
          {next.name} <img src={next.icon} alt="" /> ›
        </Link>
      </nav>
    </article>
  );
}
