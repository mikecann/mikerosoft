import { useEffect, useState } from 'react';
import { Badge, Button, Card, Group, Image, Text } from '@mantine/core';
import { PLATFORM_COLOR, PLATFORM_LABEL, sortPlatforms, type Tool } from './tools';
import type { ToolDates } from './gitHistory';
import { formatToolDate } from './toolDates';
import { toolPath } from './toolPages';
import { Link } from './router';
import { versionedAsset } from './versionedAsset';

function ScreenshotSection({ screenshots, name }: { screenshots: string[]; name: string }) {
  const [idx, setIdx] = useState(0);

  useEffect(() => {
    if (screenshots.length <= 1) return;
    const id = setInterval(() => setIdx((i: number) => (i + 1) % screenshots.length), 4000);
    return () => clearInterval(id);
  }, [screenshots.length]);

  return (
    <Card.Section>
      <Image
        src={versionedAsset(screenshots[idx])}
        alt={`${name} screenshot`}
        height={180}
        fit="cover"
        style={{ objectPosition: 'top' }}
      />
    </Card.Section>
  );
}

function DateLabel({ label, iso, isHighlighted }: { label: string; iso: string; isHighlighted: boolean }) {
  return (
    <Text
      span
      inherit
      fw={isHighlighted ? 700 : undefined}
      c={isHighlighted ? 'gray.3' : undefined}
      title={new Date(iso).toLocaleString('en-AU')}
    >
      {label} {formatToolDate(iso)}
    </Text>
  );
}

export function ToolCard({
  tool,
  dates,
  highlight,
}: {
  tool: Tool;
  dates?: ToolDates;
  /** Which date the grid is sorted by, so it stands out. */
  highlight?: keyof ToolDates;
}) {
  const hasScreenshot = tool.screenshots.length > 0;

  return (
    <Card shadow="sm" padding="lg" radius="md" withBorder className="tool-card" style={{ display: 'flex', flexDirection: 'column' }}>
      {tool.header ? (
        <Card.Section>
          <Image
            src={versionedAsset(tool.header)}
            alt={`${tool.name} header`}
            height={180}
            fit="cover"
            style={{ objectPosition: 'center' }}
          />
        </Card.Section>
      ) : hasScreenshot && (
        <ScreenshotSection screenshots={tool.screenshots} name={tool.name} />
      )}

      <Group
        mt={tool.header || hasScreenshot ? 'md' : 0}
        mb="xs"
        gap="sm"
        wrap="wrap"
        align="flex-start"
        justify="space-between"
      >
        <Text fw={700} size="md" style={{ minWidth: 0, flex: '1 1 auto' }}>
          <Link href={toolPath(tool.name)} className="tool-card-link">
            {tool.name}
          </Link>
        </Text>
        <Group gap={6} wrap="wrap" justify="flex-end" style={{ flex: '0 0 auto' }}>
          {sortPlatforms(tool.platforms).map(id => (
            <Badge key={id} size="xs" variant="light" color={PLATFORM_COLOR[id]}>
              {PLATFORM_LABEL[id]}
            </Badge>
          ))}
        </Group>
      </Group>

      <Text size="sm" c="dimmed" lh={1.6} style={{ flex: 1 }}>
        {tool.desc}
      </Text>

      {dates && (
        <Text size="xs" c="dimmed" mt="sm">
          <DateLabel label="Added" iso={dates.added} isHighlighted={highlight === 'added'} />
          {' · '}
          <DateLabel label="Updated" iso={dates.updated} isHighlighted={highlight === 'updated'} />
        </Text>
      )}

      <Group gap="xs" mt="md" wrap="nowrap" className="tool-card-actions">
        <Button
          component={Link}
          href={toolPath(tool.name)}
          variant="light"
          color="blue"
          radius="md"
          size="sm"
          style={{ flex: 1 }}
        >
          Take a look
        </Button>
        <Button
          component="a"
          href={tool.url}
          target="_blank"
          rel="noopener"
          variant="subtle"
          color="gray"
          radius="md"
          size="sm"
        >
          Source
        </Button>
      </Group>
    </Card>
  );
}
