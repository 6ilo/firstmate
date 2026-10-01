#!/usr/bin/env bash
# Run a well-specified ship task as a Claude cloud session and supervise it like
# a local worker: the build runs on the session's own machine, nothing heavy
# runs here, and its pull request comes back as the task's ready report.
#
# Usage:
#   fm-cloud.sh launch <task-id> <owner/repo> --mode direct-PR --yolo <on|off>
#                      [--base <branch>] [--branch-prefix <prefix>]
#                      [--project <local-clone>] [--brief <file>]
#   fm-cloud.sh poll <task-id>
#
# launch reads the written brief (default data/<task-id>/brief.md), appends the
# cloud delivery instructions below, and starts `claude --cloud` on
# https://github.com/<owner/repo> at <base> (default main). The session runs on
# the captain's Claude plan in the default cloud environment set with
# /remote-env; this script never chooses or changes that environment.
# The brief is sent to the session as its whole prompt, so it should carry the
# task itself: the local worker scaffold's worktree, status-file, and inbox
# instructions name paths on this machine that a cloud session cannot reach.
# The session is told to push branch <prefix><task-id> (prefix default fm/)
# and open one ready-for-review pull request into <base> without merging it.
# Only mode direct-PR is accepted: no-mistakes and local-only need a local copy
# a cloud session does not have, and the target repository's own CI checks the
# pull request.
#
# The task is filed through the same backlog gate bin/fm-spawn.sh uses: the
# home's backlog item must exist and be dispatchable before anything launches,
# and the item moves to In flight when the task record is published. The
# record (state/<task-id>.meta) carries kind=ship, backend=cloud, the session
# URL as cloud_session=, cloud_repo=, base=, branch=, mode=, yolo=, spawn_gen=,
# and project= when a local clone is known. It names no window and no worktree,
# takes no heavy validation slot, and fm-send and fm-control cannot reach it:
# a cloud session is steered, if ever, from its own session page.
#
# Why launch drives a private tmux server: `claude --cloud` refuses to run
# without an interactive terminal, and the first launch from a new folder stops
# at a folder-trust prompt. launch runs it inside a private tmux server
# (`tmux -L`), answers the trust prompt only for its own scratch clone under
# $HOME/.local/state/firstmate/cloud-launch/, reads the session URL back from
# the screen, and stops that server. It never touches the operator's tmux
# server or any other folder's trust.
#
# poll is the task's watcher check: launch writes state/<task-id>.check.sh to
# run it and binds it with bin/fm-check-register.sh. It prints nothing until
# the session's pull request exists. On an open or merged, non-draft pull
# request from the task branch it retires its own check, arms the merge poll
# through bin/fm-pr-check.sh with the pull request's full URL, and appends
# `done [at=<epoch>]: PR <url>` - the direct-PR ready report - to the task's
# status log, which wakes the supervisor like any worker's ready report. From
# then on the normal merge poll, merge, and bin/fm-teardown.sh cleanup apply.
# A draft pull request prints one notice (recorded in state/<task-id>.cloud-draft)
# and is otherwise waited on; a merge poll that cannot be armed restores this
# check and prints the refusal on every poll until it can.
#
# Test and operator seams: FM_CLOUD_GIT_BASE replaces https://github.com as the
# clone source, FM_CLOUD_LAUNCH_DIR the scratch clone root, and
# FM_CLOUD_LAUNCH_WAIT_SECS (default 120) how long launch waits for the URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^#   fm-cloud.sh poll/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

cloud_repo_valid() {  # <owner/repo>
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$1" != *..* ]]
}

cloud_ref_valid() {  # <branch>
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && git check-ref-format --branch "$1" >/dev/null 2>&1
}

# The prompt a cloud session receives: the written brief, then the delivery
# contract that lets this home find its pull request.
cloud_prompt_write() {  # <brief> <repo> <base> <branch> <out>
  local brief=$1 repo=$2 base=$3 branch=$4 out=$5
  {
    cat "$brief"
    printf '\n# Cloud delivery\n'
    printf 'You are running as a Claude cloud session with no supervisor attached; work on your own and do not wait for replies.\n'
    printf 'Work in %s, starting from %s.\n' "$repo" "$base"
    printf 'Commit your work on a branch named exactly %s and push it to origin.\n' "$branch"
    printf 'Open one pull request from %s into %s, ready for review rather than a draft, and never merge it.\n' "$branch" "$base"
    printf 'That pull request is your ready report: the supervising home finds it by the branch name, so keep that name and open no second pull request.\n'
    printf 'If you cannot finish, push what you have and open the pull request as a draft that says what is left.\n'
  } > "$out"
}

