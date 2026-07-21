# nagsly — design & build handoff

`nagsly` is a **continuous, dismiss-to-stop meeting alarm for macOS** — the last
mile that Google Calendar's transient toast notifications don't cover. It plays a
looping alarm sound ~1 minute before a meeting (and a quiet "heads-up" toast
earlier), and keeps sounding until dismissed — the behaviour of the macOS Clock
app alarm, but calendar-aware and scriptable.

This doc is the build spec. It was extracted from a working prototype (see
`seed/`) that lived inside a Google-Drive-backed repo, which is exactly why this
is being rebuilt as a standalone local tool — **launchd cannot execute scripts
stored under `~/Library/CloudStorage` (Google Drive); background agents get
`Operation not permitted` / exit 126.** `~/dev/nagsly` is on real local disk, so
launchd can run it. Do not move this repo under CloudStorage.

The name: it *nags* you until you deal with the meeting.

---

## Provenance

The prototype in `seed/` is a **working, tested** meeting alarm (the four
`meeting-alarm-*.sh` scripts + a passing `bats` suite). It proves the hard parts:
the launchd arming model, the afplay loop, the SuperDB transform, the calendar
filters. **Reuse its logic; do not preserve its shape.** The rebuild changes the
architecture substantially (below). `seed/` is raw material, not the target
layout — delete it once its logic has been absorbed.

`seed/meeting-alarm-refresh.md` is the Claude/MCP feeder (see Plugins). It stays
conceptually external — it becomes one plugin among several.

---

## Architecture (the target)

### Core = a JSON event store + an alarm engine. Zero calendar dependency.

Core `nagsly` knows nothing about Google Calendar. You can type events in by
hand and it will alarm on them. Calendar sources are **plugins** that populate
events; core just stores and arms them.

Two things core owns:

1. **A per-source JSON event store** under `~/.config/nagsly/events.d/`:
   ```
   ~/.config/nagsly/events.d/
     manual.json     # written by `nagsly add` / `rm` / `clear`
     gcalcli.json    # written wholesale by nagsly-fetch-gcalcli
     claude.json     # written wholesale by the MCP feeder
   ```
   Each file is a JSON array of canonical events. **A fetch overwrites its own
   file wholesale** — no merge logic in fetchers, no risk of clobbering another
   source or your manual events. Atomic write per file (write tmp, `mv`).

   **Canonical event schema** (decided):
   ```json
   { "id": "<stable-id>", "source": "gcalcli", "start": "2026-07-16T10:00:00-05:00", "title": "All hands" }
   ```
   `start` is an ISO 8601 string **with offset** (Google returns local-with-
   offset). Core derives epoch + local HH:MM from `start` at read time — never
   pre-freezes them — so it stays timezone-honest and human-readable. `source` is
   slightly redundant given per-source files but is cheap and survives a future
   merge-to-one-file; keep it.

2. **The alarm engine** — merge all `events.d/*.json` on read, find the next
   event after now, and for each enabled mode arm a precise fire (below).

### Single binary, git-style subcommands

One `nagsly` executable dispatches subcommands (decided — replaces the prototype's
four separate scripts):

```
# event store (core, manual path)
nagsly add "<title>" <when>     # append to manual.json; <when> = ISO or HH:MM (today)
nagsly list                     # merged view of all sources, next-first
nagsly rm <id>                  # remove one event (manual source; see open Qs)
nagsly clear [source]           # wipe a source's file (default: manual)

# alarm engine (core)
nagsly poll                     # launchd entry point: arm fires for the next meeting
nagsly status                   # read-only rollup (see below)
nagsly next                     # dry-run: next meeting + what it WOULD arm
nagsly stop                     # silence a currently-firing alarm

# plugins
nagsly fetch <name> [args...]   # run `nagsly-fetch-<name>` on PATH, repopulate <name>.json
```

Internal subcommand `build` dispatches from the same binary but is not
user-facing (`build`/normalize is a helper the plugins call). (The prototype
also had an internal `fire` subcommand the poller spawned detached; the inline
firing model — see the core mechanic below — removed it.)

### Language

