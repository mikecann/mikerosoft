# Meeting Archive Worker launcher

This is the small, signed macOS app that owns Bruce's Removable Volumes
consent. The Python environment, models, cache, credentials, database, worker
source, and meeting media remain on CannMedia.

Build it on Bruce's internal disk:

```bash
cd /path/to/worker/launcher
./build-app.sh
```

The default destination is `~/Applications/Meeting Archive Worker.app`. The
build deliberately defaults to ad-hoc signing with the stable designated
identifier `com.mikerosoft.meeting-archive-worker`, so a certificate appearing
later cannot silently replace the app's privacy identity. Set
`MEETING_ARCHIVE_WORKER_CODESIGN_IDENTITY` only when intentionally migrating to
a named signing identity.

Before enabling the service, open the app from Finder while logged in as Bruce.
Choose exactly `/Volumes/CannMedia/MeetingArchive` and approve macOS's
Removable Volumes request if shown. The application's own path restriction is
the exact archive directory; macOS's permission applies to removable volumes.
The app stores an ordinary bookmark for the exact selection and verifies the
CannMedia volume UUID and real directory path, then reports that setup is ready.
Close the app before enabling the LaunchAgent.

The per-user LaunchAgent should run the signed bundle executable directly:

```text
/Users/bruce/Applications/Meeting Archive Worker.app/Contents/MacOS/meeting-archive-worker
--worker
```

Use those as two `ProgramArguments` entries. The private viewer LaunchAgent can
use the same executable with `--viewer`, but it must remain disabled until its
separate network-route approval. These are the only accepted modes; the app
does not accept arbitrary commands or paths. Do not target `/bin/bash`, the
external wrapper, or `open`. The launcher starts the existing guarded
`run-service-bruce.sh` as its child and waits for it, so the child runs with the
GUI app's responsibility and the LaunchAgent tracks the complete service
lifetime. It forwards shutdown to the child and escalates after a bounded wait.
Service-mode failures are written to stderr and exit without opening a window,
so a KeepAlive restart cannot repeatedly interrupt the desktop. Grant folder
access interactively before loading the LaunchAgent.

Run the path and command contract tests without opening the app:

```bash
./run-tests.sh
```
