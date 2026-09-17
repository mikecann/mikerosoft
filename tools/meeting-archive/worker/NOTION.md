# Notion publication

The worker's optional Notion stage is an additive publication of a finalized
archive. The callable entry point is:

```python
from pathlib import Path
from meeting_archive_worker.notion import publish

receipt = publish(Path("/path/to/archive"))
```

Runtime configuration comes from `MEETING_ARCHIVE_NOTION_TOKEN`,
`MEETING_ARCHIVE_NOTION_DATA_SOURCE`, and `MEETING_ARCHIVE_PLAYBACK_BASE_URL`.
The playback URL must be HTTPS without credentials, query parameters, or a
fragment. The Bruce wrapper loads credentials from its protected credential
file before starting the worker. Tests and local callers may inject a
stdlib `urllib.request.Request` transport. The configured data source is
expected to already have these properties: `Name`, `Started`, `Duration`,
`Speakers`, `Description`, `Audio file`, and `Transcript file`. Publication
does not create or alter a Notion schema.

The page fields contain meeting metadata and private HTTPS links to
`<playback-base>/meeting/<UUID>`. Ownership keys are carried in the fragment of
those links, attached to normal labels such as `Play recording`, `Transcript`,
and each turn's timestamp. They are never rendered as extra marker text. The
viewer requires Tailscale and the allowed user identity. Its network route is
a separate, explicit deployment step.

Transcript turns are appended as timestamped speaker paragraphs. Rich
text is capped at 2,000 characters and append requests at 100 blocks. A
timestamp link uses `t=<seconds>` in its fragment so the private viewer can
start playback at that turn. Manual and unknown page content remains in place
because the publisher never replaces or deletes a page's children.

`notion-receipt.json` is written atomically inside the archive after the page
and all owned blocks are confirmed. It records the page ID, owned block IDs,
and a content fingerprint. If metadata or transcript speaker assignments are
corrected, the same page is reused: receipt-owned blocks are updated in place,
new marked blocks are appended, and removed blocks are moved to trash only when their
IDs came from that receipt. Manual and unknown blocks are never changed. If a
page create or block append loses its response, the publisher searches the
stable HTTPS ownership link before retrying. Existing receipts and pages made
with the earlier visible HTML and `meetingarchive://` markers are recognized
once and rewritten to the readable HTTPS-link format. HTTP 429 responses use `Retry-After` with a
bounded retry budget. Failed property updates never produce a successful
receipt. Changing the playback base URL also changes the content fingerprint
so the same page is refreshed without retranscribing audio.
