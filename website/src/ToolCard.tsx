import { useEffect, useState } from 'react';
import { Badge, Button, Card, Group, Image, Text, ThemeIcon } from '@mantine/core';
import { PLATFORM_COLOR, PLATFORM_LABEL, sortPlatforms, type Tool } from './tools';

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
        src={screenshots[idx]}
        alt={`${name} screenshot`}
        height={180}
        fit="cover"
        style={{ objectPosition: 'top' }}
      />
    </Card.Section>
  );
}

export function ToolCard({ tool }: { tool: Tool }) {
  const hasScreenshot = tool.screenshots.length > 0;

  return (
    <Card shadow="sm" padding="lg" radius="md" withBorder style={{ display: 'flex', flexDirection: 'column' }}>
      {tool.header ? (
        <Card.Section>
          <Image
            src={tool.header}
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
        <Group gap="sm" wrap="nowrap" style={{ minWidth: 0, flex: '1 1 auto' }}>
          <ThemeIcon variant="light" color="blue" size={36} radius="md">
            <img
              src={tool.icon}
              alt=""
              width={16}
              height={16}
              style={{ imageRendering: 'pixelated', display: 'block' }}
            />
          </ThemeIcon>
          <Text fw={700} size="md">
            {tool.name}
          </Text>
        </Group>
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

      <Button
        component="a"
        href={tool.url}
        target="_blank"
        rel="noopener"
        variant="light"
        color="blue"
        fullWidth
        mt="md"
        radius="md"
        size="sm"
      >
        View source
      </Button>
    </Card>
  );
}
