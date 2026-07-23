import '@mantine/core/styles.css';
import './App.css';
import { useState } from 'react';
import {
  Anchor,
  Box,
  Button,
  Container,
  createTheme,
  Group,
  Image,
  MantineProvider,
  SimpleGrid,
  Stack,
  Text,
  Title,
} from '@mantine/core';
import { ToolCard } from './ToolCard';
import {
  filterToolsByPlatforms,
  PLATFORM_COLOR,
  PLATFORM_LABEL,
  PLATFORM_ORDER,
  tools,
  type PlatformId,
} from './tools';

const theme = createTheme({
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
  primaryColor: 'blue',
});

function GithubCorner() {
  return (
    <a
      href="https://github.com/mikecann/mikerosoft"
      target="_blank"
      rel="noopener noreferrer"
      aria-label="View source on GitHub"
      title="View source on GitHub"
      className="github-corner"
      style={{
        position: 'fixed',
        top: 0,
        right: 0,
        zIndex: 50,
        color: 'var(--mantine-color-white)',
      }}
    >
      <svg
        width="80"
        height="80"
        viewBox="0 0 250 250"
        aria-hidden="true"
        style={{
          display: 'block',
        }}
      >
        <path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z" />
        <path
          d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2"
          fill="currentColor"
          className="github-corner-arm"
        />
        <path
          d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z"
          fill="currentColor"
        />
      </svg>
    </a>
  );
}

export default function App() {
  const [activePlatforms, setActivePlatforms] = useState<PlatformId[]>([...PLATFORM_ORDER]);
  const visibleTools = filterToolsByPlatforms(tools, activePlatforms);

  function togglePlatform(platform: PlatformId) {
    setActivePlatforms(current => (
      current.includes(platform)
        ? current.filter(id => id !== platform)
        : PLATFORM_ORDER.filter(id => id === platform || current.includes(id))
    ));
  }

  return (
    <MantineProvider theme={theme} defaultColorScheme="dark">
      <Box
        style={{
          minHeight: '100vh',
          background: 'var(--mantine-color-dark-8)',
        }}
      >
        <GithubCorner />
        <Container size={1800} py="xl" px="xl">
          <Stack align="center" mb="xl" gap="md">
            <Image
              src="/logo.png"
              alt="Mikerosoft logo"
              maw={300}
              w="100%"
            />
            <Title order={1} c="blue" mt="xs">Mikerosoft</Title>
            <Text c="dimmed" ta="center" maw={600} lh={1.6}>
              A collection of personalised desktop tools for{' '}
              <Anchor href="https://mikecann.blog" target="_blank" rel="noopener">
                Mike Cann
              </Anchor>.
              <br />
              <Text span size="sm" c="gray.6">
                (and is in no way affiliated with Microsoft... please don't sue me!)
              </Text>
            </Text>
            <Group
              gap="xs"
              justify="center"
              wrap="wrap"
              role="group"
              aria-label="Filter tools by platform"
            >
              {PLATFORM_ORDER.map(id => {
                const isActive = activePlatforms.includes(id);
                return (
                  <Button
                    key={id}
                    type="button"
                    size="compact-sm"
                    radius="xl"
                    variant={isActive ? 'light' : 'outline'}
                    color={isActive ? PLATFORM_COLOR[id] : 'gray'}
                    aria-pressed={isActive}
                    onClick={() => togglePlatform(id)}
                    className="platform-filter"
                  >
                    {PLATFORM_LABEL[id]}
                  </Button>
                );
              })}
            </Group>
          </Stack>

          {visibleTools.length > 0 ? (
            <SimpleGrid
              id="tool-grid"
              cols={{ base: 1, sm: 2, md: 3, lg: 4 }}
              spacing="lg"
            >
              {visibleTools.map(tool => (
                <ToolCard key={tool.name} tool={tool} />
              ))}
            </SimpleGrid>
          ) : (
            <Text ta="center" c="dimmed" py="xl" role="status">
              Select Windows or macOS to show available tools.
            </Text>
          )}
        </Container>
      </Box>
    </MantineProvider>
  );
}
