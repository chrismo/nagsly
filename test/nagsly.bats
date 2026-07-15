#!/usr/bin/env bats
#
# Test suite for nagsly. Ported from the prototype's meeting-alarm.bats and
# extended for the new surface (single binary, per-source JSON store, plugins).
#
# Determinism: a pinned NAGSLY_NOW + TZ so epoch conversion and HH:MM rendering
# are identical regardless of the host clock/timezone; an isolated NAGSLY_DIR
# per test so nothing touches the real ~/.config/nagsly.

BIN="$BATS_TEST_DIRNAME/../bin/nagsly"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/gcal-raw.json"

setup() {
  TEST_DIR="$(mktemp -d "$TMPDIR/nagsly-test.XXXXXX")"
  export NAGSLY_DIR="$TEST_DIR/cfg"
  mkdir -p "$NAGSLY_DIR/events.d"
  # 2026-07-13 22:33 CDT — before the earliest surviving meeting (07-14 15:30).
  export NAGSLY_NOW=1784000000
  export TZ=America/Chicago
  export ASDF_SUPERDB_VERSION=0.3.0
  # HARD SAFETY: no test may ever produce real audio or a blocking dialog. A
  # dry fire clears its state and exits immediately without sleeping/playing.
  export NAGSLY_DRY_FIRE=1
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Wrap the raw-API fixture as gws NDJSON-style input and build it into gws.json.
build_gws() {
  "$BIN" build gws < "$FIXTURE"
}

# ── the SuperDB transform / filter set (ported from the prototype) ───────────

@test "build keeps exactly the four real meetings" {
  build_gws
  run "$BIN" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "list is epoch-sorted ascending" {
  build_gws
  run "$BIN" list
  [[ "${lines[0]}" == *"Eng managers chat"* ]]
  [[ "${lines[1]}" == *"Engineering Forum"* ]]
  [[ "${lines[2]}" == *"Change Management"* ]]
  [[ "${lines[3]}" == *"All hands - Q3 kickoff"* ]]
}

@test "renders HH:MM in local time and carries the title" {
  build_gws
  run "$BIN" list
  [[ "${lines[0]}" == "15:30  Eng managers chat"* ]]
  [[ "${lines[1]}" == "10:00  Engineering Forum"* ]]
  [[ "${lines[2]}" == "12:00  Change Management"* ]]
  [[ "${lines[3]}" == "10:00  All hands - Q3 kickoff"* ]]
}

@test "keeps a company all-hands whose attendee list is truncated to just self" {
  # Google truncates large invites (guestsCanSeeGuests:false) so only 'self'
  # appears in attendees. It is NOT a solo hold because someone else organizes
  # it — a genuine solo hold has organizer.self == true. Keying on
  # organizer.self is what preserves the all-hands. (Prototype regression.)
  build_gws
  run "$BIN" list
  [[ "$output" == *"All hands - Q3 kickoff"* ]]
}

@test "drops declined, all-day, focus, solo, cancelled, and past events" {
  build_gws
  run "$BIN" list
  [[ "$output" != *"declined"* ]]
  [[ "$output" != *"all-day"* ]]
  [[ "$output" != *"Focus block"* ]]
  [[ "$output" != *"Solo hold"* ]]
  [[ "$output" != *"Cancelled"* ]]
  [[ "$output" != *"Way in the past"* ]]
}

@test "advancing now past a meeting drops it from list" {
  # now = 2026-07-15 11:00 CDT: after Eng Forum (10:00) and Eng mgrs (07-14),
  # so Change Management (07-15 12:00) and All hands (07-16 10:00) survive.
  build_gws
  export NAGSLY_NOW=1784131200
  run "$BIN" list
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"Change Management"* ]]
  [[ "${lines[1]}" == *"All hands - Q3 kickoff"* ]]
}

@test "a corrupt events file errors loudly, not silently as 'no meetings'" {
  # Regression: a SuperDB read failure must NOT look like an empty calendar —
  # for an alarm, a silent read error means the alarm quietly never fires.
  printf 'this is not json {{{' > "$NAGSLY_DIR/events.d/manual.json"
  run "$BIN" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"error reading events"* ]]
  run "$BIN" poll
  [ "$status" -ne 0 ]
}

@test "empty events feed yields no upcoming meetings, exit 0" {
  printf '{"events":[]}' | "$BIN" build gws
  run "$BIN" list
  [ "$status" -eq 0 ]
  [[ "$output" == "no upcoming meetings" ]]
}

