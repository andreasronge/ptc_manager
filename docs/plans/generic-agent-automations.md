# Generic Agent Automations

Status: Proposed design plan  
First pilot repositories: `andreasronge/ptc_runner`, then `andreasronge/ptc_manager`

User-experience review: [interactive scenarios](../automation-plan-review.html)

## Purpose

PtcManager should let a maintainer define useful agent work once and decide how
that work starts. The same action may be launched manually from a contextual
button, run immediately from its configuration page, or be triggered on a
schedule. Later it may also react to a GitHub event.

Examples include:

- prepare or review an issue;
- implement an approved issue;
- fix and merge a pull request;
- produce a private repository status update;
- inspect failed nightly CI and create or update GitHub issues;
- review stale issues or dependencies;
- eventually deploy an exact merged revision and verify its health.

The system must remain understandable on a phone, show why every agent started,
and preserve the exact prompt and repository state used by every run.

## Goals

- Support any number of private GitHub repositories owned by the maintainer;
  `ptc_runner` and `ptc_manager` are only the first pilots.
- Make agent actions repository-specific, without a repository-wide prompt.
- Use one action definition with one or more manual or scheduled triggers.
- Generate board buttons from action configuration instead of a hard-coded
  catalog.
- Send new automation work through Herdr and select any capable available agent
  by default, with optional preferred or required capabilities; independently
  choose read-only access, trusted direct `gh` access, or brokered publication.
- Treat Herdr agent kinds as opaque integration identifiers. Adding a healthy
  kind must require configuration and capability checks, not a PtcManager code
  branch or a vendor-specific result parser.
- Show the complete resolved prompt, including generated coordinator text.
- Keep hard enforcement outside prompt prose.
- Retain every run, its trigger, prompt version, source SHA, agent, output, and
  reported GitHub changes.
- Use durable Elixir-native scheduling while keeping PtcManager, rather than a
  Herdr terminal session, as the durable job queue.
- Make adding an ordinary automation a configuration task rather than an Elixir
  code change.

## Non-goals for the first release

- A general workflow programming language.
- Arbitrary boolean expressions controlling button visibility.
- Automatic parsing of prompt prose to infer permissions, queue locks, or UI
  placement.
- Multiple PtcManager web nodes sharing SQLite.
- Automatic self-deployment of PtcManager.
- Replacing the existing issue, PR, Herdr, and Operations domain records with
  Oban records.
- Removing the optional GitHub App publication broker.

## Product principles

### Prompt-defined actions, not prompt-parsed actions

The prompt specifies what the agent should do. Small structured fields specify
facts PtcManager must know before the agent runs: target type, UI placement,
GitHub access, queue lane, locking policy, executor, timeout, and result type.
PtcManager must not guess those facts by interpreting prose.

### Configuration is snapshotted

Editing an action affects only future runs. A queued or running action retains
the exact definition version, resolved prompt, trigger context, repository, and
source SHA it started with.

### Prompt policy is visible; enforce only what the credential boundary can enforce

The UI should display the full prompt and allow the maintainer to edit the
human-readable action and policy instructions. Path containment, credential
selection, concurrency locks, output validation, and brokered publication gates
remain enforced by PtcManager.

An agent given the worker's unrestricted authenticated `gh` identity can act
outside the intended target, publish before a gate runs, or continue after a
PtcManager lock is lost. That mode is useful for the maintainer's trusted
personal agents, but its target and gate policy is advisory and auditable, not
technically enforceable. The UI and audit log must say this plainly. A workflow
that requires exact-target or exact-SHA enforcement must use a credential-free
agent plus a narrow broker/wrapper carrying a fencing token.

### GitHub is authoritative for GitHub state

PtcManager stores configuration, queue state, audit history, private summaries,
and run provenance. GitHub remains authoritative for issues, pull requests,
checks, labels, and merge state.

Issue workflow and execution workflow have separate sources of truth:

- GitHub owns whether an issue is open or closed, its assignees, and its
  repository-configured workflow labels, native `blocked by`/`blocking`
  relationships, and PR open/merged/closed state.
- PtcManager owns whether one of its invocations is queued, running, retained,
  reconciling, or complete, plus its internal target and resource claims.

PtcManager does not duplicate issue state in a second editable state machine.
It derives board placement from GitHub plus its own active execution records.
Generic agents, following their configurable prompts, perform GitHub issue
updates and label changes with `gh`; PtcManager reconciles the result afterward.

## UX design

The UX should be implemented before the generic database model is considered
finished. The screens below define the minimum concepts the model must support.

### Navigation and repository selection

Add an **Automations** item to the primary navigation.

Every repository-aware page gets a compact repository selector populated from
the configured repository registry. It includes `All repositories` where an
aggregate view is meaningful and health indicators when synchronization,
authentication, checkout, or gates are unhealthy. The registry is not limited
to the two pilot repositories.

The selected repository is represented in the URL, for example
`?repo=andreasronge/ptc_manager`. When the URL has no selection, a small
LiveView hook restores the last choice from browser `localStorage`. This keeps
links shareable and back/forward navigation correct while remembering the
choice independently on the Mac and phone.

### Automations index

The index is scoped to one repository by default. Each automation card shows:

- name and short purpose;
- enabled, paused, or unhealthy state;
- target type: repository, issue, or pull request;
- Herdr agent policy and the actual assigned agent when running;
- GitHub access level;
- manual button placements;
- schedule summaries;
- next scheduled run;
- last run outcome and time;
- queued or running status with the same spinner language used elsewhere;
- `Run now`, `Edit`, and `History` actions.

Primary actions:

- **New automation** opens the action editor.
- **Run now** uses the same action definition and queue as any other trigger.
  It is available directly for repository-target actions. Issue and PR actions
  require a target picker, or are run from the contextual card that supplies
  the target.
- **Pause** disables all future triggers without deleting configuration or
  history. Pausing the whole automation is different from pausing one schedule:
  it blocks manual buttons and Run now too. It does not cancel a domain job
  that was already atomically materialized before the pause.

The page should favor readable cards on mobile and a denser table on wide
screens. Advanced queue details are not shown unless requested.

### Agent profiles and health

Configuration gets an **Agent profiles** panel for the current Herdr worker. It
shows every configured profile, its Herdr kind, objective capabilities,
concurrency limit, active count, last health check, and installation or
authentication problem. It also explains that the selector applies to future
runs; an already queued invocation retains its snapshotted selector.

The normal action editor offers only `Any eligible`, `Prefer`, and `Require`.
Installation paths, launch arguments, credentials, and capability attestation
remain in an advanced admin surface. A **Test profile** action performs the same
non-interactive checks used by dispatch and returns a readable diagnostic. It
must not consume a real repository task or silently mutate a checkout.

### Action editor

The editor is a short guided form, not a raw record editor.

#### Basic section

1. Repository, fixed after creation unless the action is duplicated.
2. Name and short description.
3. Target: repository, issue, or pull request.
4. Agent through Herdr:
   - any capable agent (recommended);
   - prefer a configured agent profile or kind, with fallback;
   - require a configured profile, kind, or objective integration capability
     only when the action genuinely cannot run without it.
5. GitHub access:
   - none;
   - read-only;
   - trusted direct `gh` access;
   - brokered publication where the execution profile supports it.
6. Prompt.

There is no repository-wide prompt. An action may be duplicated to another
repository and edited there.

#### Trigger section

An action may have zero or more triggers:

- **Manual button**: choose one supported surface and a button label.
- **Schedule**: initially available only for repository-target actions; choose
  a friendly frequency, local time, and timezone, and expose the cron
  expression only under Advanced.

Initial manual surfaces are deliberately finite:

- repository Automation page;
- Planning: open issue;
- Planning: implementation-ready issue;
- Delivery: PR needing attention;
- Delivery: PR ready to merge.

The editor previews where each button will appear. Unsupported combinations,
such as an issue action on a PR card, are rejected before saving.

#### Advanced section

- planning or writing queue lane;
- light or heavy resource class;
- concurrency policy;
- repository lock type;
- timeout;
- result presentation;
- enabled state.

Safe defaults come from the selected target and surface. Most actions should
not require opening this section.

#### Prompt preview section

Show the exact future prompt in four visibly separate blocks:

1. **Coordinator context**: generated repository, target, SHA, job identity,
   and trigger facts.
2. **Operational policy**: visible maintainer-editable policy text.
3. **Action instructions**: the main maintainer-editable prompt.
4. **Result contract**: generated output requirements.

The preview labels generated and editable text. Saving produces a new immutable
definition version and an audit entry. A previous version can be viewed and
restored as a new version. Activating a new version revalidates every existing
trigger against its target type and execution profile. PtcManager refuses an
incompatible activation and links to the triggers that must be changed or
removed; it never leaves a targetless schedule behind.

### Trigger editor

#### Manual trigger

Fields:

- button label;
- surface;
- supported target state;
- optional confirmation text.

A manual trigger never bypasses the queue. Clicking it creates a normal run and
immediately gives visible queued feedback on the originating card.

#### Scheduled trigger

Fields:

- enabled;
- friendly recurrence: daily, weekdays, weekly, monthly, or custom;
- local time and timezone;
- next occurrence preview;
- optional `Run now` button.

The page shows the persisted next execution and the linked agent run after it
fires. Pausing invalidates the current schedule version and cancels its future
scheduler job but retains history. In the first release, scheduled issue or PR
actions are rejected because they do not have an exact target. A later target
selector may snapshot a query and the selected target IDs for each occurrence.

Pausing or archiving the parent automation atomically increments the version of
all its schedule triggers and cancels their known future jobs. Every due worker
rechecks both trigger and parent enabled state plus schedule version. Resuming
the parent creates a new future occurrence only for triggers that are still
individually enabled; it does not silently re-enable a trigger the maintainer
paused separately.

Activating a compatible new definition version also increments each schedule
version, invalidates its pending occurrence, and inserts a replacement carrying
the new immutable definition version. This makes “editing affects future runs”
literal and prevents a due worker from consulting whatever version happens to
be current later.

### Contextual board buttons

Planning and Delivery ask PtcManager for applicable enabled manual triggers for
the card's repository, target type, surface, and state. The board does not know
action keys such as `repair_and_merge_pr`.

The initial configuration seeds ordinary editable actions rather than special
Prepare/Review code paths:

| Surface | Button | Action |
| --- | --- | --- |
| Open issue | Triage issue | Decide whether the issue is worth doing; clarify, reject, defer, identify dependencies, or make it ready |
| Open issue | Make implementation-ready | Assuming the issue should be done, investigate feasibility and rewrite it until implementation is safe |
| Ready issue | Approve and start | Implement and create a PR |
| PR needing attention | Fix and merge | Repair, verify, and merge the PR |
| PR ready to merge | Prepare merge decision | Produce the private merge brief |

Button labels and prompts are editable. `Triage issue` may retain the current
user-facing label `Prepare issue`; `Make implementation-ready` may retain
`Review issue`. The distinction comes from their configured prompts, not from
an action key, skill, parser, or different Herdr mechanism. Either action may
update the GitHub issue and may make it ready when its prompt concludes that no
further review is needed.

The separate default `Fix` action is removed or disabled. `Fix and merge` is
one action with one button. Its trusted-direct or brokered GitHub capability
and merge lock are structured configuration; its desired behavior is expressed
by its prompt.

### Issue readiness, labels, and claims

Each repository configures a deliberately small workflow-label mapping. The
initial recommendation is:

- `ptc:ready` — the open issue is sufficiently defined and feasible to approve;
- `ptc:blocked` — a non-issue external condition must change first;
- `ptc:needs-decision` — the agent needs a named maintainer choice.

No separate `claimed` label is required initially. GitHub assignees and the
repository's existing claim-comment convention are the visible claim signal.
PtcManager shows an external-claim icon when synchronization sees such a signal,
including work started outside PtcManager.

An issue is eligible for the Ready lane when GitHub reports it open with the
configured ready label, without the configured blocked or needs-decision labels,
and with no unsatisfied native GitHub dependency. An active PtcManager target
claim or an external GitHub claim is displayed separately and prevents a second
automatic start unless the maintainer explicitly overrides it.

Immediately before materialization, PtcManager refreshes and records the
authoritative GitHub target state. It refuses a stale start when the issue has
closed, lost its ready label, gained a blocked or needs-decision label, or become
externally claimed since the board was rendered. It then takes an atomic
internal target claim before starting any action it owns. That minimal
coordinator logic prevents two PtcManager workers from racing.
The prompted agent still performs the GitHub assignment, claim comment, issue
rewrite, and label mutations. Claims created entirely outside PtcManager are
necessarily best-effort coordination through GitHub; preventing a simultaneous
external race would require a shared claim broker later.

### Native issue dependencies and blocked work

GitHub's native issue dependency relationship is authoritative for issue A
blocking issue B. PtcManager synchronizes `blockedBy` and `blocking` as a
read-only local projection for board rendering, queue eligibility, audit, and
fast reconciliation; it does not offer a second editable dependency graph.
Agents use the GitHub CLI/API relationship operations, not prose such as
“depends on #123” as the machine-readable contract. PtcManager verifies the
relationship from GitHub after the agent settles.

`ptc:ready` and dependency state are intentionally independent. An issue may be
well-defined and retain `ptc:ready` while waiting for another issue. Its card
shows `Ready · blocked by #A` with linked blocker titles and states. The generic
`ptc:blocked` label remains available for external blockers that cannot be
represented by a GitHub issue dependency, such as an upstream release or
missing third-party access.

