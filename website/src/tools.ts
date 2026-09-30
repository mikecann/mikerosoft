/** Where the tool is wired up in this repo today (see root README macOS matrix). */
export type PlatformId = 'windows' | 'macos';

export const PLATFORM_ORDER: readonly PlatformId[] = ['windows', 'macos'];

export const PLATFORM_LABEL: Record<PlatformId, string> = {
  windows: 'Windows',
  macos: 'macOS',
};

export const PLATFORM_COLOR: Record<PlatformId, string> = {
  windows: 'blue',
  macos: 'teal',
};

export function sortPlatforms(platforms: readonly PlatformId[]): PlatformId[] {
  return [...platforms].sort((a, b) => PLATFORM_ORDER.indexOf(a) - PLATFORM_ORDER.indexOf(b));
}

export const CATEGORY_ORDER = ['Video & recording', 'Images', 'Desktop', 'Developer'] as const;

export type Category = (typeof CATEGORY_ORDER)[number];

export interface Tool {
  name: string;
  desc: string;
  /** A Mikerosoft 95 icon in website/public/icons. */
  icon: string;
  header?: string;
  screenshots: string[];
  /** A short demo clip, played on the tool's page. */
  video?: string;
  url: string;
  platforms: readonly PlatformId[];
  category: Category;
}

export function filterToolsByPlatforms(
  toolList: readonly Tool[],
  activePlatforms: readonly PlatformId[],
): Tool[] {
  const active = new Set(activePlatforms);
  return toolList.filter(tool => tool.platforms.some(platform => active.has(platform)));
}

export function groupToolsByCategory(toolList: readonly Tool[]): { category: Category; tools: Tool[] }[] {
  return CATEGORY_ORDER
    .map(category => ({ category, tools: toolList.filter(tool => tool.category === category) }))
    .filter(group => group.tools.length > 0);
}

/**
 * Keeps tools whose name, description or category contains every word of the
 * query, with tools whose name matches listed first.
 */
export function searchTools(toolList: readonly Tool[], query: string): Tool[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const nameMatches = (tool: Tool) => words.every(word => tool.name.includes(word));
  const matches = toolList.filter(tool => {
    const haystack = `${tool.name} ${tool.desc} ${tool.category}`.toLowerCase();
    return words.every(word => haystack.includes(word));
  });
  return [...matches.filter(nameMatches), ...matches.filter(tool => !nameMatches(tool))];
}

const base = 'https://cdn.jsdelivr.net/gh/mikecann/mikerosoft@main/tools';

