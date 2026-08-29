# PtcManager implementation plan

## Purpose

PtcManager is a private maintainer console for GitHub repositories and the
agents working on them. It helps one maintainer decide what should be worked on,
understand the decision in plain language, start approved work, and decide when
a pull request is ready to merge.

The first deployment runs on one Hetzner server next to Herdr. The design keeps
the coordinator separate from execution workers so more servers can be added
without replacing the user interface or GitHub integration.

## Product principles

1. A person approves consequential actions. The manager may investigate and
   propose, but it does not start issue work, close issues, or merge pull
   requests without an approval tied to the current GitHub version.
2. GitHub is the source of truth for issues, pull requests, checks, and commits.
   PtcManager stores private summaries, approvals, execution state, and an audit
   log; it does not turn GitHub labels into an internal job queue. An optional
   `ptc:approved` label is a display-only projection and never grants authority.
3. Simplified explanations are private. They may be cached in PtcManager but
   are never written to GitHub issues or pull requests.
4. Model output is a proposal, not authority. Deterministic code validates
   state transitions. An implementation agent may push only its approved work
   branch and open its pull request through a narrowly scoped `gh` identity; it
   may not merge, rewrite issues, or change workflow policy.
5. Public issue, pull-request, and comment text is untrusted data. It cannot
   grant tools, reveal secrets, or change policy.
6. The manager, implementer, and reviewer are separate roles. An implementation
   agent cannot approve its own work.

## User experience

### Issue inbox

Each issue card shows:

- a short plain-language explanation;
- why the issue matters;
- likely scope, effort, and risk;
- readiness and missing information;
- expandable technical evidence;
- the age and freshness of the analysis.

Available actions in the first product release:

- **Approve and start** creates one queued implementation job;
- **Investigate more** requests a deeper manager pass;
- **Needs changes** records private guidance for a new analysis;
- **Skip** dismisses the current proposal without changing GitHub;
- **Open on GitHub** leaves PtcManager for the canonical issue.

An approval records the issue number, repository, issue `updated_at`, content
digest, proposal digest, approver, and time. If the issue changes before the job
starts, the approval becomes stale and must be renewed. Dispatch does not trust
the last periodic snapshot: immediately before leasing or starting work, the
coordinator fetches the issue directly from GitHub, recomputes the digest, and
fails closed when freshness cannot be established.

### Pull-request inbox

Each pull request shows:

- a plain-language description of what changed and why;
- tests and required checks;
- unresolved review requests and mergeability;
- known risks and remaining uncertainty;
- expandable technical review evidence;
- the exact reviewed head commit.

**Approve for merge** enables automatic merging once every required check is
green. The approval is bound to the pull request head SHA, base repository and
ref, reviewed base SHA, and diff digest. The merge executor rechecks all of
those values, required checks, mergeability, and review state immediately
before merging. Any code or effective-base change invalidates the approval.
Transient checks may be retried without changing the approval; a code fix or
conflict resolution creates a new reviewable version and requires approval
again.

### Agent activity

The dashboard shows every known agent with:

- agent and worker identity;
- repository and issue or pull request;
- role: manager, implementer, or reviewer;
- state: queued, starting, working, idle, blocked, done, failed, or lost;
- start time, elapsed time, and last heartbeat;
- Herdr workspace, pane, and session when available;
- a link to the related work item and recent bounded status text.

It also shows each worker's currently advertised implementation capacity and
its worktree allocations: active owner, issue or PR, lifecycle state, age, and
whether the allocation is safe to reclaim. Capacity disappearing because a
worker or agent misses a heartbeat is shown as degraded availability, not as a
cleanup instruction.

The interface distinguishes `lost` from `failed`: a worker that stops sending
heartbeats has an unknown outcome until the coordinator reconciles Herdr and
GitHub.

## Architecture

```text
                       GitHub
                 issues / PRs / checks
                          |
                          v
                 +-------------------+
                 | Coordinator       |
                 |                   |
                 | sync + policy     |
                 | approvals + jobs  |
                 | audit + web UI    |
                 +---------+---------+
                           |
                   worker protocol
                           |
             +-------------+-------------+
             |                           |
             v                           v
      Local worker (v1)          Remote worker (later)
      Herdr on Hetzner           Herdr on another server
             |                           |
             v                           v
       Codex / Claude              Codex / Claude
```

### Coordinator

One coordinator owns:

- the web interface and authenticated sessions;
- periodic read-only GitHub reconciliation;
- the durable database and audit log;
- generation and storage of private summaries;
- approval validation;
- job scheduling and leases;
- the authoritative view of workers and agent runs.

The first version runs the coordinator and one worker on the same server. They
still communicate through the same internal worker boundary used by future
remote workers.

### Workers

