# shellcheck shell=bash
# Attended one-job hold: the record, its mutex, the gate predicate, and the spawn gates.
# Usage: . bin/fm-attended-job-lib.sh
#
# Opt-in only. A home takes part when someone with access to it creates
# config/attended-one-job; nothing here writes that file. The file, and any flag a caller
# passes to bin/fm-attended-job.sh, are assertions by whoever supplies them: nothing here
# can verify who did, so they are not consent, approval, authorization, or proof that any
# worker is stopped. A home with neither that flag nor a state/.attended-job
# record behaves exactly as it did before this library existed, and every gate below
# returns "not held" after two file tests.
#
# The record, state/.attended-job, is one file of key=value lines closed by a checksum
# line and replaced atomically under the record mutex state/.attended-job.lock. Its
# phase is reserved (a job is allowed, nothing is spawned), armed (the spawn bound the
# job to its task record and spawn generation), or terminal (hold: supervision stands
# down and no worker may start). Its launch field is none, claimed (the final launch
# gate in the worker pane passed), or refused. Hold, bind, and launch claim all take the
# same mutex, so exactly one of "claim" and "hold" wins.
#
# fm_attended_home_held <state> [config-dir] [home] is the single gate predicate. It
# returns 0 (held) for a terminal record, for an unreadable, foreign, or malformed
# record, and for an opted-in home that has task records but no record (a deleted
# record). Record presence dominates the flag. Holding never signals anything and never
# resumes anything, and nothing in this release leaves a hold: `clear` in
# bin/fm-attended-job.sh is disabled, and no stored outcome, receipt, flag, or note is
# read as permission to release one. A missing, invalid, or apparently quiescent record
# is held exactly like any other.
#
# Lock order: the spawn's per-task meta lock first, then this record mutex briefly.
# `stop` and the pane launch gate take the record mutex only and never wait for a meta
# lock while holding it. Every acquisition is bounded and a failure refuses.
#
# docs/configuration.md "Attended one-job hold" owns the operator-facing contract.

FM_ATT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ATTENDED_SCHEMA=fm-attended-job.v1
FM_ATTENDED_RECORD=.attended-job
FM_ATTENDED_LOCK=.attended-job.lock
FM_ATTENDED_KEYS=" schema seq phase task home gen worktree harness backend brief launch reason outcome created bound deadline hw "
# The job's time bound, in seconds, fixed at reserve from the actual local clock.
FM_ATTENDED_BOUND_MIN=300
FM_ATTENDED_BOUND_MAX=28800
FM_ATTENDED_BOUND_DEFAULT=3600
FM_ATTENDED_LOCK_SECONDS=${FM_ATTENDED_LOCK_SECONDS:-10}
FM_ATTENDED_LAUNCH_WAIT_POLLS=${FM_ATTENDED_LAUNCH_WAIT_POLLS:-300}

# Fields of the last record read; empty after an absent or invalid record.
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_ATT_SCHEMA= FM_ATT_SEQ= FM_ATT_PHASE= FM_ATT_TASK= FM_ATT_HOME= FM_ATT_GEN=
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_ATT_WORKTREE= FM_ATT_HARNESS= FM_ATT_BACKEND= FM_ATT_BRIEF= FM_ATT_LAUNCH=
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_ATT_REASON= FM_ATT_OUTCOME= FM_ATT_CREATED= FM_ATT_BOUND= FM_ATT_DEADLINE= FM_ATT_HW=
# Why the last fm_attended_home_held call returned 0.
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_ATT_HOLD_REASON=
# Why the last gate refused, for the caller's message.
# shellcheck disable=SC2034 # Read by sourcing callers.
FM_ATT_REFUSAL=

