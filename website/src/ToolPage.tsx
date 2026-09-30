import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react';
import {
  Anchor,
  Badge,
  Box,
  Button,
  Code,
  Container,
  Group,
  Image,
  Modal,
  Paper,
  SimpleGrid,
  Stack,
  Text,
  Title,
  UnstyledButton,
} from '@mantine/core';
import { Link } from './router';
import { formatToolDate } from './toolDates';
import { TOOL_DATES } from './toolDates.generated';
import { toolDetails } from './toolDetails';
import { makeItYoursPrompt, readmeUrl, toolPath } from './toolPages';
import { PLATFORM_COLOR, PLATFORM_LABEL, sortPlatforms, tools, type Tool } from './tools';
import { versionedAsset } from './versionedAsset';

/** Turns `backticked` bits of copy into inline code and **starred** bits into bold. */
function RichText({ text }: { text: string }) {
  return (
    <>
      {text.split(/(`[^`]+`|\*\*[^*]+\*\*)/).map((part, i) => {
        if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) {
          return <Code key={i} className="inline-code">{part.slice(1, -1)}</Code>;
        }
        if (part.length > 4 && part.startsWith('**') && part.endsWith('**')) {
          return <strong key={i} className="rich-strong">{part.slice(2, -2)}</strong>;
        }
        return <Fragment key={i}>{part}</Fragment>;
      })}
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

function SectionTitle({ children }: { children: ReactNode }) {
  return (
    <Title order={2} size="h3" mb="md" className="section-title">
      {children}
    </Title>
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

function GetItCallout({ tool }: { tool: Tool }) {
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
    if (promptRef.current && selection) {
      selection.selectAllChildren(promptRef.current);
    }
    setStatus('select');
  }

  return (
    <Paper className="callout callout-get" radius="lg" p={{ base: 'lg', sm: 'xl' }}>
      <Text className="callout-kicker">How to get it</Text>
      <Title order={2} size="h3" mt={4} mb="xs">Make it your own</Title>
      <Text c="gray.4" lh={1.6} mb="md">
        There's no installer, these are just my own tools. The easiest way to get one is to paste
        this into your coding agent (Claude Code, Codex, Cursor or whatever you use) and let it copy
        the source over and tweak it for you.
      </Text>

      <Box className="prompt-box">
        <Text ref={promptRef} className="prompt-text">{prompt}</Text>
      </Box>
      {status === 'select' && (
        <Text size="sm" c="yellow.4" mt="xs" role="status">
          Your browser wouldn't let me copy it, so I've selected it. Press Cmd+C or Ctrl+C.
        </Text>
      )}

      <Group mt="md" gap="sm" wrap="wrap">
        <Button
          onClick={copy}
          color={copied ? 'teal' : 'blue'}
          radius="md"
          leftSection={copied ? <CheckIcon /> : <CopyIcon />}
          className="copy-prompt-button"
        >
          {copied ? 'Copied! Now paste it into your agent' : 'Copy prompt'}
        </Button>
        <Button component="a" href={tool.url} target="_blank" rel="noopener" variant="default" radius="md">
          View source
        </Button>
        <Button component="a" href={readmeUrl(tool)} target="_blank" rel="noopener" variant="subtle" color="gray" radius="md">
          README
        </Button>
      </Group>

      <Box className="by-hand" mt="lg" pt="md">
        <Text size="sm" c="dimmed" lh={1.6} mb={8}>
          Rather do it by hand? Grab the whole repo and you'll find it in{' '}
          <Code className="inline-code">tools/{tool.name}</Code>.
        </Text>
        <Box className="prompt-box prompt-box-small">
          <Text className="prompt-text">git clone https://github.com/mikecann/mikerosoft</Text>
        </Box>
      </Box>
    </Paper>
  );
}

function HowToUseCallout({ tool }: { tool: Tool }) {
  const details = toolDetails[tool.name];

  return (
    <Paper className="callout callout-use" radius="lg" p={{ base: 'lg', sm: 'xl' }}>
      <Text className="callout-kicker callout-kicker-teal">How to use it</Text>
      <Title order={2} size="h3" mt={4} mb="md">Once it's set up</Title>

      <Stack component="ol" gap="sm" className="steps">
        {details.howToUse.map((step, i) => (
          <li key={i} className="step">
            <span className="step-number" aria-hidden="true">{i + 1}</span>
            <Text lh={1.6} c="gray.3"><RichText text={step} /></Text>
          </li>
        ))}
      </Stack>

      {details.requirements.length > 0 && (
        <Box mt="lg">
          <Text size="xs" fw={700} tt="uppercase" c="dimmed" mb={8} className="letter-spaced">
            You'll need
          </Text>
          <Stack component="ul" gap={6} className="requirements">
            {details.requirements.map(requirement => (
              <Text component="li" key={requirement} size="sm" lh={1.5} c="gray.4" className="requirement">
                <RichText text={requirement} />
              </Text>
            ))}
          </Stack>
        </Box>
      )}
    </Paper>
  );
}

function Gallery({ tool }: { tool: Tool }) {
  const [active, setActive] = useState(0);
  const [zoomed, setZoomed] = useState(false);
  const shots = tool.screenshots.map(versionedAsset);

  useEffect(() => setActive(0), [tool.name]);

  if (shots.length === 0) return null;
  const current = shots[Math.min(active, shots.length - 1)];

  return (
    <Box component="section" mt={56}>
      <SectionTitle>{shots.length === 1 ? 'Screenshot' : 'Screenshots'}</SectionTitle>

      <UnstyledButton
        onClick={() => setZoomed(true)}
        className="shot-main"
        aria-label="Open screenshot full size"
      >
        <img src={current} alt={`${tool.name} screenshot ${active + 1}`} />
        <span className="shot-zoom-hint">Click to enlarge</span>
      </UnstyledButton>

      {shots.length > 1 && (
        <Group gap="sm" mt="sm" wrap="wrap">
          {shots.map((shot, i) => (
            <UnstyledButton
              key={shot}
              onClick={() => setActive(i)}
              className="shot-thumb"
              data-active={i === active || undefined}
              aria-label={`Show screenshot ${i + 1}`}
              aria-pressed={i === active}
            >
              <img src={shot} alt="" />
            </UnstyledButton>
          ))}
        </Group>
      )}

      <Modal
        opened={zoomed}
        onClose={() => setZoomed(false)}
        size="auto"
        centered
        withCloseButton={false}
        padding={0}
        radius="md"
        overlayProps={{ backgroundOpacity: 0.85, blur: 4 }}
      >
        <UnstyledButton onClick={() => setZoomed(false)} aria-label="Close" style={{ display: 'block' }}>
          <img src={current} alt={`${tool.name} screenshot ${active + 1}`} className="shot-full" />
        </UnstyledButton>
      </Modal>
    </Box>
  );
}

function Video({ tool }: { tool: Tool }) {
  if (!tool.video) return null;

  return (
    <Box component="section" mt={56}>
      <SectionTitle>See it in action</SectionTitle>
      <Box className="video-frame">
        <video src={versionedAsset(tool.video)} controls muted loop playsInline autoPlay preload="metadata" />
      </Box>
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
      <Container size={1100} px={{ base: 'md', sm: 'xl' }} pt="lg" pb={80}>
        <Group justify="space-between" mb="lg" pr={{ base: 56, sm: 72 }}>
          <Link href="/" className="back-link">
            <span aria-hidden="true">←</span> All tools
          </Link>
          <Link href="/" className="brand-link" aria-label="Mikerosoft home">
            <img src="/logo.png" alt="" />
            <span>Mikerosoft</span>
          </Link>
        </Group>

        <Box className="hero">
          {tool.header && (
            <Image src={versionedAsset(tool.header)} alt="" className="hero-image" />
          )}
          <Box className="hero-fade" />
        </Box>

        <Box className="hero-body">
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
        </Box>

        <SimpleGrid cols={{ base: 1, md: 2 }} spacing="lg" mt="xl">
          <GetItCallout tool={tool} />
          <HowToUseCallout tool={tool} />
        </SimpleGrid>

        <Box component="section" mt={56} maw={760}>
          <SectionTitle>What is it?</SectionTitle>
          <Stack gap="md">
            {details.intro.map((paragraph, i) => (
              <Text key={i} size="lg" lh={1.7} c="gray.3"><RichText text={paragraph} /></Text>
            ))}
          </Stack>
          {details.specificToMike && (
            <Paper className="heads-up" radius="md" p="md" mt="lg">
              <Text size="sm" lh={1.6}>
                <Text span fw={700} c="yellow.4">Heads up: </Text>
                <RichText text={details.specificToMike} />
              </Text>
            </Paper>
          )}
        </Box>

        <Video tool={tool} />
        <Gallery tool={tool} />

        {dates && (
          <Text size="sm" c="dimmed" mt={56}>
            Added {formatToolDate(dates.added)} · Last updated {formatToolDate(dates.updated)} ·{' '}
            <Anchor href={tool.url} target="_blank" rel="noopener" size="sm">Browse the code on GitHub</Anchor>
          </Text>
        )}

        <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="md" mt="xl">
          <NeighbourLink tool={previous} label="← Previous" align="left" />
          <NeighbourLink tool={next} label="Next →" align="right" />
        </SimpleGrid>
      </Container>
    </Box>
  );
}
