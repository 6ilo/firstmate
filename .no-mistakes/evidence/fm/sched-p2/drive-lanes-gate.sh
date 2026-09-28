#!/usr/bin/env bash
# Drives bin/fm-lanes.sh (the real CLI) against a disposable lab home + isolated heavy-slot ledger.
set -u
REPO=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB FM_HEAVY_SLOT_DIR=$LAB/ledger FM_LANES_CALENDAR_CACHE=$LAB/cal.json
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HEAVY_SLOT_PRESSURE_LEVEL=1 FM_HEAVY_SLOT_SWAP_USED_MB=0 FM_HEAVY_SLOT_BROWSER_PAGES=0
ep() { date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-28 $1:00" +%s; }
G() { echo "\$ $*"; env "$@" "$REPO/bin/fm-lanes.sh" gate | cut -d' ' -f1-3,11-17; }
reset() { rm -f "$LAB/state/lanes-load.state" "$LAB/config/lanes.json" "$LAB/cal.json"; }
L=FM_HEAVY_SLOT_LOAD1
echo "== S1 overnight window: 23:30 idle 3700s, load 3 -> open night-idle; 22:59 idle -> not night"
reset
G FM_LANES_NOW=$(ep 23:30) FM_LANES_IDLE_SECS=3700 $L=8 FM_LANES_LOAD5=8
G FM_LANES_NOW=$(ep 06:59) FM_LANES_IDLE_SECS=3700 $L=8 FM_LANES_LOAD5=8
G FM_LANES_NOW=$(ep 07:00) FM_LANES_IDLE_SECS=3700 $L=8 FM_LANES_LOAD5=8
G FM_LANES_NOW=$(ep 22:59) FM_LANES_IDLE_SECS=3700 $L=8 FM_LANES_LOAD5=8
echo "== S2 overnight but idle under an hour -> closed no-window"
G FM_LANES_NOW=$(ep 23:30) FM_LANES_IDLE_SECS=3599 $L=8 FM_LANES_LOAD5=8
echo "== S3 daytime quiet needs both 1m and 5m < 6"
G FM_LANES_NOW=$(ep 14:00) FM_LANES_IDLE_SECS=0 $L=5.9 FM_LANES_LOAD5=5.9
G FM_LANES_NOW=$(ep 14:00) FM_LANES_IDLE_SECS=0 $L=5.9 FM_LANES_LOAD5=6
G FM_LANES_NOW=$(ep 14:00) FM_LANES_IDLE_SECS=0 $L=6 FM_LANES_LOAD5=2
echo "== S4 calendar busy (fresh cache) during busy daytime -> open calendar; stale cache -> closed"
N=$(ep 14:00)
printf '{"fetched_at":%s,"busy":[{"start":%s,"end":%s}]}' $((N-60)) $((N-600)) $((N+600)) > $LAB/cal.json
G FM_LANES_NOW=$N FM_LANES_IDLE_SECS=0 $L=9 FM_LANES_LOAD5=9
printf '{"fetched_at":%s,"busy":[{"start":%s,"end":%s}]}' $((N-30000)) $((N-600)) $((N+600)) > $LAB/cal.json
G FM_LANES_NOW=$N FM_LANES_IDLE_SECS=0 $L=9 FM_LANES_LOAD5=9
echo 'not json' > $LAB/cal.json
G FM_LANES_NOW=$N FM_LANES_IDLE_SECS=0 $L=9 FM_LANES_LOAD5=9
rm -f $LAB/cal.json
echo "== S5 load ceiling 16 trips (two samples), stays closed until <12 for 15 min"
reset; T=$(ep 23:30)
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=17 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+60)) FM_LANES_IDLE_SECS=3700 $L=17 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+120)) FM_LANES_IDLE_SECS=3700 $L=13 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+180)) FM_LANES_IDLE_SECS=3700 $L=11 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+180+899)) FM_LANES_IDLE_SECS=3700 $L=11 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+180+900)) FM_LANES_IDLE_SECS=3700 $L=11 FM_LANES_LOAD5=10
echo "== S5b adversarial: a single 12.5 sample during the reopen wait restarts the 15-min timer"
reset
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=16 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+60)) FM_LANES_IDLE_SECS=3700 $L=16 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+120)) FM_LANES_IDLE_SECS=3700 $L=5 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+600)) FM_LANES_IDLE_SECS=3700 $L=12.5 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+1020)) FM_LANES_IDLE_SECS=3700 $L=5 FM_LANES_LOAD5=10
G FM_LANES_NOW=$((T+1020+900)) FM_LANES_IDLE_SECS=3700 $L=5 FM_LANES_LOAD5=10
echo "== S6 max_load=10 governs ceiling with no load_ceiling; steady load 11 stays closed past 15 min"
reset; echo '{"max_load":10}' > $LAB/config/lanes.json
for d in 0 60 120 1100 2100; do G FM_LANES_NOW=$((T+d)) FM_LANES_IDLE_SECS=3700 $L=11 FM_LANES_LOAD5=10; done
echo "   then load 9 for 15 min reopens"
G FM_LANES_NOW=$((T+2200)) FM_LANES_IDLE_SECS=3700 $L=9 FM_LANES_LOAD5=9
G FM_LANES_NOW=$((T+3100)) FM_LANES_IDLE_SECS=3700 $L=9 FM_LANES_LOAD5=9
echo "   explicit load_ceiling overrides max_load"
reset; echo '{"max_load":10,"load_ceiling":20}' > $LAB/config/lanes.json
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=15 FM_LANES_LOAD5=9
G FM_LANES_NOW=$((T+60)) FM_LANES_IDLE_SECS=3700 $L=15 FM_LANES_LOAD5=9
echo "== S7 memory gate closes the lane (pressure 4)"
reset
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=3 FM_LANES_LOAD5=3 FM_HEAVY_SLOT_PRESSURE_LEVEL=4
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=3 FM_LANES_LOAD5=3 FM_HEAVY_SLOT_SWAP_USED_MB=8000
echo "== S8 live ask waiting for a heavy slot closes the lane"
H=$LAB; for i in 1 2 3; do sleep 300 & P=$!; "$REPO/bin/fm-heavy-slot.sh" acquire --task hold$i --home $H --lane ask --pid $P --worktree $H >/dev/null; done
"$REPO/bin/fm-heavy-slot.sh" acquire --task ask4 --home $H --lane ask --wait 60 --worktree $H >/dev/null 2>&1 & AP=$!
sleep 3
"$REPO/bin/fm-heavy-slot.sh" list --home $H | sed -n '/ask_waiters/,$p'
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=3 FM_LANES_LOAD5=3
kill $AP 2>/dev/null; wait $AP 2>/dev/null
for i in 1 2 3 ask4; do "$REPO/bin/fm-heavy-slot.sh" release --task $i --home $H >/dev/null 2>&1; "$REPO/bin/fm-heavy-slot.sh" release --task hold$i --home $H >/dev/null 2>&1; done
G FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=3 FM_LANES_LOAD5=3
echo "== S9 invalid config fails closed"
echo '{"night_window":"25:00-07:00"}' > $LAB/config/lanes.json
env FM_LANES_NOW=$T FM_LANES_IDLE_SECS=3700 $L=3 FM_LANES_LOAD5=3 "$REPO/bin/fm-lanes.sh" gate | tr ' ' '\n' | grep -E '^(verdict|reason|config_error)='
reset
echo "== S10 dry-run check logs and prints nothing, exit 0 (real machine readings, no injection)"
unset FM_HEAVY_SLOT_PRESSURE_LEVEL FM_HEAVY_SLOT_SWAP_USED_MB FM_HEAVY_SLOT_BROWSER_PAGES
out=$("$REPO/bin/fm-lanes.sh" check); echo "exit=$? stdout_bytes=${#out}"
"$REPO/bin/fm-lanes.sh" check
cat $LAB/state/lanes-dryrun.log
echo "idle-seconds (real): $("$REPO/bin/fm-lanes.sh" idle-seconds)"
echo "== S11 dry-run only: no ledger slot taken, nothing dispatched"
"$REPO/bin/fm-heavy-slot.sh" list --home $LAB | head -5
ls $LAB/state
kill $(jobs -p) 2>/dev/null
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