@test "lowercase eventType/status (real API casing) is handled" {
  printf '%s' '{"events":[
    {"summary":"Lower","eventType":"default","status":"confirmed","start":{"dateTime":"2026-07-16T10:00:00-05:00"},"attendees":[{"email":"a@x","organizer":true},{"email":"me@x","self":true,"responseStatus":"accepted"}]},
    {"summary":"FocusLower","eventType":"focusTime","status":"confirmed","start":{"dateTime":"2026-07-16T11:00:00-05:00"}}
  ]}' | "$BIN" build gws
  run "$BIN" list
  [[ "$output" == *"Lower"* ]]
  [[ "$output" != *"FocusLower"* ]]
}

# ── event id (stable across re-fetch) ────────────────────────────────────────

@test "re-fetch produces identical ids (no thrash)" {
  build_gws
  before="$(cat "$NAGSLY_DIR/events.d/gws.json")"
  build_gws
  after="$(cat "$NAGSLY_DIR/events.d/gws.json")"
  [ "$before" = "$after" ]
}

# ── manual event store: add / list / rm / clear ─────────────────────────────

@test "add with full ISO stores and lists the event" {
  run "$BIN" add "Manual mtg" "2026-07-16T14:00:00-05:00"
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == *"14:00  Manual mtg"* ]]
  [[ "$output" == *"[manual]"* ]]
}

@test "add with HH:MM resolves to today at that local time" {
  run "$BIN" add "Today thing" "23:45"
  [ "$status" -eq 0 ]
  run cat "$NAGSLY_DIR/events.d/manual.json"
  [[ "$output" == *'"start":"2026-07-13T23:45:00-05:00"'* ]]
}

@test "add with 'tomorrow HH:MM' resolves to the next day" {
  run "$BIN" add "Tomorrow thing" "tomorrow 09:30"
  [ "$status" -eq 0 ]
  run cat "$NAGSLY_DIR/events.d/manual.json"
  [[ "$output" == *'"start":"2026-07-14T09:30:00-05:00"'* ]]
}

@test "add rejects an unparseable when" {
  run "$BIN" add "Bad" "half past noon"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]]
}

@test "add escapes a title containing a double quote" {
  run "$BIN" add 'Say "hi"' "2026-07-16T10:00:00-05:00"
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == *'Say "hi"'* ]]
}

@test "rm removes a manual event by id" {
  # Grab the id straight from the add receipt ("... (id <hex>)").
  local add_out id
  add_out="$("$BIN" add "Removable" "2026-07-16T10:00:00-05:00")"
  id="$(printf '%s' "$add_out" | sed -E 's/.*\(id ([0-9a-f]+)\).*/\1/')"
  run "$BIN" rm "$id"
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" != *"Removable"* ]]
}

@test "rm of an unknown id reports not found, leaves store intact" {
  "$BIN" add "Keep me" "2026-07-16T10:00:00-05:00"
  run "$BIN" rm deadbeefdead
  [[ "$output" == *"no manual event with id"* ]]
  run "$BIN" list
  [[ "$output" == *"Keep me"* ]]
}

@test "clear with no arg wipes only manual, leaves fetched sources" {
  build_gws
  "$BIN" add "Manual one" "2026-07-16T10:00:00-05:00"
  run "$BIN" clear
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" != *"Manual one"* ]]
  [[ "$output" == *"All hands - Q3 kickoff"* ]]   # gws source survived
}

@test "clear <source> wipes that source" {
  build_gws
  run "$BIN" clear gws
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == "no upcoming meetings" ]]
}

# ── per-source merge ─────────────────────────────────────────────────────────

@test "list merges manual + fetched sources, sorted by epoch" {
  build_gws
  # 07-15 11:00 CDT, between Eng Forum (10:00) and Change Management (12:00).
  "$BIN" add "Interleaved" "2026-07-15T11:00:00-05:00"
  run "$BIN" list
  # Order: Eng mgrs(07-14) < Eng Forum(07-15 10) < Interleaved(11) < Change(12) < All hands
  [[ "${lines[2]}" == *"Interleaved"* ]]
  [[ "${lines[2]}" == *"[manual]"* ]]
}

# ── the alarm engine: arm-window + dry-run (ported) ──────────────────────────

# Put one manual meeting `secs` seconds after NAGSLY_NOW.
seed_meeting() {
  local secs="$1" title="${2:-Soon}"
  local epoch=$(( NAGSLY_NOW + secs ))
  local iso
  iso="$(date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '[{"id":"seed1","source":"manual","start":"%s","title":"%s"}]\n' "$iso" "$title" \
    > "$NAGSLY_DIR/events.d/manual.json"
}

