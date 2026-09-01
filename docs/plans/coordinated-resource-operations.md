# Coordinated Resource Operations

Status: implementation plan  
Initial worker: `herdr-build-01`  
Initial repositories: `andreasronge/ptc_runner`, `andreasronge/ptc_manager`

## Purpose

PtcManager should allow several agents to investigate and edit concurrently
without allowing their most memory-intensive build, test, lint, or verification
processes to exhaust a worker. Agent admission and expensive-operation admission
are separate concerns.

The first release introduces one additional configurable capacity:

- **light agent slots** bound planning and investigation agents;
- **heavy agent slots** bound implementation, repair, and merge agents;
- **operation slots** bound concurrent expensive command process trees.

For the current 8 GB Hetzner worker, the initial recommendation is three light
agents, two heavy agents, and one expensive operation.

## Compatibility requirement

Every repository must continue to build, test, lint, run, and publish through
its normal commands without PtcManager, Herdr, a running coordinator, or a PTC
wrapper. Examples such as `mix test`, `npm test`, and checked-in CI scripts keep
their ordinary behavior for developers, CI, and unmanaged agents.

The usual example is a checkout on the maintainer's Mac: no PtcManager resource
wrapper is expected to be installed, and the repository commands run directly.
The same rule applies to ordinary CI and any other unmanaged checkout.

Coordination is additive:

- a managed agent explicitly runs an expensive command through the generic
  PtcManager operation command; or
- a repository script detects the managed-operation environment and delegates
  to that command, while executing directly when the environment is absent.

The operation command must fail closed inside an explicitly managed context if
the coordinator cannot safely grant a slot. Outside that context it must not
intercept or change repository commands.

The wrapper protocol is cooperative scheduling, not the sole safety boundary.
A managed agent can still execute an arbitrary unwrapped command. Every managed
agent therefore also runs in its own cgroup created from Herdr's delegated
systemd subtree with a configurable
memory high-water mark and hard maximum. An unwrapped command may lose the
statistics and orderly operation queue, but it cannot consume the whole Herdr
service cgroup or stop unrelated agents. This containment is enabled only on
managed Linux workers and has no effect on the maintainer's Mac.

Rollout is guarded by `PTC_OPERATION_CGROUPS`: it remains off for an upgraded
host until the versioned Herdr unit and launcher with cgroup-v2 delegation are
installed. It is required before concurrent managed agents are treated as
safely contained; the cooperative queue can be tested independently first.

No executable-name shims, shell aliases, agent-vendor hooks, or PATH replacement
may be required. A normal checkout remains independently usable.

## User experience

### Configuration

Rename the capacity section to **Worker capacity** and expose three positive
integer settings:

- light agents;
- heavy agents;
- expensive operations.

Changing a limit is a soft resize. Existing agents and operations finish. New
admission pauses until current usage is below the new value. Persist every
capacity change with its effective time and worker incarnation so historical
utilization uses the capacity that actually existed during each interval.

### Operations

Show light, heavy, and expensive-operation usage separately. The agent run
keeps its existing active state while an associated operation supplies its
more specific displayed phase. An agent may be:

- working normally;
- waiting for an operation slot;
- building;
- testing;
- linting;
- verifying;
- finishing or failed.

For every queued or active operation show repository, job or action, agent,
operation label, wait time, run time, and assigned worker slot. Cancellation of
an owning job must remove a queued request; cancellation of a running operation
must terminate its process tree before releasing its slot.

### Statistics

Store one bounded metric record per operation. Aggregate by worker, repository,
operation label, and a selectable time window. Display:

- execution count and success rate;
- total execution time;
- average, p20, median, p80, and maximum execution time;
- average and p80 queue wait;
- p80 and maximum observed peak memory;
- slot utilization and recent longest operations.

Queue time and execution time remain separate. Percentiles use one documented
nearest-rank implementation so UI and tests agree. Raw command arguments are
not stored because they may contain secrets or create unbounded cardinality;
the caller supplies a short validated label such as `test`, `build`, `lint`,
`duplication`, or `pre-push`.

Peak memory means the highest cgroup memory consumption attributed to the
complete operation. The broker records the kernel's cgroup peak rather than
sampling only the wrapper or its immediate child.

## Agent-independent protocol

