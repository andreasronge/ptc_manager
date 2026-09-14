# Plan: an operator surface for a monitoring agent

Status: planned. Companion to `collection-steward.md`. That plan describes an
automation inside the console that keeps a collection moving. This plan is
the layer underneath it: it makes the console observable and drivable from
outside, so that a coding agent run by the maintainer (Claude Code, Codex, or
a console automation) can do the monitoring job today, and so that the
steward, when it exists, has the same signals and the same verbs.

## 1. Why the interface is the first friction

The steward plan counts 56 manual console operations in two days, and says
where they were done: every one needed the database and `bin/ptc_manager rpc`,
because the signal that something had stalled was on no page. That sentence is
the friction this plan removes. Each stall was a bug in its own right, and
four have been fixed, but a monitor that cannot see the console's state or act
on it without a database session is not a monitor. Concretely, an agent that
watches the console today has these ways in:

| Surface | What it gives | Why it is not enough |
| --- | --- | --- |
| `/health` | `status` and `operational_mode` | Two fields; no runs, jobs, stops, reviews, or slot state |
| LiveView pages | Everything a person sees | Behind the session password; HTML meant for a person, not a program |
| Release RPC | Any function | The deployment script has a working form (`sudo -u ptc-manager -H bin/ptc_manager rpc`), but nothing documents it for a maintainer session, and a form run without that user and home crashes the RPC node with a `persistent_term` error and a crash dump |
| Health snapshot (`deploy/ptc-manager-health-snapshot`, every 15 minutes) | Capacity settings, live agent runs, live actions, live and recent resource operations, live jobs, journal error counts | Row lists with states and timings, no interpretation; no collection runs, stop reports, review rounds, publications, or audit events; 15 minutes stale |
| `check_health` action | Preflight that validates the snapshot and injects it as evidence; the README describes only that preflight | No default definition, no prompt, no trigger, so nothing can start it |

The steward plan's section 2 lists what went wrong; this plan is about how a
program finds out and what it is allowed to do about it.

## 2. Principles

- **A read is a projection.** The operator surface reads through the same
  context functions the LiveViews use and adds nothing to the database. It
  never runs GitHub, git, or Herdr commands on request.
- **A write is an existing button, pressed by the maintainer.** Every operator
  verb calls the public function behind a console button, with the same
  fencing, the same audit event, and an actor that names the operator. The
  operator token is a maintainer credential, equal in standing to the console
  password: an agent that holds it is the maintainer's own session, as a
  Claude Code session issuing `rpc` calls is today. There is no verb without a
  button, with one named exception: the reviewed-head merge, which no button
  offers and only a collection run enqueues, is accepted for a member of a
  live run with automatic merging because it repeats that run's own effect.
  `PLAN.md` keeps every other merge and every deployment as separate human
  decisions, so those have no verb at all: fix-and-merge, which merges a
  repaired head, stays a click, and a deployment is requested only by a click.
  Verbs the product principles reserve for a deliberate click (abandon
  retained work, cancel a run, remove a repository, edit configuration or
  profiles) are not exposed either. An autonomous steward acting without a person's
  token is out of scope here and needs its own entry in `PLAN.md`.
- **Stalls are computed, not logged.** A stall is a predicate over the tables
  the console already writes. It is shown on the dashboard, served to the
  operator surface, and given to the `check_health` agent, from one module.
- **Model output stays data.** A `check_health` agent proposes verbs. The
  console runs a proposal only when the signed-in maintainer clicks it. An
  operator agent that reads proposals through the read surface treats them as
  one more untrusted input to its own runbook; it never relays them.

## 3. Work items, in order

Each item is one or more pull requests, each with its own issue. Each item is
useful on its own, and the write surface lands only after the false signals it
would act on are fixed. The CI fix goes first because every later item adds
test files, and partition 2 currently fails about half the pushes on its own.

### 3.1 CI headroom (#92)

Partition 2 sits within three seconds of the 59-second budget since the
collections feature. Rebalance the partitions or raise the count so a new
test file cannot push it over. No product decision is involved.

### 3.2 `PtcManager.Stalls`: stall detection over existing tables

A pure module with `detect/1` (now) returning a list of
`%{kind, severity, target_type, target_id, since, detail}` structs, one
function per predicate, each tested against fixtures. The first set, taken
from the steward plan's section 3.2 and from what the maintainer's agent had
to query by hand:

