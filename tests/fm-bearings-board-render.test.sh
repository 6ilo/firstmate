#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.77\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board with a Today lane and return what the renderer produced. The
# date is far from any real run day, so the now line sits at build time.
render_today() {  # <home> <today-json>
  local home=$1 data="$1/payload.json"
  jq -n --argjson today "$2" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[], today:$today}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_a_board_without_today_keeps_the_lane_hidden() {
  local home out
  home=$(make_home today-absent)
  out=$(render "$home" '[]')
  printf '%s' "$out" | jq -e '
    .error == "" and .today.hidden == true
      and .today.lanes.captain == [] and .today.lanes.ai == []
      and .today.asks == [] and .today.plans == []
  ' >/dev/null || fail "a board without today rendered a Today lane: $out"
  pass "a board without today keeps the Today lane hidden"
}

test_the_today_lane_renders_both_lanes_asks_and_plans() {
  local home out
  home=$(make_home today-lanes)
  out=$(render_today "$home" '{
    "date": "2026-01-15", "timezone": "America/Chicago", "built_at": "12:30",
    "entries": [
      {"lane": "captain", "start": "10:00", "end": "11:00", "title": "Ventures pitch"},
      {"lane": "captain", "start": "16:30", "end": "18:30", "title": "Capstone session 2", "note": "Hyde Park Art Center"},
      {"lane": "ai", "start": "12:00", "end": "13:30", "title": "Admin follow-up PR"},
      {"lane": "ai", "start": "12:00", "end": "16:00", "title": "Hoverboard series"},
      {"lane": "ai", "start": "13:30", "end": "14:00", "title": "Your merge calls", "needs_input": true}
    ],
    "asks": [{"when": "~1:30pm", "text": "Merge calls before prep"}],
    "plans": ["Finish the admin follow-up PR", "Hoverboard fasteners"]
  }')
  printf '%s' "$out" | jq -e '
    .error == "" and .today.hidden == false
      and .today.sub == "Thursday 15 January · Chicago time · built 12:30pm"
      and .today.head == ["", "You", "AI"]
      and .today.hours[0] == "8am" and .today.hours[-1] == "7pm"
      and ([.today.lanes.captain[] | .title] == ["Ventures pitch", "Capstone session 2"])
      and ([.today.lanes.captain[] | .kinds[0]] | all(. == "captain"))
      and (.today.lanes.captain[0] | .past == true and .sub == "10am-11am")
      and (.today.lanes.captain[1] | .past == false
        and .sub == "4:30pm-6:30pm · Hyde Park Art Center")
      and (.today.lanes.ai | map(select(.title == "Your merge calls"))[0]
        | .kinds[0] == "ask" and (.sub | startswith("needs you · 1:30pm-2pm")))
      and ([.today.lanes.ai[] | select(.title != "Your merge calls") | .kinds[0]] | all(. == "ai"))
      and .today.now.top == "198px"
      and .today.asks == [{"when": "~1:30pm", "text": "Merge calls before prep"}]
      and .today.plans == ["Finish the admin follow-up PR", "Hoverboard fasteners"]
  ' >/dev/null || fail "the Today lane did not render the day it was given: $out"
  pass "the Today lane renders both lanes, the input marker, the now line, asks, and plans"
}

test_overlapping_today_blocks_share_their_lane() {
  local home out
  home=$(make_home today-overlap)
  out=$(render_today "$home" '{
    "date": "2026-01-15", "timezone": "America/Chicago", "built_at": "09:00",
    "entries": [
      {"lane": "ai", "start": "12:00", "end": "13:30", "title": "First"},
      {"lane": "ai", "start": "12:00", "end": "16:00", "title": "Second"},
      {"lane": "ai", "start": "17:00", "end": "18:00", "title": "Alone"},
      {"lane": "captain", "start": "21:00", "end": "21:15", "title": "Recap"},
      {"lane": "captain", "start": "21:15", "end": "21:45", "title": "Approve"}
    ],
    "asks": [], "plans": []
  }')
  printf '%s' "$out" | jq -e '
    ([.today.lanes.ai[] | {(.title): .width}] | add) as $w
    | $w.First == "calc(50% - 8px)" and $w.Second == "calc(50% - 8px)"
      and $w.Alone == "calc(100% - 8px)"
      and ([.today.lanes.ai[] | select(.title != "Alone") | .left] | sort)
        == ["calc(0% + 4px)", "calc(50% + 4px)"]
      and ([.today.lanes.ai[] | .past] | all(. == false))
      and ([.today.lanes.captain[] | .width] | unique) == ["calc(50% - 8px)"]
      and ([.today.lanes.captain[] | .kinds] | all(index("short") != null))
      and .today.asks[0].text == "Nothing expected from you today."
      and .today.plans == ["Nothing planned yet."]
  ' >/dev/null || fail "overlapping blocks did not share their lane: $out"
  pass "overlapping Today blocks sit side by side instead of on top of each other"
}

test_a_late_short_block_stays_inside_the_lane() {
  local home out
  home=$(make_home today-late)
  out=$(render_today "$home" '{
    "date": "2026-01-15", "timezone": "America/Chicago", "built_at": "09:00",
    "entries": [
      {"lane": "captain", "start": "23:40", "end": "23:50", "title": "Last check"},
      {"lane": "ai", "start": "23:45", "end": "23:55", "title": "Night ask", "needs_input": true}
    ],
    "asks": [], "plans": []
  }')
  printf '%s' "$out" | jq -e '
    (.today.hours | length) as $n
    | .today.hours[-1] == "11pm"
      and ([.today.lanes.captain[], .today.lanes.ai[]]
        | all(((.top | rtrimstr("px") | tonumber) + (.height | rtrimstr("px") | tonumber)) <= $n * 44))
      and (.today.lanes.captain[0].sub == "11:40pm-11:50pm")
  ' >/dev/null || fail "a late short block drew past midnight: $out"
  pass "a late short block stays inside the lane instead of drawing past midnight"
}

test_today_strings_render_as_text_never_markup() {
  local home out
  home=$(make_home today-text)
  out=$(render_today "$home" '{
    "date": "2026-01-15", "timezone": "America/Chicago", "built_at": "12:00",
    "entries": [
      {"lane": "captain", "start": "13:00", "end": "14:00", "title": "<img src=x onerror=alert(1)>", "note": "</script><b>n</b>"}
    ],
    "asks": [{"when": "<i>soon</i>", "text": "<b>ask</b>"}],
    "plans": ["<script>alert(1)</script>"]
  }')
  printf '%s' "$out" | jq -e '
    .error == ""
      and (.today.lanes.captain[0] | .title == "<img src=x onerror=alert(1)>"
        and (.sub | endswith("</script><b>n</b>")) and .markup == "")
      and .today.asks == [{"when": "<i>soon</i>", "text": "<b>ask</b>"}]
      and .today.plans == ["<script>alert(1)</script>"]
  ' >/dev/null || fail "a Today payload string was not rendered as plain text: $out"
  pass "Today payload strings render as text, never as markup"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_board_without_today_keeps_the_lane_hidden
test_the_today_lane_renders_both_lanes_asks_and_plans
test_overlapping_today_blocks_share_their_lane
test_a_late_short_block_stays_inside_the_lane
test_today_strings_render_as_text_never_markup
