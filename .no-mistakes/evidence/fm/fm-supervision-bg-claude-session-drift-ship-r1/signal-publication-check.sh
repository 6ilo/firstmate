#!/usr/bin/env bash
set -eu
ROOT=${ROOT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-signal.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/bin"
ln -s /bin/bash "$LAB/claude"

cat > "$LAB/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${MODE:-}" = B ] && [ "${1:-}" = "$FM_HOME/state/.lock" ] \
  && [ -f "$FM_HOME/state/.lock-session" ] \
  && [ "$(/bin/cat "$FM_HOME/state/.lock-session")" = NEW ] \
  && [ "$(/bin/cat "$FM_HOME/state/.lock")" != 1 ] \
  && [ ! -e "$FM_HOME/state/ready" ]; then
  : > "$FM_HOME/state/ready"
  while [ ! -e "$FM_HOME/state/release" ]; do sleep 0.01; done
fi
exec /bin/cat "$@"
SH
cat > "$LAB/bin/mv" <<'SH'
#!/usr/bin/env bash
/bin/mv "$@"
rc=$?
if [ "${MODE:-}" = A ] && [ "${!#}" = "$FM_HOME/state/.lock-session" ]; then
  : > "$FM_HOME/state/ready"
  while [ ! -e "$FM_HOME/state/release" ]; do sleep 0.01; done
fi
exit "$rc"
SH
cat > "$LAB/bin/rm" <<'SH'
#!/usr/bin/env bash
/bin/rm "$@"
rc=$?
case " $* " in
  *" $FM_HOME/state/.lock-session.prev "*)
    if [ "${MODE:-}" = C ] && [ -f "$FM_HOME/state/.lock" ] \
      && [ "$(/bin/cat "$FM_HOME/state/.lock")" != 1 ]; then
      : > "$FM_HOME/state/ready"
      while [ ! -e "$FM_HOME/state/release" ]; do sleep 0.01; done
    fi
    ;;
esac
exit "$rc"
SH
chmod +x "$LAB/bin/cat" "$LAB/bin/mv" "$LAB/bin/rm"

run_case() {
  mode=$1
  home="$LAB/$mode"
  mkdir -p "$home/state"
  printf '1\n' > "$home/state/.lock"
  printf 'OLD\n' > "$home/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    PATH="$LAB/bin:$PATH" MODE="$mode" FM_HOME="$home" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$LAB/claude" -c '
      export CLAUDE_CODE_SESSION_ID=NEW CLAUDE_PID=$$
      "$FM_LOCK" > "$FM_HOME/state/output" 2>&1 &
      child=$!
      printf "%s\n" "$child" > "$FM_HOME/state/child"
      wait "$child" || true
      : > "$FM_HOME/state/done"
      :
    ' &
  launcher=$!
  i=0
  while [ ! -e "$home/state/ready" ] && [ "$i" -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$home/state/ready" ] || { echo "phase $mode did not reach signal window"; return 1; }
  kill -TERM "$(/bin/cat "$home/state/child")"
  : > "$home/state/release"
  wait "$launcher" || true
  case "$mode" in
    A)
      [ "$(/bin/cat "$home/state/.lock")" = 1 ]
      [ "$(/bin/cat "$home/state/.lock-session")" = OLD ]
      echo "phase A: signal restored OLD beside unchanged pid 1"
      ;;
    B)
      [ "$(/bin/cat "$home/state/.lock")" != 1 ]
      [ ! -e "$home/state/.lock-session" ]
      echo "phase B: signal removed sidecar beside unverified new pid $(/bin/cat "$home/state/.lock")"
      ;;
    C)
      [ "$(/bin/cat "$home/state/.lock")" != 1 ]
      [ "$(/bin/cat "$home/state/.lock-session")" = NEW ]
      echo "phase C: signal preserved NEW beside verified new pid $(/bin/cat "$home/state/.lock")"
      ;;
  esac
}

run_case A
run_case B
run_case C
