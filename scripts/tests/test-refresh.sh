#!/bin/bash
# Tests for voicedictate-ios-refresh and its LaunchAgent. Every external tool
# (xcrun/devicectl, xcodebuild, xcodegen, git, security, osascript) is a stub
# on PATH, HOME is a temp dir, and the script itself refuses to run when a
# tool doesn't resolve to a stub: nothing here reaches the phone or Apple.
#   bash scripts/tests/test-refresh.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
REFRESH="$SCRIPTS/voicedictate-ios-refresh"
PASS=0 FAIL=0

eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     expected: $2"; echo "     actual:   $3"; fi
}
has() { # <name> <needle> <haystack>
  case "$3" in *"$2"*) PASS=$((PASS + 1)); echo "ok   $1" ;;
  *) FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     missing: $2"; echo "     in: $3" ;; esac
}
lacks() { # <name> <needle> <haystack>
  case "$3" in *"$2"*) FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     unexpected: $2" ;;
  *) PASS=$((PASS + 1)); echo "ok   $1" ;; esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vd-refresh-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export TZ=UTC
ep() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }

# ---- decision logic (sourced) -----------------------------------------------
# With the script's own thresholds and window, not the library defaults.
SETTINGS="$(grep -E '^(REFRESH_WITHIN_HOURS|MIN_FRESH_HOURS|WINDOW_[A-Z_]+)=' "$REFRESH")"
(
  eval "$SETTINGS"
  # shellcheck source=../refresh-lib.sh
  . "$SCRIPTS/refresh-lib.sh"
  N10=$(ep 2026-10-28T10:00:00Z)  # Wednesday, inside the window
  N14=$(ep 2026-10-28T14:00:00Z)  # Wednesday afternoon
  H=3600
  eq "settings: refresh within 100h"             100     "$REFRESH_WITHIN_HOURS"
  eq "settings: window text"                     "Mon-Fri 10:00-12:00" "$(window_text)"
  eq "decide: 5 days left -> skip"               skip    "$(decide "$N10" $((N10 + 120 * H)))"
  eq "decide: 100h+1s left -> skip"              skip    "$(decide "$N10" $((N10 + 100 * H + 1)))"
  eq "decide: 100h left in the window -> refresh" refresh "$(decide "$N10" $((N10 + 100 * H)))"
  eq "decide: 2 days left, afternoon -> wait"    wait    "$(decide "$N14" $((N14 + 48 * H)))"
  eq "decide: 2 days left, 10:00 -> refresh"     refresh "$(decide "$N10" $((N10 + 48 * H)))"
  eq "decide: 1h left, afternoon -> still wait"  wait    "$(decide "$N14" $((N14 + H)))"
  eq "decide: expired, afternoon -> still wait"  wait    "$(decide "$N14" $((N14 - H)))"
  eq "decide: expired, in the window -> refresh" refresh "$(decide "$N10" $((N10 - H)))"
  eq "decide: unknown expiry, afternoon -> wait" wait    "$(decide "$N14" "")"
  eq "decide: unknown expiry, window -> refresh" refresh "$(decide "$N10" "")"
  E=$(ep 2026-10-30T20:00:00Z)
  eq "decide: Wed 09:59:59 is outside"           wait    "$(decide $(ep 2026-10-28T09:59:59Z) "$E")"
  eq "decide: Wed 10:00 is inside"               refresh "$(decide $(ep 2026-10-28T10:00:00Z) "$E")"
  eq "decide: Wed 11:59:59 is inside"            refresh "$(decide $(ep 2026-10-28T11:59:59Z) "$E")"
  eq "decide: Wed 12:00 is outside"              wait    "$(decide $(ep 2026-10-28T12:00:00Z) "$E")"
  eq "decide: 01:30 at night is outside"         wait    "$(decide $(ep 2026-10-28T01:30:00Z) "$E")"
  eq "decide: Fri 11:30 is inside"               refresh "$(decide $(ep 2026-10-30T11:30:00Z) "$E")"
  E=$(ep 2026-11-03T20:00:00Z)
  eq "decide: Sat 10:30 is outside"              wait    "$(decide $(ep 2026-10-31T10:30:00Z) "$E")"
  eq "decide: Sun 11:00 is outside"              wait    "$(decide $(ep 2026-11-01T11:00:00Z) "$E")"
  eq "decide: Mon 10:00 is inside"               refresh "$(decide $(ep 2026-11-02T10:00:00Z) "$E")"
  # After a successful refresh the profile lasts >= MIN_FRESH_HOURS: the
  # day's later runs are no-ops.
  for t in 10:30 11:00 11:30; do
    eq "decide: $t after a 10:00 refresh -> skip" skip \
      "$(decide $(ep 2026-11-02T${t}:00Z) $(($(ep 2026-11-02T10:05:00Z) + MIN_FRESH_HOURS * H)))"
  done
  # Why not 96h: a profile made Mon 11:35 isn't due at Thursday's last run.
  E=$(( $(ep 2026-11-02T11:35:00Z) + 168 * H ))
  eq "decide: 100h covers Thu 10:00 for a Mon 11:35 profile" refresh "$(decide $(ep 2026-11-05T10:00:00Z) "$E")"
  eq "decide: 96h would miss Thu 11:30"          skip    "$(REFRESH_WITHIN_HOURS=96; decide $(ep 2026-11-05T11:30:00Z) "$E")"
  eq "local_time"                                "Sat 31 Oct 19:00" "$(local_time $(ep 2026-10-31T19:00:26Z))"
  eq "format_left"                               "2d 3h" "$(format_left $((51 * H + 59)))"
  eq "format_left: expired"                      "-0d 5h" "$(format_left $((-5 * H)))"
  eq "iso_to_epoch rejects junk"                 1 "$(iso_to_epoch nonsense >/dev/null; echo $?)"
  # device_reachable: `list devices` files and `device info details` files.
  J="$TMP/unit-json"; mkdir -p "$J"
  dev() { # <id> <pairing> <tunnel> <caps json>
    printf '{"identifier":"%s","hardwareProperties":{"udid":"UDID-%s"},"capabilities":%s,"connectionProperties":{"pairingState":"%s","tunnelState":"%s"}}' "$1" "$1" "$4" "$2" "$3"
  }
  INSTALLAPP='[{"featureIdentifier":"com.apple.coredevice.feature.installapp"}]'
  CONNECTONLY='[{"featureIdentifier":"com.apple.coredevice.feature.connectdevice"}]'
  r() { device_reachable "$J/$1" "${2:-D1}" && echo yes || echo no; }
  printf '{"result":{"devices":[%s,%s]}}' "$(dev D0 paired connected "$INSTALLAPP")" "$(dev D1 paired connected "[]")" >"$J/list-connected"
  printf '{"result":{"devices":[%s]}}' "$(dev D1 paired disconnected "$INSTALLAPP")" >"$J/list-available"
  printf '{"result":{"devices":[%s]}}' "$(dev D1 paired disconnected "$CONNECTONLY")" >"$J/list-idle"
  printf '{"result":{"devices":[%s]}}' "$(dev D1 unpaired connected "$INSTALLAPP")" >"$J/list-unpaired"
  printf '{"result":%s}' "$(dev D1 paired connected "$INSTALLAPP")" >"$J/details-connected"
  printf '{"result":%s}' "$(dev D1 paired disconnected "$CONNECTONLY")" >"$J/details-best-effort"
  printf '{"info":{"outcome":"failed"},"error":{"code":1,"userInfo":{}}}' >"$J/details-error"
  printf 'not json' >"$J/junk"
  eq "reachable: list, tunnel connected"         yes "$(r list-connected)"
  eq "reachable: list, by UDID"                  yes "$(r list-connected UDID-D1)"
  eq "reachable: list, other device only"        no  "$(r list-connected D9)"
  eq "reachable: list, installapp capability"    yes "$(r list-available)"
  eq "reachable: list, paired but idle (Fri 30 Oct)" no "$(r list-idle)"
  eq "reachable: list, unpaired"                 no  "$(r list-unpaired)"
  eq "reachable: details, connected"             yes "$(r details-connected)"
  eq "reachable: details, other device"          no  "$(r details-connected D9)"
  eq "reachable: details, best-effort stale info" no "$(r details-best-effort)"
  eq "reachable: details, error result"          no  "$(r details-error)"
  eq "reachable: junk"                           no  "$(r junk)"
  eq "reachable: missing file"                   no  "$(r missing)"
  l() { says_locked "$@" && echo yes || echo no; }
  echo 'ERROR: The developer disk image could not be mounted on this device. (kAMDMobileImageMounterDeviceLocked: The device is locked.)' >"$J/ddi-locked"
  echo 'ERROR: Unable to connect: The device is passcode protected.' >"$J/passcode"
  echo 'ERROR: Timed out waiting for the device to connect.' >"$J/timeout"
  eq "locked: DDI mount error"                   yes "$(l "$J/ddi-locked")"
  eq "locked: passcode protected"                yes "$(l "$J/passcode")"
  eq "locked: in the second file"                yes "$(l "$J/timeout" "$J/ddi-locked")"
  eq "locked: timeout is not a lock"             no  "$(l "$J/timeout")"
  eq "locked: missing files"                     no  "$(l "$J/missing" "$J/missing2")"
) | tee "$TMP/unit.out"
PASS=$((PASS + $(grep -c '^ok' "$TMP/unit.out"))); FAIL=$((FAIL + $(grep -c '^FAIL' "$TMP/unit.out")))