@test "next arms nothing when the meeting is far beyond the arm window" {
  # 17h out: toast fire (T-10m) is ~16.8h away, far past ARM_WINDOW=360.
  seed_meeting $(( 17 * 3600 ))
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD arm"* ]]
  [[ "$output" == *"Soon"* ]]   # still reported as next
}

@test "next arms the alarm once the meeting enters the arm window" {
  # 90s out: alarm fire_at = T-60s = 30s away, within ARM_WINDOW=360.
  seed_meeting 90
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD arm alarm"* ]]
}

@test "arm is idempotent: an already-armed mode is a dry-run no-op" {
  # 90s out: alarm is within the arm window. Pre-create the alarm state file
  # (simulating an earlier poll's arm). `next` (dry-run) must then NOT claim it
  # would arm the alarm again — the state file makes re-arm a no-op.
  seed_meeting 90
  local epoch=$(( NAGSLY_NOW + 90 ))
  mkdir -p "$NAGSLY_DIR/state"
  printf '%s\t%s\t%s\n' "$epoch" "09:59" "Soon" > "$NAGSLY_DIR/state/arm-alarm-$epoch"
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD arm alarm"* ]]
}

@test "poll spawns a dry fire and records an arm state file" {
  # With NAGSLY_DRY_FIRE the spawned fire exits immediately (no audio/sleep). A
  # real poll therefore just proves the spawn path runs cleanly end to end.
  seed_meeting 90
  run "$BIN" poll
  [ "$status" -eq 0 ]
}

@test "arm respects mode toggles (alarm off => no alarm arm)" {
  seed_meeting 90
  ALARM_ENABLED=0 run "$BIN" next
  [[ "$output" != *"WOULD arm alarm"* ]]
}

# ── alarm fire wiring (no real audio) ────────────────────────────────────────

@test "alarm fire runs the afplay loop and stops on timeout (stubbed, silent)" {
  # Verify the alarm-mode wiring end to end WITHOUT real sound or a blocking
  # dialog: stub afplay + alerter on PATH so nothing audible/visible happens.
  # afplay records each invocation; a 1s alarm_timeout stops the loop; alerter
  # returns immediately (mimicking a Stop click) so the fire doesn't block.
  local stub="$TEST_DIR/stub"; mkdir -p "$stub"
  cat > "$stub/afplay" <<EOF
#!/usr/bin/env bash
echo "afplay \$*" >> "$TEST_DIR/afplay.calls"
sleep 0.1
EOF
  cat > "$stub/alerter" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub/afplay" "$stub/alerter"

  # fire_epoch in the past => no sleep; fire immediately. NAGSLY_DRY_FIRE MUST be
  # unset for this one test so the real alarm path runs (against the stubs).
  local past=$(( NAGSLY_NOW - 10 ))
  run env -u NAGSLY_DRY_FIRE PATH="$stub:$PATH" ALERTER=alerter ALARM_TIMEOUT=1 \
    "$BIN" fire alarm "$past" "Wiring test" "09:59"
  [ "$status" -eq 0 ]

  # afplay was invoked at least once with the configured sound file.
  [ -f "$TEST_DIR/afplay.calls" ]
  grep -q "Sosumi.aiff" "$TEST_DIR/afplay.calls"

  # The fire returned (status 0 above) rather than looping forever — the
  # alarm_timeout=1 path killed the loop. (We don't pgrep global afplay: that
  # would match unrelated audio the developer may be playing.)
}

# ── status readout ───────────────────────────────────────────────────────────

@test "status reports next meeting and mode toggles" {
  seed_meeting $(( 2 * 3600 ))
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Soon"* ]]
  [[ "$output" == *"modes:"* ]]
  [[ "$output" == *"feed:"* ]]
}

# ── plugin dispatch ──────────────────────────────────────────────────────────

@test "fetch runs a plugin found on PATH and repopulates its source file" {
  # A fake plugin on PATH that writes gws.json via `nagsly build`.
  local pdir="$TEST_DIR/plugins"
  mkdir -p "$pdir"
  cat > "$pdir/nagsly-fetch-fake" <<EOF
#!/usr/bin/env bash
cat "$FIXTURE" | "$BIN" build fake
EOF
  chmod +x "$pdir/nagsly-fetch-fake"
  PATH="$pdir:$PATH" run "$BIN" fetch fake
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == *"[fake]"* ]]
  [[ "$output" == *"All hands - Q3 kickoff"* ]]
}

@test "fetch fails cleanly when the plugin is not on PATH" {
  run "$BIN" fetch nonexistent-source
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin not found"* ]]
}
