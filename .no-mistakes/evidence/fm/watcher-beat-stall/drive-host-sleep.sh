#!/usr/bin/env bash
# Real watcher in a lab home; beacon backdated 314s; second arm judged with and without a host sleep window.
set -u
TREE=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$TREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
E() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$LAB" "$@"; }
E FM_POLL=600 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$TREE/bin/fm-watch.sh" > "$LAB/w1.out" 2>&1 &
W=$!
for i in $(seq 1 60); do [ -e "$LAB/state/.last-watcher-beat" ] && break; sleep 0.5; done
sleep 3
beat=$(( $(date +%s) - 314 )); touch -t "$(date -r $beat +%Y%m%d%H%M.%S)" "$LAB/state/.last-watcher-beat"
echo "live watcher pid $W; beacon backdated to 314s old (grace 300)"
for case in "no-sleep|" "sleep-before-beat|$((beat-400)) $((beat-10))" "sleep-290s-after-beat|$((beat+14)) $((beat+304))"; do
  name=${case%%|*}; win=${case#*|}
  rc=0; E FM_HOST_SLEEP_WINDOW="$win" FM_POLL=5 FM_WATCHER_STALE_GRACE=300 FM_WATCHER_STALL_BOUND=9999999999 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$TREE/bin/fm-watch.sh" > "$LAB/a.out" 2> "$LAB/a.err" || rc=$?
  echo "--- second arm, $name (FM_HOST_SLEEP_WINDOW='$win'): exit=$rc"
  cat "$LAB/a.out" "$LAB/a.err" | head -3
done
kill -0 $W 2>/dev/null && echo "original watcher $W still alive (not evicted)"
echo "--- real macOS sleep record via fm_host_last_sleep_window: '$(env -u FM_HOST_SLEEP_WINDOW bash -c ". $TREE/bin/fm-beacon-lib.sh; fm_host_last_sleep_window")'"
echo "--- /usr/sbin/sysctl kern.sleeptime kern.waketime:"; /usr/sbin/sysctl kern.sleeptime kern.waketime
kill $W; wait $W 2>/dev/null; rm -rf "$LAB"
