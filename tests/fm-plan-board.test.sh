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
  out=$(node "$HARNESS" "$TMP_ROOT/page.html")
  printf '%s' "$out" | jq -e '
    .error == null
      and .staticUnbalanced == []
      and ([.views[][] | .unbalanced] | flatten) == []
      and (.views | keys) == ["PB", "PR", "ROOT"]
      and ([.views.ROOT.time.svg, .views.ROOT.deps.svg, .views.ROOT.map.svg] | all)
      and (.views.PB.cards.text | contains("Item schema") and contains("Template with four modes")
        and contains("Skill text") and contains("Cross-home plan index") and contains("Automatic reader"))
      and (.counts | contains("Your calls 1") and contains("Tasks ahead 3"))
      and (.next | contains("Where does the board live?"))
  ' >/dev/null || fail "the sample board did not render every page and mode cleanly: $out"
  pass "the sample builds a page whose every plan and board mode renders balanced markup"
}

test_saved_answers_come_back_as_the_decision_text() {
  local dir="$TMP_ROOT/read-db" out saved="$TMP_ROOT/saved.json"
  mkdir -p "$dir/answers" "$dir/reopen" "$dir/notes"
  printf '%s\n' '{"item":"Q1","pick":"A","note":"go","unsure":false,"at":"2026-10-01T10:00:00Z"}' > "$dir/answers/Q1.json"
  printf '%s\n' '{"item":"Q2","note":"maybe five","at":"2026-10-01T10:01:00Z"}' > "$dir/reopen/Q2.json"
  printf '%s\n' '{"note":"ship it","at":"2026-10-01T10:02:00Z"}' > "$dir/notes/general.json"
  jq -n --slurpfile a "$dir/answers/Q1.json" --slurpfile r "$dir/reopen/Q2.json" --slurpfile g "$dir/notes/general.json" \
    '{answers:{Q1:$a[0]}, reopen:{Q2:$r[0]}, notes:{general:$g[0]}}' > "$saved"
  "$BOARD" build "$SAMPLE" "$TMP_ROOT/page.html" >/dev/null
  out=$(node "$HARNESS" "$TMP_ROOT/page.html" "$saved")
  assert_equals "$("$BOARD" answers "$SAMPLE" "$dir")" "$(printf '%s' "$out" | jq -r .copy)" \
    "the page's copy-out text and the read-back decision text differ"
  assert_contains "$(printf '%s' "$out" | jq -r .copy)" "Q1 Where does the board live? -> A: A claude.ai page with a saved store | note: go" \
    "the saved pick was not shown with its option"
  printf '%s' "$out" | jq -e '
    .writes == [{path: "answers/Q1", data: (.writes[0].data | {item, pick, note, unsure, at})}]
      and .writes[0].data.pick == "B" and .writes[0].data.note == "go"
      and (.bar | startswith("1 of 1 calls answered and saved"))
  ' >/dev/null || fail "picking an option did not save one answer document: $out"
  pass "saved answers read back as the page's own text, and a pick saves one answer document"
}

test_a_view_without_a_store_offers_the_copy_fallback() {
  local out
  "$BOARD" build "$SAMPLE" "$TMP_ROOT/page.html" >/dev/null
  out=$(node "$HARNESS" "$TMP_ROOT/page.html")
  assert_contains "$(printf '%s' "$out" | jq -r .bar)" "Saving is off in this view; use Copy answers." \
    "a view with no store did not point to the copy fallback"
  assert_contains "$(printf '%s' "$out" | jq -r .copy)" "Q1 Where does the board live? -> no answer" \
    "the copy fallback did not list the open call"
  pass "a view with no store still answers through the copy fallback"
}

test_item_text_renders_as_text() {
  local f out
  f=$(edit '(.items[] | select(.id == "T1") | .title) = "</script><img src=x onerror=alert(1)>"')
  "$BOARD" build "$f" "$TMP_ROOT/text.html" >/dev/null || fail "a title with markup did not build"
  out=$(node "$HARNESS" "$TMP_ROOT/text.html")
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
.items += [{"id":"Z","kind":"plan","owner":"x","title":"Second root"}] => exactly one item must have no parent
CASES
  [ ! -e "$TMP_ROOT/bad.html" ] || fail "a refused build still wrote a page"
  pass "invalid items files are refused with a reason and write nothing"
}

test_the_build_is_deterministic
test_the_sample_builds_a_valid_page
test_saved_answers_come_back_as_the_decision_text
test_a_view_without_a_store_offers_the_copy_fallback
test_item_text_renders_as_text
test_invalid_items_are_refused_with_the_reason
