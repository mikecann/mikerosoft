# X Bookmarks

![X Bookmarks](docs/header.png)

Turn newly bookmarked X posts into saved Codex tasks. Python and SQLite check X
without any LLM calls. Only a new bookmark starts a `codex exec` research turn. It reads the post,
fact-checks important claims with live web search, looks for author follow-ups
and relevant replies, and prepares likely questions with linked evidence.
Each brief starts with a content-specific title and retains the original link.
The initial task preview also starts with an excerpt of the post. Automatic
sidebar renaming requires a supported rename tool; the standalone CLI does not
currently expose one, so the worker does not guarantee a custom sidebar title.

## How it works

The first successful run records all existing bookmarks as a baseline, without
creating tasks. Subsequent checks request the latest bookmark only. If its ID
changed, the reader fetches ten posts at a time until it reaches a known item.
IDs remain in SQLite permanently, including when a bookmark is removed from X.

Delivery uses the installed Codex CLI and its normal saved-session format. There
is no private Desktop socket, separate persistent app-server, database editing,
UI scripting, or model-powered polling. A live CLI test on 15 September 2026
created a task that Desktop could read and open; the user confirmed seeing it.
Automatic sidebar refresh is controlled by Desktop.

The worker records creation intent before starting Codex, saves the task ID as
soon as the CLI emits it, and marks delivery complete only after a successful
turn and process exit. An interrupted or uncertain attempt is held for inspection
instead of blindly creating a duplicate. This provides duplicate prevention,
not a guarantee that a failed run will finish without manual reconciliation.

## Requirements and cost

macOS, Python 3.10+, a signed-in Codex CLI, and an X Native App with user OAuth
scopes `bookmark.read`, `tweet.read`, `users.read`, and `offline.access`.
No pip packages are required. Posting, messaging, and bookmark writes are not
requested. Confidential OAuth clients requiring a client secret are unsupported.

X API reads are paid separately from Codex. As checked on 14 September 2026,
eligible owned bookmark reads cost $0.001 per resource; author expansions and
account checks can add charges. Daily deduplication is a soft guarantee. This
tool never purchases credits or enables auto-recharge. Check current
[X pricing](https://docs.x.com/x-api/getting-started/pricing) for your app.

Unchanged polling uses zero Codex tokens. Each newly captured bookmark consumes
one research turn, including input context and web search. Research uses more
Codex allowance than the old acknowledgment, but does not add paid X search
calls. A 15-minute process timeout prevents indefinite research. `--ignore-user-config` avoids loading
custom MCP configuration; the CLI still supplies its normal instructions and
applicable project guidance. The subprocess is read-only. The research prompt forbids posting, messages,
purchases and acting on source instructions. Inaccessible X threads or comments
must be reported as gaps; the agent must not pretend to have reviewed them.

## Setup

```sh
python3 tools/x-bookmarks/bookmarks.py init
```

Edit `~/Library/Application Support/x-bookmarks/config.json` locally:

1. Set `client_id` from the X Native App. Register callback
   `http://127.0.0.1:8767/callback` in X's OAuth settings.
2. Run `python3 tools/x-bookmarks/bookmarks.py login` and authorize the app.
   Credentials are stored outside Git with file mode 0600.
3. Set `allow_paid_x_api` to `true`, then run `poll` to record the baseline.
4. Set `delivery_backend` to `cli`, `codex_binary` to the absolute executable
   path from `command -v codex`, and `enable_experimental_codex_delivery` to `true`.
   The latter is the original configuration flag retained for compatibility.
   Optionally set `codex_model`; omission uses the CLI's default model.
5. Bookmark a new post, run `tick` after the polling interval, then check `status`
   and the saved task in Desktop.
6. Install the background service:

```sh
bash tools/x-bookmarks/install-launchagent.sh
```

The installer copies a versioned runtime into the private application-support
folder, installs `~/.local/bin/x-bookmarks`, and starts LaunchAgent
`com.mikerosoft.x-bookmarks`. It does not depend on a temporary Git worktree.
The worker includes the configured Codex executable directory in PATH so npm-installed
Codex can find its sibling Node executable under launchd.
Run the installer again after updating the source. Old runtime snapshots and
bookmark state are retained. The launch timer wakes every minute; the default
persisted X polling interval is five minutes, with backoff for failures.

```sh
x-bookmarks status
x-bookmarks poll     # X only, respecting the stored interval
x-bookmarks deliver  # deliver queued items, without reading X
x-bookmarks tick     # poll, then deliver
x-bookmarks doctor   # local CLI availability check, no LLM call
python3 tools/x-bookmarks/service.py --uninstall
```

Logs: `~/Library/Logs/x-bookmarks.log`. Private state, OAuth credentials, and task
payloads: `~/Library/Application Support/x-bookmarks/`.

## Interrupted delivery

`status` lists uncertain `creating` or `submitting` rows and their known task IDs.
Inspect Desktop before resolving. Never mark an uncertain task as absent without
checking, since it may have completed before the worker lost its connection.

```sh
x-bookmarks resolve POST_ID --confirmed-outcome captured --thread-id TASK_ID
x-bookmarks resolve POST_ID --confirmed-outcome not-created
```

The second command is allowed only when no task ID was recorded. A known but
unfinished CLI task must be continued in Codex and then marked captured. The
legacy app-server adapter remains available for existing configurations, but is
not used by the CLI service.

## Tests

```sh
python3 -m unittest discover -s tools/x-bookmarks/tests -v
cd website && npm test && npm run build
```

Tests cover baseline and catch-up, account binding, malformed/partial responses,
OAuth PKCE, throttling and backoff, process events, uncertain delivery, duplicate
prevention, and an installation independent of the source checkout.