Dependency satisfaction follows explicit rules:

- an open blocker is unsatisfied;
- a blocker closed as completed is satisfied;
- a dependency explicitly removed in GitHub is satisfied;
- a blocker closed as not planned is not silently satisfied: the dependent
  issue becomes `dependency needs decision` until a maintainer removes or
  replaces the relationship, closes the dependent issue, or explicitly accepts
  the outcome;
- reopening a blocker makes the dependency unsatisfied again;
- every blocker must be satisfied before implementation can start;
- an inaccessible or deleted cross-repository blocker is unknown and therefore
  blocks dispatch rather than failing open.

PtcManager detects dependency cycles, including cross-repository cycles it can
observe. Every issue in a cycle remains blocked and the UI shows the shortest
known cycle, for example `#A → #B → #A`, as `needs attention`; no issue in the
cycle starts automatically.

A maintainer may choose **Approve when unblocked** for an otherwise ready issue.
That creates one durable invocation in `waiting_on_dependencies`, but allocates
no Herdr agent, resource slot, repository lock, or worktree. When synchronization
observes all blockers satisfied, the normal atomic eligibility check may
materialize it once. Without that prior approval, the issue merely moves back to
Ready and still requires approval. Queue and Operations show each blocker and
why it is or is not satisfied.

Dependency state is refreshed when either side synchronizes, when an agent
reports a relationship change, before workspace creation, after bootstrap, and
immediately before agent start or publication. A late blocker addition therefore
prevents launch or publication even when the board was stale.

The simple-language triage explanation remains private PtcManager output and is
not copied into the issue. Durable implementation facts and decisions belong in
GitHub.

### Run detail and read-only output

Every queued or active item links to one run detail panel/page showing:

- action and definition version;
- trigger and trigger context;
- repository, target, source SHA, and started time;
- agent and Herdr session;
- queue lane and lock reason;
- live or retained read-only terminal output;
- full resolved prompt;
- final result, GitHub links, and reported GitHub changes;
- retry, cancellation, or failure history.

Prompt text is collapsed by default on a phone but remains accessible.

### Low-fidelity wireframes

These wireframes are acceptance artifacts for Slice 0. They intentionally show
information hierarchy rather than final colors or typography.

#### Automations index, desktop

```text
+--------------------------------------------------------------------------+
| Automations          [ptc_runner v]                [+ New automation]     |
| Repo healthy · gh trusted-direct · 2 queued · 1 running                  |
+--------------------------------------------------------------------------+
| Nightly CI investigator                         [enabled] [planning]       |
| Repository · any Herdr agent · trusted direct gh                       ! |
| Every day 06:30 Europe/Stockholm · next Mon 06:30                        |
| Last: no changes, 10h ago               [Run now] [Edit] [History]       |
+--------------------------------------------------------------------------+
| Daily update                                      [enabled] [planning]     |
| Repository · any Herdr agent · read only                                  |
| Every day 07:00 · next Mon 07:00                                         |
| Last: published summary, 9h ago          [Run now] [Edit] [History]       |
+--------------------------------------------------------------------------+
| Fix and merge                                     [enabled] [writing]      |
| Pull request · retained Herdr · trusted direct gh                         |
| Button: Delivery / needs attention              [Edit] [History]         |
+--------------------------------------------------------------------------+
```

The warning icon opens a short explanation of what direct credentials can and
cannot enforce. `Run now` is absent from the PR action because no PR is selected.

#### Automations index, phone

```text
Automations                         [+]
[ptc_runner v]

Nightly CI investigator       enabled
Repository · any Herdr agent
Tomorrow 06:30 · last: no changes
[Run now]  [Edit]  [History]

Fix and merge                enabled
PR · Delivery / needs attention
[Edit]  [History]
```

#### Action editor and prompt preview

```text
Edit automation: Nightly CI investigator

1 Basics       repository / any capable Herdr agent / trusted direct gh [!]
2 Instructions [editable prompt.................................]
3 Triggers     [x] Run now   [x] Daily at 06:30 Europe/Stockholm
4 Advanced     planning · one/action/repo · 20 min · common result

Prompt preview
  Generated coordinator context                      [generated]
  Operational policy                                 [editable]
  Action instructions                                [editable]
  Result contract                                    [generated]

[Discard]                                      [Save new version]
```

#### Contextual button and run detail

```text
Delivery card                                  Run detail drawer
+-----------------------------+                +---------------------------+
| PR #1722 · needs attention  | --click------> | Fix and merge · queued    |
| Fix viewer gate             |                | Waiting: merge lock       |
| [Fix and merge]             |                | Source: 10dd0371          |
+-----------------------------+                | Prompt v4 · manual button |
                                               | [View resolved prompt]    |
                                               | [Read-only agent output]  |
                                               +---------------------------+
```

The same status badge and spinner component is used on the originating card,
Operations, Automations, and run detail. Opening details must not collapse on a
LiveView refresh.

#### Schedule editor

```text
Schedule
[x] Enabled
Frequency  [Weekdays v]   Time [06:30]   Zone [Europe/Stockholm v]
Next run   Monday 31 Aug, 06:30
Missed runs after downtime: run once, then continue with the next future time

[Pause schedule]                                      [Save new version]
```

For an issue or PR definition, this section instead explains that schedules
need a future target-selector feature and offers contextual manual buttons.

### Failure and safety feedback

The UI distinguishes:

- waiting for an agent;
- waiting for a repository lock;
- scheduled for later;
- agent running;
- synchronizing GitHub state;
- scheduler retrying;
- agent needs attention;
- completed with no changes;
- completed with GitHub changes;
- failed before agent start;
- failed during agent execution.

A configuration-health problem links directly to the relevant repository,
action, authentication, gate, or trigger editor.

## Example automations

### Failed nightly CI investigation

Repository: `andreasronge/ptc_runner`  
Target: repository  
Agent: any Herdr agent with repository-read and trusted-`gh` capabilities  
GitHub access: trusted direct  
Lane: planning  
Concurrency: one active run for this action and repository  
Manual trigger: `Check nightly CI now` on the Automations page  
Scheduled trigger: daily after the normal nightly window

Prompt responsibilities:

- inspect the latest relevant completed Nightly workflow run;
- ignore a run already handled by this automation;
- inspect failed jobs and bounded failed logs;
- investigate repository code and recent changes;
- search open and closed issues for the same failure;
- update an existing issue or create a focused new issue;
- avoid duplicate issues on retry;
- make no code change or pull request;
- return a simple summary, evidence, workflow link, and GitHub changes.

Each schedule occurrence and invocation has a stable marker. When the scheduled
agent discovers the relevant workflow-run ID, it includes both markers in its
result and searches GitHub for an existing marker before creating an issue. A
future workflow-event trigger uses the workflow-run ID as its immutable event
delivery key.

The first implementation may inspect workflow runs on a schedule using `gh`.
A later GitHub workflow-completed poller or webhook trigger can start the same
action definition without changing its prompt or result history.

### Repository status update

Target: repository  
Lane: planning  
Result: private Markdown update stored and rendered by PtcManager

The action and schedule are enabled for `ptc_runner`. The action exists but is
disabled by default for `ptc_manager`. It may also have a `Generate now` manual
trigger.

### Fix and merge

Target: pull request  
Surface: Delivery, PR needing attention  
Lane: writing  
GitHub access: trusted direct initially; brokered publication when strict gate
enforcement is required  
Lock: exclusive merge lock for the repository

The prompt tells the retained or imported Herdr agent to repair conflicts or
failing CI, run repository gates, push the repaired branch, wait for required
checks, and merge the exact PR. In trusted-direct mode, these are audited agent
instructions rather than a credential boundary. In brokered mode, the broker
checks the PR, SHA, fence, and gate evidence before it pushes or merges. The
action may complete with the PR still open when the prompt reports a blocker;
PtcManager never performs a hidden merge merely because the action had merge
capability.

### Future deployment

Target: repository revision  
Lane: deployment  
Trigger: initially manual only

Deployment is a later typed capability. It accepts an exact merged SHA, runs a
fixed repository-owned deployment script, streams output, verifies migrations
and health, and records the deployed revision. The agent monitors and explains
the operation but may not invent a deployment command or deploy unmerged
worktree contents.

## Architecture

### Action definitions and immutable versions

Use the neutral name `automation_definitions` because one configured button may
materialize an existing `agent_action`, an implementation `job`, or later a
typed deployment. The definition is a mutable identity shell:

| Field | Purpose |
| --- | --- |
| `repository_id` | Required repository scope |
| `key` | Stable repository-local identifier |
| `name`, `description` | Human-facing identity |
| `enabled` | Master pause switch |
| `current_version_id` | Version selected for future invocations |
| `archived_at` | Soft deletion without losing history |

Add `automation_definition_versions`. Every field that can affect execution or
enforcement lives here, not only the prompt:

| Field | Purpose |
| --- | --- |
| `target_type` | `repository`, `issue`, or `pull_request` |
| `execution_profile` | Code-owned dispatch, workspace, and synchronization path |
| `agent_selector` | Immutable Herdr policy: any, preferred, or required capabilities/kind |
| `github_access` | `none`, `read`, `trusted_direct`, or `brokered_publish` |
| `queue_lane` | `planning` or `writing`; deployment later |
| `resource_class` | `light` or `heavy`; consumes the corresponding worker pool |
| `lock_policy` | Typed concurrency/serialization behavior |
| `timeout_seconds` | Bounded execution time |
| `result_type`, `result_protocol_version` | Common or typed specialized validator/presenter and its immutable envelope version |
| `operational_policy`, `prompt` | Maintainer-editable instructions |
| `configuration_snapshot` | Any remaining profile-specific immutable settings |
| `created_by`, `inserted_at` | Audit provenance |

A queued invocation copies or references this immutable version. Workers must
never read the current definition for agent selector, credentials, lane, locks,
timeout, result validation, prompt, workspace, or synchronization. Editing any
of these fields creates a new version and affects only future invocations.

Selecting a version as current is transactional with trigger validation and
scheduled-occurrence invalidation/replacement. A version whose target or
profile is incompatible with an existing trigger may be saved for inspection,
but cannot become current until that trigger is fixed or removed.

Keys identify behavior in audit history; code must not branch on keys for
button placement or dispatch. Dispatch is intentionally typed by
`execution_profile`.

### Execution profiles and adapters

The first release has a finite, code-owned registry:

| Profile | Existing domain path | Workspace and purpose |
| --- | --- | --- |
| `generic_ephemeral` | `agent_actions` | Fresh repository snapshot for ordinary configured analysis or maintenance |
| `retained_pr_repair` | `agent_actions` plus retained Herdr session | Repair or merge a specific PR while preserving its context and worktree |
| `implementation_job` | approval, `jobs`, Dispatch, and Herdr | Implement an issue in an isolated worktree and publish a PR |
| `private_daily_update` | `agent_actions` plus `daily_digests` publisher | Credential-free summary with the existing private update presentation |

Each profile declares supported target types, required PtcManager agent-profile capabilities,
workspace strategy, allowed credential modes, allowed resource classes, prompt
context builder, result schema, synchronizer/publisher, and lock policies. The
form filters invalid combinations and the server validates them again. Writer,
repair, merge, build, and test profiles require `heavy`; immutable-snapshot
planning profiles may allow `light`.

`generic_ephemeral` is the no-code extension point. Once implemented, a new
repository-level manual or scheduled action using its common result contract
requires configuration only. Specialized behavior—retained sessions,
implementation jobs, daily-update publishing, or deployment—uses a typed
profile and stays code-owned.

### Prepared workspace before agent start

PtcManager owns workspace orchestration; the agent does not initialize its own
checkout. For a writer action, PtcManager chooses and persists the repository,
exact source SHA, deterministic branch name, worktree policy, action version,
and launch identity. It then asks Herdr to create the isolated worktree and
workspace. Herdr performs that operation and returns the native worktree,
workspace, pane, and path identifiers, but it does not decide which revision or
branch PtcManager should use.

The agent starts only after this persisted, idempotent preflight succeeds:

1. atomically claim the refreshed target, repository lock, and worktree
   allocation;
2. synchronize the repository's canonical worker checkout and resolve the
   immutable source SHA;
3. call Herdr's worktree creation operation with the selected source and branch,
   then persist every returned native ID and path before continuing;
4. before executing repository code, verify the path is inside the worker's
   configured worktree root, is not a symlink or alias of another checkout, has
   the expected ownership and permissions, and contains the expected clean HEAD
   and branch under the configured credential isolation;
5. atomically claim the allowed light or heavy resource pool and selected agent
   profile, then run the repository-owned bootstrap command with a bounded,
   explicit environment that contains no agent prompt, GitHub write credential,
   or result-submission capability;
6. reverify containment, HEAD, branch, and cleanliness after bootstrap, and
   verify required toolchains, GitHub access mode, result broker, and repository
   gate configuration;
7. refresh and record authoritative GitHub eligibility again so a target change
   during bootstrap prevents launch;
8. mark the workspace `ready`, persist deterministic agent-start and
   prompt-delivery attempt IDs plus the resolved-prompt hash, mint the short-lived
   result token, and start or adopt the selected Herdr agent. A failed launch
   revokes the token;
9. before sending input, atomically change the prompt attempt from `pending` to
   `sending` and the invocation to `accepting_result`, then send the immutable
   prompt with its delivery marker. Record `accepted` only after Herdr confirms
   the prompt operation.

