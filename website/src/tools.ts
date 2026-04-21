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

export interface Tool {
  name: string;
  desc: string;
  icon: string;
  header?: string;
  screenshots: string[];
  url: string;
  platforms: readonly PlatformId[];
}

const base = 'https://cdn.jsdelivr.net/gh/mikecann/mikerosoft@main/tools';

export const tools: Tool[] = [
  {
    name: 'transcribe',
    desc: 'Extract audio from a video and transcribe it via faster-whisper (CUDA with CPU fallback); right-click any video file in Explorer',
    icon: `${base}/transcribe/icons/film.png`,
    header: `${base}/transcribe/docs/header.png`,
    screenshots: [`${base}/transcribe/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/transcribe',
    platforms: ['windows'],
  },
  {
    name: 'video-to-markdown',
    desc: 'Convert a YouTube URL to a markdown image-link and copy it to clipboard; right-click any .url Internet Shortcut in Explorer',
    icon: `${base}/video-to-markdown/icons/page_white_link.png`,
    header: `${base}/video-to-markdown/docs/header.png`,
    screenshots: [
      `${base}/video-to-markdown/docs/ss1.png`,
      `${base}/video-to-markdown/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-to-markdown',
    platforms: ['windows'],
  },
  {
    name: 'removebg',
    desc: 'Remove the background from an image using rembg / birefnet-portrait; right-click any image file in Explorer',
    icon: `${base}/removebg/icons/picture.png`,
    header: `${base}/removebg/docs/header.png`,
    screenshots: [`${base}/removebg/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/removebg',
    platforms: ['windows'],
  },
  {
    name: 'img-upscale',
    desc: 'Upscale an image locally with a quality-first transformer backend; right-click any image file in Explorer, choose 2x, 4x, 8x, or 16x, and keep the original file format',
    icon: `${base}/img-upscale/icons/picture.png`,
    header: `${base}/img-upscale/docs/header.png`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-upscale',
    platforms: ['windows'],
  },
  {
    name: 'ghopen',
    desc: 'Open the current repo on GitHub; opens the PR page if on a PR branch; right-click any folder in Explorer',
    icon: `${base}/ghopen/icons/world_go.png`,
    header: `${base}/ghopen/docs/header.png`,
    screenshots: [`${base}/ghopen/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/ghopen',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'ctxmenu',
    desc: 'Manage Explorer context menu entries - toggle shell verbs and COM handlers on/off without admin rights',
    icon: `${base}/ctxmenu/icons/application_form.png`,
    header: `${base}/ctxmenu/docs/header.png`,
    screenshots: [`${base}/ctxmenu/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/ctxmenu',
    platforms: ['windows'],
  },
  {
    name: 'backup-phone',
    desc: 'Back up an iPhone over MTP (USB) to a flat folder on disk',
    icon: `${base}/backup-phone/icons/phone.png`,
    header: `${base}/backup-phone/docs/header.png`,
    screenshots: [`${base}/backup-phone/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/backup-phone',
    platforms: ['windows'],
  },
  {
    name: 'scale-monitor',
    desc: 'Toggle Monitor 4 between 200% (normal) and 300% (filming) scaling',
    icon: `${base}/scale-monitor/icons/monitor.png`,
    header: `${base}/scale-monitor/docs/header.png`,
    screenshots: [
      `${base}/scale-monitor/docs/ss1.png`,
      `${base}/scale-monitor/docs/ss2.png`,
    ],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/scale-monitor',
    platforms: ['windows'],
  },
  {
    name: 'task-stats',
    desc: 'Real-time NET/CPU/GPU/MEM sparklines overlaid on the taskbar',
    icon: `${base}/task-stats/icons/chart_bar.png`,
    header: `${base}/task-stats/docs/header.png`,
    screenshots: [`${base}/task-stats/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/task-stats',
    platforms: ['windows'],
  },
  {
    name: 'voice-type',
    desc: 'Push-to-talk local voice transcription for Windows and macOS. On Apple Silicon it uses MLX for faster final transcription',
    icon: `${base}/voice-type/icons/sound.png`,
    header: `${base}/voice-type/docs/header.png`,
    screenshots: [`${base}/voice-type/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/voice-type',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'video-titles',
    desc: 'Chat with an AI agent to ideate YouTube titles using the Compelling Title Matrix framework; right-click any video in Explorer (requires OpenRouter API key)',
    icon: `${base}/video-titles/icons/video-titles.png`,
    header: `${base}/video-titles/docs/header.png`,
    screenshots: [`${base}/video-titles/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-titles',
    platforms: ['windows'],
  },
  {
    name: 'generate-from-image',
    desc: 'AI image generation from a reference image - right-click any image in Explorer, describe what you want, and Gemini 3 Pro generates a new image (requires OpenRouter API key)',
    icon: `${base}/generate-from-image/icons/wand.png`,
    header: `${base}/generate-from-image/docs/header.png`,
    screenshots: [`${base}/generate-from-image/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/generate-from-image',
    platforms: ['windows'],
  },
  {
    name: 'svg-to-png',
    desc: 'Render an SVG to PNG at high resolution - right-click any .svg file in Explorer; output is always at least 2048px on its smallest dimension',
    icon: `${base}/svg-to-png/icons/svg-to-png.png`,
    header: `${base}/svg-to-png/docs/header.png`,
    screenshots: [`${base}/svg-to-png/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/svg-to-png',
    platforms: ['windows'],
  },
  {
    name: 'img-to-svg',
    desc: 'Convert a raster image to SVG vector using vtracer (fast, any image) or StarVector AI model (icons/logos/diagrams); right-click any image file in Explorer',
    icon: `${base}/img-to-svg/icons/img-to-svg.png`,
    header: `${base}/img-to-svg/docs/header.png`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-to-svg',
    platforms: ['windows'],
  },
  {
    name: 'video-description',
    desc: 'Generate a YouTube description via Gemini - auto-loads or generates a transcript, then drops into an interactive chat for revisions; right-click any video in Explorer (requires OpenRouter API key)',
    icon: `${base}/video-description/icons/video-description.png`,
    header: `${base}/video-description/docs/header.png`,
    screenshots: [`${base}/video-description/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/video-description',
    platforms: ['windows'],
  },
  {
    name: 'copypath',
    desc: 'Copy the absolute path of a file or folder to the clipboard from the terminal; defaults to the current directory if no argument given',
    icon: `${base}/copypath/icons/page_copy.png`,
    header: `${base}/copypath/docs/header.png`,
    screenshots: [`${base}/copypath/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/copypath',
    platforms: ['windows'],
  },
  {
    name: 'worktrees',
    desc: 'Interactive git worktree cleanup on macOS and Windows: list primary vs linked checkouts, remove selected linked trees, or remove all linked (Bun + inquirer)',
    icon: `${base}/worktrees/icons/worktrees.png`,
    header: `${base}/worktrees/docs/header.png`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/worktrees',
    platforms: ['windows', 'macos'],
  },
  {
    name: 'img-gen',
    desc: 'Chat-style AI image generation using Gemini via OpenRouter; right-click any folder in Explorer to open; annotate generated images and refine iteratively; drag images out to Explorer to save (requires OpenRouter API key)',
    icon: `${base}/img-gen/icons/img-gen.png`,
    header: `${base}/img-gen/docs/header.png`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/img-gen',
    platforms: ['windows'],
  },
  {
    name: 'face-swap',
    desc: 'Swap a face from one image into another locally using InsightFace; right-click any image to pre-load the target, or launch it from Windows Search',
    icon: `${base}/face-swap/icons/face-swap.png`,
    header: `${base}/face-swap/docs/header.png`,
    screenshots: [`${base}/face-swap/docs/ss1.png`],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/face-swap',
    platforms: ['windows'],
  },
  {
    name: 'mac-screenshot',
    desc: 'Global macOS screenshot hotkey daemon. Press F12 to capture a selection, save it with a timestamp, copy it to the clipboard, and open it in Preview for annotation',
    icon: `${base}/mac-screenshot/icons/mac-screenshot.png`,
    header: `${base}/mac-screenshot/docs/header.png`,
    screenshots: [],
    url: 'https://github.com/mikecann/mikerosoft/tree/main/tools/mac-screenshot',
    platforms: ['macos'],
  },
];