# ---- threshold sweep --------------------------------------------------------
# For every expiry time (hourly over two weeks, in Europe/Berlin time across the
# 2026-10-25 DST change), simulate the LaunchAgent's runs (Mon-Fri 10:00,
# 10:30, 11:00, 11:30) and count the days on which all four runs come before
# expiry and decide "refresh". Every expiry must get at least two such days.
(
  eval "$SETTINGS"
  . "$SCRIPTS/refresh-lib.sh"
  export TZ=Europe/Berlin
  RUNS=""
  for day in $(seq 0 27); do
    d=$(date -j -v+"${day}"d -f '%Y-%m-%d %H:%M:%S' '2026-10-12 00:00:00' '+%Y-%m-%d %u')
    case "${d#* }" in 6|7) continue ;; esac
    for t in 10:00 10:30 11:00 11:30; do
      RUNS="$RUNS ${d% *}=$(date -j -f '%Y-%m-%d %H:%M:%S' "${d% *} $t:00" +%s)"
    done
  done
  start=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-19 00:00:00' +%s)
  worst=99 worst_at=""
  for i in $(seq 0 $((14 * 24 - 1))); do
    E=$((start + i * 3600))
    days="" bad=""
    for r in $RUNS; do
      day=${r%=*} at=${r#*=}
      if [ "$at" -lt "$E" ] && [ "$(decide "$at" "$E")" = refresh ]; then days="$days $day"
      else bad="$bad $day"; fi
    done
    n=0
    for day in $(printf '%s\n' $days | sort -u); do
      case " $bad " in *" $day "*) ;; *) n=$((n + 1)) ;; esac
    done
    if [ "$n" -lt "$worst" ]; then worst=$n worst_at=$(date -j -r "$E" '+%a %Y-%m-%d %H:%M'); fi
  done
  eq "sweep: every expiry gets >= 2 full weekday windows (fewest: $worst, for $worst_at)" yes \
    "$([ "$worst" -ge 2 ] && echo yes || echo no)"
) | tee "$TMP/sweep.out"
PASS=$((PASS + $(grep -c '^ok' "$TMP/sweep.out"))); FAIL=$((FAIL + $(grep -c '^FAIL' "$TMP/sweep.out")))

# ---- stubs ------------------------------------------------------------------
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
CALLS="$TMP/calls.log" NOTES="$TMP/notifications.log" ALERTS="$TMP/alerts.log" ANSWERS="$TMP/answers"
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }

# defaults: Xcode's account lists, signed in unless $STUB_XCODE_ACCOUNTS is
# "none" (signed out, as on 9 Nov) or "missing" (no such key). Not logged
# to $CALLS: every run reads it.
stub defaults '[ "$*" = "read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists" ] || exit 1
case "${STUB_XCODE_ACCOUNTS:-signed-in}" in
  none) printf "{\n    \"IDE.Identifiers.Prod\" =     (\n    );\n}\n" ;;
  missing) echo "The domain/default pair of (com.apple.dt.Xcode, DVTDeveloperAccountManagerAppleIDLists) does not exist" >&2; exit 1 ;;
  *) printf "{\n    \"IDE.Identifiers.Prod\" =     (\n                {\n            identifier = \"X\";\n            username = \"someone@example.com\";\n        }\n    );\n}\n" ;;
esac'
# Profiles are plain plists here; `security cms -D -i f` just prints them.
stub security 'echo "security $*" >>"$CALLS"; [ "$1 $2 $3" = "cms -D -i" ] && cat "$4"'
# osascript: a notification logs its text to $NOTES; an alert logs
# "title|message|retry:timeout" to $ALERTS and answers with the next line of
# $STUB_ANSWERS (none = no answer). "Retry unlock" also unlocks the phone,
# "Retry at <epoch>" also moves the script's clock there.
stub osascript 'case "$*" in
  *"display alert"*)
    set -- "${@: -4}"
    printf "%s|%s|%s\n" "$1" "$(printf %s "$2" | tr "\n" " ")" "$3:$4" >>"$ALERTS"
    a=$(head -n1 "$STUB_ANSWERS"); sed -i "" 1d "$STUB_ANSWERS"
    case "$a" in
      "Retry unlock") rm -f "$STUB_LOCKED"; a=Retry ;;
      "Retry at "*) echo "${a#Retry at }" >"$VD_REFRESH_NOW_FILE"; a=Retry ;;
    esac
    printf "%s\n" "$a" ;;
  *) echo "${@: -1}" >>"$NOTES" ;;