A worker advertises a stable worker ID and capabilities such as `herdr`,
`codex`, `claude`, CPU slots, and repository checkouts. It leases a job for a
bounded period, starts an agent through Herdr, and sends heartbeats and state
changes to the coordinator. Every lease attempt receives a monotonically
increasing fencing token. The coordinator and every external-write broker
reject heartbeats, transitions, or effects carrying an older token, so a paused
worker cannot resume as a second authority after its lease expires.

Remote workers are not required for the first release. The protocol must not
assume a shared filesystem, shared Herdr socket, or globally unique pane IDs.
Coordinator job IDs and worker IDs provide global identity.

Jobs are durable database records, not in-memory tasks. If no compatible agent
or worker is available, work remains queued across coordinator and server
restarts. A scheduler records why a job is waiting, its priority, next attempt,
and retry count. Expired leases are reconciled before a job can be reassigned.
CI repair and conflict-resolution jobs prefer the original agent and worktree;
after a bounded affinity window they may be handed to another compatible agent
with the prior run, PR, review, and failure context. Only one fenced lease may
modify a branch at a time.

Each worker also advertises its healthy, implementation-capable agent slots.
That advertised capacity determines the worker's worktree limit; the product
does not hard-code a fixed number of worktrees. A worker never creates more
simultaneous implementation worktrees than it has usable implementation slots,
and a transient loss of capacity never authorizes deletion of active work.

Worktrees have an explicit lifecycle: `active` while an agent owns them, `warm`
after a verified PR exists, `reclaimable` when the clean local HEAD exactly
matches the GitHub PR branch, and `terminal` after the PR is merged or closed.
Terminal worktrees are removed promptly. When all current slots are occupied,
the least-recently-used reclaimable worktree may be removed before a new one is
created. Active worktrees are never removed, and a dirty worktree or one without
a verified remote PR is retained and marked for attention. If no allocation is
safe to reclaim, the next job remains durably queued. Repair work can recreate
a worktree from the authoritative PR branch while retaining same-agent
preference.

### Model adapters

- Codex investigations run non-interactively with read-only repository access
  and schema-constrained output.
- Claude Code is an optional second-opinion adapter with an explicit tool
  allowlist and JSON output.
- PtcRunner workflows may later perform bounded batch classification and
  evidence processing. Durable queue state and GitHub writes stay in the
  coordinator so the manager can recover even when the target repository or a
  model provider is broken.

### GitHub workflow

Version one polls GitHub instead of exposing a webhook endpoint. At the current
backlog size this is simpler to operate and lets the web server remain private.

The initial manager credential is read-only. An implementation worker uses a
separate, narrowly scoped `gh` identity that can push branches and create pull
requests only in configured repositories. The generated implementation command
names the approved repository, issue, and job-derived branch; tells the agent to
run the configured tests and independent review-and-fix passes; then instructs
it to push and create or reconcile one pull request. It explicitly forbids
merging and unrelated GitHub mutation.

The normal path is therefore agent-owned Git work, not coordinator-owned
publishing. The agent reports the PR URL and exact head SHA. PtcManager then
reconciles those claims directly with GitHub and accepts success only when the
repository, issue, branch, base, and commit match the approved job. Repeated
execution must find and update the existing job PR rather than create a
duplicate. GitHub remains authoritative for the remote branch, PR, checks,
conflicts, and merge result; PtcManager is authoritative for private approvals,
review policy, queue leases, worktree allocation, agent affinity, and its audit
log.

The pre-PR quality policy is repository-configurable. Its initial default is
two independent review-and-fix passes, but the required count, reviewer tools,
test commands, and clean-review requirement are stored as policy rather than
embedded in prompts or code. PtcManager records and verifies bounded review
evidence before presenting the resulting PR as ready for a merge decision.

### Web access

The application binds to loopback on the Hetzner server and is exposed only to
the maintainer's private Tailscale network. The responsive interface works in a
desktop or mobile browser and can be installed as a home-screen web app.

Mutating requests use application authentication, CSRF protection, and an
append-only audit event even when Tailscale already restricts network access.

## Data model

The initial SQLite database contains:

- `repositories`: configured GitHub repositories and sync cursors;
- `issues`: latest canonical issue snapshot and content digest;
- `pull_requests`: latest canonical PR snapshot, head SHA, and checks summary;
- `proposals`: immutable manager analyses and private simplified summaries;
- `approvals`: immutable decisions bound to a proposal and source version;
- `jobs`: durable requested work and state transitions;
- `pr_publications`: existing disabled recovery records reserved for a future
  failed-push recovery mechanism, not the normal publishing path;
- `worktree_allocations`: worker-local paths, lifecycle state, ownership,
  verified PR/head, last use, and reclaimability evidence;
- `workers`: stable execution nodes, capabilities, and last heartbeat;
- `agent_runs`: one execution attempt with worker-local Herdr identifiers;
- `audit_events`: append-only actor, action, target, timestamp, and safe detail.

