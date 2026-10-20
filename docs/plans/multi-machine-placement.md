# Plan: several machines, capability-gated work, repositories homed on one machine

Status: ready for implementation as **one pull request** made of the commits in
section 9. The implementing agent may change decisions marked *open* (section
10) and must record each change; the invariants in section 2 are fixed.

## 1. Problem

PtcManager runs as one instance per machine: its own SQLite database, Oban
Lite queues, Herdr server, and GitHub polling. A maintainer with more than one
machine has two problems:

1. **Capability.** Machines differ. One may lack Docker access for the job
   user, another may have newer tools or more memory. A repository whose gates
   need a tool the machine lacks gets jobs that start, fail with
   `environment_broken`, spend their collection-run retry, and pause the run.
2. **Ownership.** Nothing stops two instances from managing the same GitHub
   repository and acting on the same issues, labels, branches, and pull
   requests.

### Decision: home each repository on one machine

A repository is *homed* on exactly one machine. That machine's PtcManager
polls GitHub for it, runs its collection runs, and executes all of its work
locally. Each machine probes its own tools as the job identity and refuses to
admit work for a repository whose declared requirements it does not satisfy;
that work stays visibly queued instead of failing. Machines exchange a signed,
read-only status document over Tailscale HTTPS so that a repository cannot be
claimed twice, every console shows the whole cluster, and a repository's
settings can move with it.

**Not in scope: remote placement** (one machine coordinating a job that
executes on another). Every part of execution assumes the database, the Herdr
server, and the worktree share a host: `Herdr.Command` runs the local `herdr`
CLI (the README records that Herdr's SSH machines are not a remote-worker
protocol); result JSON, `ExecutionArtifacts`, `WorktreeSecurity`, the
`ptc-operation` broker socket, the pre-publication gate, `GitProbe`, and the
publication broker all use the local filesystem; leases are reconciled against
local Herdr state. Section 11 lists what remote placement would need.

Also out of scope: per-issue requirement overrides, machine tags, minimum
memory, preferred machines, actions on another machine's work (the UI links to
the owning console instead), history migration, a merged inbox or board across
machines, and probing the pre-publication gate's separate OS identity.

## 2. Invariants (fixed; not open to the implementer)

1. A repository is claimed by at most one configured member at a time, under
   the membership procedure in 6.6. No automatic takeover, ever.
2. Machines never share SQLite, never use Distributed Erlang, and never send
   each other commands. The peer protocol is read-only `GET`s.
3. Secret values never leave the machine that stores them.
4. Nothing is written to a managed repository. Requirements live in
   PtcManager's repository configuration, not in `.ptc-manager.yml`.
5. Gating is write-free: no SQLite write per poll, per tick, or per waiting
   job. Only transitions are persisted (`sqlite-coordinator-contention`).
6. Network and subprocess work never happens inside a database transaction.
7. With no cluster configuration (`PTC_CLUSTER_MEMBERS` unset) and no
   repository requirements, behaviour is exactly as today.
8. Model output and peer documents are data, never authority.

## 3. Prerequisites (operations, documented in the README)

1. Every PtcManager instance that has GitHub credentials for a managed
   repository either joins the cluster or has that repository disabled. An
   instance outside the membership is outside the protocol.
