#!/usr/bin/env bash
#
# Meeting-alarm fire — spawned detached by the poller (meeting-alarm.sh).
#
# Sleeps until the exact target epoch (second-accurate; a plain sleep, NOT
# launchd's minute-granular scheduler), then fires one of two modes:
#   toast  — a single quiet alerter notification (no sound). Liveness signal.
#   alarm  — a continuous afplay loop + non-blocking alerter with a Stop action
#            + a safety auto-timeout so a stuck alarm can't run forever.
#
# Clears its state file on completion so the poller's re-arm stays idempotent.
#
# Usage: meeting-alarm-fire.sh <toast|alarm> <fire_epoch> <title> <hhmm> [state_file]

set -euo pipefail

mode="${1:?mode required (toast|alarm)}"
fire_epoch="${2:?fire epoch required}"
title="${3:-meeting}"
hhmm="${4:-}"
state_file="${5:-}"

CONFIG_DIR="${MEETING_ALARM_DIR:-$HOME/.config/meeting-alarm}"
CONFIG_FILE="$CONFIG_DIR/config"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SOUND_FILE="${SOUND_FILE:-/System/Library/Sounds/Sosumi.aiff}"
ALARM_TIMEOUT="${ALARM_TIMEOUT:-90}"     # seconds; hard stop for the loop
ALERTER="${ALERTER:-alerter}"

cleanup() { [[ -n "$state_file" && -f "$state_file" ]] && rm -f "$state_file"; return 0; }
trap cleanup EXIT

# --- sleep to the exact second ----------------------------------------------
now="$(date +%s)"
delay=$(( fire_epoch - now ))
if (( delay > 0 )); then
  sleep "$delay"
fi

# --- fire --------------------------------------------------------------------
case "$mode" in
  toast)
    "$ALERTER" \
      --title "⏰ meeting-alarm live" \
      --subtitle "$title" \
      --message "Coming up at ${hhmm}" \
      --timeout 15 >/dev/null 2>&1 || true
    ;;

  alarm)
    # Continuous loop in the background; capture its PID so the auto-timeout
    # and the Stop action can kill THIS loop specifically. disown so the
    # shell doesn't print a "Terminated" job message when we kill it.
    ( while :; do afplay "$SOUND_FILE"; done ) &
    loop_pid=$!
    disown "$loop_pid" 2>/dev/null || true

    # Safety auto-timeout: stop the loop after ALARM_TIMEOUT even if never
    # dismissed. Runs detached so it doesn't block the notification.
    ( sleep "$ALARM_TIMEOUT"; kill "$loop_pid" 2>/dev/null; killall afplay 2>/dev/null ) &
    timeout_pid=$!

    # Non-blocking (well, alerter blocks until action/close/timeout — that's
    # fine here because we're already a detached process). Clicking Stop or
    # letting it time out both lead to killing the loop.
    "$ALERTER" \
      --title "⏰ MEETING NOW" \
      --subtitle "$title" \
      --message "Starts ${hhmm} — click Stop to silence" \
      --close-label "Stop" \
      --timeout "$ALARM_TIMEOUT" >/dev/null 2>&1 || true

    kill "$loop_pid" 2>/dev/null || true
    kill "$timeout_pid" 2>/dev/null || true
    killall afplay 2>/dev/null || true
    ;;

  *)
    echo "meeting-alarm-fire: unknown mode '$mode'" >&2
    exit 2
    ;;
esac