Planning actions normally use an immutable read-only snapshot rather than a Git
worktree. Writer, implementation, repair, and merge actions use an isolated
worktree. A retained same-task session reuses its prepared worktree, but
PtcManager revalidates its identity, HEAD, cleanliness, credentials, and result
directory before sending a follow-up prompt.

Repository-specific initialization belongs in the checked-in repository
contract rather than in an agent prompt. The initial `.ptc-manager.yml` shape is:

```yaml
version: 1
bootstrap:
  command: ./scripts/ptc/bootstrap
  timeout_minutes: 10
verification:
  before_publish: ./scripts/ci/pre-publication
  timeout_minutes: 45
```

The bootstrap script installs or verifies dependencies and generated assets in
an idempotent way. PtcManager supplies shared caches where safe, but the script
must not mutate another worktree. Global worker prerequisites such as Herdr,
Git, the configured agent CLI, Node, Elixir, and authenticated `gh` are checked
by worker/profile health, not repeatedly installed by each repository script.

If any preflight stage fails, no agent is started. Operations displays `failed
before agent start`, the exact failed stage, bounded command output, and safe
retry or cleanup choices. The recovery state machine below finds a workspace
using the persisted deterministic launch/worktree identity and adopts it instead
of creating a duplicate.

### Worker and agent crash recovery

Each worker reports a stable `worker_id`, an ephemeral `worker_incarnation_id`
for the current host/service boot, and a separate `herdr_incarnation_id`. Every
agent start already has its own immutable launch-attempt identity. Keeping these
identities separate distinguishes a host reboot, a Herdr restart, a coordinator
restart, and one crashed agent without guessing from a missing heartbeat.

A changed incarnation or interrupted authoritative heartbeat moves affected
active attempts to `recovery_pending`. It does not release their resource-slot,
repository-lock, branch, worktree, prompt-delivery, or publication claims and
does not authorize duplicate execution. The worker is unavailable for new work
until it supplies the configured consecutive healthy snapshots; the initial
default is two snapshots across a bounded observation window.

Recovery then reconciles each fenced attempt in this order:

1. verify the exact Herdr workspace, pane, agent, process, worktree, branch, and
   launch-attempt identities;
2. reconcile prompt-delivery state and any submitted result before sending more
   input;
3. inspect the retained worktree's source SHA, current HEAD, commits,
   cleanliness, gate evidence, and bounded terminal output;
4. refresh GitHub's authoritative issue, PR, remote-head, check, and merge
   state;
5. choose exactly one outcome below and record the evidence used.

The allowed outcomes are:

- A matching agent that is still working or blocked is adopted and its lease is
  renewed without another prompt.
- A matching native session that is idle may receive one bounded continuation
  prompt only after result, worktree, and GitHub reconciliation prove that work
  is incomplete. The agent must first inspect retained commits, tests, result
  artifacts, and any existing PR before changing files or repeating a GitHub
  side effect.
- A terminal session or apparently completed branch enters result
  reconciliation. It is never prompted merely because Herdr reports `idle` or
  `done`.
- An agent absent from consecutive authoritative snapshots may be replaced in
  the retained worktree only after the prior launch attempt is fenced and the
  old process is proven absent. The replacement receives a new fencing token,
  launch-attempt identity, and recovery-context packet.
- Ambiguous process, session, prompt, worktree, branch, result, or GitHub state
  remains fail-closed in `needs_attention`; the worktree and claims stay
  retained until a maintainer resolves or quarantines them.

The recovery-context packet contains the invocation and old/new attempt IDs,
new fencing token, repository and target, worktree and branch identities,
source/local/remote SHAs, known issue and PR state, retained output and result,
completed and failed gates, and an explicit instruction not to repeat a side
effect before checking whether it already occurred.

PtcManager never authorizes two attempts to write the same worktree or branch.
Brokered GitHub effects enforce the current fence and reject stale attempts. In
trusted-direct mode, however, an old authenticated agent cannot be technically
prevented from using `gh`; replacement therefore requires proof that its process
is gone, and ambiguous state is quarantined rather than described as safely
fenced.

Confirmed resource-exhaustion failures such as exit 137 or an observed OOM are
classified separately from transport loss and ordinary agent failure. Their
recovery attempts are serialized per worker, use bounded retry counts and
backoff, and do not start while host-pressure admission is closed. Recovery
keeps the original resource class and follows ordinary delivery priority, so a
merge recovery remains ahead of unrelated implementation work without creating
a restart storm.

Operations and run detail show the worker restart reason when known, old and
new incarnations, `recovery_pending`, `reconciling`, `resuming`, `replaced`, or
`needs_attention` state, attempt count, last evidence time, next retry, retained
claims, and whether maintainer action is required. Audit history records every
observation, fence change, adoption, continuation, replacement, and release.
Agent status alone is never proof of success.

### Cleanup lifecycle

Cleanup is a separate fenced lifecycle. Merge, PR closure, decline, explicit
abandonment, or failed preparation may atomically change an unowned worktree
from `retained`, `preflight_failed`, or `abandoned` to `deleting`. A resume or
follow-up may acquire ownership only while the worktree is `retained`; it cannot
race a committed `deleting` transition. The cleanup worker presents the current
lifecycle fencing token, verifies the exact
native Herdr/Git identities and contained path before every destructive step,
and records partial progress so a crash resumes removal rather than recreating
or deleting an unrelated workspace. Ambiguity moves the worktree to
`quarantined` for operator review. Worktree capacity is tracked independently
from active light/heavy agent capacity.

### Targets closed or merged while work exists

A GitHub target never silently disappears merely because it becomes terminal.
The Planning or Delivery card leaves the active lane, but its invocation remains
in Operations and run history with a prominent, acknowledgeable warning naming
the observed GitHub state, synchronization time, last source/head SHA, agent,
and retained output. A short `Recently changed externally` section keeps such
items discoverable from the originating screen; retention duration is a UI
setting, while the durable audit record is not deleted.

Reconciliation applies these stage-specific rules:

- **Queued or waiting:** an externally closed issue, merged PR, or PR closed
  without merge becomes terminal before capacity or a worktree is allocated.
  The run records `closed externally`, `merged externally`, or `closed without
  merge`, releases its claims, and never starts an agent.
- **Preparing or bootstrapping:** the existing authoritative refresh prevents
  agent launch. The run records the external change, releases active capacity,
  and schedules fenced cleanup of the unused workspace.
- **Agent actively working:** PtcManager immediately marks the run
  `external change detected`, blocks new prompts and every brokered publish or
  merge using its fence, and shows the warning. It does not kill the terminal or
  delete the worktree underneath a live process by default. It lets the current
  Herdr turn settle, accepts any final report only as audit evidence, reconciles
  GitHub as authoritative, and then transitions according to the terminal facts
  below. Cleanup runs only when no open PR or explicit maintainer decision still
  requires the retained context.
  Trusted-direct `gh` cannot be technically revoked, so its warning and prompt
  instruct the agent to stop; this limitation remains explicit in the UI.
- **Retained or previously completed:** no work resumes. History remains
  visible, the retained session is made ineligible for further prompts, and
  cleanup waits for the normal fencing and Herdr-idle proof.

The terminal outcome depends on the GitHub facts:

- a PR confirmed merged is success, even when another actor merged it;
- a PR closed without merge is declined/cancelled, not a failure disguised as
  success;
- an issue closed with no open managed PR ends its implementation invocation;
- if an issue closes while its managed PR remains open, the PR stays visible in
  Delivery and the run becomes `needs attention`: the maintainer chooses whether
  to continue the PR, close it, or reopen the issue;
- if a PR closes without merge while its issue remains open, the issue may
  return to Planning/Ready after cleanup, but the old approval is not reused and
  a new implementation requires a new explicit approval.

Reopening an issue or PR never resurrects a terminal invocation automatically.
Synchronization projects the reopened GitHub item back into the appropriate
board, while any new work receives a new invocation, eligibility check, prompt
snapshot, and usually a new worktree. An old retained session may be reused only
through an explicit same-task recovery action that proves its worktree and fence
still valid.

Cleanup requires both terminal GitHub state and proof that no Herdr process is
active. A working process delays cleanup; an unreachable or ambiguous process
quarantines the workspace. This preserves evidence and prevents an external
closure race from deleting files an agent is still using.

### Herdr is the launch and session boundary

Herdr 0.8.2 is a terminal, workspace, and agent lifecycle manager. Its CLI can
start an agent of an explicitly supplied `--kind`, prompt it, wait for it, read
its output, and retain its session. It does **not** currently provide PtcManager
with a durable job queue, task-capability advertisement, or a scheduler that
decides which agent kind is best for a task. A supported Herdr kind is not proof
that its executable and credentials are installed for the PtcManager worker's
OS identity.

The responsibility boundary is therefore:

- PtcManager owns definitions, durable queueing, locks, eligibility, capacity,
  deterministic selection, retries, and audit history.
- Herdr creates the workspace/pane, starts the explicitly selected kind, owns
  terminal/session lifecycle, and provides status and retained output.
- The selected agent CLI performs the prompted work inside that Herdr session.

PtcManager must not launch `codex`, `claude`, `cursor-agent`, or another model
CLI directly for new generic automation work. It selects a configured agent
profile, then calls Herdr with the profile's exact kind and launch arguments.
Outside the temporary compatibility adapters, production dispatch,
reconciliation, result ingestion, retry, and UI code may not switch on known
kind names. A newly configured Herdr kind uses those same paths unchanged.
The request and resulting invocation record contain:

- immutable prompt and result contract;
- repository snapshot or managed worktree reference;
- execution profile and required objective capabilities;
- credential mode and queue/lock metadata;
- optional exact retained Herdr session ID;
- immutable selector policy, selected agent-profile snapshot, and a
  preallocated deterministic Herdr launch identity;
- returned Herdr agent name, kind, pane/session identity, output reference, and
  terminal state.

If no eligible profile is healthy or has capacity, work stays visibly queued
with a reason. PtcManager never silently falls back to a direct model process.

#### Agent profiles

Add configured `agent_profiles` for the worker environment. A profile is an
operational installation, not a claim that one model is universally better:

| Field | Purpose |
| --- | --- |
| `key`, `display_name` | Stable configured worker identity |
| `herdr_kind` | Opaque open string passed unchanged to Herdr; examples may include `codex`, `claude`, or `cursor` |
| `enabled` | Administrative availability switch |
| `max_concurrency`, `priority` | Optional per-profile ceiling and deterministic preference |
| `capabilities` | Objective tested abilities required by execution profiles |
| `launch_configuration` | Code/admin-owned arguments and environment reference |
| `last_health_check` | Executable, authentication, Herdr integration, and start-test result |

Initial objective capabilities include:

- `workspace:read-snapshot` and `workspace:write-worktree`;
- `github:none`, `github:read`, and `github:trusted-direct`;
- `network:none` and `network:available`;
- `result:ptc-file-v1` for the generic result helper;
- later, typed `task:deploy` for a fixed repository-owned script.

Capability names describe tested integration facts, not subjective labels such
as “best at refactoring.” Credential and network isolation remain properties of
the execution profile and OS environment; a profile checkbox cannot enforce
them by itself. Launch arguments and credential references are admin-managed in
the first release rather than freely editable prompt configuration.

Health checks run as the same OS identity and non-interactive environment used
by the worker. They verify the executable, authentication, configured Herdr
integration, and a safe start/prompt/read lifecycle where practical. The UI
shows `ready`, `busy`, `unhealthy`, or `not installed`, including the failing
check and its time.

“Any agent” means any Herdr kind whose worker profile passes the objective
capabilities required by the action and supports unattended start, prompt,
status/output, and result submission. It does not mean PtcManager should try an
installed but unauthenticated or interactive-only integration. The distinction
is operational health, not a built-in allowlist of model vendors.

Add durable `agent_profile_slot_claims` rather than computing capacity from a
non-atomic count. Assignment runs in one SQLite write transaction that rechecks
profile enabled/health state, counts current profile and resource-pool claims,
inserts a unique claim for the invocation when both limits permit it, snapshots
the selected profile, and persists a unique launch-attempt ID plus a Herdr-safe
agent name derived from it. This transaction commits before repository bootstrap
or any agent-start command; Herdr workspace creation may already have completed
under the separate worktree allocation.
If the preferred profile loses its final slot, the same routing operation tries
the next eligible fallback; a required profile remains queued.

Claims carry a lease, heartbeat, and fencing token. They are held while bootstrap
is consuming the selected resource class, while Herdr is starting, and while the
agent is actively working. They are released after the result is captured or the
action terminally fails or is cancelled. A retained idle
session and worktree have their own lifecycle allocation and do not consume an
active execution slot; before PtcManager prompts that session again it must
atomically reacquire the same profile's slot. A blocked session may yield its
slot only if all resume paths, including user decisions, reacquire before
sending input. Otherwise it keeps the claim.

Workspace and pane labels also carry the launch-attempt ID. Before starting or
retrying, dispatch looks up the deterministic agent name: an existing live agent
is adopted rather than started twice. The returned native session and pane IDs
are added to the already persisted identity after Herdr responds.

Prompt delivery is a separately persisted side effect. A prompt attempt has an
immutable ID, prompt hash, and `pending`, `sending`, `accepted`, or `unknown`
state. A crash while it is still `pending` is safe to resume. A crash after the
state becomes `sending` is not automatically retried unless Herdr can prove that
the same delivery ID was not accepted. If acceptance cannot be proven either
way, PtcManager marks `prompt_delivery_unknown`, retains the agent, worktree, and
slot, and asks the maintainer whether to resend. An explicit resend creates a new
attempt and includes the stable invocation marker so the agent must first check
for an existing result or GitHub side effect. This is conservative at-least-once
recovery with duplicate safeguards, not a false exactly-once claim.