The prototype is bash. The single-binary refactor is still fine in bash (a
`case "$1"` dispatcher), but this is the moment to decide if a slightly richer
language pays off given JSON storage + subcommands. **Recommendation: stay bash**
— the deps (afplay, launchctl, alerter, gcalcli, super) are all shell-shaped, and
SuperDB does the JSON heavy lifting. Don't rewrite in another language without a
reason.

---

## The alarm engine (proven in seed/ — preserve this behaviour)

### Two independent fire modes per meeting, each with its own lead + toggle

- **toast** at `TOAST_LEAD` (default **T-10m**): one quiet `alerter` notification,
  no sound. A liveness/confidence signal ("nagsly is alive and sees this
  meeting"), meant to slot alongside Google's existing 4h/2h/30m/2m toasts.
- **alarm** at `ALARM_LEAD` (default **T-60s**): the continuous looping `afplay`
  alarm + a non-blocking `alerter` with a Stop action + a safety auto-timeout.

Each mode independently enable/disable-able (run toast-only first to build trust,
then flip the loud alarm on).

### The core mechanic — inline firing (revised from the prototype)

> **Design change, made during the build — this supersedes the prototype's
> "coarse poll arms a precise detached one-shot".** The prototype spawned
> `nagsly fire … &` (nohup, detached) to `sleep` to the exact second, for
> second-accurate firing. That model was proven from an interactive shell but
> **does not survive the launchd daemon on modern macOS** (verified on-device):
> launchd reaps a job's entire process tree when the poll exits — `nohup`,
> `disown`, and double-fork all die. Registering each fire as its own launchd
> job *does* survive, but trips a per-arm **"Background Activity" notification**
> (Ventura+ BTM; also verified). Both were dead ends.

The poller now **fires inline**. launchd runs `nagsly poll` on a short interval
(`StartInterval` **60s**). Each run finds the next meeting and, per enabled mode,
fires **inside the poll process** if `now` is within that mode's lead window
(`fire_at <= now < event_epoch`) and it hasn't already fired. Firing is bounded
by the poll interval (**±60s**), not second-accurate — acceptable for a
"nag-me-when-it-starts" alarm, and it stops fighting launchd.

Dedup: a per-`(mode, epoch)` marker `~/.config/nagsly/state/fired-<mode>-<epoch>`.
A 60s poll sees the same meeting in-window for many ticks; the marker fires each
mode exactly once. Markers whose meeting epoch is now past are pruned each poll.

**Double-booked meetings (two+ at the same start).** The poll considers all
events sharing the earliest in-window start, not just the one that sorts first —
an earlier `head -n 1` fired for only the first-sorting meeting and left the
other silent (hit live). Because the alarm mode blocks the poll while it sounds,
firing per-meeting would stack blocking alarms back-to-back and double the nag;
instead the slot fires **once** with every co-starting title joined (`"Standup +
1:1 with Sam"`) so you know you're double-booked. The `(mode, epoch)` marker key
already means "one fire per time slot", so it needs no change for this — same
epoch, same marker.

### Sound is `afplay`, never `alerter` — and the loop is self-bounding

`alerter`'s own sound flag is unreliable (confirmed on this machine — Chris hit it
in an RWX script too). `alerter` is **visual only** here; a looping `afplay`
subshell does all audio. The loop is **self-bounding**: it checks a deadline each
iteration and stops itself after `alarm_timeout`. This is deliberate — a
*separate* `sleep; kill` timer is a background child that launchd reaps when the
poll's tick ends, leaving the loop running forever with no killer (a real runaway
hit during the build). A self-bounding loop auto-stops even if the poll is reaped
mid-alarm. The loop's argv carries a sentinel (`nagsly-alarm-loop`) so
`nagsly stop` = `pkill -f nagsly-alarm-loop` + `killall afplay` matches the loop
without killing the poller it runs inside (verified).

### launchd agent

`StartInterval` 60s + `RunAtLoad`, **NOT** `KeepAlive`. The poller is a
short-lived script, not a daemon — `KeepAlive` would tight-loop it. Silent-failure
protection = the unconditional 5-min re-run (a failed poll self-heals next tick) +
a heartbeat line each run in `~/.config/nagsly/nagsly.log`. `nagsly status` reads
this to answer "is it alive?".