| Kind | Predicate | Source |
| --- | --- | --- |
| `run_flapping` | One run has a `collection_run.paused` and a `collection_run.resumed` audit event within one minute, twice in ten minutes | `audit_events` |
| `run_idle_complete` | A run is `active`, `member_statuses/1` reports every member `closed_completed`, and the last step is older than the tick worker's one-minute reconcile | `collection_runs`, `collection_run_members`, `collection_run_steps`, `issues` |
| `run_no_progress` | A run is `active`, has no live job, no queued or running action, and no step for longer than a threshold | same, plus `jobs`, `agent_actions` |
| `stop_unacknowledged` | `Operations.unacknowledged_stopped_jobs/0`, re-exposed with the stop's age | `jobs` |
| `action_repeating_failure` | The same `action_key` failed twice in a row with the same terminal reason | `agent_actions` |
| `review_snoozing` | A review round is `queued` or `preparing` while the mode is neither `active` nor `draining`, which is when the prepare and review workers snooze; or a continuation is pending while the mode is not `active`, which is when the resume worker snoozes | `review_rounds`, `jobs`, mode |
| `review_repeated_finding` | A finding's description text appears in two consecutive completed rounds of one job; the reviewer contract has no location field, so text is the key | `review_rounds` |
| `operation_slot_orphaned` | A resource operation holds a slot with no wrapper PID and recovery has not run within a few minutes; `mark_stale_recovery_pending/2` marks after 15 seconds, and S7 happened when the marked recovery never ran, so this alarms on the recovery itself | `resource_operations` |
| `dispatch_rejected` | A `job.dispatch_rejected` audit event whose `details.reason` is not terminal (`issue_closed`) and whose job is still cancelled | `audit_events`, `jobs` |
| `publication_stuck_green` | A publication belonging to a member of a live run with `auto_merge` is mergeable with successful checks and an unchanged head, and no merge action exists; outside a run a green pull request is the maintainer's decision, not a stall | `pr_publications`, `collection_runs`, `agent_actions` |
| `agent_out_of_contact` | What `Operations.AgentHealth.needing_attention/2` already computes, re-exposed with the same thresholds | `agent_runs` |

The dashboard shows the list under a **Needs attention** heading, replacing
nothing; today's cards stay. Each row names the kind in words and links to the
page where the console's button lives. `mix ptc.demo.reset` seeds one stall so
the section is visible in the browser checkpoint.

Detectors that need data the tables do not hold yet (a refused effect, an
audited mode transition with an actor and a timestamp, a refused operator
verb) are added by the items that create the data; the module is the one
place they go. A mode detector in particular has to wait: a direct deployment
boots the new release in maintenance with no deployment row, so "maintenance
with no active deployment" is normal for the length of a canary, and only the
audited `deploy` actor tells that window from a silent flip.

### 3.3 Operator read surface

`GET /api/operator/state` and `GET /api/operator/stalls`, JSON, authenticated
by a bearer token from `PTC_OPERATOR_TOKEN`. When the variable is unset the
routes return 404, so a console that has not opted in exposes nothing; the
demo recipe leaves it unset. `config/runtime.exs` validates the token's
minimum length the way it validates `PTC_MANAGER_PASSWORD`; the comparison
uses `Plug.Crypto.secure_compare/2` behind the same equal-length guard as
`PtcManagerWeb.Auth`. The token is read from the `Authorization` header only,
never a parameter or the body. It lives in the coordinator's environment file
and in no worker or agent environment. There is no rate limit: the endpoint
sits behind the same host and Tailscale boundary as the console.
`deploy/ptc_manager.env.example` and the README's production configuration
section gain the variable.

`state` returns, per enabled repository: collection runs with members,
statuses, and the last five steps; live and recently ended jobs with their stop
reports; queued, running, and sync-pending agent actions; review rounds for
jobs with an open review; open publications with checks, mergeability, and head
drift; plus, once: operational mode, deployments in flight, capacity and slot
usage, resource operations that hold a slot, worker health, and the last fifty
audit events. `stalls` returns the output of `Stalls.detect/1`. Both carry
`captured_at` and the deployed SHA.