# Start `claude --cloud` in <dir> inside a private tmux server and print the
# session URL. Owned from the fleet-ops pilot wrapper (2026-09-28).
cloud_session_start() {  # <dir> <prompt-file>
  local dir=$1 prompt=$2 sock out pane url='' waited=0 limit
  limit=${FM_CLOUD_LAUNCH_WAIT_SECS:-120}
  case "$limit" in ''|*[!0-9]*) limit=120 ;; esac
  sock="fm-cloud-launch-$$"
  out="$(dirname "$dir")/launch-$$.log"
  tmux -L "$sock" new-session -d -s l -x 220 -y 50 \
    "cd $(printf '%q' "$dir") && claude --cloud \"\$(cat $(printf '%q' "$prompt"))\"; echo LAUNCH_EXIT=\$?; sleep 30" \
    || { echo "error: could not start the private tmux server for the cloud launch" >&2; return 1; }
  while [ "$waited" -lt "$limit" ]; do
    sleep 2
    waited=$((waited + 2))
    pane=$(tmux -L "$sock" capture-pane -p -t l 2>/dev/null || true)
    if printf '%s' "$pane" | grep -q "Yes, I trust this folder"; then
      tmux -L "$sock" send-keys -t l Down
      sleep 1
      tmux -L "$sock" send-keys -t l Enter
    fi
    url=$(printf '%s\n' "$pane" | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | head -1 || true)
    printf '%s\n' "$pane" > "$out"
    [ -z "$url" ] || break
  done
  tmux -L "$sock" kill-server 2>/dev/null || true
  if [ -z "$url" ]; then
    echo "error: no cloud session URL after ${limit}s from claude $(claude --version 2>/dev/null | head -1); the last screen is saved at $out" >&2
    return 1
  fi
  rm -f "$out"
  printf '%s\n' "$url"
}

cloud_scratch_clone() {  # <repo> <base> -> prints the clone dir
  local repo=$1 base=$2 root dir
  root=${FM_CLOUD_LAUNCH_DIR:-$HOME/.local/state/firstmate/cloud-launch}
  dir="$root/${repo//\//__}"
  mkdir -p "$root" || return 1
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" && git -C "$dir" checkout -q -B "$base" "origin/$base" || return 1
  else
    git clone -q --depth 20 --branch "$base" "${FM_CLOUD_GIT_BASE:-https://github.com}/$repo.git" "$dir" || return 1
  fi
  printf '%s\n' "$dir"
}

cloud_check_arm() {  # <task-id>
  local id=$1 check="$STATE/$1.check.sh" tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-cloud-check.XXXXXX") || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Cloud task pull-request discovery; written by bin/fm-cloud.sh launch.\n'
    printf 'FM_HOME=%q exec %q poll %q\n' "$FM_HOME" "$SCRIPT_DIR/fm-cloud.sh" "$id"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f "$tmp" "$check"; then
    rm -f "$tmp"
    return 1
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null
}