Coordinator, worker, Herdr, and individual-agent failure all use the single
worker-and-agent recovery state machine above. An expired lease, missing
heartbeat, or absent returned session ID is never enough by itself to release
capacity or create a replacement.

#### Light and heavy capacity

Each Herdr worker exposes two maintainer-configurable limits:

- `heavy_agent_slots` for implementation, builds, tests, PR repair, conflict
  resolution, and merge work;
- `light_agent_slots` for issue triage, readiness analysis, summaries, and other
  immutable-snapshot planning work.

Every immutable action version declares `resource_class: light | heavy`; this is
a visible Advanced setting whose choices are constrained by its execution
profile. It is never inferred from prompt prose. The server rejects a light
writer, build, repair, or merge action even if a crafted client bypasses the
form. A profile's own `max_concurrency` may impose a stricter ceiling, but does
not combine the two resource pools into one number.

A full heavy pool does not prevent a light planning action from starting when a
light slot and eligible profile are available. Light actions running beside a
repository merge must use immutable snapshots and no writer lock. Host CPU,
memory, or disk-pressure protection may temporarily stop all new starts even
when a configured slot remains; the UI reports that separately from ordinary
queue capacity.

Dispatch uses a throughput-oriented priority order within eligible work:

1. finish or reconcile a merge to the default branch;
2. repair a PR with failing CI or conflicts;
3. continue implementation work;
4. run issue planning and other maintenance automations.

Priority never bypasses repository locks or starves already-running work. Light
planning may still start during higher-priority heavy work because it consumes a
different pool. Aging raises long-waiting work within its class, and Operations
shows both configured limits, active claims, queued counts, and waiting reasons.

#### Deterministic routing

For each invocation, PtcManager:

1. routes a same-task follow-up to its exact retained session when that session
   and worktree remain valid;
2. otherwise filters enabled, healthy profiles by execution-profile
   requirements, credentials, workspace type, and selector requirements;
3. honors an explicitly required profile, kind, or capability;
4. honors a preferred profile or kind when eligible, with documented fallback;
5. tries the remaining profiles by priority and least claimed load, with a
   stable tie-breaker, and atomically claims a slot together with assignment;
6. retries the next eligible fallback when a concurrent dispatch wins a slot;
7. leaves the invocation queued with an explicit reason when none is eligible
   or all eligible profiles are at capacity;
8. snapshots both the selection explanation and actual Herdr assignment.

Unrelated work starts in a fresh isolated session. A long-lived session is not
reused merely because it is idle: it may contain task-specific conversational
context and a checkout belonging to another run. Retention is only for the same
implementation/PR lifecycle.

#### Initial routing policy

The action defaults describe requirements, not a permanent vendor assignment:

| Work | Initial selector |
| --- | --- |
| Triage or make an issue implementation-ready | Any read-snapshot planning profile with the generic result helper |
| Implement an issue | Any write-worktree/test profile; review behavior is part of the configurable action prompt |
| Repair or merge a managed PR | Exact retained session first; otherwise any eligible writer for an imported PR |
| Nightly CI investigation | Any planning profile with required GitHub access |
| Private daily update | Any credential-free read-snapshot profile |
| Future deployment | Require typed `task:deploy`, independent of agent brand |

PtcManager does not interpret “review this three times” as a Codex skill or a
model-selection rule. It is prompt behavior of the configured Herdr action. An
optional future policy may request a different agent profile for independent
review, but PtcManager should first collect comparable outcomes—success,
duration, retries, user intervention, and cost—before preferring Claude,
Cursor, or Codex for a category.

#### Current Hetzner pilot state

The 2026-08-31 inspection of `herdr-build-01` found:

- Herdr 0.8.2 with one idle Codex and one idle Claude interactive agent;
- Codex available to the automated `ptc-manager-worker` identity;
- Claude absent from that worker's non-interactive `PATH`, despite the manually
  running interactive session;
- Cursor not installed and its Herdr integration unavailable.

Therefore fresh automated jobs initially route only to the healthy Codex
profile. This is deployment state, not a Codex hard-code. Claude becomes
eligible after it is installed, authenticated, and health-tested for the worker
identity. Cursor does likewise later. A retained existing Claude session may
only receive a same-task follow-up when PtcManager has its exact session,
worktree, and credential provenance.

Slice 4 is not considered operationally model-neutral until the same safe
read-only generic action has completed through Codex and at least one second
real Herdr kind (prefer Claude on the current host), in addition to the invented
kind contract test. Lack of a second healthy installation may delay that pilot,
but must never be “solved” with a Codex-specific application branch.

The existing direct Codex paths are temporary compatibility implementations for
current manager analysis and daily updates. Migrating those actions means
expressing their isolation as execution-profile requirements (for example,
`workspace:read-snapshot`, `network:none`, and `github:none`) and then removing
the direct process adapter after parity tests.

### Triggers

Add `automation_triggers`:

| Field | Purpose |
| --- | --- |
| `automation_definition_id` | Action to launch |
| `kind` | `manual` or `schedule`; GitHub event later |
| `enabled` | Per-trigger pause |
| `surface` | Manual placement enum |
| `button_label` | Manual label |
| `target_states` | Valid finite target states |
| `cron_expression` | Persisted canonical schedule |
| `time_zone` | IANA timezone |
| `schedule_version` | Incremented on trigger/parent lifecycle or definition-version activation |
| `next_run_at` | Human-visible next occurrence |
| `scheduler_job_id` | Linked Oban job |
| `last_triggered_at` | Operational status |

Manual and schedule-specific validation prevents invalid combinations.
Schedule triggers initially require a repository-target definition. A direct
`Run now` is recorded as an invocation with `trigger_kind: run_now` and no
trigger ID; contextual board actions use their manual trigger ID and exact card
target.

### Trigger occurrences and invocation lineage

Add `automation_trigger_occurrences` with an immutable identity:

- `trigger_id`, `schedule_version`, and `due_at`;
- an unconditional unique index on that triple;
- the exact `automation_definition_version_id` selected when reserved;
- `oban_job_id` and materialization timestamps;
- disabled, stale-version, materialized, or failed status;
- the created invocation ID when materialized.

An Oban retry uses insert-or-get on the same occurrence. After validating the
parent, trigger, and schedule version, the due worker first transactionally:

1. creates or resumes the invocation;
2. reserves the next unique future occurrence and its Oban job; and
3. marks the current occurrence claimed.

It then opens a second transaction that rechecks the parent, trigger, and
schedule version and conditionally creates and links the execution profile's
domain record while changing the invocation from `claimed` to `materialized`.
Pause, archive, or version-change transactions atomically mark any matching
claimed-but-unmaterialized invocation `stale` while they invalidate the future
occurrence. SQLite write serialization makes the outcome unambiguous:

- if materialization commits first, the already queued domain job continues;
- if pause or invalidation commits first, no domain job is created.

A crash between phases resumes the same invocation. Exhausted domain
materialization retries leave a visible failed invocation but do not stop the
already reserved future schedule. Failed or cancelled agent work never makes
the occurrence reusable. A schedule edit increments the version; stale jobs
see the mismatch and stop without launching work.

Add lightweight `automation_invocations` as immutable provenance, not as a new
execution queue or a competing source of runtime truth. It links exactly one
trigger event to the domain record that performs the work:

- definition and immutable version;
- optional trigger and occurrence;
- `trigger_kind` and snapshotted trigger context;
- exact repository, target, source SHA, and resolved prompt;
- stable invocation/side-effect marker;
- one of `agent_action_id` or implementation `job_id` initially;
- materialization failure, if dispatch fails before a domain record exists.

Operations derives live state from the linked `agent_action`, `job`, Herdr run,
and GitHub reconciliation. The invocation exists so all configured buttons and
schedules share prompt/version/trigger provenance even though current execution
paths are different.

### Existing runs

Extend existing `agent_actions` where applicable:

- `automation_invocation_id`;
- `resolved_prompt` remains immutable;
- exact repository, target, and source SHA;
- existing state, run, output, audit, and result relationships.

Implementation jobs link to the same invocation without being converted into
`agent_actions`. Legacy `action_key` remains during migration and can later
mirror the definition key for readable queries.

### Generic result protocol

Herdr supplies lifecycle, terminal output, and retained-session identity. Its
short pane metadata is useful for display but is not a durable, typed business
result channel. PtcManager therefore gives every generic agent the same small
brokered result protocol, independent of whether the Herdr kind is Codex,
Claude, Cursor, or something added later.

After bootstrap and final preflight, immediately before agent launch, PtcManager
creates coordinator-owned immutable `request.json` and `prompt.md`, plus a
separate agent-writable staging directory if the action may produce a long
report. Final result artifacts are never writable by the agent identity.
PtcManager injects only into the launched agent process:

- `PTC_RUN_ID`;
- `PTC_RESULT_STAGING_DIR`;
- `PTC_RESULT_COMMAND`, pointing to a small `ptc-result` broker client;
- a short-lived, single-run submission token that cannot name another run.

The broker accepts a submission only while that invocation is in its explicit
`accepting_result` state. Bootstrap never receives the token or helper
environment. A launch failure, cancellation, terminal result, or timeout closes
the state and revokes the token; a retained correction attempt receives a newly
minted token after capacity and workspace revalidation.

The generated result instructions tell the agent to stage any long private
report as `report.md` and finish by invoking the helper with a result envelope.
The helper submits over a coordinator-owned Unix socket; it is not trusted merely
because the agent invoked it. The coordinator validates the token, schema, run
ID, field and total sizes, and link/path policy. For a staged report it opens the
file without following symlinks, reads bounded bytes, hashes and copies those
exact bytes into coordinator-owned immutable storage, and only then atomically
publishes `result.json` beside the copied report. Later edits to staging cannot
change the retained result. Clear broker errors remain visible in the terminal
so the still-running agent can correct and resubmit it.

The agent OS identity cannot write the coordinator's final result store. Where
an installation intentionally runs trusted-direct agents under the same OS
identity, the broker still provides schema, run scoping, immutable ingestion,
and auditability, but the UI must not describe filesystem permissions as a
security boundary. A hardened profile uses separate coordinator and agent OS
identities.

Version 1 of the envelope is deliberately small:

```json
{
  "version": 1,
  "run_id": "run_01...",
  "status": "succeeded",
  "summary": "The nightly failure was already covered by issue #1742.",
  "markdown_file": "report.md",
  "links": ["https://github.com/.../issues/1742"],
  "github_changes": ["Updated issue #1742"],
  "decision": null
}
```

Allowed statuses initially include `succeeded`, `no_changes`, `blocked`, and
`needs_decision`. A `needs_decision` result may include one plain-language
question and a bounded list of choices; free-form maintainer input remains
available in the UI. Existing issue-decision and daily-update payloads may keep
specialized validation while converging on the versioned envelope.

PtcManager consumes the result only after Herdr reports the run settled. A
missing or invalid result is not inferred from terminal prose: PtcManager
retains the terminal and session where possible, marks the action
`needs_attention`, and lets the maintainer ask the same agent to correct and
resubmit it. Agents never receive database credentials or write PtcManager
tables directly. The result records reported side effects; reconciliation still
reads GitHub for authoritative issue, PR, check, label, and merge state.

The transport is abstracted from the envelope. The first implementation is a
local broker reached through a Unix socket; a later remote Herdr worker may
submit the identical envelope to an authenticated HTTP endpoint using the same
short-lived run-scoped semantics. A skill may teach an agent how to call
`ptc-result`, but it is convenience instruction, not a required parser, model
dependency, or source of truth.

## Prompt assembly

There is no repository-wide prompt. The resolved prompt is assembled from:

1. generated coordinator context;
2. the selected definition version's editable operational policy;
3. the selected definition version's editable action prompt;
4. generated result instructions.

The resolved prompt and its digest are stored on the run before it can be
claimed. Editing a definition creates a new version; it never mutates queued or
running prompts.

The complete default and resolved prompt are visible in Configuration. The UI
may allow editing operational policy text, but it cannot disable enforcement
implemented outside the prompt.

## GitHub access

For the current personal repositories, trusted-direct mode uses the existing
authenticated `gh` identity of the worker account. Onboarding checks:

- `gh auth status` succeeds for that execution identity;
- the private repository is readable;
- a non-mutating API probe confirms required issue, PR, Actions, and repository
  access;
- the checkout remote identifies the configured repository.

The GitHub App or an equivalent narrow command broker remains the enforcement
boundary for isolated exact-commit publication. It receives an exact repository,
target, SHA, current lock fencing token, and gate evidence, and refuses a stale
or broader mutation. The credential-free agent cannot call unrestricted `gh`.

`github_access: trusted_direct` is intentionally broad within the authenticated
account. It is the practical default for the maintainer's current personal
agent workflows, including issue maintenance and agents that push or merge
their own PRs. The UI presents a clear warning and the full prompt before it is
enabled, especially on a schedule. PtcManager records intended targets and
reconciles what happened, but does not claim it can prevent an authenticated
agent from making another GitHub change.

`github_access: brokered_publish` is required anywhere the product promises
that no publication can occur without an exact-target or exact-SHA gate. Future
fine-grained per-repository credentials may provide a middle ground without
changing the action model.