esac'
stub xcodegen 'echo "xcodegen $*" >>"$CALLS"; [ -z "${STUB_XCODEGEN_FAIL:-}" ]'
# git: rev-parse/symbolic-ref answer; archive tars the fixture tree.
stub git 'echo "git $*" >>"$CALLS"
while [ "$1" = -C ]; do shift 2; done
case "$1" in
  symbolic-ref) echo stub-branch ;;
  rev-parse) case "$*" in *nope*) exit 1 ;; esac; echo 0123456789abcdef0123456789abcdef01234567 ;;
  archive) tar -c -C "$STUB_TREE" . ;;
  *) exit 1 ;;
esac'
# xcodebuild: makes an app + appex whose profile expiries are the next line
# of $STUB_EXPIRIES (app;appex), or fails like a signed-out Xcode (always
# with $STUB_BUILD_FAIL, or when that line is "fail").
stub xcodebuild 'echo "xcodebuild $*" >>"$CALLS"
dd=""; while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && dd=$2; shift; done
line=$(head -n1 "$STUB_EXPIRIES"); sed -i "" 1d "$STUB_EXPIRIES"
if [ -n "${STUB_BUILD_FAIL:-}" ] || [ "$line" = fail ]; then
  echo "error: No Account for Team \"TEAM\". Add a new account in Accounts settings."; exit 65; fi
app="$dd/Build/Products/Debug-iphoneos/VoiceDictate.app"
mkdir -p "$app/PlugIns/DictationKeyboard.appex"
prof() { printf "<plist version=\"1.0\"><dict><key>ExpirationDate</key><date>%s</date><key>Entitlements</key><dict><key>application-identifier</key><string>%s</string></dict></dict></plist>\n" "$1" "$2"; }
prof "${line%;*}" TEAM.test.app >"$app/embedded.mobileprovision"
prof "${line#*;}" TEAM.test.app.keyboard >"$app/PlugIns/DictationKeyboard.appex/embedded.mobileprovision"
printf "<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.app</string></dict></plist>\n" >"$app/Info.plist"'
# xcrun devicectl: the device by $STUB_DEVICE:
#   connected  list shows a live tunnel
#   available  list shows the installapp capability, no tunnel
#   idle       list shows paired/disconnected (what `list devices` reports
#              until something connects); `device info details` connects
#   stale      idle, and details answers with the same stale state
#   locked     idle, and details fails because the phone is locked
#   gone       unavailable, and details times out
# While the file $STUB_LOCKED exists the phone is locked: install fails as
# it does then, and "locked" probes fail; once it is gone they connect.
# install fails with $STUB_INSTALL_FAIL, apps lists test.app once installed,
# or fails as on a locked phone with $STUB_APPS_LOCKED.
stub xcrun 'echo "xcrun $*" >>"$CALLS"
[ "$1" = devicectl ] || exit 1; shift
out=""; args="$*"; while [ $# -gt 0 ]; do [ "$1" = --json-output ] && out=$2; shift; done
installapp="[{\"featureIdentifier\":\"com.apple.coredevice.feature.installapp\"}]"
connectonly="[{\"featureIdentifier\":\"com.apple.coredevice.feature.connectdevice\"}]"
dev() { printf "{\"identifier\":\"TEST-DEVICE\",\"capabilities\":%s,\"connectionProperties\":{\"pairingState\":\"paired\",\"tunnelState\":\"%s\"}}" "$2" "$1"; }
state=${STUB_DEVICE:-connected}
[ "$state" = locked ] && [ -n "${STUB_LOCKED:-}" ] && [ ! -f "$STUB_LOCKED" ] && state=idle
case "$args" in
  "list devices"*)
    case "$state" in
      connected) d=$(dev connected "$installapp") ;;
      available) d=$(dev disconnected "$installapp") ;;
      idle|stale|locked) d=$(dev disconnected "$connectonly") ;;
      *) d=$(dev unavailable "[]") ;;
    esac
    printf "{\"result\":{\"devices\":[%s]}}" "$d" >"$out" ;;
  "device info details"*)
    case "$state" in
      idle) printf "{\"result\":%s}" "$(dev connected "$installapp")" >"$out" ;;
      stale) printf "{\"result\":%s}" "$(dev disconnected "$connectonly")" >"$out" ;;
      locked)
        echo "ERROR: The developer disk image could not be mounted on this device. (kAMDMobileImageMounterDeviceLocked: The device is locked.)"
        printf "{\"info\":{\"outcome\":\"failed\"},\"error\":{\"code\":1}}" >"$out"; exit 1 ;;
      *)
        echo "ERROR: Timed out waiting for the device to connect."
        printf "{\"info\":{\"outcome\":\"failed\"},\"error\":{\"code\":2}}" >"$out"; exit 1 ;;
    esac ;;
  "device install app"*)
    [ -z "${STUB_INSTALL_FAIL:-}" ] || { echo "ERROR: install failed"; exit 1; }
    if [ -n "${STUB_LOCKED:-}" ] && [ -f "$STUB_LOCKED" ]; then
      echo "ERROR: The developer disk image could not be mounted on this device. (kAMDMobileImageMounterDeviceLocked: The device is locked.)"; exit 1; fi
    touch "$STUB_INSTALLED"; echo "{}" >"$out" ;;
  "device info apps"*)
    if [ -n "${STUB_APPS_LOCKED:-}" ]; then
      echo "ERROR: The developer disk image could not be mounted on this device. (kAMDMobileImageMounterDeviceLocked: The device is locked.)"; exit 1; fi
    if [ -f "$STUB_INSTALLED" ]; then apps="[{\"bundleIdentifier\":\"test.app\"}]"; else apps="[]"; fi
    printf "{\"result\":{\"apps\":%s}}" "$apps" >"$out" ;;
  *) exit 1 ;;
esac'

REPO="$TMP/repo"; mkdir -p "$REPO"; echo 'DEVELOPMENT_TEAM = TEAM' >"$REPO/Local.xcconfig"
TREE="$TMP/tree"; mkdir -p "$TREE"; echo 'name: Committed' >"$TREE/project.yml"
STATE="$TMP/home/Library/Application Support/voice-dictate/ios-refresh.json"
LOGF="$TMP/home/Library/Logs/voice-dictate-ios-refresh.log"
PROFILES="$TMP/home/Library/Developer/Xcode/UserData/Provisioning Profiles"

