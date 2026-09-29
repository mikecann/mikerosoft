# X Bookmarks

![X Bookmarks](docs/header.png)

Turn newly bookmarked X posts into saved Codex tasks. Python and SQLite check X
without any LLM calls. Only a new bookmark starts a short-lived `codex app-server --stdio` research turn. It reads the post,
fact-checks important claims with live web search, looks for author follow-ups
and relevant replies, and prepares likely questions with linked evidence.
Each brief starts with a content-specific title and retains the original link.
The worker sets a subject-based task name before research, then replaces it with
the brief's heading using `thread/name/set`.

## How it works

The first successful run records all existing bookmarks as a baseline, without
creating tasks. Subsequent checks request the latest bookmark only. If its ID
changed, the reader fetches ten posts at a time until it reaches a known item.
IDs remain in SQLite permanently, including when a bookmark is removed from X.

Delivery uses the installed Codex binary's documented app-server JSON-RPC
interface over stdin/stdout. Each new bookmark starts a short-lived worker;
unchanged checks do not start Codex. There are no Desktop private sockets,
Codex database edits, UI scripting, or persistent additional app-server.

**Why not `codex exec`?** Desktop's current sidebar catalogue explicitly excludes
`exec` sessions. The September 15 test only proved that such a task could be
read and manually opened. It did not prove automatic sidebar discovery.
App-server-created sessions are eligible for Desktop's catalogue. Desktop
controls refresh timing, so a completed worker is not itself proof of visibility.
When validating an installation, confirm a fresh task appears in Desktop's task
list without navigating to it or manually opening it first.

The worker records creation intent before sending `thread/start`, saves the task
ID before starting a turn, and marks delivery complete only after a completed
research turn and successful title update. It rejects a hidden `exec` source.
An interrupted or uncertain attempt is held for inspection instead of blindly
creating a duplicate. `delivered` means persisted research and naming succeeded;
it is not an acknowledgement from Desktop's separate sidebar catalogue.

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
calls. A 15-minute turn timeout prevents indefinite research. The app-server
uses the user's existing Codex login and model settings, with read-only sandboxing
and approval policy `never`. The research thread disables configured MCP servers,
plugins, apps, hooks, shell tools, and memory features, retaining live web search.
The research prompt forbids posting, messages,
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
4. Set `delivery_backend` to `app-server`, `codex_binary` to the absolute executable
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
x-bookmarks doctor   # app-server protocol check, no LLM call
python3 tools/x-bookmarks/service.py --uninstall
```

Logs: `~/Library/Logs/x-bookmarks.log`. Private state, OAuth credentials, and task
payloads: `~/Library/Application Support/x-bookmarks/`.

## Interrupted delivery

`status` lists uncertain `creating`, `created`, or `submitting` rows and their known task IDs.
Inspect Desktop before resolving. Never mark an uncertain task as absent without
checking, since it may have completed before the worker lost its connection.

```sh
x-bookmarks resolve POST_ID --confirmed-outcome captured --thread-id TASK_ID
x-bookmarks resolve POST_ID --confirmed-outcome not-created
```

The second command is allowed only when no task ID was recorded. A known but
unfinished task must be continued in Codex and then marked captured. The
legacy app-server adapter remains available for existing configurations, but is
not used by the stdio app-server service.

## Tests

```sh
python3 -m unittest discover -s tools/x-bookmarks/tests -v
cd website && npm test && npm run build
```

Tests cover baseline and catch-up, account binding, malformed/partial responses,
OAuth PKCE, throttling and backoff, process events, uncertain delivery, duplicate
prevention, and an installation independent of the source checkout.
