# Collection runs

Status: planned on 2026-09-11, revised after two independent reviews
Scope: unattended delivery of an issue that has GitHub sub-issues, from the
first child to the verified umbrella, with reviews, bounded recovery, and one
escalation path to the maintainer
Related: `PtcManager.AutoImplementation`, `PtcManager.MaintainerActions`,
`PtcManager.Reviews`, the Planning page

## Purpose

`andreasronge/ptc_runner#1465` is one issue that plans five ordered
implementation issues plus two prerequisites. Today each child costs the
maintainer at least four clicks: prepare, approve, approve and merge, and the
retrospective. Between children nobody reads the retrospective, so the next
issue starts from a stale plan.

A **collection run** is the maintainer's single decision that a collection may
be delivered unattended. It authorizes PtcManager to admit each member when
its dependencies close, to merge a member pull request at the exact reviewed
head once CI is green, to run a handoff between members that reads the merged
retrospective and updates the remaining issues, to spend one bounded recovery
per stuck mode, and to escalate everything else through one GitHub comment on
the umbrella issue. Reviews, the publication contract, and the merge boundary
are unchanged: an agent merges only a head that PtcManager reviewed.

GitHub stays the source of truth. A collection is an issue with GitHub
sub-issues; order is GitHub's native "blocked by" relation, which PtcManager
already reads and gates admission on. PtcManager stores the run, its policy,
the membership the maintainer authorized, and the bounded steps it has spent.

## What exists

- `AutoImplementation` admits open, unassigned `ptc:ready` issues with resolved
  dependencies after each sync, once per issue, five per repository per day.
- `issue_dependencies` mirrors GitHub's `blockedBy` relation. Approval and
  admission refuse an issue with an open blocker or a cycle.
- `repair_and_merge_pr` ("Fix and merge") queues a Herdr agent that repairs,
  pushes, waits for CI, and merges one PR under the repository merge lock.
  `MaintainerActions.Sync` accepts the merge only when the merged head equals
  the authorized head, and `Publications.record_remote_status/2` ends the job.
- A stop report ends an attempt with a typed reason; the maintainer has Try
  again, Ask on the issue, and Stop. Review exhaustion pauses the job;
  `Reviews.decide/5` offers continue, retry, manual, and cancel.
- `prepare_issue` and `review_issue` leave exactly one of `ptc:ready`,
  `ptc:blocked`, `ptc:needs-decision`, or close the issue. A `needs-decision`
  result carries two to four options that the Planning card turns into a form,
  and `resolve_issue_decision` writes the answer back.
- Repository sync lists open issues and re-fetches issues it already knows
  that went missing, so a closed issue is only known if it was once open
  during a sync.

## Gaps this plan closes

1. Sync does not read `parent` or sub-issues, so an umbrella is approvable and
   auto-admittable like any other issue, and membership is unknown.
2. The children of #1465 say "Blocked by #N" in text and carry `ptc:blocked`.
   PtcManager reads neither; nothing would ever start.
3. A broker-published PR body has no closing keyword, so merging a child never
   closes its issue and the next child stays blocked forever.
4. Nothing merges without a click, nothing runs after a merge, and no agent
   result can start another action. There is no notification channel.
5. Nothing tells an issue reviewer that a too-large issue must become a
   collection instead of `ptc:ready`.

## Design

### 1. Structure from GitHub

`GitHub.Client.issue_fields/0` adds

```graphql
parent { number repository { nameWithOwner } }
subIssues(first: 100) {
  totalCount
  nodes { number state stateReason repository { nameWithOwner } }
}
```

`IssueSnapshot` projects new issue fields:

- `parent_issue_number` (integer or nil; nil for a cross-repository parent),
- `sub_issues`, a map `%{"nodes" => [%{"number", "state", "state_reason",
  "repository_full_name"}], "total" => n, "overflow" => bool}`, bounded to 100
  nodes and sorted by number,
- `structure_projected` (boolean), true only when the response carried the
  fields.