Private repositories remain private; public visibility is not required.

## Repository-owned gates

Write-capable implementation and publication require the design in
`ptc_manager` issue #1 before `ptc_manager` itself is enabled for implementation.

Each repository should check in a small PtcManager contract, initially
`.ptc-manager.yml`:

```yaml
version: 1
bootstrap:
  command: ./scripts/ptc/bootstrap
  timeout_minutes: 10
verification:
  before_publish: ./scripts/ci/pre-publication
  timeout_minutes: 45
```

The repository owns the executable gate. A developer pre-push hook, PtcManager,
and GitHub CI should delegate to the same checked-in scripts. The
credential-bearing publisher continues to disable Git hooks.

The exact candidate commit also owns this contract and the scripts it invokes.
The broker evidence proves that the recorded candidate command ran against the
recorded SHA; it does not make a malicious candidate's self-weakened policy
trustworthy. Gate-policy changes therefore require explicit human review, and
protected-branch CI remains the final merge boundary.

### Reuse the `ptc_runner` duplication ratchet

For `ptc_manager`, `mix precommit` should include the same duplication policy
already proven in `ptc_runner`, not a newly designed detector. The reviewed
source is `ptc_runner` commit `1a21d3f7c9ed6b6d489b8173ba215ef120b9d2b0`;
adopt these assets and behavior from that commit:

- ExDNA `~> 1.5` as a development/test-only dependency;
- `.ex_dna.exs` with the same excluded boilerplate macros and minimum AST mass;
- `scripts/duplication_gate.sh check|bless`;
- the Python baseline ratchet and its fingerprint/remnant semantics;
- the existing line-movement, literal-change, growth, one-to-one remnant, and
  unrelated-clone regression tests;
- a repository-local `.duplication-baseline.json`, initially blessed from the
  current `ptc_manager` tree.

The initial adoption deliberately vendors the small gate implementation with a
source-commit provenance note so PtcManager can run locally and in CI without a
sibling `ptc_runner` checkout or network fetch. It is reuse by exact port plus
parity tests, not an independent rewrite. PtcManager owns only its baseline and
the list of scanned paths. If a third repository adopts the gate or either copy
needs a behavior change, extract the ratchet into a small standalone versioned
tool consumed by all repositories rather than allowing copies to drift.

The PtcManager gate scans its Elixir source and tests, runs from both
`mix precommit` and CI, fails only on new or grown clones, and retains the same
operator choices: extract shared logic, suppress an intentionally independent
copy with a reason, or explicitly bless accepted debt. The generic PtcManager
repository contract invokes `mix precommit`; it does not need to know that this
repository's gate happens to use ExDNA.

Before brokered publication, PtcManager runs the frozen command as a
credential-free worker against the exact candidate SHA, requires a clean
worktree afterward, and stores command, exit status, duration, bounded output,
and verified SHA. A head change makes the result stale and the broker blocks
publication until it passes again. Trusted-direct agents are instructed to run
the same repository gate, and PtcManager records the result, but their broad
credential means PtcManager cannot guarantee that they did not publish first.

## Durable scheduling

Use Oban OSS with `Oban.Engines.Lite` on the current SQLite database. Oban owns
delivery time, retry, persisted scheduler state, and scheduler history.
PtcManager queues and slot claims own agent capacity, planning versus writing
lanes, merge serialization, retained-session allocations, and worktree
lifecycle; Herdr reports and controls the selected agent session.

Each enabled schedule has exactly one persisted future occurrence and linked
Oban job. Configuration transactionally inserts the unique occurrence and Oban
job. When due, the worker insert-or-gets an invocation for
`(trigger_id, schedule_version, due_at)` and reserves the next future occurrence
before it attempts the profile's normal PtcManager domain work. A crash after
commit and before Oban acknowledges the job reuses the same occurrence and
invocation instead of creating another action. A terminal materialization
failure is visible in Operations but does not silently disable later runs.

A server outage leaves the due job in SQLite; it runs after restart. Because
only one future occurrence existed, the initial policy runs at most one overdue
occurrence and then computes the next future time rather than backfilling every
missed interval.

Schedule calculations use the trigger's IANA time zone, but occurrence identity
is always the resolved UTC `due_at`. For a nonexistent local time during the
spring DST gap, schedule the occurrence at the first valid instant after the
gap. For a repeated local time during the autumn DST fold, run once at the
earlier resolved instant. If a shifted gap occurrence collides with another
genuine cron match at that same UTC instant—for example `0 2,3 * * *`—the two
matches deliberately coalesce into one occurrence and its audit metadata lists
both nominal local matches. A time-zone or cron edit increments
`schedule_version` and recomputes the one future occurrence from the edit time;
it never reuses or backfills the invalidated local occurrence. Deterministic
tests cover both folds and gaps, wall-clock rollback, a time-zone edit across a
transition, an outage spanning a transition, and the shifted/genuine collision.

Changing, pausing, or resuming a schedule increments `schedule_version`,
cancels its known future Oban job, and records an audit event. Pausing,
archiving, or resuming the parent automation also version-invalidates all of
its scheduled triggers. A job always rechecks parent enabled state, trigger
enabled state, and version before claiming an occurrence. A small
reconciliation worker repairs a missing Oban job for the current unique future
occurrence after an interrupted configuration transaction.

Oban's static Cron configuration is not used as the user-editable schedule
source. Schedules are PtcManager records and use dynamic one-shot Oban jobs.

## Concurrency and idempotency

Initial lock policies are finite and named:

- `none` for credential-free, read-only ephemeral work only;
- `one_per_action_repository`;
- `one_per_target`;
- `repository_writer`;
- `repository_merge`.

Planning actions may run during a merge action when they use an immutable
source snapshot. Writing and merge actions retain existing repository-aware
serialization.

Replace the current unconditional active-action-per-target index with an
explicit lock claim keyed by the immutable invocation's calculated lock keys.
Claiming all required keys and changing the domain record to running occur in
one transaction. Claims include a fencing token; retained sessions and brokers
must present the current token before a protected mutation. The compatibility
matrix is code-owned and tested: `repository_merge` excludes other repository
writers and merges, but not immutable read-only planning; `repository_writer`
excludes merges and other writers; target locks serialize only the same target.
Dropping the old index is part of the same migration that enables these claims,
so `none` neither stays accidentally serialized nor creates an unguarded writer.

Scheduled occurrences use unconditional uniqueness, regardless of whether the
eventual agent succeeds, fails, or is cancelled. Future GitHub-event triggers
also use an immutable event-delivery key with insert-or-get semantics. Prompts
for trusted-direct actions that create GitHub records receive the stable
invocation marker and must search for it before creating a duplicate; this is a
best-effort side-effect safeguard, not a substitute for a broker.

## Multi-repository prerequisites

Before adding `ptc_manager`:

- remove the global `PTC_REPOSITORY_PATH` runtime override from all repository
  operations;
- use each repository row's absolute `local_path`;
- give `ptc_manager` a dedicated worker checkout such as
  `/srv/ptc_manager-src`, never the live release under `/opt/ptc_manager`;
- prove worktree roots and cleanup are repository-safe;
- scope action definitions, triggers, runs, prompts, gates, locks, and status
  updates by repository;
- add repository-scoped authentication and checkout health checks;
- keep the `ptc_manager` status-update action disabled initially;
- keep PtcManager self-deployment disabled initially.

## Implementation slices

Each slice should be independently reviewed, tested, committed, deployed when
safe, and browser-tested on desktop and mobile-sized layouts.

### Slice 0: plan and UX acceptance

- Review this document against current Planning, Delivery, Operations,
  Configuration, and Updates behavior.
- Produce low-fidelity desktop and mobile wireframes for Automations index,
  action editor, prompt preview, schedule editor, and run detail.
- Confirm terminology and default actions before schema migrations.

Acceptance:

- a maintainer can explain the difference between an action, trigger, and run;
- every proposed field is visible in or required by a user journey;
- advanced controls do not dominate the normal create/edit flow.

### Slice 0.5: deterministic integration test rig

- Add the shared `PtcManager.TestScenario` support described in the Test
  strategy, with stateful GitHub, Herdr, agent, clock, and fault controls.
- Put Herdr control behind one injectable command/gateway boundary rather than
  creating more fake shell scripts in individual test files.
- Put GitHub HTTP transport behind an injectable boundary while retaining the
  existing domain-level issue and PR behaviours.
- Put credential-free and credential-bearing Git/port execution behind an
  injectable runner so push-success/ack-loss and timeout windows can be tested.
- Use real temporary Git repositories and worktrees for workspace tests.
- Model stable worker identity, worker and Herdr incarnations, authoritative
  snapshot sequences, retained processes, and confirmed resource-exhaustion
  failures so recovery can be advanced without wall-clock sleeps.
- Add parity scenarios for current implementation dispatch, PR repair,
  publication, reconciliation, and cleanup. Add each new golden journey in the
  later slice that introduces its production path; this slice does not fake a
  future scheduler, generic result broker, or multi-repository coordinator.
- Migrate duplicated one-off fakes into the rig when their tests are touched;
  do not block this slice on rewriting the complete existing suite.

Acceptance:

- tests advance work explicitly without `Process.sleep/1` or live poller timing;
- every external operation exercised by the current parity scenarios can fail
  before its side effect or after its side effect but before acknowledgement;
- a scenario exposes a readable ordered trace of database, GitHub, Herdr, agent,
  result, and UI events when it fails;
- no required CI test launches a real LLM or mutates a maintainer repository;
- the initial parity scenarios run repeatedly with the same result.

### Slice 0.75: deployment maintenance and canary admission

- Add a deployment maintenance mode that starts the release with all pollers,
  Oban queues when present, result ingestion, mutations, and dispatch paused.
- Add a canary-only admission mode that permits one explicitly identified
  read-only invocation while preserved and newly queued ordinary work remains
  paused.
- Teach the checked-in deployment task to restore a SQLite snapshot only before
  maintenance mode is lifted; after any new effect it may pause and perform only
  a schema-compatible code rollback or forward repair.
- Add a disposable-target deployment harness that exercises maintenance entry,
  pre-effect failure and restore, canary-only admission, post-effect failure,
  and ordinary-work resume. The harness activates only capabilities present in
  that slice; it does not require generic dispatch or Oban before they exist.

Acceptance:

- the web/read-only health surface can be checked while every ordinary worker
  and write path is paused;
- exactly one allowlisted canary can traverse an available action path without
  releasing preserved work;
- ordinary work resumes only after the canary succeeds;
- no automated rollback restores an older database after a durable or external
  effect may have occurred.

### Slice 1: exact-SHA pre-publication gate

- Implement `ptc_manager` issue #1.
- Port the reviewed `ptc_runner` duplication gate assets and regression tests,
  add the ExDNA dependency, bless only PtcManager's initial local baseline, and
  run the check from both `mix precommit` and CI.
- Add the repository contract parser and frozen per-job gate configuration.
- Run the gate credential-free and persist exact-SHA evidence.
- Keep publisher hooks disabled.
- Add pass, failure, changed-head, timeout, bounded-output, and dirty-worktree
  tests, including replacement-ref, assume-unchanged, clean-filter, transformed
  checkout, and rejected-submodule regressions.
- Provision a root-owned, credential-free gate toolchain and run the real
  checked-in bootstrap and pre-publication scripts as a pre-stop deployment
  canary.

Acceptance:

- the unchanged PtcManager tree passes its initial baseline, an injected new or
  grown clone fails, resolved debt passes with the same update message, and the
  ported `ptc_runner` fixtures produce byte-equivalent classifications;
- the broker refuses branch push or PR creation without a passing, current
  gate, exact target, and fencing token;
- push-success/ack-loss, gate partial failure, and changed-head scenarios leave
  one externally verifiable outcome and never blindly repeat a publication;
- the first strictly gated `ptc_manager` implementation pilot uses brokered
  publication rather than trusted-direct credentials.

### Slice 2: multi-repository correctness

- Remove the global checkout override.
- Add repository-safe checkout, worktree, sync, publication, and cleanup tests.
- Synchronize native GitHub `blockedBy`/`blocking` relationships as a read-only
  repository-scoped projection, including accessible cross-repository links,
  blocker state reasons, unknown blockers, and cycle detection.
- Add repository authentication and gate health to configuration.
- Add URL plus localStorage repository selection.

Checkpoint A establishes the safe foundation before enabling a second
repository: persisted checkout ownership, canonical Git root/common-directory
and GitHub-origin validation, explicit worktree roots, legacy single-repository
upgrade reconciliation, repository-safe external worktree names, and a stable
repository selector on the existing Planning, Delivery, and Updates pages. It
is browser-testable with two mocked repositories.

Checkpoint B adds repository configuration health without running uncommitted
policy: checkout ownership, GitHub sync health, and the committed default-branch
publication gate are visible together and update while synchronization runs.

Checkpoint C replaces issue-body dependency inference with GitHub's native
`blockedBy` projection. Each local edge retains the exact repository and issue
identity plus the blocker title, URL, state, and close reason; configured
repositories may additionally link to their local issue row. Unknown blockers,
dependency overflow, close-without-completion, and shortest observable cycles
fail closed and are explained on the Planning card. A single GraphQL page reads
issue details and up to 100 native blockers per issue, avoiding one REST call
per open issue. The checkpoint is browser-testable with mocked same-repository,
cross-repository, completed, inaccessible, not-planned, and cyclic blockers.

