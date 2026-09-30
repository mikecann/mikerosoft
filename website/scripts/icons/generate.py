"""Generates 3x3 sheets of Mikerosoft 95 tool icons with Gemini via OpenRouter.

Each sheet draws 9 of SUBJECTS against the famfamfam-style reference in
style-ref.png, on flat magenta so slice.py can cut them out. Drawing 9 at once
keeps the family consistent. For a new tool, add it to SUBJECTS and draw just
its sheet. Needs OPENROUTER_API_KEY in the environment or the repo root .env. Sheets are ignored
by git; only the cut-out icons in website/public/icons are kept.

usage: python3 generate.py <sheet-index...>
"""
import base64, json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = os.environ.get('OPENROUTER_API_KEY') or next(
    l.split('=', 1)[1].strip().strip('"\'')
    for l in open(os.path.join(HERE, '..', '..', '..', '.env'))
    if l.startswith('OPENROUTER_API_KEY=')
)
MODEL = 'google/gemini-3-pro-image-preview'

SUBJECTS = [
    # sheet 0: video
    ('tandem', 'a two-seater tandem bicycle in orange and yellow, seen from the side'),
    ('record-it', 'a chunky red camcorder with a glowing red record dot'),
    ('video-hq', 'a black-and-white film clapperboard sitting on a yellow manila folder'),
    ('telemprompit', 'a teleprompter: an angled sheet of glass on a stand reflecting lines of white text'),
    ('record-meeting', 'a silver studio microphone in front of two small speech bubbles'),
    ('meeting-archive', 'a grey metal filing cabinet with one drawer open, a small webcam sitting on top'),
    ('transcribe', 'a strip of film with a white speech bubble full of text lines coming out of it'),
    ('unmultitrack', 'three strips of film fanning out and splitting apart from one bundle'),
    ('remove-portrait', 'a film frame showing a person silhouette on a grey-and-white transparency checkerboard'),
    # sheet 1: video + images
    ('video-titles', 'a small television with a glowing yellow light bulb above it'),
    ('video-description', 'a sheet of paper with text lines, a red play button in the corner and a pencil'),
    ('video-to-markdown', 'a red play-button video screen with an arrow pointing to a sheet of paper marked with a big "M" and a down arrow'),
    ('video-gen', 'a film clapperboard with sparkling yellow magic stars bursting from it'),
    ('removebg', 'a framed photo of a green hill where half the background is a grey-and-white transparency checkerboard, with a pink eraser'),
    ('img-upscale', 'a small framed picture with a green arrow growing into a much larger framed picture'),
    ('img-gen', 'a painter\'s palette with a white chat speech bubble containing a sparkle'),
    ('generate-from-image', 'a framed landscape photo with a magic wand casting yellow sparkles over it'),
    ('face-swap', 'two cartoon faces side by side with curved blue arrows swapping between them'),
    # sheet 2: images + desktop
    ('img-to-svg', 'blocky square pixels on the left turning into a smooth blue bezier curve with square control handles on the right'),
    ('svg-to-png', 'a vector pen nib with a bezier curve turning into a framed picture made of pixels'),
    ('color-picker', 'a glass eyedropper picking up colour, with a small row of rainbow colour swatches'),
    ('mac-screenshot', 'a camera with a dashed selection rectangle around it'),
    ('taskbar', 'a computer monitor whose screen shows a grey taskbar along the bottom edge with a small green button at its left and a few tiny coloured app squares'),
    ('task-stats', 'a square dark panel showing a green line graph above small orange and purple bar charts, like a tiny system monitor'),
    ('voice-type', 'a microphone standing on top of a single keyboard key'),
    ('mikey-mouse', 'a white computer mouse with blue back and forward arrows on either side'),
    ('last-window-quits', 'an application window closing with a red X and a small exit door swinging shut'),
    # sheet 3: desktop + developer
    ('phonebooth', 'three small smartphones side by side each mirrored onto a monitor behind them'),
    ('scale-monitor', 'a computer monitor with a magnifying glass and "200%" style zoom arrows'),
    ('sleep-monitors', 'a dark computer monitor with a yellow crescent moon and blue "Z z z"'),
    ('ctxmenu', 'a right-click context menu popup with checkboxes and a mouse pointer'),
    ('backup-phone', 'a smartphone with a green arrow pouring photos into a grey hard drive'),
    ('token-stats', 'a stack of gold coins next to a rising blue line chart'),
    ('worktrees', 'a small green tree whose branches are git branch lines with round commit dots'),
    ('ghopen', 'a yellow folder with a blue globe and a green arrow popping out of it'),
    ('copypath', 'a brown clipboard holding a sheet with a folder path written on it'),
    # sheet 4: icons for the site itself, saved as ui-<name>.png
    ('ui-windows', 'a beige desktop PC tower with a monitor showing a blue sky desktop, no logos'),
    ('ui-macos', 'a thin silver laptop, lid open, screen showing a soft purple wallpaper, no logos'),
    ('ui-video', 'a black video camera on a small tripod with a red record light'),
    ('ui-images', 'a stack of two framed photos, the front one a green hill under a blue sky'),
    ('ui-desktop', 'a computer monitor showing a small blue window with a title bar'),
    ('ui-developer', 'a dark code editor window with coloured angle brackets and lines of code'),
    ('ui-calendar', 'a desk calendar page with a red top binding and a date number'),
    ('ui-changes', 'a notepad page with lines of text and a small blue clock in the corner'),
    ('ui-get', 'an open brown cardboard box with a big green arrow pointing down into it'),
]

