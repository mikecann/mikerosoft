# X bookmarks

Capture newly observed X bookmarks and queue one Codex task per post, containing
the author, text, and original link. Python's standard library and SQLite do the
polling. There are **no LLM calls, tokens, Codex processes, or agent heartbeats
during unchanged polling**. Delivery is a separate, opt-in step.

## Current status

Implemented and tested locally, **not live**. Paid API reads and experimental
Codex delivery both default to disabled. No service has been installed.

On 14 September 2026, the local Codex CLI was `0.154.0`. Its documented CLI help
provides `codex app-server proxy`, which forwards JSONL to an **existing** local
app-server control socket. A read-only connection attempt failed because
`~/.codex/app-server-control/app-server-control.sock` does not exist on this
machine. The Desktop app's separate private IPC socket is not that protocol.
This implementation does not reverse-engineer private IPC, write Codex's
database, or start another app-server beside Desktop.

The adapter follows the installed CLI-generated schemas for `thread/start`,
`thread/resume`, `thread/name/set`, and `turn/start`. OpenAI documents those in
its [app-server reference](https://learn.chatgpt.com/docs/app-server), but labels
the app-server integration experimental. The in-chat `create_thread` tool is
not assumed to be externally callable. A working Desktop-compatible socket and
a real bookmark delivery must still prove task creation, visible text in the
sidebar task, and persistence across restart. A successful `doctor` only proves
that a known Desktop task can be read through that server.

No reusable X API credentials were found in the searched project `.env` key
names under `~/dev`, X-related config filenames under `~/.config`, or the
current environment. Earlier `x-engagement` work used signed-in Chrome. That is
not an OAuth token with bookmark access. This search does not prove that no
credentials exist in a password manager or elsewhere.

## Authentication and cost

X requires an approved developer app and a **user** OAuth token with
`bookmark.read`, `tweet.read`, and `users.read`.
[X bookmark lookup quickstart](https://docs.x.com/x-api/posts/bookmarks/quickstart/bookmarks-lookup)

The included PKCE login supports an X **Native App / public client**, requests
those scopes plus `offline.access`, and refreshes expiring tokens automatically.
It requests no posting, messaging, or bookmark-write permission. Confidential
Web App or bot clients requiring a client secret are not supported by this
helper. Browser cookies and app-only bearer tokens are not substitutes.
[X OAuth reference](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code)

X API reads are paid separately from Codex. As checked on 14 September 2026,
eligible owned bookmark reads cost **$0.001 per resource** when the authorized
user owns the developer app. Standard post and user reads have different prices;
author expansions and `/users/me` can add resources. X describes daily UTC
deduplication as a soft guarantee. Repeated full scans can therefore incur
charges again each day, even when no new task is created. Confirm your app's
eligibility, expansion billing, and spending limit in the developer console.
This tool does not buy credits or enable auto-recharge.
[X pricing](https://docs.x.com/x-api/getting-started/pricing)

## Setup

Requires macOS and Python 3.10+. No pip packages are needed. Run from a permanent
repo checkout before installing the service, since launchd retains absolute
paths. Do not install it from a disposable worktree.

```sh
python3 tools/x-bookmarks/bookmarks.py init
```

This creates disabled configuration at
`~/Library/Application Support/x-bookmarks/config.json`. Edit it locally. Keep
credentials out of this repo and out of chat.

1. Set `client_id` from your X Native App. Register the exact callback URL
   `http://127.0.0.1:8767/callback` in its OAuth settings.
2. Run `python3 tools/x-bookmarks/bookmarks.py login` and authorize in the
   browser. Login only obtains credentials, without fetching bookmarks or
   enabling paid reads. Tokens are stored in `oauth.json` with mode `0600`.
3. After reviewing and approving X usage costs, set `allow_paid_x_api` to `true`
   and run `python3 tools/x-bookmarks/bookmarks.py poll` once. The entire first
   successful paginated snapshot becomes the baseline and creates **no tasks**.

Alternatively, import an existing public-client user token into the private
`token_file`: JSON fields are `access_token`, `refresh_token`, `scope` (a
space-separated string), and `expires_at` (Unix seconds). Set `client_id` for
refresh. Preserve file mode `0600`. Never paste token values into command-line
arguments. Account identity is checked using `/users/me` and pinned in state;
switching accounts requires a different state directory and baseline.

Only after a compatible existing Codex server is available:

1. Set `codex_binary` to the absolute output of `command -v codex` and, if
   needed, `codex_socket` to its supported control socket path. Set
   `desktop_probe_thread_id` to a known local Desktop task ID.
2. Run `python3 tools/x-bookmarks/bookmarks.py doctor`. It performs read-only
   JSON-RPC initialization and task lookup, with no X calls or LLM requests.
3. Set `enable_experimental_codex_delivery` to `true`. Bookmark one new post,
   wait for the configured interval, run `poll`, then `deliver`. Check its task
   in Desktop, including full text, author, link, and persistence. Repeat polling
   to verify it stays one task before enabling the background timer.

Task creation preserves the configured default model. Only a newly discovered
post triggers `turn/start`, which can use Codex tokens. Its prompt asks for a
minimal acknowledgment, explicitly excludes research and tool use, and labels
the post as untrusted quoted data. The task uses a read-only sandbox and its own
local directory containing `bookmark.json`. Prompt constraints are not a general
tool-permission boundary; inspect the first real turn before enabling delivery.

## Background service

After successful baseline and delivery verification:

```sh
bash tools/x-bookmarks/install-launchagent.sh
python3 tools/x-bookmarks/bookmarks.py status
tail -n 20 ~/Library/Logs/x-bookmarks.log
```

The installer refuses to start without API configuration and a baseline. If
delivery is enabled, it also requires a successful Desktop history probe.
It installs `com.mikerosoft.x-bookmarks` as a normal per-user LaunchAgent.
launchd wakes once per minute; a persisted `next_poll` enforces the configured
poll interval (default five minutes), including across restarts. Transient
failures use exponential backoff, and HTTP 429 honors server retry hints.
An exclusive process lock prevents overlapping CLI and scheduled runs.

```sh
# Stop the service, preserving tokens, captured posts, and deduplication history:
bash tools/x-bookmarks/install-launchagent.sh --uninstall

# Inspect generated configuration without starting anything:
bash tools/x-bookmarks/install-launchagent.sh --output /tmp/x-bookmarks.plist
```

`bash install_mac.sh` installs the `x-bookmarks` CLI symlink only. It never opts
into API billing, starts polling, or installs the LaunchAgent. No Windows
installer changes are needed for this macOS-only tool.

## Delivery and recovery

The SQLite state records each post forever. Removing and re-bookmarking the same
post will not create a second task. Back up the state directory; deleting it
loses deduplication. An empty initial snapshot still establishes a baseline.
All pages must succeed before any snapshot is committed. A page error, missing
author, repeated cursor, or `max_pages` limit leaves the prior snapshot intact.
Do not raise the default 20-page limit without reviewing the associated cost.

Polling observes what X returns, not an atomic bookmark event stream. Posts
added and removed between polls cannot be detected. An X-hidden bookmark that
first becomes visible later is indistinguishable from a new bookmark; the
baseline covers only the API-visible collection. Changes during pagination can
also move a post between pages; a later scan can recover it. No filtering by
tweet creation date is used, since an old tweet can be bookmarked today.

States are `baseline`, `pending`, `creating`, `created`, `submitting`, and
`delivered`. `delivered` means Codex acknowledged accepting the turn, not that
the model completed successfully. Up to five pending posts are delivered per
timer tick. Failures before the creation request leave a post pending. A known
created task is reused. A lost creation/submission response leaves an uncertain
state that is **never retried automatically**, including after a crash.

`status` lists uncertain post IDs and any known task IDs, without their text.
Inspect the Desktop task history, including archived tasks and the matching
directory under `state-dir/tasks/POST_ID`, before manually resolving:

```sh
# Task exists and already contains the captured post:
x-bookmarks resolve POST_ID --thread-id TASK_ID --confirmed-outcome captured

# Task exists but no user message was submitted; reuse it on the next delivery:
x-bookmarks resolve POST_ID --thread-id TASK_ID --confirmed-outcome created-without-message

# Only after confirming the interrupted creation never made a task:
x-bookmarks resolve POST_ID --confirmed-outcome not-created
```

These commands record the operator's confirmed outcome; they do not infer it or
contact Codex. `not-created` is rejected if a task ID is already known. There is
no automatic exactly-once guarantee from the destination API. Holding ambiguous
deliveries trades automatic recovery for protection against duplicate tasks.

## Verification

```sh
python3 -m unittest discover -s tools/x-bookmarks/tests -v
```

Tests use fake X responses and a fake Codex subprocess, with no paid calls. They
cover pagination, baseline/restart behavior, old tweet IDs, account changes,
partial responses, expired-token refresh, private file modes, duplicate guards,
lost responses, manual recovery, PKCE state, launchd arguments, HTTP error
redaction, rate-limit backoff, and unchanged polls that never open Codex.

Live OAuth, X billing, task creation, sidebar visibility, and model completion
remain unverified until the two external prerequisites above are resolved.

Icon: reused famfamfam Silk `page_white_link.png`, Mark James, CC BY 2.5.
