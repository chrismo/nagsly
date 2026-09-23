# nagsly — for Claude

`nagsly` is a standalone macOS meeting-alarm CLI. It is **built and in daily
use** — this is maintenance, not a build-out. The README's "Design notes" section
holds the decisions that cost something to learn; don't re-litigate them.

## Layout

- `bin/nagsly` — the whole tool (one bash binary, git-style subcommands)
- `plugins/nagsly-fetch-gws` — Google Calendar fetcher (Google Workspace CLI)
- `plugins/nagsly-sync-gws`, `nagsly-sync-pr`, `nagsly-sync-gmail` — one-shot
  adapters for the core sync scheduler
- `plugins/nagsly-monitor-pr`, `plugins/nagsly-monitor-gmail` — registration and
  state checking for GitHub/Gmail monitors
- `test/nagsly.bats` + `test/fixtures/` — the suite
- `install.sh`, `com.chrismo.nagsly.plist.template`
- `specs/` — plans for un-built work

## Non-negotiables (the ones easiest to get wrong)

- **Never store this repo under `~/Library/CloudStorage`** — launchd can't exec
  there. It lives at `~/dev/nagsly`.
- **SuperDB pinned:** `export ASDF_SUPERDB_VERSION=0.3.0`. The 0.3.0 idiom
  gotchas are in the README's Design notes (`is()` not `!= null`, `coalesce` not
  `??`, `//` is division not a comment, `-dynamic` for heterogeneous input, `-f
  line` not `-f text`, etc.). Test queries via the superdb MCP + real runs.
- **Sound = afplay, never alerter.** alerter is visual only — its sound flag is
  unreliable.
- **The afplay loop must stay self-bounding** (checks its own deadline). A
  separate `sleep; kill` timer gets reaped by launchd, which leaves a runaway
  loop with no killer. This actually happened.
- **launchd = StartInterval + RunAtLoad, not KeepAlive** (short script, not a
  daemon). Loaded-check uses `launchctl print gui/<uid>/<label>`, not
  `launchctl list | grep`.
- **Config/storage is JSON** under `~/.config/nagsly/`. Per-source event files in
  `events.d/`; a fetch overwrites its own file wholesale. Integration sync is
  core-scheduled by its separate LaunchAgent; never put network work on alarm's
  path.
- **The all-hands-not-a-solo-hold** filter (key on `organizer.self`) and the
  **focus-time exemption** both have regression tests — keep them.

## Workflow

- TDD — the suite is good; add a failing test first.
- `bats test/nagsly.bats` must stay green. The suite exports `NAGSLY_DRY_FIRE=1`
  so no test can produce real audio.
- Note that the `poll` path can't observe alarm timing: the stubbed alerter
  returns instantly, so `do_fire` kills the loop after one play. Test loop
  timing against the loop body directly.
- Verify alarm changes by **actually hearing it** (short `alarm_timeout`).
- Commit straight to `main`; no branches or PRs in this repo.
- Run `./install.sh` after editing — nagsly runs from `~/.local/bin`, so repo
  edits are inert until installed.