**launchd loaded-check gotcha (cost us a debug cycle):** check
`launchctl print "gui/$(id -u)/com.<label>"`, NOT `launchctl list | grep`. The
legacy `list` reflects the *caller's* bootstrap session, so a script spawned
outside the login session false-reports "not loaded".

### `nagsly status` — the confidence readout

```
nagsly status
  poller: loaded (launchd), last heartbeat 40s ago
  feed:   7 meeting(s) across 2 source(s)
  next:   'Eng managers chat' @ 15:30 (in 4h)
  fired:  (none yet — modes fire within their lead window)
  modes:  toast on (T-10m)   alarm on (T-60s)
```
This is the primary "is it working" surface — Chris's whole motivation for the
tool is *confidence it will fire*, so status must be honest about the difference
between "loaded" and "actually executing" (heartbeat freshness is the tell).

---

## Plugins — `nagsly-fetch-<name>` on PATH (decided)

`nagsly fetch gcalcli` runs `nagsly-fetch-gcalcli` if present on PATH (git-style
external subcommands). A plugin's job:

1. pull from its source,
2. **filter + normalize** to the canonical event schema,
3. write its own `events.d/<name>.json` wholesale (via a core helper or directly).

**All calendar-specific concerns live in the plugin, not core** — the SuperDB
filtering, RRULE handling, timezone resolution. Core stays source-agnostic.

### Plugin: `nagsly-fetch-gcalcli` (the standalone calendar feeder)

`gcalcli` is chosen over the secret `.ics` feed because **Google expands recurring
meetings server-side** — no RRULE-expansion engine needed. (The `.ics` feed emits
raw RRULEs — verified 282 RRULEs / 8 timezones in the real feed — which would
require a full iCal recurrence engine. Rejected for that reason.) Cost: a one-time
`gcalcli` OAuth setup (interactive; Chris runs it).

The **filter set** (proven in `seed/meeting-alarm-build-events.sh`, a SuperDB
0.3.0 transform — reuse it):
- timed only (drop all-day)
- eventType == DEFAULT (drop focus/OOO/working-location/birthday)
- status != cancelled
- self attendee not declined
- **not a solo hold**: drop iff *I* organize it AND no other attendee is listed.
  Critically, a company all-hands has a truncated attendee list (Google returns
  only you when `guestsCanSeeGuests:false`) but is organized by *someone else*, so
  it survives. Keying on `organizer.self` is what distinguishes them. **This was a
  real bug caught in the prototype — preserve the test for it.**
- drop already-started (epoch <= now)

### Plugin: the Claude/MCP feeder (lives in work-rig, external)

`seed/meeting-alarm-refresh.md` is a Claude slash-command that calls the hosted
Google Calendar MCP (the only calendar access available inside a Claude session),
dumps raw JSON, and normalizes. It is **one more fetcher** — not required, not in
this repo's critical path. It writes `events.d/claude.json`. Keep it working from
work-rig; nagsly just consumes the file. (It predates gcalcli and is why "Strategy
C" existed: MCP is live-session-only and can't run headless, which is the whole
reason a standalone fetcher like gcalcli is wanted.)

---

## SuperDB (the transform engine — pinned 0.3.0)

Storage + transforms use **SuperDB**, pinned via `ASDF_SUPERDB_VERSION=0.3.0`
(the runtime the 0.3.0 docs/idioms target; the machine's default `super` is a
pre-release build). JSON in, JSON/TSV out. Chris prefers SuperDB over jq across
this tooling (sibling of his day-timeline pipelines).

**Hard-won 0.3.0 idioms (these bite — from real debugging in the prototype):**
- field presence: `where is(field, <string>)` — **not** `!= null` (which silently
  matches nothing). This also drops all-day events (they carry `start.date`, not
  `start.dateTime`).
- null-coalesce: `coalesce(x, default)` — **not** `??`.
- cast: `cast(x, <type>)` — **not** `type(x)`. Epoch seconds =
  `cast(cast(<iso>, <time>), <int64>) / 1000000000` (int64 of a time = nanoseconds).
- local HH:MM: slice the ISO string `start.dateTime[11:16]` — the string's own
  offset already encodes local time, so no tz/DST math. (strftime renders UTC.)
