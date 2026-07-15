#!/usr/bin/env bash
#
# Deterministic transform: raw Google Calendar MCP JSON -> flat events file.
#
# A Claude session dumps `list_events` output verbatim to $RAW (default
# ~/.config/meeting-alarm/events-raw.json). This script applies ALL filtering,
# epoch conversion, and sorting with zero model judgment via a single SuperDB
# query, so the result is auditable and testable. See test/meeting-alarm.bats.
#
# SuperDB (not jq) is the query engine across the meeting/day tooling — this
# mirrors day-timeline's collect-*.sh pipelines. Pinned to 0.3.0 via
# ASDF_SUPERDB_VERSION (the runtime the 0.3.0 docs/idioms target).
#
# Output (atomic write to $OUT, default ~/.config/meeting-alarm/events):
#   <epoch_seconds>\t<HH:MM>\t<title>       one per line, sorted ascending
#
# Filters (drop the event if ANY is true):
#   - not a timed event      (no start.dateTime, i.e. all-day start.date)
#   - eventType != DEFAULT   (drops FOCUS_TIME / OUT_OF_OFFICE / WORKING_LOCATION / BIRTHDAY)
#   - status == cancelled
#   - self attendee responseStatus == declined
#   - solo self-event        (YOU organize it AND no other attendee listed) —
#                            NOT dropped for big invites where Google truncates
#                            the attendee list to just you (guestsCanSeeGuests
#                            false); those are organized by someone else, so
#                            organizer.self is absent/false.
#   - already started        (epoch <= now)
#
# Notes on the 0.3.0 idioms used (verified against real MCP payloads):
#   - `where is(start.dateTime, <string>)` is the field-presence test; a naive
#     `!= null` silently matches nothing, and this also drops all-day events
#     (which carry start.date, not start.dateTime).
#   - epoch seconds = cast(cast(<iso>, <time>), <int64>) / 1e9  (int64 = ns).
#   - local HH:MM is sliced straight from the ISO string [11:16]; the string's
#     own offset already encodes local time, so no tz/DST math is needed.
#   - `[unnest attendees | where ...]` is the per-record array subquery.
#   - output via native `-f tsv -noheader` (string `+` concat is unsupported).
#
# Usage: meeting-alarm-build-events.sh [raw_json_path] [out_path]

set -euo pipefail

export ASDF_SUPERDB_VERSION="${ASDF_SUPERDB_VERSION:-0.3.0}"

CONFIG_DIR="${MEETING_ALARM_DIR:-$HOME/.config/meeting-alarm}"
RAW="${1:-$CONFIG_DIR/events-raw.json}"
OUT="${2:-$CONFIG_DIR/events}"

if [[ ! -f "$RAW" ]]; then
  echo "meeting-alarm-build-events: raw JSON not found: $RAW" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

now="${MEETING_ALARM_NOW:-$(date +%s)}"   # override for deterministic tests
[[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"   # guard non-numeric override/typo

# Query stages (SPQ has no line-comment syntax, so the narrative lives here):
#   1. unnest events                     — one record per event
#   2. is(start.dateTime,<string>)       — timed only; drops all-day (start.date)
#   3. eventType == DEFAULT              — drops focus/OOO/working-loc/birthday
#   4. status != cancelled
#   5. _selfDeclined                     — drop if my own attendee row is declined
#   6. _others / organizer.self          — drop solo holds; keep big invites
#   7. epoch > NOW                       — drop already-started
#   8. sort epoch                        — ascending, for the poller
# -dynamic: defer field resolution to runtime. Required because the event
# records are heterogeneous (some lack attendees/organizer) and an empty
# events:[] would otherwise fail static type-checking on missing fields.
super -dynamic -f tsv -noheader -c '
  const NOW = '"$now"'
  unnest events
  | where is(start.dateTime, <string>)
  | where coalesce(eventType, "DEFAULT") == "DEFAULT"
  | where coalesce(status, "confirmed") != "cancelled"
  | put _selfDeclined := len([unnest coalesce(attendees, []) | where coalesce(self, false) and responseStatus == "declined"]) > 0
  | where not _selfDeclined
  | put _others := len([unnest coalesce(attendees, []) | where not coalesce(self, false)])
  | where not (coalesce(organizer.self, false) and _others == 0)
  | put epoch := cast(cast(start.dateTime, <time>), <int64>) / 1000000000
  | where epoch > NOW
  | values {epoch, hhmm: start.dateTime[11:16], summary: coalesce(summary, "(no title)")}
  | sort epoch
' "$RAW" > "$OUT.tmp"

mv -f "$OUT.tmp" "$OUT"

count="$(wc -l < "$OUT" | tr -d ' ')"
echo "meeting-alarm-build-events: wrote $count upcoming meeting(s) to $OUT"
