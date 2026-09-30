#!/usr/bin/env bash
# Behavior tests for bin/fm-plan-board.sh and the shipped plan-board template
# (.agents/skills/plan-board/assets/plan-board-template.html). Boards are built
# from the shipped sample items file and executed under the minimal DOM shim in
# tests/assets/plan-board-harness.mjs, so assertions are on what the page
# renders and saves, never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-plan-board.sh"
SAMPLE="$ROOT/.agents/skills/plan-board/assets/sample-items.json"
HARNESS="$ROOT/tests/assets/plan-board-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-plan-board)

for tool in jq node python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

# edit <jq-filter>: write the sample with one change applied and echo its path.
edit() {
  local f
  f=$(mktemp "$TMP_ROOT/items.XXXXXX")
  jq "$1" "$SAMPLE" > "$f"
  printf '%s\n' "$f"
}

# render <items.json> [<saved.json>|""] [--known <record>]: build the page and
# print what the harness saw.
render() {
  local items=$1 saved=${2-} page
  shift
  [ $# -gt 0 ] && shift
  page=$(mktemp "$TMP_ROOT/page.XXXXXX")
  "$BOARD" build "$items" "$page" "$@" >/dev/null || fail "$items did not build"
  if [ -n "$saved" ]; then node "$HARNESS" "$page" "$saved"; else node "$HARNESS" "$page"; fi
}

# A read-back directory in the layout `Artifact read_db ... out_dir=` writes,
# and the same documents as the harness's fake store.
READ_DB="$TMP_ROOT/read-db"
SAVED="$TMP_ROOT/saved.json"
mkdir -p "$READ_DB/answers" "$READ_DB/reopen" "$READ_DB/notes" "$READ_DB/check"
printf '%s\n' '{"item":"Q1","pick":"A","note":"go","unsure":false,"at":"2026-10-01T10:00:00Z"}' > "$READ_DB/answers/Q1.json"
printf '%s\n' '{"item":"Q3","note":"one level is enough","at":"2026-10-01T10:01:00Z"}' > "$READ_DB/reopen/Q3.json"
printf '%s\n' '{"note":"ship it","at":"2026-10-01T10:02:00Z"}' > "$READ_DB/notes/general.json"
printf '%s\n' '{"item":"U2","choice":0,"correct":true,"at":"2026-10-01T10:03:00Z"}' > "$READ_DB/check/U2.json"
jq -n --slurpfile a "$READ_DB/answers/Q1.json" --slurpfile r "$READ_DB/reopen/Q3.json" \
  --slurpfile g "$READ_DB/notes/general.json" --slurpfile c "$READ_DB/check/U2.json" \
  '{answers:{Q1:$a[0]}, reopen:{Q3:$r[0]}, notes:{general:$g[0]}, check:{U2:$c[0]}}' > "$SAVED"

test_the_build_is_deterministic() {
  local copy="$TMP_ROOT/elsewhere/items.json"
  mkdir -p "$(dirname "$copy")"
  cp "$SAMPLE" "$copy"
  "$BOARD" build "$SAMPLE" "$TMP_ROOT/a.html" >/dev/null || fail "the sample did not build"
  "$BOARD" build "$SAMPLE" "$TMP_ROOT/b.html" >/dev/null || fail "the second build failed"
  "$BOARD" build "$copy" "$TMP_ROOT/c.html" >/dev/null || fail "the copied sample did not build"
  cmp -s "$TMP_ROOT/a.html" "$TMP_ROOT/b.html" || fail "two builds of one items file differ"
  cmp -s "$TMP_ROOT/a.html" "$TMP_ROOT/c.html" || fail "the build depends on where the items file lives"
  pass "the same items file always builds the same bytes"
}

test_the_sample_builds_a_valid_page() {
  local out
  "$BOARD" build "$SAMPLE" "$TMP_ROOT/page.html" >/dev/null
  assert_equals "<title>Sample plan</title>" "$(head -n 1 "$TMP_ROOT/page.html")" "the page does not open with its title"
  assert_no_grep "__FM_PLAN_BOARD_" "$TMP_ROOT/page.html" "a template slot was left unfilled"
  sed -n '/^<script>$/,/^<\/script>$/p' "$TMP_ROOT/page.html" | sed '1d;$d' > "$TMP_ROOT/page.js"
  node --check "$TMP_ROOT/page.js" || fail "the page's script does not parse"
  out=$(node "$HARNESS" "$TMP_ROOT/page.html")
  printf '%s' "$out" | jq -e '
    .error == null
      and .staticUnbalanced == []
      and ([.views[][] | .unbalanced] | flatten) == []
      and (.views | keys) == ["PB", "PR", "ROOT"]
      and ([.views.ROOT.time.svg, .views.ROOT.deps.svg, .views.ROOT.map.svg] | all)
      and ([.views[][] | .text | contains("ring = who notices it")] | all)
      and (.views.PB.cards.text | contains("Item schema") and contains("Template with four modes")
        and contains("Skill text") and contains("Cross-home plan index") and contains("Automatic reader"))
      and (.counts | contains("Your calls 2") and contains("In the fog 1") and contains("Changes ahead 3"))
  ' >/dev/null || fail "the sample board did not render every plan and mode cleanly: $out"
  pass "the sample builds a page whose every plan and board mode renders balanced markup with a legend"
}

test_changes_carry_who_notices_them_and_their_state() {
  local out
  out=$(render "$SAMPLE")
  printf '%s' "$out" | jq -e '
    (.views.PB.cards.text | contains("■ Team ◎ visible B Planned") and contains("● Public C Deferred")
      and contains("Deferred until Tue 6 Oct") and contains("▲ Agents only B Built") and contains("▲ Agents only U In the fog"))
      and (.views.ROOT.map.text | contains("●1 ■1 ▲3 · ◎1 visible")
        and contains("fog 1 · planned 1 · building 1") and contains("built 1 · deferred 1"))
      and (.views.PB.time.text | contains("Built: T1 ✓") and contains("● T6 Learner-facing notice"))
      and (.views.PB.deps.text | contains("✓ ▲ T1 · Built") and contains("■ T2 · Planned ◎"))
  ' >/dev/null || fail "the change encoding was not drawn the same way across modes: $out"
  pass "every mode marks who notices a change, whether it is visible, and its state"
}

test_a_qualifying_plan_opens_on_the_opening_page() {
  local out again
  out=$(render "$SAMPLE")
  again=$(render "$SAMPLE")
  printf '%s' "$out" | jq -e '
    .opening.hidden == false and .opening.plainHidden == true
      and (.opening.mission | startswith("“every large plan should reach me") and contains("Success:") and contains("Out:"))
      and (.opening.ruled | contains("Q3 Do plans nest?: A · Yes, to any depth") and contains("Admin portal Today: T11 sized L"))
      and (.opening.glossary | test("<li id=\"g-picture\"><b>Picture</b>.*<ul><li id=\"g-diagram\">.*<li id=\"g-photo\">"))
      and (.opening.glossary | contains("<a href=\"#g-mockup\">→ Mockup</a>"))
      and (.opening.pictures | contains("Where a saved answer goes") and contains("A call card on a phone"))
      and .opening.calls == ["Q2", "Q1"]
      and (.opening.quizOrder | length) == 6
      and (.opening.quizOrder | map(split(":")[1]) | join("")) != "012012"
      and (.concepts | contains("Mockup."))
  ' >/dev/null || fail "the opening page was not drawn in order: $out"
  assert_equals "$(printf '%s' "$out" | jq -c .opening.quizOrder)" "$(printf '%s' "$again" | jq -c .opening.quizOrder)" \
    "the quiz order changed between two renders"
  pass "a plan across two homes opens on mission, rulings, glossary, pictures, a shuffled quiz, then calls in unlock order"
}

test_a_plan_with_no_trigger_opens_on_the_ordinary_start() {
  local f out
  f=$(edit '(.items[] | select(.id == "T6") | .links) = []')
  out=$(render "$f")
  printf '%s' "$out" | jq -e '.error == null and .opening.hidden == true and .opening.plainHidden == false
    and (.next | contains("How many statuses?"))' >/dev/null \
    || fail "a one-home plan with few calls did not open on the ordinary start: $out"
  jq -n '{answers:{Q2:{item:"Q2",pick:"",note:"",unsure:true}}}' > "$TMP_ROOT/unsure.json"
  out=$(render "$f" "$TMP_ROOT/unsure.json")
  printf '%s' "$out" | jq -e '.opening.hidden == false' >/dev/null \
    || fail "a not-sure answer did not switch the plan to its opening page: $out"
  pass "a plan opens on the ordinary start until it spans two homes, has five calls, or gets a not-sure answer"
}

test_a_call_marked_unsure_requires_the_opening_page() {
  local f err out
  f=$(edit 'del(.opening) | (.items[] | select(.id == "T6") | .links) = [] | (.items[] | select(.id == "Q2") | .unsure) = true')
  "$BOARD" build "$(edit '(.items[] | select(.id == "T6") | .links) = [] | del(.opening)')" "$TMP_ROOT/plain.html" >/dev/null \
    || fail "a one-home plan with two calls and no opening did not build"
  if err=$("$BOARD" build "$f" "$TMP_ROOT/unsure.html" 2>&1); then
    fail "a plan with a not-sure call built without an opening page"
  fi
  assert_contains "$err" "this plan needs an opening page" "the refusal did not name the opening page"
  out=$(render "$(edit '(.items[] | select(.id == "T6") | .links) = [] | (.items[] | select(.id == "Q2") | .unsure) = true')")
  printf '%s' "$out" | jq -e '.error == null and .opening.hidden == false and .opening.plainHidden == true' >/dev/null \
    || fail "a plan with a not-sure call did not open on its opening page: $out"
  pass "a call recorded as not sure requires and opens the opening page"
}

test_saved_answers_come_back_as_the_decision_text() {
  local out
  out=$(render "$SAMPLE" "$SAVED")
  assert_equals "$("$BOARD" answers "$SAMPLE" "$READ_DB")" "$(printf '%s' "$out" | jq -r .copy)" \
    "the page's copy-out text and the read-back decision text differ"
  assert_contains "$(printf '%s' "$out" | jq -r .copy)" "Q1 Where does the board live? -> A: A claude.ai page with a saved store | note: go" \
    "the saved pick was not shown with its option"
  assert_contains "$(printf '%s' "$out" | jq -r .copy)" "Check U2 (answer-store) -> right" "a saved quiz answer was not read back"
  printf '%s' "$out" | jq -e '
    .writes[0].path == "answers/Q1" and .writes[0].data.pick == "B" and .writes[0].data.note == "go"
      and (.bar | startswith("1 of 2 calls answered and saved"))
  ' >/dev/null || fail "picking an option did not save one answer document: $out"
  pass "saved answers and quiz results read back as the page's own text, and a pick saves one answer document"
}

test_a_quiz_answer_teaches_and_saves_once() {
  local out
  out=$(render "$SAMPLE" "$SAVED")
  printf '%s' "$out" | jq -e '
    ([.writes[] | select(.path | startswith("check/"))] | length) == 1
      and (.writes[] | select(.path == "check/U1") | .data | .item == "U1" and .choice == 1 and .correct == false)
      and (.quizAfter | contains("Not quite. A mockup shows a screen before it is built") and contains("See A call card on a phone"))
      and (.quizAfter | contains("score") | not)
      and (.copyAfter | contains("Check U1 (board-card) -> missed"))
  ' >/dev/null || fail "a quiz answer was not saved once with its source index and explained: $out"
  pass "a quiz answer is explained at once, saved once by its source index, and never scored"
}

test_learning_is_recorded_from_evidence_only_once() {
  local record="$TMP_ROOT/what-you-know.jsonl" out
  printf '%s\n' '{"item":"U1","choice":2,"correct":false,"at":"2026-10-01T10:04:00Z"}' > "$READ_DB/check/U1.json"
  "$BOARD" learn "$SAMPLE" "$READ_DB" "$record" >/dev/null || fail "learn failed"
  jq -s -e '
    map({concept, state, evidence}) == [
      {concept: "board-card", state: "known", evidence: "call Q3 decided A"},
      {concept: "board-card", state: "to-teach", evidence: "quiz U1 missed"},
      {concept: "answer-store", state: "known", evidence: "quiz U2 right"}]
  ' "$record" >/dev/null || fail "the record did not hold one entry per piece of evidence: $(cat "$record")"
  assert_contains "$("$BOARD" learn "$SAMPLE" "$READ_DB" "$record")" "learned 0 new entries" "a rerun appended again"
  assert_contains "$("$BOARD" learn "$(edit '.round = 2')" "$READ_DB" "$record")" "learned 0 new entries" \
    "a later round appended an earlier round's quiz answer again"
  rm "$READ_DB/check/U1.json"
  out=$(render "$(edit '.opening.quiz |= map(select(.id != "U2"))')" "" --known "$record")
  printf '%s' "$out" | jq -e '(.opening.pictures | contains("to teach again")) and (.opening.ruled | contains("Where a saved answer goes: known (quiz U2 right)"))' >/dev/null \
    || fail "the opening page did not use the record: $out"
  if "$BOARD" build "$SAMPLE" "$TMP_ROOT/known.html" --known "$record" 2>"$TMP_ROOT/known.err"; then
    fail "a quiz about a known concept built"
  fi
  assert_contains "$(cat "$TMP_ROOT/known.err")" "quiz U2: concept answer-store is already known" "the refusal did not name the known concept"
  pass "the what-you-know record grows only from evidence, feeds the opening page, and keeps known concepts out of the quiz"
}

test_a_plan_items_own_links_count_like_its_contents() {
  local out
  out=$(render "$(edit '(.items[] | select(.id == "T6") | .links) = [] | (.items[] | select(.id == "PB") | .links) = [{"to": "x-hub", "why": "shares the hub"}]')")
  printf '%s' "$out" | jq -e '.error == null and (.views.ROOT.map.text | contains("Learner hub overhaul") and contains("shares the hub"))' >/dev/null \
    || fail "a link on a plan item was dropped: $out"
  pass "a link on a plan item reaches its plan's map edges"
}

test_a_plans_next_date_comes_from_what_is_still_ahead() {
  local out
  out=$(render "$SAMPLE")
  assert_contains "$(printf '%s' "$out" | jq -r .views.ROOT.cards.text)" "due Sat 3 Oct" "an open task's due date did not roll up"
  out=$(render "$(edit '(.items[] | select(.id == "T3") | .state) = "done"')")
  case "$(printf '%s' "$out" | jq -r .views.ROOT.cards.text)" in
    *"due Sat 3 Oct"*) fail "a built task still set its plan's next date: $out" ;;
  esac
  pass "a plan's next date rolls up only from what is still ahead"
}

