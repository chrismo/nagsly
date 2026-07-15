#!/usr/bin/env bats
#
# Test suite for bin/meeting-alarm-build-events.sh — the deterministic
# transform from raw Google Calendar MCP JSON to the flat events file.
#
# Uses a fixed MEETING_ALARM_NOW and TZ so epoch conversion and HH:MM
# rendering are deterministic regardless of the host clock/timezone.

BUILD_BIN="$BATS_TEST_DIRNAME/../bin/meeting-alarm-build-events.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/meeting-alarm/events-raw.json"

setup() {
  TEST_DIR="$(mktemp -d "$TMPDIR/meeting-alarm-test.XXXXXX")"
  OUT="$TEST_DIR/events"
  # 2026-07-13 22:33 CDT — before the earliest surviving meeting (07-14 15:30).
  export MEETING_ALARM_NOW=1784000000
  export TZ=America/Chicago
}

teardown() {
  rm -rf "$TEST_DIR"
}

run_build() {
  run bash "$BUILD_BIN" "$FIXTURE" "$OUT"
}

@test "keeps exactly the four real meetings" {
  run_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 4 ]
}

@test "output is epoch-sorted ascending" {
  run_build
  run cut -f1 "$OUT"
  [ "${lines[0]}" = "1784061000" ]   # Eng managers chat, 07-14 15:30
  [ "${lines[1]}" = "1784127600" ]   # Engineering Forum,  07-15 10:00
  [ "${lines[2]}" = "1784134800" ]   # Change Management,  07-15 12:00
  [ "${lines[3]}" = "1784214000" ]   # All hands,          07-16 10:00
}

@test "renders HH:MM in local time and carries the title" {
  run_build
  run cat "$OUT"
  [ "${lines[0]}" = $'1784061000\t15:30\tEng managers chat' ]
  [ "${lines[1]}" = $'1784127600\t10:00\tEngineering Forum' ]
  [ "${lines[2]}" = $'1784134800\t12:00\tChange Management' ]
  [ "${lines[3]}" = $'1784214000\t10:00\tAll hands - Q3 kickoff' ]
}

@test "keeps a company all-hands whose attendee list is truncated to just self" {
  # Google truncates large invites (guestsCanSeeGuests:false) so only 'self'
  # appears in attendees. It is NOT a solo hold because someone else organizes
  # it — a genuine solo hold has organizer.self == true.
  run_build
  grep -q "All hands - Q3 kickoff" "$OUT"
}

@test "drops declined, all-day, focus, solo, cancelled, and past events" {
  run_build
  run cat "$OUT"
  ! grep -q "declined" "$OUT"
  ! grep -q "all-day" "$OUT"
  ! grep -q "Focus block" "$OUT"
  ! grep -q "Solo hold" "$OUT"
  ! grep -q "Cancelled" "$OUT"
  ! grep -q "Way in the past" "$OUT"
}

@test "advancing now past a meeting drops it" {
  # now = 2026-07-15 11:00 CDT: after Eng Forum (10:00) and Eng mgrs (07-14),
  # so Change Management (07-15 12:00) and All hands (07-16 10:00) survive.
  export MEETING_ALARM_NOW=1784131200
  run_build
  [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 2 ]
  run cut -f3 "$OUT"
  [ "${lines[0]}" = "Change Management" ]
  [ "${lines[1]}" = "All hands - Q3 kickoff" ]
}

@test "fails cleanly when raw json is missing" {
  run bash "$BUILD_BIN" "$TEST_DIR/nope.json" "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "empty events array yields empty output, exit 0" {
  echo '{"events":[]}' > "$TEST_DIR/empty.json"
  run bash "$BUILD_BIN" "$TEST_DIR/empty.json" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 0 ]
}

@test "non-numeric MEETING_ALARM_NOW falls back to real time instead of failing" {
  # A typo'd override must not fail-fast the transform (H4 guard). With real
  # 'now', the fixture's future 2026 meetings are all in the past, so we just
  # assert a clean exit 0 rather than a crash.
  MEETING_ALARM_NOW="not-a-number" run bash "$BUILD_BIN" "$FIXTURE" "$OUT"
  [ "$status" -eq 0 ]
}

# ── poller (bin/meeting-alarm.sh) — arm-window + dry-run ─────────────────────

POLL_BIN="$BATS_TEST_DIRNAME/../bin/meeting-alarm.sh"

# Write an events file with one meeting `secs` seconds after MEETING_ALARM_NOW,
# into an isolated config dir, and point the poller at it.
poll_setup() {
  local secs="$1"
  export MEETING_ALARM_DIR="$TEST_DIR/cfg"
  mkdir -p "$MEETING_ALARM_DIR"
  local mtg=$(( MEETING_ALARM_NOW + secs ))
  printf '%s\t%s\t%s\n' "$mtg" "09:59" "Test meeting" > "$MEETING_ALARM_DIR/events"
}

@test "dry-run arms nothing when meeting is far beyond the arm window" {
  # Meeting 17h out: with default TOAST_LEAD=600 the toast fire is ~16.8h away,
  # far past ARM_WINDOW=360 — so nothing should arm.
  poll_setup $(( 17 * 3600 ))
  run bash "$POLL_BIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD arm"* ]]
  [[ "$output" == *"Test meeting"* ]]   # still reports it as next
}

@test "dry-run arms alarm once meeting enters the arm window" {
  # Meeting 90s out: alarm fire_at = T-60s = 30s away, within ARM_WINDOW.
  poll_setup 90
  run bash "$POLL_BIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD arm alarm"* ]]
}

@test "status reports next meeting and mode toggles" {
  poll_setup $(( 2 * 3600 ))
  run bash "$POLL_BIN" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Test meeting"* ]]
  [[ "$output" == *"modes:"* ]]
}
