# Decision and parsing helpers for voicedictate-ios-refresh. Sourced, not run;
# no side effects beyond defining functions and default thresholds, so the
# tests can call each function directly. bash 3.2 compatible (launchd's
# /bin/bash).

# Defaults; voicedictate-ios-refresh sets its own values before sourcing.
: "${REFRESH_WITHIN_HOURS:=100}"  # act when the profile expires within this
: "${WINDOW_FIRST_WEEKDAY:=1}"    # installs allowed on these local weekdays
: "${WINDOW_LAST_WEEKDAY:=5}"     # (1 = Monday ... 7 = Sunday)...
: "${WINDOW_START_HOUR:=10}"      # ...from this local hour...
: "${WINDOW_END_HOUR:=12}"        # ...up to (not including) this one
: "${MIN_FRESH_HOURS:=144}"       # a new build must be valid at least this long

# ISO-8601 UTC ("2026-10-31T19:00:26Z") -> epoch seconds. Fails on anything else.
iso_to_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

epoch_to_iso() {
  date -j -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

# Local "Sat 31 Oct 20:00" of an epoch time, for notifications.
local_time() {
  date -j -r "$1" '+%a %d %b %H:%M'
}

# Mon-Fri 10:00-11:59 local time, by default.
in_install_window() { # <epoch>
  local dh d h
  dh=$(date -j -r "$1" '+%u %H') || return 1
  d=${dh% *} h=$((10#${dh#* }))
  [ "$d" -ge "$WINDOW_FIRST_WEEKDAY" ] && [ "$d" -le "$WINDOW_LAST_WEEKDAY" ] &&
    [ "$h" -ge "$WINDOW_START_HOUR" ] && [ "$h" -lt "$WINDOW_END_HOUR" ]
}

# "Mon-Fri 10:00-12:00" for logs.
window_text() {
  local days="Mon Tue Wed Thu Fri Sat Sun" first last
  first=$(echo "$days" | cut -d' ' -f"$WINDOW_FIRST_WEEKDAY")
  last=$(echo "$days" | cut -d' ' -f"$WINDOW_LAST_WEEKDAY")
  printf '%s-%s %02d:00-%02d:00' "$first" "$last" "$WINDOW_START_HOUR" "$WINDOW_END_HOUR"
}

# decide <now-epoch> <expiry-epoch or empty> -> prints one word:
#   skip    expiry is further out than REFRESH_WITHIN_HOURS
#   wait    due, but outside the install window
#   refresh due and inside the install window
# Installing restarts the keyboard, so nothing (not even an expired or unknown
# expiry) installs outside the window.
decide() {
  local now=$1 expiry=$2
  if [ -n "$expiry" ] && [ $((expiry - now)) -gt $((REFRESH_WITHIN_HOURS * 3600)) ]; then
    echo skip; return
  fi
  if in_install_window "$now"; then echo refresh; else echo wait; fi
}

# "3d 4h" style remaining time for logs; negative means expired.
format_left() { # <seconds>
  local s=$1 sign=""
  if [ "$s" -lt 0 ]; then sign="-"; s=$((-s)); fi
  echo "${sign}$((s / 86400))d $(((s % 86400) / 3600))h"
}

# Expiry (ISO) of a provisioning profile file (CMS-signed plist).
profile_expiry() { # <embedded.mobileprovision>
  security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null
}

profile_app_identifier() { # <embedded.mobileprovision> -> TEAM.bundle.id
  security cms -D -i "$1" 2>/dev/null |
    plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null
}

# Earliest expiry (ISO) across the app's profile and every nested appex
# profile. Fails if the app or any appex lacks a readable profile.
app_expiry() { # <path/to/X.app>
  local app=$1 f e ep min="" min_iso=""
  for f in "$app/embedded.mobileprovision" "$app"/PlugIns/*.appex; do
    case "$f" in *'*.appex') continue ;; *.appex) f="$f/embedded.mobileprovision" ;; esac
    [ -f "$f" ] || return 1
    e=$(profile_expiry "$f") || return 1
    ep=$(iso_to_epoch "$e") || return 1
    if [ -z "$min" ] || [ "$ep" -lt "$min" ]; then min=$ep; min_iso=$e; fi
  done
  echo "$min_iso"
}

# All application identifiers (TEAM.bundle) signed into the app and appexes.
app_identifiers() { # <path/to/X.app>
  local f
  for f in "$1/embedded.mobileprovision" "$1"/PlugIns/*.appex/embedded.mobileprovision; do
    [ -f "$f" ] && profile_app_identifier "$f"
  done
  return 0
}

# Reads a `devicectl list devices --json-output` file. Succeeds when the device
# is paired and either has a live tunnel or advertises app installation (what
# devicectl's table shows as "connected" / "available (paired)").
device_reachable() { # <json> <device-id>
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    sys.exit(1)
for d in devices:
    ids = {d.get("identifier"), d.get("hardwareProperties", {}).get("udid")}
    if want not in ids:
        continue
    conn = d.get("connectionProperties", {})
    caps = {c.get("featureIdentifier") for c in d.get("capabilities", [])}
    if conn.get("pairingState") == "paired" and (
        conn.get("tunnelState") == "connected"
        or "com.apple.coredevice.feature.installapp" in caps
    ):
        sys.exit(0)
sys.exit(1)
PY
}

# Reads a `devicectl device info apps --json-output` file.
app_installed() { # <json> <bundle-id>
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    apps = json.load(open(path))["result"]["apps"]
except Exception:
    sys.exit(1)
sys.exit(0 if any(a.get("bundleIdentifier") == want for a in apps) else 1)
PY
}

# State file: a flat JSON object of string values.
state_get() { # <file> <key>
  [ -f "$1" ] && plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

state_write() { # <file> key value [key value ...]
  local file=$1 tmp sep="" out="{"
  shift
  while [ $# -ge 2 ]; do
    out="$out$sep\"$(json_escape "$1")\": \"$(json_escape "$2")\""
    sep=", "
    shift 2
  done
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$file.tmp.$$"
  printf '%s}\n' "$out" >"$tmp" && mv -f "$tmp" "$file"
}
