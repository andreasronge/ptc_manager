# Plan: macOS as a supported agent host

Status: ready for implementation as **one pull request** made of the commits
in section 9. The implementing agent may change decisions marked *open*
(section 10) and records each change; the invariants in section 2 are fixed.
The last commit deletes this plan.

## 1. Problem

A macOS launchd member (`PTC_MACOS_SERVICE_ROOT`; services and agents run as
the maintainer's own account; no cgroups) ran real agent jobs for the first
time on 2026-10-21, for tyraorg/api. Each step failed in a new way and was
patched separately:

| # | Failure | Patch | Kind |
|---|---|---|---|
| F1 | Children inherited the release's bundled ERTS on `PATH`; `elixir`/`mix` crashed | #254 `CommandEnvironment.scrub/1` | right fix |
| F2 | Worktree root validation needed `PTC_HERDR_RUN_AS_USER`; every dispatch failed silently with `:worktree_owner_unavailable` | #260 `WorktreeSecurity` | right for a trusted same-account host |
| F3 | `deploy/ptc-operation` used `os.waitid`, absent on macOS | #263 kqueue fallback | right fix |
| F4 | `killpg` on a zombie-only group raises EPERM on macOS; the wrapper died before `finish` | #267 `signal_group/2` | **too broad**: swallows every darwin EPERM, including forwarded signals; EPERM never proves the group is gone |
| F5 | An operation abandoned by its wrapper cannot be recovered without cgroups; after the retry bound the broker put the **whole console** into maintenance; a maintainer released the operation by RPC | none | **open** |
| F6 | Session archival used `/usr/local/bin/...` and `/var/lib/...`; a retained worktree could not be discarded | #265 | right, but path resolution has no single owner |
| F7 | `PTC_RESULT_RECONCILE_INTERVAL_MS` defaulted to 0, so finished jobs were never reconciled; publication was switched to agent mode by hand; PR reconcile also imported every external PR | env edits | **symptom**: no validated host contract |
| F8 | Codex's update prompt blocked unattended agent start | flag in `PTC_AGENT_PROFILES_JSON` | **symptom**: belongs in code |
| F9 | A member cannot deploy its own release while `ptc_manager` is disabled there (#255, #261); repository health reads the local, never-fetched default branch (#256) | none | domain-model bug |
| F10 | The maintainer's interactive Claude Code pane was adopted as an `AgentRun` and held a deployment drain | none | domain-model bug |
| F11 | Dispatch pre-lease errors are discarded every 5 s: no log, nothing on the job | none | observability bug |

Root causes:

1. **The host contract is implicit.** `config/runtime.exs` uses Linux defaults
   and the Darwin block overrides only some. Modules infer identity,
   filesystem trust, helper placement, containment and service management
   from one signal, whether `herdr_run_as_user` is empty
   (`WorkerHelper.worker_boundary?/0`, a private copy in
   `WorkerRepositoryTrust`, `WorktreeSecurity`, `Herdr.Command`,
   `CommandEnvironment.command/3`). The Darwin block does not set
   `resource_operation_wrapper`, `resource_operation_socket_path`,
   `resource_operation_context_dir`, `planning_snapshot_root`,
   `daily_digest_bundle_root` or `health_snapshot_path` to service-root
   paths.
2. **Observation, ownership and roles are conflated.** `Herdr.Sync` inserts
   every observed pane as an `AgentRun` (role `implementer` by default);
   `Deployments.drain_blockers/0` counts any working run. Deployment
   eligibility reuses `repository.enabled`, which on a cluster member means
   "this member runs automation for it". Health and deployment read
   different revisions of one branch.
3. **Nothing verifies that a host can run the whole job lifecycle, and the
   failure policy assumes kernel containment.** Without cgroups there is no
   evidence that an abandoned command stopped, yet the only outcome the
   broker has for that is global maintenance. CI runs only on Ubuntu; no
   workflow runs `resource_e2e`.

### Rejected design: automatic recovery on macOS

macOS gives an unprivileged service no containment equivalent to cgroups. A
per-operation lock inherited by the command was tried (it survives `setsid`
and reparenting), but descendants drop inherited descriptors in ordinary
use (`subprocess` closes them by default), so a free lock does not prove the
tree stopped. Signalling pids found by enumeration races with pid reuse.
Automatic macOS recovery would therefore violate invariant 2. This plan
instead makes the uncertain case **contained and visible** (4.3, 4.4). A
launchd-per-operation or Endpoint Security design may revisit this later
(section 11).

## 2. Invariants (fixed; not open to the implementer)

1. **Linux behaviour is unchanged**, including privilege boundaries, helper
   commands, recovery, escalation to maintenance, and every existing default
   and environment override. Existing Linux tests pass unmodified, except
   where a test asserted a value the profile now supplies, and then the value
   is the same.
2. **Fail closed on recovery.** Nothing *recovers* (releases) an abandoned
   or uncertain operation automatically without kernel-backed evidence
   (cgroups). On a host without it, such an operation stays fenced (holds its
   slot) until a maintainer releases it (4.4). EPERM, a missing pid, a
   timeout, an empty process listing or an inspection failure is never
   evidence. **Explicit scope:** a wrapper that saw its own command exit and
   finds no survivor (4.1) finishes normally. That is best-effort, exactly as
   a Linux host without cgroups finishes today, and the README states the
   residual risk (a descendant that both escapes the process group and clears
   its environment is not detected). Only survivors the wrapper detects, and
   operations whose wrapper is gone, are fenced.
3. **One host profile is resolved at boot and every platform decision reads
   it.** After commit 3 no module except `PtcManager.Host` reads
   `herdr_run_as_user`, `:os.type()` or `PTC_MACOS_SERVICE_ROOT`.
4. **An incomplete configuration is refused at boot or reported by readiness
   before work is admitted, never silently degraded.**
5. **GitHub is the source of truth for revisions.** Health, deployment and
   dispatch read the same fetched remote ref.
6. **Only PtcManager-owned runs carry operational weight** (drain, capacity,
   stalls, cancellation). An observed pane is shown, never waited on or
   cancelled.
7. **No compatibility shims.** Replace call sites and delete old helpers.
   Rolling out a wrapper change is gated by readiness (6.1), not by accepting
   old behaviour.
8. **GitHub write rules are unchanged** (AGENTS.md "Conventions"): readiness
   is read-only; publication still writes only the exact verified commit or
   through an approved agent action.
9. Deterministic code owns every state transition. Every bug fix starts with
   a failing test that reproduces it.

## 3. Host profile

New module `PtcManager.Host` (`lib/ptc_manager/host.ex`). The profile is
resolved once in `config/runtime.exs` into `config :ptc_manager, :host`
(shape *open*).

| Field | `:linux` | `:macos` | `:development` |
|---|---|---|---|
| selected when | Linux release (`RELEASE_NAME` set) | Darwin release with `PTC_MACOS_SERVICE_ROOT` | no release (`mix` dev/test) |
| agent identity | `{:separate, user}` when `PTC_HERDR_RUN_AS_USER` is set, else `:service_account` | `:service_account` | as configured; default `:service_account` |
| trusted ancestor owners | `[0]` for `:separate`; `[0, service uid]` for `:service_account` (as #260) | `[0, service uid]` | as identity |
| containment | `:cgroup` when `resource_operation_cgroups` is true, else `:none` | `:none` | `:none` unless a test injects one |
| uncertain-operation policy | today's code path exactly: cgroup recovery when `cgroup_path` is set, otherwise `{:retry, :operation_recovery_requires_cgroup_containment}` and escalation to maintenance | fence the operation, no maintenance (4.3) | as `:macos` |
| service manager | systemd | launchd (`macos-deploy-host`) | none |

A Darwin release without `PTC_MACOS_SERVICE_ROOT`, or with
`PTC_HERDR_RUN_AS_USER` set, or with `PTC_OPERATION_CGROUPS=true`, raises at
boot naming the setting.

**Paths.** Each `Host` path key maps to the existing application key and
environment variable; an explicit environment variable still wins:

| Host key | Application key | Env var | Kind | `:macos` default (under the service root) |
|---|---|---|---|---|
| `operation_wrapper` | `resource_operation_wrapper` | `PTC_OPERATION_WRAPPER` | executable | `bin/ptc-operation` |
| `operation_socket` | `resource_operation_socket_path` | `PTC_OPERATION_SOCKET_PATH` | socket; parent directory writable | `run/operations.sock` |
| `operation_context_dir` | `resource_operation_context_dir` | `PTC_OPERATION_CONTEXT_DIR` | directory, writable | `data/operation-contexts` |
| `execution_artifact_root` | `execution_artifact_root` | `PTC_EXECUTION_ARTIFACT_ROOT` | directory, writable | `data/execution-artifacts` |
| `planning_snapshot_root` | `planning_snapshot_root` | `PTC_PLANNING_SNAPSHOT_ROOT` | directory created by `SourceSnapshot` | `data/planning-snapshots` |
| `daily_digest_bundle_root` | `daily_digest_bundle_root` | `PTC_DAILY_DIGEST_BUNDLE_ROOT` | directory | `data/daily-digest-bundles` |
| `tool_inventory_dir` | `tool_inventory_dir` | `PTC_TOOL_INVENTORY_DIR` | directory | `data/tool-inventory` |
| `health_output` | `health_snapshot_path` | `PTC_HEALTH_OUT` | output file; parent writable | `data/health.json` |

On `:linux` the defaults are today's values, and worker-owned roots are
checked only as "exists and is a directory".

**Helpers**, keyed by identity, not only by OS. A `:service_account`
identity on Linux keeps today's direct execution:

| Helper | `{:separate, user}` (Linux, unchanged) | `:service_account` (Linux and macOS) |
|---|---|---|
| worker review, agent login | `sudo -n -H -u user` `/usr/local/bin/ptc-manager-worker-*` | configured path: `:macos` uses `<root>/bin/...`, Linux uses today's app-env value |
| claude trust, codex arming, gh label, worker git, bootstrap | `sudo -u user` `/usr/local/bin/...` | today's local behaviour (skipped, disabled, or plain `git`) |
| worktree cleanup | `sudo -u user` helper | `priv/worktree_cleanup.py`, direct |
| worktree preserve / seal | worker helper / **root** seal helper | `priv/*.py`, direct |
| tool probe | systemd unit or sudo helper | `/usr/bin/python3 priv/tool_probe.py` |
| operation recovery | **root** `ptc-manager-operation-recover` via sudo (cgroup) | Linux: unchanged (today's code path); macOS: none (4.3) |

`Host.helper_command(key, args)` returns `{binary, args}` from this table.
Call sites stop building sudo commands themselves; `Herdr.Command.command/2`
stops duplicating `CommandEnvironment.command/3`.

**Call sites to migrate** (from code research on 599f492): `WorkerHelper`,
`WorkerRepositoryTrust`, `WorktreeSecurity.configured_owner/0`,
`Herdr.Command`, `WorkerGit`, `WorkerAgentLogin`, `WorkerClaudeTrust`,
`WorkerCodexArming`, `IssueLabelWriter`, `Worktrees` cleanup,
`WorktreePreserver`, `WorkspaceSetup` bootstrap, `Machine` and
`Machine.Inventory`, `Repository.SourceSnapshot`, `ExecutionArtifacts` and
`Reviews.Adapter`, `ManagedOperationContext`, `ResourceOperationRecovery`,
`ResourceOperationBroker` escalation, `Deployments.HostRunner`,
`ServiceAccess`, `Provisioning`, and both blocks of `config/runtime.exs`. A
test greps `lib/` for the three forbidden reads (invariant 3). A test asserts
that the Linux `{:separate, user}` helper commands are byte-for-byte the
same as before.

## 4. Wrapper correctness and contained uncertainty

### 4.1 Wrapper (`deploy/ptc-operation`)

- **Handlers first.** Install the SIGINT/TERM/HUP handlers before `running`
  is sent; a signal that arrives before `Popen` is remembered and delivered
  to the group once the child exists.
- **Exact launch acknowledgement.** The wrapper starts the command only if
  the `running` response is exactly `{"status": "running", "operation_id":
  <its id>}`. Any other response (cancelled, terminal, error, missing) ends
  the wrapper without starting the command, with exit 75 and the response in
  stderr. Any later request refused because the attempt token is stale or the
  operation is no longer leased makes the wrapper SIGKILL its command group
  and exit 75 without `finish`.
- **Marker.** The child environment carries
  `PTC_OPERATION_ATTEMPT=<id>-<attempt12>`. It is diagnostic only, for 4.4;
  nothing releases on it.
- **Forwarding.** `forward/2` catches every exception from signalling, logs
  it to stderr, and keeps waiting for the child. It never treats EPERM as
  termination.
- **Final cleanup.** After `wait_unreaped/1` returns: `killpg(SIGKILL)` on
  the command group, logging errors and not trusting them. Then:
  - With `:cgroup`, as today (`cgroup.kill`, then the cgroup's `populated 0`
    decides).
  - With `:none`, wait up to 2 s for SIGKILL to take effect, then list the
    same-uid processes carrying this attempt's marker
    (`ps -E -o pid=,stat=,command=` on macOS; *open*: an equivalent with
    equal coverage), ignoring zombies (`stat` starting with `Z`). If none
    remain, reap and `finish` as today: best-effort completion under the
    explicit scope of invariant 2. If any remain, or the listing fails, send
    `finish` with the new field `processes_remaining: true` and the list
    (pid, stat and command, bounded).
  - This replaces #267's darwin EPERM exception in `signal_group/2`.
- **Self-test.** `ptc-operation self-test` exercises `wait_unreaped/1`,
  forwarding, group kill and the marker listing on a child with a
  grandchild, and exits non-zero on any failure. Readiness runs it (6.1).

### 4.2 Server: finishing with remaining processes

`ResourceOperationBroker` validates and forwards `processes_remaining` and
its list on `finish` (today it drops unknown fields).
`ResourceOperations.finish/4` with `processes_remaining: true` moves the
operation to `recovery_pending`, keeping `slot_number` (today exit 75 is
terminal `failed`). `last_error` records the list. `recovery_pending` is
already a leased state, so the slot index
(`resource_operations_one_active_owner_per_slot`) and capacity counts keep
it fenced with no index change. Commit 2 lands this with the wrapper change
and its failing tests.

### 4.3 Uncertain operations on a host without containment

`ResourceOperationRecovery.recover/1` dispatches on the profile's
uncertain-operation policy (section 3), not on containment alone:
- `:linux` is unchanged in every case, with or without cgroups.
- `:macos` and `:development` return a new outcome, `{:fenced, evidence}`.
  `evidence` holds:
  - the marker listing, or the listing error;
  - whether the wrapper pid is alive;
  - whether the operation's slot lock is free, checked with a
    non-blocking `flock` on `operation-slot-<n>.lock` that is released
    immediately.

`ResourceOperationBroker` handles `{:fenced, _}` by:
- recording it once on the operation (`last_error`, bounded);
- surfacing a stall `operation_fenced` that names the operation, its job, the
  evidence and the slot it holds;
- re-inspecting every sweep, but **not** entering maintenance. Global
  maintenance stays the Linux policy for recovery that fails with cgroups.

Every other part of the console keeps running. Only work waiting for that
slot waits.

### 4.4 Maintainer release

**Release operation** is offered on the Operations page and in the stall
card, for a fenced or escalated operation, including in maintenance mode.
PtcManager signals no pid itself, because no identity-safe signalling exists
on macOS.

**What it shows**, refreshed when opened:
- the evidence from 4.3;
- for each listed process, a copyable `kill <pid>` line, so the maintainer
  can stop processes they have checked.

**When it is offered:**
- **Release** needs the slot lock to be free (the wrapper is gone). While
  the lock is held, the action says which wrapper pid holds it and offers
  nothing else. Releasing then would hand out a slot whose lock still
  blocks the next operation.
- When the lock is free and marker processes are still listed, **Release**
  asks the maintainer to confirm that they accept those processes may still
  run.

**How it releases:** with one guarded update, from expected state
`recovery_pending` with the expected attempt token to `lost`, through
`release_recovered/4`. A heartbeat, a late `finish` or a `cancel/3` that
changes the state first makes the release fail with a message to refresh.
After the release, any request from the old wrapper is refused (4.1), so a
paused wrapper that resumes stops its command.

**Audit:** `resource_operation.released`, with the actor, the evidence and
whether processes were listed. This replaces the RPC release used on
2026-10-21.

## 5. Ownership of agent runs (fixes F10)

- Migration: allow role `observed`, and reclassify existing runs with
  `job_id IS NULL AND agent_action_id IS NULL AND role = 'implementer'` to
  `observed`.
- `Herdr.Sync`: a pane that neither `maybe_attach_managed_attempt` nor
  `maybe_attach_agent_action_attempt` binds is stored as `observed`. A later
  successful attach sets the managed role and the owner in the same update.
- **Consumers.** The implementer greps every `AgentRun` query that filters by
  state or role and lists them in the PR. At least:
  - `Deployments.drain_blockers/0`;
  - `Operations.dispatch_capacity/1` and the worker slot counts;
  - agent stalls in `Stalls`;
  - the cancel-agent handlers in `DeliveryBoardLive` and `OperationsLive` and
    the operations they call.

  Each considers owned runs only. An observed run is refused by cancel, with
  a message.
- The drain status text says "PtcManager-owned agents". The Operations page
  lists observed panes separately as "Other Herdr panes".

## 6. Readiness and observability (fixes F7, F11)

### 6.1 Readiness

New `PtcManager.Machine.Readiness`. It is evaluated at boot, refreshed with
the tool inventory, and rechecked from the banner. Each check has a key, a
status and one sentence:

| Check | Fails when |
|---|---|
| `paths` | a profile path fails its kind (section 3) |
| `helpers` | a helper the profile runs from the service root is missing, not executable, or differs from the copy packaged in this release (manifest below) |
| `operation_wrapper` | `ptc-operation self-test` fails |
| `operation_broker` | a `ping` through the broker fails. `ping` is a new broker request that authenticates a readiness-only context created by `ManagedOperationContext`, checks the socket and context directory, and creates no operation |
| `reconcile` | dispatch is enabled and `result_reconcile_interval_ms` is 0. Blocking on `:macos` and `:development`; on `:linux` reported in the banner but not blocking (invariant 1) |
| `publication` | dispatch is enabled and the selected mode is not usable: broker without its configuration (`GitHub.AppBroker.configuration_status/0`, a new public read-only function returning `:ok` or `{:error, missing_keys}`), or agent mode with no GitHub login for the agent identity (`gh auth status`, read-only) |
| `agent_login` | an enabled agent kind fails `WorkerAgentLogin` (already probed by the inventory) |

**Packaged helper manifest.** The release build writes
`priv/host-helpers.json` with the SHA-256 of each `deploy/` helper a profile
runs from a service root: `ptc-operation`, `ptc-manager-worker-review`,
`ptc-manager-worker-agent-login` and `macos-deploy-host`. The check compares
the installed copies against it. On `:linux` it is skipped for helpers the
deployment script installs.

**Effect.**
- A failing check blocks admission through `Machine.Gate` with the new reason
  `:host_not_ready`. That covers every caller of `Gate.check/…` and
  `Gate.waiting?/1`, the repository filtering in
  `Gate.unsatisfied_repository_ids/0`, reviews, resume and maintainer
  actions.
- The console shows a persistent banner naming each failing check.
- Inspection, deployment, configuration and 4.4 stay available.

### 6.2 Defaults

- **Result reconciliation (`:macos` only, so Linux is unchanged):**
  `PTC_RESULT_RECONCILE_INTERVAL_MS` defaults to 10000 when dispatch is
  enabled. An explicit 0 with dispatch enabled fails readiness on `:macos`
  and is reported on `:linux`.
- **External pull requests:** a new `PTC_EXTERNAL_PR_RECONCILE_ENABLED`. When
  unset it follows `PTC_PR_RECONCILE_ENABLED`, which is today's behaviour.
  README: "import pull requests PtcManager did not open".
- **Unattended launch flags move into code:**
  - `HerdrAdapter.agent_arguments` and `GenericHerdrAdapter` append, per
    kind, the flags that keep startup non-interactive (Codex: `-c
    check_for_update_on_startup=false`, next to `CodexTrust.override_args`),
    whatever `PTC_AGENT_PROFILES_JSON` says.
  - Applying it on Linux too is allowed, as a behaviour change, and must be
    recorded in Design decisions: it only removes a prompt that blocks an
    unattended start.
  - After deploying, the maintainer removes the flag from the Mac mini's
    `PTC_AGENT_PROFILES_JSON`.

### 6.3 Dispatch observability

- Migration: add `jobs.dispatch_blocked_reason` and
  `jobs.dispatch_blocked_at`. They are written only while a job is `queued`,
  and cleared on lease or cancel. The reason comes from one of three places:
  - **gate-filtered repositories.** `run_once` excludes them before picking a
    job. Their queued jobs get the gate's reason (`:machine_incapable`,
    `:cluster_fenced`, `:host_not_ready`), written only when it changes;
  - **a `run_once` error** before the lease, recorded on the selected job;
  - **a `lease_job` rollback** that leaves the job queued.
- An error after the lease is the job's own `last_error`, as today, and is
  never written as a blocked reason.
- The Operations work queue shows the reason next to "Waiting for a capable
  machine".
- The `machine_incapable` stall covers any pre-lease reason older than its
  threshold.
- `Dispatch.Poller` logs a reason once when it changes, and logs recovery.
  Identical consecutive failures back off from 5 s, doubling to 60 s, and the
  backoff resets on any change.

## 7. Deployment and health revisions (fixes F9; closes #261, #256, #255 part 1)

- **Existing eligibility stays.** `Deployments.configured_repositories/0`
  (the list the Deployments page shows) and `Deployments.request/2` both
  still accept an enabled repository with a deployment contract.
- **Added exception for this member's own repository:** a repository whose
  checkout path equals `Host.self_source_path/0` is listed and deployable
  even while disabled here, and needs no cluster claim. On `:macos` that path
  is `PTC_MACOS_SOURCE`; on `:linux` it is nil, so Linux is unchanged. Both
  call sites get the exception. Nothing else a disabled repository refuses
  changes. README "Several machines" documents it.
- **Health reads the fetched revision.** `Repository.Health.gate_health/2`
  reads the contract at the commit the configured `:source_updater` returns
  for the default branch, which is what dispatch and `LocalRevisionSource`
  use.
- **Clearer branch errors.** `SourceUpdater` distinguishes a branch missing on
  GitHub (`git ls-remote` shows no ref) from a fetch, authentication or
  network failure. Health reports "Branch `<b>` is not on GitHub" or "Could
  not fetch `<b>`: …", never "Commit the repository".

## 8. Tests and CI

Each fix starts with a failing test (invariant 9).

- **Python contracts** (`test/delivery_metrics_contract.py`,
  `test/review_worker_contract.py`):
  - EPERM during forwarding is logged and the wait continues;
  - final cleanup with a surviving marker process reports
    `processes_remaining`; with a zombie-only group it finishes normally;
  - a mixed zombie and live group;
  - a signal before `Popen` is delivered;
  - `self-test`;
  - fix `test_cleanup_uses_no_follow_directory_descriptors`, which errors on
    macOS on origin/main.
- **Wrapper end-to-end** (`resource_operation_wrapper_e2e_test.exs`,
  `resource_e2e`, fake broker):
  - a command that leaves an escaped grandchild (`setsid`) yields
    `processes_remaining`;
  - a normal command finishes as today;
  - the wrapper SIGKILLed mid-run leaves the operation for 4.3;
  - a cancelled, terminal or missing `running` response starts no command;
  - a stale-token refusal kills the command;
  - an escaped grandchild that keeps the marker is reported, and one that
    clears its environment is documented as undetected (asserted
    explicitly);
  - zombie-only and delayed-exit groups finish normally.
- **Lifecycle integration** (new, `resource_e2e`, temporary database and
  socket, never the live console): the real `ResourceOperationBroker` and the
  real `deploy/ptc-operation` run request → acquire → running → heartbeat →
  finish. Failure injections: broker restart mid-run, the wrapper killed
  before and after `running`, and a release racing a paused wrapper.
- **Broker and recovery** (`resource_operation_broker_test.exs`,
  `resource_operations_test.exs`):
  - `finish` with `processes_remaining` keeps the slot;
  - `{:fenced, _}` raises the stall and never enters maintenance on
    `:macos`/`:development`;
  - Linux escalation is unchanged;
  - Linux with `resource_operation_cgroups=false` still escalates to
    maintenance exactly as today;
  - the broker forwards and validates `processes_remaining`;
  - the maintainer release is refused while the slot lock is held, and its
    guarded update loses cleanly to a racing heartbeat, a late finish and a
    cancel;
  - the release is audited.
- **Host:**
  - `PtcManager.MacOSRuntimeTest` asserts every `:macos` path and the boot
    refusals;
  - `Host` unit tests for all three profiles and both identities;
  - the invariant-3 grep test;
  - Linux `{:separate, user}` helper commands are byte-for-byte unchanged.
- **Ownership:**
  - an observed working pane does not block `drain_blockers/0`, consume
    capacity, or accept cancel;
  - a managed `impl_j<id>_f<token>` pane still does;
  - a late attach restores the managed role;
  - the migration reclassifies existing rows.
- **Readiness:**
  - each check failing and passing;
  - `:host_not_ready` through every `Machine.Gate` entry point;
  - queued jobs of a gate-filtered repository show the gate's reason; the
    reason changes and clears on lease; a post-lease error never writes it;
  - the banner;
  - `ping`.
- **Deployment and health:**
  - a disabled own repository is listed and deployable on `:macos`, but not
    on `:linux`;
  - health uses the fetched commit;
  - a missing branch and a fetch failure produce different messages.
- **CI:**
  - a new job on `macos-latest` running the Python contracts,
    `mix test --include resource_e2e test/ptc_manager/resource_operation*`,
    `test/ptc_manager/macos_runtime_test.exs`, and the host and readiness
    tests, on every PR while it stays under 10 minutes (*open*);
  - the Linux nightly also includes `resource_e2e` for the wrapper suite;
  - any new slow real-process test is tagged `:nightly`.

## 9. Delivery: one pull request, reviewed commits

One branch, one PR, one commit per row. Each commit compiles, passes
`mix precommit`, leaves every profile working, and updates the README and
docs it affects.

| # | Commit | Contents |
|---|---|---|
| 1 | `ci: run the wrapper contracts and end-to-end tests on macOS` | macOS CI job with today's tests; fix the macOS-only contract failure; Linux nightly `resource_e2e` |
| 2 | `fix(operations): never treat EPERM as termination; finish with remaining processes keeps the slot` | 4.1 (handlers first, forwarding, final cleanup, marker), 4.2, their failing tests first; replaces #267's exception |
| 3 | `feat(host): resolve one host profile and route platform decisions through it` | section 3: profiles, paths, helper table, boot refusals, migrated call sites, grep test. May be split into identity and helpers / paths / trust |
| 4 | `feat(operations): fence uncertain operations without maintenance and let a maintainer release them` | 4.3, 4.4, wrapper `self-test` |
| 5 | `feat(config): defaults that follow from the host and unattended agent launch` | 6.2 |
| 6 | `fix(herdr): only PtcManager-owned agent runs hold drains and capacity` | section 5, with its migration |
| 7 | `fix(deployments): deploy this member's own release and read health at the fetched revision` | section 7 |
| 8 | `feat(machine): host readiness gate and pre-lease dispatch reasons` | 6.1 (with `ping` and the helper manifest), 6.3, migration |
| 9 | `docs: supported host matrix and macOS setup` | README matrix (Linux; macOS same account, no containment, fenced uncertainty), `deploy/ptc_manager-macos.env.example`, launchd plist examples, `docs/maintainers/host-profiles.md`; deletes this plan |

Readiness (8) lands after every default and mechanism it checks. The
implementer may change the cut and records why.

### 9.1 Review loop per commit

This is the implementer's own review of its commits, separate from
PtcManager's managed review rounds. For each commit: a fresh `codex review`
of that commit's diff in a clean checkout (`codex review --base <previous
commit>`), then fix and review again. **At most 5 rounds per commit.**

A finding still open after round 5 is either fixed without further review
and recorded, or recorded with the reason it was not fixed. Either way the
PR asks the maintainer to decide on it. The PR records each commit's rounds
and unresolved findings.

### 9.2 Running on the Mac mini

**Allowed:**
- the test suites, including `resource_e2e` and the Python contracts;
- `deploy/ptc-operation self-test` from the working tree.

**Not allowed:**
- restarting services or deploying;
- editing `/Users/Shared/ptc-services/config/*.env` or the installed helpers;
- touching the console's database.

Validation on the live console happens after the maintainer deploys and
installs the helpers.

### 9.3 Pull request

The description follows AGENTS.md, with three sections: **Summary**,
**Validation** and **Retrospective**. The Summary carries a "Design
decisions" list (decision, alternatives, reason) and the per-commit review
record. It closes #256, #261 and #268 (this plan's tracking issue), and states that
#255 is resolved only for part 1.

## 10. Implementer freedom and the decision record

Open decisions: names and shapes in 3 and 4; the process listing in 4.1;
readiness check list and thresholds; backoff values; the macOS CI trigger;
the commit cut.

Not open: section 2, and the rejected automatic macOS recovery (section 1).

### 10.1 Plan review record

This plan had three codex review rounds. Findings still open after round 3
were fixed in the plan without a further review:
- invariant 2's scope for normal completion;
- no automatic pid signalling in 4.4;
- the exact launch acknowledgement and stale-token refusal;
- the slot-lock condition for release;
- Linux recovery policy kept per profile;
- the reconcile check not blocking on Linux;
- the lifecycle integration test;
- blocked reasons for gate-filtered jobs.

The implementer should treat these sections with the same scrutiny as code
under review.

Every change from this plan, and every decision the plan does not cover, goes
into the PR's Design decisions. `docs/maintainers/host-profiles.md`
describes the shipped architecture, not its history. When a decision touches
a section 2 invariant, stop and ask the maintainer.

## 11. Out of scope

- Automatic recovery of uncertain operations on macOS (needs real
  containment: launchd-per-operation, a separate account with process
  accounting, or Endpoint Security).
- Running macOS agents under a separate account.
- A generic plugin mechanism for hosts.
- Logging and backoff for pollers other than `Dispatch.Poller`.
- The integration-branch console scope (local branch
  `feat/scope-to-integration-labels`); the existing Branch filter covers it.
- #255 parts 2 and 3.

## 12. Acceptance

1. On the Mac mini after deployment, a job whose command passes finishes
   normally through the wrapper, including when it leaves no process behind.
2. A command that leaves a running process, including one that escaped with
   `setsid`:
   - keeps its slot as `recovery_pending`;
   - shows an `operation_fenced` stall naming the process;
   - does **not** put the console into maintenance;
   - once the maintainer has stopped it with the listed `kill` line, is
     cleared by **Release** without RPC.
3. A wrapper SIGKILLed mid-run on macOS produces the same contained, visible
   state, never maintenance.
4. A forwarded SIGTERM reaches a live command group on macOS; EPERM is
   logged, not trusted.
5. No module outside `PtcManager.Host` reads `herdr_run_as_user`,
   `:os.type()` or `PTC_MACOS_SERVICE_ROOT`. Linux helper commands, recovery
   and escalation are unchanged.
6. On the Mac mini, with dispatch enabled and
   `PTC_RESULT_RECONCILE_INTERVAL_MS` unset, finished jobs reconcile.
7. An outdated `ptc-operation` in `<service root>/bin` shows the readiness
   banner and admits no work. A broken socket fails `operation_broker`.
8. An interactive Claude Code pane in the Herdr session does not hold a
   deployment drain and cannot be cancelled from the console.
9. The Mac mini deploys its own release with `ptc_manager` disabled there and
   claimed by herdr-build-01, and repository health shows the contract of the
   fetched default branch.
10. A dispatch blocked before leasing shows its reason on the Operations page
    within one poll, and logs it once.
11. Codex agents start unattended with the Mac mini's
    `PTC_AGENT_PROFILES_JSON` back to its pre-2026-10-21 value.
12. The macOS CI job and the Linux CI pass.