# reset <state expiry or ""> ; resets home, logs and stub inputs
reset() {
  rm -rf "$TMP/home" "$CALLS" "$NOTES" "$ALERTS" "$TMP/installed" "$TMP/locked" "$TMP/now"
  mkdir -p "$TMP/home"; : >"$CALLS"; : >"$NOTES"; : >"$ALERTS"; : >"$ANSWERS"
  printf '%s\n' "2026-11-04T02:00:00Z;2026-11-04T02:00:01Z" >"$TMP/expiries"
  if [ -n "$1" ]; then
    mkdir -p "$(dirname "$STATE")"
    printf '{"expiry": "%s", "bundle_id": "test.app", "device": "%s"}\n' "$1" "${2:-TEST-DEVICE}" >"$STATE"
  fi
}
# run <now ISO> [args...] ; sets OUT and RC. DEVICE= overrides the device,
# LAUNCHD=1 runs as the LaunchAgent does, LOCKED=1 starts with a locked phone.
DEVICE=TEST-DEVICE
run() {
  local now=$1; shift
  [ -z "${LOCKED:-}" ] || touch "$TMP/locked"
  OUT=$(env -i HOME="$TMP/home" TZ=UTC PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    VD_REFRESH_TEST_STUBS="$STUBS" VD_REFRESH_REPO="$REPO" VD_REFRESH_DEVICE="$DEVICE" \
    VD_REFRESH_NOW="$(ep "$now")" VD_REFRESH_NOW_FILE="$TMP/now" CALLS="$CALLS" NOTES="$NOTES" STUB_TREE="$TREE" \
    STUB_EXPIRIES="$TMP/expiries" STUB_INSTALLED="$TMP/installed" \
    ALERTS="$ALERTS" STUB_ANSWERS="$ANSWERS" ${LOCKED:+STUB_LOCKED=$TMP/locked} ${LAUNCHD:+VD_REFRESH_LAUNCHD=1} \
    ${STUB_XCODE_ACCOUNTS:+STUB_XCODE_ACCOUNTS=$STUB_XCODE_ACCOUNTS} \
    ${STUB_DEVICE:+STUB_DEVICE=$STUB_DEVICE} ${STUB_BUILD_FAIL:+STUB_BUILD_FAIL=1} \
    ${STUB_INSTALL_FAIL:+STUB_INSTALL_FAIL=1} ${STUB_APPS_LOCKED:+STUB_APPS_LOCKED=1} \
    "$REFRESH" "$@" 2>&1)
  RC=$?
  rm -f "$TMP/locked" "$TMP/now"
}
state_expiry() { plutil -extract expiry raw -o - "$STATE" 2>/dev/null; }

# ---- script runs ------------------------------------------------------------
reset 2026-10-31T19:00:26Z
run 2026-10-24T21:00:00Z
eq    "far expiry: exit 0" 0 "$RC"
has   "far expiry: logs skip" "skip: profile expires 2026-10-31T19:00:26Z" "$OUT"
eq    "far expiry: no tool calls" "" "$(cat "$CALLS")"
has   "far expiry: written to the log file" "skip:" "$(cat "$LOGF")"

reset 2026-10-30T12:00:00Z
run 2026-10-28T14:00:00Z
eq    "due in daytime: exit 0" 0 "$RC"
has   "due in daytime: waits for the window" "due but outside the install window Mon-Fri 10:00-12:00" "$OUT"
eq    "due in daytime: no tool calls" "" "$(cat "$CALLS")"
eq    "due in daytime: no notification" "" "$(cat "$NOTES")"

reset 2026-11-02T12:00:00Z
run 2026-10-31T10:30:00Z
eq    "due on Saturday morning: exit 0" 0 "$RC"
has   "due on Saturday morning: waits for a weekday" "due but outside the install window" "$OUT"
eq    "due on Saturday morning: no tool calls" "" "$(cat "$CALLS")"

reset 2026-10-28T13:00:00Z
run 2026-10-28T14:00:00Z
eq    "1h left in the afternoon: still waits" 0 "$RC"
eq    "1h left in the afternoon: no tool calls" "" "$(cat "$CALLS")"

reset 2026-10-27T13:00:00Z
STUB_DEVICE=gone run 2026-10-28T14:00:00Z
eq    "expired, afternoon, unreachable: no install, no notification" "0:" "$RC:$(cat "$CALLS")$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
run 2026-10-28T10:00:00Z --dry-run
eq    "dry-run: exit 0" 0 "$RC"
has   "dry-run: says it would build and install" "dry-run: would build committed stub-branch and install on TEST-DEVICE" "$OUT"
lacks "dry-run: no build" "xcodebuild" "$(cat "$CALLS")"
lacks "dry-run: no devicectl" "xcrun" "$(cat "$CALLS")"
eq    "dry-run: nothing logged to file" no "$([ -f "$LOGF" ] && echo yes || echo no)"
eq    "dry-run: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"

reset 2026-10-30T12:00:00Z
run 2026-10-28T10:00:00Z
eq    "window refresh: exit 0" 0 "$RC"
has   "window refresh: built from git archive" "git -C $REPO archive --format=tar 0123456789abcdef0123456789abcdef01234567" "$(cat "$CALLS")"
has   "window refresh: xcodegen on the archived tree" "xcodegen generate --spec $TMP/home/Library/Caches/voice-dictate/ios-refresh/src/project.yml" "$(cat "$CALLS")"
has   "window refresh: builds the archived project" "-project $TMP/home/Library/Caches/voice-dictate/ios-refresh/src/VoiceDictate.xcodeproj" "$(cat "$CALLS")"
has   "window refresh: with the local xcconfig" "-xcconfig $TMP/home/Library/Caches/voice-dictate/ios-refresh/src/Local.xcconfig" "$(cat "$CALLS")"
has   "window refresh: generic destination, provisioning updates" "-destination generic/platform=iOS -derivedDataPath $TMP/home/Library/Caches/voice-dictate/ios-refresh/DerivedData -allowProvisioningUpdates build" "$(cat "$CALLS")"
has   "window refresh: installs over the top" "xcrun devicectl device install app --device TEST-DEVICE" "$(cat "$CALLS")"
lacks "window refresh: never uninstalls" "uninstall" "$(cat "$CALLS")"
has   "window refresh: verifies the bundle" "device info apps --device TEST-DEVICE --bundle-id test.app" "$(cat "$CALLS")"
eq    "window refresh: state has the earlier (app) expiry" 2026-11-04T02:00:00Z "$(state_expiry)"
eq    "window refresh: state has the commit" 0123456789abcdef0123456789abcdef01234567 "$(plutil -extract commit raw -o - "$STATE")"
eq    "window refresh: temp tree removed" no "$([ -d "$TMP/home/Library/Caches/voice-dictate/ios-refresh/src" ] && echo yes || echo no)"
eq    "window refresh: no notification" "" "$(cat "$NOTES")"
# The day's later runs are no-ops: the new profile lasts ~7 days.
for t in 10:30 11:00 11:30; do
  : >"$CALLS"
  run 2026-10-28T$t:00Z
  has "window refresh: $t run skips" "skip: profile expires 2026-11-04T02:00:00Z" "$OUT"
  eq  "window refresh: $t run touches nothing" "" "$(cat "$CALLS")$(cat "$NOTES")"
done

reset 2026-10-30T12:00:00Z
STUB_DEVICE=gone run 2026-10-28T10:00:00Z
eq    "unreachable in the window: exit 1" 1 "$RC"
lacks "unreachable in the window: no build" "xcodebuild" "$(cat "$CALLS")"
eq    "unreachable in the window: one notification with the expiry" \
      "iPhone keyboard re-sign pending: iPhone not reachable, connect or unlock it. Profile expires Fri 30 Oct 12:00." \
      "$(cat "$NOTES")"
has   "unreachable in the window: logged" "FAIL: iPhone not reachable" "$(cat "$LOGF")"