2. A macOS member uses the existing launchd path (README "macOS background
   services and deployment"). On macOS jobs run as the service account
   (`PTC_HERDR_RUN_AS_USER` unset), operation cgroups are off
   (`PTC_OPERATION_CGROUPS=false`), and `HostMetrics` (Linux `/proc`) is
   unavailable; the plan must not regress that path.
3. Each instance is reachable from the others over Tailscale HTTPS
   (`tailscale serve` in front of the loopback listener).

## 4. Machine identity and inventory

### 4.1 Identity

`PTC_MACHINE_ID` (required when clustered; `^[a-z0-9][a-z0-9-]{1,62}$`) and
`PTC_MACHINE_NAME` (display; defaults to the id) in `config/runtime.exs`.
Unclustered dev and test default to `local`. A `PtcManager.Machine` module
exposes them; `OperatorState.snapshot/1` gains `machine_id`.

### 4.2 Execution contexts

Repository commands run in more than one environment, and a tool reachable in
one may not be in another. On Linux:

| Context | Runs | Environment |
|---|---|---|
| `pane` | agents and `$PTC_OPERATION_WRAPPER` commands in Herdr panes | `ptc_manager-herdr.service`: worker user, its sandbox, systemd default `PATH` |
| `setup` | workspace setup (`WorkspaceSetup` → `sudo -u <worker> ptc-manager-worker-bootstrap`) | the **manager** service's mount sandbox (inherited across sudo), the worker's groups, sudo `secure_path` |

The pre-publication gate's identity is not probed; the console says so next to
the requirements.

- **`pane` (Linux):** a oneshot `ptc_manager-tool-probe.service` runs
  `ptc-manager-tool-probe pane` with the same user, group, environment-file,
  and sandbox directives as `ptc_manager-herdr.service`; a suite test parses
  both unit files and fails when those directives differ. A timer runs it
  every 10 minutes; "Refresh" runs `systemctl start --no-block` through one
  new sudoers line, like the self-deploy trigger. Make the pane `PATH`
  explicit in `/etc/ptc_manager/herdr.env`, which both units load.
- **`setup` (Linux):** the app runs the script exactly as `WorkspaceSetup`
  runs the bootstrap helper (one new sudoers line), so it inherits the same
  sandbox.
- **macOS:** both contexts are the service account with the launchd `PATH`;
  the app runs the script once and records it for both.
- Results are written atomically to
  `/var/lib/ptc_manager-output/tool-inventory-<context>.json` on Linux (the
  established snapshot pattern) or the service root's equivalent on macOS.

### 4.3 Probe catalog

- The script runs each probe **without a shell** (`argv`, 5 s timeout, 4 KiB
  output cap, stdin closed), records raw `exit_status`, `timed_out`, `stdout`,
  and `stderr`, plus `os`, `arch`, `cpu_count`, `memory_bytes`,
  `disk_free_bytes`, and `captured_at`. A timed-out probe never prevents the
  snapshot. The catalog is capped at 24 probes.
- Built-in catalog `PtcManager.Machine.ToolProbes`: `docker` (client
  version), `docker-daemon` (server version; exit 0 means reachable),
  `docker-compose`, `deno`, `elixir`, `node`, `git`, `gh`, `psql`,
  `redis-server`, `cerbos`. Extra probes come from `PTC_TOOL_PROBES_JSON`
  (`name`, `argv`, `version_regex`), validated at boot, so adding a tool needs
  no code change and the console never stores executable probe commands.
- Parsing and semver normalization (`X.Y` → `X.Y.0`, leading `v` dropped) are
  in Elixir, compared with `Version.match?/2`, and tested with captured real
  outputs from Linux and macOS.

### 4.4 Inventory process

`PtcManager.Machine.Inventory` (modelled on `MachineUsage.Sampler`) rereads
the snapshot files every 30 s, runs the app-owned probe every 10 minutes and
on refresh in a supervised `Task` (deadline: catalog bound + 10 s), keeps the
parsed inventory in memory, and broadcasts on `"machine_usage"`. It persists
only an eligibility-changing transition, as audit `machine.inventory_changed`
with the full old and new evaluated tool lines. A context older than
`PTC_TOOL_INVENTORY_MAX_AGE_MS` (default 30 min) is *stale*.

## 5. Repository requirements and the capability gate

### 5.1 Requirements

New column `repositories.machine_requirements`, a JSON map with a wrapper key
like the other JSON columns, for example
`%{"tools" => [%{"name" => "docker-daemon"}, %{"name" => "docker-compose",
"version" => ">= 2.24.0"}]}`. A line without `version` means present and exit
0. Validation: known probe names, `Version.parse_requirement/1`, no
duplicates, at most 20 lines. Edited on the repository configuration page,
audited as `repository.machine_requirements_changed`.

`MachineRequirements.evaluate/3` is pure: a line is satisfied only when every
probed context satisfies it; reasons are `missing`, `version`, `unreachable`,
`stale`, `no_inventory`, each with its context. No requirements ⇒ always
satisfied.

### 5.2 Admission points

Every path that admits work for a repository checks the gate before a lease,
claim, or worktree reservation:

1. **Implementation dispatch.** `Operations.next_queued_job` uses `limit(1)`
   FIFO, so a gated job would block the queue. Like
   `Collections.held_job_ids/0`, `Dispatch.run_once` passes the in-memory set
   of unsatisfied repositories and the query skips their jobs. The job stays
   `queued`, which collection runs already treat as in progress (no retry
   spent). `lease_job` rolls back on `:machine_incapable` as a second line of
   defence; otherwise `reject_job!` would cancel the job.
2. **Reviews.** `Reviews.claim/1` (ordinary path via `Reviews.Worker`) and
   `Reviews.start_retry/1` return `{:error, :machine_incapable}`; both workers
   snooze. A review round's execution deadline starts at its successful claim,
   not its request, so `Reviews.sweep/0`, `Reviews.status/2`, and the claim
   predicate never expire a queued round; queue waits of any cause surface in
   `Stalls`. Review the existing expiry tests with this change.
3. **Review continuations.** `Reviews.ResumeWorker` checks the gate before
   `Reviews.Recovery.prepare` (which writes and stops agents), and
   `claim_review_continuation/2` rechecks.
4. **Resuming retained work.** `Operations.resume_from_worktree/2`.
5. **Maintainer actions and automations** that run repository commands:
   `next_agent_action_candidate_for_lane` (shared by `MaintainerActions` and
   `claim_next_agent_action_for_lane`) skips unsatisfied repositories;
   `claim_agent_action` rechecks before worktree reservation. Not
   `defer_agent_action_preflight`, which writes on every backoff.

No wait reason is stored. Pages derive "Waiting for a capable machine:
docker-daemon not reachable (pane)" from the in-memory evaluation. A `Stalls`
entry `machine_incapable` appears after 30 minutes of waiting.

### 5.3 Placement evidence

Each admission inserts an append-only audit event `placement.admitted`
(target, `machine_id`, requirements, evaluated tool lines per context with
`captured_at`) in the transaction that already records the admission.

## 6. Ownership

### 6.1 Membership

`PTC_CLUSTER_MEMBERS` (JSON `{machine_id: base_url}`, including this machine)
and `PTC_CLUSTER_SECRET` (≥ 32 bytes), identical on every member. `base_url`
must be an `https://*.ts.net` name or a Tailscale address. Boot fails when
this machine is not a member. The membership revision is the SHA-256 of the
canonical map; a changed revision at boot is audited as
`cluster.membership_changed`.

### 6.2 What a claim is

A member claims a repository (lowercased `owner/name`) when locally any of
these holds: the row is enabled; a non-terminal job, an agent action in
`AgentAction.pending_states/0`, or a non-terminal collection run exists; a
worktree allocation is not released; or an unexpired claim intent exists.
Ownership is derived; there is no owner column to drift.

### 6.3 Acquiring a claim

Every path that can enable a row uses this: `set_repository_enabled/3`,
onboarding, and `create_repository/1`. On a member, repositories are inserted
disabled.

1. Write a local claim intent (5-minute expiry) in a short transaction.
2. Outside any transaction, fetch every other member's status document.
3. Refuse (deleting the intent) if any member claims or has a pending intent
   for the repository, is unreachable, is incompatible, or reports another
   membership revision.
4. In one transaction: the intent is still ours and less than 2.5 minutes
   old; enable the row; delete the intent; audit `repository.enabled` with
   the peer checks.

The status endpoint reads all claim predicates in **one read transaction**
(one WAL snapshot), and step 4 is atomic, so a reader sees the intent or the
enabled row, never neither. Two simultaneous claimants both announce before
reading; at least one refuses.

### 6.4 Giving up a claim

- On a member, every admission point and every **work-creating** path refuses
  for a disabled repository, inside its own write transaction: job creation
  (approval, auto-implementation, collection admission,
  `retry_stopped_job`), `Operations.enqueue_agent_action` (buttons and
  `run_trigger`), and collection run creation.
  `Automations.due_schedule_triggers/1` skips disabled repositories.
- Disabling does not drain by itself (collection reconciliation stops and
  queued collection jobs fail authorization), so the console lists the
  remaining claim conditions with their existing cancel, discard, or
  cancel-run controls. When none remain, the repository is unclaimed.
- The five `list_repositories() |> Enum.filter(& &1.enabled)` sites become
  `Operations.enabled_repositories/0`.

### 6.5 Startup fencing and conflicts

- **Startup.** A member admits no new work (reason `cluster_startup`) until
  one round with every other member has succeeded at the same revision with
  no conflicting claim. No timeout fallback, nothing persisted. Running work
  keeps reconciling and publishing; a member that did not restart keeps
  serving its repositories during a partition.
- **Standing conflict.** If a peer claims a repository this member also
  claims, this member stops admitting new work for it
  (`ownership_conflict`) and shows a banner; running work continues. The
  maintainer resolves it on one side.
- **Non-member.** A signed request from a machine outside the member map gets
  a signed `403 {"member": false}`; on receiving it the caller stops admitting
  all work and shows a banner.

### 6.6 Membership procedure

- *Remove* a machine only when its status shows no claims and no intents,
  then stop it, then update and restart the others. If it is dead, first make
  sure it can never return with its database. That is the design's only human
  assertion.
- *Add* a machine: start it with the new map, then restart the others. Claims
  fail on the revision check until all agree; existing claims keep working.

## 7. Peer protocol

- **Why not Distributed Erlang:** the cookie grants remote code execution on
  every node; TLS distribution must be switched on everywhere at once, which
  conflicts with separate deploys; node versions are coupled across Linux and
  macOS builds; no shared registry is needed.
- **Transport:** `GET /api/peer/v1/...` behind `tailscale serve` (server
  authentication by the `ts.net` certificate). Requests and responses are
  HMAC-SHA256-signed with `PTC_CLUSTER_SECRET` over method, path, timestamp,
  caller id, and body hash; ±60 s skew; constant-time compare. Read-only, so
  no nonce store; a future write endpoint must add one. 404 when unclustered.
  Outbound calls use `:httpc` with `verify_peer`, through `Gateway.call` so
  tests can swap the client.
- **`/status`:** `protocol_version`, `machine_id`, `machine_name`,
  `deployed_sha`, `membership_revision`, `operational_mode`, inventory per
  context, repositories (`claim`: enabled/pending/live_work/none,
  requirements with revision, claim blockers), live jobs and runs with
  console URLs, agent CLI login status, and execution-profile digests (for
  drift). Never `OperatorState`'s `untrusted` section, prompts, issue text,
  or agent output.
- **`/repositories/:owner/:name/settings`:** the transferable settings of a
  repository this member has **disabled and unclaimed** (6.4):
  - every maintainer-editable field of the repository row except `enabled`,
    `local_path`, and sync state: at least the configured `default_branch`,
    workspace setup command and timeout, requirements, auto-fix policy and
    limit, `required_pre_pr_reviews`, maintainer labels, integration
    branches, branch prefixes, and GitHub label and branch names. A test
    enumerates the changeset's cast fields and fails when a field is neither
    transferred nor explicitly excluded, so a new setting cannot be silently
    left behind;
  - each automation's **current definition version** (prompt, execution
    profile, and other version fields) and its **triggers** (schedules, time
    zones, contextual buttons), keyed by automation key;
  - the **names** of agent environment variables. Never secret values.