`parent_issue_number` and the sub-issue numbers with their states enter the
canonical content digest beside the blockers, so an approval or proposal made
before the structure changed is stale, as it is for dependencies today.

**Fail closed.** Every guard below treats `structure_projected == false` as
unknown and refuses, exactly as `dependencies_projected` does. Rows created
before the migration are unknown until the next sync.

Deterministic rules that follow from the fields, with no new state:

- **Collection.** An issue is a collection when `sub_issues.total >= 1`. That
  one definition is used by the approval guard, the Planning group, the badge,
  and run start.
- **Collection guard.** `Operations.current_approvable_snapshot/3` refuses a
  collection with `{:error, :issue_is_collection}` and an unprojected
  structure with `{:error, :issue_structure_unknown}`, for manual, direct,
  automatic, and collection approval. `AutoImplementation.reconcile/2`
  excludes both in its query, and `dispatch_allowed/2` re-checks the fresh
  GitHub read.
- **Membership.** The members of a collection are the numbers in the
  umbrella's `sub_issues.nodes` whose repository is the umbrella's repository.
  Their state comes from those nodes when the member has no `issues` row, so a
  child that was closed before PtcManager ever saw it open still counts. A
  cross-repository sub-issue makes the collection unrunnable
  (`{:error, :cross_repository_member}`), as does `overflow`.
- **Planning.** A collection gets a **Collection** badge with
  `completed/total`, and a member gets **Part of #N**. Collections form their
  own Planning group, **Collections**, after **Needs your decision**. The
  approve forms are not rendered for a collection.

### 2. Closing keyword in broker publications

`AppBroker.pull_request_body/3` starts with `Closes #N.` for the job's issue.
GitHub closes the issue only when the PR merges into the default branch; the
broker already publishes every PR against the repository's default branch and
verifies the base, and the test states that invariant. The advisory section
keeps escaping `#`, so review findings still cannot close anything.

### 3. Structuring a collection