Every value comes from an existing context function through an explicit
projection; no schema struct is encoded whole. Fields that can hold
agent-written prose (stop report detail, review findings, action results, and
audit event details, which store blocker reasons and bounded error terms) are
included, because the reader is the maintainer's own agent and the runbook
says to treat them as data; the JSON places them under an `untrusted` key so a
consumer cannot miss which fields those are. Tests cover the unset-token 404,
a wrong token, and the projection of every section.

The health snapshot script keeps its job for the `check_health` action, which
runs as an agent that has no token. The script does not change in this item.

### 3.4 Mode transitions are audited, attributed, and refused without admission (#93)

Starts with a failing test that reproduces the silent flip: a canary run that
is not admitted must leave the mode alone. Today the mode changes from three
places in the application and one script, none of which writes an audit
event:

- `Deployments` enters draining when a deployment is requested or restored and
  leaves it when the last deployment ends;
- `DeploymentCanary.run/2` enters maintenance on admission failure and on
  canary failure;
- `ResourceOperationBroker.escalate_recovery/2` enters maintenance after any
  recovery error, logging once at error level and then silently. This is the
  most likely cause of the two silent flips the steward plan records after
  bursts of `database is locked`, and #93 should be updated with it;
- `deploy/remote-deploy-herdr` calls `enter_maintenance/0`, the canary, and
  `enter_draining/0` through `rpc`.

