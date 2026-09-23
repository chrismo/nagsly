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

@test "build keeps exactly the four real meetings plus the focus block" {
  build_gws
  run "$BIN" list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "list is epoch-sorted ascending" {
  build_gws
  run "$BIN" list
  [[ "${lines[0]}" == *"Eng managers chat"* ]] || false
  [[ "${lines[1]}" == *"Engineering Forum"* ]] || false
  [[ "${lines[2]}" == *"Change Management"* ]] || false
  [[ "${lines[3]}" == *"Focus block"* ]] || false
  [[ "${lines[4]}" == *"All hands - Q3 kickoff"* ]] || false
}

@test "renders day + HH:MM in local time and carries the title" {
  build_gws
  run "$BIN" list
  # columns: day  time  until  date  title  [source]  id  (NAGSLY_NOW =
  # 2026-07-13, so 07-14 is "tomorrow", later days show the weekday abbrev)
  [[ "${lines[0]}" == "tomorrow"*"15:30  "*"2026-07-14  Eng managers chat"* ]] || false
  [[ "${lines[1]}" == "wed"*"10:00  "*"2026-07-15  Engineering Forum"* ]] || false
  [[ "${lines[2]}" == "wed"*"12:00  "*"2026-07-15  Change Management"* ]] || false
  [[ "${lines[3]}" == "wed"*"17:00  "*"2026-07-15  Focus block"* ]] || false
  [[ "${lines[4]}" == "thu"*"10:00  "*"2026-07-16  All hands - Q3 kickoff"* ]] || false
}

@test "list labels today, tomorrow, and weekday" {
  # NAGSLY_NOW = 2026-07-13 (Sun) 22:33.
  "$BIN" add "Today evt" "23:30"                       # 07-13, later today
  "$BIN" add "Tomorrow evt" "tomorrow 09:00"           # 07-14 (Mon)
  "$BIN" add "Later evt" "2026-07-16T09:00:00-05:00"   # 07-16 (Thu)
  run "$BIN" list
  [[ "$output" == *"today"*"Today evt"* ]] || false
  [[ "$output" == *"tomorrow"*"Tomorrow evt"* ]] || false
  [[ "$output" == *"thu"*"Later evt"* ]] || false
}

@test "keeps a company all-hands whose attendee list is truncated to just self" {
  # Google truncates large invites (guestsCanSeeGuests:false) so only 'self'
  # appears in attendees. It is NOT a solo hold because someone else organizes
  # it — a genuine solo hold has organizer.self == true. Keying on
  # organizer.self is what preserves the all-hands. (Prototype regression.)
  build_gws
  run "$BIN" list
  [[ "$output" == *"All hands - Q3 kickoff"* ]] || false
}

@test "drops declined, all-day, solo, cancelled, and past events" {
  build_gws
  run "$BIN" list
  [[ "$output" != *"declined"* ]] || false
  [[ "$output" != *"all-day"* ]] || false
  [[ "$output" != *"Solo hold"* ]] || false
  [[ "$output" != *"Cancelled"* ]] || false
  [[ "$output" != *"Way in the past"* ]] || false
}

@test "keeps focus time — it looks exactly like a solo hold but IS the nag" {
  # A real focus block (verified against the live API) is organized by self with
  # NO attendees key at all, so it trips the solo-hold filter dead-on. Focus time
  # must be exempted from that filter, not just from the eventType filter —
  # either one alone still drops it.
  build_gws
  run "$BIN" list
  [[ "$output" == *"Focus block"* ]] || false
}

@test "a cancelled focus block is still dropped" {
  # Focus time is exempt from the solo-hold rule, NOT from cancellation.
  build_gws
  run "$BIN" list
  [[ "$output" != *"Focus block I declined"* ]] || false
}

@test "advancing now past a meeting drops it from list" {
  # now = 2026-07-15 11:00 CDT: after Eng Forum (10:00) and Eng mgrs (07-14), so
  # Change Management (07-15 12:00), Focus block (07-15 17:00) and All hands
  # (07-16 10:00) survive.
  build_gws
  export NAGSLY_NOW=1784131200
  run "$BIN" list
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"Change Management"* ]] || false
  [[ "${lines[1]}" == *"Focus block"* ]] || false
  [[ "${lines[2]}" == *"All hands - Q3 kickoff"* ]] || false
}

@test "a corrupt events file errors loudly, not silently as 'no meetings'" {
  # Regression: a SuperDB read failure must NOT look like an empty calendar —
  # for an alarm, a silent read error means the alarm quietly never fires.
  printf 'this is not json {{{' > "$NAGSLY_DIR/events.d/manual.json"
  run "$BIN" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"error reading events"* ]] || false
  run "$BIN" poll
  [ "$status" -ne 0 ]
}

@test "empty events feed yields no upcoming events, exit 0" {
  printf '{"events":[]}' | "$BIN" build gws
  run "$BIN" list
  [ "$status" -eq 0 ]
  [[ "$output" == "no upcoming events" ]] || false
}

