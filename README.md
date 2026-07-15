# nagsly

A continuous, dismiss-to-stop **meeting alarm for macOS**. It plays a looping
alarm ~1 minute before a meeting (and a quiet heads-up toast earlier), and keeps
sounding until you dismiss it — the behaviour of the Clock app alarm, but
calendar-aware. It *nags* you so you stop missing the start of meetings while
heads-down.

> **Status: under construction.** This repo was just scaffolded from a working
> prototype (see `seed/`). The build is specified in **[docs/DESIGN.md](docs/DESIGN.md)** —
> start there.

## Shape (target)

- **Core** = a JSON event store + an alarm engine. No calendar dependency; you
  can `nagsly add` events by hand.
- **Plugins** (`nagsly-fetch-<name>` on PATH) populate events from real calendars.
  `nagsly-fetch-gcalcli` is the standalone Google Calendar feeder.
- Single binary, git-style subcommands: `add`, `list`, `rm`, `clear`, `poll`,
  `status`, `next`, `stop`, `fetch`.

## Why a standalone local repo

macOS launchd cannot execute scripts stored under `~/Library/CloudStorage`
(Google Drive) — background agents get `Operation not permitted`. This tool must
live on real local disk. Do not move it under CloudStorage.

## macOS deps

`afplay` (sound), `launchd` (scheduling), [`alerter`](https://github.com/vjeantet/alerter)
(visual notifications), [`super`](https://superdb.org) (SuperDB, transforms;
pinned to 0.3.0), and for the calendar plugin, `gcalcli`.
