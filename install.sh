#!/usr/bin/env bash
#
# nagsly installer.
#
#   1. Copy the binary + plugins to a real local exec path (~/.local/bin).
#   2. Materialize the launchd plist from the .template ($HOME + label
#      substituted) into ~/Library/LaunchAgents, then bootstrap it.
#   3. Seed ~/.config/nagsly/config.json from the example (never overwriting an
#      existing one).
#
# COPY, not symlink: this repo lives at ~/dev/nagsly (real local disk), so a
# symlink would technically work — but a copy means the installed tool is
# independent of the repo path, and if the repo ever moved under CloudStorage a
# symlink target there would break launchd exec. A copy is the safe default.
#
# Usage:
#   ./install.sh              # install/refresh + (re)load the launchd agent
#   ./install.sh --uninstall  # bootout the agent + remove installed files

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.chrismo.nagsly"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/nagsly"
PLIST_SRC="$REPO_DIR/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_="$(id -u)"

info() { printf 'nagsly install: %s\n' "$*"; }
die()  { printf 'nagsly install: %s\n' "$*" >&2; exit 1; }

# --- uninstall ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST" "$BIN_DIR/nagsly"
  rm -f "$BIN_DIR"/nagsly-fetch-*
  info "uninstalled (config + events left intact at $CONFIG_DIR)"
  exit 0
fi

# --- guard: never run from under CloudStorage --------------------------------
case "$REPO_DIR" in
  *"/Library/CloudStorage/"*)
    die "this repo is under ~/Library/CloudStorage — launchd cannot exec there. Move it to ~/dev/nagsly." ;;
esac

# --- 1. copy binary + plugins ------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO_DIR/bin/nagsly" "$BIN_DIR/nagsly"
info "installed nagsly -> $BIN_DIR/nagsly"

shopt -s nullglob
for p in "$REPO_DIR"/plugins/nagsly-fetch-*; do
  install -m 0755 "$p" "$BIN_DIR/$(basename "$p")"
  info "installed plugin -> $BIN_DIR/$(basename "$p")"
done
shopt -u nullglob

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) info "NOTE: $BIN_DIR is not on your PATH — add it to run \`nagsly\` directly." ;;
esac

# --- 2. seed config (never clobber an existing one) --------------------------
mkdir -p "$CONFIG_DIR/events.d" "$CONFIG_DIR/state"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  info "config exists, left as-is: $CONFIG_DIR/config.json"
else
  cp "$REPO_DIR/config.example.json" "$CONFIG_DIR/config.json"
  info "seeded config -> $CONFIG_DIR/config.json"
fi

# --- 3. materialize + (re)load the launchd agent -----------------------------
[[ -f "$PLIST_SRC" ]] || die "plist template missing: $PLIST_SRC"
mkdir -p "$(dirname "$PLIST_DST")"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
info "wrote launchd plist -> $PLIST_DST"

# Reload: bootout any existing instance, then bootstrap the fresh one. Query the
# explicit gui/<uid> domain (not `launchctl list`, which reflects the caller's
# session and misreports).
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST_DST"
launchctl enable "gui/$UID_/$LABEL" 2>/dev/null || true
info "loaded launchd agent $LABEL (polls every 60s + at load)"

# --- receipt -----------------------------------------------------------------
if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
  info "verified: agent is loaded."
else
  info "WARNING: agent did not verify as loaded — check Console/log."
fi
echo
info "next: run \`nagsly status\` to confirm, and populate a feed:"
info "  nagsly add \"Test meeting\" +2m      # manual event"
info "  nagsly fetch gws                    # after \`gws auth login\`"