The complete two-repository dispatch/publication journey remains the final
Slice 2 checkpoint.

Acceptance:

- two repositories cannot silently share checkout or worktree paths;
- the two-repository golden journey proves similar issue, branch, and PR
  numbers remain isolated through dispatch, result, publication, and cleanup;
- native dependencies are linked to exact repository/issue identities, and an
  inaccessible cross-repository blocker fails closed rather than being confused
  with an issue of the same number;
- changing the repository filter is stable across refresh and link navigation.

### Slice 3: persisted action definitions

- Add automation definitions and immutable versions containing every execution
  and enforcement field.
- Seed current actions without changing behavior.
- Resolve and snapshot prompts from definition versions.
- Show complete default and resolved prompts.
- Add the Agent profiles health panel and seed the currently verified Codex
  worker profile; show Claude and Cursor as unavailable until separately
  installed and validated for the worker identity.

Acceptance:

- existing buttons still enqueue byte-equivalent prompts and behavior;
- editing agent, access, lane, locks, timeout, profile, result type, or prompt
  cannot mutate an existing invocation;
- the UI distinguishes Herdr-supported kinds from profiles actually ready for
  unattended worker dispatch;
- no repository-wide prompt exists.

### Slice 4: execution profiles, invocation lineage, and locks

- Add the code-owned execution-profile registry and capability validation.
- Add configured agent profiles, worker-identity health checks, deterministic
  routing, durable slot claims, crash reconciliation, and selection provenance.
- Add separate light and heavy worker pools, profile ceilings, resource-pressure
  admission, throughput priority, and visible queue reasons.
- Add the prepared-workspace state machine: source synchronization, Herdr
  worktree creation, persisted native identity, repository bootstrap, preflight,
  agent start, retained-worktree validation, and durable cleanup.
- Add the versioned `ptc-result` broker client and local Unix-socket transport
  with coordinator-owned immutable ingestion and run-scoped validation.
- Add one generic Herdr dispatch adapter that passes the selected explicit kind,
  plus common result validation and synchronization. Do not add direct
  model-specific process adapters for new automations.
- Add a contract scenario registering an invented Herdr kind such as
  `test-maintainer`, with no Codex/Claude/Cursor code or executable present, and
  complete dispatch, prompt, result, reconciliation, retention, and cleanup.
- Add automation invocations linking existing `agent_actions` or implementation
  `jobs` without replacing either queue.
- Add `waiting_on_dependencies` eligibility and reconciliation so a previously
  approved issue consumes no agent, profile slot, lock, or worktree until every
  authoritative blocker is satisfied.
- Introduce durable lock claims and fencing tokens, migrate current merge and
  writer serialization, then remove the old unconditional target index.
- Migrate current prompt customizations into immutable definition versions.

Acceptance:

- a new `generic_ephemeral` repository action executes without an action-key
  code branch;
- a writer agent cannot start until its Herdr worktree, result directory,
  repository bootstrap, expected SHA/branch, toolchains, credentials, and gates
  have all passed preflight;
- a failed preflight starts no agent, and crash recovery adopts the persisted
  worktree identity rather than creating a duplicate;
- generic Codex, Claude, Cursor, and an unknown test kind use the same validated
  result envelope without parsing terminal prose or receiving database
  credentials;
- no non-compatibility production module branches on a known Herdr kind name;
  adding a ready profile for a new kind requires no application-code change;
- the default selector uses any capable Herdr agent, a preference may fall back,
  and a requirement stays queued when no matching agent exists;
- a Herdr-supported but uninstalled or unauthenticated kind is ineligible;
- the initial Hetzner worker selects Codex because it is the only healthy
  automated profile, not because the action implementation names Codex;
- concurrent dispatchers cannot claim the same final profile slot, and an
  expired coordinator lease cannot release a still-active Herdr session;
- a crash after Herdr accepts `agent start` but before its response is persisted
  adopts the preallocated named agent and does not launch a duplicate;
- a crash before prompt delivery safely sends the persisted attempt once, while
  a crash in the prompt-acceptance window becomes `prompt_delivery_unknown` and
  never resends automatically;
- prompting a retained passive session reacquires capacity before work resumes;
- the assigned Herdr agent kind, name, and session are visible after dispatch;
- every non-generic current action dispatches through an explicit typed profile;
- invalid profile, target, agent, credential, result, and lock combinations are
  rejected;
- dependency addition, removal, completion, not-planned closure, reopening,
  unknown state, and cycles atomically gate dispatch and publication;
- Operations still shows implementation jobs and maintainer actions correctly;
- lock compatibility is atomic and matches the planning/writer/merge policy.
- this slice adds the golden journeys for worktree-create acknowledgement loss,
  prompt uncertainty, stale eligibility during bootstrap, cleanup/resume races,
  light-versus-heavy capacity, generic result resubmission, and externally
  merged PR reconciliation.

### Slice 5: manual triggers and generated buttons

- Add manual triggers and supported surfaces.
- Render Planning and Delivery buttons from applicable triggers.
- Seed editable generic `Triage issue` and `Make implementation-ready` actions,
  including the minimal repository label mapping and claim convention.
- Add linked blocker summaries, `Approve when unblocked`, dependency-cycle and
  unknown-blocker warnings, and `Recently changed externally` history to the
  Planning/Delivery surfaces and run detail.
- Replace the two default repair buttons with one configured `Fix and merge`
  action.
- Add immediate queue feedback and links to run detail.

Acceptance:

- creating, moving, renaming, pausing, or deleting a manual trigger changes the
  relevant button without an Elixir catalog edit;
- issue readiness is derived from GitHub labels, open/closed state, native
  dependencies, and blocker state reasons while PtcManager owns only its
  run/claim state; an external assignee or claim comment is shown without
  becoming a second PtcManager issue state machine;
- cards never silently disappear after an external close or merge; active work
  shows an immediate warning and durable Operations link;
- invalid surface and target combinations cannot be saved.

### Slice 6: Automations UX and common results

- Add Automations index and action editor.
- Add prompt preview/version history.
- Add basic duplicate-to-repository, followed by an edit screen; never copy an
  authenticated repository identity or enable schedules automatically.
- Add common result validation and presentation, including private Markdown,
  plain-language decisions, invalid-result recovery, and reported GitHub links.
- Add complete run history and read-only output links.

Acceptance:

- a new repository-level manual automation can be configured and run without
  code changes;
- an action can be duplicated to another configured repository, is disabled by
  default there, and must pass that repository's profile/authentication checks;
- issue and PR actions cannot use index-level Run now without an exact target;
- mobile layouts keep the primary action, state, next run, and last result
  readable.

### Slice 7: Oban and scheduled triggers

- Add Oban Lite migrations and supervision.
- Add schedule editing, immutable occurrences, one-shot job materialization,
  pause/resume, repository-action Run now, retries, and reconciliation.
- Display next run and linked runs in Automations and Operations.

Acceptance:

- a scheduled run survives an application restart;
- the real-Oban/on-disk-SQLite black-box suite proves restart recovery,
  `SQLITE_BUSY` handling, and single materialization outside SQL Sandbox;
- unconditional occurrence uniqueness and insert-or-get materialize only one
  invocation even after a post-commit worker crash;
- pausing either the trigger or parent automation prevents future
  materialization, including across pause/resume races: either the domain job
  was atomically materialized before pause, or the invocation becomes stale and
  no domain job is created;
- stale jobs after pause or reschedule launch nothing;
- an exhausted materialization failure is visible and the following scheduled
  occurrence still runs;
- schedules cannot be attached to issue or PR actions in the first release;
- DST spring gaps run at the first valid instant, autumn folds run once at the
  earlier instant, and time-zone edits, wall-clock rollback, and outages across
  both transitions preserve one future occurrence; a shifted gap match and a
  genuine match at the same UTC instant coalesce once with both nominal matches
  retained in audit metadata;
- configured profile capacity and PtcManager queue rules still decide when
  Herdr starts the selected agent.

### Slice 8: migrate repository status updates

- Create status-update action definitions per repository.
- Move execution through a credential-free, read-only Herdr capability profile
  before removing the direct Codex compatibility path.
- Migrate the existing `ptc_runner` schedule.
- Leave the `ptc_manager` schedule disabled.
- Remove the special-purpose scheduler after parity tests.

Acceptance:

- existing private updates remain readable;
- `ptc_runner` produces the next expected update;
- `ptc_manager` produces none until explicitly enabled.

### Slice 9: failed nightly CI automation

- Configure the example generic definition and manual plus scheduled triggers
  for `ptc_runner`; do not add a nightly-CI-specific executor.
- Supply bounded GitHub workflow metadata plus stable occurrence, invocation,
  and discovered workflow-run markers.
- Test no failure, new failure, existing issue, duplicate retry, inaccessible
  logs, and agent failure.
- Browser-test queue feedback, run output, and created/updated issue links.

Acceptance:

- the scheduler launches one agent invocation per occurrence, and trusted-direct
  retry instructions search the stable marker before creating another issue;
- a successful or already handled run creates no issue;
- the action is visible in Operations and automation history.

### Slice 10: onboard `ptc_manager` and prove repeatable onboarding

- Add the private repository and dedicated checkout.
- Validate authenticated `gh` access.
- Create repository-specific action definitions by duplicating and editing the
  desired defaults.
- Keep status updates and deployment disabled.
- Test one read-only issue action, then one small gated implementation PR.
- Document and test the same repository-registration, health, contract, action
  duplication, and enablement flow for any later private repository.

Acceptance:

- all links, actions, prompts, gates, worktrees, PRs, and cleanup refer to
  `andreasronge/ptc_manager` rather than `ptc_runner`;
- no job reads or deploys the live release directory.
- adding the next repository requires configuration and a checked-in repository
  contract, not a new action executor or hard-coded repository branch.

### Later slices

- GitHub workflow-completed event triggers using polling or webhooks.
- A typed deployment action and deployment lane.
- Optional per-run Herdr selector override rather than only a definition-level
  selector.
- Action import/export and bulk duplication between repositories.
- Fine-grained repository credentials.
- PostgreSQL and distributed Oban only if multiple PtcManager application nodes
  become necessary; multiple remote Herdr workers alone do not require it.

## Test strategy

### Confidence model

No single full-system test can prove an asynchronous agent system correct. The
release gate therefore combines four deliberately small layers:

1. domain tests for state machines, validation, locks, fencing, and invariants;
2. deterministic integration scenarios using real SQLite and Git with stateful
   fake GitHub, Herdr, and agents;
3. LiveView journeys over the same scenario rig for user-visible asynchronous
   states;
4. opt-in contract and deployment canaries against the actual Hetzner worker
   and a dedicated GitHub test repository.

Required CI never depends on model quality, external network availability, or
real Codex/Claude usage. Real-service tests prove adapter compatibility and
deployment wiring, not reasoning quality.

### Deterministic scenario rig

Add shared test support rather than another collection of file-local fakes:

- `PtcManager.TestScenario` owns the scenario, fixtures, virtual time, ordered
  event trace, and `drain/1` or `advance/2` operations;
- a stateful `TestGitHub` holds issues, labels, assignees, PRs, heads, checks,
  merges, workflow runs, and an audit of reads and mutations;
- a stateful `TestHerdr` holds worktrees, workspaces, panes, agents, prompt
  attempts, terminal output, and removals;
- a deterministic `TestAgent` reacts to a prompt with a configured sequence:
  remain working, stop, submit a valid/invalid result, or make declared GitHub
  changes before settling;
- real temporary Git repositories and worktrees exercise revision, branch,
  cleanliness, symlink, ownership, gate, and cleanup logic;
- a virtual clock controls leases, retries, schedule occurrences, timeouts, and
  backoff without wall-clock sleeps;
- Oban uses manual testing mode so scenarios inspect and execute due jobs
  explicitly rather than running background queues.

Manual Oban mode is for fast deterministic orchestration tests, not evidence of
process-restart or SQLite-engine behavior. A separate, small black-box suite
uses a dedicated on-disk SQLite file and the real Oban Lite supervision tree.
It commits at a named fault boundary, terminates the application and Repo,
reopens the same file in a fresh application instance, and verifies that the
single durable action resumes. That suite also uses two independent database
connections to cover `SQLITE_BUSY`, lock retry, interrupted shutdown, and
poller/engine recovery. It does not run inside the normal SQL sandbox.

The scenario runner calls the same public `run_once`, worker, synchronization,
and LiveView entry points used by production. It does not reach into schemas to
force the expected final state after the initial fixture is built.

Every fake external command supports at least these outcomes:

- `ok`: apply the side effect and acknowledge it;
- `fail_before`: return an error without applying the side effect;
- `effect_then_error`: apply the side effect but lose or replace the
  acknowledgement;
- `pause_after_effect`: apply the side effect and block on a test barrier so a
  competing worker, state change, or simulated coordinator restart can run.

`effect_then_error` is the most important mode: it reproduces the uncertainty
windows that otherwise create duplicate worktrees, agents, prompts, PRs,
issues, results, or merges. Scenario assertions check both durable state and
the external event trace—for example, not merely that a job finished, but that
only one prompt and one GitHub mutation occurred.

The faultable boundary covers more than HTTP and Herdr. It includes the Git
port runner used for exact-SHA fetch/push, the result broker's durable accept
and acknowledgement, and repository bootstrap/gate execution. Required
scenarios include push-success/ack-loss, PR-create/merge-success/ack-loss,
result-persist/ack-loss, and bootstrap/gate partial failure. The fake models
only observable protocols; it does not reimplement GitHub or Herdr internals.

