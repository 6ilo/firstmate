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
You are in a disposable git worktree of demo, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is scratch: install, run, edit, and commit freely; teardown discards it, so anything worth keeping goes in the report.

# Rules
1. Never push to any remote and never open a PR. On a Claude worker a hook also refuses `git push` and discarding git commands.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state} [at=<epoch>]: {one short line}" >> '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.status' && { [ ! -e '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/config/fleet-ledger' ] || '/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/9a37bdc8217c/01M7RDKWA137TH975KRHRSX6DB/bin/fm-fleet-ledger.sh' appended '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/config' '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.status' >/dev/null 2>&1 || true; }`
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
8. Hold a machine-wide heavy slot for every heavy command, because heavy runs across the whole fleet share two slots by default.
   - Heavy: a no-mistakes validation run until it reaches its CI step, pixel or visual gates, full verify scripts,
     Playwright or any headless browser, full or multi-package test suites (vitest, jest, pytest, bin/fm-test-run.sh
     families) and full-suite walks, production builds, cold dependency installs, and local model runs.
     Not heavy: single affected test files, lint, one-package typecheck, git, CI waits, reading, and editing.
   - Before a heavy command, run `'/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/9a37bdc8217c/01M7RDKWA137TH975KRHRSX6DB/bin/fm-heavy-slot.sh' acquire --task 'scout-1' --home '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV'`; before starting a validation run,
     acquire first, then re-run the same acquire with `--run <run-id>` once the run id is known.
   - Release with `'/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/9a37bdc8217c/01M7RDKWA137TH975KRHRSX6DB/bin/fm-heavy-slot.sh' release --task 'scout-1' --home '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV'` when the heavy command finishes or the validation run
     reaches its CI step.
   - When a check finishes, close the Playwright browsers and preview tabs it opened.
   - A refused acquire (exit 3) names its reason: never run the heavy command anyway; append
     `paused [at=<epoch>]: waiting for a heavy validation slot`, then retry with `--wait <secs>` and append
     `resolved [at=<epoch>]: heavy validation slot acquired` once it succeeds.

# Firstmate instruction inbox
Firstmate steers you through durable message files in '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.inbox'.
When a terminal message says an instruction is waiting, and at any natural checkpoint when you are unsure, list '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.inbox'/*.msg, act on each message in numeric order, then acknowledge it: `mv '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.inbox'/NNN.msg '/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/state/scout-1.inbox'/handled/`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.

# Definition of done
Write your findings to `/var/folders/b9/s6ct4lbj0ys1bhnjr43rp0cm0000gn/T//fm-lab.ZKtBmV/data/scout-1/report.md`.
Open the report with five one-line front-matter fields, in this order, before any other content:
`Question:` the question investigated, `Answer:` the direct answer, `Evidence:` the strongest proof, `Recommendation:` what to do next, and `Open captain calls:` each decision only the captain can make, or `none`.
The body below it must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow `/Users/anwulikaanigbodesktop/.no-mistakes/worktrees/9a37bdc8217c/01M7RDKWA137TH975KRHRSX6DB/.agents/skills/captain-hold-lifecycle/SKILL.md` and pass its shared completion gate for the report and any visual review.
When the report is complete, append `done [at=<epoch>]: {one-line conclusion}` to the status file and stop.
If your findings reveal work that should ship, say so in the report; firstmate may promote this task in place and send you ship instructions.
