---
name: plan-board
description: >-
  Agent-only v1 format for planning large changes as one nested board on a claude.ai page with a saved answer store.
  Load before planning a large change for the captain or briefing a worker to write one, before rebuilding or republishing a planning board, and when reading a planning board's saved answers back.
  Owns the item schema, the opening page and quiz, the what-you-know record, the build from one items file, and the read-back into the held task.
user-invocable: false
metadata:
  internal: true
---

# plan-board

A large plan reaches the captain as one board answerable from a phone.
The board is built, never hand-written: the writer produces only an items file and its pictures, and `bin/fm-plan-board.sh` draws every page and mode from them.
Whichever home plans uses this skill, and nothing here assumes the planning home is the home that builds.
The shipped template is `assets/plan-board-template.html`; `assets/sample-items.json` is a complete small example.

## What the board shows

- **Start:** a plan that touches two or more homes, has five or more calls, or has any "not sure" answer opens on the opening page.
  In order: the mission in the captain's words, what the captain already ruled, the glossary, the reference pictures, the understanding check, then the open calls, each shown only after the calls it depends on.
  Any other plan opens on the ordinary Start: destination, out of scope, four counts, the first picture, and the next three items.
- **Board:** one filtered item set drawn four ways.
  Cards group by plan, owner, who notices it, type or state; Timeline and What waits on what use the Today page's Charted next encodings; Map shows each plan beside the other plans and pictures it links to, with why.
  Every plan, at every depth, carries the five-part index: destination, notes, decisions so far, in the fog, out of scope.
- **Concepts:** only the pictures this plan links. **Evidence:** optional rows with sources.

Every mode draws a change the same way and shows a legend: the ring colour and ● ■ ▲ say who notices it, the fill colour and letter say the type of work, and the fill amount says the state.
A dashed ring is in the fog, a dotted ring is deferred, a half-darker fill is building, a full one with ✓ is built, a hatch is waiting, ◎ is visible, and ◆ is a call.

## The items file (fm-plan-board.v1)

Top level: `schema` ("fm-plan-board.v1"), `date` (day 0 of the Timeline), `round`, `task` (the backlog task holding the board's calls), `home` (the planning home), `items`, `plans`, `concepts`, `opening`, `evidence`.

| Item field | Holds |
|---|---|
| `id` | The source's own key: letters, digits and `_ . : @ + ~ -` |
| `parent` | The plan it sits in, to any depth; exactly one item, the root plan, has none |
| `kind` | `plan`, `call` or `task` (a change) |
| `title`, `owner`, `why` | What it is, who owns it, one line of context |
| `status` | `open` (calls only), `decided`, `parked` (in the fog) or `dropped`; calls default open, tasks decided |
| `state` | Tasks: `todo` (Planned), `underway` (Building) or `done` (Built) |
| `until` | Tasks: a date that makes it Deferred |
| `aud`, `visible` | Tasks: who notices it, `public`, `team` or `agents` (default); `visible` only on public or team, and it must link a mockup |
| `type`, `urgency`, `size` | `build plan fix content upkeep`; `now week later`; tasks sized `S M L` worker sessions |
| `options`, `rec` | Calls: 2 to 4 `{label, consequence}` (keys A to D) and the recommended key, required while open |
| `pick`, `note` | Decided calls: the captain's key and note, verbatim |
| `depends` | Calls and tasks it waits on, its blockers |
| `start`, `due` | Sourced dates only, never invented |
| `links` | `[{to, why}]` to a `plans` id or `concept:<id>` |
| `dest`, `notes`, `out`, `fog` | Plans: the index; parked items join `fog` under in the fog |

- `plans` is `{id: {title, home, owner, fact, open, url, ruled[]}}` for other plans items touch; `ruled` lists their decided calls for the opening page.
- `concepts` is the shared concept library's entries this plan uses: `[{id, kind: diagram|mockup|chart|photo, title, svg|asset, caption, used_by[]}]`.
  Copy an entry from the library rather than redrawing it, and draw a new SVG with the template's theme classes (`svg-ink`, `svg-paper`, `svg-tint`, `svg-green`, `stroke-ink`, `stroke-green`) so it follows dark mode.
  `concept:answer` (how an answer travels) is built in.
- `opening` is `{mission: {why, success[], out[]}, glossary: [{term, parent, def, related[]}], concepts: [ids], quiz: [...]}`.
  `why` quotes the captain verbatim and the mission fits one screen; "Picture" is only a parent term, with diagram, mockup, chart and photo as its children.
- A quiz holds one to three questions `{id, concept, question, options: [3], answer, why}`, each testing one concept the calls depend on, never trivia.
  The three options have the same number of words, within one; `answer` is the right option's index; the page shuffles the order with a stable seed and never keeps a score.
- Size each task to one worker session, give every open call a recommendation, link every item to the plans and pictures that explain it, put a new ask in the fog rather than widening the plan, and redraw only what changed between rounds.

## The what-you-know record

Each planning home keeps one private record at `data/what-you-know.jsonl` in its own home, never tracked.
Each line is `{concept, state: known|to-teach, evidence, at}`, and the newest line per concept wins.
Write a line only on evidence: a right quiz answer or a decided call using the concept (`bin/fm-plan-board.sh learn`), or the captain's own statement of knowing it (append by hand, quoting it as the evidence).
A missed quiz answer sets `to-teach`, and the next round redraws that concept; a miss never blocks a call.
Pass the record to every build with `--known`: the opening page lists known concepts, puts to-teach pictures first, and the build refuses a quiz question about a known concept.

## Build and publish

1. Write the items file under the task's `data/<task>/` directory, then run `bin/fm-plan-board.sh build <items.json> <board.html> --known data/what-you-know.jsonl`; it refuses an invalid file with the reason.
2. Publish `<board.html>` with the Artifact tool, declaring `capabilities: {"db": {}, "user": {}}` on the first publish, and republish every later round to the same URL.
3. Hold the calls on the board's task through `bin/fm-captain-hold.sh hold`, with the board URL in the reason.

## Read the answers back

1. Read the store, not the page, when the captain says the board is answered, a `rounds` document appears, or a sweep reaches an open board:
   `Artifact action=read_db url=<board> db_op=list collection=<c> query={"limit":1000} out_dir=<dir>` for each of `answers`, `reopen` and `check`, and `db_op=get collection=notes doc_id=general out_dir=<dir>`.
2. Run `bin/fm-plan-board.sh answers <items.json> <dir> > <dir>/decision.txt`; it prints the same text as the board's Copy answers fallback, which is also what to use when the captain pastes answers into chat.
3. Run `bin/fm-plan-board.sh learn <items.json> <dir> data/what-you-know.jsonl` to record the quiz results and decided calls.
4. Load `captain-hold-lifecycle`, then record once every open call has a pick: `bin/fm-captain-hold.sh answer <task> --decision-file <dir>/decision.txt`, adding `--release` when the held task is work that resumes.
   A call left blank or marked "not sure, draw it for me" keeps the hold and returns next round with its options drawn.
5. Update the items file: answered calls become `decided` with the captain's `pick` and `note`, change requests reopen their call or add an item in the fog, then rebuild and republish.
