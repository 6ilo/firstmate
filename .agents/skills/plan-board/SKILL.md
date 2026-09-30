---
name: plan-board
description: >-
  Agent-only v1 format for planning large changes as one nested board on a claude.ai page with a saved answer store.
  Load before planning a large change for the captain or briefing a worker to write one, before rebuilding or republishing a planning board, and when reading a planning board's saved answers back.
  Owns the item schema, the build from one items file, and the read-back into the held task.
user-invocable: false
metadata:
  internal: true
---

# plan-board

A large plan reaches the captain as one board answerable from a phone.
The board is built, never hand-written: the writer produces only an items file and one concept picture, and `bin/fm-plan-board.sh` draws every page and mode from them.
The shipped template is `assets/plan-board-template.html`; `assets/sample-items.json` is a complete small example.

## What the board shows

- **Start:** the destination, what is out of scope, four counts, the concept picture, and the next three items with open calls answerable in place.
- **Board:** one filtered item set drawn four ways.
  Cards group by plan, owner, type or status; Timeline and What waits on what use the Today page's Charted next encodings; Map shows each plan beside the other plans, concepts and mockups it links to, with why.
  Every plan, at every depth, carries the five-part index: destination, notes, decisions so far, not yet specified, out of scope.
- **Concepts:** every picture, drawn once and linked from each item it explains.
- **Evidence:** optional rows with sources.

## The items file (fm-plan-board.v1)

Top level: `schema` ("fm-plan-board.v1"), `date` (day 0 of the Timeline), `round`, `task` (the backlog task holding the board's calls), `items`, `plans`, `concepts`, `evidence`.

| Item field | Holds |
|---|---|
| `id` | The source's own key: letters, digits and `_ . : @ + ~ -` |
| `parent` | The plan it sits in, to any depth; exactly one item, the root plan, has none |
| `kind` | `plan`, `call` or `task` |
| `title`, `owner`, `why` | What it is, who owns it, one line of context |
| `status` | `open` (calls only), `decided`, `parked` (not yet specified) or `dropped`; calls default open, tasks decided |
| `state` | Tasks: `todo`, `underway` or `done` |
| `type`, `urgency`, `size` | `build plan fix content upkeep`; `now week later`; tasks sized `S M L` worker sessions |
| `options`, `rec` | Calls: 2 to 4 `{label, consequence}` (keys A to D) and the recommended key, required while open |
| `pick`, `note` | Decided calls: the captain's key and note, verbatim |
| `depends` | Calls and tasks it waits on, its blockers |
| `start`, `due` | Sourced dates only, never invented |
| `links` | `[{to, why}]` to a `plans` entry or a concept or mockup |
| `dest`, `notes`, `out`, `fog` | Plans: the index; parked items join `fog` under not yet specified |

- `plans` is `{id: {title, home, owner, fact, open, url}}` for other plans items touch.
- `concepts` is `[{id, title, kind: concept|mockup, svg, caption}]`, with ids starting `c-` or `m-`; `c-answer` (how an answer travels) is built in.
  Draw the SVG with the template's theme classes (`svg-ink`, `svg-paper`, `svg-tint`, `svg-green`, `stroke-ink`, `stroke-green`) so it follows dark mode; the first concept is the Start picture.
- Size each task to one worker session, give every open call a recommendation, and link every item to the plans it touches and the pictures that explain it.
- Put a new ask in `parked` rather than widening the plan, and redraw only the items that changed between rounds.

## Build and publish

1. Write the items file under the task's `data/<task>/` directory, then run `bin/fm-plan-board.sh build <items.json> <board.html>`; it refuses an invalid file with the reason.
2. Publish `<board.html>` with the Artifact tool, declaring `capabilities: {"db": {}, "user": {}}` on the first publish, and republish every later round to the same URL.
3. Hold the calls on the board's task through `bin/fm-captain-hold.sh hold`, with the board URL in the reason.

## Read the answers back

1. Read the store, not the page, when the captain says the board is answered, a `rounds` document appears, or a sweep reaches an open board:
   `Artifact action=read_db url=<board> db_op=list collection=answers query={"limit":1000} out_dir=<dir>`, the same for `collection=reopen`, and `db_op=get collection=notes doc_id=general out_dir=<dir>`.
2. Run `bin/fm-plan-board.sh answers <items.json> <dir> > <dir>/decision.txt`; it prints the same text as the board's Copy answers fallback, which is also what to use when the captain pastes answers into chat.
3. Load `captain-hold-lifecycle`, then record once every open call has a pick: `bin/fm-captain-hold.sh answer <task> --decision-file <dir>/decision.txt`, adding `--release` when the held task is work that resumes.
   A call left blank or marked "not sure, draw it for me" keeps the hold and returns next round with its options drawn.
4. Update the items file: answered calls become `decided` with the captain's `pick` and `note`, change requests reopen their call or add a `parked` item, then rebuild and republish.