SQLite is appropriate for the single-coordinator first release. Multi-server
workers do not require a distributed database. If coordinator high availability
is later required, the storage boundary can move to PostgreSQL without changing
the worker protocol or UI concepts.

## State and safety invariants

- At most one active implementation job exists for a repository issue. SQLite
  enforces this with a partial unique index over active states; approval, job,
  and audit-event creation occur in one transaction.
- Every job has one immutable approval and proposal origin.
- A worker lease expires unless renewed by heartbeat, and every attempt carries
  a monotonically increasing fencing token.
- An expired lease never immediately starts duplicate work; reconciliation
  first fences the previous attempt, then checks the worker, Herdr, the branch,
  and GitHub.
- An issue approval is invalid after the issue content/version changes. A
  synchronous GitHub read immediately before dispatch must prove freshness.
- A merge approval is invalid after the PR head SHA, base repository/ref,
  reviewed base SHA, or diff digest changes.
- Agent status never proves that work succeeded; GitHub branch, PR, review, and
  check state are authoritative.
- An implementation agent receives only the repository-scoped GitHub capability
  needed to push its job branch and create or update its PR; it never receives
  merge authority.
- All external effects are idempotent and carry an audit identity.
- Labels and GitHub checks may reflect an approval, but the merge gate reads the
  SHA-bound approval record rather than trusting a mutable label.

## Technology choice

Use Elixir with Phoenix LiveView and Ecto:

- LiveView provides a responsive, real-time dashboard without maintaining a
  separate frontend application;
- OTP processes fit pollers, leases, heartbeats, and supervised worker adapters;
- Ecto gives a clear SQLite-to-PostgreSQL storage boundary;
- Elixir aligns operationally with PtcRunner while keeping this repository and
  release independent from `ptc_runner`.

The application must build as a normal release and run under systemd. Local
development uses SQLite and deterministic fixtures; no GitHub or model key is
required for the test suite.

## Delivery slices

### Slice 1: runnable private dashboard

- Phoenix application and SQLite schema;
- repository, issue, worker, and agent-run domain records;
- fixture-backed issue inbox and live agent activity page;
- issue approval service with freshness and duplicate-job checks;
- database constraints and transactional approval/job/audit creation;
- audit events for approvals and job creation;
- responsive layout and tests;
- deployment/configuration documentation, but no production deployment yet.

Exit criterion: a maintainer can open the application on desktop and mobile,
inspect an issue, approve it, see one queued job, and see which simulated/local
agents are working on what and since when.

### Slice 2: read-only GitHub and Herdr reconciliation

- GitHub repository configuration and read-only polling;
- private manager summaries through a read-only Codex adapter;
- local Herdr worker that reports real agent state;
- stale approval detection after GitHub changes;
- Tailscale and systemd deployment on the Hetzner server.

Exit criterion: real `ptc_runner` issues and Herdr agents appear without any
GitHub mutation permission.

### Slice 3: approved implementation dispatch

- turn an approved job into a Herdr worktree and implementation agent;
- derive bounded concurrency and worktree capacity from each worker's healthy,
  implementation-capable agent slots;
- manage active, warm, reclaimable, and terminal worktrees, including safe
  cleanup and reconstruction from a verified PR branch;
- fencing tokens on worker state and external effects;
- generate an implementation command that fixes the approved issue, runs tests,
  completes the configured independent review-and-fix passes, pushes through
  the worker's scoped `gh` identity, and creates or reconciles one PR;
- bounded local branch-result and review-evidence verification plus GitHub-side
  PR reconciliation;
- failure, blocked, cancellation, and recovery controls;
- optional additional worker registration using mutually authenticated HTTPS.

Exit criterion: one approved issue safely reaches a draft PR while the UI shows
the complete execution history.

### Slice 4: PR decision support

- PR plain-language and technical summaries;
- checks and review reconciliation;
- independent reviewer dispatch;
- **Approve for merge** records bound to head SHA, base repository/ref,
  reviewed base SHA, and diff digest;
- same-agent-first CI repair and merge-conflict resolution with fenced handoff;
- automatic merge after approval when the approved version remains current and
  every required check and review gate is green;
- notifications for ready, blocked, failed, or stale work.

## Testing and review gates

- Domain tests cover every state transition and safety invariant.
- Persistence tests cover uniqueness, transactionality, and restart recovery.
- UI tests cover desktop/mobile information hierarchy and mutating actions.
- Adapter tests use recorded, sanitized fixtures and executable fakes.
- No test requires a GitHub token, model credential, Herdr session, or network.
- Each delivery slice receives an independent review before its implementation
  commit is treated as complete.

## Explicitly deferred

- automatic issue closing or GitHub issue rewriting;
- automatic recovery when an agent commits successfully but fails to push or
  create its PR;
- public internet exposure;
- GitHub webhooks;
- multiple active coordinators or coordinator failover;
- billing, organizations, or multiple human maintainers;
- unrestricted shell or GitHub credentials in model sessions.