A new built-in issue automation, **`structure_collection`** ("Structure
collection"): `generic_ephemeral`, `trusted_direct`, planning lane, light,
1800 s, contextual button on the Planning issue card. Its repository-neutral
default prompt asks the agent to:

- turn the plan in the issue into GitHub sub-issues when none exist, one per
  independently reviewable pull request, each with a goal, scope, and
  acceptance criteria that stand alone;
- add every ordering as a native blocked-by relation; a `Blocked by #N` line
  in the child body is welcome for readers but is not part of the contract;
- label a child `ptc:ready` when its only blockers are other children, and
  `ptc:blocked` or `ptc:needs-decision` otherwise; never label the umbrella
  `ptc:ready`;
- report `structured`, `no-changes` when the issue is small enough for one
  pull request, or `needs-decision` with options.

The Catalog runtime context carries the exact REST calls PtcManager expects,
because that is PtcManager's protocol and not a repository convention:
`POST /repos/{owner}/{repo}/issues/{number}/sub_issues` with `sub_issue_id`,
and `POST /repos/{owner}/{repo}/issues/{number}/dependencies/blocked_by` with
`issue_id`.

**Structure postflight.** Membership-changing actions (`structure_collection`,
`collection_handoff`, `collection_closeout`, and `split` results) get a
postflight that re-syncs the umbrella, every member it lists, and every issue
in `created_issue_numbers` through `Sync.sync_issue/3` with `admit: false`,
a variant that skips the automatic-implementation and collection hooks, before
the canonical cross-check runs, because the issue-target postflight refreshes
only its own target and the hooks must not admit a child in the middle of a
structure check. The reconciler runs once after the postflight finishes.

The **structure invariants** are one function used by the `structured` and
`split` cross-checks, by run start, and by **Accept changes**: every member
is in the same repository, no member is itself a collection, no `overflow`,
no dependency cycle among members, every open member carries exactly one
workflow label, and every open member's blockers are members or closed
issues. The `structured` cross-check additionally requires
`sub_issues.total >= 2`, no `ptc:ready` on the umbrella, and that every
number in `created_issue_numbers` is greater than the repository's highest
issue number recorded in the action's snapshot at enqueue time, the same
baseline the retrospective issue action uses. A mismatch fails the action, as
today.

### 4. The split guard

`prepare_issue` and `review_issue` gain the outcome **`split`**, allowed in
`allowed_outcomes`, `ActionAdapter.validate_outcome/2`, and the canonical
cross-check, which is the `structured` check above. `readiness("split")` maps
to `needs_breakdown`. Their default prompts say when to split instead of
marking ready: more than one independently reviewable deliverable, more than
one subsystem, or a change too large for one review pass; and that splitting
means performing the Structure collection work. A migration rewrites the
`system:built-in` versions so existing repositories get the rule, like
`20260904105000_add_follow_up_label_to_implementation_prompt.exs`.

Deterministic backing: automatic admission (`AutoImplementation` and a
collection run) refuses an issue whose **fresh** proposal, one whose source
digest and `source_updated_at` match the issue as `PlanningGroup.fresh?/1`
defines, says `needs_breakdown`, with `{:error, :issue_needs_breakdown}`. A
stale or absent proposal does not refuse; that keeps today's behaviour, where
automatic admission falls back to the standard profile. A maintainer may
still approve by hand.

### 5. Collection runs

Three tables.

`collection_runs`: `repository_id`, `issue_id` (the umbrella), `state`
(`active | paused | finishing | completed | cancelled`), `auto_merge` and `auto_recover`
(booleans frozen at start), `pause_sequence` (integer, incremented on each
pause), `pause_kind`, `pause_reason`, `pause_scope` (string), `paused_at`,
`actor`, `started_at`, `ended_at`, timestamps. A partial unique index allows
one run per issue in `active | paused`.

`collection_run_members`: `run_id`, `issue_number`, `issue_id` (nullable until
the member has a row), `added_by` (`start | handoff | closeout | accept`),
`inserted_at`. Unique on `(run_id, issue_number)`. This is the membership the
maintainer authorized. GitHub's `sub_issues` is compared against it on every
reconcile; a difference is structural drift (section 6).

`collection_run_steps`: `run_id`, `kind` (`admit | retry | ask_on_issue |
review_continue | review_retry | merge | handoff | closeout | escalation |
override`), `scope` (string), `agent_action_id`, `job_id`, `actor`,
`inserted_at`. Unique on `(run_id, kind, scope)`. The scope names exactly
what the bound covers:

| kind | scope |
| --- | --- |
| `admit` | member issue number |
| `retry` | stopped job id |
| `ask_on_issue` | `stopped job id:attempt:<n>` |
| `review_continue`, `review_retry` | `job id:review generation` |
| `merge` | `publication id:remote head sha` |
| `handoff` | `publication id:attempt:<n>` |
| `closeout` | `attempt:<n>` |
| `escalation` | `pause sequence:attempt:<n>` |
| `override` | the pause scope it lifts |

Action-backed steps carry an attempt number because an agent action can
fail: a failed `ask_on_issue`, `handoff`, `closeout`, or `escalation` action
allows exactly one more attempt, enqueued automatically, before the run pauses
with `action_failed`. A step and the effect it records are written in one
immediate transaction: the enqueue (`MaintainerActions.enqueue*`,
`Operations.retry_stopped_job/2`, `Reviews.decide/5`, or
`Operations.approve_collection_issue/2`) runs inside the reconciler's
transaction, so a step row exists if and only if its effect was recorded.
When a queued collection-owned action is cancelled, its step row is deleted
in the same transaction, because the effect never happened. SQLite's
immediate write lock serializes concurrent reconcilers; the unique index
makes a lost race a no-op rather than a duplicate.

**Starting a run.** The Planning card for a collection shows **Run
collection** with two checkboxes, auto-merge (default on) and auto-recover
(default on). `Collections.start/3` runs under
`OperationalMode.authorize_ordinary_work/0`, requires an enabled repository,
an open, structure-projected umbrella with at least one same-repository
member that passes the structure invariants of section 3, and no run in
`active | paused | finishing`. In one immediate transaction it inserts the
run, one member row per current sub-issue, a `handoff` step for every member
publication already merged (baseline; no handoff runs for history), an audit
event, then wakes the GitHub poller. **Pause** and **Cancel run** end the
run's authority: both cancel every queued collection-owned agent action
through `Operations.cancel_queued_agent_action/2`, deleting the cancelled
steps, and let a running one finish, because a running Herdr agent cannot be
revoked. **Resume** and **Accept changes** are overrides described in section
6. Cancel never touches a member job or GitHub.

**Reconciling.** `Collections.reconcile(repository_id)` runs after every
successful GitHub sync (beside `AutoImplementation.reconcile/2`), after
`PublicationStatusReconciler` records a status change, after
`MaintainerActions.Sync` finishes an action, and once a minute from an Oban
cron backstop, `Collections.TickWorker`, added to the crontab in
`config/config.exs`. Every entry point goes through one function that first
checks `OperationalMode.authorize_ordinary_work/0` and the repository's
`enabled` flag and returns without touching anything otherwise. It is
idempotent. For each run in `active`, in one immediate transaction, in order:

1. **Outstanding work.** Collection-owned agent actions in `queued | running
   | sync_pending` are counted. While any exists, steps 4 to 7 are skipped;
   attention checks still run. An umbrella that GitHub reports closed while a
   member is not `closed_completed` ends the run `cancelled` with reason
   `umbrella_closed`, cancelling queued actions; `completed` is reserved for
   a delivered collection.
2. **Drift.** If GitHub's member set differs from `collection_run_members`
   (a member reparented or removed, or a sub-issue added by anyone other than
   a collection action, see section 7), pause with `membership_changed`.
3. **Attention.** Classify every member (section 6). A member that needs the
   maintainer pauses the run; a member with an unspent recovery gets it.
4. **Merge.** For each member publication that is `published`, `pr_state
   open`, `remote_head_sha == head_sha`, `Reviews.publication_allowed?/2` true
   for that exact head, base, and diff digest, `checks_state in [success,
   none]`, and `mergeability == "mergeable"`: when `auto_merge` is on, the
   repository merge lock is free, and no `merge` step exists for that
   publication and head, re-read the pull request status from GitHub through
   the read-only client, and only when that fresh read still satisfies every
   condition enqueue **`merge_reviewed_pr`** (section 7) with actor
   `system:collection` and record the step. The head is immutable, so its
   check results cannot change underneath the merge agent except by a re-run,
   and the postflight proves that exactly that head was merged. What remains
   a prompt boundary is the agent's own reading of CI before it merges, the
   same boundary the manual button has today. A publication with
   `checks_state failure`, `conflicting`, or a remote head that differs from
   the verified head is never repaired automatically; it pauses with
   `child_merge_blocked`, because a repair produces a head PtcManager has not
   reviewed.
5. **Handoff.** For each member publication that is `merged` without a
   `handoff` step, in ascending publication id, enqueue `collection_handoff`
   on the umbrella with the merged PR in its snapshot and record the step.
   Only one is enqueued per reconcile, and step 1 keeps the next one waiting.
6. **Admission.** Admit every member that is open, `ptc:ready`, unclaimed,
   has resolved dependencies, has no prior job, no linked publication, and no
   fresh `needs_breakdown` proposal, through
   `Operations.approve_collection_issue/2`. That is `do_approve_issue/5` with
   mode `:collection`, actor `system:collection`, decision
   `start_implementation_collection`, and an `admit` step. It keeps every
   other gate; the run replaces the repository auto-fix policy and its daily
   limit. Capacity still bounds concurrency.
7. **Close-out.** When every member is closed with state reason `completed`
   and no `closeout` step exists, enqueue `collection_closeout` on the
   umbrella and record `closeout` `attempt:1`. A member closed for another
   reason pauses with `child_closed_without_completion`.
8. **Finishing.** When every member is `closed_completed`, the close-out
   action has ended `needs-decision` or `no-changes`, and no collection-owned
   action is outstanding, the run moves to `finishing`. It ends `completed`
   when GitHub reports the umbrella closed, which is the maintainer's
   decision, made through the close-out's decision form or by hand. A run in
   `finishing` admits nothing and merges nothing; **Cancel run** ends it if
   the maintainer keeps the umbrella open on purpose.

For a run in `paused`, the reconciler re-evaluates the recorded pause
condition (section 6) and moves the run back to `active` when it no longer
holds or an `override` step names its scope.

### 6. Member classification, bounded recovery, escalation

A member is classified from its latest job, that job's publication, its
issue row, and its sub-issue node, into exactly one of: `not_started`,
`blocked_by_dependency`, `in_progress`, `attention`, `pr_open`, `merged`,
`closed_completed`, `closed_other`. `attention` carries a reason from the
table below. Detection and pausing always run; only the automatic step in the
middle column depends on `auto_recover`, and a run with `auto_recover` off
pauses at the first row instead of spending it.

| Condition on a member | Automatic step, once per scope | Pause kind |
| --- | --- | --- |
| Stop report `missing_prerequisite` or `environment_broken` with `progress: none` | `retry` via `Operations.retry_stopped_job/2` | `child_attempt_failed` |
| Stop report `ambiguous_requirement` | `ask_on_issue` via `MaintainerActions.enqueue_blocked_issue_review/2` | `child_needs_decision` once `ptc:needs-decision` lands |
| Stop report `unsafe_to_proceed`, or `progress: partial` | none | `child_attempt_failed` |
| Job `failed`, `lost`, or `cancelled` without an actionable stop report | none; `lost` has an unknown outcome and `failed` may hold commits worth keeping | `child_attempt_failed` |
| `review_state == "paused"` and `Reviews.retry_available?/1` | `review_retry` via `Reviews.decide/5` `retry_review` | `child_review_held` |
| `review_state == "paused"` from exhaustion | `review_continue` via `Reviews.decide/5` `continue`, two extra rounds, `strong` profile | `child_review_held` |
| `review_state == "manual"` | none; a takeover is a maintainer decision | `child_review_held` |
| Job `publish_blocked` | none | `child_publication_blocked` |
| Publication open with failing checks, conflict, or a remote head that is not the verified head | none | `child_merge_blocked` |
| Merge action ended `repair-blocked` or failed | none | `child_merge_blocked` |
| Member labelled `ptc:needs-decision`, or `ptc:blocked` with no open blocker | none | `child_needs_decision` |
| Member closed with a state reason other than `completed` | none | `child_closed_without_completion` |
| Any collection-owned action ended `failed` (ask-on-issue, handoff, close-out, escalation) | none | `action_failed` |
| Handoff or close-out ended `needs-decision` | none | `umbrella_needs_decision` |
| GitHub membership differs from `collection_run_members` | none | `membership_changed` |

The pause scope is the member number plus the job, publication, or action id
the condition was observed on. Pause conditions clear deterministically:

- `child_attempt_failed`: the member has a job newer than the scoped one, is
  closed, or has an open publication;
- `child_review_held`: the scoped job's review state is neither `paused` nor
  `manual`, or a newer job exists;
- `child_publication_blocked`: the scoped publication left `blocked`;
- `child_merge_blocked`: the scoped publication is no longer open, or its
  remote head changed (a manual **Fix and merge** does both);
- `child_needs_decision`: the member is `ptc:ready` or closed;
- `child_closed_without_completion`: the member is open again or closed as
  `completed`;
- `action_failed`: a newer action with the same key and target ended `done`;
- `umbrella_needs_decision`: the umbrella no longer carries
  `ptc:needs-decision`;
- `membership_changed`: never on its own, and **Resume** is not offered for
  it; only **Accept changes**, which rewrites `collection_run_members` from
  GitHub and records an `override`. It refuses to drop a member that has an
  active job or an open publication, and the accepted set must pass the
  structure invariants of section 3.

**Resume** is an override, not a bypass: it records an `override` step whose
scope is the current pause scope and lifts that one pause. The reconciler will
not pause again for the same scope; a new job, head, generation, or action
makes a new scope and is judged afresh. Overriding `action_failed` does not
skip the work: the next reconcile enqueues the failed action's next attempt
if one is left, and pauses again otherwise. The Planning card shows the pause
kind, the member, and what would clear it.

**Escalation.** Pausing records the pause atomically and marks the escalation
pending; the reconciler enqueues **`report_collection_blocker`** on the next
pass in which no other umbrella action is queued, running, or synchronizing,
because issue actions are unique per target. It is an umbrella issue
automation (`trusted_direct`, planning lane, outcome `needs-decision` only,
modelled on `report_issue_blocker`). Its snapshot pins the allowed
outcome, the member number, PtcManager's own reason text, and the console
URL. The agent posts one comment on the umbrella and applies
`ptc:needs-decision` with two to four options, so GitHub notifies the
maintainer by email and the umbrella returns through Planning's decision form.
The `escalation` step is scoped by pause sequence and attempt; when the action
fails, one more attempt is allowed, and the console card carries the reason
regardless, as the fallback notification. Answering through the form runs
`resolve_issue_decision` on the umbrella; the collection guard makes a
`ptc:ready` umbrella harmless. Every pause kind other than
`umbrella_needs_decision` clears from the member condition above, so
answering the escalation question does not by itself resume a run whose
member is still stuck; the card says which one.

### 7. Merge, handoff, and close-out automations

**`merge_reviewed_pr`** ("Merge reviewed pull request"): pull-request target,
`retained_pr_repair` profile, `trusted_direct`, writing lane, heavy, lock
`repository_merge`, outcomes `repaired | repair-blocked` (reusing the repair
result contract), no contextual button. The runtime context names the exact
authorized head and forbids any push: mark the draft ready, wait for required
checks, merge that head, or report `repair-blocked`. The existing postflight
already accepts a merge only when the merged head equals the authorized head.
The manual **Fix and merge** button is unchanged; its prompt gains "If the
pull request is a draft, mark it ready for review before merging", which
broker drafts need today.

**`collection_handoff`** ("Collection handoff"): umbrella issue target,
`generic_ephemeral`, `trusted_direct`, planning lane, 1800 s, outcomes
`completed | no-changes | needs-decision`, `created_issue_numbers` allowed
with `completed`. Runtime context: the merged PR number and head, the member
number, the umbrella number, every open member with its labels and blockers,
and a `protected_issue_numbers` list of members with an active job or open
publication. The default prompt asks the agent to read the merged pull
request's description and retrospective, then:

- update the open, unprotected members whose assumptions the merged work
  changed;
- when the retrospective names a defect or a small fix the next member
  depends on, create one fix-up sub-issue of the umbrella with `ptc:ready` and
  blocked-by relations that place it before its dependents; never push code;
- create an ordinary issue for follow-up work that does not affect the
  collection only when it is concrete and not already tracked;
- never edit a closed or protected issue, never change the umbrella's labels,
  never merge.

Postflight: the structure postflight from section 3, then the content
digests of the protected members are compared with the snapshot taken at
enqueue time and the action fails on any change; each number in
`created_issue_numbers` that GitHub reports as a sub-issue of the umbrella is
appended to `collection_run_members` with `added_by: handoff`; a created
number that is not a sub-issue is an ordinary follow-up and joins nothing.
Only numbers created by the action can join, so a sub-issue added by hand
during the run is drift.

**`collection_closeout`** ("Collection close-out"): same shape, outcomes
`needs-decision | no-changes | completed`, `created_issue_numbers` allowed
with `completed`. The agent checks the umbrella's acceptance criteria against
the default branch in its read-only snapshot and posts one summary comment.
It reports `needs-decision` with options such as "Close #N as completed" and
"Keep it open" when the criteria are met or when it cannot tell; `completed`
when it created the missing sub-issues with `ptc:ready` (cross-check: every
created number is a sub-issue; they join the members with `added_by:
closeout` and the run continues); `no-changes` when nothing remains and the
umbrella is already closed. It never closes the umbrella itself; closing is
the maintainer's answer to the decision form. Model output decides nothing
here: it proposes, and the deterministic completion rule in section 5 ends
the run.

### 8. Existing key lists

Every list that names action keys is extended for the four new keys and
`merge_reviewed_pr`: `@issue_maintenance_action_keys`, the preflight
synchronization and snapshot capture in `MaintainerActions`, decision
validation in `ActionAdapter`, `created_issue_numbers` validation, the
`Catalog` builders and `pull_request_actions/1` filter (the merge action has
no button), `DeliveryLane` and `AgentHealth` labels, and the Automations page
copy for the new profiles. The implementation greps for `"review_issue"` and
`"repair_and_merge_pr"` and treats every hit as a checklist.

### 9. Documentation

README gains a "Collections" subsection under the Planning page: what a
collection is, the run form, the four buttons, the two policy flags, the
recovery table, and how to bring an existing plan issue such as #1465 under a
run (Structure collection, then Run collection). PLAN.md principle 1 records
that a collection run is a recorded policy that authorizes bounded admission
and exact-head merging of its members. This plan is deleted by the pull
request that completes it.

## Out of scope

- Cross-repository members or parents.
- Automatic repair of a member pull request before merging; a repaired head
  is unreviewed, so it waits for the maintainer.
- A broker-side merge through the GitHub App token.
- Notifications other than GitHub comments.
- Deploying anything after a merge.
- Revoking a running Herdr agent when a run is paused or cancelled.

## Implementation order

The work lands in one pull request, as requested, but as ordered commits that
each pass `mix precommit`, so a reviewer can bisect and a partial revert stays
consistent:

1. Sync and schema: migration for the issue fields, client query, snapshot,
   digest, collection guard, auto-fix exclusion, fresh `needs_breakdown`
   refusal, Planning badge and group. Tests in `github_client_test`,
   `github_sync_test`, `operations_test`, `auto_implementation_test`,
   `planning_group` tests.
2. Closing keyword in the broker body; `reviews_test` body assertions.
3. Automations: `structure_collection`, `merge_reviewed_pr`,
   `collection_handoff`, `collection_closeout`, `report_collection_blocker`
   in `Defaults`, Catalog builders and runtime contexts, outcome validation,
   structure postflight and cross-checks, `split` for prepare and review,
   prompt migration, key lists. Tests in `maintainer_actions_test` and
   `automations_test`.
4. Collection runs: migrations, `PtcManager.Collections` (start, pause,
   resume, accept changes, cancel, reconcile, classify, steps),
   `Operations.approve_collection_issue/2`, reconcile hooks, the cron entry
   and `Collections.TickWorker`. Tests in a new `collections_test` covering
   each reconcile branch, each recovery row, each pause clear, the override,
   drift, baseline handoffs, the outstanding-work gate, and the step bound
   under a simulated concurrent reconcile.
5. Planning UI: run form and buttons, pause display; `dashboard_live` tests.
6. README and PLAN.md; delete this plan.

## Risks

- **Sub-issue and dependency REST endpoints** must be available to the
  worker's `gh` token; the structure action fails closed when they are not,
  and the cross-check reports it.
- **Two members merging close together**: the merge lock serializes the
  actions, and the second may find its head no longer mergeable. It reports
  `repair-blocked`, the run pauses with `child_merge_blocked`, and the
  maintainer's **Fix and merge** clears it. This is the price of merging only
  reviewed heads.
- **A handoff that edits the next member** moves its content digest.
  Admission happens after the handoff, so the frozen job body is the updated
  one. Protected members cannot be edited without failing the action.
- **Test partition budget.** New test files reshuffle partitions; keep the new
  suites fast and tag any real-filesystem test `:nightly`.
