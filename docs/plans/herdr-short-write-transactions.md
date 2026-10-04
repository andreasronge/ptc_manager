# Plan: reconcile Herdr snapshots with a write-only critical section

Status: planned. Primary-fix work under the SQLite contention investigation in
#179. Delete this plan in the pull request that completes its implementation
issue.

## 1. Finding

`PtcManager.Herdr.Sync` receives a remote snapshot, then opens one
`BEGIN IMMEDIATE` transaction before it reads or classifies any durable state.
The transaction intentionally protects a coherent transition across workers,
agent runs, jobs, worktrees and audit events, but it also acquires SQLite's only
writer slot before those decisions are known.

The diagnostics deployed in PR #183 reproduced the problem with no active job
or resource operation. At 12:57 UTC, transaction 359 showed:

- `herdr_sync` held the writer slot for 20,078 ms;
- `existing_run_lookup` consumed 9,661 ms;
- `run_reconciliation` consumed 10,412 ms;
- two `agent_runs` reads inside that phase consumed 5,378 and 4,997 ms;
- a competing writer reached its 15-second busy timeout and identified
  transaction 359, then in `run_reconciliation`, as the open owner;
- SQLite was in WAL mode with normal locking and synchronous settings, a
  64 MiB connection cache, cache spill near that size and a 1,000-page WAL
  autocheckpoint.

The exact scheduler/driver interaction that stretched those reads is not a
correctness dependency of the repair. A successful Herdr snapshot currently
performs mutable-state discovery after taking the writer slot; therefore any
pause in Ecto, Exqlite or the process itself amplifies into global writer
starvation. The primary fix is to make the locked section write-only and
bounded by actual transitions, independent of why a process might pause.

## 2. Guarantees that must not change

- A snapshot is accepted only for the current worker and Herdr incarnation and
  an advancing authoritative sequence.
- A worker is not visible as online for a snapshot unless all accepted
  run/job/worktree transitions commit atomically with that snapshot.
- An observation started before a resume, review hold, newer fencing token,
  action attempt or worktree decision cannot overwrite that newer state.
- Missing-agent resolution remains a two-observation process where currently
  required, and outage/incarnation recovery continues to retain work.
- A terminal pane may become active and terminal again; settled history is not
  rewritten, but an active owner is still reconciled.
- Review and publication remain tied to their exact job attempt and commit.
- Filesystem, Herdr, GitHub, subprocess and notification work never occurs in a
  database transaction.

SQLite writes necessarily take a writer lock. “Write-only critical section”
means eliminating discovery and classification from that lock, not pretending
that writes can be lock-free.

## 3. Design

### 3.1 Separate normalization, projection, planning and application

Refactor synchronization into four explicit stages:

1. **Normalize** the untrusted Herdr response into validated, repository-neutral
   observation structs. This remains pure and occurs before database access.
2. **Project** only the durable rows relevant to this snapshot using ordinary
   reads, outside a transaction holding the writer slot.
3. **Plan** deterministic transitions from the observation and projection in a
   pure `PtcManager.Herdr.SnapshotPlan` module. A plan carries safe guards for
   every mutable fact on which each transition depends.
4. **Apply** the plan in `BEGIN IMMEDIATE` using inserts and conditional writes
   only. No `SELECT` is permitted between successful begin and commit.

The plan is data, not authority. Application validates each guard against the
current database state through the write predicate. If any expected row count
or uniqueness result differs, the whole transaction rolls back as
`:stale_snapshot_plan`.

After a stale-plan rollback, rebuild the projection and plan once. A second
conflict skips the polling cycle without degrading the worker; the next Herdr
poll is the normal retry. Busy acquisition likewise skips the cycle under the
existing rule.

### 3.2 Keep the projection bounded

Do not load every historical run for the worker. The projection consists of:

- the session's worker row;
- the latest runs for external keys present in the snapshot;
- non-terminal runs for that worker, needed to detect disappearance;
- jobs and worktrees referenced by those runs, plus reconciling jobs leased to
  the worker;
- managed job attempts and action attempts parsed from newly observed names;
- possible shared-pane and duplicate action runs for observed identities.

Use a small fixed set of joined/bulk queries. Its size may grow with observed
or currently active agents, but not with the 493 historical runs currently in
production. Preserve the existing “latest inserted run wins” rule explicitly.

### 3.3 Fence the write-only transaction

The first write reserves acceptance of the snapshot by conditionally changing
(or inserting) the worker row. For an existing authoritative worker, its
predicate includes the worker key, current/previous incarnation IDs, snapshot
sequence, status and healthy-snapshot count used by classification. A zero-row
result means the plan is stale. The updated worker is still invisible until
commit, so it cannot advertise online before the rest of the plan succeeds.

Every subsequent transition uses the minimum complete compare-and-swap guard:

- agent run: id, current state, fencing token, ownership IDs and the identity
  fields used by the decision;
- job: id, state, fencing token, lease owner, review state and absence/reconcile
  timestamps used by the decision;
- worktree: job id, current state, workspace/error/touch fields used by the
  decision;
- action run: id, state, action id, fencing token and worker;
- heartbeat bulk updates: ids grouped by the expected active state, with the
  affected count required to equal the plan;
- audit rows: inserted only after the guarded transition they describe has
  affected exactly one row.

Some decisions depend on absence or ordering rather than fields of one
projected row. The applier must fence those phantoms too. After reserving the
worker and before applying transitions, run write-only predicate assertions
against that reserved worker row (for example, a zero-increment guarded update
whose `WHERE` contains `NOT EXISTS`). Require one affected worker row for:

- no newer run for each projected external key or managed attempt;
- no newly active, unobserved run before marking an attempt missing;
- no newly matching shared-pane or duplicate action run;
- every other nonexistence fact named by the plan.

