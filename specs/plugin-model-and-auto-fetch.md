# Spec: auto-fetch + a generalized plugin model

Status: **proposed / not yet implemented.** This spec captures a set of decisions
reached in discussion; it is the implementation contract for the next work
session. Line numbers are intentionally omitted (they rot) — functions are named
so they can be grep'd in `bin/nagsly`.

## Why

The launchd poller reads `events.d/*.json` every 60s and fires inline, but
**nothing refreshes the feed** — you must run a fetch by hand or the feed goes
stale and new/moved events never alarm. Primary goal: **auto-fetch** — the poller
keeps the feed current on its own.

A thought-experiment ("what if a `pomo` plugin also existed?") pressure-tested the
plugin model and showed it's **fetch-shaped** — built around gws being the only,
calendar-pull plugin. Facts confirmed against the code:

- Only two plugin↔core entry points exist: `nagsly fetch <name>` (fire-and-forget
  passthrough, `cmd_fetch`) and `nagsly build <source>` (stdin,
  **Google-Calendar-shaped**, normalizes+writes wholesale, `cmd_build`).
- **No tick-time plugin hook** — `cmd_poll`/`fire_mode` never invoke a plugin.
  Feed refresh is entirely external today.
- `build`/`normalize_source` is **hardwired to the Google Calendar schema**
  (`events[].start.dateTime`, `eventType`, `organizer.self`, `attendees[].self`).
  A generator plugin emitting plain `{start,title}` can't use it.

Intended outcome: **ship gws auto-fetch**, done through a **generalized plugin
contract** that also fits a future command-driven generator like pomo — without
over-building for pomo (young codebase: don't preclude, don't pre-build).

## Decided architecture

1. **One binary per plugin, `nagsly-<name>`.** Retire the `nagsly-fetch-` infix.
   `plugins/nagsly-fetch-gws` → `plugins/nagsly-gws`.

2. **Core imposes exactly ONE verb on plugins: `nagsly-<name> --auto`**, run each
   poll tick for names listed in a new config `auto_fetch: [...]`. **The plugin
   owns its own interval** and decides what a tick means (gws: maybe-fetch, gated
   by its own last-run marker; a future pomo: maybe-advance a running session).
   Chosen over "core owns the interval" because it stays source-agnostic and fits
   both a periodic puller and a command generator.

3. **Core sheds `fetch` entirely.** `fetch` was gws's own verb wearing a core
   costume (pomo would never "fetch"). Remove `cmd_fetch`, `list_fetch_plugins`,
   `fetch_hint`, the `fetch)` dispatch, and the `fetch` usage/header lines.
   Plugins own their full CLI, invoked directly (`nagsly-gws`, `nagsly-gws 4`, and
   later e.g. `nagsly-pomo start 4`). No core passthrough/router (can be added
   later, non-breaking).

4. **Tick invocation is failure-isolated**: a plugin's `--auto` erroring or hanging
   must NEVER block `read_events`/`fire_mode`. Run each `--auto` backgrounded and
   detached from the poll's fire path; the poll proceeds to read+fire regardless.

Minor naming note (not blocking): the knob `auto_fetch` is slightly gws-flavored
given the generic `--auto` verb. Fine for what ships now; could later rename to
`auto_plugins`/`tick_plugins` if a non-fetch plugin lands.

## Write path: Option 1 (Split) — chosen

`build` is already a 3-stage assembly line, and **only stage 1 is
Google-specific**:

1. `normalize_source` — gcal `{events:[…]}` → filtered TSV `source\tstart\ttitle` (Google-only)
2. `cmd_build` shell loop — adds `id` per row via `event_id` (source-agnostic)
3. `rows_to_array` + `write_source` — TSV → escaped JSON → atomic file (source-agnostic)

The refactor is a clean factoring — no filter logic moves:

- **Factor stages 2+3 into `assemble_and_write <source>`** (TSV
  `source\tstart\ttitle` on stdin → adds id, escapes, atomic wholesale write;
  reuses `event_id`, `rows_to_array`, `write_source`).
- **`cmd_build`** becomes `cat | normalize_source "$src" | assemble_and_write "$src"`
  — byte-identical behavior; gws keeps piping to `nagsly build gws` unchanged.
- **Add `cmd_write <source>`** = `canon_to_rows "$src" | assemble_and_write "$src"`,
  where **`canon_to_rows`** is a thin SuperDB pass mirroring `normalize_source`'s
  OUTPUT but with NO calendar filters — accepts canonical
  `{"events":[{"start":"<ISO-offset>","title":"…"}]}`, drops past/untimed, sorts
  by start, tab-guards title, emits the same internal TSV. (Deliberately a thin
  SuperDB pass reusing the proven idiom — not a hand-rolled shell JSON parser.)
- **Dispatch:** add `write) cmd_write "$@" ;;` + a usage line.

Why Option 1 over "make build generic + move the filter into gws": the
all-hands-not-solo-hold regression (keys on `organizer.self` so a
truncated-attendee all-hands survives) is the suite's most subtle, hard-won test.
Option 1 leaves `normalize_source` and every `build gws` test **byte-for-byte in
place**. Moving the filter into the plugin would relocate that logic into a
harder-to-test spot and force reconstructing its regression test + reshaping the
fixture (`{events:}`→`{items:}`) — pure downside for the highest-risk code. Core
still imposes nothing calendar-specific on plugins (it imposes only `--auto`);
`build` is just a shared gcal-normalizer utility a plugin MAY use, while pomo uses
`write`.

