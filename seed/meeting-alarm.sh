#!/usr/bin/env bash
#
# Meeting-alarm poller — the single launchd-managed process.
#
# Reads the flat events file (built by a Claude session via
# meeting-alarm-build-events.sh) and, for the next upcoming meeting, ensures a
# precise one-shot is armed for each enabled mode:
#   - toast  at TOAST_LEAD  (default T-10m): quiet alerter, liveness signal
#   - alarm  at ALARM_LEAD  (default T-60s): continuous afplay loop
#
# The poller does ZERO calendar access. It never fires the alarm itself; it
# spawns meeting-alarm-fire.sh detached, which sleeps to the exact second and
# fires. Re-arming an already-armed (mode,epoch) is a no-op (state file). This
# is why poll granularity never affects firing precision.
#
# Usage:
#   meeting-alarm.sh              # normal poll (used by launchd)
#   meeting-alarm.sh --dry-run    # print what it WOULD arm, arm nothing
#   meeting-alarm.sh --status     # read-only overview: alive? feed? next? armed?
#
# Config: ~/.config/meeting-alarm/config (sourced if present). See config.example.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRE="$DIR/meeting-alarm-fire.sh"

CONFIG_DIR="${MEETING_ALARM_DIR:-$HOME/.config/meeting-alarm}"
CONFIG_FILE="$CONFIG_DIR/config"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

EVENTS_FILE="${EVENTS_FILE:-$CONFIG_DIR/events}"
STATE_DIR="${STATE_DIR:-$CONFIG_DIR/state}"
LOG_FILE="${LOG_FILE:-$CONFIG_DIR/meeting-alarm.log}"

TOAST_LEAD="${TOAST_LEAD:-600}"      # 10 min
ALARM_LEAD="${ALARM_LEAD:-60}"       # 1 min
TOAST_ENABLED="${TOAST_ENABLED:-1}"
ALARM_ENABLED="${ALARM_ENABLED:-1}"
# Don't arm a fire until it's within this many seconds of firing. Bounds long
# sleeps and shrinks the reschedule/cancel exposure window. Must exceed the
# launchd poll interval (300s) so no fire is skipped between polls; 360s = one
# poll of slack.
ARM_WINDOW="${ARM_WINDOW:-360}"

