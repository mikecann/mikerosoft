/** The friendly copy on each tool's page, written as Mike. */
export interface ToolDetails {
  tagline: string;
  intro: string[];
  howToUse: string[];
  requirements: string[];
  /** Anything wired to Mike's own setup that you'd want to change. */
  specificToMike?: string;
}

export const toolDetails: Record<string, ToolDetails> = {
  transcribe: {
    tagline: "Right-click a video and get an .srt transcript saved right next to it",
    intro: [
      "This one takes a video, pulls the audio out with ffmpeg and runs it through Whisper, then drops an .srt file next to the original. I mostly use it from the right-click menu in Explorer so I don't have to think about it.",
      "It runs on the GPU with CUDA if it can and falls back to the CPU if that fails. There's also a speaker mode that labels lines as SPEAKER_00, SPEAKER_01 and so on, it doesn't know who anyone actually is though.",
    ],
    howToUse: [
      "Right-click any video file in Explorer and choose Mike's Tools > Transcribe Video (on Windows 11 click \"Show more options\" first).",
      "If you want speaker labels, pick Mike's Tools > Transcribe with Speakers instead. It uses the slower `large-v3` model.",
      "Or from a terminal run `transcribe <video_file>`, adding `--diarize` for speakers or `--cpu` to skip the GPU.",
      "When it finishes, open `<video_name>.srt` in the same folder as the video.",
    ],
    requirements: [
      "Windows: ffmpeg.exe and faster-whisper-xxl.exe downloaded into C:\\dev\\tools",
      "An NVIDIA GPU with CUDA is recommended (CPU works, just slower)",
      "macOS / Linux: ffmpeg on PATH and the faster-whisper Python package",
      "For speaker labels: Python with pyannote.audio and a Hugging Face token with access to the pyannote model",
    ],
    specificToMike: "The Windows version expects its binaries and models in C:\\dev\\tools, so you'd point it somewhere else if your setup differs.",
  },
  "video-to-markdown": {
    tagline: "Turn a YouTube link into a clickable markdown thumbnail on your clipboard",
    intro: [
      "Give it a YouTube URL and it puts a markdown image link on your clipboard, so when you paste it into a README you get the video thumbnail linking back to the video.",
      "It uses the video-to-markdown.com API, which caches things on the server, so asking for the same video twice is pretty much instant.",
    ],
    howToUse: [
      "Copy a YouTube URL from your browser.",
      "Right-click anything in Explorer and choose Mike's Tools > Video to Markdown.",
      "The URL is already filled in from your clipboard, so just press Enter.",
      "When you see \"Copied to clipboard!\", paste it into your markdown file.",
      "From a terminal you can also run `video-to-markdown <youtube_url>`, or point it at a `.url` Internet Shortcut file.",
    ],
    requirements: [
      "Bun",
      "An internet connection",
      "No API key needed",
    ],
  },
  removebg: {
    tagline: "Right-click a photo to get a copy with the background removed",
    intro: [
      "A small wrapper around rembg using the birefnet-portrait model, so it works best on photos of people. Right-click an image and you get a new copy with the background gone, saved next to the original.",
      "The first run downloads about 1 GB of model weights, so give it a minute that first time.",
    ],
    howToUse: [
      "Right-click an image (.jpg, .png, .webp, .bmp or .tiff) in Explorer and choose Mike's Tools > Remove Background (on Windows 11 click \"Show more options\" first).",
      "Or from a terminal run `removebg <image_file>`.",
      "Open the new file next to the original, it has `_nobg` added to the name, e.g. `photo_nobg.jpg`.",
    ],
    requirements: [
      "Python with rembg (rembg[gpu] if you have a GPU, the CPU version works too)",
      "About 1 GB of disk for the model, downloaded on first run",
    ],
  },
  "remove-portrait": {
    tagline: "Cut the background out of a talking-head video and get a transparent .mov",
    intro: [
      "This takes a video of me talking and removes the background, writing out a transparent ProRes 4444 .mov that I can drop over a screen recording in DaVinci Resolve.",
      "By default it uses RobustVideoMatting on the GPU, which is made for video of people. The output keeps the full frame size of the source, so it lines up nicely when you place it in Resolve.",
    ],
    howToUse: [
      "Right-click a video file in Explorer and choose Mike's Tools > Remove Portrait Background.",
      "Or from a terminal run `remove-portrait <video_file>`.",
      "To try out settings quickly first, add `--sample-seconds 3 --max-width 960` so it only does a short, smaller chunk.",
      "Grab `<video_name>_portrait_removed.mov` from the same folder and drop it onto your timeline above the screen recording.",
    ],
    requirements: [
      "Windows",
      "An NVIDIA GPU with CUDA (it's slow on the CPU, especially at 4K)",
      "Python with PyTorch, set up by deps.ps1",
      "ffmpeg",
    ],
    specificToMike: "The model files are expected in C:\\dev\\tools\\_models\\remove-portrait, and the output defaults are tuned for importing into DaVinci Resolve.",
  },
  unmultitrack: {
    tagline: "Split a multi-track OBS recording into one normal video file per track",
    intro: [
      "If you record with OBS and the Aitum multi-track plugin you end up with one file holding several video streams. This pulls each one out into its own normal video file so editors like Premiere or Resolve are happy with it.",
      "By default every audio track gets copied into each output, which is usually what I want when I bring them into an editor.",
    ],
    howToUse: [
      "Right-click the recording in Explorer and choose Mike's Tools > Un-multi-track Video.",
      "Or from a terminal run `unmultitrack \"recording.mp4\"`.",
      "Open the new `recording_unmultitracked` folder next to it, which has `recording_v1.mp4`, `recording_v2.mp4` and so on.",
      "Add `--video-only` if you don't want the audio, or `--dry-run` to see what it would do first.",
    ],
    requirements: [
      "Windows",
      "ffmpeg (in C:\\dev\\tools or on PATH), ffprobe is optional",
    ],
  },
  "img-upscale": {
    tagline: "Right-click an image and upscale it 2x, 4x, 8x or 16x on your own machine",
    intro: [
      "This upscales an image locally using a Swin2SR model. Rather than one big jump it does it in 2x steps, so 4x is two steps, 8x is three and so on.",
      "It pops up a little window asking which scale you want, then saves the result next to the original in the same format. If you'd rather go quicker there's a fast backend that uses Real-ESRGAN instead.",
    ],
    howToUse: [
      "Right-click an image in Explorer and choose Mike's Tools > Upscale Image (on Windows 11 click \"Show more options\" first).",
      "Pick 2x, 4x, 8x or 16x in the window that pops up.",
      "Find the result next to the original with the scale added to the name, e.g. `photo_x4.png`.",
      "From a terminal you can run `img-upscale <image_file> --scale 4`, or add `--backend fast` for the Real-ESRGAN version.",
    ],
    requirements: [
      "Python with torch, transformers, huggingface-hub, safetensors, numpy and Pillow",
      "The Swin2SR model downloads from Hugging Face on first run",
      "Optional: realesrgan-ncnn-vulkan.exe in C:\\dev\\tools for the fast backend",
    ],
  },
  ghopen: {
    tagline: "Open the repo you're in on GitHub, or its pull request if there is one",
    intro: [
      "Run `ghopen` from anywhere inside a git repo and it opens it on GitHub in your browser. If the branch you're on has a pull request it opens that instead, which is usually what I actually wanted.",
      "It works in any repo, and it also links to the folder you're in rather than just the root.",
    ],
    howToUse: [
      "`cd` into any folder inside a git repo.",
      "Run `ghopen`, no arguments needed.",
      "On Windows you can also right-click a folder (or the empty space inside one) and choose Mike's Tools > Open on GitHub.",
      "On a Mac, run `bash tools/ghopen/setup_mac.sh` once to put `ghopen` on your PATH.",
    ],
    requirements: [
      "Windows or macOS",
      "Git",
      "The GitHub CLI (`gh`) for PR detection. Without it, it just opens the repo root from your origin remote",
    ],
  },
  ctxmenu: {
    tagline: "Hide the clutter in your Explorer right-click menu, no admin needed",
    intro: [
      "Over time apps stuff all sorts of things into the Explorer right-click menu. This is a little window that lists them all and lets you tick them off or back on again.",
      "It only writes to your own user bit of the registry, so it doesn't need admin and everything can be undone. Some Windows 11 built-ins like Share or Cast to Device aren't in there because Explorer adds those itself.",
    ],
    howToUse: [
      "Run `ctxmenu`, or search for it in the Start menu.",
      "Pick the kind of menu you want to look at from Show menu for:, e.g. All Files, Folders or Image Files.",
      "Untick the entries you don't want, or select a few and click Disable Selected.",
      "Right-click something in Explorer to check, the change applies straight away without restarting Explorer.",
      "Tick an entry again if you want it back.",
    ],
    requirements: [
      "Windows",
      "Nothing else, it uses the built-in .NET WinForms",
    ],
  },
  "color-picker": {
    tagline: "Drag over anything on screen and copy its colour as HEX, RGB, HSL and more",
    intro: [
      "A little colour picker in the style of Pixie. You hold the picker button and drag over the screen, and the window updates live with the colour under your cursor.",
      "When you let go of the mouse the value freezes, which makes copying it a lot less fiddly. It shows HEX, RGB, HSL, HLS, HSV, CMYK and BGR.",
    ],
    howToUse: [
      "Launch Color Picker from Windows Search, or run `color-picker`.",
      "Hold the picker button and drag over the screen to the colour you want.",
      "Let go of the mouse to freeze it.",
      "Click Copy HEX, Copy all, or the Copy button next to whichever format you need.",
    ],
    requirements: [
      "Windows",
      "Nothing else, it uses the built-in .NET WinForms",
    ],
  },
  "backup-phone": {
    tagline: "Copy every photo and video off your iPhone over USB, no iTunes needed",
    intro: [
      "Plug your iPhone in over USB and this copies all the photos and videos into one flat folder on disk. It does the newest folders first so recent stuff arrives first.",
      "HEIC photos get converted to WebP along the way, keeping the EXIF data. It skips anything that's already been copied, so you can just run it again next time.",
    ],
    howToUse: [
      "Plug your iPhone in with a USB cable, unlock it and tap \"Trust This Computer\".",
      "Run `backup-phone` in a terminal, or `backup-phone -Destination E:\\photos` to pick a different folder.",
      "Press Enter when it asks if you're ready (or add `-Yes` to skip that).",
      "Leave it running until it's done, then look in the destination folder.",
    ],
    requirements: [
      "Windows",
      "An iPhone connected over USB",
      "Python with Pillow and pillow-heif",
    ],
    specificToMike: "It copies to D:\\bak\\photos by default, so pass -Destination if that drive doesn't exist for you.",
  },
  "scale-monitor": {
    tagline: "Flip one monitor between 200% and 300% scaling with a single click",
    intro: [
      "I bump my monitor up to 300% scaling when I'm filming, then back to 200% for normal use. This is a little popup that does it in one click instead of digging through Display settings.",
      "The change applies straight away, no signing out or rebooting.",
    ],
    howToUse: [
      "Click the Scale Monitor taskbar shortcut, or search for it in the Start menu.",
      "A small popup appears near the bottom right showing the current scale.",
      "Click 200% or 300% to switch.",
    ],
    requirements: [
      "Windows",
    ],
    specificToMike: "It's hardcoded to the registry key for my HG584T05 monitor (Display 4), so you'd need to swap in the key for your own display.",
  },
  "sleep-monitors": {
    tagline: "Turn all your monitors off without putting the PC to sleep",
    intro: [
      "This just turns off all the connected monitors while the PC keeps running. Move the mouse or press a key and they come back on.",
      "The Start menu shortcut waits 5 seconds before doing it, otherwise the key press you launched it with wakes them straight back up.",
    ],
    howToUse: [
      "Search for Sleep Monitors in the Start menu and hit Enter.",
      "Take your hands off the keyboard and mouse, the screens go off after about 5 seconds.",
      "Move the mouse or press a key to wake them.",
      "From a terminal you can run `sleep-monitors`, or `sleep-monitors -DelaySeconds 3` to set your own delay.",
    ],
    requirements: [
      "Windows",
    ],
  },
  "task-stats": {
    tagline: "Little live graphs of your network, CPU, GPU and RAM, right next to the clock",
    intro: [
      "I used to run TrafficMonitor and XMeters on Windows, so I made my own replacement. It sits on the taskbar just to the left of the system clock and draws tiny sparkline graphs for network up and down, CPU, GPU and memory.",
      "The background is see-through so it looks like part of the taskbar, and it stays on top even when you click around. Right-click it if you want to change anything.",
    ],
    howToUse: [
      "Run `task-stats` from a terminal, or click the taskbar shortcut that `install.ps1` makes.",
      "Look to the left of the clock and the graphs should be ticking along.",
      "Right-click the overlay and choose **Settings...** to change what's shown and how it looks.",
      "The same right-click menu has **Open Task Manager** and **Open Resource Monitor** if you want to dig into something.",
      "Choose **Quit** from that menu to close it.",
    ],
    requirements: [
      "Windows",
      ".NET 10 SDK to build it",
      "An NVIDIA GPU and driver for the GPU graph (it uses `nvml.dll`)",
    ],
  },
  taskbar: {
    tagline: "A Windows-style taskbar for your Mac, one on every monitor",
    intro: [
      "This puts a Windows-style taskbar along the bottom of every monitor on macOS. Every window gets its own button instead of being lumped in with its app, and you can pin the apps you always want there.",
      "It has a few little widgets too, like the date and time, battery, CPU and network stats, and a single button that turns my Elgato lights on and off. You can set things globally and then tweak them for each monitor.",
    ],
    howToUse: [
      "Run `bash tools/taskbar/setup_mac.sh` then `bash tools/taskbar/restart.sh` to get it going.",
      "Grant **Mikerosoft Taskbar** Screen Recording access so window titles show up, and Accessibility if you want windows kept above the bar.",
      "Click a window's button to switch to it, and click it again to minimise it.",
      "Right-click any taskbar and choose settings to change size, spacing, auto-hide, pinned apps and widgets for that monitor.",
      "If you ran `install_mac.sh` you can use `taskbar restart`, `taskbar settings` and `taskbar stop`.",
    ],
    requirements: [
      "macOS 13 or newer",
      "Xcode or the Command Line Tools to build it",
      "Screen Recording permission, plus Accessibility for keeping windows above the bar and for the badges",
      "Local Network permission and Elgato lights if you want the lights widget",
    ],
    specificToMike: "Turning the lights on also opens `~/Applications/Record It.app`, and the optional prompter switch expects an Elgato Prompter on DisplayLink.",
  },
  "last-window-quits": {
    tagline: "Close an app's last window and the app actually quits, like on Windows",
    intro: [
      "On a Mac, clicking the red close button usually leaves the app running in the Dock. This small menu-bar tool quits a normal app once its last window has been closed for a second.",
      "It tries to be careful about it. Minimised windows still count as open, Finder and friends are left alone, and it asks the app to quit the normal way so you still get any save prompts.",
    ],
    howToUse: [
      "Run `bash tools/last-window-quits/setup_mac.sh`. It builds the app, starts it and adds it to login.",
      "Give **Last Window Quits** access in System Settings > Privacy & Security > Accessibility.",
      "Look for **LWQ** in the menu bar. If it says `LWQ!` it's still waiting on that permission.",
      "Now just close windows as normal, and once an app's last one is gone for a second it quits.",
      "Use the **LWQ** menu to pause it, toggle start at login, or quit.",
    ],
    requirements: [
      "macOS 13 or newer",
      "Xcode or the Command Line Tools to build it",
      "Accessibility permission",
    ],
  },
  "mikey-mouse": {
    tagline: "Makes a normal mouse feel at home on a Mac",
    intro: [
      "This replaces the two Mac Mouse Fix features I actually used. The side buttons on my mouse go back and forward in Finder, Safari and other Apple apps, which normally just ignore them.",
      "It also makes a notched scroll wheel glide instead of jumping a few lines at a time. It all lives in a little menu-bar icon.",
    ],
    howToUse: [
      "Quit Mac Mouse Fix, SensibleSideButtons or LinearMouse first, as two tools on the same buttons will fight.",
      "Run `bash tools/mikey-mouse/setup_mac.sh`. It builds the app, starts it and adds it to login.",
      "Give **Mikey Mouse** access in System Settings > Privacy & Security > Accessibility. The menu-bar icon shows `!` until you do.",
      "Press the side buttons over Finder or Safari to go back and forward, and scroll as normal.",
      "Use the menu-bar icon to turn each feature on or off and pick the scroll speed and smoothness.",
    ],
    requirements: [
      "macOS 13 or newer",
      "Xcode or the Command Line Tools to build it",
      "A mouse with side buttons and a notched wheel",
      "Accessibility permission",
    ],
  },
  "record-it": {
    tagline: "Record your screen and camera at full resolution into separate files",
    intro: [
      "This is the recorder I use for my videos. It can record the screen, the camera, both, or just audio, and when you do both you get a separate file for each so nothing gets squished into one canvas.",
      "While it's recording, it shows a live dashboard of what's actually being written to disk, and it shouts at me if something stalls or the mic goes quiet. It also writes movies in small fragments, so a crash still leaves a file that plays.",
    ],
    howToUse: [
      "Run `bash tools/record-it/setup_mac.sh` and `bash install_mac.sh`, then launch it with `record-it`.",
      "Pick **Screen**, **Camera**, **Both** or **Audio**, then choose your display, camera and microphone.",
      "Use the **Preview…** button next to the camera if you want to check your framing first.",
      "Pick a project from the Project menu, or **No Project** to save into `~/Movies/record-it-output`.",
      "Hit record, and when you stop it can show the finished files in Finder.",
      "Open **Encoder → Settings…** if you want to change the encoder or quality.",
    ],
    requirements: [
      "macOS 14 or newer",
      "Xcode or the Command Line Tools to build it",
      "Screen Recording, Camera and Microphone permissions",
      "A MacBook Pro built-in mic for camera or audio takes, since it records a backup track from it",
    ],
    specificToMike: "It defaults to my `HG584T05` display and a mic with `Yeti` in its name, and the project list comes from `~/dev/convex/convex-videos`.",
  },
  phonebooth: {
    tagline: "Mirror and control a few iPhones and iPads at once from your Mac over USB",
    intro: [
      "Plug in an iPhone or iPad with a cable and it pops up in its own window on the Mac. Plug in a few and they each get one. You click to tap, drag to swipe, scroll to scroll and just type to type.",
      "Apple's own iPhone Mirroring only does one phone over Wi-Fi, so this does a few more than that. The control side goes through WebDriverAgent, which takes a minute to set up the first time but then starts in a few seconds.",
    ],
    howToUse: [
      "Run `bash tools/phonebooth/setup_mac.sh`, then open **Phonebooth** from Spotlight.",
      "Sign into Xcode with your Apple ID under Xcode > Settings > Accounts.",
      "Turn on Developer Mode on each phone in Settings > Privacy & Security > Developer Mode.",
      "Plug the phone in and unlock it. The first time it builds and installs the helper, which takes about a minute.",
      "Click, drag, scroll and type in the window. ⇧⌘H is Home and ⌘V types your Mac clipboard into the phone.",
      "Use ⌘1 to ⌘9 to jump between phone windows.",
    ],
    requirements: [
      "macOS 14 or newer",
      "Xcode, signed in with an Apple ID (a paid developer team lasts a year, a free one expires after 7 days)",
      "Developer Mode on each iPhone or iPad",
      "A USB cable per phone",
      "Camera permission, as macOS treats the phone screen like a camera",
    ],
  },
  "token-stats": {
    tagline: "See how many AI tokens you've been burning and roughly what that'd cost",
    intro: [
      "This is a little dashboard that reads my Codex and Claude Code session history and charts daily token usage. It also guesses what that would have cost at normal API prices, which is kinda interesting to see.",
      "It can pull exact OpenRouter usage too, and export a PNG of the graph if you want to share it.",
    ],
    howToUse: [
      "Run `bash tools/token-stats/setup_mac.sh` and `bash install_mac.sh`, then launch it with `token-stats`.",
      "Your Codex and Claude history shows up by itself.",
      "Switch between 7, 30, 90 day and all-time ranges, and between tokens and cost.",
      "For OpenRouter, make a management key and choose **Connect API**.",
      "For older OpenRouter history, export a CSV from openrouter.ai/activity and choose **Add history CSV** from the OpenRouter menu.",
    ],
    requirements: [
      "macOS 14 or newer",
      "Xcode or the Command Line Tools to build it",
      "Codex and/or Claude Code session logs on the Mac",
      "Optional: an OpenRouter management key",
    ],
  },
  "record-meeting": {
    tagline: "Records an online meeting and gives you a transcript with names on it",
    intro: [
      "A small always-on-top window that records both the meeting audio coming out of the Mac and your microphone. When you stop, it saves an MP3, transcribes it locally, works out who the different speakers are and asks you to name each one.",
      "Afterwards you get a review screen where you can play the recording and click any transcript line to jump to it. It can also add each meeting as a page in a Notion database if you like.",
    ],
    howToUse: [
      "Run `bash tools/record-meeting/setup_mac.sh` and `bash install_mac.sh`, then launch it with `record-meeting`.",
      "Allow Screen & System Audio Recording and Microphone access when macOS asks.",
      "Pop your headphones on, as speakers can echo back into the mic.",
      "Hit record when the meeting starts and stop when it ends.",
      "Listen to the short voice clips and name each speaker, then review the transcript.",
      "Check Preferences to change the output folder, the Whisper model, or set up Notion.",
    ],
    requirements: [
      "macOS 15 or newer",
      "Xcode or the Command Line Tools",
      "`ffmpeg`",
      "A Hugging Face token with access to `pyannote/speaker-diarization-community-1`",
      "Optional: a Notion integration token",
    ],
  },
  "meeting-archive": {
    tagline: "Records your calls when the camera comes on and files them away for later",
    intro: [
      "This is still very much a preview. It's a menu-bar app that starts recording a meeting window when the meeting app turns the camera on, and stops once the camera's been off for 20 seconds or the window closes. I've only properly tested it with Zoom so far.",
      "When a call ends it asks for a title, then sends the recording off to my home server for transcription and speaker review, and it can end up in Notion too.",
    ],
    howToUse: [
      "Run `bash tools/meeting-archive/setup_mac.sh`, then open **Meeting Archive** yourself.",
      "Use Settings to request Accessibility, Screen & System Audio Recording, Microphone, Notifications and Calendar access.",
      "Join a call and turn your camera on, and recording starts by itself.",
      "When it ends, type a title into the little panel and press Return, or let it save on its own after 90 seconds.",
      "When speakers are ready, confirm the names and choose **Complete**.",
    ],
    requirements: [
      "macOS 15 or newer",
      "Xcode or the Command Line Tools to build it",
      "A second machine to do the processing, reachable over the network",
      "Zoom (Teams and Slack are there but untested, and Chrome doesn't work yet)",
    ],
    specificToMike: "It sends everything to my home server Bruce at `/Volumes/CannMedia/MeetingArchive`, so you'd need your own machine running the worker.",
  },
  "video-hq": {
    tagline: "One place for each video project's script, renders and transcripts",
    intro: [
      "This is my command centre for making videos. Each folder in my videos directory is a project, and Video HQ loads its script and previews the rendered MP4s so I'm not hunting around in Finder.",
      "From there I can transcribe a render, generate a YouTube description, pull a script down from Notion, or open it on the Elgato Prompter. There's also a rough cut workspace for working through a raw recording.",
    ],
    howToUse: [
      "Run `bash tools/transcribe/deps.sh` and `bash tools/video-hq/setup_mac.sh`, then open **Video HQ** from Spotlight.",
      "Pick a project from the dropdown, or choose **New Project** to start one.",
      "Use **Script** to load `script.md` or download one from a Notion page.",
      "Use the Render picker to choose a video, then **Transcribe** or **Video Description**.",
      "Open **Rough Cut Process** to work through a source recording.",
    ],
    requirements: [
      "macOS 13 or newer",
      "Xcode or the Command Line Tools",
      "`ffmpeg` and `faster-whisper` for transcription",
      "`OPENROUTER_API_KEY` for descriptions and `NOTION_API_KEY` for scripts, in the repo's `.env`",
      "Codex CLI, signed in, for the rough cut steps",
    ],
    specificToMike: "Projects default to `~/dev/convex/convex-videos` (change it with `VIDEO_HQ_PROJECTS_ROOT`), and the rough cut side leans on my `automate-filmora` checkout.",
  },
  telemprompit: {
    tagline: "Paste your notes and read them off the Elgato Prompter one line at a time",
    intro: [
      "A teleprompter I use for talking-head recordings. You paste in your notes, plain text or Notion bullets, and it shows them on the Elgato Prompter with the current line highlighted.",
      "You can step through line by line or let it auto-scroll, and a presentation clicker works from any app, which is nice when I'm demoing something else at the same time.",
    ],
    howToUse: [
      "Run `bash tools/telemprompit/setup_mac.sh`, then open **Telemprompit** from Spotlight or run `telemprompit`.",
      "Copy your notes and press ⌘V to paste them in.",
      "Click, press Space or use the arrow keys to go to the next line, and right-click to go back.",
      "Press P to start or pause auto-scroll, and `[` or `]` to change the speed.",
      "Press M to mirror it for beam-splitter glass, and ⌘, for settings.",
    ],
    requirements: [
      "macOS 14 or newer",
      "Xcode or the Command Line Tools to build it",
      "An Elgato Prompter is nice but optional, it opens as a normal window without one",
      "Accessibility permission if you want it to switch the Prompter on for you",
    ],
  },
  tandem: {
    tagline: "A video editor that me and my AI agents can both work on",
    intro: [
      "This is the video editor I'm building for my Convex videos to replace Filmora. It's built so my agents can edit the same project as me, through a CLI and an MCP server, while I work in the app.",
      "A project is just a `.tandem` JSON file in the video's folder. Tandem finds the media there, pairs up my Record It camera and screen takes, and does transcripts, waveforms and the cutout in the background.",
    ],
    howToUse: [
      "Run `bash tools/tandem/setup_mac.sh` and `bash install_mac.sh`.",
      "Open the editor with `tandem app`, or `tandem app project.tandem` for a specific project.",
      "To let Claude Code edit too, run `claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp` once.",
      "Bring in an old Filmora project with `tandem import filmora \"Video v3.wfp\"`.",
      "Use File > Archive project… before moving a project to another Mac.",
      "Run `tandem help` to see what else the CLI can do.",
    ],
    requirements: [
      "macOS 15 or newer",
      "Xcode or the Command Line Tools to build it",
      "Optional: Claude Code or another MCP client for the agent side",
    ],
    specificToMike: "It's built around my Record It takes and my Convex video projects, and its shared stickers, music and fonts live in `~/Movies/Tandem Library`.",
  },
  "voice-type": {
    tagline: "Hold a key, talk, let go, and your words get typed wherever you are",
    intro: [
      "This is push-to-talk dictation that runs entirely on your own machine, so no cloud and no subscription. You hold the hotkey, a little pill appears at the bottom of the screen with a waveform and a rough preview of what you're saying, and when you let go the final text gets typed into whatever window has focus.",
      "It uses Whisper under the hood. On an NVIDIA GPU or an Apple Silicon Mac (via MLX) it's pretty quick, and on plain CPU it drops to smaller models so it still keeps up. It also leaves your clipboard alone, which I was quite happy about.",
    ],
    howToUse: [
      "Click into any text box, editor, chat app or terminal.",
      "Hold the hotkey: Right Ctrl on Windows, or F12 or Right Ctrl on macOS.",
      "Talk while watching the overlay, the partial transcript builds up as you go.",
      "Let go of the key and the final text is typed into the focused window.",
      "To change settings, right-click the tray microphone on Windows, or on macOS type `Voice Type` into Spotlight (or run `bash tools/voice-type/open-settings-mac.sh`).",
      "On macOS, click History... in Settings to see past transcriptions, and click a row to copy it.",
    ],
    requirements: [
      "Windows with Python on PATH, or macOS with Homebrew (Apple Silicon recommended for the MLX speedup)",
      "Dependencies installed with `deps.ps1` on Windows or `setup_mac.sh` on macOS",
      "Internet on first run so the Whisper models can download from Hugging Face",
      "Optional NVIDIA GPU with CUDA on Windows for faster transcription",
      "On macOS, Accessibility and Microphone permissions",
    ],
    specificToMike: "The default microphone in settings.json is \"Yeti Stereo Microphone\", so pick your own mic (or System Default) in Settings.",
  },
  "video-titles": {
    tagline: "Right-click a video and chat with Gemini about what to call it",
    intro: [
      "I'm not great at coming up with YouTube titles, so this gives me someone to bounce ideas off. It loads the video's transcript, then drops you into a chat with Gemini that's been primed with the Compelling Title Matrix framework.",
      "If there's no transcript yet it offers to run my transcribe tool for you first. Every exchange gets saved to a text file next to the video so the ideas don't get lost.",
    ],
    howToUse: [
      "Right-click a video in File Explorer and choose Mike's Tools > Video Titles (on Windows 11 click \"Show more options\" first), or run `video-titles <video_file>`.",
      "If there's a `<videoname>.srt` next to the video it gets loaded, otherwise say yes to generating one with `transcribe`.",
      "Type a message and press Enter to chat about title ideas.",
      "Type `quit` when you're done.",
      "Find the whole conversation in `<videoname>-titles.txt` next to the video.",
    ],
    requirements: [
      "An OpenRouter API key as `OPENROUTER_API_KEY` in the repo root `.env`",
      "Bun",
      "The `transcribe` tool, only if you want it to make transcripts for you",
    ],
    specificToMike: "The system prompt is written for developer-focused YouTube content, so you might want to tweak it in `index.ts` for your own channel.",
  },
  "generate-from-image": {
    tagline: "Right-click an image, describe a change, and get a new one back",
    intro: [
      "This one's a little terminal chat for editing images with AI. You point it at an image, type what you want, and Gemini 3 Pro makes a new image from your picture and your prompt.",
      "Each result is saved as a numbered file next to the original, so you can keep going and nothing gets overwritten. There's also a one-shot mode if you just want a single result without the chat.",
    ],
    howToUse: [
      "Right-click an image in File Explorer and choose Mike's Tools > Generate from Image (on Windows 11 click \"Show more options\" first), or run `generate-from-image <image_file>`.",
      "Type what you want and press Enter, the result is saved as `<originalname>-generated-001.png`, then `002.png` and so on.",
      "Use `n <1-4>`, `aspect <ratio>` and `size <1K|2K|4K>` to change variations, aspect ratio and resolution, and `settings` to see what's set.",
      "Type `open` to view the last image or `folder` to open the output folder.",
      "Type `quit` to exit, or skip the chat entirely with `generate-from-image <image_file> --prompt \"Your edit instruction\"`.",
    ],
    requirements: [
      "An OpenRouter API key as `OPENROUTER_API_KEY` in the repo root `.env`",
      "Bun (dependencies are installed by `deps.ps1` or `bun install`)",
    ],
  },
  "svg-to-png": {
    tagline: "Turn an SVG into a nice big PNG with one right-click",
    intro: [
      "Sometimes you just need a PNG of an SVG and you want it big enough to actually use. This renders the SVG so its shortest side is at least 2048px, and if it's already bigger than that it keeps its natural size.",
      "The PNG lands right next to the SVG with the same name, so `logo.svg` becomes `logo.png`.",
    ],
    howToUse: [
      "Right-click an `.svg` file in File Explorer and choose Mike's Tools > Render to PNG (2048px min) (on Windows 11 click \"Show more options\" first).",
      "Or from a terminal run `svg-to-png <file.svg>`.",
      "Grab the PNG from the same folder as the SVG.",
    ],
    requirements: [
      "Bun (`@resvg/resvg-js` is installed by `deps.ps1` or `bun install`)",
    ],
  },
  "img-to-svg": {
    tagline: "Turn a PNG, JPEG or WebP into an SVG",
    intro: [
      "This converts raster images into SVGs. By default it uses vtracer, which is fast, runs locally and works on pretty much any image, with presets for logos and flat colour, photos, or black and white line art.",
      "If you've got an NVIDIA GPU you can also try the StarVector AI models instead, which are best for icons, logos and diagrams.",
    ],
    howToUse: [
      "Right-click an image in File Explorer and choose Mike's Tools > Convert to SVG, or run `img-to-svg logo.png`.",
      "For photos or gradients use `img-to-svg photo.webp --preset photo`, and for line art use `--preset bw`.",
      "To use the AI model run something like `img-to-svg icon.png --engine starvector-8b`.",
      "Optionally pass an output name, e.g. `img-to-svg icon.png out.svg --engine starvector-1b --max-length 2000`.",
    ],
    requirements: [
      "Python with `vtracer` and `Pillow` (installed by `deps.ps1`)",
      "For StarVector: PyTorch with CUDA, the `starvector` package, and an NVIDIA GPU (about 3 GB VRAM for 1b, about 16 GB for 8b)",
    ],
  },
  "video-description": {
    tagline: "Get a first go at a YouTube description, then chat to tweak it",
    intro: [
      "Writing YouTube descriptions is a bit of a chore, so this reads the video's transcript and has Gemini draft one for me. You get a description, timestamps, a resources section, hashtags and a few alternative titles in one go.",
      "Then you can just chat with it to fix things up, like telling it a timestamp is off or asking it to be shorter. The conversation is saved next to the video, so if you run it again later it picks up where you left off.",
    ],
    howToUse: [
      "Right-click a video in File Explorer and choose Mike's Tools > Video Description (on Windows 11 click \"Show more options\" first), or run `video-description <video_file>`.",
      "You can also right-click inside a folder, or run `video-description <folder>`, to pick from the videos in it.",
      "If there's no `<videoname>.srt` next to the video, say yes to generating one with `transcribe`.",
      "Read the first draft, then type changes like `make the description more concise` and press Enter.",
      "Type `quit` when you're happy and copy the latest version from `<videoname>-description.txt`.",
    ],
    requirements: [
      "An OpenRouter API key as `OPENROUTER_API_KEY` in the repo root `.env`",
      "Bun",
      "The `transcribe` tool, only if you want it to make transcripts for you",
    ],
    specificToMike: "The prompt asks for developer-focused descriptions, so you may want to change it in `index.ts` if your videos are about something else.",
  },
  copypath: {
    tagline: "Copy the full path of a file or folder from the terminal",
    intro: [
      "Tiny one, this. Run `copypath` and the absolute path of where you are goes on your clipboard, or give it a file or folder and it copies that instead.",
      "It copes with relative paths and even paths that don't exist yet.",
    ],
    howToUse: [
      "Run `copypath` to copy the current directory.",
      "Run `copypath <path>` to copy the resolved absolute path of a file or folder.",
      "Paste it wherever you need it.",
    ],
    requirements: [
      "PowerShell on Windows, or Python 3 on macOS",
    ],
  },
  worktrees: {
    tagline: "Tidy up the pile of git worktrees your AI agents leave behind",
    intro: [
      "I use this when Cursor leaves a pile of linked checkouts under `.cursor/worktrees`. It lists every worktree in the repo you're in, marks which is the primary and which are linked, and lets you pick some (or all the linked ones) to delete.",
      "It never lets you remove the primary checkout, and it asks before deleting anything. If a worktree has uncommitted changes it shows you the files first, so you don't lose work by accident.",
    ],
    howToUse: [
      "`cd` into any folder inside a checkout of the repo.",
      "Run `worktrees`.",
      "Pick the linked worktrees you want to remove.",
      "Check any dirty files it shows you, then confirm.",
      "Use `worktrees --force` if you want force mode from the start.",
    ],
    requirements: [
      "Bun and git on your PATH",
      "Run `bun install` in `tools/worktrees` once (on Windows `install.ps1` does this for you)",
      "On macOS, run `bash tools/worktrees/install-to-path.sh` to put the launcher in `~/.local/bin`",
    ],
  },
  "img-gen": {
    tagline: "A little chat window for making and refining images with Gemini",
    intro: [
      "Image Gen is a small desktop app where you describe an image and Gemini makes it, via OpenRouter. You open it on a folder, and when you like something you can drag it out or hit download to save it there.",
      "The bit I like is that you can draw on a result, with pen, boxes, arrows and labels, and that annotated version gets used as the input for your next prompt. It's a nice way to say \"change this bit here\" without trying to describe it in words.",
    ],
    howToUse: [
      "Right-click a folder in File Explorer and choose Mike's Tools > Image Gen, or on macOS run `img-gen <folder_path>`.",
      "Optionally attach an image, pick the model, aspect ratio, size and number of variations.",
      "Type into \"Describe what you want...\" and send it.",
      "Click the pencil on a result to annotate it, then send your next prompt to refine it.",
      "Drag an image out to Explorer, or click download, to save it into the folder.",
    ],
    requirements: [
      "An OpenRouter API key as `OPENROUTER_API_KEY` in the repo root `.env`",
      "Bun (the first launch builds the app, so it takes a bit longer)",
    ],
  },
  "video-gen": {
    tagline: "Make short AI videos from a chat window, right from a folder",
    intro: [
      "This is like Image Gen but for video. It's a chat-style desktop app that talks to OpenRouter's video models, and it defaults to Veo 3.1 Fast.",
      "It checks what the chosen model can actually do and only shows those options, so things like resolution, duration, audio, reference images and first or last frames come and go depending on the model. Videos take a while, so it waits for the job to finish and then downloads the MP4.",
    ],
    howToUse: [
      "Right-click a folder in File Explorer and choose Mike's Tools > Video Gen.",
      "Pick a model and whatever settings it offers.",
      "Type a prompt, and add reference images or first and last frames if the model supports them.",
      "Wait for the video to finish generating.",
      "Drag the video out of the window or click save to copy it into the folder you opened it from.",
    ],
    requirements: [
      "An OpenRouter API key as `OPENROUTER_API_KEY` in the repo root `.env`",
      "Bun (run `bun run build:dev` once before the first launch)",
    ],
  },
  "face-swap": {
    tagline: "Swap a face from one photo into another, all on your own machine",
    intro: [
      "This uses InsightFace to swap a face from one image into another, and it all runs locally with no cloud API. It's a small window where you drop in the target image on the left and the source face on the right.",
      "While it runs you can watch the logs, so you know what's going on, and the result gets saved next to the original with `_face-swapped` on the end of the name.",
    ],
    howToUse: [
      "Right-click an image in File Explorer and choose Mike's Tools > Face Swap to load it as the target, or right-click a folder background, or search for `Face Swap` from the Start menu.",
      "Put the image whose face you want replaced on the left.",
      "Put the face you want to copy on the right.",
      "Start the swap and watch the live logs.",
      "Check the preview, the result is already saved as something like `photo_face-swapped.jpg`.",
    ],
    requirements: [
      "Windows with Python on PATH",
      "Python packages installed by `deps.ps1`: `insightface`, `onnxruntime` or `onnxruntime-gpu`, and `opencv-python`",
      "The `inswapper_128.onnx` model, which the app can download on first run",
      "An NVIDIA GPU with CUDA is used if available, otherwise it runs on CPU",
    ],
  },
  "mac-screenshot": {
    tagline: "Press F11 to grab part of the screen and start marking it up",
    intro: [
      "A little background helper for macOS. You press F11, drag out the bit of the screen you want, and it saves it to `~/Desktop/Screenshots` with a timestamp name, copies it to the clipboard and opens it in Preview so you can scribble on it straight away.",
      "It starts on login, so once it's set up you can mostly forget about it.",
    ],
    howToUse: [
      "Run `bash tools/mac-screenshot/setup_mac.sh` once.",
      "Run `bash tools/mac-screenshot/install-launchagent.sh` so it starts on login.",
      "In System Settings > Privacy & Security > Accessibility, add Python.app and turn it on (and allow Screen Recording if macOS asks).",
      "Press F11 and drag to select the area you want.",
      "Paste it wherever you like, or annotate it in the Preview window that opens.",
    ],
    requirements: [
      "macOS",
      "Python (the setup script creates a venv and installs `pynput`)",
      "Accessibility permission, and Screen Recording if macOS asks",
    ],
    specificToMike: "The hotkey and save folder are set by `HOTKEY` and `SAVE_DIR` at the top of `mac-screenshot.py` if you want something other than F11 and `~/Desktop/Screenshots`.",
  },
};