- **Poller:** `PtcManager.Cluster.PeerPoller` polls `/status` every 15 s
  (5 s timeout), keeps results in memory only, marks a member `healthy`,
  `unreachable` (60 s without success), or `incompatible`, and audits
  transitions only. Claim checks always fetch fresh.
- **Skew:** an incompatible member is shown and blocks claims; it keeps
  serving its own repositories. Additive fields don't bump the version.

## 8. UX and administering several machines

### 8.1 Knowing which machine you are on

- **Machine badge** in the header of every page: name, OS, and a stable
  colour derived from the machine id, so acting on the wrong console is hard
  to miss.
- **Machine switcher** next to it: members with health dots. Record IDs are
  local to each machine, so the switcher never keeps a record path: a
  repository page maps to the same `owner/name` on the target if it exists
  there, list pages (board, operations, automations, configuration, cluster)
  keep their path, and any other record page lands on the target's Cluster
  page. Logins stay per machine.
- **Deep links** keep their target: "job #812 on <machine>" opens that job's
  page on the owning console.

### 8.2 Cluster page (new nav entry next to Deployments)

1. **Machines:** health, inventory age per context, tools and versions,
   capacity and load, deployed SHA (and whether it is behind the default
   branch), protocol version, agent CLI login status, refresh-inventory, and a
   link to that machine's Deployments page.