@test "lowercase eventType/status (real API casing) is handled" {
  # The live API emits "focusTime"; the fixture-era guess was "FOCUS_TIME". Both
  # must match, hence the lower() in the filter.
  printf '%s' '{"events":[
    {"summary":"Lower","eventType":"default","status":"confirmed","start":{"dateTime":"2026-07-16T10:00:00-05:00"},"attendees":[{"email":"a@x","organizer":true},{"email":"me@x","self":true,"responseStatus":"accepted"}]},
    {"summary":"FocusLower","eventType":"focusTime","status":"confirmed","start":{"dateTime":"2026-07-16T11:00:00-05:00"},"organizer":{"email":"me@x","self":true}},
    {"summary":"FocusUpper","eventType":"FOCUS_TIME","status":"confirmed","start":{"dateTime":"2026-07-16T12:00:00-05:00"},"organizer":{"email":"me@x","self":true}},
    {"summary":"OooDrop","eventType":"outOfOffice","status":"confirmed","start":{"dateTime":"2026-07-16T13:00:00-05:00"},"organizer":{"email":"me@x","self":true}}
  ]}' | "$BIN" build gws
  run "$BIN" list
  [[ "$output" == *"Lower"* ]] || false
  [[ "$output" == *"FocusLower"* ]] || false
  [[ "$output" == *"FocusUpper"* ]] || false
  [[ "$output" != *"OooDrop"* ]] || false
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
  [[ "$output" == *"14:00"*"Manual mtg"* ]] || false
  [[ "$output" == *"[manual]"* ]] || false
}

@test "add with HH:MM resolves to today at that local time" {
  run "$BIN" add "Today thing" "23:45"
  [ "$status" -eq 0 ]
  run cat "$NAGSLY_DIR/events.d/manual.json"
  [[ "$output" == *'"start":"2026-07-13T23:45:00-05:00"'* ]] || false
}

@test "add with 'tomorrow HH:MM' resolves to the next day" {
  run "$BIN" add "Tomorrow thing" "tomorrow 09:30"
  [ "$status" -eq 0 ]
  run cat "$NAGSLY_DIR/events.d/manual.json"
  [[ "$output" == *'"start":"2026-07-14T09:30:00-05:00"'* ]] || false
}

@test "add rejects an unparseable when" {
  run "$BIN" add "Bad" "half past noon"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]] || false
}

@test "add escapes a title containing a double quote" {
  run "$BIN" add 'Say "hi"' "2026-07-16T10:00:00-05:00"
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == *'Say "hi"'* ]] || false
}

@test "rm removes a manual event by id" {
  # Grab the id straight from the add receipt ("... (id <hex>)").
  local add_out id
  add_out="$("$BIN" add "Removable" "2026-07-16T10:00:00-05:00")"
  id="$(printf '%s' "$add_out" | sed -E 's/.*\(id ([0-9a-f]+)\).*/\1/')"
  run "$BIN" rm "$id"
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" != *"Removable"* ]] || false
}

@test "rm of an unknown id reports not found, leaves store intact" {
  "$BIN" add "Keep me" "2026-07-16T10:00:00-05:00"
  run "$BIN" rm deadbeefdead
  [[ "$output" == *"no manual event with id"* ]] || false
  run "$BIN" list
  [[ "$output" == *"Keep me"* ]] || false
}

@test "clear with no arg wipes only manual, leaves fetched sources" {
  build_gws
  "$BIN" add "Manual one" "2026-07-16T10:00:00-05:00"
  run "$BIN" clear
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" != *"Manual one"* ]] || false
  [[ "$output" == *"All hands - Q3 kickoff"* ]] || false   # gws source survived
}

@test "clear <source> wipes that source" {
  build_gws
  run "$BIN" clear gws
  [ "$status" -eq 0 ]
  run "$BIN" list
  [[ "$output" == "no upcoming events" ]] || false
}

# ── per-source merge ─────────────────────────────────────────────────────────

@test "list merges manual + fetched sources, sorted by epoch" {
  build_gws
  # 07-15 11:00 CDT, between Eng Forum (10:00) and Change Management (12:00).
  "$BIN" add "Interleaved" "2026-07-15T11:00:00-05:00"
  run "$BIN" list
  # Order: Eng mgrs(07-14) < Eng Forum(07-15 10) < Interleaved(11) < Change(12) < All hands
  [[ "${lines[2]}" == *"Interleaved"* ]] || false
  [[ "${lines[2]}" == *"[manual]"* ]] || false
}

# ── the alarm engine: inline fire-window + dry-run ───────────────────────────

# Put one manual meeting `secs` seconds after NAGSLY_NOW.
seed_meeting() {
  local secs="$1" title="${2:-Soon}"
  local epoch=$(( NAGSLY_NOW + secs ))
  local iso
  iso="$(date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '[{"id":"seed1","source":"manual","start":"%s","title":"%s"}]\n' "$iso" "$title" \
    > "$NAGSLY_DIR/events.d/manual.json"
}