DRY_RUN=0
MODE="${1:-}"
[[ "$MODE" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE_DIR"

now="${MEETING_ALARM_NOW:-$(date +%s)}"
# Guard: a non-numeric override/config typo must not fail-fast every poll
# (e.g. via `date -r "$now"` in log()). Fall back to real time.
[[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"

log() { printf '%s %s\n' "$(date -r "$now" '+%F %T')" "$*" >> "$LOG_FILE"; }

# Humanize a positive second count as a compact age/eta ("3m", "4h", "2d").
humanize() {
  local s="$1"
  if   (( s < 90 ));    then echo "${s}s"
  elif (( s < 5400 ));  then echo "$(( (s + 30) / 60 ))m"
  elif (( s < 172800 ));then echo "$(( (s + 1800) / 3600 ))h"
  else                       echo "$(( (s + 43200) / 86400 ))d"
  fi
}

# --- read-only status overview ----------------------------------------------
if [[ "$MODE" == "--status" ]]; then
  echo "meeting-alarm status"

  # poller: is the launchd agent loaded, and how fresh is the heartbeat?
  # Query the explicit gui/<uid> domain, NOT `launchctl list` — the legacy list
  # reflects the CALLER's bootstrap session, so a script spawned outside the
  # login session sees an empty/different domain and false-reports "not loaded".
  if launchctl print "gui/$(id -u)/com.chrismo.meeting-alarm" >/dev/null 2>&1; then
    loaded="loaded (launchd)"
  else
    loaded="NOT loaded — run ./install.sh"
  fi
  if [[ -f "$LOG_FILE" ]]; then
    hb_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$(tail -n 1 "$LOG_FILE" | cut -d' ' -f1-2)" "+%s" 2>/dev/null || echo "")"
    if [[ -n "$hb_epoch" ]]; then
      hb="last heartbeat $(humanize $(( now - hb_epoch ))) ago"
    else
      hb="heartbeat log unreadable"
    fi
  else
    hb="no heartbeat log yet"
  fi
  echo "  poller: $loaded, $hb"

  # feed: how many meetings, and how stale is the events file?
  if [[ -f "$EVENTS_FILE" ]]; then
    fcount="$(grep -c . "$EVENTS_FILE" 2>/dev/null || echo 0)"
    fmtime="$(stat -f %m "$EVENTS_FILE" 2>/dev/null || echo "$now")"
    echo "  feed:   $fcount meeting(s), refreshed $(humanize $(( now - fmtime ))) ago  ($EVENTS_FILE)"
  else
    echo "  feed:   MISSING — run /ds:meeting-alarm-refresh"
  fi

  # next upcoming meeting
  nxt=""
  if [[ -f "$EVENTS_FILE" ]]; then
    while IFS=$'\t' read -r e h t; do
      [[ -z "$e" ]] && continue
      if (( e > now )); then nxt="$e"$'\t'"$h"$'\t'"$t"; break; fi
    done < "$EVENTS_FILE"
  fi
  if [[ -n "$nxt" ]]; then
    IFS=$'\t' read -r ne nh nt <<< "$nxt"
    echo "  next:   '$nt' @ $nh (in $(humanize $(( ne - now ))))"
  else
    echo "  next:   (none upcoming)"
  fi

  # currently-armed fires (sleeping fire processes)
  shopt -s nullglob
  armed=("$STATE_DIR"/arm-*)
  shopt -u nullglob
  if (( ${#armed[@]} > 0 )); then
    echo "  armed:  ${#armed[@]} fire(s) pending:"
    for a in "${armed[@]}"; do
      IFS=$'\t' read -r _ae ah at < "$a"
      echo "            $(basename "$a" | sed -E 's/^arm-([a-z]+)-.*/\1/') → '$at' @ $ah"
    done
  else
    echo "  armed:  (none — fires arm only within their lead window)"
  fi

  # mode toggles
  t_on=$([[ "$TOAST_ENABLED" == "1" ]] && echo "on" || echo "off")
  a_on=$([[ "$ALARM_ENABLED" == "1" ]] && echo "on" || echo "off")
  echo "  modes:  toast $t_on (T-$(humanize "$TOAST_LEAD"))   alarm $a_on (T-$(humanize "$ALARM_LEAD"))"
  exit 0
fi

# --- find the next upcoming meeting (first line with epoch > now) ------------
next_line=""
if [[ -f "$EVENTS_FILE" ]]; then
  while IFS=$'\t' read -r epoch hhmm title; do
    [[ -z "$epoch" ]] && continue
    if (( epoch > now )); then
      next_line="$epoch"$'\t'"$hhmm"$'\t'"$title"
      break
    fi
  done < "$EVENTS_FILE"
fi

if [[ -z "$next_line" ]]; then
  log "checked — no upcoming meetings in $EVENTS_FILE"
  [[ $DRY_RUN -eq 1 ]] && echo "no upcoming meetings"
  exit 0
fi

IFS=$'\t' read -r n_epoch n_hhmm n_title <<< "$next_line"

# --- arm one mode: spawn fire script detached, idempotent via state file -----
arm_mode() {
  local mode="$1" lead="$2"
  local fire_at=$(( n_epoch - lead ))
  local state="$STATE_DIR/arm-${mode}-${n_epoch}"

  # Already past the fire time for this mode? Nothing to do (we missed the window
  # or it's a mode whose lead already elapsed) — don't fire late.
  if (( fire_at <= now )); then
    return 0
  fi

  # Not yet within the arm window? Wait for a later poll. This avoids arming a
  # fire (and holding a sleeping process) hours early, and shrinks the
  # reschedule/cancel exposure to ~ARM_WINDOW.
  if (( fire_at - now > ARM_WINDOW )); then
    return 0
  fi

  if [[ -f "$state" ]]; then
    return 0   # already armed for this (mode, meeting) — idempotent no-op
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "WOULD arm $mode for '$n_title' @ $n_hhmm — fire at $(date -r "$fire_at" '+%T') (lead ${lead}s)"
    return 0
  fi

  # Record the arm BEFORE spawning so a crash mid-spawn doesn't double-arm on
  # the next poll; the fire script clears it when done.
  printf '%s\t%s\t%s\n' "$n_epoch" "$n_hhmm" "$n_title" > "$state"
  nohup "$FIRE" "$mode" "$fire_at" "$n_title" "$n_hhmm" "$state" >/dev/null 2>&1 &
  log "armed $mode for '$n_title' @ $n_hhmm — fire at $(date -r "$fire_at" '+%T')"
}

armed_note=""
if [[ "$TOAST_ENABLED" == "1" ]]; then arm_mode toast "$TOAST_LEAD"; armed_note+="toast "; fi
if [[ "$ALARM_ENABLED" == "1" ]]; then arm_mode alarm "$ALARM_LEAD"; armed_note+="alarm "; fi

log "checked — next: '$n_title' @ $n_hhmm (modes: ${armed_note:-none})"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "next: '$n_title' @ $n_hhmm (epoch $n_epoch)"
fi