fm_attended_reset_fields() {
  FM_ATT_SCHEMA= FM_ATT_SEQ= FM_ATT_PHASE= FM_ATT_TASK= FM_ATT_HOME= FM_ATT_GEN=
  FM_ATT_WORKTREE= FM_ATT_HARNESS= FM_ATT_BACKEND= FM_ATT_BRIEF= FM_ATT_LAUNCH=
  FM_ATT_REASON= FM_ATT_OUTCOME= FM_ATT_CREATED= FM_ATT_BOUND= FM_ATT_DEADLINE= FM_ATT_HW=
}

# fm_attended_config_dir <state>: the home's config directory, by the same
# precedence every other script uses.
fm_attended_config_dir() {
  local state=$1
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-${state%/*}}/config}"
}

fm_attended_physical() {  # <dir>
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

fm_attended_valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# fm_attended_sha256 <file>: hex digest, or fails when no digest tool exists.
fm_attended_sha256() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$1" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$1" 2>/dev/null) || return 1
  else
    return 1
  fi
  out=${out%% *}
  case "$out" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# fm_attended_record_read <state> <home>
# Returns 0 for a valid record (fields set), 1 when no record exists, 2 when one
# exists but is not trustworthy: not a regular file, a symlink, an unknown or
# duplicate key, a torn or altered body, an unknown schema, phase, or launch value,
# or a home other than <home>. An invalid record is never repaired or ignored.
fm_attended_record_read() {
  local state=$1 home=$2 file line key val body='' sum='' seen=' ' closed=0 expect_sum
  fm_attended_reset_fields
  file="$state/$FM_ATTENDED_RECORD"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$closed" -eq 1 ]; then
      fm_attended_reset_fields
      return 2
    fi
    case "$line" in
      sum=*) sum=${line#sum=}; closed=1; continue ;;
      *=*) ;;
      *) fm_attended_reset_fields; return 2 ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$FM_ATTENDED_KEYS" in *" $key "*) ;; *) fm_attended_reset_fields; return 2 ;; esac
    case "$seen" in *" $key "*) fm_attended_reset_fields; return 2 ;; esac
    seen="$seen$key "
    body="$body$line"$'\n'
    case "$key" in
      schema) FM_ATT_SCHEMA=$val ;;
      seq) FM_ATT_SEQ=$val ;;
      phase) FM_ATT_PHASE=$val ;;
      task) FM_ATT_TASK=$val ;;
      home) FM_ATT_HOME=$val ;;
      gen) FM_ATT_GEN=$val ;;
      worktree) FM_ATT_WORKTREE=$val ;;
      harness) FM_ATT_HARNESS=$val ;;
      backend) FM_ATT_BACKEND=$val ;;
      brief) FM_ATT_BRIEF=$val ;;
      launch) FM_ATT_LAUNCH=$val ;;
      reason) FM_ATT_REASON=$val ;;
      outcome) FM_ATT_OUTCOME=$val ;;
      created) FM_ATT_CREATED=$val ;;
      bound) FM_ATT_BOUND=$val ;;
      deadline) FM_ATT_DEADLINE=$val ;;
      hw) FM_ATT_HW=$val ;;
    esac
  done < "$file"
  if [ "$closed" -ne 1 ]; then
    fm_attended_reset_fields
    return 2
  fi
  expect_sum=$(printf '%s' "$body" | cksum | awk '{print $1 "-" $2}')
  if [ -z "$expect_sum" ] || [ "$sum" != "$expect_sum" ]; then
    fm_attended_reset_fields
    return 2
  fi
  [ "$FM_ATT_SCHEMA" = "$FM_ATTENDED_SCHEMA" ] || { fm_attended_reset_fields; return 2; }
  case "$FM_ATT_SEQ" in ''|*[!0-9]*) fm_attended_reset_fields; return 2 ;; esac
  case "$FM_ATT_PHASE" in reserved|armed|terminal) ;; *) fm_attended_reset_fields; return 2 ;; esac
  case "$FM_ATT_LAUNCH" in none|claimed|refused) ;; *) fm_attended_reset_fields; return 2 ;; esac
  fm_attended_valid_id "$FM_ATT_TASK" || { fm_attended_reset_fields; return 2; }
  [ -n "$FM_ATT_HARNESS" ] && [ -n "$FM_ATT_BACKEND" ] || { fm_attended_reset_fields; return 2; }
  if [ "$FM_ATT_PHASE" = armed ] && { [ -z "$FM_ATT_GEN" ] || [ -z "$FM_ATT_WORKTREE" ]; }; then
    fm_attended_reset_fields
    return 2
  fi
  if [ "$FM_ATT_PHASE" = terminal ] && [ -z "$FM_ATT_REASON" ]; then
    fm_attended_reset_fields
    return 2
  fi
  # The time bound is part of the record: whole seconds in range, and a deadline that
  # is exactly the creation reading plus the bound. Anything else is not trusted.
  case "$FM_ATT_CREATED$FM_ATT_BOUND$FM_ATT_DEADLINE$FM_ATT_HW" in
    ''|*[!0-9]*) fm_attended_reset_fields; return 2 ;;
  esac
  case "$FM_ATT_CREATED:$FM_ATT_BOUND:$FM_ATT_DEADLINE:$FM_ATT_HW" in
    :*|*::*|*:|0[0-9]*|*:0[0-9]*) fm_attended_reset_fields; return 2 ;;
  esac
  if [ "$FM_ATT_BOUND" -lt "$FM_ATTENDED_BOUND_MIN" ] || [ "$FM_ATT_BOUND" -gt "$FM_ATTENDED_BOUND_MAX" ] \
    || [ "$FM_ATT_DEADLINE" -ne $((FM_ATT_CREATED + FM_ATT_BOUND)) ]; then
    fm_attended_reset_fields
    return 2
  fi
  if [ "$FM_ATT_HOME" != "$home" ]; then
    fm_attended_reset_fields
    return 2
  fi
  return 0
}

# fm_attended_state_has_meta <state>: true when any task record exists.
fm_attended_state_has_meta() {
  local meta
  for meta in "$1"/*.meta; do
    [ -e "$meta" ] && return 0
  done
  return 1
}

# fm_attended_home_held <state> [config-dir] [home]
# 0 = supervision must stand down and nothing may start, 1 = not held.
# Sets FM_ATT_HOLD_REASON to terminal, record-invalid, or record-missing when held.
fm_attended_home_held() {
  local state=$1 config=${2:-} home=${3:-} rc
  FM_ATT_HOLD_REASON=
  if [ ! -e "$state/$FM_ATTENDED_RECORD" ] && [ ! -L "$state/$FM_ATTENDED_RECORD" ]; then
    [ -n "$config" ] || config=$(fm_attended_config_dir "$state")
    # No record and no opt-in: the home is not an attended home at all.
    [ -e "$config/attended-one-job" ] || return 1
    # Opted in, no record: harmless until a task record exists. A task record with no
    # record means the record was deleted, which is held. Nothing, not even a leftover
    # file that looks like an acknowledgement, turns that into "not held".
    if fm_attended_state_has_meta "$state"; then
      FM_ATT_HOLD_REASON=record-missing
      return 0
    fi
    return 1
  fi
  [ -n "$home" ] || home=${FM_HOME:-${state%/*}}
  home=$(fm_attended_physical "$home") || home=${FM_HOME:-${state%/*}}
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  case "$rc" in
    0)
      if [ "$FM_ATT_PHASE" = terminal ]; then
        FM_ATT_HOLD_REASON=terminal
        return 0
      fi
      return 1
      ;;
    *)
      FM_ATT_HOLD_REASON=record-invalid
      return 0
      ;;
  esac
}

# --- deadline observation -------------------------------------------------------------
#
# The only clock is this machine's `date +%s`; no function here takes a time from a
# caller or from the record's writer. The record keeps hw, the highest reading it has
# seen. A clock that reads more than the tolerance below hw has gone backward, which
# could make a lapsed deadline look open, so it counts as due (reason clock-rollback)
# and never extends a deadline.
FM_ATTENDED_CLOCK_TOLERANCE=120
FM_ATTENDED_HW_STEP=60

# fm_attended_clock_verdict
# With a valid record read, prints ok, due, rollback, or invalid (the clock itself is
# unreadable). A bound that already lapsed at the recorded high-water mark is due
# whatever the clock now says.
fm_attended_clock_verdict() {
  local now
  now=$(date +%s 2>/dev/null) || now=
  case "$now" in ''|*[!0-9]*|0[0-9]*) echo invalid; return 0 ;; esac
  if [ "$FM_ATT_HW" -ge "$FM_ATT_DEADLINE" ]; then
    echo due
  elif [ "$now" -lt $((FM_ATT_HW - FM_ATTENDED_CLOCK_TOLERANCE)) ]; then
    echo rollback
  elif [ "$now" -ge "$FM_ATT_DEADLINE" ]; then
    echo due
  else
    echo ok
  fi
}

# fm_attended_observe <state> <config> <home>
# Cheap check for the watcher and the Stop hook. Returns 10 when the deadline is due or
# the clock rolled back (the caller runs `fm-attended-job.sh expire`), otherwise 0. An
# absent, held, or untrustworthy record is not this function's business. When the
# recorded high-water mark is at least FM_ATTENDED_HW_STEP behind the clock it advances
# it, best effort and without waiting for the mutex, so a later backward jump is
# measured against a recent reading.
fm_attended_observe() {
  local state=$1 home=$3 rc now
  [ -e "$state/$FM_ATTENDED_RECORD" ] || return 0
  home=$(fm_attended_physical "$home") || return 0
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  [ "$FM_ATT_PHASE" != terminal ] || return 0
  case "$(fm_attended_clock_verdict)" in
    due|rollback) return 10 ;;
    invalid) return 0 ;;
  esac
  now=$(date +%s)
  if [ $((now - FM_ATT_HW)) -ge "$FM_ATTENDED_HW_STEP" ]; then
    if FM_ATTENDED_LOCK_SECONDS=2 fm_attended_lock "$state"; then
      rc=0
      fm_attended_record_read "$state" "$home" || rc=$?
      if [ "$rc" -eq 0 ] && [ "$FM_ATT_PHASE" != terminal ] && [ "$now" -gt "$FM_ATT_HW" ]; then
        FM_ATT_HW=$now
        fm_attended_record_publish "$state" || true
      fi
      fm_attended_unlock
    fi
  fi
  return 0
}

# --- mutating side: needs the wake library's locks ---------------------------------

fm_attended_require_wake() {
  command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_ATT_LIB_DIR/fm-wake-lib.sh"
}

FM_ATT_LOCK_PATH=
# fm_attended_lock <state>: bounded acquire of the record mutex; nonzero refuses.
fm_attended_lock() {
  local state=$1 rc
  fm_attended_require_wake || return 1
  case "$FM_ATTENDED_LOCK_SECONDS" in ''|*[!0-9]*|0) FM_ATTENDED_LOCK_SECONDS=10 ;; esac
  FM_ATT_LOCK_PATH="$state/$FM_ATTENDED_LOCK"
  rc=0
  fm_lock_acquire_wait_bounded "$FM_ATT_LOCK_PATH" "$FM_ATTENDED_LOCK_SECONDS" || rc=$?
  [ "$rc" -eq 0 ] || FM_ATT_LOCK_PATH=
  return "$rc"
}

fm_attended_unlock() {
  [ -z "$FM_ATT_LOCK_PATH" ] || fm_lock_release "$FM_ATT_LOCK_PATH"
  FM_ATT_LOCK_PATH=
}

# fm_attended_record_publish <state>
# Writes the FM_ATT_* fields as the next record generation. The caller holds the
# record mutex. The body is replaced whole through a temp file and mv, so a reader
# sees the old or the new record and never a mix.
fm_attended_record_publish() {
  local state=$1 body seq tmp sum
  case "${FM_ATT_TASK}${FM_ATT_HOME}${FM_ATT_GEN}${FM_ATT_WORKTREE}${FM_ATT_REASON}${FM_ATT_OUTCOME}" in
    *$'\n'*) return 1 ;;
  esac
  seq=$(( ${FM_ATT_SEQ:-0} + 1 ))
  [ -n "$FM_ATT_CREATED" ] || FM_ATT_CREATED=$(date +%s)
  body="schema=$FM_ATTENDED_SCHEMA"$'\n'
  body="${body}seq=$seq"$'\n'
  body="${body}phase=$FM_ATT_PHASE"$'\n'
  body="${body}task=$FM_ATT_TASK"$'\n'
  body="${body}home=$FM_ATT_HOME"$'\n'
  body="${body}gen=$FM_ATT_GEN"$'\n'
  body="${body}worktree=$FM_ATT_WORKTREE"$'\n'
  body="${body}harness=$FM_ATT_HARNESS"$'\n'
  body="${body}backend=$FM_ATT_BACKEND"$'\n'
  body="${body}brief=$FM_ATT_BRIEF"$'\n'
  body="${body}launch=$FM_ATT_LAUNCH"$'\n'
  body="${body}reason=$FM_ATT_REASON"$'\n'
  body="${body}outcome=$FM_ATT_OUTCOME"$'\n'
  body="${body}created=$FM_ATT_CREATED"$'\n'
  body="${body}bound=$FM_ATT_BOUND"$'\n'
  body="${body}deadline=$FM_ATT_DEADLINE"$'\n'
  body="${body}hw=$FM_ATT_HW"$'\n'
  sum=$(printf '%s' "$body" | cksum | awk '{print $1 "-" $2}')
  [ -n "$sum" ] || return 1
  tmp=$(mktemp "$state/$FM_ATTENDED_RECORD.tmp.XXXXXX") || return 1
  if ! printf '%s' "$body" > "$tmp" \
    || ! printf 'sum=%s\n' "$sum" >> "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$state/$FM_ATTENDED_RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_ATT_SEQ=$seq
}

# fm_attended_meta_value <state> <id> <key>: last value of key in the task record.
fm_attended_meta_value() {
  sed -n "s/^$3=//p" "$1/$2.meta" 2>/dev/null | tail -n 1
}

# fm_attended_participates <state> <config>: true when the spawn must obey the hold,
# that is the home is opted in or a record exists. Record presence dominates the flag.
fm_attended_participates() {
  [ -e "$2/attended-one-job" ] && return 0
  [ -e "$1/$FM_ATTENDED_RECORD" ] || [ -L "$1/$FM_ATTENDED_RECORD" ]
}

# fm_attended_refuse <reason>: record why a gate refused and return 1.
fm_attended_refuse() {
  FM_ATT_REFUSAL=$1
  return 1
}

# fm_attended_spawn_gate <state> <config> <home> <id> <kind> <relaunch> <backend> <harness> <brief>
# Early gate (G6a), before the spawn creates an endpoint, a worktree, or a trust entry.
# Returns 0 to proceed. A home that is neither opted in nor holding a record passes
# untouched. Otherwise the spawn must be the one fresh ship job the reservation names.
# Sets FM_ATT_REFUSAL when it refuses.
fm_attended_spawn_gate() {
  local state=$1 config=$2 home=$3 id=$4 kind=$5 relaunch=$6 backend=$7 harness=$8 brief=$9 rc digest verdict
  FM_ATT_REFUSAL=
  fm_attended_participates "$state" "$config" || return 0
  home=$(fm_attended_physical "$home") || { fm_attended_refuse "the home path cannot be resolved"; return 1; }
  [ "$kind" = ship ] || { fm_attended_refuse "only a fresh ship task may run in an attended one-job home (kind=$kind)"; return 1; }
  [ "$relaunch" = 0 ] || { fm_attended_refuse "a relaunch is refused in an attended one-job home"; return 1; }
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  case "$rc" in
    1) fm_attended_refuse "no job is reserved; run bin/fm-attended-job.sh reserve --task $id first"; return 1 ;;
    2) fm_attended_refuse "the attended-job record is unreadable, altered, or foreign; the home is held"; return 1 ;;
  esac
  [ "$FM_ATT_PHASE" = reserved ] || { fm_attended_refuse "the attended-job record is $FM_ATT_PHASE, not reserved"; return 1; }
  [ "$FM_ATT_TASK" = "$id" ] || { fm_attended_refuse "the reservation names task $FM_ATT_TASK, not $id"; return 1; }
  [ "$FM_ATT_LAUNCH" = none ] || { fm_attended_refuse "the reservation already has launch=$FM_ATT_LAUNCH"; return 1; }
  [ "$FM_ATT_BACKEND" = "$backend" ] || { fm_attended_refuse "the reservation is for backend $FM_ATT_BACKEND, not $backend"; return 1; }
  [ "$FM_ATT_HARNESS" = "$harness" ] || { fm_attended_refuse "the reservation is for harness $FM_ATT_HARNESS, not $harness"; return 1; }
  [ -e "$config/attended-one-job" ] || { fm_attended_refuse "config/attended-one-job is absent"; return 1; }
  if fm_attended_state_has_meta "$state"; then
    fm_attended_refuse "a task record already exists in this home"
    return 1
  fi
  digest=$(fm_attended_sha256 "$brief") || { fm_attended_refuse "the brief cannot be digested"; return 1; }
  [ "$digest" = "$FM_ATT_BRIEF" ] || { fm_attended_refuse "the brief changed since the reservation"; return 1; }
  # A lapsed or untrustworthy time bound refuses here without writing anything; the
  # bind and the launch gate are the ones that hold, under the mutex.
  verdict=$(fm_attended_clock_verdict)
  [ "$verdict" = ok ] || { fm_attended_refuse "the reservation's time bound is not usable (clock=$verdict)"; return 1; }
  return 0
}

# fm_attended_spawn_bind <state> <config> <home> <id> <gen> <worktree> <brief>
# Bind gate (G6b), called under the spawn's per-task meta lock immediately before the
# task record is published. It re-reads everything under the record mutex and writes
# phase=armed with the spawn generation and worktree, so no task record ever exists
# without a bound attended record. The spawn calls it only after the early gate decided
# the home participates, so a record and flag that have both vanished since then refuse
# here instead of passing. Returns 0 on success.
fm_attended_spawn_bind() {
  local state=$1 config=$2 home=$3 id=$4 gen=$5 worktree=$6 brief=$7 rc digest verdict
  FM_ATT_REFUSAL=
  home=$(fm_attended_physical "$home") || { fm_attended_refuse "the home path cannot be resolved"; return 1; }
  rc=0
  fm_attended_lock "$state" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_attended_refuse "the attended-job mutex could not be taken within ${FM_ATTENDED_LOCK_SECONDS}s"
    return 1
  fi
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_attended_unlock
    fm_attended_refuse "the attended-job record is missing or untrustworthy at bind"
    return 1
  fi
  if [ "$FM_ATT_PHASE" != reserved ] || [ "$FM_ATT_TASK" != "$id" ] || [ "$FM_ATT_LAUNCH" != none ]; then
    fm_attended_unlock
    fm_attended_refuse "the reservation is $FM_ATT_PHASE for $FM_ATT_TASK with launch=$FM_ATT_LAUNCH, not an open reservation for $id"
    return 1
  fi
  if [ ! -e "$config/attended-one-job" ]; then
    fm_attended_unlock
    fm_attended_refuse "config/attended-one-job was removed during the spawn"
    return 1
  fi
  digest=$(fm_attended_sha256 "$brief") || digest=
  if [ -z "$digest" ] || [ "$digest" != "$FM_ATT_BRIEF" ]; then
    fm_attended_unlock
    fm_attended_refuse "the brief changed since the reservation"
    return 1
  fi
  verdict=$(fm_attended_clock_verdict)
  if [ "$verdict" != ok ]; then
    # A lapsed bound or a rolled-back clock holds the home here, under the mutex, so
    # nothing is published for a job that may no longer start.
    case "$verdict" in
      due) fm_attended_hold_locked "$state" expired || true ;;
      rollback) fm_attended_hold_locked "$state" clock-rollback || true ;;
    esac
    fm_attended_unlock
    fm_attended_refuse "the reservation's time bound is not usable (clock=$verdict)"
    return 1
  fi
  FM_ATT_PHASE=armed
  FM_ATT_GEN=$gen
  FM_ATT_WORKTREE=$worktree
  if ! fm_attended_record_publish "$state"; then
    fm_attended_unlock
    fm_attended_refuse "the attended-job record could not be written"
    return 1
  fi
  fm_attended_unlock
  return 0
}

# fm_attended_hold_locked <state> <reason>: with the mutex held and the fields read,
# make the record terminal. Idempotent for an already terminal record.
fm_attended_hold_locked() {
  [ "$FM_ATT_PHASE" != terminal ] || return 0
  FM_ATT_PHASE=terminal
  FM_ATT_REASON=$2
  FM_ATT_OUTCOME=
  fm_attended_record_publish "$1"
}

# fm_attended_launch_gate <state> <config> <home> <id> <gen> <brief>
# Final launch gate (G6c), run by the staged launch file in the worker pane. Under
# the record mutex it re-reads the record and the actual bindings and either claims
# the launch (launch=claimed) or refuses. A refusal that finds a bound job also makes
# the record terminal with launch=refused, so the spawn and `stop` see a positive
# "no worker will start". Returns 0 only when the claim was written.
fm_attended_launch_gate() {
  local state=$1 config=$2 home=$3 id=$4 gen=$5 brief=$6 rc why digest meta_gen meta_wt verdict hold_reason=launch-refused
  FM_ATT_REFUSAL=
  home=$(fm_attended_physical "$home") || { FM_ATT_REFUSAL="the home path cannot be resolved"; return 1; }
  rc=0
  fm_attended_lock "$state" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_ATT_REFUSAL="the attended-job mutex could not be taken within ${FM_ATTENDED_LOCK_SECONDS}s"
    return 1
  fi
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_attended_unlock
    FM_ATT_REFUSAL="the attended-job record is missing or untrustworthy"
    return 1
  fi
  why=
  if [ "$FM_ATT_PHASE" = terminal ]; then
    why="the home is held ($FM_ATT_REASON)"
  elif [ "$FM_ATT_PHASE" != armed ]; then
    why="the record is $FM_ATT_PHASE, not armed"
  elif [ "$FM_ATT_TASK" != "$id" ] || [ "$FM_ATT_GEN" != "$gen" ]; then
    why="the record is bound to $FM_ATT_TASK generation $FM_ATT_GEN, not $id generation $gen"
  elif [ "$FM_ATT_LAUNCH" != none ]; then
    why="a launch was already $FM_ATT_LAUNCH for this generation"
  elif [ ! -e "$config/attended-one-job" ]; then
    why="config/attended-one-job was removed"
  else
    meta_gen=$(fm_attended_meta_value "$state" "$id" spawn_gen)
    meta_wt=$(fm_attended_meta_value "$state" "$id" worktree)
    digest=$(fm_attended_sha256 "$brief") || digest=
    if [ "$meta_gen" != "$gen" ] || [ "$meta_wt" != "$FM_ATT_WORKTREE" ]; then
      why="the task record no longer carries this generation and worktree"
    elif [ -z "$digest" ] || [ "$digest" != "$FM_ATT_BRIEF" ]; then
      why="the brief changed since the reservation"
    else
      verdict=$(fm_attended_clock_verdict)
      if [ "$verdict" != ok ]; then
        why="the job's time bound is not usable (clock=$verdict)"
        case "$verdict" in
          due) hold_reason=expired ;;
          rollback) hold_reason=clock-rollback ;;
        esac
      fi
    fi
  fi
  if [ -n "$why" ]; then
    FM_ATT_REFUSAL=$why
    # A bound job that is refused here can never start: say so in the record and
    # hold the home, so no later attempt can claim it and nothing resumes by itself.
    if [ "$FM_ATT_TASK" = "$id" ] && [ "$FM_ATT_GEN" = "$gen" ] && [ "$FM_ATT_LAUNCH" = none ]; then
      FM_ATT_LAUNCH=refused
      if [ "$FM_ATT_PHASE" != terminal ]; then
        FM_ATT_PHASE=terminal
        FM_ATT_REASON=$hold_reason
        FM_ATT_OUTCOME=
      fi
      fm_attended_record_publish "$state" || true
    fi
    fm_attended_unlock
    return 1
  fi
  FM_ATT_LAUNCH=claimed
  if ! fm_attended_record_publish "$state"; then
    fm_attended_unlock
    FM_ATT_REFUSAL="the launch claim could not be written"
    return 1
  fi
  fm_attended_unlock
  return 0
}

# fm_attended_launch_settle <state> <home> <id> <gen>
# The one bounded attempt to close a launch that was typed but not confirmed. It takes
# the record mutex once, waiting at most FM_ATTENDED_LOCK_SECONDS and never retrying,
# stealing, or clearing it, and under it makes a still-open launch terminal with
# launch=refused so a late pane gate can only refuse. Prints one word:
#   claimed    a claim landed first; it is left exactly as it was, and this is not a hold
#   refused    the record is terminal with launch=refused; returns 0
#   uncertain  the mutex, the record, or the write failed, so nothing is known to be
#              held, a late pane gate may still claim and start a worker; returns 3
fm_attended_launch_settle() {
  local state=$1 home=$2 id=$3 gen=$4 rc
  home=$(fm_attended_physical "$home") || { echo uncertain; return 3; }
  rc=0
  fm_attended_lock "$state" || rc=$?
  [ "$rc" -eq 0 ] || { echo uncertain; return 3; }
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$FM_ATT_TASK" != "$id" ] || [ "$FM_ATT_GEN" != "$gen" ]; then
    fm_attended_unlock
    echo uncertain
    return 3
  fi
  case "$FM_ATT_LAUNCH" in
    claimed) fm_attended_unlock; echo claimed; return 0 ;;
    refused) fm_attended_unlock; echo refused; return 0 ;;
  esac
  FM_ATT_LAUNCH=refused
  if [ "$FM_ATT_PHASE" != terminal ]; then
    FM_ATT_PHASE=terminal
    FM_ATT_REASON=launch-unconfirmed
    FM_ATT_OUTCOME=
  fi
  if fm_attended_record_publish "$state"; then
    fm_attended_unlock
    echo refused
    return 0
  fi
  fm_attended_unlock
  echo uncertain
  return 3
}

# fm_attended_launch_receipt <state> <home> <id> <gen> [settle]
# Prints claimed, refused, pending, or invalid for this generation without taking the
# mutex. With "settle" it is fm_attended_launch_settle and returns its status, so a
# failed settle is a nonzero "uncertain" and never reads as held or refused.
fm_attended_launch_receipt() {
  local state=$1 home=$2 id=$3 gen=$4 settle=${5:-} rc
  if [ -n "$settle" ]; then
    fm_attended_launch_settle "$state" "$home" "$id" "$gen"
    return $?
  fi
  home=$(fm_attended_physical "$home") || { echo invalid; return 0; }
  rc=0
  fm_attended_record_read "$state" "$home" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$FM_ATT_TASK" != "$id" ] || [ "$FM_ATT_GEN" != "$gen" ]; then
    echo invalid
    return 0
  fi
  case "$FM_ATT_LAUNCH" in
    claimed) echo claimed ;;
    refused) echo refused ;;
    *) echo pending ;;
  esac
}