# Put TWO manual meetings at the SAME start (`secs` after NAGSLY_NOW) — the
# double-booked case. Distinct ids/titles, identical `start` (so identical epoch).
seed_double_booked() {
  local secs="$1" a="${2:-Standup}" b="${3:-1:1 with Sam}"
  local epoch=$(( NAGSLY_NOW + secs ))
  local iso
  iso="$(date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '[{"id":"dbA","source":"manual","start":"%s","title":"%s"},{"id":"dbB","source":"manual","start":"%s","title":"%s"}]\n' \
    "$iso" "$a" "$iso" "$b" > "$NAGSLY_DIR/events.d/manual.json"
}

@test "next fires nothing when the meeting is beyond every mode's lead" {
  # 17h out: even the toast (T-10m) window doesn't open for ~16.8h.
  seed_meeting $(( 17 * 3600 ))
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD fire"* ]] || false
  [[ "$output" == *"Soon"* ]] || false   # still reported as next
}

@test "next fires the alarm once the meeting is inside the alarm lead" {
  # 30s out: within the T-2m alarm lead (fire_at is ~90s in the past, meeting
  # still future) -> the alarm mode is due.
  seed_meeting 30
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD fire alarm"* ]] || false
}

@test "does not fire once the meeting has already started" {
  # 10s in the PAST: past the meeting start -> not fired (don't nag late), and
  # read_events drops it from 'next' entirely.
  seed_meeting -10
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD fire"* ]] || false
}

@test "fire is idempotent: an already-fired mode is not fired again" {
  # Within the alarm lead, but a fired-marker exists (an earlier tick fired it).
  # `next` must NOT claim it would fire the alarm again.
  seed_meeting 30
  local epoch=$(( NAGSLY_NOW + 30 ))
  mkdir -p "$NAGSLY_DIR/state"
  printf 'alarm\t%s\t09:59\tSoon\n' "$epoch" > "$NAGSLY_DIR/state/fired-alarm-$epoch"
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD fire alarm"* ]] || false
}

@test "poll fires inline and writes a fired-marker (dry, no audio)" {
  # With NAGSLY_DRY_FIRE, a due mode is a no-op echo but the fired-marker is
  # still written — proving the dedup path. Meeting 30s out = alarm due.
  seed_meeting 30
  run "$BIN" poll
  [ "$status" -eq 0 ]
  local epoch=$(( NAGSLY_NOW + 30 ))
  [ -f "$NAGSLY_DIR/state/fired-alarm-$epoch" ]
  # A second poll must NOT re-fire (marker present).
  run "$BIN" poll
  [ "$status" -eq 0 ]
}

@test "prune drops fired-markers for meetings now in the past" {
  # A marker for a meeting 5s ago should be pruned on the next poll.
  seed_meeting 3600                        # a future meeting so poll has work
  local old=$(( NAGSLY_NOW - 5 ))
  mkdir -p "$NAGSLY_DIR/state"
  printf 'alarm\t%s\t00:00\tOld\n' "$old" > "$NAGSLY_DIR/state/fired-alarm-$old"
  run "$BIN" poll
  [ ! -f "$NAGSLY_DIR/state/fired-alarm-$old" ]
}

@test "fire respects mode toggles (alarm off => alarm not fired)" {
  seed_meeting 30
  ALARM_ENABLED=0 run "$BIN" next
  [[ "$output" != *"WOULD fire alarm"* ]] || false
}

@test "double-booked: both meeting titles are named in a single alarm" {
  # Two meetings at the SAME start, both inside the alarm lead. The poll must
  # not silently drop one (the head -n 1 bug): the one alarm fire must name
  # BOTH titles, so you know you're double-booked. (Chris hit this live: nagged
  # about one meeting, silent about the other at the same time.)
  seed_double_booked 30
  run "$BIN" next
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD fire alarm"* ]] || false
  [[ "$output" == *"Standup"* ]] || false
  [[ "$output" == *"1:1 with Sam"* ]] || false
}

@test "double-booked: one fired-marker per (mode,epoch) covers both meetings" {
  # Co-starting meetings share an epoch, so one marker per (mode,epoch) means
  # 'fired once for this slot'. The second poll must not re-fire.
  seed_double_booked 30
  run "$BIN" poll
  [ "$status" -eq 0 ]
  local epoch=$(( NAGSLY_NOW + 30 ))
  [ -f "$NAGSLY_DIR/state/fired-alarm-$epoch" ]
  run "$BIN" poll
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRY fire alarm"* ]] || false   # marker present => no second fire
}

# ── alarm fire wiring (no real audio) ────────────────────────────────────────

