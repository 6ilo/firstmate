# Fleet activity ledger

The fleet activity ledger is one append-only, line-oriented file that an outside tool can follow to see what a firstmate home is doing: tasks being dispatched, the status events workers report, PRs recorded and merged, cleanups, session starts, and away mode.
It is the supported hook for building dashboards, notifiers, or audit trails on top of firstmate without reading its private state files or its chat.
This document is the contract; treat everything it states as stable within a schema version.

## Turning it on

The ledger is off by default.
Turn it on, and off again, for one home from that home's directory:

```sh
bin/fm-fleet-ledger.sh enable
bin/fm-fleet-ledger.sh disable
```

`enable` is the supported way in.
In one locked step it marks the current end of every status log and creates the optional, local, gitignored `config/fleet-ledger` presence flag, so everything that happens from the moment the ledger is on is recorded, including activity in tasks that are already running, and nothing from before it is.
Creating that flag by hand instead (`touch config/fleet-ledger`) also turns the ledger on, but the baseline is only taken when firstmate next writes to the ledger, so status lines appended between the touch and that first write are not recorded.
`disable` takes the same lock to remove the flag, so once it returns no further record is written, not even by a producer that was already on its way.
It discards the ledger's read positions with it, so a status line appended while the ledger is off is never recorded later: turning it on again, with `enable` or a bare `touch`, records from that moment on.
The ledger files themselves are kept, so `seq` continues where it left off.

Turning the ledger on and off writes no record of its own; the ledger carries fleet activity only.
A period when it was off is therefore simply absent from it, not marked, and a reader that needs to know the ledger was following has to keep that itself.
Both commands report a failure with a non-zero exit, change the flag on the side of the transition that leaves the ledger consistent either way, and complete what a failure left half done when you re-run them.

With the flag absent, firstmate writes nothing, starts no process, resolves no path, and loads none of the ledger's own code: a producer pays shell-builtin existence tests on that flag, and nothing else.
The flag is per home and is not inherited by secondmate homes; opt each home in whose activity you want to follow.
A secondmate itself still appears in its parent's ledger as a task, including the status lines it reports to its parent.

## Reading it

The ledger is `state/fleet-ledger.jsonl` under the home.
The file appears with the first record after the ledger is turned on.
Follow it like any log, for example `tail -n +1 -F state/fleet-ledger.jsonl | jq -Rc 'fromjson? // empty'`, which also follows it across rotation.

A record is one JSON object in UTF-8, and it is complete only once its line ends with a newline.
A crash or a full disk can leave the record that was being written behind as one malformed line, so skip any line that does not parse, as the example above does; that is the only kind of line a reader has to skip.
Every string in a record is filtered to valid UTF-8 first, so bytes a status log, a task record, or a URL holds that are not valid UTF-8 never reach a reader; on a host with no working `iconv` every non-ASCII byte is dropped instead.
A reader must ignore members it does not recognize and event kinds it does not recognize, so later versions can add them without breaking it.

## Record format

Every record carries these members, in this order:

| Member | Type | Meaning |
| --- | --- | --- |
| `v` | integer | Schema version, currently `1`. A change that removes or redefines a member or event kind increments it. |
| `seq` | integer | Sequence number, starting at 1 and increasing by exactly 1 per record, across rotation. |
| `ts` | integer | Unix time in seconds when firstmate wrote the record. |
| `event` | string | The event kind, listed below. |
| `task` | string or null | The task id the event is about, or `null` for a home-level event. |

Event-specific members follow.
A member whose value is unknown or absent is `null`, never omitted.

## Event kinds

| Event | Written when | Extra members |
| --- | --- | --- |
| `session.started` | A firstmate session starts in this home and holds its session lock. | none |
| `away.entered` | The captain enters away mode (`/afk`); a refresh of an existing away posture writes nothing. | none |
| `away.returned` | Away mode ends and its record is archived. | none |
| `task.dispatched` | A worker, scout, or secondmate is launched for a task. | `kind`, `project`, `harness`, `model`, `effort`, `mode`, `yolo` |
| `task.relaunched` | A replacement worker is launched into an existing task. | same as `task.dispatched` |
| `task.status` | A line appended to the task's status log is picked up. | `state`, `at`, `key`, `text` |
| `task.pr_recorded` | Firstmate records the task's PR and starts watching it for a merge. | `pr` |
| `task.merged` | The task's work lands. | `via`, `pr` |
| `task.cleaned_up` | The task's worker and isolated copy are cleaned up after landing. | none |

Member meanings:

- `kind` is `ship`, `scout`, or `secondmate`.
- `project` is the project's directory name (the secondmate home's directory name for a secondmate), never a full path.
- `harness`, `model`, and `effort` name the worker runtime, model, and reasoning effort; `default` means the runtime's own default.
- `mode` is the delivery mode (`no-mistakes`, `direct-PR`, `local-only`, or `secondmate`) and `yolo` is `on` or `off`; both are `null` when the task has no delivery contract, such as a scout.
- `state` is the status line's leading lowercase word before its first colon, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, `resolved`, or `note`, and `null` for a line with no such word.
- `at` is the Unix time the worker stamped into the line with `[at=<epoch>]`, or `null` when the line carries no well-formed stamp.
- `key` is the line's `[key=<slug>]` correlation key, or `null` when it has none.
- `text` is the line's message after the first colon (the whole line when it has none), with the time and key stamps removed and at most 2000 bytes kept; a character that bound cut in half is dropped with the rest of the invalid bytes.
  It is always a string, so a line whose message is empty, such as `done:`, carries `""` rather than `null`.
