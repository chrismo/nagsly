#!/usr/bin/env bash
#
# Dismiss a firing meeting-alarm. Bind to a hotkey (Raycast/Alfred/Shortcuts)
# for one-touch silence, or run from a terminal.
#
# Kills both the looping fire process AND the current afplay, so the loop
# can't immediately respawn afplay. Safe to run when nothing is firing.
#
# Note: `pkill -f 'meeting-alarm-fire.sh alarm'` matches the afplay-loop
# subshell too (a subshell inherits the parent's argv), so this kills the whole
# fire tree, not just the top process — verified. `killall afplay` then clears
# any in-flight playback.

set -uo pipefail

# Stop the alarm-mode fire loop(s) first so they don't respawn afplay.
pkill -f 'meeting-alarm-fire.sh alarm' 2>/dev/null || true
# Then silence any in-flight playback.
killall afplay 2>/dev/null || true

echo "meeting-alarm: silenced."
