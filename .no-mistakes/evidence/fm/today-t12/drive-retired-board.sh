#!/usr/bin/env bash
# Live drive: the real fm-today-bridge.sh against a marked lab home and the
# machine's real Lavish store (read-only), across a real task-owned board
# lifecycle driven through bin/fm-procevent.sh.
set -u
LAB=$1; BOARD=$2; ROOT=$PWD
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
pe() { "$ROOT/bin/fm-procevent.sh" "$@"; }
snap() {
  echo "\$ fm-today-bridge.sh snapshot | jq .sections.boards"
  "$ROOT/bin/fm-today-bridge.sh" snapshot 2>"$LAB/err" > "$LAB/snap.json"; echo "exit=$?"
  jq -c '.sections.boards[]' "$LAB/snap.json"
  echo "stderr board lines:"; grep -i board "$LAB/err" || echo "  (none)"
  python3 "$ROOT/tests/fm-today-contract-check.py" check "$ROOT/docs/today-contract" "$LAB/snap.json" >/dev/null 2>&1 && echo "contract check: ok" || echo "contract check: FAIL"
}
SID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
echo "board=$BOARD sid=$SID"
printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' t12-lab "$LAB" t12-lab > "$LAB/state/t12-lab.meta"
echo; echo "== 1. task t12-lab arms the board (register-task) and one round is captured"
pe register-task lavish "$SID" t12-lab -- /bin/echo poll "$BOARD"; echo "register exit=$?"
pe start "$SID" >/dev/null 2>&1; echo "start exit=$?"
ls "$LAB/state/procevent" "$LAB/state/procevent-inbox" | sed 's/^/  /'
snap
echo; echo "== 2. round acknowledged (handled)"
pe handled "$SID" 1; snap
echo; echo "== 3. source retired while task is alive -> must stay listed, state listening (not owner-gone)"
pe retire "$SID"; echo "retire exit=$?"; ls "$LAB/state/procevent" | sed 's/^/  /'
H1=$(cd "$LAB/state" && find . -type f -exec shasum {} + | sort)
snap
H2=$(cd "$LAB/state" && find . -type f -exec shasum {} + | sort)
[ "$H1" = "$H2" ] && echo "state/ unchanged by snapshot: yes" || echo "state/ unchanged by snapshot: NO"
echo; echo "== 4. task torn down (state/t12-lab.meta removed) -> listed owner-gone"
rm -f "$LAB/state/t12-lab.meta"; snap
echo; echo "== 5. push --dry-run writes the checked snapshot"
"$ROOT/bin/fm-today-bridge.sh" push --dry-run "$LAB/dry.json" 2>/dev/null; echo "exit=$?"; jq -c '.sections.boards' "$LAB/dry.json"
echo; echo "== 6. privacy: board title/body text absent from snapshot"
TITLE=$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$BOARD" | head -1); echo "board <title> length=${#TITLE}"
if [ -n "$TITLE" ] && grep -qF "$TITLE" "$LAB/dry.json"; then echo "title leaked: YES"; else echo "title leaked: no"; fi