2. **Repositories:** home machine, requirement result on every member (✓ or
   the failing line), live work, and a **Move** action (8.3).
3. **Drift:** differences that matter, flagged and never synced: membership
   revision, protocol version, deployed SHA more than one release apart,
   execution-profile digests. Capacity is shown but not flagged; it should
   differ with hardware.

`OperatorState.snapshot/1` gains a `cluster` section from the poller's
memory.

### 8.3 Moving a repository

1. **Source console:** "Move <repository>…" lists claim conditions with their
   controls, then disables. When nothing remains it shows "ready to claim on
   another member" and a link to each eligible member's claim page.
2. **Target readiness.** The repository must first be onboarded on the
   target the normal way (disabled): local checkout, provisioning and service
   access grants (`ptc-manager-provision-repository` on Linux), and a
   commit identity that resolves (`CommitIdentities`). The claim page checks
   these (checkout present and readable, startup preflight passes, identity
   resolves) outside any transaction and refuses to continue until they
   pass.
3. **Target console:** "Claim <repository> from <source>" runs the claim
   protocol (6.3), fetches the source's settings endpoint, shows a diff
   against the target's current settings, lists the agent environment
   variable **names** to re-enter, and applies everything in the step-4
   transaction with one confirmation. Automations are matched by key: a
   target automation seeded at onboarding is updated to the source's current
   version as a new version (never duplicated), an automation the target
   lacks is created, and every imported automation and trigger arrives
   **paused**, including seeded ones, so nothing runs before the maintainer
   reviews it. The audit records the source, the settings digest, and the
   peer checks.

