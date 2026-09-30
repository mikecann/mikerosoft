# Agent guidance - mikerosoft.app

Instructions for AI agents working in this repo.

---

## Repo purpose

This repo is the mikerosoft.app website: a Windows XP style desktop that shows
off Mike's personal desktop tools. It used to hold the tools too, in `tools/`.
Each tool now lives in its own public repo at `https://github.com/mikecann/<tool>`
(MIT, its own README, AGENTS.md, installers, CI and full history). Work on a
tool in a clone of that tool's repo, not here.

Tools that were renamed when they moved out: `video-to-markdown` is
`youtube-to-markdown`, `removebg` is `cutout`, `remove-portrait` is
`video-cutout`, `mac-screenshot` is `snap-it`, `ctxmenu` is `right-click-tidy`,
`generate-from-image` is `img-remix` and `worktrees` is `worktree-tidy`.
`prompter-kit` is the shared Swift package taskbar, video-hq and telemprompit
use for the Elgato Prompter.

## Key rules

- **Use test-first development for non-trivial changes.** Write or update the
  automated test first, then implement the change until the test passes.
- **When behaviour changes, rerun the relevant tests** (`npm test` in
  `website/`) and `npm run build` before committing.
- The site deploys from `main`, so anything pushed to `main` goes live.

---

## website specifics

The mikerosoft.app site in `website/` deploys from `main` through
`.github/workflows/deploy-website.yml` whenever `website/` changes, once a day
(22:00 UTC, 06:00 in Perth), and on a manual run (Actions > Deploy Website >
Run workflow, or `gh workflow run deploy-website.yml`).

Every tool now lives in its own public repo, `github.com/mikecann/<name>`,
named after the tool. The site reads from those repos, not from this repo's
`tools/` folder: its source link, media, dates and changelog all come from the
tool's repo. A push to a tool repo reaches the site on the next daily build,
or straight away if you run the workflow by hand. GitHub pauses scheduled
workflows after 60 days without activity in this repo; re-enable it from the
Actions tab if that happens.

To add a new tool to the site:

1. Create its public repo at `github.com/mikecann/<name>` with a README (the
   same "Get it" prompt as the site's Copy prompt), a `docs/header.webp`, and
   ideally real screenshots in `docs/`.
2. Add it to `website/src/tools.ts`: `url: repoUrl('<name>')`, and media with
   `asset('<name>', 'docs/...')`, which serves the file from the repo's `main`
   through jsDelivr.
3. Add its page copy to `website/src/toolDetails.ts`.
4. Draw its icon (`website/public/icons/<name>.png`, see below).
5. Take its share image (`website/public/share/<name>.jpg`, see below).
6. `npm test` and `npm run build` in `website/`, then commit and push.

If a tool is renamed, rename its repo, entry, icon, share image and
`toolDetails` key, and add `old: 'new'` to `RENAMED_TOOLS` in `tools.ts`.
Old `/tools/<old>` links then open the tool under its new name, and the build
writes `dist/tools/<old>.html` that previews the tool and redirects.

- The site is a Windows XP desktop, in the style of Mike's Convex OS
  (github.com/mikecann/convex-os), built on XP.css plus `website/src/xp.css`.
  Every tool is a desktop icon down the left and right edges, and each one
  opens in its own window that can be dragged, resized, minimised and
  closed. The window in front sets the address bar, so `/tools/<name>` opens
  that tool's window over the Mikerosoft one. The window logic lives in
  `website/src/windowManager.ts` with tests. Tool windows follow the PostHog
  homepage layout: the write-up on the left, a Get it card with the Copy
  prompt button on the right, then media, then What's changed. On phones
  windows fill the screen and the desktop is a grid of icons.
- It should behave like XP: desktop icons select on a click and open on a
  double click, can be box-selected and dragged (the layout is saved in
  localStorage, logic in `website/src/desktopLayout.ts`), and the desktop,
  icons, title bars and taskbar buttons all have right-click menus. The
  taskbar has Quick Launch with Show Desktop, a clock that opens Date and
  Time, and a Start menu with recent tools, cascading All Programs, Run and
  Turn Off. Phones open icons with a single tap.
- XP.css is imported into a CSS layer (`@import ... layer(xp)` at the top of
  `website/src/xp.css`), so the site's own styles always beat it. Don't add
  specificity hacks to fight XP.css button styles; give custom buttons the
  `plain` class instead.
- GitHub links open in a new browser tab. github.com sends
  `X-Frame-Options: deny`, so it can't be shown in a window on the desktop.
- Date and Time is an `app:` window: it's on the taskbar but has no URL.
- Site icons (platforms, categories, calendar and so on) are `ui-*.png` in
  `website/public/icons`, drawn by the same icon generator.
- The desktop wallpaper (`website/public/wallpaper.webp`) is an original
  Bliss-style image generated for this site (rolling green hill, blue sky,
  a few clouds) - not Microsoft's copyrighted photo and not Convex OS's
  logo-bearing copy of it. The small XP icons in `website/public/xp` come
  from Convex OS, which borrowed them from github.com/ShizukuIchi/winXP.
- Tools come from `website/src/tools.ts`. Each one needs a `category`, a
  `url` of its own repo, and its own icon at `website/public/icons/<name>.png`. The icons are high-res
  famfamfam-style drawings made with `website/scripts/icons/generate.py` and
  `slice.py`. For a new tool, add it to `SUBJECTS` there and draw its sheet so
  it matches the family. Tests fail if a tool has no category or icon.
- Give every tool repo a `docs/header.webp` (1376x768). It's used as the
  share image until one's been taken, and as the tool page's artwork when
  there are no real screenshots yet. jsDelivr caches `@main` files for up to
  12 hours, so a replaced image can take that long to show; purge it sooner
  at `https://purge.jsdelivr.net/gh/mikecann/<name>@main/<path>`.
- The added and updated dates on each tool come from its repo's git history.
  `npm run dates` (run automatically before `dev` and `build`) keeps a
  blob-less mirror of every tool repo in the ignored `website/.repo-cache/`,
  cloning or fetching it (at most every 10 minutes, and falling back to the
  cached copy when offline), and writes the ignored
  `website/src/toolDates.generated.ts`. Added is the repo's first commit,
  which is the tool's real age because the repos kept their monorepo history.
  Updated is the latest commit that touched more than `docs/`, `README.md`,
  `AGENTS.md`, `LICENSE` or `.github/`, since those describe or check a tool
  rather than change it. The `Standalone repo: ...` commit that split each
  tool out of this repo doesn't count either.
- Every tool has its own page at `/tools/<name>` (`website/src/ToolContent.tsx`).
  It leads with real media: `video` first, then `screenshots`, and only falls
  back to the generated `header` art when there's nothing real. Give every tool
  real screenshots or a short clip of it working.
- Setup on the page is one step: copy a prompt that tells your agent to clone
  the tool's repo and make it your own (`makeItYoursPrompt`, word for word the
  prompt in each tool repo's README). Don't add setup instructions to the page.
- The page copy (a tagline and a short intro, in Mike's voice with no em dashes)
  lives in `website/src/toolDetails.ts`. A new tool needs an entry there or
  `npm test` fails.
- "What's changed" on each page comes from the tool repo's git history, with
  the same rules as the updated date. `npm run changelog` (run automatically
  before `dev` and `build`) writes the ignored
  `website/public/changelog/<tool>.json` from commit subjects and bodies, so
  write commit bodies in the tool repos that say why something changed.
- `npm run build` also writes `dist/tools/<name>.html` with that tool's title,
  description and share image, so links shared on social previews properly.
- Link previews are 1200x630 screenshots in `website/public/share`: the
  desktop for the home page and each tool's window for its page. They're
  committed, not built. After adding a tool or changing how the site looks,
  run `npm run dev` and then `npm run share-images` in `website/`, check a few,
  and commit them. A tool without one falls back to its header art.
- `npm test` in `website/` runs the tool list, sorting, git-history, changelog
  and tool page tests. It doesn't touch the network; `npm run build` does.

---