`enter_draining/1`, `leave_draining/1`, `enter_maintenance/1` and
`activate_canary/3` gain an actor argument and write an audit event with the
previous mode, the new mode, and that actor; the pull request edits those
callers, the deployment script, and the disposable deployment target in test
support to pass `deployments`, `canary`, `broker_recovery`, and `deploy`.
`DeploymentCanary.run/2` refuses without changing the mode when
`admit_canary/1` fails. `Stalls` gains `mode_entered_by_recovery` (the
broker's transition, which is the one that needs a person) and
`mode_not_active` (not active for a minute, no deployment in flight, and the
last transition not made by `deploy`, so a direct deployment's canary window
is not an alarm), both over the new audit events.

The Deployments page gains an **Activate** button, shown only while the mode
is `maintenance`, `Deployments.active/0` is empty, and the last audited
transition was not made by `deploy`, which runs the canary and activates as
the signed-in maintainer. The third condition matters: during a direct
deployment the script has already installed maintenance and is about to run
its own canary, and a second admission would make the script's canary fail
with `canary_already_admitted` and abort the deployment. This button is the
rescue the maintainer's agent performed twice through `rpc`. Activating the
running release is not a deployment, so `PLAN.md`'s rule that deployment
stays a human decision is untouched.

This pull request also edits the steward plan's section 5: the audit half of
its item 1 and its items 2 to 4 point at this plan; `run_events` and item 5
(review budget by diff size and the lower-effort retry) stay there.

### 3.5 Remove the false signals a monitor would act on

Two open issues make the console report a problem that is not there. A
monitor that follows the runbook would act on each of them, so they land
before any write verb does. One pull request each.

- **#19**: a retained repair reads "Out of contact" while it runs. The resumed
  action run copies the implementation run's pane name, Herdr sync resolves
  that name to the implementation run only, and nothing ever binds the pane to
  the action run. Sync must refresh every live run bound to an observed pane.
- **#84**: a repair's own push is fenced by the reconciler and a blocked head
  re-announces itself every poll. An action in flight for a pull request owns
  its head; a block announces once and keeps checks and mergeability current.

### 3.6 Remedies that are dead on arrival

The steward plan's R1, R2, S5, and #100. Without these a monitor can only
detect; the remedy is the same hand-made bundle it replaced. R1, R2 and S5
have no open issue; this item files one each with the steward plan's
reproduction. Three pull requests: approvals (R1 with S5), the worktree resume
(R2), and the repair review (#100).

- `retry_stopped_job/2` re-freezes the approval from the current issue digest
  instead of reusing the stale one (R1, A7). Direct approval does the same
  after a decision comment, so an operator need not wait for the poller.
- A dispatch rejection stores its reason as a value, requeues after the next
  issue sync unless the reason is terminal, and the job card names the reason
  in words (S5). The known causes (`issue_claimed`, the dirty bootstrap) are
  already fixed; this guards the next one. `Stalls.dispatch_rejected` moves
  from the audit event to the stored value.
- `resume_from_worktree/2`: for any failed job with a retained worktree, a new
  approval from the current digest on the same worktree and branch (R2), with
  a **Resume** button on the failed job's delivery board card next to Retry
  and Abandon. Replaces the bundle-and-helper-branch rescue.
- A repair action can request a managed review of the retained commit, or the
  repair prompt states that CI is the gate and the retained policy permits the
  push (#100).

### 3.7 Operator write surface

`POST /api/operator/commands` with the same token. `PLAN.md` says mutating
requests use application authentication, CSRF protection, and an audit
event; on this route the bearer token is the authentication, and CSRF
protection is unnecessary because a browser cannot attach the header, so the
same PR adds one sentence to that paragraph of `PLAN.md` recording the
operator token as a maintainer credential and this route as its use. Nothing
else in `PLAN.md` changes, because no verb reaches a decision it reserves.

The body names one verb, an `operator` name (at most 40 characters of
letters, digits, dot, dash and underscore, since it is rendered in the audit
UI), and arguments; the actor recorded is `operator:<name>`, so the audit trail
says which agent or person acted. The response is a projection of the result
with the same `untrusted` marking as `state`, never a whole struct, plus the
audit event written. The verbs, each with its tier from the steward plan's
section 4 and the function it calls:

| Verb | Tier | Function |
| --- | --- | --- |
| `acknowledge_stop` | 1 | `Operations.acknowledge_job_stop/2` |
| `approve_issue` | 2 | `Operations.approve_issue_directly/4` |
| `retry_stopped_job` | 2 | `Operations.retry_stopped_job/2` |
| `resume_from_worktree` | 2 | `Operations.resume_from_worktree/2` (item 3.6) |
| `decide_review` | 2 | `Reviews.decide/5` with the job's current `review_generation`, `continue` or `retry_review`; `extra_rounds` is bounded by that function's own 0 to 5 limit, and the steward plan's tier 3 for rounds beyond a profile cap applies once such a cap exists |
| `enqueue_action` | 2 | `MaintainerActions.enqueue/3` for a key the Catalog currently offers as a button on that target, so the verb admits exactly what the page does: `private_issue_analysis`, `prepare_issue`, `review_issue`, `structure_collection` for an issue; `pr_retrospective` and `repair_pr` for a publication. `merge_reviewed_pr`, which no button offers, only for a publication whose issue is a member of a live run with `auto_merge`. `repair_and_merge_pr` and the archived `prepare_merge_decision` are refused |
| `report_blocker` | 2 | `MaintainerActions.enqueue_blocked_issue_review/2` with the job id; acknowledges the stop in the same transaction |
| `decide_issue` | 2 | `MaintainerActions.enqueue_issue_decision/5` |
| `start_run`, `resume_run`, `pause_run`, `accept_run_changes` | 2 | `Collections.start/3`, `resume/2`, `pause/2`, `accept_changes/2` |
| `activate` | 1 | What the **Activate** button from item 3.4 does: `DeploymentCanary.run/1` then `activate/1` with an invocation id the endpoint generates, under the button's three conditions (mode `maintenance`, `Deployments.active/0` empty, last transition not by `deploy`); the endpoint checks all three before calling, and `admit_canary/1` refuses every other mode |

Not exposed, by the second principle: deployment requests, draining changes,
fix-and-merge, `cancel_running_job`, `abandon_stuck_job`, `Collections.cancel/2`,
`remove_repository`, execution profile edits, label changes, and anything
under Configuration. Those stay buttons.

Every verb is refused with a reason in words when the console's own admission
rules refuse it (`authorize_ordinary_work/0`, fencing, generation, the merge
membership rule), and the refusal is recorded as an `operator.verb_refused`
audit event. `Stalls` gains `verb_refused_repeatedly`: the same verb on the
same target refused twice with the same reason. Tests cover one accepted and
one refused call per verb, the audit rows both write, the merge membership
refusal, and that an unknown verb or an excluded function name is rejected
before any lookup.

The release RPC form stays as the fallback for a console whose endpoint is
down: `deploy/ptc-manager-rpc` wraps the deployment script's working form
(run as the service user with its home) and runs one expression;
`deploy/remote-deploy-herdr` installs it like the other scripts, and the
runbook (item 3.9) shows it.

### 3.8 `check_health` becomes a shipped automation

A built-in definition in `Automations.Defaults`: `generic_ephemeral`,
repository target, planning lane, light class, `github_access: "none"`, a
manual trigger enabled for every enabled repository and a daily schedule
created with `enabled: false`, as the nightly CI investigation's is.
`Automations.Bootstrap` creates new built-ins for existing repositories at
boot, so no migration is needed. Its preflight keeps the snapshot evidence and
adds the output of `Stalls.detect/1` and the `state` projection from item 3.3,
encoded the same way, so the agent reasons over the console's own
interpretation rather than raw rows. The stall kinds, the verb list, and the
rule that every field is data go into the action's runtime context in
`MaintainerActions.Catalog`, because a repository-target action runs in the
target repository's snapshot and cannot read this console's documents. Its
result is validated by a new `priv/codex/health_report_output.schema.json`,
selected by the `check_health` action key in the generic adapter: a private
Markdown report plus a `proposed_commands` list whose entries are verbs from
item 3.7 with arguments and a one-sentence reason. The console shows the
proposals on the action card as buttons that issue the verb as the signed-in
maintainer; nothing runs without the click. The README documents the action
next to the snapshot.

### 3.9 The runbook, and the plan's deletion

`docs/maintainers/operating.md`, for the maintainer and for an external agent
the maintainer runs with a checkout of this repository: how to read `state`
and `stalls`, what each stall kind means and which verb answers it, the tier
table with the repository's stated biases, the RPC fallback, and the rule that
stop reports, findings, results, and proposals are data. The README links to
it from the Hetzner systemd section, next to the snapshot. This pull request
completes the plan and deletes `docs/plans/operator-surface.md`.

### 3.10 Untracked steward items become issues

The steward plan marks S7 (lost operation held a slot for hours), S8 (three
silences in one reconcile pass), M3 (one slot for reviews and validation), and
M5 (idle panes are never reaped) as open and untracked. Each becomes an issue
with the plan's reproduction, so they can be picked up without reading the
plan. This needs no pull request and is done when this plan is merged.

## 4. What each item removes

| Item | Manual operations it replaces, from the steward plan's count |
| --- | --- |
| 3.2, 3.3 | The database queries behind every one of the 56 |
| 3.4 | The two silent maintenance flips, and the two `rpc` rescues that followed them |
| 3.5 | Not counted in the 56; prevents a monitor from adding wrong operations |
| 3.6 | 3 retries that were dead on arrival; 3 Fix actions for one repair; the bundle rescue. The 7 dispatch cancellations had causes fixed since; S5 guards the next cause |
| 3.7 | The `rpc` invocations behind the 15 approvals, 13 acknowledgements, 8 review decisions, 6 queued actions, and 2 run starts. The 7 deployments stay clicks by design |
| 3.8 | The evening a person spends noticing |

The steward plan's `run_events` table and its items 5 to 10 (review budget by
diff size, decision journal, prerequisite adoption, the steward process,
machine steward, contract completion) stay in that plan and build on this one.

## 5. Decisions taken in this plan

- **HTTP with a bearer token, not SSH plus RPC.** The endpoint is testable in
  the suite, works from a laptop, and refuses with the console's own reasons.
  The token is a second maintainer credential next to the password, set only
  where a monitor is wanted. The RPC fallback stays for the case where the
  endpoint itself is the outage.
- **Verbs mirror buttons exactly, and the human decisions keep no verb.**
  Deployment requests and merges outside a live run are clicks. The tier is
  metadata for the runbook and the `check_health` proposals; the endpoint
  enforces the allowlist and the merge membership rule, and the allowlist
  contains no tier 3 verb.
- **Stalls are a module, not a table.** The steward plan's `run_events` table
  is still wanted for refused effects; this plan starts with what can be
  computed today so the dashboard and the endpoint are useful before that
  table exists.

## 6. Non-goals

- A steward process, decision journal, or policy engine; see the steward plan.
- Any GitHub write from the operator surface. GitHub is written only by an
  agent holding an approved action or by the broker, as `PLAN.md` says.
- Replacing the health snapshot. The agent that runs `check_health` has no
  token and must keep reading immutable evidence.
- Public exposure. The endpoint sits behind the same host and Tailscale
  boundary as the console.
