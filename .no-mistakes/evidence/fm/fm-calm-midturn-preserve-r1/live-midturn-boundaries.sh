#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/kunchen/.no-mistakes/worktrees/52b07e9083e7/01M2NK64YSRAKYMMK7JHKGA6NY
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M2NK64YSRAKYMMK7JHKGA6NY
LAB="$ROOT/.tmp-live-midturn-$$"
PROJECT="$LAB/project"
FMHOME="$LAB/fmhome"
SOCKET="fm-calm-boundary-$$"
SESSION=calm-boundary
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$PROJECT/.claude/skills" "$FMHOME/config"
ln -s "$ROOT/.claude/mods/firstmate-calm" "$PROJECT/.claude/skills/firstmate-calm"
printf 'on\n' > "$FMHOME/config/calm"
printf 'BRIEF_NARRATION_7Q\n' > "$PROJECT/brief.txt"
printf 'MULTILINE_PRESERVED_A7\nMULTILINE_PRESERVED_B7\n' > "$PROJECT/multiline.txt"
python3 - "$PROJECT" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
def bounded(prefix, suffix, length, fill):
    return prefix + fill * (length - len(prefix) - len(suffix)) + suffix
(p/'at240.txt').write_text(bounded('AT240_BEGIN_', '_AT240_END', 240, 'T'))
(p/'under239.txt').write_text(bounded('UNDER239_BEGIN_', '_UNDER239_END', 239, 'U'))
assert len((p/'at240.txt').read_text()) == 240
assert len((p/'under239.txt').read_text()) == 239
PY
unset_args=()
while IFS= read -r name; do unset_args+=( -u "$name" ); done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
launch() {
  local extra=${1:-}
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 100 -c "$PROJECT" \
    "env ${unset_args[*]} CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$FMHOME' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' $extra; sleep 20"
}
screen() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION"; }
send() { tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"; tmux -L "$SOCKET" send-keys -t "$SESSION" Enter; }
wait_for() {
  local needle=$1 i=0 shot
  while (( i < 800 )); do
    shot=$(screen)
    if [[ $shot == *'trust this folder'* || $shot == *'Enter to confirm'* ]]; then
      tmux -L "$SOCKET" send-keys -t "$SESSION" Down Enter
    elif [[ $shot == *"$needle"* ]]; then
      sleep 1
      return 0
    fi
    sleep .25; ((i+=1))
  done
  screen >&2
  echo "timed out waiting for $needle" >&2
  return 1
}
wait_for_reply() {
  local needle=$1 i=0 shot count
  while (( i < 800 )); do
    shot=$(screen)
    count=$(printf '%s' "$shot" | python3 -c 'import sys; print(sys.stdin.read().count(sys.argv[1]))' "$needle")
    if (( count >= 2 )) && [[ $shot != *'╲▁▁▁╱'* ]]; then
      sleep 1
      return 0
    fi
    sleep .25; ((i+=1))
  done
  screen >&2
  echo "timed out waiting for completed reply $needle" >&2
  return 1
}
run_case() {
  local file=$1 final=$2 capture=$3
  send "Use Bash to read $file. After that tool result, copy the file content verbatim into an assistant text response with no framing, then call Bash again with the command true. After that second tool, reply exactly $final and nothing else."
  wait_for_reply "$final"
  screen > "$EVIDENCE/$capture"
}
launch
wait_for '❯'
run_case brief.txt FINAL_BRIEF_DONE live-brief-settled.txt
run_case multiline.txt FINAL_MULTILINE_DONE live-multiline-settled.txt
run_case at240.txt FINAL_240_DONE live-at240-settled.txt
run_case under239.txt FINAL_239_DONE live-under239-settled.txt
all=$(screen)
[[ $all != *BRIEF_NARRATION_7Q* ]]
[[ $all == *MULTILINE_PRESERVED_A7* && $all == *MULTILINE_PRESERVED_B7* ]]
[[ $all == *AT240_BEGIN_* && $all == *_AT240_END* ]]
[[ $all != *UNDER239_BEGIN_* && $all != *_UNDER239_END* ]]
send /exit
sleep 2
launch --continue
wait_for_reply FINAL_239_DONE
screen > "$EVIDENCE/live-restored-boundaries.txt"
restored=$(screen)
[[ $restored != *BRIEF_NARRATION_7Q* ]]
[[ $restored == *MULTILINE_PRESERVED_A7* && $restored == *MULTILINE_PRESERVED_B7* ]]
[[ $restored == *AT240_BEGIN_* && $restored == *_AT240_END* ]]
[[ $restored != *UNDER239_BEGIN_* && $restored != *_UNDER239_END* ]]
echo 'PASS: live Claude Code TUI hid short and 239-character single-line mid-turn rows, preserved multiline and 240-character rows, and restored the same visibility after --continue.'