The initial rig may run `async: false` while SQLite and remaining application
configuration are process-global. New orchestration code should accept explicit
gateway, clock, and runtime dependencies so the rig does not add more
`Application.put_env/3` coordination. Parallelization is a later optimization,
not a prerequisite for deterministic coverage.

### High-risk scenario matrix

| Risk | Injected event | Required assertion |
| --- | --- | --- |
| Duplicate workspace or agent | Herdr applies create/start, then loses the reply | Recovery adopts the deterministic identity; one workspace and agent exist |
| Duplicate prompt or GitHub side effect | Herdr accepts prompt, then times out | State is `prompt_delivery_unknown`; no automatic resend or second PR/issue |
| Stale approved work | Issue closes, becomes blocked, or is claimed during bootstrap | Agent never starts; refreshed GitHub reason is visible |
| Dependency eligibility drift | Blocker completes, is reopened, closes not planned, becomes inaccessible, or forms a cycle | Waiting work starts once only after explicit satisfaction; unknown/cyclic work remains visibly blocked |
| Queue/capacity race | Concurrent dispatchers compete for the final light/heavy/profile slot | One durable winner; every loser remains visibly queued with a reason |
| Unsafe worktree cleanup | Cleanup races a retained-session resume or crashes mid-removal | One fenced winner; active/wrong-path worktree is never deleted; retry is safe |
| Untrusted or ambiguous result | Wrong token/run, invalid schema, symlink, oversized or changed staging file | Broker rejects it, final store is unchanged, and retained correction is possible |
| Duplicate scheduled work | Coordinator stops after occurrence/job materialization | Restart produces one occurrence, invocation, and domain record, then schedules the next future run |
| GitHub changed outside PtcManager | PR merges, head advances, CI changes, or issue assignment changes mid-run | Reconciliation follows GitHub truth without publishing, repairing, or blocking twice |
| Target closes during active work | Issue closes or PR merges/closes while a Herdr turn is working | Warning appears immediately; new brokered effects stop; session/output remain until safe settle and fenced cleanup |
| Cross-repository leakage | Two repositories use similar issue/branch numbers concurrently | Paths, locks, prompts, credentials, results, links, and cleanup remain repository-scoped |
| Deployment/migration regression | Release restarts with queued, retained, and scheduled work | Migration preserves identities and queue state; pollers resume without duplicate execution |
| Worker or agent crash recovery | Coordinator, Herdr, host, transport, individual agent, or OOM fails at a named boundary | Claims remain fenced; work is adopted, reconciled, resumed once, replaced safely, or quarantined without duplicate prompt/publication |

Maintain a small set of named golden journeys rather than a combinatorial suite:

1. approve one ready issue through prepared worktree, agent result, and linked PR;
2. lose the worktree-create acknowledgement and adopt the single worktree;
3. lose prompt acknowledgement and retain one unknown session without resend;
4. change GitHub eligibility during bootstrap and prove no agent starts;
5. preapprove blocked issue B, complete blocker A, and start B exactly once
   without prior resource allocation; then cover not-planned and cycle variants;
6. close an issue and merge/close a PR during an active turn, preserving warning,
   output, terminal classification, and safe cleanup;
7. race cleanup against retained-session resume;
8. fill a heavy pool while a light planning action still completes;
9. after Slice 7, restart after scheduled materialization and prove one
   invocation, including the real-engine SQLite restart case;
10. reject a cross-run result and successfully resubmit through the same retained
   agent;
11. reconcile a PR merged outside PtcManager while repair is pending;
12. run similar targets in two repositories without cross-contamination.
13. terminate the coordinator, Herdr server, host incarnation, transport, and
    individual agent at named boundaries before prompt, after commit, after
    result, and after PR publication; prove adoption or fail-closed recovery;
14. simulate confirmed OOM recovery with bounded backoff and serialized worker
    admission, then prove capacity is eventually restored without duplicate
    publication.

### Adapter contract tests

The deterministic rig tests PtcManager behavior; thin contract tests protect the
real adapters:

- recorded Herdr JSON fixtures cover every supported response envelope and
  error classification;
- a temporary executable verifies exact Herdr CLI arguments, environment
  scrubbing, timeouts, and bounded output;
- an injectable GitHub transport or local HTTP stub verifies method, URL,
  pagination, headers, rate limits, decoding, and error classification without
  public network access;
- a temporary Git/port runner verifies exact arguments, environment isolation,
  output bounds, timeouts, and success-with-lost-acknowledgement handling;
- a tagged `:external` Hetzner test verifies real Herdr health plus
  worktree-create/list/remove against a disposable repository, without starting
  a paid LLM;
- a tagged `:external` GitHub test uses a dedicated private sandbox repository,
  never `ptc_runner` or `ptc_manager`; read-only probes run before ordinary
  deployments, while mutation/merge canaries require explicit enablement.

Fixture tests do not replace the external canary because Herdr and GitHub may
change independently. External tests do not replace deterministic scenarios
because network tests cannot reproduce crash windows reliably.

### LiveView journeys

Use existing Phoenix LiveView test helpers with `TestScenario`; a full browser
is not required for most asynchronous UI behavior. A journey clicks the real
button, drains one controlled stage at a time, and asserts the same target shows
consistent `queued`, `preparing`, `working`, `reconciling`, `needs attention`,
and completed states across the originating card, Operations, and run detail.

Keep a very small real-browser suite for behavior implemented in JavaScript:
repository selection in localStorage, drawers that remain open across LiveView
updates, mobile navigation, and read-only terminal/result panels. Do not put
the full orchestration matrix in browser automation.

### Deployment confidence gate

Every deploy records the exact commit and evidence for these stages. Each stage
requires only capabilities already introduced and enabled by the slice being
deployed: the real-Oban restart suite becomes required with Slice 7, and the
generic-action canary becomes required with Slice 4. Earlier slices use the
existing credential-free direct-adapter parity canary supplied by Slice 0.75;
that canary proves its actual queue → compatibility adapter → persisted result
→ UI path and does not pretend Herdr or the generic result broker exists yet.

1. **Required CI:** warning-free compile, formatting check, domain tests,
   deterministic integration scenarios, local adapter contract tests, LiveView
   journeys, applicable migration tests, and—once Oban exists—the on-disk
   SQLite/real-Oban restart suite.
2. **Pre-deploy target check:** no managed run is in an unsafe interruption
   window; database backup succeeds; pending migration and rollback compatibility
   are reported; Herdr, GitHub read access, disk, permissions, toolchains, and
   repository contracts are healthy.
3. **Maintenance start:** use the checked-in deployment task and start the new
   release in maintenance mode. Web health and read-only inspection are
   available, but pollers, Oban queues, result ingestion, ordinary mutations,
   and agent dispatch remain paused. Run migrations once and retain the previous
   release plus database backup.
4. **Pre-effect verification:** confirm the expected release SHA and migrations,
   component supervision/configuration, repository health, and preservation of
   pre-deploy queued, retained, and scheduled identities without executing them.
   Only after these checks pass may the deployment leave maintenance mode.
5. **Canary-only admission:** keep ordinary and preserved work paused, enable
   only the infrastructure needed by one allowlisted, credential-free read-only
   canary, and verify the newest available path. Before Slice 4 this is queue →
   direct compatibility adapter → persisted result → UI. From Slice 4 onward it
   is the full queue → Herdr → brokered result → UI journey. Before enabling a
   new write/publish path, separately run one explicit sandbox-repository write
   canary under the same allowlist rule.
6. **Active verification:** only after the canary passes, enable the available
   planning/writer pollers, result broker, Oban scheduler, configured agent
   profiles, and ordinary traffic. Verify the preserved identities remain
   singular and eligible work resumes once.

Rollback follows an explicit effect boundary:

- before maintenance mode is lifted, no new PtcManager external or durable
  business effect is allowed; a failed migration or pre-effect check may stop
  the service and restore both the previous release and its SQLite snapshot;
- after maintenance mode is lifted, the database snapshot is never restored
  automatically. A failure pauses dispatch and writes, preserves evidence, and
  uses a schema-compatible application rollback or forward repair. An operator
  may restore a database only after proving there are no newer local or external
  effects to orphan.

Exercise maintenance entry, pre-effect snapshot restore, post-effect pause, and
schema-compatible code rollback on a disposable deployment target; shell syntax
or script-text assertions alone are insufficient. A write canary whose GitHub
outcome is unknown is never retried automatically. Production actions remain
disabled behind their feature flag until the corresponding golden scenario,
adapter contract, and sandbox canary have passed.

### Definition of deployable

A slice is deployable only when:

- every new external side effect has `ok`, `fail_before`, and
  `effect_then_error` coverage;
- every new durable state has restart/reconciliation coverage, and states
  driven by Oban or SQLite concurrency have the real-engine on-disk restart case;
- every destructive operation has containment, ownership, fence, competing
  owner, and partial-failure coverage;
- every new queue or lock rule has a concurrent-claim test;
- every user-triggered action has one LiveView journey with immediate feedback;
- when a slice adds or changes migrations, they are tested from the previously
  deployed schema with representative records applicable to that slice;
- required CI is green and the target pre-deploy check passes;
- when a slice adds or changes an executable action path, the post-deploy
  read-only canary completes and its run is visible in Operations.

### Domain tests

- definition and version immutability, including editing every credential,
  profile, agent, lane, lock, timeout, result, and prompt field after enqueue;
- execution-profile capability validation and typed dispatch;
- agent-profile health checks, any/preferred/required selection, deterministic
  load routing, atomic final-slot claims, lease/fence reconciliation,
  preallocated launch identity, no-capacity queueing, retained-session
  reacquisition, and actual-agent provenance;
- stable worker identity plus worker/Herdr incarnation changes, consecutive
  healthy snapshot admission, recovery state transitions, retained claims,
  adopt/reconcile/resume-once/replace/quarantine outcomes, recovery backoff, OOM
  serialization, and trusted-direct ambiguity warnings;
- independent light/heavy pool limits, profile ceilings, host-pressure pauses,
  rightmost-first priority, aging, and light planning during a heavy merge;
- issue readiness from repository-configured labels, internal target claims,
  externally assigned/comment-claimed issues, native same/cross-repository
  dependencies, multiple blockers, completed versus not-planned blockers,
  dependency removal/reopening, unknown blockers, cycle detection, and
  reconciliation after an agent changes GitHub state;
- preapproved `waiting_on_dependencies` work becoming eligible exactly once
  without consuming capacity beforehand, while unapproved work merely returns
  to Ready;
- prepared-workspace stage transitions, pre-bootstrap containment/ownership/SHA
  and credential checks, idempotent bounded bootstrap, post-bootstrap
  revalidation, failed preflight without agent start, deterministic worktree
  adoption, retained-worktree revalidation, and deferred safe cleanup;
- malicious bootstrap without a result token, token minting only at launch,
  broker state gating, token expiry/revocation, and a GitHub eligibility change
  during bootstrap;
- fenced cleanup transitions from `retained`, `preflight_failed`, and
  `abandoned`, cleanup-versus-resume races, partial-cleanup crash recovery, and
  quarantine of ambiguous paths/identities;
- result-helper envelope versions, coordinator-owned immutable ingestion, size
  and path limits, symlink rejection, direct final-store write denial, cross-run
  submission denial, post-submission staging replacement, run-ID mismatch,
  invalid/missing result recovery, and GitHub reconciliation overriding
  agent-reported state;
- trigger validation and applicability;
- prompt resolution and snapshots;
- schedule occurrence uniqueness, materialization, post-commit crash, retry,
  exhausted materialization, continued future delivery, restart, trigger and
  parent pause/resume/archive races, stale version, and reconciliation;
- conditional claimed-to-materialized transitions proving that pause/version
  invalidation and domain-job creation cannot both win;
- definition-version activation revalidates triggers and replaces pending
  occurrences with the exact new version;
- event-delivery uniqueness and retry idempotency;
- repository isolation, lock compatibility, atomic claims, and fencing;
- exact-SHA broker gate enforcement and trusted-direct warning semantics;
- direct Run now target requirements;
- migration of all current actions and status updates.

### Integration tests

- fake Oban execution creates exactly one invocation and the one linked domain
  record required by its execution profile;
- manual and scheduled triggers enter the same invocation/materialization path;
- implementation profiles still create approval/jobs while generic profiles
  create `agent_actions`;
- two concurrent dispatch transactions competing for one profile slot produce
  one assignment and one visibly queued invocation;
- a fault injected immediately after successful Herdr start is recovered by
  deterministic name without releasing the slot or starting another agent;
- faults immediately before prompt send, after Herdr prompt acceptance, and
  before acceptance persistence either resume a still-pending attempt or retain
  one visible `prompt_delivery_unknown` session without automatic resend;
- a fault after Herdr worktree creation but before agent start adopts the same
  worktree and resumes the first incomplete preflight stage;
- Herdr termination, individual-agent termination, host-incarnation change,
  transport loss, interruption after commit/result/publication, and simulated
  OOM preserve fencing and retained work; each either adopts, reconciles,
  resumes once, safely replaces, or visibly quarantines without a duplicate
  prompt, branch writer, PR, or merge;
- wrong-root, aliased, symlinked, wrong-owner, wrong-SHA, or credential-leaking
  workspaces are rejected before any repository bootstrap code executes;
- bootstrap failure records `failed before agent start`, retains bounded output,
  releases active capacity safely, enters `preflight_failed`, never receives a
  result token, and never invokes the agent CLI;