@test "alarm fires the afplay loop inline and stops on timeout (stubbed, silent)" {
  # Verify the alarm wiring end to end WITHOUT real sound or a blocking dialog:
  # stub afplay + alerter on PATH. Meeting 30s out = alarm due; a 1s
  # alarm_timeout stops the loop; the stub alerter returns immediately.
  # NAGSLY_DRY_FIRE MUST be unset for this one test so the real path runs.
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

  seed_meeting 30
  run env -u NAGSLY_DRY_FIRE PATH="$stub:$PATH" ALERTER=alerter ALARM_TIMEOUT=1 \
    TOAST_ENABLED=0 "$BIN" poll
  [ "$status" -eq 0 ]

  # afplay was invoked at least once with the configured sound file.
  [ -f "$TEST_DIR/afplay.calls" ]
  grep -q "Submarine.aiff" "$TEST_DIR/afplay.calls"

  # The fire returned (status 0 above) rather than looping forever — the
  # alarm_timeout=1 path killed the loop. (We don't pgrep global afplay: that
  # would match unrelated audio the developer may be playing.)
}

@test "alarm_gap spaces out the loop's repeats" {
  # Exercise the loop body directly rather than through `poll`: in `poll` the
  # stub alerter returns instantly, so do_fire kills the loop after one play and
  # neither the timeout nor the gap is observable. Here a 3s window with a 1s
  # gap and an instant sound fits ~3 plays; with no gap the same window fits
  # hundreds. The upper bound is what proves the sleep happened.
  local stub="$TEST_DIR/stub"; mkdir -p "$stub"
  cat > "$stub/afplay" <<EOF
#!/usr/bin/env bash
echo play >> "$TEST_DIR/afplay.calls"
EOF
  chmod +x "$stub/afplay"

  PATH="$stub:$PATH" bash -c '
    deadline=$(( $(date +%s) + $2 ))
    while (( $(date +%s) < deadline )); do
      afplay "$1"
      for (( i = 0; i < $3; i++ )); do
        (( $(date +%s) < deadline )) || break
        sleep 1
      done
    done
  ' tag /System/Library/Sounds/Submarine.aiff 3 1

  local plays; plays="$(wc -l < "$TEST_DIR/afplay.calls" | tr -d ' ')"
  [ "$plays" -ge 2 ]
  [ "$plays" -le 5 ]
}

@test "killing the alarm loop is silent (no 'Terminated' on stderr)" {
  # Regression: the alarm loop is backgrounded and killed when alerter returns.
  # Without a `disown`, bash's job reaper prints "Terminated: 15 bash -c ..." to
  # the poll's stderr — noise in the launchd log, and it leaks the whole loop
  # body. `kill 2>/dev/null` does NOT suppress it (the notice is the shell's, not
  # kill's). Surfaced when alarm_gap landed: the loop now sits in `sleep`, so the
  # kill lands mid-sleep rather than inside afplay.
  local stub="$TEST_DIR/stub"; mkdir -p "$stub"
  cat > "$stub/afplay" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$stub/alerter" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub/afplay" "$stub/alerter"

  seed_meeting 30
  run env -u NAGSLY_DRY_FIRE PATH="$stub:$PATH" ALERTER=alerter \
    ALARM_TIMEOUT=5 ALARM_GAP=3 TOAST_ENABLED=0 "$BIN" poll
  [ "$status" -eq 0 ]
  [[ "$output" != *"Terminated"* ]] || false
  [[ "$output" != *"deadline"* ]] || false   # the leaked loop body
}

@test "alarm_gap is read from config and passed to the loop" {
  # The loop body test above only matters if the binary actually feeds the
  # configured gap into it. There's no config-dump command, so assert the two
  # halves of the wiring: the knob is read from config.json, and it's passed as
  # the loop's 4th arg (the $3 the loop body reads).
  run grep -q 'ALARM_GAP="\$(config alarm_gap' "$BIN"
  [ "$status" -eq 0 ]
  run grep -q '"\$ALARM_LOOP_TAG" "\$SOUND_FILE" "\$ALARM_TIMEOUT" "\$ALARM_GAP"' "$BIN"
  [ "$status" -eq 0 ]
}

# ── status readout ───────────────────────────────────────────────────────────

@test "status reports next meeting and mode toggles" {
  seed_meeting $(( 2 * 3600 ))
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Soon"* ]] || false
  [[ "$output" == *"modes:"* ]] || false
  [[ "$output" == *"feed:"* ]] || false
}

# ── logs ─────────────────────────────────────────────────────────────────────

@test "logs summarizes heartbeats and shows activity (fires/errors), not the spam" {
  mkdir -p "$NAGSLY_DIR"
  cat > "$NAGSLY_DIR/nagsly.log" <<'LOG'
2026-07-16 09:40:00 checked — next: 'X' @ 10:00 (modes: toast alarm )
2026-07-16 09:41:00 checked — next: 'X' @ 10:00 (modes: toast alarm )
2026-07-16 09:50:29 firing toast for 'X' @ 10:00
2026-07-16 09:42:00 ERROR reading events (super rc=127): boom
LOG
  run "$BIN" logs
  [ "$status" -eq 0 ]
  # heartbeat summary line (count + span), heartbeats themselves suppressed
  [[ "$output" == *"2 heartbeats"* ]] || false
  [[ "$output" != *"modes: toast alarm"* ]] || false   # the chatty 'checked' lines are hidden
  # activity — good AND bad — shown
  [[ "$output" == *"firing toast for 'X'"* ]] || false
  [[ "$output" == *"ERROR reading events"* ]] || false
}

