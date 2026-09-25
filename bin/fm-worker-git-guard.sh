#!/usr/bin/env bash
# Claude PreToolUse Bash hook that blocks destructive or delivering git calls
# for a worker whose lane must never push.
#
# bin/fm-spawn.sh writes this hook into the per-task .claude/settings.local.json
# of a Claude scout, and of a Claude ship whose delivery mode is local-only.
# Those briefs already say "Never push to any remote" (bin/fm-brief.sh for a
# scout, fm_ship_rule_one in bin/fm-dod-lib.sh for local-only); this hook turns
# a violation of that rule into a refused tool call instead of a surprise found
# later. Direct-PR and no-mistakes lanes, secondmates, and every other harness
# get no hook and keep the prose rule alone.
#
# Blocked, in any segment of a chained command (; && || | & newline, subshell),
# after any leading VAR=value assignments, shell keywords (if then elif else do
# while until !), and wrappers (`env`, `command`, `exec`, `sudo`, `nohup`,
# `time`, `timeout` with its duration, `xargs`, with their options), with git
# named bare or by path, and after git's global options (-C <dir>, -c <k=v>,
# --git-dir=..., and the like):
#   git push
#   git reset ... --hard
#   git clean ... -f / --force (including clustered short flags such as -fd)
#   git branch ... -D, or --delete/-d with --force/-f (including clusters)
#   git checkout ... .
#   git restore ... . (unless --staged/-S without --worktree/-W: unstage only)
# Anything that is not a git call is never blocked, even when it contains the
# word push. Splitting is deliberately simple and quote-unaware: a quoted
# "; git push" inside another git call's argument can be refused, which errs
# toward the brief rule rather than away from it.
#
# Usage:
#   <Claude PreToolUse JSON on stdin> | bin/fm-worker-git-guard.sh
#
# Exit contract:
#   ALLOW - exit 0, no output.
#   DENY  - exit 2 and one line on stderr naming the brief rule; Claude shows
#           that line to the model and does not run the command.
#   FAIL OPEN - empty stdin, missing jq, or no .tool_input.command: exit 0.
set -u

case "${1:-}" in
  -h | --help)
    sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Cheap prefilter: nothing to inspect without the word git.
case "$CMD" in
  *git*) ;;
  *) exit 0 ;;
esac

# Classify one already-split segment. Prints the offending form and returns 0
# when the segment is a forbidden git call; returns 1 otherwise.
classify_segment() {
  local -a w
  local i n sub a staged=0 worktree=0 dot=0 del=0 force=0
  # Quotes and escapes are dropped so "git" 'push' still reads as git push.
  a=${1//\"/}
  a=${a//\'/}
  a=${a//\\/}
  read -r -a w <<<"$a" || true
  n=${#w[@]}
  i=0
  # Leading env assignments, shell keywords, and transparent wrappers; a
  # numeric word is a wrapper's count or duration (timeout 60, xargs -n 1).
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      if | then | elif | else | do | while | until | !) i=$((i + 1)) ;;
      env | command | exec | sudo | nohup | time | timeout | xargs) i=$((i + 1)) ;;
      -u | -g | -s) i=$((i + 2)) ;;
      -* | [0-9]*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  case "${w[$i]}" in
    git | */git) ;;
    *) return 1 ;;
  esac
  i=$((i + 1))
  # git's global options; -C and -c take a separate value.
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  sub=${w[$i]}
  i=$((i + 1))
  [ "$sub" = push ] && { printf 'git push'; return 0; }
  while [ "$i" -lt "$n" ]; do
    a=${w[$i]}
    case "$sub" in
      reset) [ "$a" = --hard ] && { printf 'git reset --hard'; return 0; } ;;
      clean)
        case "$a" in
          --force | --force=*) printf 'git clean -f'; return 0 ;;
          --*) ;;
          -*f*) printf 'git clean -f'; return 0 ;;
        esac
        ;;
      branch)
        case "$a" in
          --delete) del=1 ;;
          --force) force=1 ;;
          --*) ;;
          -*D*) printf 'git branch -D'; return 0 ;;
          -*)
            case "$a" in -*d*) del=1 ;; esac
            case "$a" in -*f*) force=1 ;; esac
            ;;
        esac
        ;;
      checkout) [ "$a" = . ] && { printf 'git checkout .'; return 0; } ;;
      restore)
        case "$a" in
          .) dot=1 ;;
          --staged) staged=1 ;;
          --worktree) worktree=1 ;;
          --*) ;;
          -*)
            case "$a" in -*S*) staged=1 ;; esac
            case "$a" in -*W*) worktree=1 ;; esac
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  [ "$sub" = branch ] && [ "$del" = 1 ] && [ "$force" = 1 ] && { printf 'git branch -D'; return 0; }
  [ "$sub" = restore ] && [ "$dot" = 1 ] && { [ "$staged" = 0 ] || [ "$worktree" = 1 ]; } && { printf 'git restore .'; return 0; }
  return 1
}

NL=$'\n'
SPLIT=$CMD
for sep in '&&' '||' ';' '|' '&' '(' ')' '`' '{' '}'; do
  SPLIT=${SPLIT//"$sep"/$NL}
done
while IFS= read -r seg; do
  if form=$(classify_segment "$seg"); then
    printf '%s\n' "firstmate worker git guard: \`$form\` is blocked - brief Rule 1 on scout and local-only lanes: never push to any remote; firstmate owns delivery, and this hook also refuses discarding work with reset --hard, clean -f, branch -D, or checkout/restore ." >&2
    exit 2
  fi
done <<<"$SPLIT"
exit 0
