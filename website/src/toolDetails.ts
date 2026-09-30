/** The friendly copy on each tool's page, written as Mike. */
export interface ToolDetails {
  tagline: string;
  intro: string[];
}

export const toolDetails: Record<string, ToolDetails> = {
  transcribe: {
    tagline: "Right-click a video and get an .srt transcript saved right next to it",
    intro: [
      "This one takes a video, pulls the audio out with ffmpeg and runs it through Whisper, then drops an .srt file next to the original. I mostly use it from the right-click menu in Explorer so I don't have to think about it.",
      "It runs on the GPU with CUDA if it can and falls back to the CPU if that fails. There's also a speaker mode that labels lines as SPEAKER_00, SPEAKER_01 and so on, it doesn't know who anyone actually is though.",
    ],
  },
  "video-to-markdown": {
    tagline: "Turn a YouTube link into a clickable markdown thumbnail on your clipboard",
    intro: [
      "Give it a YouTube URL and it puts a markdown image link on your clipboard, so when you paste it into a README you get the video thumbnail linking back to the video.",
      "It uses the video-to-markdown.com API, which caches things on the server, so asking for the same video twice is pretty much instant.",
    ],
  },
  removebg: {
    tagline: "Right-click a photo to get a copy with the background removed",
    intro: [
      "A small wrapper around rembg using the birefnet-portrait model, so it works best on photos of people. Right-click an image and you get a new copy with the background gone, saved next to the original.",
      "The first run downloads about 1 GB of model weights, so give it a minute that first time.",
    ],
  },
  "remove-portrait": {
    tagline: "Cut the background out of a talking-head video and get a transparent .mov",
    intro: [
      "This takes a video of me talking and removes the background, writing out a transparent ProRes 4444 .mov that I can drop over a screen recording in DaVinci Resolve.",
      "By default it uses RobustVideoMatting on the GPU, which is made for video of people. The output keeps the full frame size of the source, so it lines up nicely when you place it in Resolve.",
    ],
  },
  unmultitrack: {
    tagline: "Split a multi-track OBS recording into one normal video file per track",
    intro: [
      "If you record with OBS and the Aitum multi-track plugin you end up with one file holding several video streams. This pulls each one out into its own normal video file so editors like Premiere or Resolve are happy with it.",
      "By default every audio track gets copied into each output, which is usually what I want when I bring them into an editor.",
    ],
  },
  "img-upscale": {
    tagline: "Right-click an image and upscale it 2x, 4x, 8x or 16x on your own machine",
    intro: [
      "This upscales an image locally using a Swin2SR model. Rather than one big jump it does it in 2x steps, so 4x is two steps, 8x is three and so on.",
      "It pops up a little window asking which scale you want, then saves the result next to the original in the same format. If you'd rather go quicker there's a fast backend that uses Real-ESRGAN instead.",
    ],
  },
  ghopen: {
    tagline: "Open the repo you're in on GitHub, or its pull request if there is one",
    intro: [
      "Run `ghopen` from anywhere inside a git repo and it opens it on GitHub in your browser. If the branch you're on has a pull request it opens that instead, which is usually what I actually wanted.",
      "It works in any repo, and it also links to the folder you're in rather than just the root.",
    ],
  },
  ctxmenu: {
    tagline: "Hide the clutter in your Explorer right-click menu, no admin needed",
    intro: [
      "Over time apps stuff all sorts of things into the Explorer right-click menu. This is a little window that lists them all and lets you tick them off or back on again.",
      "It only writes to your own user bit of the registry, so it doesn't need admin and everything can be undone. Some Windows 11 built-ins like Share or Cast to Device aren't in there because Explorer adds those itself.",
    ],
  },
  "color-picker": {
    tagline: "Drag over anything on screen and copy its colour as HEX, RGB, HSL and more",
    intro: [
      "A little colour picker in the style of Pixie. You hold the picker button and drag over the screen, and the window updates live with the colour under your cursor.",
      "When you let go of the mouse the value freezes, which makes copying it a lot less fiddly. It shows HEX, RGB, HSL, HLS, HSV, CMYK and BGR.",
    ],
  },
  "backup-phone": {
    tagline: "Copy every photo and video off your iPhone over USB, no iTunes needed",
    intro: [
      "Plug your iPhone in over USB and this copies all the photos and videos into one flat folder on disk. It does the newest folders first so recent stuff arrives first.",
      "HEIC photos get converted to WebP along the way, keeping the EXIF data. It skips anything that's already been copied, so you can just run it again next time.",
    ],
  },
  "scale-monitor": {
    tagline: "Flip one monitor between 200% and 300% scaling with a single click",
    intro: [
      "I bump my monitor up to 300% scaling when I'm filming, then back to 200% for normal use. This is a little popup that does it in one click instead of digging through Display settings.",
      "The change applies straight away, no signing out or rebooting.",
    ],
  },
  "sleep-monitors": {
    tagline: "Turn all your monitors off without putting the PC to sleep",
    intro: [
      "This just turns off all the connected monitors while the PC keeps running. Move the mouse or press a key and they come back on.",
      "The Start menu shortcut waits 5 seconds before doing it, otherwise the key press you launched it with wakes them straight back up.",
    ],
  },
  "task-stats": {
    tagline: "Little live graphs of your network, CPU, GPU and RAM, right next to the clock",
    intro: [
      "I used to run TrafficMonitor and XMeters on Windows, so I made my own replacement. It sits on the taskbar just to the left of the system clock and draws tiny sparkline graphs for network up and down, CPU, GPU and memory.",
      "The background is see-through so it looks like part of the taskbar, and it stays on top even when you click around. Right-click it if you want to change anything.",
    ],
  },
  taskbar: {
    tagline: "A Windows-style taskbar for your Mac, one on every monitor",
    intro: [
      "This puts a Windows-style taskbar along the bottom of every monitor on macOS. Every window gets its own button instead of being lumped in with its app, and you can pin the apps you always want there.",
      "It has a few little widgets too, like the date and time, battery, CPU and network stats, and a single button that turns my Elgato lights on and off. You can set things globally and then tweak them for each monitor.",
    ],
  },
  "last-window-quits": {
    tagline: "Close an app's last window and the app actually quits, like on Windows",
    intro: [
      "On a Mac, clicking the red close button usually leaves the app running in the Dock. This small menu-bar tool quits a normal app once its last window has been closed for a second.",
      "It tries to be careful about it. Minimised windows still count as open, Finder and friends are left alone, and it asks the app to quit the normal way so you still get any save prompts.",
    ],
  },
  "mikey-mouse": {
    tagline: "Makes a normal mouse feel at home on a Mac",
    intro: [
      "This replaces the two Mac Mouse Fix features I actually used. The side buttons on my mouse go back and forward in Finder, Safari and other Apple apps, which normally just ignore them.",
      "It also makes a notched scroll wheel glide instead of jumping a few lines at a time. It all lives in a little menu-bar icon.",
    ],
  },
  "record-it": {
    tagline: "Record your screen and camera at full resolution into separate files",
    intro: [
      "This is the recorder I use for my videos. It can record the screen, the camera, both, or just audio, and when you do both you get a separate file for each so nothing gets squished into one canvas.",
      "While it's recording, it shows a live dashboard of what's actually being written to disk, and it shouts at me if something stalls or the mic goes quiet. It also writes movies in small fragments, so a crash still leaves a file that plays.",
    ],
  },
  phonebooth: {
    tagline: "Mirror and control a few iPhones and iPads at once from your Mac over USB",
    intro: [
      "Plug in an iPhone or iPad with a cable and it pops up in its own window on the Mac. Plug in a few and they each get one. You click to tap, drag to swipe, scroll to scroll and just type to type.",
      "Apple's own iPhone Mirroring only does one phone over Wi-Fi, so this does a few more than that. The control side goes through WebDriverAgent, which takes a minute to set up the first time but then starts in a few seconds.",
    ],
  },
  "token-stats": {
    tagline: "See how many AI tokens you've been burning and roughly what that'd cost",
    intro: [
      "This is a little dashboard that reads my Codex and Claude Code session history and charts daily token usage. It also guesses what that would have cost at normal API prices, which is kinda interesting to see.",
      "It can pull exact OpenRouter usage too, and export a PNG of the graph if you want to share it.",
    ],
  },
  "record-meeting": {
    tagline: "Records an online meeting and gives you a transcript with names on it",
    intro: [
      "A small always-on-top window that records both the meeting audio coming out of the Mac and your microphone. When you stop, it saves an MP3, transcribes it locally, works out who the different speakers are and asks you to name each one.",
      "Afterwards you get a review screen where you can play the recording and click any transcript line to jump to it. It can also add each meeting as a page in a Notion database if you like.",
    ],
  },
  "meeting-archive": {
    tagline: "Records your calls when the camera comes on and files them away for later",
    intro: [
      "This is still very much a preview. It's a menu-bar app that starts recording a meeting window when the meeting app turns the camera on, and stops once the camera's been off for 20 seconds or the window closes. I've only properly tested it with Zoom so far.",
      "When a call ends it asks for a title, then sends the recording off to my home server for transcription and speaker review, and it can end up in Notion too.",
    ],
  },
  "video-hq": {
    tagline: "One place for each video project's script, renders and transcripts",
    intro: [
      "This is my command centre for making videos. Each folder in my videos directory is a project, and Video HQ loads its script and previews the rendered MP4s so I'm not hunting around in Finder.",
      "From there I can transcribe a render, generate a YouTube description, pull a script down from Notion, or open it on the Elgato Prompter. There's also a rough cut workspace for working through a raw recording.",
    ],
  },
  telemprompit: {
    tagline: "Paste your notes and read them off the Elgato Prompter one line at a time",
    intro: [
      "A teleprompter I use for talking-head recordings. You paste in your notes, plain text or Notion bullets, and it shows them on the Elgato Prompter with the current line highlighted.",
      "You can step through line by line or let it auto-scroll, and a presentation clicker works from any app, which is nice when I'm demoing something else at the same time.",
    ],
  },
  tandem: {
    tagline: "A video editor that me and my AI agents can both work on",
    intro: [
      "This is the video editor I'm building for my Convex videos to replace Filmora. It's built so my agents can edit the same project as me, through a CLI and an MCP server, while I work in the app.",
      "A project is just a `.tandem` JSON file in the video's folder. Tandem finds the media there, pairs up my Record It camera and screen takes, and does transcripts, waveforms and the cutout in the background.",
    ],
  },
  "voice-type": {
    tagline: "Hold a key, talk, let go, and your words get typed wherever you are",
    intro: [
      "This is push-to-talk dictation that runs entirely on your own machine, so no cloud and no subscription. You hold the hotkey, a little pill appears at the bottom of the screen with a waveform and a rough preview of what you're saying, and when you let go the final text gets typed into whatever window has focus.",
      "It uses Whisper under the hood. On an NVIDIA GPU or an Apple Silicon Mac (via MLX) it's pretty quick, and on plain CPU it drops to smaller models so it still keeps up. It also leaves your clipboard alone, which I was quite happy about.",
    ],
  },
  "video-titles": {
    tagline: "Right-click a video and chat with Gemini about what to call it",
    intro: [
      "I'm not great at coming up with YouTube titles, so this gives me someone to bounce ideas off. It loads the video's transcript, then drops you into a chat with Gemini that's been primed with the Compelling Title Matrix framework.",
      "If there's no transcript yet it offers to run my transcribe tool for you first. Every exchange gets saved to a text file next to the video so the ideas don't get lost.",
    ],
  },
  "generate-from-image": {
    tagline: "Right-click an image, describe a change, and get a new one back",
    intro: [
      "This one's a little terminal chat for editing images with AI. You point it at an image, type what you want, and Gemini 3 Pro makes a new image from your picture and your prompt.",
      "Each result is saved as a numbered file next to the original, so you can keep going and nothing gets overwritten. There's also a one-shot mode if you just want a single result without the chat.",
    ],
  },
  "svg-to-png": {
    tagline: "Turn an SVG into a nice big PNG with one right-click",
    intro: [
      "Sometimes you just need a PNG of an SVG and you want it big enough to actually use. This renders the SVG so its shortest side is at least 2048px, and if it's already bigger than that it keeps its natural size.",
      "The PNG lands right next to the SVG with the same name, so `logo.svg` becomes `logo.png`.",
    ],
  },
  "img-to-svg": {
    tagline: "Turn a PNG, JPEG or WebP into an SVG",
    intro: [
      "This converts raster images into SVGs. By default it uses vtracer, which is fast, runs locally and works on pretty much any image, with presets for logos and flat colour, photos, or black and white line art.",
      "If you've got an NVIDIA GPU you can also try the StarVector AI models instead, which are best for icons, logos and diagrams.",
    ],
  },
  "video-description": {
    tagline: "Get a first go at a YouTube description, then chat to tweak it",
    intro: [
      "Writing YouTube descriptions is a bit of a chore, so this reads the video's transcript and has Gemini draft one for me. You get a description, timestamps, a resources section, hashtags and a few alternative titles in one go.",
      "Then you can just chat with it to fix things up, like telling it a timestamp is off or asking it to be shorter. The conversation is saved next to the video, so if you run it again later it picks up where you left off.",
    ],
  },
  copypath: {
    tagline: "Copy the full path of a file or folder from the terminal",
    intro: [
      "Tiny one, this. Run `copypath` and the absolute path of where you are goes on your clipboard, or give it a file or folder and it copies that instead.",
      "It copes with relative paths and even paths that don't exist yet.",
    ],
  },
  worktrees: {
    tagline: "Tidy up the pile of git worktrees your AI agents leave behind",
    intro: [
      "I use this when Cursor leaves a pile of linked checkouts under `.cursor/worktrees`. It lists every worktree in the repo you're in, marks which is the primary and which are linked, and lets you pick some (or all the linked ones) to delete.",
      "It never lets you remove the primary checkout, and it asks before deleting anything. If a worktree has uncommitted changes it shows you the files first, so you don't lose work by accident.",
    ],
  },
  "img-gen": {
    tagline: "A little chat window for making and refining images with Gemini",
    intro: [
      "Image Gen is a small desktop app where you describe an image and Gemini makes it, via OpenRouter. You open it on a folder, and when you like something you can drag it out or hit download to save it there.",
      "The bit I like is that you can draw on a result, with pen, boxes, arrows and labels, and that annotated version gets used as the input for your next prompt. It's a nice way to say \"change this bit here\" without trying to describe it in words.",
    ],
  },
  "video-gen": {
    tagline: "Make short AI videos from a chat window, right from a folder",
    intro: [
      "This is like Image Gen but for video. It's a chat-style desktop app that talks to OpenRouter's video models, and it defaults to Veo 3.1 Fast.",
      "It checks what the chosen model can actually do and only shows those options, so things like resolution, duration, audio, reference images and first or last frames come and go depending on the model. Videos take a while, so it waits for the job to finish and then downloads the MP4.",
    ],
  },
  "face-swap": {
    tagline: "Swap a face from one photo into another, all on your own machine",
    intro: [
      "This uses InsightFace to swap a face from one image into another, and it all runs locally with no cloud API. It's a small window where you drop in the target image on the left and the source face on the right.",
      "While it runs you can watch the logs, so you know what's going on, and the result gets saved next to the original with `_face-swapped` on the end of the name.",
    ],
  },
  "mac-screenshot": {
    tagline: "Press F11 to grab part of the screen and start marking it up",
    intro: [
      "A little background helper for macOS. You press F11, drag out the bit of the screen you want, and it saves it to `~/Desktop/Screenshots` with a timestamp name, copies it to the clipboard and opens it in Preview so you can scribble on it straight away.",
      "It starts on login, so once it's set up you can mostly forget about it.",
    ],
  },
};
