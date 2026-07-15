# nagsly

A continuous, dismiss-to-stop **meeting alarm for macOS**. It plays a looping
alarm ~1 minute before a meeting (and a quiet heads-up toast earlier), and keeps
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
nagsly next                   # dry-run: next meeting + what it WOULD arm
nagsly stop                   # silence a currently-firing alarm
nagsly fetch <name> [args]    # run nagsly-fetch-<name> on PATH
```

## How it fires

Two independent modes per meeting, each with its own lead + on/off toggle:

- **toast** at `toast_lead` (default T-10m): one quiet `alerter` notification, no
  sound — a liveness signal that nagsly is alive and sees the meeting.
- **alarm** at `alarm_lead` (default T-60s): a continuous looping `afplay` alarm
  + a non-blocking `alerter` with a **Stop** action + a safety auto-timeout.

The launchd poller runs every 5 minutes and does **not** fire the alarm itself —
it finds the next meeting and spawns a detached `nagsly fire` that sleeps to the
exact second. So firing is second-accurate regardless of the coarse poll. Run
toast-only first (`alarm_enabled: 0`) to build trust, then flip the loud alarm
on.

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
deterministically in SuperDB: timed-only, `eventType == default`, not cancelled,
not declined, and drops solo holds while **keeping** a company all-hands (keyed
on `organizer.self`, so a truncated-attendee all-hands organized by someone else
survives).

> `gws` is open source (Apache-2.0) but its README notes it is "not an officially
> supported Google product." Core nagsly has zero calendar dependency — the
> plugin is swappable, and you can always `nagsly add` by hand.

## Config

`~/.config/nagsly/config.json` (seeded from [`config.example.json`](config.example.json)).
Knobs: `toast_lead`, `alarm_lead`, `toast_enabled`, `alarm_enabled`, `sound_file`,
`alarm_timeout`, `arm_window`. Each is also overridable via an `UPPER_SNAKE` env
var of the same name.

Storage is all local JSON under `~/.config/nagsly/`; per-source event files live
in `events.d/`, and a fetch overwrites its own file wholesale.

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

## Design

The full build spec and every decision behind it lives in
**[docs/DESIGN.md](docs/DESIGN.md)**.
