import { Fragment, useEffect, useRef, useState } from 'react';
import type { ChangelogEntry } from './changelog';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolDetails } from './toolDetails';
import { makeItYoursPrompt } from './toolPages';
import { CATEGORY_ICON, PLATFORM_ICON, PLATFORM_LABEL, sortPlatforms, type Tool } from './tools';
import { versionedAsset } from './versionedAsset';
import { ImageViewer } from './XpDialogs';

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
  const promptRef = useRef<HTMLTextAreaElement>(null);
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
    promptRef.current?.select();
    setStatus('Selected. Press Ctrl+C or Cmd+C to copy it.');
  }

  return (
    <aside className="task-pane get-it" aria-labelledby={`get-${tool.name}`}>
      <h2 className="task-pane-head" id={`get-${tool.name}`}>
        <img src="/icons/ui-get.png" alt="" />
        Get it
      </h2>
      <div className="task-pane-body">
        <p>
          Paste this into your AI coding agent. It'll copy the code over and set it up for your machine. Anything
          else, just ask it.
        </p>
        <button type="button" className="copy-button" onClick={copy}>
          <img src="/xp/run.png" alt="" />
          Copy prompt
        </button>
        <p className="copy-status" role="status">{status}</p>
        <textarea ref={promptRef} readOnly value={prompt} rows={5} aria-label="The prompt" />
        <a className="task-link" href={tool.url} target="_blank" rel="noopener">
          <img src="/xp/github.png" alt="" />
          View the source on GitHub
        </a>
      </div>
    </aside>
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
      <section className="media" aria-label="Artwork">
        <h2 className="section-head"><img src={CATEGORY_ICON.Images} alt="" />Screenshots</h2>
        {tool.header && (
          <div className="media-stage" data-art>
            <img src={versionedAsset(tool.header)} alt={`Artwork for ${tool.name}`} />
          </div>
        )}
        <p className="media-note">This is artwork I made for the tool, not a screenshot. Real ones are coming soon.</p>
      </section>
    );
  }

  const current = items[Math.min(active, items.length - 1)];

  return (
    <section className="media" aria-label={tool.video ? 'Video and screenshots' : 'Screenshots'}>
      <h2 className="section-head">
        <img src={tool.video ? CATEGORY_ICON['Video & recording'] : CATEGORY_ICON.Images} alt="" />
        {tool.video ? 'See it in action' : 'Screenshots'}
      </h2>
      <div className="media-stage">
        {current.kind === 'video' ? (
          <video key={current.src} src={current.src} controls autoPlay muted loop playsInline />
        ) : (
          <button type="button" className="plain zoom" onClick={() => setViewing(images.indexOf(current.src))} aria-label="Open full size">
            <img src={current.src} alt={`Screenshot of ${tool.name}`} />
          </button>
        )}
      </div>
      {items.length > 1 && (
        <div className="thumbs" role="group" aria-label="Pick a screenshot">
          {items.map((item, i) => (
            <button
              key={item.src}
              type="button"
              className="plain thumb"
              aria-pressed={i === active}
              aria-label={item.kind === 'video' ? 'Play the video' : `Screenshot ${i + 1}`}
              onClick={() => setActive(i)}
            >
              {item.kind === 'video' ? <span className="thumb-video">▶ Video</span> : <img src={item.src} alt="" />}
            </button>
          ))}
        </div>
      )}
      {viewing !== null && (
        <ImageViewer images={images} index={viewing} onIndexChange={setViewing} onClose={() => setViewing(null)} />
      )}
    </section>
  );
}

function Change({ entry }: { entry: ChangelogEntry }) {
  const [open, setOpen] = useState(false);
  const [why, ...more] = entry.paragraphs;

  return (
    <li className="change">
      <time dateTime={entry.date}>{formatToolDate(entry.date)}</time>
      <div>
        <p className="change-title">{entry.title}</p>
        {why && <p className="change-body">{why}</p>}
        {open && more.map((paragraph, i) => <p key={i} className="change-body">{paragraph}</p>)}
        <p className="change-links">
          {more.length > 0 && (
            <button type="button" className="plain link" onClick={() => setOpen(value => !value)}>
              {open ? 'Less' : 'More detail'}
            </button>
          )}
          <a href={`${REPO_URL}/commit/${entry.hash}`} target="_blank" rel="noopener">{entry.hash.slice(0, 7)}</a>
        </p>
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
    <section className="changes" aria-labelledby={`changes-${tool.name}`}>
      <h2 className="section-head" id={`changes-${tool.name}`}>
        <img src="/icons/ui-changes.png" alt="" />
        What's changed
        <span className="count">{entries.length === 1 ? '1 change' : `${entries.length} changes`}</span>
      </h2>
      <ol>
        {shown.map(entry => <Change key={entry.hash} entry={entry} />)}
      </ol>
      {entries.length > CHANGES_SHOWN && (
        <button type="button" onClick={() => setShowAll(value => !value)}>
          {showAll ? 'Show fewer' : `Show all ${entries.length} changes`}
        </button>
      )}
    </section>
  );
}

/** A tool's window: what it is and how to get it up top, then media, then its history. */
export function ToolContent({ tool }: { tool: Tool }) {
  const details = toolDetails[tool.name];
  const dates = TOOL_DATES[tool.name];

  return (
    <div className="doc scroll-area">
      <div className="tool-top">
        <div className="tool-intro">
          <header className="tool-head">
            <img src={tool.icon} alt="" />
            <div>
              <h1>{tool.name}</h1>
              <p className="chips">
                {sortPlatforms(tool.platforms).map(id => (
                  <span key={id}><img src={PLATFORM_ICON[id]} alt="" />{PLATFORM_LABEL[id]}</span>
                ))}
                <span><img src={CATEGORY_ICON[tool.category]} alt="" />{tool.category}</span>
                {dates && <span><img src="/icons/ui-calendar.png" alt="" />Updated {formatToolDate(dates.updated)}</span>}
              </p>
            </div>
          </header>
          <p className="lead">{details.tagline}</p>
          {details.intro.map((paragraph, i) => <p key={i}><RichText text={paragraph} /></p>)}
        </div>
        <GetIt tool={tool} />
      </div>
      <Media tool={tool} />
      <Changes tool={tool} />
    </div>
  );
}
