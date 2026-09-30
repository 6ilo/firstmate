# shellcheck shell=bash
# fm-beacon-lib.sh - the watcher liveness beacon's age, measured in awake time.
# Usage: . bin/fm-beacon-lib.sh
#
# The watcher touches state/.last-watcher-beat on every poll cycle, and every
# liveness verdict compares that beacon's age with a grace window.
# Wall-clock age alone misreads host sleep as a wedged watcher: no process runs
# while the machine sleeps, so a healthy watcher's beacon ages past grace, and
# the first verdict after wake reports a stale heartbeat for a loop that simply
# has not had a chance to run.
# fm_beacon_age reports the age in awake time instead: the wall-clock age minus
# the host's most recent sleep when that sleep began at or after the beacon's
# last touch.
# Only that one sleep is known, so any earlier sleep inside the same interval
# still counts as age: the result can overstate awake time but never
# understates it, and a genuinely wedged watcher still goes stale, measured only
# in time it could have run.
# The sleep window comes from macOS's kern.sleeptime and kern.waketime; a host
# without them gets the wall-clock age unchanged.
# FM_HOST_SLEEP_WINDOW="<slept-epoch> <woke-epoch>" replaces the host read, and
# an empty value means no known sleep; tests use it.

_FM_BEACON_UNAME=${_FM_BEACON_UNAME:-$(uname 2>/dev/null || echo unknown)}

# Print "<slept-epoch> <woke-epoch>" for the host's most recent sleep, or
# nothing when none is known. Returns 1 when the host exposes no sleep record.
fm_host_last_sleep_window() {
  local line sec slept='' woke=''
  if [ -n "${FM_HOST_SLEEP_WINDOW+set}" ]; then
    printf '%s\n' "$FM_HOST_SLEEP_WINDOW"
    return 0
  fi
  [ "$_FM_BEACON_UNAME" = Darwin ] || return 1
  # One line per name, in argument order: "{ sec = 1790729687, usec = 321360 } Tue ...".
  while IFS= read -r line; do
    sec=${line#*sec = }
    sec=${sec%%,*}
    case "$sec" in ''|*[!0-9]*) return 1 ;; esac
    if [ -z "$slept" ]; then slept=$sec; else woke=$sec; fi
  done <<EOF
$(/usr/sbin/sysctl -n kern.sleeptime kern.waketime 2>/dev/null)
EOF
  [ -n "$slept" ] && [ -n "$woke" ] || return 1
  printf '%s %s\n' "$slept" "$woke"
}

# fm_beacon_age <beacon-path>
# Awake-time seconds since <beacon-path> was last touched, per the header.
# A missing or unreadable beacon prints 999999, the same sentinel fm_path_age
# (bin/fm-wake-lib.sh) uses, so it always reads as stale.
fm_beacon_age() {
  local path=$1 m now age window slept woke
  if [ "$_FM_BEACON_UNAME" = Darwin ]; then
    m=$(/usr/bin/stat -f %m "$path" 2>/dev/null)
  else
    m=$(stat -c %Y "$path" 2>/dev/null)
  fi
  case "$m" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  now=$(date +%s)
  age=$((now - m))
  window=$(fm_host_last_sleep_window 2>/dev/null) || window=
  slept=${window%% *}
  woke=${window##* }
  case "$slept:$woke" in
    *[!0-9:]*|:*|*:) ;;
    *)
      if [ "$slept" -ge "$m" ] && [ "$woke" -gt "$slept" ] && [ "$woke" -le "$now" ]; then
        age=$((age - (woke - slept)))
      fi
      ;;
  esac
  [ "$age" -ge 0 ] || age=0
  echo "$age"
}