cmd_launch() {
  local id repo mode='' yolo='' base=main prefix=fm/ project='' brief='' branch meta lock
  local backlog=0 row clone prompt url gen tmp
  [ "$#" -ge 2 ] || usage
  id=$1 repo=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --mode) mode=$2 ;;
      --yolo) yolo=$2 ;;
      --base) base=$2 ;;
      --branch-prefix) prefix=$2 ;;
      --project) project=$2 ;;
      --brief) brief=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  fm_pr_task_id_valid "$id" || die "invalid task id: $id"
  cloud_repo_valid "$repo" || die "the repository must be owner/repo on GitHub: $repo"
  case "$mode" in
    direct-PR) ;;
    '') die "pass --mode direct-PR; a cloud task's delivery mode is never guessed" ;;
    *) die "a cloud task ships mode direct-PR only; $mode needs a local copy a cloud session does not have" ;;
  esac
  case "$yolo" in on|off) ;; *) die "pass --yolo on or --yolo off; merge posture is never guessed" ;; esac
  branch="$prefix$id"
  cloud_ref_valid "$base" || die "invalid base branch: $base"
  cloud_ref_valid "$branch" || die "invalid task branch: $branch"
  [ -n "$brief" ] || brief="$DATA/$id/brief.md"
  [ -f "$brief" ] && [ -s "$brief" ] || die "no written brief at $brief"
  if [ -z "$project" ] && [ -d "$FM_HOME/projects/${repo#*/}/.git" ]; then
    project="$FM_HOME/projects/${repo#*/}"
  fi
  command -v tmux >/dev/null 2>&1 || die "a cloud launch needs tmux on PATH"
  command -v claude >/dev/null 2>&1 || die "a cloud launch needs claude on PATH"
  fm_backlog_directory_present "$STATE" "state directory" || die "$FM_BACKLOG_TRANSITION_ERROR"
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    die "task $id already has a task record; a cloud launch never replaces one"
  fi

  # The same pre-launch backlog gate as bin/fm-spawn.sh: refuse before anything
  # starts when this home has no dispatchable item for the task.
  if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    backlog=1
    if ! fm_backlog_row_probe "$DATA" "$id"; then
      [ "$FM_BACKLOG_ROW_RESULT" != not_found ] \
        || die "task $id has no backlog item in this home; add it first (bin/fm-tasks-axi.sh add $id '<title>' --kind ship) and re-run"
      die "task $id's backlog item could not be read before launch ($FM_BACKLOG_ROW_ERROR)"
    fi
    row=$FM_BACKLOG_ROW_STATE
    fm_backlog_row_dispatchable "$row" || die "this home's backlog item $id is not dispatchable in state $row"
  elif [ "$?" -eq 2 ]; then
    die "task $id cannot be launched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)"
  fi

  lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_acquire_wait "$lock"
  # shellcheck disable=SC2064  # the lock path is fixed for this launch.
  trap "fm_lock_release '$lock' || true" EXIT
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || die "task $id gained a task record while this launch waited"

  clone=$(cloud_scratch_clone "$repo" "$base") || die "could not prepare the scratch clone of $repo at $base"
  prompt=$(umask 077; mktemp "$STATE/.fm-cloud-prompt.XXXXXX") || exit 1
  cloud_prompt_write "$brief" "$repo" "$base" "$branch" "$prompt" || { rm -f "$prompt"; exit 1; }
  url=$(cloud_session_start "$clone" "$prompt") || { rm -f "$prompt"; exit 1; }
  rm -f "$prompt"

  # The session is now running and cannot be stopped from here, so every
  # failure below names its URL for a person to stop it on its session page.
  gen="s$(date +%s).${BASHPID:-$$}.$RANDOM"
  tmp=$(umask 077; mktemp "$STATE/.fm-cloud-meta.XXXXXX") || die "cloud session $url started, but its task record could not be prepared"
  {
    printf 'kind=ship\n'
    printf 'backend=cloud\n'
    printf 'harness=claude\n'
    printf 'mode=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    printf 'cloud_repo=%s\n' "$repo"
    printf 'base=%s\n' "$base"
    printf 'branch=%s\n' "$branch"
    printf 'cloud_session=%s\n' "$url"
    [ -z "$project" ] || printf 'project=%s\n' "$project"
    printf 'spawn_gen=%s\n' "$gen"
  } > "$tmp" || { rm -f "$tmp"; die "cloud session $url started, but its task record could not be prepared"; }
  chmod 0600 "$tmp"
  fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE" \
    || { rm -f "$tmp"; die "cloud session $url started, but its task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)"; }
  cloud_check_arm "$id" \
    || die "cloud session $url started, but its pull-request check could not be armed; re-run bin/fm-cloud.sh poll $id by hand"
  if [ "$backlog" = 1 ] && ! fm_backlog_atomic_transition dispatch "$meta" "$DATA" "$id" "$STATE"; then
    die "cloud session $url started and its task record is published, but the backlog item did not move to In flight ($FM_BACKLOG_TRANSITION_ERROR)"
  fi
  printf 'launched %s backend=cloud repo=%s branch=%s mode=%s yolo=%s session=%s\n' \
    "$id" "$repo" "$branch" "$mode" "$yolo" "$url"
}

cmd_poll() {
  local id meta repo branch rows url state draft marker err row_url row_draft
  [ "$#" -eq 1 ] || usage
  id=$1
  fm_pr_task_id_valid "$id" || exit 2
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ "$(fm_meta_get "$meta" backend)" = cloud ] || exit 0
  repo=$(fm_meta_get "$meta" cloud_repo)
  branch=$(fm_meta_get "$meta" branch)
  cloud_repo_valid "$repo" && [ -n "$branch" ] || { echo "cloud task $id has no valid repository or branch in its task record"; exit 0; }
  # A forge read that fails is silent: the next poll retries it.
  rows=$(gh pr list --repo "$repo" --head "$branch" --state all --limit 20 \
    --json url,state,isDraft --jq '.[] | [.url, .state, (.isDraft | tostring)] | @tsv' 2>/dev/null) || exit 0
  url='' draft=''
  while IFS=$'\t' read -r row_url state row_draft; do
    case "$state" in OPEN|MERGED) ;; *) continue ;; esac
    if [ "$row_draft" = true ]; then
      [ -n "$draft" ] || draft=$row_url
      continue
    fi
    url=$row_url
    break
  done <<< "$rows"
  if [ -z "$url" ]; then
    marker="$STATE/$id.cloud-draft"
    if [ -n "$draft" ] && [ "$(cat "$marker" 2>/dev/null || true)" != "$draft" ]; then
      printf '%s\n' "$draft" > "$marker"
      echo "cloud task $id opened draft pull request $draft; its ready report waits until it is marked ready for review"
    fi
    exit 0
  fi
  "$SCRIPT_DIR/fm-check-unregister.sh" "$id" >/dev/null || { echo "cloud task $id: pull request $url found, but its discovery check could not be retired"; exit 0; }
  if ! err=$("$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" 2>&1 >/dev/null); then
    cloud_check_arm "$id" || true
    echo "cloud task $id: pull request $url found, but merge monitoring could not be armed: $err"
    exit 0
  fi
  rm -f "$STATE/$id.cloud-draft"
  printf 'done [at=%s]: PR %s\n' "$(date +%s)" "$url" >> "$STATE/$id.status"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md), as every status append does.
  [ ! -e "$CONFIG/fleet-ledger" ] \
    || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATE/$id.status" >/dev/null 2>&1 || true
}

[ "$#" -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  launch) cmd_launch "$@" ;;
  poll) cmd_poll "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