History stays on the source and is reached through deep links.

### 8.4 Administration

- **Deploys** stay per machine (systemd on Linux, launchd on macOS). The
  Cluster page shows each SHA; the protocol version tolerates skew. No
  "deploy all".
- **Configuration** for clustering lives in the env files. The README gains a
  "Several machines" section with the env variables, the membership
  procedure (6.6), and the prerequisite checks.
- **`mix ptc.cluster check`** (run on any member, or from a maintainer
  machine with the member map and secret) signs a status request to each
  member and prints membership revision, protocol version, SHA, clock skew,
  and signature failures. It exits non-zero on mismatch.
- **Daily digests and notifications** stay per machine; they cover disjoint
  repositories.
- **Health tooling** (health snapshot, release RPC) is Linux-only today; the
  README says so for macOS members.

## 9. Delivery: one pull request, reviewed commits

One branch, one PR, one commit per row. Each commit compiles, passes
`mix precommit`, and leaves the product working with clustering unconfigured
(invariant 7).

| # | Commit | Contents |
|---|---|---|
| 1 | `feat(machine): identity, badge, tool inventory` | 4.1–4.4, header badge (8.1), probe script, units, sudoers lines, deploy installation |
| 2 | `feat(dispatch): repository requirements and capability gate` | 5.1–5.3, requirements UI, stalls entry |
| 3 | `feat(cluster): signed peer status protocol and poller` | 6.1, 7 (status only), switcher (8.1), `mix ptc.cluster check` |
| 4 | `feat(cluster): single-owner claims and startup fencing` | 6.2–6.6 |
| 5 | `feat(cluster): move a repository with its settings` | settings endpoint, 8.3 |
| 6 | `feat(cluster): cluster page, drift, operator state` | 8.2, README "Several machines" |
| 7 | `test(cluster): multi-node integration tests` | 9.2; deletes this plan |

The implementer may split or merge commits when a different cut reviews
better, and records why (section 10).

### 9.1 Review loop per commit

