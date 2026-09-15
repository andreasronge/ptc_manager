# Plan: the collection steward

Status: planned. A design basis for an agent inside PtcManager that keeps a
collection moving without a person at the console. It is written from two
days of doing that job by hand (2026-09-12 to 2026-09-14) for the ptc_runner
collection #1918 and its follow-ups (#1919, #1952, #1956, #1953, #1860,
#1890–#1892). Nothing here is implemented.

## 1. What the two days looked like

| Measure | Value |
| --- | --- |
| Jobs started | 41 (16 done, 19 failed, 6 cancelled) |
| Stop reports | 20: 12 `ambiguous_requirement`, 6 `environment_broken`, 2 `unsafe_to_proceed`; 18 of 20 with `progress: none` |
| Dispatch rejections that cancelled a job | 7 (`issue_claimed` 3, `worktree_changed` 2, `issue_closed` 2) |
| Review attempts | 46: 40 completed in 6.8 min on average, 6 failed after 17.5 min (timeouts) |
| Agent actions that failed | 13, of which 8 were the same blocker-report schema bug |
| Manual console operations by the maintainer's agent | 56: 15 direct approvals, 13 stop acknowledgements, 8 review decisions, 7 deployments, 6 queued actions, 3 retries, 2 profile edits, 2 run starts |
| `database is locked` errors in the console journal | 671 |
| PtcManager fixes merged on the way | 4 (#91, #95, #97, #99), plus 3 runtime rescues that no button offered |

Every one of the 56 operations was a decision a program could have made, or
a decision a person could have made in one sentence if the question had been
put to them with the two possible answers. None of them needed the console's
UI; all of them needed the database and `bin/ptc_manager rpc`, because the
signal that something had stalled was not on any page.

## 2. Frictions, grouped, with status

### 2.1 Silent stalls (the run looked healthy while doing nothing)

| # | Friction | Status | Proposal |
| --- | --- | --- | --- |
| S1 | A member whose blocker was answered was never re-admitted; the run resumed and re-paused every second. | Fixed, #95 | Keep: every pause/resume pair within one minute is an alarm, not a state. |
| S2 | Every green publication's merge was deferred forever because the publication was loaded without its repository; the deferral was logged at info and never reached the journal. | Fixed, #97 | An effect the run refuses must become a run step (`refused`, with reason) that the card shows. Info-level logging of a refused effect is a stall. |
| S3 | No second close-out after a close-out created members. | Fixed, #99 | Same rule: a run that is active with every member delivered and no pending step is an alarm. |
| S4 | The blocker report (`report_collection_blocker`) failed 8 times in a row on a schema description; the comment still landed on GitHub, the console never captured the options. | Fixed, #91 | Validate every action's output schema against the adapter's rules in the test suite (done); alarm on any action key failing twice with the same error. |
| S5 | Dispatch rejections cancel the job silently: an issue assigned by the console's own agent counted as claimed (`issue_claimed`), a stale approval digest, a dirty bootstrap (`worktree_changed`). The maintainer saw a cancelled card with a bare atom. | Fixed, #95, #105, #112; bootstrap cause fixed in ptc_runner #1953 | Dispatch now accepts the console's claim, re-freezes activity-only drift, approves retries afresh, and surfaces an unanswered rejection as a stall. |
| S6 | Two silent flips into maintenance mode, both after bursts of `database is locked`; reviews snooze forever in that mode with no card and no log line. | Fixed, #105, #108 | Every mode transition is audited with its actor, and a review left snoozing in restricted mode is surfaced as a stall. |
| S7 | A lost resource operation held the single expensive-operation slot for five and a half hours before recovery ran. | Fixed, #88, #105 | Recovery is bounded and retains diagnostics; a lost operation holding a slot is surfaced as a stall. |
| S8 | `reconcile/1` rescues exceptions and logs at warning; the merge deferral logs at info; `apply_action` swallows `{:error, _}` from the transaction. Three different silences in one pass. | Partly fixed, #105; `run_events` remains open | Existing-table stall detection exposes known refusal shapes, but a durable event for every refused reconcile branch is not implemented. |

### 2.2 Agent stops that needed a person

| # | Friction | Status | Proposal |
| --- | --- | --- | --- |
| A1 | 12 `ambiguous_requirement` stops. Each needed: read the stop report, read the issue and the code, decide, write a comment, wait for the GitHub sync, re-approve. Median turnaround by hand was about ten minutes; by a person checking in occasionally it would have been hours. | Open | The steward classifies the stop, drafts the decision with the two options and a recommendation, and either applies the default under policy (see §4) or pushes the two-option question to the maintainer. |
| A2 | The same question was asked twice on sibling issues (#1918 then #1937) because the decision lived in a comment on one issue. | Open | A decision journal per collection: every recorded decision is appended to the umbrella and injected into every member's runtime context, so an agent reads it before it can stop on it. |
| A3 | Late discovery of a prerequisite: #1919 found a defect in #1290 (became #1952) and then an architectural gap (became #1956). Each was a person filing an issue with a reproduction, adding `Blocked by`, labelling, and later re-labelling and restarting. | Open | First-class "prerequisite discovered" transition: the steward files the issue from the stop report, blocks the member on it, adopts it as a member (today only handoff and close-out created issues are adopted), runs it, and resumes the member when it merges. |
| A4 | Plan-derived issues stopped three times on public-signature questions that the plan left open (#1956), even after two codex reviews of the plan. | Open | A "contract completion" pass before the first implementation job: an agent lists every public signature, option, and closed code the plan or issue leaves unnamed and answers them in the issue body. Also let an implementer proceed on a reversible API choice under a recorded assumption instead of stopping. |
| A5 | Decisions were recorded as comments; the issue body still said the old thing, so the next agent had to reconcile them. | Open | The steward amends the issue body (a `## Decisions` section) rather than commenting; comments are for humans. |
| A6 | Auto-fix refuses any issue that already had a job (`already_attempted`), so every restart after a stop was manual. | Open | The steward owns restarts; auto-fix stays first-attempt only. |
| A7 | Re-approval binds the issue digest, so after every decision comment the operator must wait for the poller before approving, or the job is cancelled as stale. | Fixed, #112 | Dispatch re-freezes an approval when only issue activity changed and still refuses title or body changes. |

### 2.3 Resuming work that already exists

| # | Friction | Status | Proposal |
| --- | --- | --- | --- |
| R1 | `retry_stopped_job` creates a fresh job with the stopped job's approval; after an agent has assigned or commented, the digest has moved and dispatch cancels it as stale. Three such retries were dead on arrival. | Fixed, #112 | A retry receives a fresh approval after the current issue passes the same gates. |
| R2 | `Reviews.decide/5` refuses `continue` for a failed job whose review never started, and for any job in `pr_open`. The work sat in the worktree; the only way out was a hand-made commit and a git bundle. | Fixed, #114, #115 | **Resume in its worktree** handles failed and lost jobs on the same branch and worktree; PR-open repairs use the retained implementer with pull-request CI as their gate. |
| R3 | A Fix action cannot request a managed review; the retained agent then refuses to push, and only pushes while an action is live. Three Fix actions for one repair. | Fixed, #114 | Repair actions explicitly use pull-request CI as their gate and authorize the retained implementer to push. |
| R4 | Retained agents park at a prompt nobody answers; Herdr reports the pane as done; the console sees `no_commits`. | Partly handled (`unreconciled?`) | The steward reads the pane tail (`herdr pane read`) when a job reports done with no commits and decides. |

### 2.4 Reviews

| # | Friction | Status | Proposal |
| --- | --- | --- | --- |
| V1 | A 25-file diff times out at 30 minutes with an extra-high reasoning reviewer; two attempts lost, 75 minutes each. Raising the profile to 60 minutes and dropping to high effort passed in one 11-minute round. | Mitigated by hand (profiles now 60 min) | Budget by diff size; on a timeout, retry once at the next lower effort automatically; only then pause. |
| V2 | Each review round on a large change found one new narrow edge (five rounds on #1952, four on #1919). Budget 5 was enough, barely. | Working as designed | Let the steward add rounds while findings keep changing and the diff keeps shrinking; pause only when a finding repeats. |

### 2.5 Machine and Herdr

| # | Friction | Status | Proposal |
| --- | --- | --- | --- |
| M1 | `core.hooksPath = .githooks` in the shared checkout made every bootstrap dirty; two dispatches failed with a bare `:worktree_changed`. | Fixed in ptc_runner (#1953) | A bootstrap canary after every main merge: create a worktree, bootstrap, `git status` must be clean, else alarm before any job is dispatched. |
| M2 | SQLite contention: 671 lock errors in two days, Oban stager and deployment coordinator crashes, one job stopped because the wrapper could not reach the coordinator. | Partly (#79) | Move the console to a database that serialises writers properly, or route every write through one owner process. Until then, alarm on lock-error rate. |
| M3 | Review verification on the console shares the one expensive-operation slot with agent validation, so waits of 6 minutes per test run were common with two agents live. | Open | Separate slots for reviewer clones and implementer validation, or a queue that prefers short operations. |
| M4 | GitHub returned 502 and GraphQL errors on merge; a plain retry worked. | Handled by hand | Retry with backoff in the merge action. |
| M5 | Retained Herdr panes (eight idle sessions) hold memory and confuse `herdr agent list` output; nothing reaps them once the job is terminal. | Open | Reap idle panes whose job is done or cancelled after a grace period. |

### 2.6 Human-in-the-loop

| # | Friction | Status |
| --- | --- | --- |
| H1 | Hex publication and release drafts need a person, by design; the tag, draft publication, and workflow dispatch could be one console action. | Open, low priority |
| H2 | Merges were done with `gh` rather than the console's approval, so the console reconciled after the fact. Fine, but the steward should use the console's merge so the record is one. | Design rule |

## 3. The steward: goal and shape

A steward is one long-lived process per collection run (and one per repository
for the machine-level checks). It does what the maintainer's agent did by hand:
notice, diagnose, decide within policy, act through the console's own
functions, record, and escalate only when the policy says the choice is the
maintainer's.

It is not a new agent kind. It is a coordinator that uses the existing
maintainer actions and, when it needs judgement, runs bounded ephemeral agent
actions with structured outputs (the `report_issue_blocker` /
`resolve_issue_decision` pattern) rather than reasoning in the coordinator.

### 3.1 Inputs it watches

- `collection_runs`, `collection_run_steps`, `member_statuses/1`, and the
  proposed `run_events` table (§2.1 S8).
- Job stop reports (`reason_code`, `progress`, `prerequisite`, `detail`).
- Review rounds: state, failure code, duration, findings, and whether a
  finding repeats.
- Publications: checks, mergeability, head drift.
- Console health: operational mode, unacknowledged stops, resource operations
  without a wrapper PID, lock-error rate, deployments in flight.
- Machine: bootstrap canary result for the current main, disk, Herdr agent
  list, idle panes.

### 3.2 Events it must recognise

| Event | Signal | Default handling |
| --- | --- | --- |
| Member stopped: environment broken | `reason_code: environment_broken`, console health degraded at the time | Repair the environment cause if known (mode, slot, lock burst), then resume from the retained worktree. Never a fresh job. |
| Member stopped: ambiguous requirement | `reason_code: ambiguous_requirement`, `progress: none` | Draft a decision (§4). Apply if tier 1 or 2; escalate if tier 3. Record in the decision journal; amend the issue body; restart. |
| Member stopped: unsafe, prerequisite found | `reason_code: unsafe_to_proceed` or `prerequisite` set, detail names a defect elsewhere | File the prerequisite with the report's reproduction, block the member, adopt it as a member, run it first, resume the member on merge. |
| Member stopped with partial progress | `progress: partial` | Always resume from the retained worktree; if the console cannot, preserve the work (commit and bundle) before anything else. |
| Review attempt failed | round `failed`, `review_timeout`/`review_expired` | Retry once with a longer budget and the next lower effort; then pause. |
| Review findings repeating | the same finding text or location in two consecutive rounds | Pause for the maintainer with the repeated finding quoted. |
| Review budget exhausted, findings still changing | rounds == budget, last two differ | Add two rounds, once. |
| Publication green | checks success, mergeable, head unchanged | Merge through the console's action; on GitHub 5xx, retry with backoff. |
| Publication red | checks failure | Queue Fix; the repair action authorizes the retained implementer to push and uses pull-request CI as its gate (#114). |
| Close-out created members | close-out outcome `completed` | Nothing; the run adopts and continues (#99). |
| Close-out says done, parent open | close-out `needs-decision` with all criteria met | Close the parent as completed (tier 1). |
| Run active, all members delivered, no step | `member_statuses` all `closed_completed`, last step older than one poll | Alarm; queue a close-out. |
| Resume/pause pair within a minute | audit events | Alarm; stop reconciling this run until a person or the steward has diagnosed. |
| Console not active with no deployment | `/health` not active for 60 s | Run the canary and activate; audit; alarm if it recurs within a day. |
| Bootstrap canary dirty | `git status` after bootstrap non-empty | Alarm and hold dispatch for the repository until clean. |

### 3.3 Actions it may take

All through existing public functions, in order of preference:

- `Operations.acknowledge_job_stop/2`, `Operations.approve_issue_directly/2`,
  `Operations.retry_stopped_job/2`, `Operations.resume_from_worktree/2`,
  `Reviews.decide/5` (`continue`, `retry_review`, with profile and
  instructions), `MaintainerActions.enqueue/3` (`repair_pr`,
  `merge_reviewed_pr`, `report_issue_blocker`, `resolve_issue_decision`),
  `Collections.start/3`, `resume/2`, `accept_changes/2`, `cancel/2`,
  `ExecutionProfiles.save/3`, `Deployments.request/2`,
  `DeploymentCanary.run/1` + `activate/1`.
- GitHub writes only through the existing label wrapper and the trusted
  actions: issue body amendment (new), prerequisite creation (new, via a
  `file_prerequisite` action with the same schema as `create_retrospective_issue`),
  `Blocked by` lines and native sub-issue relations.
- New operations this plan still needs: `file_prerequisite/2` with adoption
  (§2.2 A3), `amend_issue_decisions/3` (§2.2 A5), and `run_events` (§2.1 S8).
  `resume_from_worktree/2` and the mode-transition audit have landed (#115,
  #108).

### 3.4 Loop

Event-driven from the same notifications the LiveViews use
(`Operations.notify_changed/1`), with a periodic pass every minute for the
health checks and a daily bootstrap canary. Every pass is idempotent and
records what it did or refused as a run event. It never holds state that is
not in the database.

## 4. Decision policy

Decisions are tiered. The tier decides who acts, not whether the decision is
recorded: every decision, including a human one, lands in the collection's
decision journal and the member's issue body.

| Tier | Meaning | Examples from the two days | Who |
| --- | --- | --- | --- |
| 1: mechanical | One correct answer given the repository's rules | Acknowledge a stop after a rescue; close a parent whose close-out found every criterion met; retry a timed-out review at lower effort; unassign the console's own login; requeue after a transient lock burst | Steward, always |
| 2: conservative default | Two defensible answers; the repository has a stated bias (fail closed, optional stays optional, no new envelope version, privacy contract stands) | Entry-effect composition (A over B); private templates unservable; V4 privacy contract stands; launcher stays optional; guardian ownership satisfies the lease rule | Steward applies the default and notifies; the maintainer can reverse within the run |
| 3: maintainer | Changes a product surface, a public contract, a release, money, or scope | Publishing to Hex; making a dependency mandatory; splitting or reordering a collection; abandoning retained work; adding review rounds beyond the profile's cap | Maintainer, from a two-option prompt the steward drafts with a recommendation |

The steward drafts tier 2 and 3 decisions with an ephemeral agent action
whose output schema is `decision_question`, `decision_options` (two to four,
each with label, description, example), `recommended_option`, `tier`, and
`evidence`. The tier claimed by the agent is advisory; the coordinator caps it
by a per-repository policy table keyed on what the decision touches
(dependency requirement, envelope version, release, scope, privacy contract).

## 5. Work items, in order

1. `run_events` (§2.1 S8). The mode-transition audit is done by #108 and
   existing-table stall detection by #105; durable refused-effect events remain.
2. **Done, #95, #105, #112:** dispatch claims and activity-only approval drift
   are handled, retries are approved afresh, and unanswered rejections surface.
3. **Done, #115:** `resume_from_worktree/2` resumes a failed or lost job in its
   retained branch and worktree. Preservation remains the recovery fallback.
4. **Done, #114:** repair actions state that pull-request CI is the gate and
   authorize the retained implementer to push.
5. Review budget by diff size and the automatic lower-effort retry (§2.4 V1).
6. Decision journal and issue-body amendment (§2.2 A2, A5).
7. `file_prerequisite/2` with member adoption (§2.2 A3).
8. The steward process itself: events (§3.2), policy table (§4), escalation
   through the existing decision UI and a push channel.
9. Machine steward: bootstrap canary, mode watchdog, lock-rate alarm, idle
   pane reaping, slot separation (§2.5).
10. Contract-completion pass for plan-derived issues (§2.2 A4).

Items 1 to 5 remove most of the manual operations counted in §1 on their own;
the steward (8) is what turns the rest from a person's evening into policy.

## 6. Non-goals

- Replacing managed reviews or the maintainer's merge authority for tier 3.
- Letting the steward edit code. It files issues, records decisions, and
  drives the console; implementation stays with implementation jobs.
- Cross-host or multi-console coordination.
