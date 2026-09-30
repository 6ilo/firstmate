#!/usr/bin/env bash
# drive-watcher.sh <tree-root> <label> <young-settled-count> <duration-secs>
# Seeds a disposable lab home with pending-reply history, runs the real
# bin/fm-watch.sh from <tree-root> against it, samples the beacon age each
# second, and reports record survival.
set -u
TREE=$1 LABEL=$2 N=$3 DUR=$4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$TREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
S="$LAB/state"; D="$S/pending-replies"; mkdir -p "$D"
now=$(date +%s)
rec() { # corr phase resolved_epoch extra
  { printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=t%s\n' "$1" "$1"
    printf 'parent_status=%s\ncreated_epoch=%s\ndelivered_epoch=%s\nphase=%s\n' "$S/t.status" $((now-300000)) $((now-300000)) "$2"
    [ "$3" = - ] || printf 'resolved_epoch=%s\nresolved_via=status\n' "$3"
    [ -z "${4:-}" ] || printf '%s\n' "$4"; } > "$D/$1"
}
i=0; while [ $i -lt "$N" ]; do rec "$(printf 'a%015x' $i)" resolved $((now-3600)) 'escalated_epoch=1
escalation_closed_epoch=2'; i=$((i+1)); done
i=0; while [ $i -lt 40 ]; do rec "$(printf 'b%015x' $i)" resolved $((now-2*86400)); i=$((i+1)); done
rec c000000000000001 resolved $((now-2*86400)) 'escalated_epoch=1'
rec d000000000000001 awaiting_report -
rec d000000000000002 escalated - 'escalated_epoch=1'
echo "[$LABEL] seeded: young-settled=$N old-settled=40 old-resolved-open-escalation=1 unresolved=2 total=$(ls "$D" | wc -l | tr -d ' ')"
echo "[$LABEL] load: $(sysctl -n vm.loadavg)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" FM_POLL=5 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$TREE/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
W=$!
max=0; t=0; ages=""
while [ $t -lt "$DUR" ]; do
  sleep 1; t=$((t+1))
  if [ -e "$S/.last-watcher-beat" ]; then a=$(( $(date +%s) - $(stat -f %m "$S/.last-watcher-beat") )); else a=none; fi
  ages="$ages $a"; case $a in none) ;; *) [ $a -gt $max ] && max=$a ;; esac
  kill -0 $W 2>/dev/null || { echo "[$LABEL] watcher exited at t=${t}s"; break; }
done
echo "[$LABEL] beacon age per second:$ages"
echo "[$LABEL] max beacon age over ${t}s with FM_POLL=5: ${max}s"
kill $W 2>/dev/null; wait $W 2>/dev/null
left() { [ -e "$D/$1" ] && echo kept || echo pruned; }
echo "[$LABEL] records remaining: $(ls "$D" | wc -l | tr -d ' ')"
echo "[$LABEL] young settled a000000000000000: $(left a000000000000000)"
echo "[$LABEL] old settled b000000000000000: $(left b000000000000000); old settled pruned count: $(( 40 - $(ls "$D" | grep -c '^b') ))/40"
echo "[$LABEL] old resolved w/ open escalation c000000000000001: $(left c000000000000001) (closed_epoch=$(grep -c escalation_closed_epoch "$D/c000000000000001" 2>/dev/null || echo -))"
echo "[$LABEL] unresolved d000000000000001: $(left d000000000000001); d000000000000002: $(left d000000000000002)"
echo "[$LABEL] watcher stdout: $(head -c 400 "$LAB/watch.out" | tr '\n' ' ')"
echo "[$LABEL] watcher stderr: $(head -c 400 "$LAB/watch.err" | tr '\n' ' ')"
rm -rf "$LAB"