All Herdr panes inherit stable pane identity. PtcManager maps that pane to its
fenced job or action and injects a managed-operation context before starting the
configured Herdr agent kind. The protocol does not branch on Codex, Claude,
Cursor, or another supported kind.

Before `herdr agent start`, PtcManager writes a coordinator-owned, mode-`0440`
context file in a setgid directory shared only with the worker identity, then
asks the pane's interactive shell to source it. The worker can read but cannot
alter the contract. The inherited contract
contains only the run identity, fence, local Unix-socket path, wrapper path, and
an unguessable bounded capability token. The agent receives no SQLite path or
database credential. A coordinator-owned Unix-socket broker validates the
token, peer OS identity, active run, pane identity, and fencing token for every
request. Context files are removed when the run becomes terminal.

A managed agent invokes a normal executable, conceptually:

```sh
ptc-operation run --label test -- mix test
```

The executable:

1. validates the managed run identity and fencing token through the local
   broker;
2. generates one random logical-invocation ID and reuses it for every transport
   retry made by that wrapper process;
3. creates an idempotent durable operation request for that invocation;
4. reports `waiting` while no slot is available;
5. receives one fenced slot lease and an empty per-operation cgroup from the
   worker-local coordinator;
6. starts the command in that cgroup and reports `running`;
7. streams command input/output unchanged and reads cgroup memory metrics;
8. records exit status, duration, and peak cgroup memory;
9. releases the lease only after the cgroup is empty and terminal.

A later, intentional invocation with the same run and label receives a new
logical-invocation ID and a new record. Idempotency prevents duplicated acquire
or completion effects from one wrapper; it never collapses two commands merely
because their labels match.

The child receives `PTC_OPERATION_ACTIVE` and the operation identity. A nested
instrumented script reuses that active lease and may update the display phase;
it must not request a second slot and deadlock itself.

Herdr metadata may mirror the current phase for its own UI. It is display-only:
the database request, fencing token, process ownership, and slot lease are the
PtcManager source of truth.

## Scheduling and locking

Operation requests are worker-local because RAM is worker-local. The database
serializes admission and grants no more than the configured number of leases
for one worker incarnation. A unique slot identity plus fencing token prevents
two requests from owning the same slot.

Initial ordering is:

1. merge verification;
2. repair verification;
3. implementation verification;
4. other heavy operations;
5. oldest request first within a priority.

An OS-held slot lock and a per-operation cgroup created beneath the pane's
delegated agent boundary are the final local
exclusion and containment boundaries. Database state provides durable ordering
and UI visibility; it is not by itself proof that a previous process tree has
stopped. The unprivileged agent cannot move processes out of its operation
cgroup. A replacement cannot use a slot until the old lock is absent and the
old cgroup is empty, or the broker has positively terminated every process in
it.

The operation capacity is independent from light and heavy agent counts. An
agent waiting for verification remains `working` for existing capacity and
deployment-guard semantics, because it keeps the conversation and worktree.
The linked operation record is `queued` and supplies the UI label “waiting for
verification”; the existing passive retained-agent state `waiting` is not
reused. A queued operation does not consume an operation slot.

## Failure and recovery

The state machine is `queued -> starting -> running -> terminal`, with explicit
`cancelled`, `lost`, and `recovery_pending` outcomes.

- Wrapper failure before process start returns the request to a safe terminal
  state without consuming a slot.
- Agent death while queued cancels the request after authoritative Herdr
  reconciliation.
- Wrapper or child death while running fences the request, inspects the cgroup
  and lock, and releases capacity only after cgroup emptiness is proven.
- Coordinator restart adopts a live fenced wrapper and rebuilds visible state;
  it never grants the same slot merely because a lease timestamp expired.
- Worker or Herdr incarnation change quarantines active operations together
  with their owning agent attempts.
- Lowering capacity never revokes a live slot. Slot numbers above the new limit
  retire when their current operations finish.
- Ambiguous identity, process ownership, or lock state fails closed and is
  shown as requiring maintainer attention.

Managed Linux workers isolate every agent and operation in cgroups below a
systemd subtree delegated only to the Herdr worker identity.
The Herdr service uses an OOM policy that does not stop the entire service merely
because one contained child becomes an OOM victim. Operation coordination keeps
normal verification orderly; cgroups are the required backstop when an agent
ignores the wrapper or a child daemonizes.