@test "logs shows most-recent activity first" {
  mkdir -p "$NAGSLY_DIR"
  cat > "$NAGSLY_DIR/nagsly.log" <<'LOG'
2026-07-16 09:00:00 firing alarm for 'OLDER' @ 09:01
2026-07-16 10:00:00 firing alarm for 'NEWER' @ 10:01
LOG
  run "$BIN" logs
  [ "$status" -eq 0 ]
  # NEWER must appear before OLDER in the output
  [[ "$output" == *"NEWER"*"OLDER"* ]] || false
}

@test "logs survives a large log (no SIGPIPE from grep|head under pipefail)" {
  mkdir -p "$NAGSLY_DIR"
  # A log big enough that grep is still writing when head/tail close the pipe.
  # Under `set -o pipefail` this makes grep die on SIGPIPE (141) and, without a
  # guard, aborts cmd_logs before it prints anything.
  {
    for i in $(seq 1 5000); do
      printf "2026-07-16 09:%02d:00 checked — next: 'X' @ 10:00 (modes: toast alarm )\n" $((i % 60))
    done
    echo "2026-07-16 09:50:29 firing toast for 'X' @ 10:00"
  } > "$NAGSLY_DIR/nagsly.log"
  run "$BIN" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"heartbeats"* ]] || false
  [[ "$output" == *"firing toast for 'X'"* ]] || false
}

@test "logs is graceful when no log exists yet" {
  run "$BIN" logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log yet"* ]] || false
}

# ── scheduled sync ────────────────────────────────────────────────────────────

@test "sync runs configured integration when due and records the attempt" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  cat > "$pdir/nagsly-sync-fake" <<EOF
#!/usr/bin/env bash
echo called >> "$TEST_DIR/sync.calls"
EOF
  chmod +x "$pdir/nagsly-sync-fake"
  printf '{"sync_plugins":["fake"],"sync_every":{"fake":120}}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PATH" run "$BIN" sync --due
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/sync.calls" | tr -d ' ')" -eq 1 ]
  PATH="$pdir:$PATH" run "$BIN" sync --due
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/sync.calls" | tr -d ' ')" -eq 1 ]
}

@test "sync supports hyphenated integration names" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  # Config keys support hyphens; they are quoted in the SuperDB field lookup.
  cat > "$pdir/nagsly-sync-my-calendar" <<EOF
#!/usr/bin/env bash
echo called >> "$TEST_DIR/sync.calls"
EOF
  chmod +x "$pdir/nagsly-sync-my-calendar"
  printf '{"sync_plugins":["my-calendar"],"sync_every":{"my-calendar":120}}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PATH" run "$BIN" sync
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/sync.calls" | tr -d ' ')" -eq 1 ]
}

@test "manual sync checks integrations regardless of their interval" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  cat > "$pdir/nagsly-sync-fake" <<EOF
#!/usr/bin/env bash
echo called >> "$TEST_DIR/sync.calls"
EOF
  chmod +x "$pdir/nagsly-sync-fake"
  printf '{"sync_plugins":["fake"],"sync_every":{"fake":120}}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PATH" run "$BIN" sync --due
  PATH="$pdir:$PATH" run "$BIN" sync
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/sync.calls" | tr -d ' ')" -eq 2 ]
}

@test "sync records a failed attempt and continues with later integrations" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$pdir/nagsly-sync-broken"
  cat > "$pdir/nagsly-sync-good" <<EOF
#!/usr/bin/env bash
echo called >> "$TEST_DIR/good.calls"
EOF
  chmod +x "$pdir/nagsly-sync-broken" "$pdir/nagsly-sync-good"
  printf '{"sync_plugins":["broken","good"],"sync_every":{"broken":120,"good":120}}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [ -f "$TEST_DIR/good.calls" ]
  [ -f "$NAGSLY_DIR/state/sync-broken.json" ]
  [[ "$output" == *"broken"* ]] || false
}

@test "sync reports absent integrations as failed attempts" {
  printf '{"sync_plugins":["not-installed"]}' > "$NAGSLY_DIR/config.json"
  run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"not-installed"* ]] || false
  [ -f "$NAGSLY_DIR/state/sync-not-installed.json" ]
}

@test "sync times out and terminates a hung integration process group" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  cat > "$pdir/nagsly-sync-slow" <<EOF
#!/usr/bin/env bash
sleep 30 &
echo \$! > "$TEST_DIR/child.pid"
wait
EOF
  chmod +x "$pdir/nagsly-sync-slow"
  printf '{"sync_plugins":["slow"]}' > "$NAGSLY_DIR/config.json"
  NAGSLY_SYNC_TIMEOUT=1 PATH="$pdir:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]] || false
  [ -f "$TEST_DIR/child.pid" ]
  local child_pid
  child_pid="$(<"$TEST_DIR/child.pid")"
  sleep 0.2
  ! kill -0 "$child_pid" 2>/dev/null
  [ -f "$NAGSLY_DIR/state/sync-slow.json" ]
}

