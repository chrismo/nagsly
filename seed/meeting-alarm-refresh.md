---
description: Refresh the meeting-alarm feed — pull the next ~4 days of calendar via MCP and rebuild the flat events file the poller reads.
allowed-tools: mcp__claude_ai_Google_Calendar__list_events, Bash
---

# meeting-alarm refresh

Refresh the flat events file that the (dumb, headless) `meeting-alarm` poller
reads. This is the ONE step that needs a live Claude session: the Google
Calendar MCP is session-only, so a background job can't call it — instead a
session pre-expands the calendar (recurrence + timezones resolved by Google)
into a flat file, and the poller just reads that.

**Deterministic-everywhere principle:** your only jobs are (1) call the MCP and
(2) dump its output verbatim, then (3) run the build script. Do NOT filter,
reformat, or editorialize the events yourself — `meeting-alarm-build-events.sh`
applies all filtering (all-day / OOO / focus / declined / solo / past),
epoch-conversion, and sorting deterministically so the result is auditable and
identical every run.

## Step 1: Confirm MCP auth

If Google Calendar isn't connected, run `/mcp` → "claude.ai Google Calendar"
first. Without it, stop and tell the user.

## Step 2: Compute the window

```bash
date "+%Y-%m-%dT%H:%M:%S%z"                 # start = now
date -v+4d "+%Y-%m-%dT%H:%M:%S%z"           # end   = now + 4 days (3–4 business days)
```

## Step 3: Pull events via MCP (only DEFAULT events)

```
mcp__claude_ai_Google_Calendar__list_events(
  startTime = "<now>",
  endTime   = "<now+4d>",
  timeZone  = "America/Chicago",
  orderBy   = "startTime",
  eventType = ["DEFAULT"],        # server-side: excludes focus/OOO/working-location/birthday
  pageSize  = 250)
```

If the response has a `nextPageToken`, page through until exhausted so a busy
window isn't truncated.

## Step 4: Dump raw JSON verbatim

Write the MCP response(s) as a single JSON object to
`~/.config/meeting-alarm/events-raw.json`. The shape the build script expects is
`{"events":[ ...event objects... ]}` — exactly what `list_events` returns. If you
paged, merge the pages' `events` arrays into one object. Write it verbatim; no
hand-editing of event objects.

## Step 5: Build the flat feed (deterministic)

```bash
~/.local/bin/meeting-alarm-build-events.sh
```

(That resolves the default paths: reads `~/.config/meeting-alarm/events-raw.json`,
writes `~/.config/meeting-alarm/events`.) It prints how many upcoming meetings it
kept.

## Step 6: Receipt

Show the user the resulting `events` file (or the count) and remind them the
poller will pick it up on its next 5-minute tick — or `launchctl kickstart -k
gui/$(id -u)/com.chrismo.meeting-alarm` to arm the very next meeting immediately.