These assertions observe the database after `BEGIN IMMEDIATE`, without a
`SELECT`, and rollback before any transition if the projection is obsolete.
Add the supporting compound/partial indexes; an assertion may not hide a scan
of historical runs while holding the writer slot.

An expected transition that affects zero or too many rows aborts the complete
snapshot. Intentional no-ops are represented as no transition, not as an
unchecked failed write. New run insertion is protected by the reserved worker
snapshot and latest-run assertions; a uniqueness conflict is also a stale-plan
rollback.

Use one shared CAS/assert/apply helper rather than copying conditional-update logic.
The helper returns typed outcomes and never converts a constraint or database
error into success.

### 3.4 Make the steady state one short write

For a snapshot containing only already-settled terminal panes:

- the projection and settled-owner classification happen before `BEGIN`;
- no run, job or worktree statement is planned;
- the write transaction contains only the guarded worker heartbeat/sequence
  write and commit.

For active agents, bulk heartbeat refresh remains one statement, while actual
state changes add guarded run/job/worktree writes. Missing-run, absence,
incarnation-change and degraded-transport plans remain atomic but are bounded
by active/reconciling records rather than all history.

Do not split one accepted snapshot across commits and do not mark the worker
online in a preliminary transaction. Those alternatives create a visible
partially reconciled snapshot and can reopen admission incorrectly.

### 3.5 Preserve diagnostics

Emit a telemetry event after planning and before writer acquisition with safe
counts: observed active/terminal agents, relevant projected rows, and planned
inserts/updates/no-ops by entity. Extend the existing transaction summary with
actual affected-row counts. No IDs, names, paths, SQL parameters or prompt
content are logged.

The planning event also provides deterministic synchronization for concurrency
tests; tests attach a telemetry handler rather than adding a production sleep
or test-only callback.

## 4. Tests first

### 4.1 Query-shape regression

On a migrated, file-backed SQLite database outside the SQL sandbox, seed:

- at least 500 historical terminal runs;
- 15 retained settled panes with attention worktrees;
- one active retained continuation with a resource-operation heartbeat;
- one reconciling/review-held job and one shared action pane.

Count telemetry statements by transaction correlation ID. Before the refactor,
the regression must show reads inside the immediate transaction and growth
from historical rows. Afterward it must assert:

- zero `SELECT`/`PRAGMA` statements between begin and commit;
- a settled replay performs one worker write and no run/job/worktree writes;
- projection query and result counts do not grow with unrelated history;
- `EXPLAIN QUERY PLAN` for projection and write-side phantom assertions uses
  the intended compound/partial indexes and does not scan historical
  `agent_runs`;
- active heartbeat writes are bulk and planned/affected counts agree.

Run the same projection against materially different history sizes as a
secondary scaling check. Use statement counts, query plans and phase boundaries
as the deterministic regression, not a wall-clock threshold alone.

### 4.2 Stale-plan interleavings

Pause on the post-plan telemetry event, mutate state through its owning public
context on another connection, then release application. Cover independently:

- a newer worker snapshot sequence and a worker-incarnation change;
- job resume with a newer fencing token/lease owner;
- review becoming held or being released;
- agent run terminal → active and replacement-run creation, including a newer
  run inserted without changing the projected old run;
- worktree moving to unrelated `attention`, terminal or removed state;
- an action attempt changing owner/state;
- a new shared-pane or duplicate-action candidate appearing;
- a previously absent active run appearing before missing-run application;
- absence observation advancing between plans.

Each old plan must roll back completely: no worker heartbeat/sequence advance,
no partial audit row, no run/job/worktree overwrite, no lease release and no
publication eligibility change. The rebuilt plan may apply only if it reflects
the new state.

### 4.3 Contention and lifecycle regression

Use a real multi-connection SQLite pool and a controlled workload whose
transaction and busy-timeout bounds are fixed by the test. Repeatedly run the
retained snapshot while operation acquisition/heartbeat/release, Oban polling
and review handoff write concurrently. Assert that this bounded workload
produces no busy result, no leaked operation or review slot, and a bounded
number of queued checkouts. This is a regression for the reproduced shape, not
a claim that arbitrary external lock holders can never cause SQLite contention.
Keep elapsed time only as a generous wrapper-deadline assertion; correctness is
established by transaction shape and state, while production observation is
the final contention evidence.

Retain all existing Herdr cases, especially incarnation quarantine, stale
snapshot versus resume, retained PR recovery, attention preservation,
terminal → active → terminal reconciliation, shared panes and two-snapshot
absence confirmation.

## 5. Delivery and production proof

Implement as one focused issue, but commits may land in this order: failing
query-shape/concurrency fixtures; pure projection/planner; guarded applier;
successful/degraded-path conversion; cleanup and documentation. Do not change
pool size, busy timeout, WAL/checkpoint or cache settings in this issue, so the
production result measures transaction structure rather than a configuration
change.

Run focused tests, `mix precommit` and complete `mix test`. Review especially
the guard completeness and all cases that intentionally tolerate a zero-row
write.

After deployment, keep retained jobs paused and require several background
cycles to show:

- no read statement inside `herdr_sync` transactions;
- settled transaction duration below one second;
- no busy errors or operation-heartbeat delay;
- planned and affected transition counts agree.

Then run one disposable fresh-job smoke and resume one retained job. Resume the
remaining jobs sequentially only after the first retained continuation reaches
a stable terminal or pull-request state without contention.

## 6. Completion criteria

The implementation issue is complete when the write-only transaction and
stale-plan regressions pass, all repository checks pass, production background
polling remains contention-free, and one retained continuation completes its
operation and review lifecycle. Its completing pull request deletes this plan;
#179 can close only after the broader production recovery criteria in
`sqlite-coordinator-contention.md` are also satisfied.