reset ""
STUB_DEVICE=gone run 2026-10-28T10:00:00Z
eq    "unreachable, unknown expiry: says so" \
      "iPhone keyboard re-sign pending: iPhone not reachable, connect or unlock it. Profile expiry unknown." \
      "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=gone run 2026-10-28T14:00:00Z --force
eq    "unreachable, forced outside the window: exit 1" 1 "$RC"
has   "unreachable, forced outside the window: logged" "not reachable; not building" "$OUT"
eq    "unreachable, forced outside the window: no notification" "" "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=available run 2026-10-28T11:30:00Z
eq    "phone available over Wi-Fi: installs" 0 "$RC"
has   "phone available over Wi-Fi: install happened" "device install app" "$(cat "$CALLS")"
lacks "phone available over Wi-Fi: no connection probe" "device info details" "$(cat "$CALLS")"

reset 2026-10-30T12:00:00Z
run 2026-10-28T10:00:00Z
lacks "tunnel already up: no connection probe" "device info details" "$(cat "$CALLS")"

# Fri 30 Oct: paired, unlocked, on Wi-Fi, but `list devices` said
# "disconnected" because nothing had connected yet.
reset 2026-10-30T12:00:00Z
STUB_DEVICE=idle run 2026-10-28T10:00:00Z
eq    "idle phone: connects, builds and installs" 0 "$RC"
has   "idle phone: probes with a bounded timeout" "xcrun devicectl device info details --device TEST-DEVICE --timeout 30 --json-output" "$(cat "$CALLS")"
has   "idle phone: install happened" "device install app" "$(cat "$CALLS")"
eq    "idle phone: state has the new expiry" 2026-11-04T02:00:00Z "$(state_expiry)"
eq    "idle phone: no notification" "" "$(cat "$NOTES")"
has   "idle phone: logs the probe" "not connected; connecting (up to 30s)" "$(cat "$LOGF")"
has   "idle phone: logs the connection" "iPhone TEST-DEVICE connected" "$(cat "$LOGF")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=stale run 2026-10-28T10:00:00Z
eq    "probe returns stale state: exit 1" 1 "$RC"
lacks "probe returns stale state: no build" "xcodebuild" "$(cat "$CALLS")"
has   "probe returns stale state: not reachable" "iPhone keyboard re-sign pending: iPhone not reachable, connect or unlock it." "$(cat "$NOTES")"

# A details.json left by an earlier connected run must not count.
reset 2026-10-30T12:00:00Z
mkdir -p "$TMP/home/Library/Caches/voice-dictate/ios-refresh"
printf '{"result":{"identifier":"TEST-DEVICE","capabilities":[],"connectionProperties":{"pairingState":"paired","tunnelState":"connected"}}}' \
  >"$TMP/home/Library/Caches/voice-dictate/ios-refresh/details.json"
STUB_DEVICE=gone run 2026-10-28T10:00:00Z
eq    "stale details.json from an earlier run: ignored" 1 "$RC"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=locked run 2026-10-28T10:00:00Z
eq    "locked in the window: exit 1" 1 "$RC"
lacks "locked in the window: no build" "xcodebuild" "$(cat "$CALLS")"
eq    "locked in the window: says it is locked" \
      "iPhone keyboard re-sign pending: iPhone is locked, unlock it. Profile expires Fri 30 Oct 12:00." \
      "$(cat "$NOTES")"
has   "locked in the window: logged" "FAIL: iPhone is locked, unlock it" "$(cat "$LOGF")"
has   "locked in the window: devicectl error in the log" "  | ERROR: The developer disk image could not be mounted" "$(cat "$LOGF")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=locked run 2026-10-28T14:00:00Z --force
eq    "locked, forced outside the window: exit 1" 1 "$RC"
has   "locked, forced outside the window: logged" "iPhone TEST-DEVICE is locked; not building" "$OUT"
eq    "locked, forced outside the window: no notification" "" "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=gone run 2026-10-28T10:00:00Z
has   "gone: probe error in the log" "  | ERROR: Timed out waiting" "$(cat "$LOGF")"
lacks "gone: not called locked" "locked" "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
STUB_APPS_LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked after install: exit 1" 1 "$RC"
eq    "locked after install: says why it is unconfirmed" \
      "iPhone keyboard re-sign pending: installed, but the iPhone is locked so the install could not be confirmed. Profile expires Fri 30 Oct 12:00." \
      "$(cat "$NOTES")"
eq    "locked after install: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"

reset 2026-10-30T12:00:00Z
STUB_BUILD_FAIL=1 run 2026-10-28T10:00:00Z
eq    "build failure: exit 1" 1 "$RC"
has   "build failure: notifies with the reason" "iPhone keyboard re-sign pending: build failed: No Account for Team" "$(cat "$NOTES")"
has   "build failure: and the expiry" "Profile expires Fri 30 Oct 12:00." "$(cat "$NOTES")"
eq    "build failure: one notification" 1 "$(wc -l <"$NOTES" | tr -d ' ')"
lacks "build failure: no install" "device install" "$(cat "$CALLS")"
eq    "build failure: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"
has   "build failure: error lines in the log" "  | error: No Account" "$(cat "$LOGF")"

reset 2026-10-30T12:00:00Z
STUB_INSTALL_FAIL=1 run 2026-10-28T10:00:00Z
eq    "install failure: exit 1" 1 "$RC"
has   "install failure: notifies" "iPhone keyboard re-sign pending: install on the iPhone failed" "$(cat "$NOTES")"
eq    "install failure: one notification" 1 "$(wc -l <"$NOTES" | tr -d ' ')"
eq    "install failure: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"

reset 2026-10-31T19:00:26Z
run 2026-10-24T21:00:00Z --force --no-install
eq    "force no-install: exit 0" 0 "$RC"
has   "force no-install: overrides the skip" "decision skip, overridden by --force" "$OUT"
has   "force no-install: reports the built expiry" "profile valid until 2026-11-04T02:00:00Z" "$OUT"
lacks "force no-install: no devicectl at all" "xcrun" "$(cat "$CALLS")"
eq    "force no-install: state unchanged" 2026-10-31T19:00:26Z "$(state_expiry)"

# Xcode reuses a cached profile that is still valid: purge it and rebuild.
reset 2026-10-30T12:00:00Z
printf '%s\n' "2026-10-30T12:00:00Z;2026-10-30T12:00:00Z" "2026-11-04T02:00:00Z;2026-11-04T02:00:00Z" >"$TMP/expiries"
mkdir -p "$PROFILES"
p() { printf '<plist version="1.0"><dict><key>ExpirationDate</key><date>%s</date><key>Entitlements</key><dict><key>application-identifier</key><string>%s</string></dict></dict></plist>\n' "$1" "$2"; }
p 2026-10-30T12:00:00Z TEAM.test.app >"$PROFILES/stale-app.mobileprovision"
p 2026-10-30T12:00:00Z TEAM.test.app.keyboard >"$PROFILES/stale-kb.mobileprovision"
p 2026-10-30T12:00:00Z TEAM.other.app >"$PROFILES/other.mobileprovision"
p 2026-11-20T12:00:00Z TEAM.test.app >"$PROFILES/fresh-app.mobileprovision"
run 2026-10-28T10:00:00Z
eq    "stale profile: exit 0" 0 "$RC"
eq    "stale profile: built twice" 2 "$(grep -c '^xcodebuild' "$CALLS")"
eq    "stale profile: our stale profiles moved aside" "fresh-app.mobileprovision other.mobileprovision" "$(cd "$PROFILES" && echo *)"
eq    "stale profile: state has the fresh expiry" 2026-11-04T02:00:00Z "$(state_expiry)"

