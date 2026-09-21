# Plan: bound SQLite writer time during coordinator recovery

Status: active for GitHub issue #179. Delete this plan in the pull request that
completes the issue.

## 1. Problem and evidence

PtcManager's SQLite database is in WAL mode, but SQLite still admits only one
writer. A writer that remains open longer than the operation wrapper's
10-second socket deadline can therefore make validation and review appear
unavailable even when CPU, memory and disk are healthy.

The first production incident on release `9dd8844` showed a 30,141 ms
`herdr_sync` transaction while retained terminal panes caused repeated
worktree statements. PR #180 removed settled-terminal worktree writes and
throttled unchanged retained-work observations. A fresh-job smoke on release
`200bb0b` then passed end to end: its operation acquired and released slot 1,
its review completed, its pull request opened, and CI passed.

The first retained continuation exposed a second path at 11:22 UTC:

- `herdr_sync` ran for 60,242 ms and rolled back;
- worktree statements attributed to that transaction took about 14–15 seconds;
- resource-operation sweeps, Oban, dispatch, publication reconciliation,
  worktree cleanup, usage sampling and a LiveView request queued or failed;
- the active operation later recovered and continued heartbeating.

The diagnostics identify the long transaction's workload, but not the exact
phase, statement sequence or concurrent transaction responsible for each
wait. The evidence establishes lock amplification; it does not yet establish
whether the underlying wait is a transaction-shape defect, WAL/checkpoint or
pager behaviour, or another connection interaction.

## 2. Safety constraints

- Do not increase timeouts as the repair.
- Preserve authoritative snapshot sequencing, worker-incarnation fencing,
  job/run/worktree coherence, operation slot fencing, exact-commit review and
  publication guarantees.
- Do not parse terminal output or trust agent claims for state transitions.
- Diagnostics must not log SQL parameters, prompts, tokens, repository paths
  or other secrets.
- Do not resume more retained production jobs while the active-continuation
  path can reproduce lock starvation. If current recovery stops, retain its
  work rather than starting over.
- SQLite remains the supported database for this repair. A database migration
  is a separate product decision, not a substitute for bounding transactions.

## 3. Work, in order

### 3.1 Reproduce the active-continuation workload

Start with a failing real-SQLite regression outside the SQL sandbox. Seed the
shape that the fresh smoke omitted:

- many settled terminal Herdr panes and retained `attention` worktrees;
- one terminal managed run whose failed job is resumed in its existing
  worktree and becomes active;
- normal Herdr reconciliation and retained-work polling;
- one queued/running resource operation with repeated heartbeats;
- one review request/handoff.

Use deterministic synchronization, not sleeps as proof. First reproduce an
unpaused workload defect: excessive writer duration, statement amplification,
or a specific SQLite pager/checkpoint mechanism must breach a small bound
without a deliberately held lock. A test-only query or phase observer may then
coordinate a competing operation and verify ownership, but a test that creates
the incident merely by pausing the writer is not a reproduction. The regression
must distinguish application work performed inside the transaction from time
spent waiting in SQLite and from pool queueing.

### 3.2 Make lock ownership and phase duration observable

Extend `PtcManager.DatabaseDiagnostics` and the Herdr sync context with bounded,
safe data:

- a correlation ID for the outer transaction;
- begin-wait, transaction, commit/rollback and phase durations;
- phase names for worker acceptance, run reconciliation, worktree
  reconciliation, heartbeat refresh, missing-run handling and absence
  resolution;
- snapshot counts by active and terminal state and changed-row counts;
- a normalized statement operation/source fingerprint for slow queries, never
  parameters;
- the age and safe workload identity of other open application transactions
  when a busy error or slow writer acquisition occurs.

Record repository SQLite settings (`journal_mode`, `synchronous`, cache size,
cache spill and WAL autocheckpoint) once at startup. Production currently
reports WAL, normal synchronous mode, a 64 MiB connection cache, cache spill
threshold near that cache size and a 1,000-page autocheckpoint. Do not run an
active checkpoint merely to collect diagnostics.

Tests must prove correlation cleanup after commit, rollback and process exit,
and prove that emitted metadata contains no query parameters.

### 3.3 Shorten the Herdr write critical section

Use the regression and diagnostics to make the smallest supported change.
Expected direction, subject to the evidence from 3.1–3.2:

1. Normalize the remote snapshot and classify existing records before taking
   SQLite's writer lock where doing so cannot mutate state.
2. Inside `BEGIN IMMEDIATE`, re-read and recheck every mutable input used by a
   precomputed decision: worker identity/snapshot sequence; run freshness,
   state and fencing token; job owner, state and review hold; and worktree
   state, error and relevant timestamps. Treat a mismatch as a stale plan and
   retry or skip the snapshot without changing admission.
3. Apply only actual deterministic transitions. Replace per-agent heartbeat
   and worktree statements with bounded bulk updates where their predicates
   are equivalent.
4. Keep the transaction free of filesystem, Herdr, GitHub, process waits and
   notifications.
5. If the snapshot cannot safely commit within one atomic unit, split it only
   at a documented fence that prevents partial data from opening admission or
   publication. Never expose a worker as online from a partially reconciled
   snapshot.

Do not disable `BEGIN IMMEDIATE` globally. It prevents stale deferred
read-to-write upgrades and remains correct for short write transactions.
Database configuration changes such as cache-spill or checkpoint tuning require
a deterministic reproduction of that mechanism and a focused test; they are
not speculative fixes.

### 3.4 Prove coordinator responsiveness

The real-SQLite regression must run repeated reconciliation cycles and assert:

- no `Database busy` or lock errors;
- a queued operation acquires a slot, enters running, heartbeats and releases
  it without exceeding the wrapper deadline;
- a review handoff completes for the exact commit;
- no slot or review lease leaks;
- terminal replay remains write-free;
- terminal → active → terminal recovery still reconciles the owner;
- synchronized adversarial changes between preclassification and writer
  acquisition cannot overwrite a newer snapshot/run, reopen admission, change
  a newer job or worktree state, release or leak a review hold, or make a commit
  publishable;
- the outer Herdr transaction remains below an explicit bound with the seeded
  retained population.

Run focused tests, `mix precommit`, and the complete `mix test`. Independently
review the implementation, especially any movement of reads outside the write
transaction and every fence rechecked inside it.

## 4. Production verification

Deploy only after CI passes. Then, without mass retrying retained work:

1. Confirm release SHA, health, active mode and an empty operation-slot set.
2. Run one disposable GitHub-backed smoke through validation, managed review,
   publication and slot release; close its pull request without merging.
3. Observe several Herdr polling cycles and require no busy errors and bounded
   transaction/query timings.
4. Resume exactly one retained continuation and observe its validation,
   heartbeat, review and publication path through several more cycles.
5. Resume remaining jobs sequentially only after the preceding job reaches a
   stable terminal or pull-request state.

If any lock wait exceeds the operation-wrapper deadline, stop recovery, retain
work, and attach the correlated phase/transaction evidence to #179. Do not
raise the timeout or restart jobs as remediation.

## 5. Completion criteria

Issue #179 is complete only when the deterministic active-continuation
regression passes, transaction ownership is diagnosable, the smallest measured
cause is fixed, repository checks pass, and production has completed both the
fresh smoke and one retained continuation without coordinator lock or heartbeat
failure. The completing pull request deletes this plan.
