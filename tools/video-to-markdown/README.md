![header](docs/header.webp)

# video-to-markdown

Convert a YouTube URL into a ready-to-paste markdown image link and copy it to your clipboard in seconds.

Uses the [video-to-markdown.com](https://video-to-markdown.com) public API. Videos are processed and cached server-side, so repeated calls for the same URL are instant.

---


## Screenshots

![video-to-markdown screenshot](docs/ss1.png)
![video-to-markdown screenshot](docs/ss2.png)


## What it produces

Given a YouTube URL, the tool calls the API and puts something like this on your clipboard:

```markdown
[![Never Gonna Give You Up](https://thumbs.video-to-markdown.com/abc123.jpg)](https://youtu.be/dQw4w9WgXcQ)
```

Paste it into any Markdown file and you get a clickable thumbnail that links back to the video.

---

## Usage

### Right-click menu (any file or folder)

Right-click **anything** in Explorer - any file type, any folder - open **Mike's Tools** and choose **Video to Markdown**. A terminal window opens:

1. Paste the YouTube URL (pre-filled automatically if your clipboard already has one)
2. Press **Enter**
3. On success: "Copied to clipboard!" appears with the video title

### Right-click a `.url` Internet Shortcut (silent-ish mode)

Right-click a Windows Internet Shortcut (`.url` file) and choose **Video to Markdown**. The tool reads the URL from the file and converts it - no typing required.

### Command line

```
video-to-markdown                       # prompt for URL (clipboard pre-filled if YouTube URL is there)
video-to-markdown https://youtu.be/...  # convert directly
video-to-markdown "My Video.url"        # read URL from a Windows Internet Shortcut
```

---

## Workflow tip

Copy the YouTube URL from your browser before right-clicking - the prompt is pre-filled so you just hit Enter.

---

## Icon

`page_white_link.png` from the [famfamfam silk icon set](https://www.famfamfam.com/lab/icons/silk/) (Mark James, CC BY 2.5).

---

## Dependencies

- [bun](https://bun.sh) runtime
- [@inquirer/prompts](https://www.npmjs.com/package/@inquirer/prompts) for the interactive URL prompt
- Internet connection

No API keys required. Uses `clip.exe` (built into Windows) for clipboard access.

---

## API

`POST https://quirky-squirrel-220.convex.site/api/markdown`

Request:
```json
{ "url": "https://youtu.be/dQw4w9WgXcQ" }
```

Response:
```json
{
  "markdown": "[![Title](https://thumbs.video-to-markdown.com/abc.jpg)](https://youtu.be/...)",
  "title": "Video Title",
  "url": "https://youtu.be/..."
}
```

Built on [Convex](https://convex.dev). Thumbnails hosted on Cloudflare R2 at `thumbs.video-to-markdown.com`.