## Repository integration

PtcManager supplies a concise managed prompt instruction describing the
operation command and recommended labels. A repository can optionally wrap its
authoritative gate, for example its pre-push script, only when the managed
environment is present. The same script runs its existing body directly in all
other environments.

The first pilot must prove both paths:

1. an ordinary local checkout runs its build and tests with no wrapper binary,
   coordinator, environment variables, or network service;
2. a managed Herdr run executes the same gate under one operation lease.

Repository configuration may select the suggested operation label and managed
gate command, but PtcManager does not infer project type or rewrite arbitrary
build commands.

## Data model

Add an operation-capacity field to the existing persistent capacity setting.
Add effective-dated capacity history per worker and worker incarnation.
Add a durable `resource_operations` record containing at least:

- worker, worker incarnation, repository, job or action, and agent-run IDs;
- stable idempotency key, operation label, priority, state, and slot number;
- fencing token and wrapper/process identity;
- queued, started, heartbeat, finished, and next-reconcile timestamps;
- wait and run durations, exit status, observed peak RSS, and bounded error;
- cancellation and recovery metadata.

Exactly one of job or agent-action ownership is required by a database check
constraint. Every transition that makes either owner terminal reconciles its
operation in the same transaction when it is still queued, or records a fenced
`cancelling` request when it is running. The broker terminates the operation
cgroup and only then completes both cancellation and slot release. This applies
to user cancellation, target closure, ordinary completion, failure, and lost or
recovery transitions for both owner types.

Keep terminal records for statistics and audit. Apply a documented retention or
aggregation policy before the table can grow without bound.

## Test strategy

### Default suite

Extend `PtcManager.TestScenario` with operation requests, deterministic
interleaving barriers, worker restart, wrapper death, and process ownership.
Use virtual time and explicit messages rather than sleeps.

Fast state-machine and integration tests cover:

- concurrent acquisition never exceeding capacity, including a simultaneous
  last-slot race;
- priority and FIFO ordering;
- soft capacity increases and decreases;
- fencing, replayed messages, and idempotent completion;
- queued and running cancellation;
- wrapper death, child death, coordinator restart, worker restart, and stale
  heartbeat recovery;
- a double-forked or `setsid` descendant remaining contained until the broker
  terminates the operation cgroup;
- a direct unwrapped expensive command remaining inside the owning agent's
  memory-bounded cgroup without creating a false operation record;
- nested acquisition without deadlock;
- exact percentile, utilization, and retention calculations;
- UI rendering for capacity, waiting/running state, metrics, and errors;
- unmanaged commands succeeding when the wrapper and PtcManager are absent.

The normal repository gate must remain below its existing 60-second budget.

### Optional resource E2E

Add a separately tagged suite, excluded by default, that starts an isolated
coordinator, temporary SQLite database, real operation wrapper, and two or
three fake shell agents. It runs no LLM and uses no public network.

It proves:

- multiple fake agents can edit concurrently while only the configured number
  of operation process trees execute;
- output and exit codes pass through unchanged;
- killing a queued wrapper, active wrapper, active command, or coordinator does
  not leak or duplicate a slot;
- lowering capacity during execution is safe;
- metrics and the Operations page reflect the final result.

The suite has an enforced target below 30 seconds and a hard timeout below 60
seconds. A separate manual Herdr canary may use a real agent, but correctness
must never depend on a paid model, vendor hooks, or model timing.

## Delivery checkpoints

1. **Plan and model:** reviewed plan, migration, state machine, capacity setting,
   metrics calculations, deterministic tests, and mocked Operations UI.
2. **Broker and runner:** authenticated Unix-socket broker, generic executable,
   per-operation cgroups, nested calls, cancellation, peak memory, and optional
   sub-minute resource E2E.
3. **Herdr integration:** inject managed identity for every configured agent
   kind, place each managed agent in a memory-bounded cgroup, mirror display
   metadata, and reconcile crash/restart and OOM cases.
4. **Pilot repository:** opt one authoritative gate into managed delegation and
   prove the unmanaged path remains byte-for-byte equivalent.
5. **Production rollout:** deploy with one operation slot, observe statistics,
   then decide whether the worker safely supports more.

Each checkpoint is independently testable and committed before deployment.