- `via` is `pr` for a merged pull or merge request, with `pr` its URL, or `local` for a local-only landing, with `pr` null.
- `pr` is the canonical pull or merge request URL.

Example:

```json
{"v":1,"seq":41,"ts":1790113113,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":"default","effort":"low","mode":"no-mistakes","yolo":"off"}
{"v":1,"seq":42,"ts":1790113400,"event":"task.status","task":"fix-login","state":"done","at":1790113395,"key":null,"text":"PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"seq":43,"ts":1790113402,"event":"task.pr_recorded","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"seq":44,"ts":1790120001,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"seq":45,"ts":1790120050,"event":"task.cleaned_up","task":"fix-login"}
```

## Where records come from

Records are produced at the existing single places where firstmate already records each fact, never by reading chat:

- Lifecycle events come from the scripts that perform them: dispatch, PR recording, merging, cleanup, session start, and the away-mode record.
- Workers append status lines to their own log with a plain shell `echo`, so no firstmate code runs at that moment.
  The supervision watcher picks those lines up at the start of each poll cycle (every 15 seconds by default), so a `task.status` record can trail the worker's line by up to one poll interval.
  The watcher runs whenever work is under way; lines written while it is not running are picked up when it next runs.
- A lifecycle record about a task first picks up that task's unread status lines, so within one task its status records always precede the lifecycle record that follows them.
  Cleanup picks a task's remaining lines up before its status log is retired, so the last thing a task says is recorded even when it says it after the watcher's final poll.
- Opting in does not replay history: status lines already in a log when the ledger is turned on are skipped.
  With `enable` that point is when the command ran; with a bare `touch` of the flag it is the first ledger write after it.
  Turning the ledger off and on again sets a new such point, so lines appended while it was off are skipped exactly like lines from before the first opt-in.
  A status log created after that point is recorded from its first line.

## Ordering and durability

- Records appear in `seq` order, one writer at a time, and each is appended in one write.
- `ts` is when the record was written, so it rises with `seq` apart from clock adjustments; use `at` for when a worker says a status event happened.
- Status records are at-least-once: an interruption between writing a status record and saving the read position repeats that status record under a new `seq`, and an interruption at that same point on each following attempt repeats it again, with no bound on how many times.
  A reader that must act on a status event only once has to recognize the repeat itself, by the task and the line's `at` and `text`.
  Lifecycle records are written once per occurrence.
- A line is only recorded once it ends with a newline, so a worker's half-written line waits for the next pick-up.
- Records are not synced to disk individually; a machine crash can lose the most recent records.
  A record a full disk or a killed writer cut off part way stays in the file as one malformed line: the next write only ends that line with a newline, never rewrites or replaces the file, so bytes a follower already read never change under it and the next record starts on a line of its own.
  Such a fragment carries no record, and the sequence number it would have had goes to the next record, so the records a reader can parse keep their unbroken sequence.
- A record that cannot be written is reported on the producer's error output and never blocks the work itself; a write that has not finished within ten seconds is stopped and reported the same way, so a stuck ledger costs a producer that fixed bound and nothing more.
  Such an event is simply absent: `seq` has no gap for it, because a sequence number is only spent on a record that was written.
- `seq` restarts at 1 only if both ledger files are deleted.

## Size bound and rotation

When the ledger reaches 8 MiB, the next write renames it to `state/fleet-ledger.jsonl.1`, replacing any earlier one, and starts a new file; the bound and the single kept generation are fixed, with nothing to configure.
Disk use therefore stays under about twice the bound.
`seq` continues across rotation, so a reader that remembers its last `seq` can tell whether it missed records and resume from `.1` when it did.

## What it contains, and how to treat it

Every member firstmate composes itself - the event kind, the task id, the times, and every structured member listed above - is drawn from that task's own record, and deliberately carries none of this:

- No secrets, credentials, tokens, or environment values.
- No absolute paths, worktree locations, terminal or pane identifiers, or other machine-local details: `project`, for one, is a directory name and never a path.
- No task briefs, captain instructions, report contents, backlog notes, conversation text, or away-mode words.
- No wake, polling, or other internal supervision mechanics.
- No state reconstruction: the ledger is an event log, not the current state of the fleet; `bin/fm-fleet-snapshot.sh` prints the current snapshot.

A status record's `text` is the exception, and nothing filters it: it is a verbatim copy of the line the worker or firstmate appended to that task's status log, so whatever that line happened to hold - a token it echoed, an absolute path, anything at all - reaches the ledger unchanged.
The ledger therefore needs exactly the protection the home's `state/` directory needs: give its readers the same trust as readers of `state/`, keep it on the machine, and filter it yourself before publishing or forwarding any of it anywhere else.

The writer mechanics, including its read-position records under `state/`, are owned by [`bin/fm-fleet-ledger.sh`](../bin/fm-fleet-ledger.sh)'s header.