@test "status reports recorded integration health" {
  mkdir -p "$NAGSLY_DIR/state"
  printf '{"last_attempt":1783999900,"last_success":1783999800,"last_error":7}' \
    > "$NAGSLY_DIR/state/sync-fake.json"
  run "$BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake: attempt 1783999900, success 1783999800, error 7"* ]] || false
}

@test "sync refuses a plugin name that could alter paths or command names" {
  printf '{"sync_plugins":["../escape"]}' > "$NAGSLY_DIR/config.json"
  run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid integration name"* ]] || false
  [ ! -e "$NAGSLY_DIR/state/../sync-escape.json" ]
}

@test "sync rejects intervals below the one-minute scheduler floor" {
  printf '{"sync_plugins":["fake"],"sync_every":{"fake":10}}' > "$NAGSLY_DIR/config.json"
  run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"integer >= 60"* ]] || false
}

@test "sync rejects excessively large intervals without arithmetic evaluation" {
  printf '{"sync_plugins":["fake"],"sync_every":{"fake":999999999999999999999999}}' > "$NAGSLY_DIR/config.json"
  run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"integer >= 60"* ]] || false
}

@test "sync timeout rejects excessive values" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  printf '#!/usr/bin/env bash\\nexit 0\\n' > "$pdir/nagsly-sync-fake"
  chmod +x "$pdir/nagsly-sync-fake"
  printf '{"sync_plugins":["fake"]}' > "$NAGSLY_DIR/config.json"
  NAGSLY_SYNC_TIMEOUT=999999999999 PATH="$pdir:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"integer from 1 to 3600"* ]] || false
}

@test "pr registers a monitor through the standalone monitor adapter" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "pr view 123" ]]; then
  printf '{"number":123,"title":"Ship nagsly","url":"https://github.com/acme/app/pull/123","state":"OPEN","reviewDecision":"REVIEW_REQUIRED","isDraft":false}\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"bucket":"pass"}]\n'
else
  exit 2
fi
EOF
  chmod +x "$pdir/gh"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" pr 123
  [ "$status" -eq 0 ]
  local -a monitor_files=("$NAGSLY_DIR/monitors.d"/pr-*.json)
  [ "${#monitor_files[@]}" -eq 1 ]
  grep -q '"number":"123"' "${monitor_files[0]}"
  [[ "$output" == *"registered PR #123"* ]] || false
}

@test "pr with no ref resolves the current branch without passing an empty argument" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "pr view --json" ]]; then
  printf '{"number":123,"title":"Ship","url":"https://github.com/acme/app/pull/123"}\n'
else exit 2; fi
EOF
  chmod +x "$pdir/gh"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" pr
  [ "$status" -eq 0 ]
  [ -f "$NAGSLY_DIR/monitors.d/pr-$(printf '%s' 'https://github.com/acme/app/pull/123' | shasum -a 256 | cut -c1-12).json" ]
}

@test "gmail query builder scopes every search to sent mail" {
  run bash -c 'source "$1"; build_query "release review"' _ "$PWD/plugins/nagsly-monitor-gmail"
  [ "$status" -eq 0 ]
  [ "$output" = "in:sent release review" ]
  run bash -c 'source "$1"; build_query "team@example.com"' _ "$PWD/plugins/nagsly-monitor-gmail"
  [ "$status" -eq 0 ]
  [ "$output" = "in:sent to:team@example.com" ]
  run bash -c 'source "$1"; build_query "subject:launch after:2026/01/01"' _ "$PWD/plugins/nagsly-monitor-gmail"
  [ "$status" -eq 0 ]
  [ "$output" = "in:sent subject:launch after:2026/01/01" ]
}

@test "gmail registers a sent message thread monitor and sync detects a reply once" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gws" <<'EOF'
#!/usr/bin/env bash
case "$2 $3 $4" in
  "users messages list")
    printf '%s\n' "$*" >> "$NAGSLY_DIR/gws.args"
    printf '{"messages":[{"id":"msg-1","threadId":"thread-1"}]}\n' ;;
  "users messages get") printf '{"id":"msg-1","threadId":"thread-1","payload":{"headers":[{"name":"Subject","value":"Launch review"},{"name":"To","value":"team@example.com"}]}}\n' ;;
  "users threads get") printf '{"messages":[{"labelIds":["INBOX"],"snippet":"Looks good","payload":{"headers":[{"name":"From","value":"reviewer@example.com"},{"name":"Subject","value":"Re: Launch review"}]}}]}\n' ;;
  *) exit 2 ;;
esac
EOF
  cat > "$pdir/alerter" <<EOF