reset 2026-10-30T12:00:00Z
printf '%s\n' "2026-10-30T12:00:00Z;2026-10-30T12:00:00Z" "2026-10-30T12:00:00Z;2026-10-30T12:00:00Z" >"$TMP/expiries"
run 2026-10-28T10:00:00Z
eq    "stale, nothing to purge: exit 1" 1 "$RC"
has   "stale, nothing to purge: notifies" "Xcode reused a profile expiring 2026-10-30T12:00:00Z" "$(cat "$NOTES")"
lacks "stale, nothing to purge: no install" "device install" "$(cat "$CALLS")"

# The rebuild after purging fails (Xcode signed out, 6 Nov): the purged
# profiles go back and the first, shorter-lived build installs.
cached_profiles() {
  mkdir -p "$PROFILES"
  p 2026-11-01T12:00:00Z TEAM.test.app >"$PROFILES/cached-app.mobileprovision"
  p 2026-11-01T12:00:00Z TEAM.test.app.keyboard >"$PROFILES/cached-kb.mobileprovision"
}
FIRST_COPY="$TMP/home/Library/Caches/voice-dictate/ios-refresh/first-build"
reset 2026-10-30T12:00:00Z
cached_profiles
printf '%s\n' "2026-11-01T12:00:00Z;2026-11-01T12:00:00Z" fail >"$TMP/expiries"
run 2026-10-28T10:00:00Z
eq    "rebuild fails: exit 0" 0 "$RC"
eq    "rebuild fails: built twice" 2 "$(grep -c '^xcodebuild' "$CALLS")"
eq    "rebuild fails: purged profiles moved back" "cached-app.mobileprovision cached-kb.mobileprovision" "$(cd "$PROFILES" && echo *)"
has   "rebuild fails: logs why" "rebuild after purging: build failed: No Account for Team" "$(cat "$LOGF")"
has   "rebuild fails: logs the fallback" "falling back to the first build: shorter-lived profile valid until 2026-11-01T12:00:00Z" "$(cat "$LOGF")"
has   "rebuild fails: first build installed" "device install app" "$(cat "$CALLS")"
eq    "rebuild fails: state has the first build's expiry" 2026-11-01T12:00:00Z "$(state_expiry)"
eq    "rebuild fails: copy of the first build removed" no "$([ -d "$FIRST_COPY" ] && echo yes || echo no)"
eq    "rebuild fails: no notification" "" "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
cached_profiles
printf '%s\n' "2026-10-29T09:00:00Z;2026-10-29T09:00:00Z" fail >"$TMP/expiries"
run 2026-10-28T10:00:00Z
eq    "rebuild fails, first build < 24h: exit 1" 1 "$RC"
has   "rebuild fails, first build < 24h: notifies" "re-sign pending: rebuild after purging: build failed: No Account" "$(cat "$NOTES")"
lacks "rebuild fails, first build < 24h: no install" "device install" "$(cat "$CALLS")"
eq    "rebuild fails, first build < 24h: profiles moved back" "cached-app.mobileprovision cached-kb.mobileprovision" "$(cd "$PROFILES" && echo *)"
eq    "rebuild fails, first build < 24h: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"

reset 2026-11-01T12:00:00Z
cached_profiles
printf '%s\n' "2026-11-01T12:00:00Z;2026-11-01T12:00:00Z" fail >"$TMP/expiries"
run 2026-10-28T10:00:00Z
eq    "rebuild fails, first build not newer than installed: exit 1" 1 "$RC"
lacks "rebuild fails, first build not newer than installed: no install" "device install" "$(cat "$CALLS")"

# ---- alerts -----------------------------------------------------------------
# 4-6 Nov: the phone was locked at install time, and the notification saying
# so was hidden by Focus while the display was shared. LaunchAgent runs now
# raise a modal alert that can retry the install.
ALERT_STAMP="$TMP/home/Library/Application Support/voice-dictate/ios-refresh-last-alert"
reset 2026-10-30T12:00:00Z
echo "Retry unlock" >"$ANSWERS"
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked install, Retry after unlocking: exit 0" 0 "$RC"
eq    "locked install, Retry after unlocking: built once" 1 "$(grep -c '^xcodebuild' "$CALLS")"
eq    "locked install, Retry after unlocking: installed twice" 2 "$(grep -c 'device install app' "$CALLS")"
eq    "locked install, Retry after unlocking: one alert" 1 "$(wc -l <"$ALERTS" | tr -d ' ')"
has   "locked install, Retry after unlocking: alert says why" "|install failed: the iPhone is locked." "$(cat "$ALERTS")"
has   "locked install, Retry after unlocking: alert says what to do" "Unlock your iPhone and keep it unlocked until the install finishes. Then choose Retry." "$(cat "$ALERTS")"
has   "locked install, Retry after unlocking: alert has the expiry" "The installed profile expires Fri 30 Oct 12:00" "$(cat "$ALERTS")"
has   "locked install, Retry after unlocking: Retry offered, gives up after 10 min" "|retry:600" "$(cat "$ALERTS")"
eq    "locked install, Retry after unlocking: no notification" "" "$(cat "$NOTES")"
eq    "locked install, Retry after unlocking: state updated" 2026-11-04T02:00:00Z "$(state_expiry)"
has   "locked install, Retry after unlocking: retry logged" "retry 1 of 3, as asked" "$(cat "$LOGF")"
eq    "locked install, Retry after unlocking: alert time stored" "$(ep 2026-10-28T10:00:00Z)" "$(cat "$ALERT_STAMP")"

reset 2026-10-30T12:00:00Z
echo Later >"$ANSWERS"
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked install, Later: exit 1" 1 "$RC"
eq    "locked install, Later: installed once" 1 "$(grep -c 'device install app' "$CALLS")"
has   "locked install, Later: logged" "alert answered: Later" "$(cat "$LOGF")"
eq    "locked install, Later: state unchanged" 2026-10-30T12:00:00Z "$(state_expiry)"

reset 2026-10-30T12:00:00Z
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked install, unanswered: exit 1" 1 "$RC"
has   "locked install, unanswered: logged" "alert answered: no answer" "$(cat "$LOGF")"

reset 2026-10-30T12:00:00Z
printf 'Retry\nRetry\nRetry\nRetry\n' >"$ANSWERS"
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked install, Retry forever: exit 1" 1 "$RC"
eq    "locked install, Retry forever: 1 + 3 installs" 4 "$(grep -c 'device install app' "$CALLS")"
eq    "locked install, Retry forever: 4 alerts" 4 "$(wc -l <"$ALERTS" | tr -d ' ')"
has   "locked install, Retry forever: the last one has no Retry" "|:600" "$(tail -n1 "$ALERTS")"
lacks "locked install, Retry forever: nor says to choose it" "Then choose Retry" "$(tail -n1 "$ALERTS")"

