#!/usr/bin/env bash
# Adversarial live drive: a board firstmate armed for itself (plain register,
# not task-owned) is captured, concluded, and retired while still open in the
# real Lavish store; and every other real open Lavish board has no rounds here.
# None may be listed or named on stderr.
set -u
LAB=$1; BOARD=$2; ROOT=$PWD
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
SID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
echo "open boards in real Lavish store: $(jq '[.sessions[]|select(.status=="open")]|length' ~/.lavish-axi/state.json)"
echo "board=$BOARD sid=$SID"
"$ROOT/bin/fm-procevent.sh" register lavish "$SID" -- /bin/echo poll "$BOARD"
"$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1
"$ROOT/bin/fm-procevent.sh" handled "$SID" 1 2>&1
"$ROOT/bin/fm-procevent.sh" retire "$SID" 2>&1
echo "inbox:"; ls "$LAB/state/procevent-inbox" | sed 's/^/  /'
echo "source records:"; ls "$LAB/state/procevent" | grep '\.source$' | sed 's/^/  /' || echo "  (none)"
"$ROOT/bin/fm-today-bridge.sh" snapshot 2>"$LAB/err" >"$LAB/snap.json"; echo "snapshot exit=$?"
echo "boards: $(jq -c .sections.boards "$LAB/snap.json")"
echo "stderr board lines:"; grep -i board "$LAB/err" || echo "  (none)"
