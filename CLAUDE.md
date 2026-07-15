# nagsly — for Claude

You are building `nagsly`, a standalone macOS meeting-alarm CLI. **Read
`docs/DESIGN.md` first** — it is the full build spec and captures every decision
already made (do not re-litigate them).

## Orientation

- **`seed/`** holds a *working, tested* prototype (four `meeting-alarm-*.sh`
  scripts + a passing `bats` suite + the launchd plist template + config example).
  It proves the hard parts. **Reuse its logic; do not preserve its shape** — the
  target architecture is different (single binary, subcommands, per-source JSON
  stores, plugins). Delete `seed/` once its logic is absorbed.
- The target layout: `bin/` (the `nagsly` binary), `plugins/`
  (`nagsly-fetch-gcalcli`, …), `test/` (bats + fixtures), `docs/`, `install.sh`.

## Non-negotiables (from DESIGN.md — the ones easiest to get wrong)

- **Never store this repo under `~/Library/CloudStorage`** — launchd can't exec
  there. It lives at `~/dev/nagsly`.
- **SuperDB pinned:** `export ASDF_SUPERDB_VERSION=0.3.0`. The 0.3.0 idiom
  gotchas are listed in DESIGN.md (`is()` not `!= null`, `coalesce` not `??`,
  `//` is division not a comment, `-dynamic` for heterogeneous input, `-f line`
  not `-f text`, etc.). Test queries live via the superdb MCP + real runs.
- **Sound = afplay, never alerter.** alerter is visual only.
- **launchd = StartInterval + RunAtLoad, not KeepAlive** (short script, not a
  daemon). Loaded-check uses `launchctl print gui/<uid>/<label>`, not
  `launchctl list | grep`.
- **Config/storage is JSON** under `~/.config/nagsly/`. Per-source event files in
  `events.d/`; a fetch overwrites its own file wholesale.
- **The all-hands-not-a-solo-hold** filter (key on `organizer.self`) and the
  **arm-window** behaviour both have regression tests in the prototype — keep them.

## Workflow

TDD where the prototype already has tests (port + extend them). Verify the alarm
engine end-to-end by actually hearing it (short `alarm_timeout` for tests). The
GitHub remote is deferred — build locally; `gh repo create chrismo/nagsly` later.