export const tools: Tool[] = [
  {
    name: 'transcribe',
    desc: 'Extract audio from a video and transcribe it via faster-whisper (CUDA with CPU fallback); right-click any video file in Explorer',
    icon: '/icons/transcribe.png',
    header: `${base}/transcribe/docs/header.webp`,
    screenshots: [`${base}/transcribe/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/transcribe',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'video-to-markdown',
    desc: 'Convert a YouTube URL to a markdown image-link and copy it to clipboard; right-click any .url Internet Shortcut in Explorer',
    icon: '/icons/video-to-markdown.png',
    header: `${base}/video-to-markdown/docs/header.webp`,
    screenshots: [
      `${base}/video-to-markdown/docs/ss1.png`,
      `${base}/video-to-markdown/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-to-markdown',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'removebg',
    desc: 'Remove the background from an image using rembg / birefnet-portrait; right-click any image file in Explorer',
    icon: '/icons/removebg.png',
    header: `${base}/removebg/docs/header.webp`,
    screenshots: [`${base}/removebg/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/removebg',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'remove-portrait',
    desc: 'Remove the background from a talking-head video and save a transparent MOV for Resolve; right-click any video file in Explorer',
    icon: '/icons/remove-portrait.png',
    header: `${base}/remove-portrait/docs/header.webp`,
    screenshots: [`${base}/remove-portrait/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/remove-portrait',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'unmultitrack',
    desc: 'Extract every video stream from an OBS/Aitum multi-track recording into separate editor-friendly files; right-click any video file in Explorer',
    icon: '/icons/unmultitrack.png',
    header: `${base}/unmultitrack/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/unmultitrack',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'img-upscale',
    desc: 'Upscale an image locally with a quality-first transformer backend; right-click any image file in Explorer, choose 2x, 4x, 8x, or 16x, and keep the original file format',
    icon: '/icons/img-upscale.png',
    header: `${base}/img-upscale/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-upscale',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'ghopen',
    desc: 'Open the current repo on GitHub; opens the PR page if on a PR branch; right-click any folder in Explorer',
    icon: '/icons/ghopen.png',
    header: `${base}/ghopen/docs/header.webp`,
    screenshots: [`${base}/ghopen/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/ghopen',
    category: 'Developer',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'ctxmenu',
    desc: 'Manage Explorer context menu entries - toggle shell verbs and COM handlers on/off without admin rights',
    icon: '/icons/ctxmenu.png',
    header: `${base}/ctxmenu/docs/header.webp`,
    screenshots: [`${base}/ctxmenu/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/ctxmenu',
    category: 'Desktop',
    platforms: ['windows'],
  },
  {
    name: 'color-picker',
    desc: 'Pixie-style screen color picker: drag over the screen, preview the live color, and copy HEX, RGB, HSL, HLS, HSV, CMYK, or BGR',
    icon: '/icons/color-picker.png',
    header: `${base}/color-picker/docs/header.webp`,
    screenshots: [`${base}/color-picker/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/color-picker',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'backup-phone',
    desc: 'Back up an iPhone over MTP (USB) to a flat folder on disk',
    icon: '/icons/backup-phone.png',
    header: `${base}/backup-phone/docs/header.webp`,
    screenshots: [`${base}/backup-phone/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/backup-phone',
    category: 'Desktop',
    platforms: ['windows'],
  },
  {
    name: 'scale-monitor',
    desc: 'Toggle Monitor 4 between 200% (normal) and 300% (filming) scaling',
    icon: '/icons/scale-monitor.png',
    header: `${base}/scale-monitor/docs/header.webp`,
    screenshots: [
      `${base}/scale-monitor/docs/ss1.png`,
      `${base}/scale-monitor/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/scale-monitor',
    category: 'Desktop',
    platforms: ['windows'],
  },
  {
    name: 'sleep-monitors',
    desc: 'Turn off all connected monitors until keyboard or mouse input wakes them',
    icon: '/icons/sleep-monitors.png',
    header: `${base}/sleep-monitors/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/sleep-monitors',
    category: 'Desktop',
    platforms: ['windows'],
  },
  {
    name: 'task-stats',
    desc: 'Real-time NET/CPU/GPU/MEM sparklines overlaid on the taskbar',
    icon: '/icons/task-stats.png',
    header: `${base}/task-stats/docs/header.webp`,
    screenshots: [`${base}/task-stats/docs/ss1.png`],
    video: `${base}/task-stats/screenshots/vid1.mp4`,
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/task-stats',
    category: 'Desktop',
    platforms: ['windows'],
  },
  {
    name: 'taskbar',
    desc: 'Windows-style taskbar for macOS: one bar per monitor, pinned apps, widgets including a one-button Elgato lights toggle, and window avoidance',
    icon: '/icons/taskbar.png',
    header: `${base}/taskbar/docs/header.webp`,
    screenshots: [
      `${base}/taskbar/docs/ss1.png`,
      `${base}/taskbar/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/taskbar',
    category: 'Desktop',
    platforms: ['macos'],
  },
  {
    name: 'last-window-quits',
    desc: 'Quit normal macOS Dock apps one second after their final window closes, while preserving minimized windows, save prompts, and background-only apps',
    icon: '/icons/last-window-quits.png',
    header: `${base}/last-window-quits/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/last-window-quits',
    category: 'Desktop',
    platforms: ['macos'],
  },
  {
    name: 'mikey-mouse',
    desc: 'Menu-bar helper that makes a normal mouse feel at home on macOS: side buttons go back and forward in Finder and Safari, and a notched scroll wheel glides smoothly',
    icon: '/icons/mikey-mouse.png',
    header: `${base}/mikey-mouse/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/mikey-mouse',
    category: 'Desktop',
    platforms: ['macos'],
  },
  {
    name: 'record-it',
    desc: 'Native SwiftUI screen and camera recorder with 4K/30 capture, project-aware source folders, system audio, microphone audio, and separate full-resolution outputs',
    icon: '/icons/record-it.png',
    header: `${base}/record-it/docs/header.webp`,
    screenshots: [
      `${base}/record-it/docs/ss1.png`,
      `${base}/record-it/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/record-it',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'phonebooth',
    desc: 'Mirror and control several iPhones and iPads at once over USB, each in its own window: click to tap, drag to swipe, scroll to scroll, and type to type',
    icon: '/icons/phonebooth.png',
    header: `${base}/phonebooth/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/phonebooth',
    category: 'Desktop',
    platforms: ['macos'],
  },
  {
    name: 'token-stats',
    desc: 'Native SwiftUI dashboard for Codex, Claude, and OpenRouter token usage, API-equivalent costs, model breakdowns, and shareable graph exports',
    icon: '/icons/token-stats.png',
    header: `${base}/token-stats/docs/header.png`,
    screenshots: [`${base}/token-stats/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/token-stats',
    category: 'Developer',
    platforms: ['macos'],
  },
  {
    name: 'record-meeting',
    desc: 'Always-on-top meeting recorder with system audio and microphone capture, live waveform, synchronized speaker-labelled transcript review, MP3 export, and Notion publishing',
    icon: '/icons/record-meeting.png',
    header: `${base}/record-meeting/docs/header.webp`,
    screenshots: [
      `${base}/record-meeting/docs/ss1.png`,
      `${base}/record-meeting/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/record-meeting',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'meeting-archive',
    desc: 'Preview: camera-triggered Zoom recording with microphone and meeting audio, Bruce archival and transcription, speaker review, and Notion indexing. Wider app support is still in validation.',
    icon: '/icons/meeting-archive.png',
    header: `${base}/meeting-archive/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/meeting-archive',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'video-hq',
    desc: 'Native macOS video-production hub: browse project folders, import scripts from Notion, preview rendered MP4s, transcribe, and generate YouTube descriptions',
    icon: '/icons/video-hq.png',
    header: `${base}/video-hq/docs/header.jpg`,
    screenshots: [
      `${base}/video-hq/docs/ss1.jpg`,
      `${base}/video-hq/docs/ss2.jpg`,
      `${base}/video-hq/docs/ss3.jpg`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-hq',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'telemprompit',
    desc: 'Teleprompter for the Elgato Prompter: paste notes or Notion bullets, step through them line by line or auto-scroll, mirror for beam-splitter glass, and drive it with a clicker from any app',
    icon: '/icons/telemprompit.png',
    header: `${base}/telemprompit/docs/header.png`,
    screenshots: [
      `${base}/telemprompit/docs/ss1.png`,
      `${base}/telemprompit/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/telemprompit',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'tandem',
    desc: 'Native video editor that replaces Filmora for the Convex videos: record-it takes, a cutout PiP, ripple editing, titles, word captions, 9:16 shorts and a -14 LUFS export, with a CLI and MCP server so agents can edit the same project',
    icon: '/icons/tandem.png',
    header: `${base}/tandem/docs/header.jpg`,
    screenshots: [`${base}/tandem/docs/ss1.jpg`, `${base}/tandem/docs/ss2.jpg`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/tandem',
    category: 'Video & recording',
    platforms: ['macos'],
  },
  {
    name: 'voice-type',
    desc: 'Push-to-talk local voice transcription for Windows and macOS. On Apple Silicon it uses MLX for faster final transcription',
    icon: '/icons/voice-type.png',
    header: `${base}/voice-type/docs/header.webp`,
    screenshots: [`${base}/voice-type/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/voice-type',
    category: 'Desktop',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'video-titles',
    desc: 'Chat with an AI agent to ideate YouTube titles using the Compelling Title Matrix framework; right-click any video in Explorer (requires OpenRouter API key)',
    icon: '/icons/video-titles.png',
    header: `${base}/video-titles/docs/header.webp`,
    screenshots: [`${base}/video-titles/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-titles',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'generate-from-image',
    desc: 'AI image generation from a reference image - right-click any image in Explorer, describe what you want, and Gemini 3 Pro generates a new image (requires OpenRouter API key)',
    icon: '/icons/generate-from-image.png',
    header: `${base}/generate-from-image/docs/header.webp`,
    screenshots: [`${base}/generate-from-image/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/generate-from-image',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'svg-to-png',
    desc: 'Render an SVG to PNG at high resolution - right-click any .svg file in Explorer; output is always at least 2048px on its smallest dimension',
    icon: '/icons/svg-to-png.png',
    header: `${base}/svg-to-png/docs/header.webp`,
    screenshots: [`${base}/svg-to-png/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/svg-to-png',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'img-to-svg',
    desc: 'Convert a raster image to SVG vector using vtracer (fast, any image) or StarVector AI model (icons/logos/diagrams); right-click any image file in Explorer',
    icon: '/icons/img-to-svg.png',
    header: `${base}/img-to-svg/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-to-svg',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'video-description',
    desc: 'Generate a YouTube description via Gemini - auto-loads or generates a transcript, then drops into an interactive chat for revisions; right-click any video in Explorer (requires OpenRouter API key)',
    icon: '/icons/video-description.png',
    header: `${base}/video-description/docs/header.webp`,
    screenshots: [`${base}/video-description/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-description',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'copypath',
    desc: 'Copy the absolute path of a file or folder to the clipboard from the terminal; defaults to the current directory if no argument given',
    icon: '/icons/copypath.png',
    header: `${base}/copypath/docs/header.webp`,
    screenshots: [`${base}/copypath/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/copypath',
    category: 'Developer',
    platforms: ['windows'],
  },
  {
    name: 'worktrees',
    desc: 'Interactive git worktree cleanup on macOS and Windows: list primary vs linked checkouts, remove selected linked trees, or remove all linked (Bun + inquirer)',
    icon: '/icons/worktrees.png',
    header: `${base}/worktrees/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/worktrees',
    category: 'Developer',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'img-gen',
    desc: 'Chat-style AI image generation using Gemini via OpenRouter; right-click any folder in Explorer to open; annotate generated images and refine iteratively; drag images out to Explorer to save (requires OpenRouter API key)',
    icon: '/icons/img-gen.png',
    header: `${base}/img-gen/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-gen',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'video-gen',
    desc: 'Chat-style AI video generation using OpenRouter video models; right-click any folder in Explorer to open; model-aware settings, reference images, first/last frames, save or drag generated MP4s into the folder (requires OpenRouter API key)',
    icon: '/icons/video-gen.png',
    header: `${base}/video-gen/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-gen',
    category: 'Video & recording',
    platforms: ['windows'],
  },
  {
    name: 'face-swap',
    desc: 'Swap a face from one image into another locally using InsightFace; right-click any image to pre-load the target, or launch it from Windows Search',
    icon: '/icons/face-swap.png',
    header: `${base}/face-swap/docs/header.webp`,
    screenshots: [`${base}/face-swap/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/face-swap',
    category: 'Images',
    platforms: ['windows'],
  },
  {
    name: 'mac-screenshot',
    desc: 'Global macOS screenshot hotkey daemon. Press F11 to capture a selection, save it with a timestamp, copy it to the clipboard, and open it in Preview for annotation',
    icon: '/icons/mac-screenshot.png',
    header: `${base}/mac-screenshot/docs/header.webp`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/mac-screenshot',
    category: 'Images',
    platforms: ['macos'],
  },
];
