Work on your own; do not wait for a human.

# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}

# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.

# Setup
You are in a disposable git worktree of alpha, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is scratch: install, run, edit, and commit freely; teardown discards it, so anything worth keeping goes in the report.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state} [at=<epoch>]: {one short line}" >> '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.status' && { [ ! -e '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/config/fleet-ledger' ] || '/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/ba7143190a89/01M3B2NFN19C6NCRXRFFVX27JW/bin/fm-fleet-ledger.sh' appended '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/config' '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.status' >/dev/null 2>&1 || true; }`
   States: working, needs-decision, blocked, paused, done, failed.
   Replace `<epoch>` with the number `date +%s` prints; a stamp that is not plain digits records no time.
   Each append wakes firstmate, so append only a phase change a supervisor would act on or one of the
   states above other than working; firstmate reads your pane for progress.
   Write every PR you mention - status line, terminal, summary - as its full https:// URL exactly as the
   forge printed it, never a bare number such as "PR 108".
   Use `paused: {why}` ONLY while deliberately idling on a known external wait you expect to clear
   on its own (an upstream release, a rate-limit reset, a scheduled window, or your own validation round); firstmate then rechecks on a long cadence instead of
   treating you as wedged. Add `until <YYYY-MM-DDTHH:MMZ>` (UTC) when you know when it clears.
   Use `blocked:` when you are stuck and need help.
5. If you hit the same obstacle twice, append `blocked [at=<epoch>]: {why}` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append `needs-decision [at=<epoch>]: {summary of options}` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   When a blocker or wait clears WITHOUT a firstmate reply, append `resolved [at=<epoch>]: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume; firstmate's reply otherwise writes it.
7. Never administer infrastructure that every lane shares; if you genuinely need it touched, append
   `blocked [at=<epoch>]: {what you need}` and stop, and firstmate arranges it.
   - The `no-mistakes` daemon serves every lane and home, so only firstmate stops, restarts, or updates it.
     Before appending `blocked:` about the pipeline, run `no-mistakes daemon status` and `no-mistakes axi status`.
     A refused or missing daemon socket, or a run record failed with a daemon error, is a real block: append
     `blocked [at=<epoch>]: {the daemon error}` and stop, even when the local run record still says running or
     fixing, because that record can be stale after the daemon exits.
     Otherwise, if the run is still running or fixing, reattach and keep going: a drive-call error, timeout,
     slow read, or generic unreachability is NOT a daemon error, because the daemon runs each round in the
     background while the call was only waiting for a read.
   - The worktree pool your own worktree came from, and the repository every lane's worktree shares:
     never create, remove, return, prune, move, or reassign a worktree or pool slot, and never write into
     a sibling slot's directory. This is administration rather than an edit, so rule 2 does not cover it,
     and it lands on lanes running right now. The act is the rule and commands are only examples - `treehouse`
     get/return/remove/prune, the equivalent on any other worktree provider or runtime backend, and
     `git worktree add|remove|move|prune`. A slot that looks unused is not evidence that it is free, and
     returning your own worktree is firstmate's job at cleanup.

# Firstmate instruction inbox
Firstmate steers you through durable message files in '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.inbox'.
When a terminal message says an instruction is waiting, and at any natural checkpoint when you are unsure, list '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.inbox'/*.msg, act on each message in numeric order, then acknowledge it: `mv '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.inbox'/NNN.msg '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/state/live-scout.inbox'/handled/`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.

# Definition of done
Write your findings to `/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T/tmp.tWWDi9e2fC/home/data/live-scout/report.md`.
Open the report with five one-line front-matter fields, in this order, before any other content:
`Question:` the question investigated, `Answer:` the direct answer, `Evidence:` the strongest proof, `Recommendation:` what to do next, and `Open captain calls:` each decision only the captain can make, or `none`.
The body below it must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, use the lavish-axi rule: arm your board with bin/fm-procevent-lavish.sh arm <artifact.html> --for <task-id>; never run lavish-axi poll yourself. Re-arm with the reply after each nonterminal round to acknowledge it, route the board feedback through your steering inbox, write needs-decision [key=board-review] with the live board URL when the captain owes a decision, and stop at session_ended or an empty End without re-arming - acknowledge that final round with bin/fm-procevent.sh handled <source-id> <sequence> to conclude and retire your board.
Before reporting done, read and follow `/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/ba7143190a89/01M3B2NFN19C6NCRXRFFVX27JW/.agents/skills/captain-hold-lifecycle/SKILL.md` and pass its shared completion gate for the report and any visual review.
When the report is complete, append `done [at=<epoch>]: {one-line conclusion}` to the status file and stop.
If your findings reveal work that should ship, say so in the report; firstmate may promote this task in place and send you ship instructions.