- a target that closes, loses readiness, becomes blocked, or is externally
  claimed while bootstrap runs prevents agent launch;
- a cleanup worker and retained-session resume racing for one worktree produce
  exactly one fenced winner, including after a partial Herdr/Git removal crash;
- a fake generic Herdr kind can submit the same `ptc-result` envelope as Codex,
  and completes the full lifecycle, proving dispatch, reconciliation, result
  ingestion, UI provenance, and cleanup are model-neutral;
- crafted configuration cannot route a writer/merge profile through the light
  pool, and stale GitHub open/label/assignee state prevents materialization;
- authenticated GitHub fixtures cover nightly workflow outcomes;
- generated buttons create the expected definition version and trigger context;
- GitHub reconciliation overrides incorrect agent-reported state.
- an issue or PR closed before claim, during bootstrap, during active Herdr
  work, and while retained produces the stage-appropriate durable outcome,
  warning, fencing, and cleanup behavior;
- a PR merged externally succeeds, a PR closed without merge is declined, an
  issue closed while its PR remains open requires a decision, and reopening any
  target creates no automatic resurrection of the old invocation;
- cleanup waits for Herdr idle/done after external closure and quarantines an
  unreachable or ambiguous live process.

### Browser tests

- repository selection and localStorage fallback;
- desktop and phone Automations layouts;
- create/edit/pause/run action;
- add and remove manual button;
- add, pause, and resume schedule;
- reject a schedule or targetless Run now for issue/PR definitions;
- show the trusted-direct credential warning and brokered-mode explanation;
- full resolved-prompt inspection;
- queued/running/completed/failing status feedback;
- linked `Blocked by` summaries, `Approve when unblocked`, dependency cycles,
  unknown blockers, and automatic movement after blocker completion;
- immediate `Changed on GitHub while agent was working` feedback plus a
  discoverable recently-changed card and permanent Operations history;
- worker restart reason, recovery state and attempt count, next retry, retained
  claims, replacement/adoption outcome, and prominent maintainer-attention state;
- navigation from board button to Operations and run output.

## Rollout and compatibility

Migrations seed current catalog actions and preserve existing `agent_actions`,
implementation jobs, daily digests, and prompt customizations. Initially, old
catalog builders may delegate to seeded definitions while UI queries move to
triggers. Existing prompt customizations become immutable definition versions,
not a second editable prompt source. Feature flags allow generated buttons,
profile dispatch, durable locks, and Oban schedules to be enabled separately.

The migration includes an explicit parity matrix:

| Existing behavior | New profile | Domain record retained |
| --- | --- | --- |
| Prepare/review/merge-decision actions | `generic_ephemeral` or a typed compatibility profile | `agent_actions` |
| PR repair and merge | `retained_pr_repair` | `agent_actions`, retained run/worktree |
| Approve and start implementation | `implementation_job` | approvals and `jobs` |
| Daily repository update | `private_daily_update` | `agent_actions` and `daily_digests` |

No compatibility profile is removed until its prompt, eligibility,
workspace, result, synchronization, and cleanup behavior has a parity test.

Do not remove the old daily scheduler until the migrated scheduled action has
run successfully. Do not enable `ptc_manager` write actions until the
pre-publication gate and repository-path isolation are deployed and verified.

## Decisions recorded

- UX design precedes final schema implementation.
- Actions are per repository; there is no repository-wide prompt.
- The complete prompt is visible.
- Human-readable policy may be configured, while non-prompt enforcement stays
  in code.
- Trusted-direct `gh` is the practical default for current personal private
  repository agents, with an explicit warning that target and gate policy is
  not technically enforceable in that mode.
- A GitHub App or equivalent narrow broker is optional for ordinary trusted
  actions and required for any exact-target/exact-SHA publication guarantee.
- Every execution-sensitive setting is immutable per invocation.
- Execution profiles, not action keys or prompt parsing, choose adapters,
  workspaces, credentials, validators, synchronizers, and publishers.
- Herdr is the only agent-launch boundary for new automations. PtcManager owns
  the capability/profile router, passes Herdr an explicit kind, and records the
  assignment; it does not directly launch or permanently hard-code Codex,
  Claude Code, or Cursor.
- Herdr kinds are opaque to generic production code. An invented kind must pass
  the complete lifecycle contract test, and the Hetzner pilot validates the
  same read-only action with at least two real kinds before claiming operational
  model neutrality.
- Any capable Herdr agent is the default. Specific kinds or skills are required
  only when the action genuinely depends on them.
- Triage and implementation-readiness review are ordinary configurable Herdr
  actions. Repeating a review up to N times is prompt behavior, not a Codex
  skill requirement or a separate executor.
- GitHub is authoritative for issue content, open/closed state, assignees, and
  the minimal repository-configured workflow labels, native issue dependencies,
  blocker state reasons, and PR terminal state. PtcManager is authoritative only
  for its queue, run, lock, capacity, and history records.
- Native GitHub dependencies represent issue-to-issue blocking; `ptc:blocked`
  is reserved for external conditions. Ready-but-blocked work may be preapproved
  but consumes no resources until every blocker is explicitly satisfied.
- An issue or PR closed or merged during work never silently disappears. New
  brokered effects stop, the active Herdr turn settles without destructive
  cleanup underneath it, and a warning plus permanent run history explains the
  terminal outcome.
- PtcManager takes a minimal atomic internal target claim; agents perform GitHub
  assignment, comments, rewrites, and label changes according to their prompts.
- Workers expose separate configurable light and heavy capacity pools. Immutable
  action configuration selects a pool; prompt prose does not.
- PtcManager decides the exact source, branch, and worktree policy; Herdr creates
  and identifies the workspace; a checked-in repository bootstrap prepares it;
  only then may PtcManager start the agent.
- Generic agents return a versioned run-scoped result through a brokered
  `ptc-result` submission. Final artifacts are coordinator-owned and immutable;
  agents do not write the database, and PtcManager does not parse terminal prose
  as structured output.
- Required CI uses deterministic stateful GitHub/Herdr/agent fakes, real
  temporary Git, virtual time, and explicit external-effect fault injection.
  Real-service canaries are small, tagged, and confined to dedicated sandbox
  targets.
- Scheduled occurrences have unconditional identities independent of run
  outcome.
- The default PR repair experience is one `Fix and merge` button/action.
- Status updates are configurable scheduled actions and disabled initially for
  `ptc_manager`.
- Repository selection is URL-backed and remembered in browser localStorage.
- Oban Lite supplies durable scheduling on SQLite.
- Deployment is a later typed action, not part of the first automation release.
- PtcManager adopts the reviewed `ptc_runner` ExDNA duplication ratchet and its
  tests exactly, while keeping a repository-local baseline and no runtime
  dependency on the `ptc_runner` checkout.

## Independent design review

An independent Codex review compared this plan with the current queue,
maintainer-action adapters, Herdr dispatch, synchronization, credential,
locking, and daily-update code. Its six findings were accepted and addressed:

1. Broad `gh` access cannot enforce target or publication gates. The design now
   distinguishes honest trusted-direct semantics from broker-enforced
   publication.
2. Newly configured actions had no runnable executor/handler model. Immutable,
   code-owned execution profiles and an adapter registry now define dispatch,
   workspaces, credentials, results, and synchronization.
3. Oban completion retries could duplicate a schedule occurrence. Immutable,
   unconditionally unique occurrences and insert-or-get invocation
   materialization now close that gap.
4. Issue/PR schedules and index-level Run now lacked a target. They are
   repository-only initially; contextual buttons provide exact issue/PR
   targets.
5. New concurrency policies conflicted with the current unconditional target
   uniqueness index. The plan now introduces atomic lock claims, compatibility
   rules, and fencing in the same migration that removes the old index.
6. Security-sensitive fields were mutable on the definition. They now live in
   immutable versions and workers may not consult current values for queued
   work.

Follow-up review found four sequencing gaps, also addressed: terminal dispatch
failure no longer stops later schedules; parent pause/archive and definition
version changes invalidate occurrences; definition activation revalidates every
trigger; basic cross-repository duplication moved before onboarding. A final
race review made claimed-to-materialized dispatch conditional against a
concurrent pause or version change. The Herdr-routing review then found a
separate last-slot race; durable transactional profile-slot claims, fencing,
and Herdr-aware crash reconciliation now close it. A final launch-window review
required the deterministic Herdr identity to be stored before `agent start`, so
a successful launch can be adopted even when the coordinator dies before
recording Herdr's response.

The maintainer's scenario review then simplified issue actions and clarified
sources of truth. The plan now treats triage and implementation-readiness as
prompt-configured generic Herdr actions, keeps durable issue facts in GitHub,
uses only a minimal PtcManager claim, supports an arbitrary repository registry,
and separates light planning capacity from heavy build/merge capacity. The
generic-result review selected a validated brokered envelope rather than
model-specific JSON parsing or direct database access. The workspace review
made repository bootstrap and complete preflight prerequisites to agent start.

A second independent review focused specifically on whether the test and deploy
plan could justify production confidence. Its five findings were accepted:

1. Deployment now starts in a worker-disabled maintenance mode and defines an
   effect boundary: SQLite snapshot restore is allowed only before any new
   durable or external effect; afterward recovery pauses work and goes forward
   or uses schema-compatible code rollback.
2. Slice 0.5 now builds reusable seams plus parity scenarios for current paths;
   future golden journeys are added by the slices that introduce those paths,
   and global deployability requirements apply only when relevant.
3. Manual Oban tests are complemented by a real-Oban, on-disk SQLite restart
   suite with independent connections, lock contention, and interrupted
   shutdown coverage.
4. Fault injection includes Git/port publication, result acknowledgement, and
   bootstrap/gate runners, while local adapter contract tests are required CI.
5. Schedule semantics now define and test DST gaps, folds, time-zone edits,
   clock rollback, and outages across a transition.

Its follow-up found three remaining sequencing ambiguities, also addressed:
Slice 0.75 now owns maintenance and canary admission; deployment requirements
are capability-dependent until generic dispatch and Oban exist; and ordinary
work remains paused until an allowlisted canary passes. DST gap collisions now
have an explicit coalescing rule and retain both nominal matches for audit.
A final check clarified that the pre-Slice-4 canary exercises the existing
direct compatibility adapter; the full Herdr and brokered-result canary becomes
mandatory only when Slice 4 introduces those boundaries.

## Research basis

- [GitHub issue dependencies](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies)
  documents native `blocked by`/`blocking` relationships, their board/icon
  presentation, GitHub CLI mutation flags, and structured `blockedBy` and
  `blocking` fields.
- [GitHub issue-dependency REST API](https://docs.github.com/en/rest/issues/issue-dependencies)
  documents repository-scoped list/add/remove operations used for authoritative
  reconciliation and brokered write access.
- [Herdr agent automation](https://herdr.dev/docs/agent-automation/) documents
  explicit `agent start --kind`, prompt, wait, status, and read operations.
- [Herdr socket API](https://herdr.dev/docs/socket-api/) documents the raw
  worktree, workspace, pane, agent, and plugin operations available to a
  coordinator.
- [Herdr agents](https://herdr.dev/docs/agents/) documents lifecycle detection,
  retained agent identity, and the distinction between detected processes and
  integration-backed status.
- [Herdr integrations](https://herdr.dev/docs/integrations/) documents
  installation per agent and confirms that integration state supplies lifecycle
  or session information rather than task routing.
- [Oban testing](https://hexdocs.pm/oban/testing.html) documents manual testing
  mode for explicitly inspecting and executing queued jobs without background
  queues, which fits deterministic scheduler scenarios.
- [Codex use cases](https://developers.openai.com/codex/use-cases) demonstrate
  coding, review, analysis, and automation uses.
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage)
  documents non-interactive execution, structured output, permissions, and
  session resume.
- [Cursor CLI documentation](https://docs.cursor.com/en/cli/overview) documents
  interactive and non-interactive coding, review, modification, and session
  resume.

These sources support treating all three as possible Herdr-launched workers;
they do not provide a fair cross-product benchmark. Routing preferences should
therefore be based on local health and measured PtcManager outcomes.

## Questions to settle during UX review

1. Should the initial workflow labels remain `ptc:ready`, `ptc:blocked`, and
   `ptc:needs-decision`, and should every repository default to the same names?
2. What exact assignee/comment convention should count as an external issue
   claim for the first repositories?
3. Should the default button labels change immediately to `Triage issue` and
   `Make implementation-ready`, or retain `Prepare issue` and `Review issue`
   while their prompts adopt the clearer meanings?
4. What should the initial per-worker limits be for light agents, heavy agents,
   and retained worktrees? The recommendation for the current Hetzner pilot is
   to measure two light and two heavy slots separately, with host-pressure
   admission still able to pause starts.
5. Should `Prepare merge decision` remain a default button or become an
   optional disabled action?
6. Should definition editing be allowed while runs of an older version are
   active? The recommendation is yes because runs are immutable and versioned.
7. Should a scheduled trusted-direct GitHub action require a one-time
   confirmation when first enabled? The recommendation is yes.
8. Should action deletion mean soft deletion only? The recommendation is yes so
   historical runs remain explainable.
9. Should `Run now` execute even when the schedule is paused? The recommendation
   is yes, with explicit confirmation and normal queue rules.
10. Which `ptc_runner` Nightly workflow names or files should the first CI action
   inspect?
11. At what local time should the first Nightly investigation run until an
   event-driven trigger is added?