For each commit: one fresh codex review of that commit's diff, then fix and
resume the same review session; **at most 4 review rounds per commit**. A
finding still open after round 4 is either fixed without further review and
recorded, or recorded with the reason it was not fixed. The PR description
lists each commit's rounds and any unresolved findings.

### 9.2 Multi-node integration tests

Unit tests cover evaluation, signing, and claim logic with faked peers
through `Gateway.call`. In addition, a small `:nightly`-tagged integration
suite runs **real members** against each other:

- **Harness:** start two or three members, each with its own SQLite file,
  HTTP port, `PTC_MACHINE_ID`, and shared member map. The preferred harness is
  `:peer` nodes running the application with per-node app env; if application
  singletons make that impractical, OS processes running `mix phx.server` in
  demo mode are acceptable, each with its own database file through the
  variable the chosen environment actually reads (`PTC_DATABASE_PATH` in
  dev, see `config/dev.exs`; `DATABASE_PATH` in prod) and its own `PORT`.
  The harness asserts the members' database paths differ and never point at
  the development database. Herdr and
  GitHub stay faked (dispatch and sync disabled or pointed at stubs); only the
  cluster layer is real. Plain HTTP on loopback is allowed in tests behind an
  explicit test-only flag; signing stays on.
- **Scenarios:**
  1. Both members see each other healthy; the Cluster page data matches.
  2. Claiming a repository on B is refused while A claims it; after A
     disables with no conditions, B's claim succeeds and settings arrive
     (secret names only).
  3. Simultaneous claims from A and B: never both succeed (repeat with
     randomized delays).
  4. Partition: stop B's endpoint; A marks B unreachable within the bound,
     keeps admitting for its own repositories, refuses claims.
  5. Restart fencing: restart A from a copied database that still has a
     moved repository enabled; A admits nothing for it and shows the
     conflict once B is reachable.
  6. Skew: B reports another protocol version; A shows it incompatible and
     refuses claims.
  7. Non-member: a member removed from the map gets the signed refusal and
     fences itself.
- The suite runs in under a few minutes, is excluded from
  `scripts/ci/test-suite`, and runs with `mix test`.

## 10. Implementer freedom and the decision record

Open decisions (defaults above; change them when the code argues for it):
probe execution mechanism per OS, probe catalog contents, intervals, timeouts
and expiry values, HMAC header names and canonical string, status document
field names, whether claim intents are a table or a column, where the gate's
in-memory state lives, page layout and naming, the integration harness
(9.2), and the commit cut (9).

Not open: section 2.

Every change from this plan, and every decision the plan does not cover, is
recorded in two places: a "Design decisions" section of the PR description
(decision, alternatives, reason) and a durable maintainer document
`docs/maintainers/multi-machine.md` that explains the shipped design, since
this plan is deleted by the last commit. When a decision touches a section 2
invariant, stop and ask the maintainer instead.

## 11. Deferred: remote placement

Running work on a machine other than the repository's home would need at
least: a remote dispatch command with idempotency keys and cross-machine
fencing; result JSON, artifacts, and stop reports returned to the
coordinator; the pre-publication gate and publication broker on the executing
machine with the exact verified commit; lease renewal across partitions; and
per-machine broker credentials. Revisit when homing a repository on a capable
machine is not acceptable.

## 12. Acceptance

1. Each console shows the badge and switcher, and the Cluster page lists all
   members with inventories per context; a member whose job user cannot reach
   Docker shows `docker` present and `docker-daemon` failing.
2. A repository requiring a missing tool keeps its work queued with the
   reason, other repositories' work still starts, and its collection run does
   not pause. When the tool appears and the probe refreshes, the work starts.
3. Claims are exclusive, including simultaneous claims, restarts from stale
   databases, and asymmetric or changed membership.
4. Moving a repository carries its non-secret settings and lists the secret
   names to re-enter; automations arrive paused.
5. A partitioned member keeps serving its own repositories; an incompatible
   member is shown and blocks claims.
6. With `PTC_CLUSTER_MEMBERS` unset and no requirements, the existing suite
   passes unchanged.
7. The integration scenarios in 9.2 pass.
