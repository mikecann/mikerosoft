import '@mantine/core/styles.css';
import {
  Anchor,
  Badge,
  Box,
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
import { PLATFORM_COLOR, PLATFORM_LABEL, PLATFORM_ORDER, tools } from './tools';

const theme = createTheme({
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
  primaryColor: 'blue',
});

export default function App() {
  return (
    <MantineProvider theme={theme} defaultColorScheme="dark">
      <Box
        style={{
          minHeight: '100vh',
          background: 'var(--mantine-color-dark-8)',
        }}
      >
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
              <br />
              <br />
              <Anchor
                href="https://github.com/mikecann/mikerosoft"
                target="_blank"
                rel="noopener"
              >
                View the repository on GitHub
              </Anchor>
            </Text>
            <Text size="sm" c="dimmed" ta="center" maw={720} lh={1.6}>
              Badges on each card show where I actually run and maintain the integration today (Explorer
              and taskbar stubs on Windows, first-class setup scripts on macOS per the repo README).
            </Text>
            <Group gap="xs" justify="center" wrap="wrap">
              {PLATFORM_ORDER.map(id => (
                <Badge key={id} size="sm" variant="outline" color={PLATFORM_COLOR[id]}>
                  {PLATFORM_LABEL[id]}
                </Badge>
              ))}
            </Group>
          </Stack>

          <SimpleGrid
            cols={{ base: 1, sm: 2, md: 3, lg: 4 }}
            spacing="lg"
          >
            {tools.map(tool => (
              <ToolCard key={tool.name} tool={tool} />
            ))}
          </SimpleGrid>
        </Container>
      </Box>
    </MantineProvider>
  );
}