# Retry answered after the window ended: no install outside it.
reset 2026-10-30T12:00:00Z
echo "Retry at $(ep 2026-10-28T12:01:00Z)" >"$ANSWERS"
LAUNCHD=1 LOCKED=1 run 2026-10-28T11:55:00Z
eq    "Retry after noon: exit 1" 1 "$RC"
eq    "Retry after noon: no second install" 1 "$(grep -c 'device install app' "$CALLS")"
has   "Retry after noon: logged" "install window ended while the alert waited; installing next run" "$(cat "$LOGF")"

# At most one alert an hour; between them the failure still notifies.
reset 2026-10-30T12:00:00Z
printf '%s\n' "2026-11-04T02:00:00Z;2026-11-04T02:00:01Z" "2026-11-04T02:00:00Z;2026-11-04T02:00:01Z" "2026-11-04T02:00:00Z;2026-11-04T02:00:01Z" >"$TMP/expiries"
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
LAUNCHD=1 LOCKED=1 run 2026-10-28T10:30:00Z
eq    "throttle: 10:30 shows no second alert" 1 "$(wc -l <"$ALERTS" | tr -d ' ')"
eq    "throttle: 10:30 notifies instead" \
      "iPhone keyboard re-sign pending: install failed: the iPhone is locked. Profile expires Fri 30 Oct 12:00." "$(cat "$NOTES")"
has   "throttle: 10:30 logs why" "notification only" "$(cat "$LOGF")"
LAUNCHD=1 LOCKED=1 run 2026-10-28T11:00:00Z
eq    "throttle: 11:00 alerts again" 2 "$(wc -l <"$ALERTS" | tr -d ' ')"

reset 2026-10-30T12:00:00Z
echo "Retry unlock" >"$ANSWERS"
STUB_DEVICE=locked LAUNCHD=1 LOCKED=1 run 2026-10-28T10:00:00Z
eq    "locked before building, Retry after unlocking: exit 0" 0 "$RC"
has   "locked before building, Retry after unlocking: alert says why" "|iPhone is locked, unlock it." "$(cat "$ALERTS")"
eq    "locked before building, Retry after unlocking: built and installed once" "1 1" \
      "$(grep -c '^xcodebuild' "$CALLS") $(grep -c 'device install app' "$CALLS")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=gone LAUNCHD=1 run 2026-10-28T10:00:00Z
eq    "unreachable, alert: exit 1" 1 "$RC"
has   "unreachable, alert: says to connect" "Connect the iPhone by USB, or unlock it on the same Wi-Fi as this Mac. Then choose Retry." "$(cat "$ALERTS")"
lacks "unreachable, alert: no build" "xcodebuild" "$(cat "$CALLS")"

reset 2026-10-27T13:00:00Z
STUB_BUILD_FAIL=1 LAUNCHD=1 run 2026-10-28T10:00:00Z
eq    "signed out of Xcode, alert: exit 1" 1 "$RC"
has   "signed out of Xcode, alert: says to sign in" "Sign in to Xcode > Settings > Accounts with your Apple account" "$(cat "$ALERTS")"
has   "signed out of Xcode, alert: no Retry" "|:600" "$(cat "$ALERTS")"
has   "signed out of Xcode, alert: profile already expired" "The profile expired Tue 27 Oct 13:00" "$(cat "$ALERTS")"
eq    "signed out of Xcode, alert: no notification" "" "$(cat "$NOTES")"

# Xcode signed out while nothing is due: warn early, build nothing.
reset 2026-10-31T19:00:26Z
STUB_XCODE_ACCOUNTS=none LAUNCHD=1 run 2026-10-26T10:00:00Z
eq    "signed out, not due: exit 0" 0 "$RC"
eq    "signed out, not due: no build or install" "" "$(cat "$CALLS")"
eq    "signed out, not due: one alert" 1 "$(wc -l <"$ALERTS" | tr -d ' ')"
has   "signed out, not due: alert says to sign in" "|Xcode is signed out.  Sign in under Xcode > Settings > Accounts (needed for the next re-sign)." "$(cat "$ALERTS")"
has   "signed out, not due: alert has the expiry" "The installed profile expires Sat 31 Oct 19:00" "$(cat "$ALERTS")"
has   "signed out, not due: no Retry" "|:600" "$(cat "$ALERTS")"
has   "signed out, not due: logged" "Xcode is signed out (no account in Xcode > Settings > Accounts)" "$(cat "$LOGF")"
STUB_XCODE_ACCOUNTS=none LAUNCHD=1 run 2026-10-26T10:30:00Z
eq    "signed out, not due: 10:30 throttled" 1 "$(wc -l <"$ALERTS" | tr -d ' ')"
eq    "signed out, not due: 10:30 notifies" \
      "iPhone keyboard re-sign pending: Xcode is signed out. Profile expires Sat 31 Oct 19:00." "$(cat "$NOTES")"
STUB_XCODE_ACCOUNTS=none LAUNCHD=1 run 2026-10-26T11:00:00Z
eq    "signed out, not due: 11:00 alerts again" 2 "$(wc -l <"$ALERTS" | tr -d ' ')"

reset 2026-10-30T12:00:00Z
STUB_XCODE_ACCOUNTS=none LAUNCHD=1 run 2026-10-28T14:00:00Z
eq    "signed out, due but outside the window: alerts, builds nothing" "0:1:" \
      "$RC:$(wc -l <"$ALERTS" | tr -d ' '):$(cat "$CALLS")"

reset 2026-10-31T19:00:26Z
LAUNCHD=1 run 2026-10-26T10:00:00Z
eq    "signed in, not due: no alert or notification" "" "$(cat "$ALERTS")$(cat "$NOTES")"
STUB_XCODE_ACCOUNTS=missing LAUNCHD=1 run 2026-10-26T10:00:00Z
eq    "accounts unreadable: not called signed out" "" "$(cat "$ALERTS")$(cat "$NOTES")"
lacks "accounts unreadable: nothing logged about it" "signed out" "$(cat "$LOGF")"

reset 2026-10-31T19:00:26Z
STUB_XCODE_ACCOUNTS=none run 2026-10-26T10:00:00Z --dry-run
has   "signed out, dry run: says so" "Xcode is signed out" "$OUT"
eq    "signed out, dry run: no alert or notification" "" "$(cat "$ALERTS")$(cat "$NOTES")"

# Due: the build reports it, with the same advice; one alert, not two.
reset 2026-10-30T12:00:00Z
STUB_XCODE_ACCOUNTS=none STUB_BUILD_FAIL=1 LAUNCHD=1 run 2026-10-28T10:00:00Z
eq    "signed out, due: one alert" 1 "$(wc -l <"$ALERTS" | tr -d ' ')"
has   "signed out, due: from the build" "|build failed: No Account for Team" "$(cat "$ALERTS")"
has   "signed out, due: logged up front" "Xcode is signed out; the build will likely fail" "$(cat "$LOGF")"

