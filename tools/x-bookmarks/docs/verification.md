# Verification, 15 September 2026

- 40 Python tests pass, covering X polling, OAuth, CLI delivery, interrupted
  attempts, no-process unchanged checks, and durable runtime installation.
- Six website tests pass; TypeScript and Vite production build pass.
- Browser inspection confirmed the new tool card and generated banner render.
- A private copy of the existing 18-bookmark database was used for a controlled
  catch-up test. The newest existing bookmark was removed only from that copy,
  and its saved head was reset so the real X API treated it as unseen.
- The real API returned one pending bookmark alongside 17 baseline bookmarks.
  The actual CLI delivered it and exited successfully. Desktop's task reader
  confirmed the exact author, text, original link, and completed acknowledgment.
- Test task ID: `01a0a3d5-fd89-7ad2-87e5-678cb7460f57`.
- Repeating the real API check and delivery kept the same one delivered task.
- The normal 18-bookmark baseline was not changed by that test.
- LaunchAgent `com.mikerosoft.x-bookmarks` was installed using a versioned runtime
  outside the Git worktree. Its initial unchanged tick exited with code 0.

The controlled test used an existing bookmark as unseen local input. A fresh
user bookmark arriving through the installed timer has not yet been observed.
Desktop restart persistence and long-duration absence of flicker were not tested.
The website was verified locally, not on the public production deployment.

## Fresh bookmark and background delivery follow-up

The next real bookmark was detected by the installed timer, but its first CLI
attempt failed before task creation because launchd's PATH omitted the npm
installation's Node directory. The CLI environment now explicitly includes the
configured Codex executable's parent directory. A regression test covers this.

After verifying that no task existed for that bookmark, its uncertain state was
reconciled and the actual LaunchAgent was retriggered. It created and completed
one task, `01a0a3e8-142a-71d0-abce-09272821fe85`. Desktop read back the exact
bookmark payload and acknowledgment. Repeating delivery created no duplicate.
The background process exited with code 0. All 41 Python tests pass.