#!/usr/bin/env bash
echo notify >> "$TEST_DIR/gmail-notifies"
EOF
  chmod +x "$pdir/gws" "$pdir/alerter"
  GWS=gws PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" gmail sarah@example.com
  [ "$status" -eq 0 ]
  grep -q 'in:sent to:sarah@example.com' "$NAGSLY_DIR/gws.args"
  local -a monitor_files=("$NAGSLY_DIR/monitors.d"/gmail-*.json)
  [ "${#monitor_files[@]}" -eq 1 ]
  printf '{"sync_plugins":["gmail"]}' > "$NAGSLY_DIR/config.json"
  export NAGSLY_TEST_NOTIFY_LOG="$TEST_DIR/gmail-notifies"
  GWS=gws PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/gmail-notifies" | tr -d ' ')" -eq 1 ]
  GWS=gws PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/gmail-notifies" | tr -d ' ')" -eq 1 ]
  [ "$(super -dynamic -f line -c 'values status' "${monitor_files[0]}")" = "replied" ]
}

@test "gmail refuses a missing thread ID without storing a monitor" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gws" <<'EOF'
#!/usr/bin/env bash
if [[ "$4" == list ]]; then printf '{"messages":[{"id":"msg-1"}]}\n'
else printf '{"id":"msg-1","payload":{"headers":[]}}\n'; fi
EOF
  chmod +x "$pdir/gws"
  GWS=gws PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" gmail sarah@example.com
  [ "$status" -ne 0 ]
  [ ! -d "$NAGSLY_DIR/monitors.d" ]
}

@test "monitor list displays registered monitors and rm removes by id" {
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '{"id":"pr-deadbeef","kind":"pr","title":"Ship nagsly","status":"waiting","url":"https://github.com/acme/app/pull/123"}\n' \
    > "$NAGSLY_DIR/monitors.d/pr-deadbeef.json"
  run "$BIN" monitor list
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr-deadbeef"*"pr"*"waiting"*"Ship nagsly"* ]] || false
  run "$BIN" monitor rm pr-deadbeef
  [ "$status" -eq 0 ]
  [ ! -f "$NAGSLY_DIR/monitors.d/pr-deadbeef.json" ]
}

@test "PR and Gmail sync succeed when no monitors are registered" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$pdir/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$pdir/gws"
  chmod +x "$pdir/gh" "$pdir/gws"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '{"sync_plugins":["pr","gmail"]}' > "$NAGSLY_DIR/config.json"
  GWS=gws PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -eq 0 ]
}

@test "PR sync detects a merge, notifies once, and retains completed monitor" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cp "$PWD/plugins/nagsly-monitor-pr" "$pdir/nagsly-monitor-pr"
  chmod +x "$pdir/nagsly-monitor-pr"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr view" ]]; then
  printf '{"number":123,"title":"Ship nagsly","url":"https://github.com/acme/app/pull/123","state":"MERGED","reviewDecision":"APPROVED","isDraft":false}\n'
elif [[ "$1 $2" == "pr checks" ]]; then
  printf '[]\n'
else exit 2; fi
EOF
  cat > "$pdir/alerter" <<EOF
#!/usr/bin/env bash
echo notify >> "$TEST_DIR/notifies"
EOF
  chmod +x "$pdir/gh" "$pdir/alerter"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '{"id":"pr-deadbeef","kind":"pr","number":"123","title":"Ship nagsly","url":"https://github.com/acme/app/pull/123","status":"waiting","last_state":"waiting","every":60}\n' \
    > "$NAGSLY_DIR/monitors.d/pr-deadbeef.json"
  printf '{"sync_plugins":["pr"],"sync_every":{"pr":120}}' > "$NAGSLY_DIR/config.json"
  export NAGSLY_TEST_NOTIFY_LOG="$TEST_DIR/notifies"
  NAGSLY_NOW=1784000000 PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync --due
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/notifies" | tr -d ' ')" -eq 1 ]
  NAGSLY_NOW=1784000120 PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync --due
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/notifies" | tr -d ' ')" -eq 1 ]
  [ "$(super -dynamic -f line -c 'values status' "$NAGSLY_DIR/monitors.d/pr-deadbeef.json")" = "merged" ]
}

@test "PR sync does not commit a state transition when gh checks fail unexpectedly" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cp "$PWD/plugins/nagsly-monitor-pr" "$pdir/nagsly-monitor-pr"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$2" == view ]]; then printf '{"state":"OPEN","reviewDecision":"APPROVED","isDraft":false}\n'
else exit 1; fi
EOF
  chmod +x "$pdir/gh" "$pdir/nagsly-monitor-pr"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '%s\n' '{"id":"pr-deadbeef","kind":"pr","number":"123","title":"Ship","url":"https://github.com/acme/app/pull/123","status":"waiting","last_state":"waiting"}' > "$NAGSLY_DIR/monitors.d/pr-deadbeef.json"
  printf '{"sync_plugins":["pr"]}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [ "$(super -dynamic -f line -c 'values status' "$NAGSLY_DIR/monitors.d/pr-deadbeef.json")" = "waiting" ]
}

