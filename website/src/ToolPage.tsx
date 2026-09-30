import { Fragment, useEffect, useRef, useState } from 'react';
import {
  Anchor,
  Badge,
  Box,
  Button,
  Code,
  Container,
  Group,
  Modal,
  SimpleGrid,
  Stack,
  Text,
  Title,
  UnstyledButton,
} from '@mantine/core';
import type { ChangelogEntry } from './changelog';
import { Link } from './router';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolDetails } from './toolDetails';
import { makeItYoursPrompt, toolPath } from './toolPages';
import { PLATFORM_COLOR, PLATFORM_LABEL, sortPlatforms, tools, type Tool } from './tools';
import { versionedAsset } from './versionedAsset';

const REPO_URL = 'https://github.com/mikecann/mikerosoft';
const CHANGES_SHOWN = 6;

/** Turns `backticked` bits of copy into inline code. */
function RichText({ text }: { text: string }) {
  return (
    <>
      {text.split(/(`[^`]+`)/).map((part, i) => (
        part.length > 2 && part.startsWith('`') && part.endsWith('`')
          ? <Code key={i} className="inline-code">{part.slice(1, -1)}</Code>
          : <Fragment key={i}>{part}</Fragment>
      ))}
    </>
  );
}

/** Keeps tiny pixel-art icons crisp without making big app icons jaggy. */
function ToolIcon({ src, className }: { src: string; className: string }) {
  const [isTiny, setIsTiny] = useState(false);

  return (
    <img
      src={versionedAsset(src)}
      alt=""
      className={className}
      data-pixelated={isTiny || undefined}
      onLoad={event => setIsTiny(event.currentTarget.naturalWidth <= 32)}
    />
  );
}

function CopyIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}

function PlayIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M8 5v14l11-7z" />
    </svg>
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
  const promptRef = useRef<HTMLParagraphElement>(null);
  const [status, setStatus] = useState<'idle' | 'copied' | 'select'>('idle');
  const copied = status === 'copied';

  useEffect(() => {
    if (status === 'idle') return;
    const id = setTimeout(() => setStatus('idle'), 4000);
    return () => clearTimeout(id);
  }, [status]);

  async function copy() {
    if (await copyText(prompt)) {
      setStatus('copied');
      return;
    }
    // No clipboard access, so select it and let them copy it themselves.
    const selection = window.getSelection();
    if (promptRef.current && selection) selection.selectAllChildren(promptRef.current);
    setStatus('select');
  }

  return (
    <Box className="get-it">
      <Text className="get-it-kicker">Want it?</Text>
      <Text c="gray.3" lh={1.6} mt={4}>
        Paste this into your AI coding agent. It'll copy the code over and set it up for your
        machine. Anything else you want to know, just ask it.
      </Text>

      <Group mt="md" gap="sm" wrap="wrap">
        <Button
          onClick={copy}
          size="md"
          color={copied ? 'teal' : 'blue'}
          radius="md"
          leftSection={copied ? <CheckIcon /> : <CopyIcon />}
        >
          {copied ? 'Copied! Now paste it into your agent' : 'Copy prompt'}
        </Button>
        <Button component="a" href={tool.url} target="_blank" rel="noopener" size="md" variant="default" radius="md">
          View source
        </Button>
      </Group>

      <Box className="prompt-box" mt="md">
        <Text ref={promptRef} className="prompt-text">{prompt}</Text>
      </Box>
      {status === 'select' && (
        <Text size="sm" c="yellow.4" mt="xs" role="status">
          Your browser wouldn't let me copy it, so I've selected it. Press Cmd+C or Ctrl+C.
        </Text>
      )}
    </Box>
  );
}

type MediaItem = { kind: 'video' | 'image'; src: string; isArt?: boolean };

function mediaFor(tool: Tool): MediaItem[] {
  const items: MediaItem[] = [];
  if (tool.video) items.push({ kind: 'video', src: versionedAsset(tool.video) });
  for (const shot of tool.screenshots) items.push({ kind: 'image', src: versionedAsset(shot) });
  // The header is artwork rather than the tool itself, so it only fills in when there's nothing real.
  if (items.length === 0 && tool.header) {
    items.push({ kind: 'image', src: versionedAsset(tool.header), isArt: true });
  }
  return items;
}

function Media({ tool }: { tool: Tool }) {
  const items = mediaFor(tool);
  const [active, setActive] = useState(0);
  const [zoomed, setZoomed] = useState(false);

  if (items.length === 0) return null;
  const current = items[Math.min(active, items.length - 1)];

  return (
    <Box>
      <Box className="stage">
        {current.kind === 'video' ? (
          <video key={current.src} src={current.src} controls muted loop playsInline autoPlay preload="metadata" />
        ) : (
          <UnstyledButton onClick={() => setZoomed(true)} className="stage-image" aria-label="Open full size">
            <img src={current.src} alt={`${tool.name} ${current.isArt ? 'artwork' : 'screenshot'}`} />
          </UnstyledButton>
        )}
      </Box>

      {items.length > 1 && (
        <Group gap="sm" mt="sm" wrap="wrap">
          {items.map((item, i) => (
            <UnstyledButton
              key={item.src}
              onClick={() => setActive(i)}
              className="thumb"
              data-active={i === active || undefined}
              aria-label={item.kind === 'video' ? 'Play the video' : `Show screenshot ${i + 1}`}
              aria-pressed={i === active}
            >
              {item.kind === 'video' ? (
                <span className="thumb-video"><PlayIcon /></span>
              ) : (
                <img src={item.src} alt="" />
              )}
            </UnstyledButton>
          ))}
        </Group>
      )}

      <Modal
        opened={zoomed && current.kind === 'image'}
        onClose={() => setZoomed(false)}
        size="auto"
        centered
        withCloseButton={false}
        padding={0}
        radius="md"
        overlayProps={{ backgroundOpacity: 0.85, blur: 4 }}
      >
        <UnstyledButton onClick={() => setZoomed(false)} aria-label="Close" style={{ display: 'block' }}>
          <img src={current.src} alt="" className="shot-full" />
        </UnstyledButton>
      </Modal>
    </Box>
  );
}

function ChangeEntry({ entry }: { entry: ChangelogEntry }) {
  const [open, setOpen] = useState(false);
  const [why, ...more] = entry.paragraphs;

  return (
    <li className="change">
      <span className="change-dot" aria-hidden="true" />
      <Text size="xs" c="dimmed" fw={600} title={new Date(entry.date).toLocaleString('en-AU')}>
        {formatToolDate(entry.date)}
      </Text>
      <Text fw={700} c="gray.1" mt={2} lh={1.4}>{entry.title}</Text>
      {why && <Text size="sm" c="gray.5" lh={1.6} mt={4} className="change-body">{why}</Text>}
      {open && more.map((paragraph, i) => (
        <Text key={i} size="sm" c="gray.5" lh={1.6} mt="xs" className="change-body">{paragraph}</Text>
      ))}
      <Group gap="md" mt={6}>
        {more.length > 0 && (
          <Anchor component="button" type="button" size="xs" c="blue.4" onClick={() => setOpen(value => !value)}>
            {open ? 'Less' : 'More detail'}
          </Anchor>
        )}
        <Anchor href={`${REPO_URL}/commit/${entry.hash}`} target="_blank" rel="noopener" size="xs" c="dimmed">
          {entry.hash.slice(0, 7)}
        </Anchor>
      </Group>
    </li>
  );
}

function Changelog({ tool }: { tool: Tool }) {
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
    <Box component="section" mt={80} maw={760}>
      <Title order={2} size="h3">What's changed</Title>
      <Text c="dimmed" size="sm" mt={4} mb="xl">
        {entries.length === 1 ? 'One change' : `${entries.length} changes`}, newest first, straight from the commit history.
      </Text>
      <Stack component="ol" gap="xl" className="changes">
        {shown.map(entry => <ChangeEntry key={entry.hash} entry={entry} />)}
      </Stack>
      {entries.length > CHANGES_SHOWN && (
        <Button variant="subtle" color="gray" mt="lg" radius="md" onClick={() => setShowAll(value => !value)}>
          {showAll ? 'Show fewer' : `Show all ${entries.length} changes`}
        </Button>
      )}
    </Box>
  );
}

function NeighbourLink({ tool, label, align }: { tool: Tool; label: string; align: 'left' | 'right' }) {
  return (
    <Link href={toolPath(tool.name)} className="neighbour" data-align={align}>
      <Text size="xs" c="dimmed" tt="uppercase" fw={700} className="letter-spaced">{label}</Text>
      <Group gap="xs" justify={align === 'right' ? 'flex-end' : 'flex-start'} wrap="nowrap" mt={4}>
        <ToolIcon src={tool.icon} className="tool-icon-small" />
        <Text fw={700} truncate>{tool.name}</Text>
      </Group>
    </Link>
  );
}

export function ToolPage({ tool }: { tool: Tool }) {
  const details = toolDetails[tool.name];
  const dates = TOOL_DATES[tool.name];
  const index = tools.indexOf(tool);
  const previous = tools[(index - 1 + tools.length) % tools.length];
  const next = tools[(index + 1) % tools.length];

  useEffect(() => {
    document.title = `${tool.name} · Mikerosoft`;
    return () => {
      document.title = 'Mikerosoft';
    };
  }, [tool.name]);

  return (
    <Box className="tool-page">
      <Container size={1240} px={{ base: 'md', sm: 'xl' }} pt="lg" pb={80}>
        <Group justify="space-between" mb="xl" pr={{ base: 56, sm: 72 }}>
          <Link href="/" className="back-link">
            <span aria-hidden="true">←</span> All tools
          </Link>
          <Link href="/" className="brand-link" aria-label="Mikerosoft home">
            <img src="/logo.png" alt="" />
            <span>Mikerosoft</span>
          </Link>
        </Group>

        <Box className="tool-hero">
          <Box className="tool-hero-info">
            <Group gap="md" wrap="nowrap" align="center">
              <Box className="tool-icon-wrap">
                <ToolIcon src={tool.icon} className="tool-icon" />
              </Box>
              <Box style={{ minWidth: 0 }}>
                <Title order={1} className="tool-title">{tool.name}</Title>
                <Group gap={6} mt={6}>
                  {sortPlatforms(tool.platforms).map(id => (
                    <Badge key={id} variant="light" color={PLATFORM_COLOR[id]}>{PLATFORM_LABEL[id]}</Badge>
                  ))}
                </Group>
              </Box>
            </Group>

            <Text className="tagline" mt="lg">{details.tagline}</Text>
            <Stack gap="sm" mt="md">
              {details.intro.map((paragraph, i) => (
                <Text key={i} c="gray.4" lh={1.65}><RichText text={paragraph} /></Text>
              ))}
            </Stack>

            {dates && (
              <Text size="xs" c="dimmed" mt="md">
                Added {formatToolDate(dates.added)} · Updated {formatToolDate(dates.updated)}
              </Text>
            )}
          </Box>

          <Box className="tool-hero-media">
            <Media tool={tool} />
          </Box>

          <Box className="tool-hero-get">
            <GetIt tool={tool} />
          </Box>
        </Box>

        <Changelog tool={tool} />

        <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="md" mt={80}>
          <NeighbourLink tool={previous} label="← Previous" align="left" />
          <NeighbourLink tool={next} label="Next →" align="right" />
        </SimpleGrid>
      </Container>
    </Box>
  );
}
