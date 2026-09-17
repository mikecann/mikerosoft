# Private meeting playback viewer

The viewer is a small, read-only HTTP service designed to run behind Tailscale
Serve. It binds only to `127.0.0.1:8765`; it does not implement TLS, listen on
the LAN, or configure Tailscale itself.

The intended private URL is:

```text
https://bruce.tail9ef766.ts.net:10443/meeting/<UUID>
```

The page contains the browser-compatible playback asset, escaped transcript
turns with seek buttons, and a user-clicked
`meetingarchive://meeting/<UUID>` link for the installed Mac app. The fixed
download endpoints are:

```text
GET or HEAD /meeting/<UUID>/playback.mp4
GET or HEAD /meeting/<UUID>/transcript.md
```

There is no meeting index, search, arbitrary file parameter, profile endpoint,
database endpoint, or credentials endpoint.

## Access and path checks

Every request must contain exactly one Tailscale Serve identity header:

```text
Tailscale-User-Login: mike.cann@gmail.com
```

The backend listens only on localhost. Tailscale Serve removes incoming
identity headers before adding its authenticated value, so callers cannot
provide a different identity through the private HTTPS route.
Localhost callers bypass Serve and can supply that header themselves, so this
design trusts Bruce's local user and process boundary; it authenticates tailnet
requests, not hostile local processes.

The UUID must be canonical lowercase text and must have a matching durable row
in the worker's `acceptances` table. The row and its stored acknowledgement
must agree on meeting ID, revision, manifest hash, and archive path. Accepted
paths must have exactly the form `<year>/<month>/<UUID>` below the configured
meetings root.

Generated files are opened one directory component at a time with `openat`,
`O_NOFOLLOW`, and an `fstat` regular-file check. User input never becomes a
filesystem path. Media is streamed in 64 KiB chunks and supports one bounded
byte range for browser seeking. Metadata and transcript JSON have fixed input
limits, and all displayed strings are HTML-escaped under a restrictive content
security policy.

The SQLite connection uses read-only and query-only modes. Viewer requests do
not create receipts, sidecars, profiles, logs, or cache files.

## Isolated verification

Tests or an isolated Bruce fixture can supply their own roots without changing
the production wrapper:

```sh
PYTHONPATH=tools/meeting-archive/worker \
python3 -m meeting_archive_worker.viewer \
  --archive-root /path/to/isolated/meetings \
  --db /path/to/isolated/worker.sqlite \
  --host 127.0.0.1 \
  --port 8765 \
  --allowed-login mike.cann@gmail.com \
  --max-threads 2
```

The production wrapper does not accept environment overrides. It hardcodes the
verified CannMedia volume, production meetings root, worker database, localhost
address, identity, and a four-request-thread ceiling.

## Staging on Bruce

Install the small [Meeting Archive Worker launcher](launcher/README.md) on
Bruce's internal disk and grant its scoped CannMedia access from the logged-in
desktop first. Both background services start that signed app with a fixed
role. The viewer remains a separate service and is never enabled by granting
the worker app drive access.

Stage the owner-only LaunchAgent without starting it:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-viewer-service-bruce.sh
```

After review, localhost startup is explicit:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-viewer-service-bruce.sh --enable
```

Both scripts verify CannMedia UUID
`5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46` before Python can open the database or
archive. The viewer process receives no Hugging Face or Notion credentials.
The installer never changes Tailscale configuration.

## Private HTTPS route

Creating this route is a separate, explicit networking action:

```sh
/usr/local/bin/tailscale serve \
  --bg \
  --https=10443 \
  http://127.0.0.1:8765
```

It is deliberately separate from Bruce's existing ports 443 and 8443. Never
use `tailscale serve reset`, because reset would remove those existing routes.
Once the private route is approved and verified, publication uses:

```sh
MEETING_ARCHIVE_PLAYBACK_BASE_URL=https://bruce.tail9ef766.ts.net:10443
```

Disable only this route with:

```sh
/usr/local/bin/tailscale serve --https=10443 off
```

Disable and unstage only the localhost viewer with:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/uninstall-viewer-service-bruce.sh
```

Neither operation deletes meetings, transcripts, SQLite state, models, or
credentials.