# Outside launchd (and not a --force run in a terminal): notifications only.
reset 2026-10-30T12:00:00Z
echo Retry >"$ANSWERS"
LOCKED=1 run 2026-10-28T10:00:00Z
eq    "manual run, locked install: exit 1" 1 "$RC"
eq    "manual run, locked install: no alert" "" "$(cat "$ALERTS")"
has   "manual run, locked install: notifies" "install failed: the iPhone is locked" "$(cat "$NOTES")"

reset 2026-10-30T12:00:00Z
STUB_DEVICE=locked LAUNCHD=1 LOCKED=1 run 2026-10-28T14:00:00Z --force
eq    "locked, forced outside the window under launchd: no alert" "1:" "$RC:$(cat "$ALERTS")"

reset 2026-10-31T19:00:26Z OTHER-DEVICE
run 2026-10-28T10:00:00Z --dry-run
has   "other device's state: expiry treated as unknown" "recorded expiry is for OTHER-DEVICE, not TEST-DEVICE; decision refresh" "$OUT"

reset ""
run 2026-10-28T14:00:00Z
eq    "no state, daytime: waits" 0 "$RC"
has   "no state, daytime: says so" "no recorded expiry" "$OUT"

reset ""
mkdir -p "$TMP/rec/VoiceDictate.app/PlugIns/K.appex"
p 2026-10-31T19:00:29Z TEAM.test.app >"$TMP/rec/VoiceDictate.app/embedded.mobileprovision"
p 2026-10-31T19:00:26Z TEAM.test.app.keyboard >"$TMP/rec/VoiceDictate.app/PlugIns/K.appex/embedded.mobileprovision"
printf '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.app</string></dict></plist>\n' >"$TMP/rec/VoiceDictate.app/Info.plist"
run 2026-10-24T21:00:00Z --record "$TMP/rec/VoiceDictate.app"
eq    "record: exit 0" 0 "$RC"
eq    "record: earlier of app and appex" 2026-10-31T19:00:26Z "$(state_expiry)"
eq    "record: for the target device" TEST-DEVICE "$(plutil -extract device raw -o - "$STATE")"
rm -f "$STATE"
run 2026-10-24T21:00:00Z --dry-run --record "$TMP/rec/VoiceDictate.app"
eq    "record with --dry-run: rejected" 64 "$RC"
eq    "record with --dry-run: no state written" no "$([ -f "$STATE" ] && echo yes || echo no)"
rm "$TMP/rec/VoiceDictate.app/PlugIns/K.appex/embedded.mobileprovision"
run 2026-10-24T21:00:00Z --record "$TMP/rec/VoiceDictate.app"
eq    "record: appex without profile fails" 1 "$RC"

# The guard: a tool that resolves outside the stubs aborts before anything runs.
reset 2026-10-30T12:00:00Z
mv "$STUBS/xcodebuild" "$TMP/xcodebuild.off"
run 2026-10-28T10:00:00Z
mv "$TMP/xcodebuild.off" "$STUBS/xcodebuild"
eq    "guard: unstubbed tool refuses" 99 "$RC"
eq    "guard: no tool calls" "" "$(cat "$CALLS")"

reset 2026-10-30T12:00:00Z
DEVICE="" run 2026-10-28T10:00:00Z
eq    "no device: usage error" 64 "$RC"
has   "no device: says how to set it" "set VD_REFRESH_DEVICE" "$OUT"
eq    "no device: no tool calls" "" "$(cat "$CALLS")"

# ---- LaunchAgent ------------------------------------------------------------
# A copy of the repo layout with its own Local.xcconfig; only --print runs, so
# launchctl and ~/Library/LaunchAgents are never touched.
mkdir -p "$TMP/agent-repo/scripts" "$TMP/agent-repo/launchd"; ROOT="$(cd "$TMP/agent-repo" && pwd)"
cp "$SCRIPTS/install-refresh-agent.sh" "$SCRIPTS/voicedictate-ios-refresh" "$SCRIPTS/refresh-lib.sh" "$ROOT/scripts/"
cp "$SCRIPTS/../launchd/voicedictate-ios-refresh.plist" "$ROOT/launchd/"
INSTALL="$ROOT/scripts/install-refresh-agent.sh"
eq "agent: missing Local.xcconfig fails" 1 "$(HOME="$TMP/home" "$INSTALL" --print --device TEST-DEVICE >/dev/null 2>&1; echo $?)"
printf '%s\n' 'DEVELOPMENT_TEAM = TEAM' 'VOICEDICTATE_ID_PREFIX = com.first' 'VOICEDICTATE_ID_PREFIX = com.test // last one wins' >"$ROOT/Local.xcconfig"
eq "agent: --print needs --device" 64 "$(HOME="$TMP/home" "$INSTALL" --print >/dev/null 2>&1; echo $?)"
eq "agent: odd device id rejected" 1 "$(HOME="$TMP/home" "$INSTALL" --print --device 'x</string>' >/dev/null 2>&1; echo $?)"
PL="$TMP/agent.plist"
HOME="$TMP/home" "$INSTALL" --print --device TEST-DEVICE >"$PL"
eq "agent: rendered plist lints" 0 "$(plutil -lint -s "$PL" >/dev/null; echo $?)"
eq "agent: no placeholder left" 0 "$(grep -c PLACEHOLDER "$PL")"
eq "agent: label from the ID prefix" com.test.voicedictate.ios-refresh "$(plutil -extract Label raw -o - "$PL")"
eq "agent: device in the environment" TEST-DEVICE "$(plutil -extract EnvironmentVariables.VD_REFRESH_DEVICE raw -o - "$PL")"
eq "agent: program is the script itself (Login Items name)" "$ROOT/scripts/voicedictate-ios-refresh" "$(plutil -extract ProgramArguments.0 raw -o - "$PL")"
eq "agent: one program argument" 1 "$(plutil -extract ProgramArguments raw -o - "$PL")"
eq "agent: script is executable" yes "$([ -x "$REFRESH" ] && echo yes || echo no)"
eq "agent: script has a bash shebang" '#!/bin/bash' "$(head -n1 "$REFRESH")"
want="" got=""
for d in 1 2 3 4 5; do for t in 10:0 10:30 11:0 11:30; do want="$want $d/$t"; done; done
i=0
while plutil -extract "StartCalendarInterval.$i" xml1 -o /dev/null "$PL" >/dev/null 2>&1; do
  f() { plutil -extract "StartCalendarInterval.$i.$1" raw -o - "$PL" 2>/dev/null || echo -; }
  got="$got $(f Weekday)/$(f Hour):$(f Minute)"
  i=$((i + 1))
done
eq "agent: Mon-Fri at 10:00, 10:30, 11:00, 11:30 only" "$want" "$got"
eq "agent: not at load" false "$(plutil -extract RunAtLoad raw -o - "$PL")"
eq "agent: log path" "$TMP/home/Library/Logs/voice-dictate-ios-refresh.log" "$(plutil -extract StandardErrorPath raw -o - "$PL")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
