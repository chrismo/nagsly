# nagsly

A continuous, dismiss-to-stop **meeting alarm for macOS**. It plays a looping
alarm a couple minutes before a meeting (and a quiet heads-up toast earlier), and keeps
sounding until you dismiss it — the behaviour of the Clock app alarm, but
calendar-aware. It *nags* you so you stop missing the start of meetings while
heads-down.

## Shape

- **Core** = a per-source JSON event store + an alarm engine. No calendar
  dependency; you can `nagsly add` events by hand and it will alarm on them.
- **Plugins** (`nagsly-fetch-<name>` on PATH) populate events from real
  calendars. `nagsly-fetch-gws` is the standalone Google Calendar feeder (built
  on the [Google Workspace CLI](https://github.com/googleworkspace/cli)).
- One binary, git-style subcommands.

```
nagsly add "<title>" <when>   # add a manual event. <when>:
                              #   HH:MM | "tomorrow HH:MM" | +Nm | +Nh | full ISO
nagsly list                   # merged view of all sources, next-first
nagsly rm <id>                # remove one manual event
nagsly clear [source]         # wipe a source's file (default: manual)
nagsly poll                   # launchd entry point: arm the next meeting
nagsly status                 # read-only "is it working" rollup
nagsly stop                   # silence a currently-firing alarm
nagsly fetch <name> [args]    # run nagsly-fetch-<name> on PATH
```

## How it fires

Two independent modes per meeting, each with its own lead + on/off toggle:

- **toast** at `toast_lead` (default T-10m): one quiet `alerter` notification, no
  sound — a liveness signal that nagsly is alive and sees the meeting.
- **alarm** at `alarm_lead` (default T-2m): a continuous looping `afplay` alarm
  + a non-blocking `alerter` with a **Stop** action + a safety auto-timeout.

The launchd poller runs every 60 seconds. On each tick it fires any mode whose
lead window is open and that hasn't already fired (a per-(mode,epoch) marker
dedups across the many ticks a meeting spends in-window). Firing is therefore
bounded by the poll interval (±60s), not second-accurate — the lead defaults are
set wide enough (alarm at T-2m) that the alarm reliably sounds *before* the
meeting minute rather than landing on it. Run toast-only first
(`alarm_enabled: 0`) to build trust, then flip the loud alarm on.

Silence a firing alarm with `nagsly stop` (bind it to a hotkey for one-touch
dismissal), the alerter's Stop action, or just wait out the auto-timeout.

## Install

```bash
./install.sh          # copies the binary + plugins to ~/.local/bin, seeds
                      # ~/.config/nagsly/config.json, loads the launchd agent
nagsly status         # confirm it's loaded
nagsly add "Test" +2m # a manual event to prove firing end-to-end
```

`./install.sh --uninstall` removes the agent and installed files (leaves your
config + events intact).

## Calendar feed (gws plugin)

```bash
gws auth login        # one-time interactive OAuth (you run this)
nagsly fetch gws      # pull the next 4 days into events.d/gws.json
nagsly fetch gws 7    # …or N days
```

`nagsly-fetch-gws` pulls upcoming events via the Google Workspace CLI (JSON, with
server-side recurrence expansion), and `nagsly build` applies all filtering
deterministically in SuperDB: timed-only, `eventType` of `default` or
`focusTime`, not cancelled, not declined, and drops solo holds while **keeping**
a company all-hands (keyed on `organizer.self`, so a truncated-attendee all-hands
organized by someone else survives).

Focus time is nagged like any meeting. A focus block is structurally identical to
a solo hold — organized by you, no attendees — so it is explicitly exempted from
the solo-hold filter. A hold is a placeholder; focus time is time you defended on
purpose and are most likely to let slip.

> `gws` is open source (Apache-2.0) but its README notes it is "not an officially
> supported Google product." Core nagsly has zero calendar dependency — the
> plugin is swappable, and you can always `nagsly add` by hand.

## Config

`~/.config/nagsly/config.json` (seeded from [`config.example.json`](config.example.json)).
Knobs: `toast_lead`, `alarm_lead`, `toast_enabled`, `alarm_enabled`, `sound_file`,
`alarm_timeout`, `alarm_gap`. Each is also overridable via an `UPPER_SNAKE` env
var of the same name.

The alarm repeats its sound until dismissed or until `alarm_timeout`, with
`alarm_gap` seconds of silence between repeats (default **8**). Set `alarm_gap: 0`
to play back-to-back — the repeat rate then becomes the sound file's own length,
which for a short sound like Submarine.aiff is relentless. The gap never pushes
the loop past `alarm_timeout`: it sleeps in 1-second slices and re-checks the
deadline each slice.

Storage is all local JSON under `~/.config/nagsly/`; per-source event files live
in `events.d/`, and a fetch overwrites its own file wholesale.

## Alternatives to consider

nagsly's niche is narrow: a CLI-first, launchd-polled, *continuously looping
audible* alarm you must actively dismiss, with a solo-hold filter. Most existing
tools instead do a **one-shot notification** or a **visual screen takeover**. If
that fits you better, these are the ones worth a look:

- [MeetingBar](https://github.com/leits/MeetingBar) — open source (macOS
  menu bar). Notifications + optional full-screen reminder; Shortcuts/AppleScript
  hooks. One-shot, not a persistent audio loop.
- [Meeting Reminder](https://github.com/adamswbrown/meeting-reminder) — open
  source native menu-bar app; progressive alerts, full-screen reminders.
- [In Your Face](https://www.inyourface.app/mac/) — paid. Blocks your entire
  screen at meeting time (visual-first, not an audible loop).
- [BigReminder](https://bigreminder.app/) — paid. Full-screen calendar takeover.
- [Meety](https://getmeety.app/) — paid menu-bar calendar with a stronger alert
  layer + one-click join.
- [Calendar Alarm](https://apps.apple.com/us/app/calendar-alarm/id6737744058) —
  paid App Store app; the closest on *audio* — a real loud alarm that rings on
  silent — but GUI-only, iOS-flavored, no scripting or solo-hold filter.
- Native [Calendar alerts](https://support.apple.com/guide/calendar/set-alerts-for-an-event-icl1012/mac)
  (optionally + Automator for full-volume sound) — free, built in, but one-shot.

## Why a standalone local repo

macOS launchd cannot execute scripts stored under `~/Library/CloudStorage`
(Google Drive) — background agents get `Operation not permitted`. This tool must
live on real local disk. Do not move it under CloudStorage.

## macOS deps

`afplay` (sound), `launchd` (scheduling), [`alerter`](https://github.com/vjeantet/alerter)
(visual notifications), [`super`](https://superdb.org) (SuperDB, transforms;
pinned to 0.3.0 via `ASDF_SUPERDB_VERSION`), and for the calendar plugin,
[`gws`](https://github.com/googleworkspace/cli).

## Tests

```bash
bats test/nagsly.bats
```

Deterministic via a pinned `NAGSLY_NOW` + `TZ` and an isolated `NAGSLY_DIR` per
test. The suite exports `NAGSLY_DRY_FIRE=1` so no test can ever produce real
audio; one stubbed-alerter test exercises the alarm wiring silently.

## Design notes

The decisions that cost something to learn, and would not be obvious from
reading the code.

### Firing happens inline, not from a detached timer

The obvious design is a coarse poll that arms a precise detached one-shot
(`sleep` to the exact second, then fire). That works from an interactive shell
and **does not survive launchd** (verified on-device): launchd reaps a job's
entire process tree when the poll exits — `nohup`, `disown`, and double-fork all
die with it. Registering each fire as its own launchd job *does* survive, but
trips a per-arm "Background Activity" notification on Ventura+ (BTM). Both were
dead ends.

So the poller fires **inside the poll process**. The cost is accuracy: firing is
bounded by the 60s poll interval, not second-accurate. That's fine for a
nag-me-when-it-starts alarm, and it stops fighting launchd.

### The audio loop is self-bounding

`alerter`'s own sound flag is unreliable (hit on this machine, and in an RWX
script too), so `alerter` is **visual only** here and `afplay` does all audio.

The loop checks a deadline each iteration and stops *itself* after
`alarm_timeout`. A separate `sleep; kill` timer would be a background child that
launchd reaps when the poll's tick ends — leaving the loop running forever with
no killer. That was a real runaway during the build. A self-bounding loop
auto-stops even if the poll is reaped mid-alarm.

The loop's argv carries a `nagsly-alarm-loop` sentinel so `nagsly stop` can
`pkill -f` the loop without killing the poller it runs inside.

### launchd gotchas

`StartInterval` 60s + `RunAtLoad`, **not** `KeepAlive` — the poller is a
short-lived script, not a daemon, and `KeepAlive` would tight-loop it. A failed
poll self-heals on the next tick, and each run writes a heartbeat line that
`nagsly status` reads to answer "is it actually executing?" (as opposed to merely
"loaded" — heartbeat freshness is the tell).

To check whether the agent is loaded, use `launchctl print "gui/$(id -u)/<label>"`,
**not** `launchctl list | grep`. The legacy `list` reflects the *caller's*
bootstrap session, so a script spawned outside the login session false-reports
"not loaded". That cost a debug cycle.

### Why `gws` and not the secret `.ics` feed

Google expands recurring meetings server-side, so the plugin needs no RRULE
engine. The `.ics` feed emits raw RRULEs — 282 of them across 8 timezones in the
real feed — which would require a full iCal recurrence engine. Rejected for that
reason; the cost is a one-time interactive OAuth.

### Focus time is nagged (amended after real use)

The original filter dropped everything with `eventType != default`, which put
focus blocks in the same bucket as OOO and birthdays. Real usage disagreed: a
focus block booked to force an unglamorous task is *exactly* what gets forgotten,
more so than a meeting — nobody else is waiting on you and nothing interrupts
you.

Verified against the live API, a focus block carries `eventType: "focusTime"`,
`organizer.self: true`, and **no `attendees` key at all** — structurally
indistinguishable from a solo hold. So both the eventType filter *and* the
solo-hold filter had to change; either one alone still drops it. The plugin also
had to widen its `eventTypes` request to `["default","focusTime"]`, since the API
was filtering them out upstream where no downstream filter could recover them.

The exemption is deliberately narrow: focus time bypasses the eventType and
solo-hold filters only. Cancelled and already-started focus blocks are still
dropped like any event.

Considered and rejected: a `nagsly` keyword in the event description as a
per-event opt-in. More flexible, but ~2–3x the work for flexibility not needed,
and it taxes you at creation time — exactly when you're rushed and most likely to
forget. If focus blocks ever show up that should *not* nag, the right move is an
opt-*out* marker.

### The all-hands that looks like a solo hold

Dropping solo holds is keyed on `organizer.self`, not on the attendee count. A
company all-hands has a truncated attendee list (Google returns only you when
`guestsCanSeeGuests: false`), so counting attendees silently eats it — a real bug
caught in the prototype. It's organized by someone *else*, which is what
distinguishes it. There's a regression test; keep it.

### Reschedule and cancel

Nothing is pre-armed — each poll re-reads the feed and decides fresh whether a
mode is due — so a moved or cancelled meeting is picked up on the next tick, as
long as the feed is refreshed. The one residual exposure is inside a mode's lead
window: if a meeting is cancelled *after* its fired-marker is written but before
the feed refreshes, that one alarm still stands. Rare and benign — a spurious
alarm to dismiss.

### SuperDB 0.3.0 idioms (pinned via `ASDF_SUPERDB_VERSION`)

These bite, and cost real debugging:

- field presence is `where is(field, <string>)` — **not** `!= null`, which
  silently matches nothing. This is also what drops all-day events (they carry
  `start.date`, not `start.dateTime`).
- null-coalesce is `coalesce(x, default)` — **not** `??`.
- cast is `cast(x, <type>)` — **not** `type(x)`. Epoch seconds are
  `cast(cast(<iso>, <time>), <int64>) / 1000000000` (int64 of a time is
  nanoseconds).
- for local HH:MM, slice the ISO string `start.dateTime[11:16]` — the string's
  own offset already encodes local time, so no tz/DST math. `strftime` renders
  UTC.
- per-record array predicates use a bracketed subquery:
  `[unnest attendees | where ...]`, then `len(...)`.
- **`//` is division, not a comment.** SPQ has no line-comment syntax — keep
  narrative in the surrounding shell, not in the query.
- string `+` concatenation is unsupported. Emit records and use `-f tsv
  -noheader`, or build JSON, rather than string-joining.
- `-dynamic` is required for heterogeneous or empty input (records missing
  fields, or an empty `events: []`) — otherwise static type-checking fails on
  absent fields.
- `-f text` is deprecated; use `-f line`.

### Canonical event schema

```json
{ "id": "<stable-id>", "source": "gws", "start": "2026-07-16T10:00:00-05:00", "title": "All hands" }
```

`start` is ISO 8601 **with offset**. Core derives epoch and local HH:MM from it at
read time rather than pre-freezing them, so the store stays timezone-honest and
human-readable. `id` is stable across re-fetch so re-fetching doesn't thrash.
Each write is atomic (tmp file, then `mv`), and a fetch overwrites its own
source file wholesale — no merge logic in fetchers, no way to clobber another
source or your manual events.