PROMPT = """Make a 3x3 grid of 9 separate desktop application icons for a Windows 98 styled website.

Style: match the attached reference exactly in spirit. It shows famfamfam "silk" icons, which I want redrawn at high resolution: simple chunky shapes, a crisp dark outline around every object, bright friendly saturated colours, soft top-left lighting with gentle gradients, slight 3/4 perspective where it helps, no text except where asked, no drop shadow onto the background. Smooth, clean, high resolution vector-style illustration, NOT pixel art and NOT blocky. Each icon must read clearly when shrunk to 32 pixels, so keep details few and bold. All 9 icons must look like one consistent family.

Layout: exactly 3 columns and 3 rows, each icon centred in its own cell with plenty of empty space around it, nothing touching or overlapping between cells. Background: one flat solid pure magenta (#FF00FF) everywhere, with no gradients, borders, grid lines, labels or shadows. Never use magenta or pink inside the icons.

Icons, left to right, top to bottom:
{items}"""


def generate(sheet: int) -> str:
    subjects = SUBJECTS[sheet * 9:(sheet + 1) * 9]
    items = '\n'.join(f'{i + 1}. {desc}' for i, (_, desc) in enumerate(subjects))
    ref = base64.b64encode(open(os.path.join(HERE, 'style-ref.png'), 'rb').read()).decode()
    body = {
        'model': MODEL,
        'modalities': ['image', 'text'],
        'image_config': {'aspect_ratio': '1:1', 'image_size': '2K'},
        'messages': [{'role': 'user', 'content': [
            {'type': 'image_url', 'image_url': {'url': f'data:image/png;base64,{ref}'}},
            {'type': 'text', 'text': PROMPT.format(items=items)},
        ]}],
    }
    req = urllib.request.Request('https://openrouter.ai/api/v1/chat/completions', json.dumps(body).encode(), {
        'Authorization': f'Bearer {KEY}', 'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/mikecann/mikerosoft', 'X-Title': 'mikerosoft/website-icons',
    })
    data = json.load(urllib.request.urlopen(req, timeout=300))
    images = data['choices'][0]['message'].get('images') or []
    if not images:
        return f'sheet {sheet}: no image. {data["choices"][0]["message"].get("content")}'
    out = os.path.join(HERE, f'sheet-{sheet}.png')
    open(out, 'wb').write(base64.b64decode(images[0]['image_url']['url'].split(',', 1)[1]))
    return f'sheet {sheet}: {out}'


if __name__ == '__main__':
    with ThreadPoolExecutor(4) as pool:
        for line in pool.map(generate, [int(a) for a in sys.argv[1:]]):
            print(line)
