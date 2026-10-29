#!/bin/bash
# Installs (or with --uninstall removes) the LaunchAgent that runs
# voicedictate-ios-refresh Mon-Fri at 10:00, 10:30, 11:00 and 11:30 for one
# iPhone.
#
#   install-refresh-agent.sh --device <id>          install or reinstall
#   install-refresh-agent.sh --print --device <id>  print the rendered plist only
#   install-refresh-agent.sh --uninstall            remove the agent
#
# <id> is the Identifier column of `xcrun devicectl list devices`. The agent's
# label is <VOICEDICTATE_ID_PREFIX>.voicedictate.ios-refresh, with the prefix
# read from Local.xcconfig, so the agent, the app and the keyboard all carry
# your identifier.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TEMPLATE="$REPO/launchd/voicedictate-ios-refresh.plist"
CONFIG="$REPO/Local.xcconfig"
LOG="$HOME/Library/Logs/voice-dictate-ios-refresh.log"
DOMAIN="gui/$(id -u)"

usage() { echo "usage: $0 --device <id> | --print --device <id> | --uninstall" >&2; exit 64; }
die() { echo "$*" >&2; exit 1; }

MODE=install DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) [ $# -ge 2 ] || usage; DEVICE=$2; shift ;;
    --print) MODE=print ;;
    --uninstall) MODE=uninstall ;;
    *) usage ;;
  esac
  shift
done

# Last assignment wins, as in xcconfig.
[ -f "$CONFIG" ] || die "missing $CONFIG (copy Local.xcconfig.example and set VOICEDICTATE_ID_PREFIX)"
PREFIX=$(sed -n 's/^[[:space:]]*VOICEDICTATE_ID_PREFIX[[:space:]]*=[[:space:]]*\([A-Za-z0-9.-]*\).*/\1/p' "$CONFIG" | tail -n 1)
[ -n "$PREFIX" ] || die "set VOICEDICTATE_ID_PREFIX in $CONFIG"
LABEL="$PREFIX.voicedictate.ios-refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$MODE" != uninstall ]; then
  [ -n "$DEVICE" ] || usage
  case "$DEVICE" in *[!A-Za-z0-9-]*) die "device id may only contain letters, digits and '-': $DEVICE" ;; esac
fi

# XML-escape, then escape for the sed replacement.
subst() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\|&]/\\&/g'; }
render() {
  sed -e "s|VOICEDICTATE_LABEL_PLACEHOLDER|$(subst "$LABEL")|g" \
      -e "s|VOICEDICTATE_REPO_PLACEHOLDER|$(subst "$REPO")|g" \
      -e "s|VOICEDICTATE_DEVICE_PLACEHOLDER|$(subst "$DEVICE")|g" \
      -e "s|VOICEDICTATE_LOG_PLACEHOLDER|$(subst "$LOG")|g" "$TEMPLATE"
}

case "$MODE" in
  print)
    render
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL (state and log kept)"
    ;;
  install)
    # Login Items names the agent after this executable, so it must run directly.
    chmod +x "$REPO/scripts/voicedictate-ios-refresh"
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/$LABEL.XXXXXX")"
    render >"$tmp"
    plutil -lint -s "$tmp"
    mv -f "$tmp" "$PLIST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed $LABEL for device $DEVICE: runs Mon-Fri at 10:00, 10:30, 11:00 and 11:30, log $LOG"
    ;;
esac