Canonical plugin stdin shape (for `nagsly write <source>`):
```json
{"events":[{"start":"2026-07-15T14:00:00-05:00","title":"Pomodoro break"}]}
```

## Plugin organization — "core plugins", bundled but decoupled

Bundled plugins live in this repo as **core plugins** (better UX than a separate
repo), with external contribution supported. The boundary that prevents improper
coupling is the **PATH contract, not the repo boundary** — a plugin is
discovered/invoked only by being `nagsly-<name>` on PATH and speaks only two
contracts (`--auto` tick; stdin → `nagsly build`/`nagsly write`). It never sources
core or shares files beyond `events.d/<name>.json` + its own `state/` marker.

Discipline: **a bundled plugin must be written exactly as an external one** —
copyable to another repo, dropped on PATH, works unchanged (gws already satisfies
this). Concretely:

- **`plugins/` = standalone `nagsly-<name>` executables.** The only core surface a
  plugin touches is the `nagsly` binary on PATH.
- **Install boundary — bundled = available, NOT running.** `install.sh` copies
  core always and copies plugins, but enables NONE (`auto_fetch` defaults `[]`).
  Opt a plugin in by adding `<name>` to `auto_fetch` (+ auth for gws).
- **Enforced decoupling**, not just documented:
  - `docs/PLUGINS.md` — the plugin contract (PATH name `nagsly-<name>`, the
    `--auto` verb, stdin→`build`/`write`, per-plugin `state/` marker, MUST NOT
    source core, MUST run standalone) + how to contribute an external plugin.
  - A bats coupling test: for each `plugins/nagsly-*` — is executable; does NOT
    `source`/`.` the core `nagsly`; runs standalone. Proves "copyable to another
    repo unchanged."

## DESIGN.md retirement

`docs/DESIGN.md` was a build-handoff spec; the build is done and has diverged from
it. Retire it:
1. **Salvage** the durable decisions/rationale not recoverable from code (why gws
   over gcalcli/.ics; why inline over detached-fire; SuperDB 0.3.0 idiom gotchas;
   the all-hands-not-solo-hold bug + why) into **README** — or `specs/` if any
   genuinely un-built material remains (e.g. the MCP feeder, merge-to-one-file).
   Triage built vs. un-built during execution.
2. **Delete** `docs/DESIGN.md`.

## Incidental cleanups (found during exploration; fold in)

- `config.example.json` still ships dead `arm_window` (code never reads it) and a
  comment claiming a 300s poll (it's 60s). Remove `arm_window`; fix the interval
  note; make the `_modes` "sees your meetings" comment event-neutral; add
  `auto_fetch` (default `[]`).
- `config()` comment falsely claims a `NAGSLY_<KEY>` env prefix; only the bare
  UPPER_SNAKE key is honored. Fix the comment (or honor the prefix).

## Files to modify

- `bin/nagsly` —
  - Write path: factor `assemble_and_write`; `cmd_build` delegates to it; add
    `cmd_write` + `canon_to_rows`; wire `write)` into `main` + usage.
  - Remove fetch surface: `cmd_fetch`, `list_fetch_plugins`, `fetch_hint`, the
    `fetch)` dispatch, the `fetch` usage/header lines.
  - Tick hook: in `cmd_poll`, after `prune_markers`, for each name in `auto_fetch`
    (via `config`) run `nagsly-<name> --auto` backgrounded + detached, never
    blocking read/fire.
  - Config comment fix (the NAGSLY_ prefix claim).
- `plugins/nagsly-fetch-gws` → `plugins/nagsly-gws` — `git mv` rename; add an
  `--auto` verb (own interval + last-run marker under `state/`, e.g.
  `state/autofetch-gws`); bare/`N`-day invocation stays the manual fetch;
  pipeline stays `… | nagsly build gws`.
- `install.sh` — glob `nagsly-*` (was `nagsly-fetch-*`); message updates.
- `config.example.json` — add `auto_fetch` (default `[]`); remove dead
  `arm_window`; fix the 300s / "sees your meetings" comments.
- `test/nagsly.bats` — replace the two fetch-dispatch tests with the new model;
  add `nagsly write pomo` canonical-input tests (past-drop, sort, escaping, id
  stability) + a new fixture `test/fixtures/canon.json`; add `--auto` tick
  coverage (stub a `nagsly-<name>` on PATH, assert the tick invokes it + a failing
  one doesn't block firing); add the coupling test. All existing `build gws`
  calendar-filter tests stay UNCHANGED.
- `docs/PLUGINS.md` — NEW: the plugin contract + external-contribution guide.
- `README.md` — new invocation model (`nagsly-gws`, `auto_fetch`, `--auto`
  contract, `write` vs `build`, "core plugins" pointing at PLUGINS.md); salvaged
  design rationale.
- `docs/DESIGN.md` — salvage rationale → README (or `specs/`), then delete.

## Verification

- `bats test/nagsly.bats` green (all-hands regression preserved).
- Real daemon: set `auto_fetch:["gws"]`, confirm the poll tick refreshes
  `events.d/gws.json` (watch mtime + `nagsly.log`) with no second launchd job / no
  "Background Activity" notification; confirm a forced plugin failure doesn't stop
  firing (feed staleness visible in `status`, alarm still fires on last-good feed).
- Confirm `nagsly-gws --auto` no-ops cheaply when its interval hasn't elapsed.