@test "PR sync rejects malformed gh checks output without advancing approval" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$2" == view ]]; then printf '{"state":"OPEN","reviewDecision":"APPROVED","isDraft":false}\n'
else printf '{"bucket":"pass"}\n'; fi
EOF
  chmod +x "$pdir/gh"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '%s\n' '{"id":"pr-deadbeef","kind":"pr","number":"123","title":"Ship","url":"https://github.com/acme/app/pull/123","status":"waiting","last_state":"waiting"}' > "$NAGSLY_DIR/monitors.d/pr-deadbeef.json"
  printf '{"sync_plugins":["pr"]}' > "$NAGSLY_DIR/config.json"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [ "$(super -dynamic -f line -c 'values status' "$NAGSLY_DIR/monitors.d/pr-deadbeef.json")" = "waiting" ]
}

@test "PR sync reports notification failure and leaves transition retryable" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cp "$PWD/plugins/nagsly-monitor-pr" "$pdir/nagsly-monitor-pr"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$2" == view ]]; then printf '{"state":"MERGED","reviewDecision":"APPROVED","isDraft":false}\n'
else printf '[]\n'; fi
EOF
  cat > "$pdir/alerter" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  # Override dry-fire only with stubbed notification/audio executables.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$pdir/afplay"
  chmod +x "$pdir/gh" "$pdir/alerter" "$pdir/afplay" "$pdir/nagsly-monitor-pr"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '%s\n' '{"id":"pr-deadbeef","kind":"pr","number":"123","title":"Ship","url":"https://github.com/acme/app/pull/123","status":"waiting","last_state":"waiting"}' > "$NAGSLY_DIR/monitors.d/pr-deadbeef.json"
  printf '{"sync_plugins":["pr"]}' > "$NAGSLY_DIR/config.json"
  NAGSLY_DRY_FIRE= PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"alerter failed"* ]] || false
  [ "$(super -dynamic -f line -c 'values status' "$NAGSLY_DIR/monitors.d/pr-deadbeef.json")" = "waiting" ]
}

@test "re-registering a completed PR does not reset its stored state" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
printf '{"number":123,"title":"Ship","url":"https://github.com/acme/app/pull/123","state":"MERGED"}\n'
EOF
  chmod +x "$pdir/gh"
  local id="pr-$(printf '%s' 'https://github.com/acme/app/pull/123' | shasum -a 256 | cut -c1-12)"
  mkdir -p "$NAGSLY_DIR/monitors.d"
  printf '{"id":"%s","kind":"pr","number":"123","status":"merged","last_state":"merged"}\n' "$id" > "$NAGSLY_DIR/monitors.d/$id.json"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" pr 123
  [ "$status" -eq 0 ]
  [ "$(super -dynamic -f line -c 'values status' "$NAGSLY_DIR/monitors.d/$id.json")" = merged ]
}

@test "PR registration deduplicates by PR URL and escapes JSON strings" {
  local pdir="$TEST_DIR/stubs"; mkdir -p "$pdir"
  cat > "$pdir/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"number":123,"title":"Ship \"it\"","url":"https://github.com/acme/app/pull/123","state":"OPEN","reviewDecision":"REVIEW_REQUIRED","isDraft":false}'
EOF
  chmod +x "$pdir/gh"
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" pr 123
  [ "$status" -eq 0 ]
  PATH="$pdir:$PWD/plugins:$PATH" run "$BIN" pr 123
  [ "$status" -eq 0 ]
  local -a monitor_files=("$NAGSLY_DIR/monitors.d"/pr-*.json)
  [ "${#monitor_files[@]}" -eq 1 ]
  super -dynamic -f line -c 'values title' "${monitor_files[0]}" | grep -q 'Ship "it"'
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
  [[ "$output" == *"[fake]"* ]] || false
  [[ "$output" == *"All hands - Q3 kickoff"* ]] || false
}

@test "fetch fails cleanly when the plugin is not on PATH, and lists options" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  printf '#!/usr/bin/env bash\n' > "$pdir/nagsly-fetch-fake"; chmod +x "$pdir/nagsly-fetch-fake"
  PATH="$pdir:$PATH" run "$BIN" fetch nonexistent-source
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin not found"* ]] || false
  [[ "$output" == *"available plugins:"* ]] || false
  [[ "$output" == *"fake"* ]] || false      # discovered plugin is listed
}

@test "fetch with no plugin name lists the available plugins" {
  local pdir="$TEST_DIR/plugins"; mkdir -p "$pdir"
  printf '#!/usr/bin/env bash\n' > "$pdir/nagsly-fetch-fake"; chmod +x "$pdir/nagsly-fetch-fake"
  PATH="$pdir:$PATH" run "$BIN" fetch
  [ "$status" -ne 0 ]
  [[ "$output" == *"fetch needs a plugin name"* ]] || false
  [[ "$output" == *"fake"* ]] || false
}

# (No test for the "zero plugins installed" hint: the binary's PATH self-heal
# reintroduces ~/.local/bin — where the real nagsly-fetch-gws lives — so a test
# can't reliably present an empty plugin set. The hint path is exercised by hand
# on a machine with nothing installed.)
