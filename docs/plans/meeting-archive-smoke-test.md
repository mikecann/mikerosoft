# Meeting Archive smoke test

Start with Zoom. Its camera-triggered recording, muted-call continuity,
automatic save, Bruce transfer, transcription, and Notion publication have
passed a short live test. Google Meet is still blocked pending the browser
capture choice; Teams and Slack are not yet validated live.

## Before the call

Bruce's [worker app drive permission](../../tools/meeting-archive/worker/launcher/README.md)
is complete. The background processor is enabled and passed managed startup,
clean shutdown, and automatic restart with one worker holding the service lock.
This call will test new media through that managed service. An actual reboot
remains untested.

1. Open `~/Applications/Meeting Archive.app` and Settings. Meeting detection,
   Screen and meeting audio, and Microphone should say Granted.
2. Enable notifications for Meeting Archive in macOS Settings. They currently
   say Denied, so start/finish alerts will not appear until this is changed.
3. To test calendar suggestions, add the personal and Convex Google accounts
   to macOS Internet Accounts with Calendars enabled, then select the actual
   calendars in Meeting Archive. Only iCloud calendars are currently visible.
4. Leave local-copy cleanup off for this test. The permanent originals on
   Bruce have no automatic deletion policy.

## First call, about three minutes

1. Open a new private Zoom meeting with a second device or willing participant.
   Camera preview alone should not start a recording. Join and turn the camera
   on; the menu-bar indicator and Library should show recording.
2. Have both people state their names and a short distinctive sentence. Share
   a slide or some code containing small text. Use headphones to avoid echo.
3. Mute yourself in Zoom and speak another sentence. Meeting Archive should
   continue capturing your microphone. Open an unrelated app briefly; it
   should keep recording the identified meeting window.
4. Turn your Zoom camera off while remaining in the call. Recording should
   stop after the detector observes that change. Ignore the naming prompt;
   it should save after 20 seconds and continue processing automatically.
5. Allow Bruce a few minutes. The earlier 149-second test processed and
   published in about 217 seconds; this is a measured example, not a deadline.

## Check the result

- Title, date, start time, and duration are correct. Calendar suggestions only
  apply once the Google calendars are connected.
- The saved video shows the call and readable shared content. Both voices,
  including the sentence spoken while muted in Zoom, are audible.
- The Library reaches Published to Notion. Transcript and speaker review load
  from Bruce. Listen to unknown-speaker excerpts and confirm the correct names.
- Timestamp links seek correctly. The private HTTPS route from Notion still
  needs approval/activation; the Library's Play action retrieves via SSH.
- A second short call tests whether confirmed speakers are recognized using
  new speech. Recognition should leave uncertain matches unnamed.
- A final brief session tests Skip this meeting. It stops capture and suppresses
  the current camera session; the already captured portion still follows the
  normal save/discard prompt.

After reviewing the result, enable “This directory is covered by Bruce’s
backup; remove verified local media” to remove verified local duplicates. The
backup configuration includes CannMedia, but a backup restore test is still
outstanding. Keep any failed example and report the app, approximate time,
expected behaviour, and observed result so it can be investigated.

This smoke test does not substitute for the remaining long-call, failure,
window-transition, wider-app, backup-restore, and reboot tests in the main plan.