- per-record array predicate: `[unnest attendees | where ...]` subquery in
  brackets, then `len(...)`.
- **`//` is division, not a comment.** SPQ has no line-comment syntax; keep
  narrative in the surrounding shell, not the query.
- string `+` concatenation is unsupported — emit records and use `-f tsv
  -noheader`, or build JSON, rather than string-joining.
- `-dynamic` is required for heterogeneous/empty input (records missing fields,
  or an empty `events:[]` array) — otherwise static type-checking fails on absent
  fields.
- output formats: `-f line`, `-f tsv`, `-f json`, `-S`/`-s` for Super JSON. `-f
  text` is deprecated (use `-f line`).

---

## Config & state (`~/.config/nagsly/`, all local, no secrets)

```
~/.config/nagsly/
  config.json         # knobs (JSON — Chris wants JSON for all config/storage)
  events.d/*.json     # per-source event stores
  state/fired-*       # per-(mode,epoch) "already fired" markers (pruned when past)
  nagsly.log          # heartbeat log
```
Knobs: `toast_lead` (600), `alarm_lead` (60), `toast_enabled`, `alarm_enabled`,
`sound_file` (default `/System/Library/Sounds/Submarine.aiff`), `alarm_timeout`
(90). All overridable via env for tests (the prototype used `MEETING_ALARM_NOW` +
`MEETING_ALARM_DIR` for deterministic bats — carried here with a `NAGSLY_*`
prefix; `NAGSLY_DRY_FIRE` makes a fire a silent no-op so no test produces audio).
(`arm_window` is gone — it belonged to the removed detached-arm model.)

---

## Installer

`install.sh` must **copy** (not symlink) the binary + plugins to a real local
exec path (`~/.local/bin`), materialize the launchd plist from a `.template` with
`$HOME` + label substituted, and `launchctl bootstrap` it. The **copy vs symlink**
point is load-bearing only if this repo ever lived under CloudStorage — since
`~/dev/nagsly` is local, a symlink to it is actually fine. Either works; document
the reason. Seed `~/.config/nagsly/config.json` from an example (never overwrite an
existing one).

---

## Tests

Carry the prototype's `bats` approach: `$TMPDIR`-isolated `NAGSLY_DIR` per test,
pinned `NAGSLY_NOW` + `TZ=America/Chicago` for deterministic epoch/HH:MM. The
prototype's 12 tests were ported and extended (31 total) to cover the new
surface: `add`/`list`/`rm`/`clear`, the per-source merge, id stability, plugin
dispatch, the inline fire-window + dedup + prune, and a silent stubbed-alerter
alarm-wiring test. Kept: the all-hands-not-solo-hold regression test and the
fire-window (formerly arm-window) tests. The whole suite exports
`NAGSLY_DRY_FIRE=1` so no test can ever produce real audio.

---

## Open questions for the build session

1. **`rm`/`clear` semantics** across per-source files: does `rm <id>` only apply to
   `manual.json`, or can it remove a single fetched event (which the next fetch
   would restore anyway)? Leaning: `rm`/`add` touch only `manual.json`; `clear
   [source]` wipes a whole source file.
2. **`fetch` merge on read** if two sources list the "same" meeting — probably
   don't dedupe yet; revisit if it's annoying in practice.
3. **id generation** for events (manual + fetched) — stable enough that re-fetch
   doesn't thrash, e.g. hash of `source+start+title`.
4. **`nagsly add <when>`** parsing — support bare `HH:MM` (today) and full ISO;
   decide what "tomorrow 9am" ergonomics are worth.

---

## Reschedule/cancel

The inline model largely dissolves the prototype's known reschedule/cancel
limitation. Because nothing is pre-armed — each poll re-reads the feed and
decides fresh whether a mode is due — a meeting that moves or cancels is picked
up on the next 60s tick, as long as the feed is refreshed (`nagsly fetch`). The
only residual exposure is within a single mode's lead window: if a meeting is
cancelled *after* its `fired-<mode>-<epoch>` marker is written but the feed
hasn't refreshed, that one already-delivered alarm stands. Rare, benign (a
spurious alarm to dismiss), and far smaller than the prototype's hours-long
sleeping-timer exposure.