test_item_text_renders_as_text() {
  local f out
  f=$(edit '(.items[] | select(.id == "T1") | .title) = "</script><img src=x onerror=alert(1)>"')
  out=$(render "$f")
  printf '%s' "$out" | jq -e '.error == null and (.views.PB.cards.text | contains("&lt;/script&gt;&lt;img src=x onerror=alert(1)&gt;"))' >/dev/null \
    || fail "an item title was rendered as markup: $out"
  pass "item text renders as text, never as markup"
}

test_invalid_items_are_refused_with_the_reason() {
  local f err line reason
  while IFS= read -r line; do
    reason=${line##* => }
    f=$(edit "${line%% => *}")
    if err=$("$BOARD" build "$f" "$TMP_ROOT/bad.html" 2>&1); then
      fail "an invalid items file built ($reason)"
    fi
    assert_contains "$err" "$reason" "the refusal did not name the problem"
  done <<'CASES'
(.items[] | select(.id == "T1") | .depends) = ["NOPE"] => T1: depends on unknown item NOPE
(.items[] | select(.id == "T1") | .depends) = ["T2"] => dependency cycle
(.items[] | select(.id == "Q1")) |= del(.rec) => Q1: an open call needs a recommendation
(.items[] | select(.id == "T2") | .links[0].to) = "x-missing" => T2: link to unknown plan or concept x-missing
(.items[] | select(.id == "PB") | .parent) = "T1" => PB: parent must name a plan item
.concepts[0].svg = "<svg><script>alert(1)</script></svg>" => svg must carry no script
.concepts[0].svg = "<svg/onload=alert(1)></svg>" => svg must carry no script
.concepts[0].svg = "<svg><a href=\"javascript&#58;alert(1)\"><text>x</text></a></svg>" => svg must carry no script
.concepts[0].svg = "<svg><a href=\"java\tscript:alert(1)\"><text>x</text></a></svg>" => svg must carry no script
.items += [{"id":"Z","kind":"plan","owner":"x","title":"Second root"}] => exactly one item must have no parent
(.items[] | select(.id == "T3") | .visible) = true => T3: only a public or team change can be visible
(.items[] | select(.id == "T2") | .links) = [] => T2: a visible change must link at least one mockup
(.items[] | select(.id == "Q2") | .aud) = "team" => Q2: only a task carries aud
(.items[] | select(.id == "T3") | .unsure) = true => T3: only a call carries unsure
(.items[] | select(.id == "Q2") | .unsure) = "yes" => Q2: unsure must be true or false
.opening.quiz[0].options[2] = "A chart" => quiz U1: options must have the same number of words
.opening.glossary[3].parent = "Image" => glossary term Diagram: parent Image is not a term
del(.opening) => this plan needs an opening page
CASES
  [ ! -e "$TMP_ROOT/bad.html" ] || fail "a refused build still wrote a page"
  pass "invalid items files are refused with a reason and write nothing"
}

test_the_build_is_deterministic
test_the_sample_builds_a_valid_page
test_changes_carry_who_notices_them_and_their_state
test_a_qualifying_plan_opens_on_the_opening_page
test_a_plan_with_no_trigger_opens_on_the_ordinary_start
test_a_call_marked_unsure_requires_the_opening_page
test_saved_answers_come_back_as_the_decision_text
test_a_quiz_answer_teaches_and_saves_once
test_learning_is_recorded_from_evidence_only_once
test_a_plan_items_own_links_count_like_its_contents
test_a_plans_next_date_comes_from_what_is_still_ahead
test_item_text_renders_as_text
test_invalid_items_are_refused_with_the_reason
