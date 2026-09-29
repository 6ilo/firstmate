#!/usr/bin/env bash
# Adversarial live drive: task-a then task-b each own the same board for one
# round, then the source is retired. The owner is ambiguous: the board must be
# left out and named once on stderr.
set -u
LAB=$1; BOARD=$2; ROOT=$PWD
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
SID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD"); echo "board=$BOARD sid=$SID"
seq=0
for t in task-a task-b; do
  seq=$((seq+1))
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' $t "$LAB" $t > "$LAB/state/$t.meta"
  "$ROOT/bin/fm-procevent.sh" register-task lavish "$SID" $t -- /bin/echo poll "$BOARD"
  "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1
  "$ROOT/bin/fm-procevent.sh" handled "$SID" $seq
  "$ROOT/bin/fm-procevent.sh" retire "$SID"
done
for f in "$LAB"/state/procevent-inbox/"$SID".*.owner-task; do echo "  $(basename "$f"): $(cat "$f")"; done
"$ROOT/bin/fm-today-bridge.sh" snapshot 2>"$LAB/err" >"$LAB/snap.json"; echo "snapshot exit=$?"
echo "boards: $(jq -c '[.sections.boards[]|select(.link|test("'"${SID#lavish-}"'"))]' "$LAB/snap.json")"
echo "stderr board lines:"; grep -i "board" "$LAB/err" || echo "  (none)"
