# PtcManager

PtcManager is a private maintainer console for reviewing GitHub work, approving
agent jobs, and seeing what Codex or Claude agents are doing and how long they
have been running. The coding agent tests and commits its implementation;
its task prompt asks it to run the configured number of `codex-review` skill
passes and fix their findings. PtcManager verifies and publishes the final
commit through its credential-isolated GitHub broker; the maintainer's next
consequential decision is whether the PR may merge.

The current Slice 4 increment adds the first PR decision-support path on top of
the approved execution, publication, worktree, and maintainer-action workflows:

- a responsive issue inbox with private plain-language summaries;
- four focused maintainer views: **Planning** for backlog decisions,
  **Delivery** for the approval-to-merge Kanban, **Updates** for daily change
  briefings, **Operations** for machine capacity plus the agent/task timeline,
  **Automations** for repository actions, schedules, prompts, and history, and
  **Configuration** for repository onboarding and compatibility prompt instructions;
- an **Approve and start** workflow backed by SQLite transactions, with a
  per-task choice of zero to three independent Codex review passes;
- one active implementation job per issue, enforced by the database;
- a live agent-activity panel with agent name, worker, role, task, start time,
  elapsed time, heartbeat, and Herdr identifiers, plus five recent ended runs;
- password authentication, CSRF protection, and approval audit events;
- deterministic demo data so the UI works without GitHub or model credentials;
- manual or periodic read-only GitHub issue synchronization;
- read-only Herdr agent reconciliation with lost-agent detection;
- optional private Codex investigations in an ephemeral read-only sandbox;
- synchronous GitHub freshness checks immediately before dispatch;
- durable worker leases and monotonically increasing fencing tokens;
- isolated Herdr worktrees and named Codex or Claude implementation agents;
- safe failure and lost-lease states visible in the dashboard;
- bounded, credential-free verification of a non-empty committed branch diff;
- fenced reconciliation claims that are safe to retry after interruption;
- verified base, head, commit count, and diff digest visible before PR acceptance;
- repository-owned validation instructions and a provider-neutral review-pass count frozen per task;
- exact-SHA branch push and draft-PR creation through a GitHub App broker;
- a strict checked-in `.ptc-manager.yml` setup contract with optional broker
  verification frozen from the exact candidate commit;
- a credential-free, disposable verifier checkout that must pass the frozen
  gate cleanly before the GitHub App broker can push that SHA;
- persistent light/heavy agent limits plus an independent expensive-operation
  limit instead of a hard-coded worktree count;
- durable worktree allocation, safe reclamation, and terminal cleanup;
- canonical PR status and GitHub link in the dashboard;
- read-only GitHub check-run, commit-status, draft, and merge-conflict signals
  that import every open repository PR and place it in In progress, Needs
  attention, or Ready to merge;
- a generic durable agent-action queue with **Investigate privately**,
  **Prepare issue**, **Review issue**, **Fix**, and **Approve and merge**
  buttons, all visible alongside queued implementation jobs on **Operations**;
- repository-specific, immutable prompt versions for private issue analysis,
  Approve-and-start implementation, and every active maintainer action. Each
  automation has one completely editable prompt, including any safety guidance
  the maintainer wants. PtcManager supplies a project-specific suggestion and
  adds only concise runtime facts and the machine result protocol. Queued and
  running actions keep their frozen version;
- a direct Delivery-board **Approve and merge** action once CI and mergeability
  are clean. New implementation agents include a configurable retrospective in
  the PR description rather than starting a separate retrospective agent;
- one shared clock/spinner status language for queued and actively running work
  across Planning, Delivery, and Operations;
- canonical display of the mutually exclusive `ptc:ready`, `ptc:blocked`, and
  `ptc:needs-decision` GitHub labels;
- structured projection of canonical `Blocked by #<number>` issue dependencies,
  with blocker links and status in the dashboard;
- approval and dispatch checks that prevent unresolved dependencies from
  starting implementation;
- agent-action attempts, results, and elapsed time in the shared activity view.
- an **Approve for merge** decision bound to the exact analyzed PR version;
- explicit stale-approval display when the observed head, base, or diff changes.

Upgrades still honor the former `PTC_REQUIRED_PRE_PR_REVIEWS` value when this
release first backfills already-existing jobs. It no longer overrides new
per-task choices after that migration.

Dispatch, maintainer actions, and publishing are disabled by default. The
implementation prompt forbids GitHub writes unless the explicit agent-publication
trial mode is enabled. In this initial version the worker
identity also hosts explicitly queued maintainer actions and therefore has an
authenticated `gh` session; technical separation is deferred. The broker can
publish only the fenced, verified job branch and one PR; it does **not** merge,
close issues, edit issue text, or trust labels as commands. See
[PLAN.md](PLAN.md).

## Run locally

Requirements: Elixir, Erlang/OTP, SQLite, `lsof`, and a C compiler toolchain.

```sh
mix setup
mix phx.server
```

### Managed expensive commands remain optional

Repositories keep their ordinary build, test, lint, and run commands. On a Mac,
in ordinary CI, or in any checkout without a PtcManager context, no resource
wrapper is needed and commands behave normally.

PtcManager injects `PTC_OPERATION_WRAPPER` only into managed Herdr panes. An
agent can coordinate a memory-heavy command without changing the command itself:

```sh
$PTC_OPERATION_WRAPPER run --label test -- mix test
$PTC_OPERATION_WRAPPER run --label build -- npm run build
```

The installed `ptc-operation` executable deliberately executes the requested
command directly when `PTC_MANAGED_OPERATION_CONTEXT` is absent. A repository
script may therefore use the same invocation locally and on a worker, but no
repository is required to adopt it. Nested wrappers reuse the active operation
instead of requesting another slot.

On a managed worker, requests are authenticated over a local Unix socket and
queued independently of the light/heavy agent-session limits. The Operations
page shows the waiting or running phase, timings, success rate, percentiles, and
peak memory. If the coordinator is unavailable in an explicitly managed pane,
the wrapper exits with status 75 instead of silently bypassing the limit.

Linux cgroup-v2 containment is optional and off unless
`PTC_OPERATION_CGROUPS=true`. The checked-in Herdr systemd unit delegates only
the memory and process controllers. Its launcher keeps the Herdr server in a
separate leaf; each managed pane then receives an agent memory boundary and
each coordinated command a child cgroup. That makes unwrapped agent commands
remain bounded and lets PtcManager measure the complete command process tree.
If a wrapper or worker disappears, the broker first fences the stale attempt,
then the root-owned bounded recovery helper terminates that exact child cgroup
before releasing its operation slot. Waiting wrappers send heartbeats and are
cancelled when they disappear, so abandoned queue rows cannot consume capacity.
When cgroup containment is disabled, crash recovery deliberately keeps the slot
fenced for maintainer attention because wrapper disappearance cannot prove that
its child process tree stopped.
Enable this only after installing the versioned Herdr unit, launcher, and
sourceable agent-context helper. It is never enabled on the Mac.

The deterministic state-machine tests run in the normal suite. A sub-second
socket/process integration test is kept out of the default suite and can be run
explicitly:

```sh
./scripts/ci/resource-operation-e2e
```

Open <http://localhost:4000> and sign in with `ptc-manager-dev`.

### Isolated browser checkpoint

To inspect the real LiveViews with deterministic mock issues, jobs, workers,
and agent activity, use the dedicated demo database. The reset task refuses to
touch the ordinary development database:

```sh
PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db mix ptc.demo.reset
PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db PORT=4100 mix phx.server
```

Open <http://localhost:4100>, sign in with `ptc-manager-dev`, and check
Planning, Delivery, and Operations. No GitHub, Herdr, or LLM credentials are
used, even if effectful PtcManager variables exist in your shell. To restore
the exact starting state, stop the demo Phoenix server, run the reset command
again, and then restart it. The reset also refuses to continue when `lsof`
reports that another process still has the demo database open.

The authenticated routes are:

- `/` — Planning backlog and maintainer actions;
- `/board` — active delivery Kanban;
- `/updates` — easy-to-read daily briefings of merged pull requests and dated direct commits;
- `/operations` — live CPU, memory, build-disk and slot signals, followed by
  the latest 40 agent runs and their tasks. Select an agent to open a bounded,
  read-only terminal panel; active panels refresh every five seconds and expose
  no prompt or input controls;
- `/automations` — repository-scoped, immutable action versions; one complete
  editable prompt with a runtime preview; Herdr-kind selectors; manual and scheduled
  triggers; Run now; cross-repository copying; and durable result history;
- `/configuration` — safe registration and health checks for dedicated repository
  checkouts, with direct links to each repository's prompt and automation settings.

To choose a different local password:

```sh
PTC_MANAGER_PASSWORD='choose-a-long-password' mix phx.server
```

On the first database setup, seed the initial repository checkout and then use
the real read-only adapters locally:

```sh
PTC_REPOSITORY_PATH=/absolute/path/to/ptc_runner \
GITHUB_READ_TOKEN='github_pat_read_only_token' \
PTC_GITHUB_SYNC_INTERVAL_MS=300000 \
PTC_HERDR_SESSION=default \
PTC_HERDR_SYNC_INTERVAL_MS=10000 \
mix phx.server
```

`PTC_REPOSITORY_PATH` seeds an empty database. During an upgrade from the
single-repository setup, startup may also import it into the sole repository row
when that row has no path, or verify that it still identifies the same physical
checkout. A conflict blocks startup with an explicit preflight error instead of
silently switching checkouts. Remove the legacy variable before configuring a
second repository.

The resulting absolute path belongs to that repository row; it is not a
process-wide override. Each enabled checkout must be the Git root for the
configured GitHub origin. PtcManager canonicalizes symlinks and Git common
directories and blocks startup and dispatch if two repository rows share a
checkout or linked worktree. Additional repositories must each have their own
clone. Agent work also requires one explicit absolute
`PTC_WORKTREE_ROOT`; PtcManager does not infer a different root beside each
checkout.

GitHub issue synchronization requires `GITHUB_READ_TOKEN` because native issue
dependencies are read through GitHub's authenticated GraphQL API. Set it to a
fine-grained token with repository metadata, Issues read, and Pull Requests read
access, including for public repositories. To project CI and merge readiness
onto the Delivery board, also grant
**Commit statuses: Read** and **Checks: Read**. PtcManager uses the token only
through its read-only GitHub client. If either CI source is unavailable, the
board reports CI as unknown and will not place that PR in **Ready to merge**.

Automatic draft-PR publishing is a separate, off-by-default capability. Create
a GitHub App installed only on the managed repository with repository
**Contents: Read and write** and **Pull requests: Read and write** permissions.
Store its private key outside the repository, readable only by the coordinator.
Configure the App ID, installation ID, and PEM path, then set
`PTC_PUBLICATION_ENABLED=true`.

Every repository that uses writable implementation worktrees must commit a
strict `.ptc-manager.yml` contract. The bootstrap is required and belongs to
the repository rather than PtcManager:

```yaml
version: 1
bootstrap:
  command: ./scripts/ptc/bootstrap
  timeout_minutes: 10
```

When the Herdr agent pushes its own branch and creates the PR, this is the
complete contract. Repository hooks may provide fast local feedback, while
GitHub CI and branch protection remain the authoritative merge gate.

Brokered publication is an optional alternative for agents without GitHub
write credentials. In that mode PtcManager verifies the exact commit in a
credential-free disposable checkout before its GitHub App publishes the
branch. Repositories using that mode must also configure:

```yaml
verification:
  before_publish: ./scripts/ci/pre-publication
  timeout_minutes: 45
```

Malformed sections and unknown fields fail closed. Omitting `verification`
does not weaken brokered publication: a broker job without that section is
blocked before PtcManager uses its GitHub credential.

`bootstrap.command` is one repository-relative, checked-in executable script.
Herdr remains responsible for creating the Git worktree. After creation,
PtcManager runs this script with the worktree as its current directory, records
the worktree-creation and setup durations, verifies that HEAD, branch, and
tracked files did not change, and only then starts the selected Herdr agent.
Repository-specific setup belongs behind this entrypoint. For example,
`ptc_runner` can commit a small wrapper which calls its existing setup logic:

```sh
#!/bin/sh
set -eu
./scripts/worktree.sh seed .
./scripts/worktree.sh init .
```

The setup script must be executable in Git. It may create ignored dependency
and build artifacts, but changing tracked files, HEAD, or the job branch fails
closed before any agent starts. Setup status, bounded output, and timings are
shown on the Operations page.

Issue planning, daily updates, and repository investigation automations use
`generic_ephemeral` read-only source snapshots. Other `generic_ephemeral`
actions also skip the writable build bootstrap. Writable implementation jobs
run the full repository setup. This repository's bootstrap maintains an
optional cache
beneath `${XDG_CACHE_HOME:-$HOME/.cache}/ptc-manager/workspaces`, keyed by the
dependency lock, repository setup files, Mix environment, Elixir/OTP, OS, and
architecture. A warm cache copies dependency sources, compiled dependency
artifacts, and pinned asset executables into the new worktree; agents never
share writable `deps` or `_build` directories. Set `PTC_WORKSPACE_CACHE_ROOT`
inside the repository setup environment to select another cache root. Cache
miss/hit state and restore, dependency, asset-tool, and publish timings are
recorded on Operations. Cache failure is non-fatal and falls back to the normal
clean bootstrap.

Before enabling a repository on a server, exercise the same handoff against a
local Herdr session:

```sh
mix ptc.herdr_workspace_canary \
  --session canary \
  --repository /absolute/path/to/repository
```

The canary asks real Herdr to create a disposable worktree, runs the real
checked-in setup script, reports phase timings, and removes its workspace and
temporary branch. It does not start an AI agent and does not access GitHub.

Before publication, PtcManager reads the contract from the verified candidate
commit—not from a possibly dirty filesystem copy—and freezes its bootstrap
command, pre-publication command, timeouts, and digest on the job. It then
creates a fresh checkout owned by `ptc-manager-gate`, runs both commands
with an empty environment and OS-enforced timeouts, verifies the checkout stayed
clean, and stores the exact SHA, exit status, duration, and at most 64 KiB of
output. A changed head, failed command, timeout, dirty checkout, missing
contract, or stale evidence prevents the broker from being called. The
exact-SHA checks disable Git replacement objects and compare tracked contents
and executable modes with a second fresh checkout, so repository-local replace
refs, index flags, and clean filters cannot hide a different contract or
modified file. Built-in checkout transformations such as `eol` and `ident` are
supported. Repository-local clean/smudge/process filters—including Git LFS—fail
closed in this first slice because their configuration cannot safely be copied
into the independent reference checkout. The frozen commands and timeouts are
also re-hashed before passed evidence is reused. The
credential-bearing publisher still disables Git hooks: untrusted repository
hooks must never run in the process holding the GitHub App token.

Brokered publication currently rejects repositories containing Git submodules.
Recursive submodule verification is intentionally deferred; failing closed is
safer than accepting a clean gitlink whose nested worktree is dirty.

The candidate commit owns this contract and the scripts it invokes. This gate
therefore proves which candidate command ran and what it returned; it is not a
defence against a malicious author weakening their own gate. A PR that changes
gate policy needs explicit human review, and protected-branch CI remains the
merge boundary.

In broker mode, the generated task tells the implementation agent to run the
configured tests, invoke the `codex-review` skill the configured number of
times, fix findings, and commit without using GitHub credentials. This review loop is agent-owned
prompt policy: PtcManager does not launch reviewers or store review evidence.
The agent places its bounded retrospective in the final commit message, and the
broker copies that section into the draft PR description.
The broker stages untrusted Git data separately, re-verifies the base, head, and
diff, pushes only the deterministic job branch, and creates or reconciles one
draft PR. Codex, Claude, Herdr, and the worker never receive its short-lived
GitHub token.

For a small trial that intentionally reuses the worker's authenticated `gh`
session, set `PTC_IMPLEMENTATION_AGENT_PUBLISHES_PR=true` and leave
`PTC_PUBLICATION_ENABLED=false`. Agent mode automatically enables the required
read-only PR discovery/status poller. The prompt then authorizes the coding agent to
push only its deterministic job branch and create or reuse one PR, while still
forbidding issue edits, unrelated GitHub writes, and merging. PtcManager
discovers that PR through its read-only client and accepts it only when the
repository, base, branch, and exact verified head match. This mode does not
weaken the explicit maintainer approval required before merge.

Private issue investigation is a light, durable Herdr action. It uses the
repository's configured agent selector, a read-only planning snapshot, and the
same file-based structured-result protocol as other generic actions. Its result
is stored only as a private PtcManager proposal; it cannot update GitHub. Queued,
running, failed, and completed investigations remain visible in Operations.

Pressing any maintainer-action button stores that prompt in the durable queue and authorizes one
agent to use the configured checkout and authenticated `gh` CLI. The initial
catalog contains:

- **Prepare issue**, which rewrites or closes the issue and leaves exactly one
  of `ptc:ready`, `ptc:blocked`, or `ptc:needs-decision` on an open issue;
- **Review issue**, which asks a configured Herdr agent to challenge and improve
  issue readiness and apply the same canonical label rules as **Prepare issue**;
- **Apply decision**, shown after an issue action returns a schema-validated
  question with two to four plain-language choices. A maintainer can choose an
  option or enter a custom answer; a queued agent then records that decision on
  GitHub and normally moves the issue to `ptc:ready`. Choices are tied to the
  exact synchronized issue version, so an edit requires a fresh analysis;
- **Approve and merge**, which has the highest heavy-work queue priority.
  PtcManager prevents new writing agents from starting in that repository while
  the action is queued, running, or awaiting GitHub confirmation. The Herdr
  agent—not PtcManager—repairs and pushes the branch, watches required CI,
  resolves any newly introduced conflict, and merges that exact PR with the
  authenticated `gh` CLI. PtcManager verifies the resulting GitHub state and
  retains the session until the PR is merged or closed. Imported PRs can still
  be reviewed and repaired, but do not receive a generated implementation
  retrospective because PtcManager did not start their agent.

Maintainer actions use two deliberately separate resource pools. Heavy work is
ordered **merge → repair → new implementation**, with oldest work first inside
each priority. A merge action still serializes repository writers, so agents do
not race to rewrite or merge branches. Light issue preparation, review,
decision, investigation, and summary work can continue independently. The two
limits are persisted and editable under **Configuration → Concurrent agents**;
`PTC_LIGHT_AGENT_CAPACITY` and `PTC_HEAVY_AGENT_CAPACITY` only provide the
initial values for a new database.

Daily updates reuse the planning lane. Oban Lite persists scheduled occurrences
in the same SQLite database. After 02:00 in `Europe/Stockholm`, it idempotently
queues one read-only update per enabled repository for the immediately preceding
local calendar day. It deliberately does not scan or backfill older dates. The
coordinator selects pull requests by GitHub's `merged_at` timestamp and direct
commits by their committer timestamp for the exact timezone-aware window. Every
commit query is pinned to one captured default-branch head. GitHub does not
expose the arrival time of a direct push, so that distinction is shown in the
bounded manifest rather than guessed. A configured generic Herdr agent receives
that manifest and a read-only local snapshot, then writes a plain-language
Markdown briefing with practical examples. PtcManager rejects model-reported
SHA, included-change count, or PR numbers that differ from the coordinator manifest. It
stores the structured result and provenance in SQLite. The Updates page renders
the Markdown through an HTML sanitizer before displaying it.

The complete generation prompt and schedule are editable per repository on
**Automations**. `ptc_runner` receives the daily trigger enabled by default;
`ptc_manager` receives it disabled. Pausing a definition or trigger prevents
future materialization without changing an already queued invocation.

```sh
PTC_DAILY_DIGEST_ENABLED=true
PTC_DAILY_DIGEST_HOUR=2
PTC_DAILY_DIGEST_TIME_ZONE=Europe/Stockholm
PTC_DAILY_DIGEST_INTERVAL_MS=60000
```

The hour is interpreted in the configured time zone, including daylight-saving
changes. Failed or waiting daily jobs remain visible in Operations and on the
corresponding Updates entry.

Before an issue-planning agent starts, PtcManager synchronizes the canonical
GitHub issue, records its content digest, and captures the configured checkout's
exact Git commit SHA and branch or ref. The action details show the source ref
and SHA. The planning agent
runs from a separate coordinator-owned Git clone whose complete tree is made
read-only before the worker can see it; concurrent build agents therefore cannot
alter the evidence. The temporary clone is removed when the agent exits, while
its provenance remains in the action record. A durable reaper retries cleanup
after an interrupted or expired run. This makes a review's issue and code
evidence reproducible even if `main` advances while other agents are merging
work. In production the snapshot directory is owned by the coordinator beneath
the sticky shared-output parent, so the worker can traverse and read it but
cannot rewrite, rename, or replace it.

For issue dependencies, GitHub remains authoritative. Maintainer actions write
the canonical `Blocked by #<number>` marker into the dependent issue and apply
`ptc:blocked`. GitHub synchronization projects those markers into local
dependency rows for display and safety checks. An unresolved or unknown blocker
prevents approval; if it appears after approval, dispatch cancels that stale job
before starting an agent. Closing every blocker does not auto-start the dependent
issue: the dashboard asks the maintainer to run **Prepare issue** again and make
a fresh approval decision. At most 100 dependency rows are projected per issue,
and one repository sync performs at most 100 lookups for blockers that are not
already known locally. An issue declaring more than 100 blockers gets a visible
overflow warning and remains ineligible for approval until its dependency list
is simplified. Definitive missing or pull-request references remain visible as
**not synchronized** instead of failing the whole sync. Rows that predate this
projection remain approval- and dispatch-ineligible until their first successful
GitHub synchronization.

GitHub assignment is projected as the advisory work claim. Issue cards show
`Taken by @login`, and PtcManager will not approve duplicate implementation
while any assignee remains. This matches `ptc_runner`'s worktree helper, which
assigns the issue and posts its standardized claim comment before work begins;
the periodic issue sync therefore does not need to fetch every comment. Rows
that predate this projection remain approval-ineligible until their first
successful GitHub synchronization confirms the assignment state.

Enable the runner only after Codex and `gh` are authenticated for its OS user:

```sh
sudo -u ptc-manager-worker -H codex login
sudo -u ptc-manager-worker -H gh auth login
```

Then set `PTC_AGENT_ACTIONS_ENABLED=true`. Completed actions trigger a GitHub
issue re-sync; GitHub title, body, open/closed state, and workflow label remain
canonical. The action's final private summary stays in PtcManager.

The seed data is idempotent. To restore the demonstration dashboard after
trying approvals:

```sh
mix ecto.reset
```

### Generic automations and additional repositories

PtcManager stores every automation as a repository identity plus immutable
versions. A version freezes its target type, execution profile, Herdr selector,
GitHub access, light/heavy queue, lock policy, timeout, result contract, and one
maintainer-editable task prompt. New repositories receive
a PtcManager suggestion that names the project and delegates coding conventions
and validation to its checked-in instructions and scripts. The Automations page
previews that editable prompt together with example runtime context.
A trigger points at the current
version only when it materializes a run, so later edits cannot alter queued or
running work.

`generic_ephemeral` actions run through Herdr with an explicit opaque kind. The
configured selector may accept any healthy profile, prefer one kind with
fallback, or require an exact kind. The coordinator opens the prepared snapshot,
starts the chosen kind, records its Herdr name/session, and accepts only a
versioned JSON result file outside the repository. It never parses terminal
prose and does not give the agent database credentials. Adding a healthy
`claude`, `cursor`, or future kind is a worker profile/configuration change, not
a new action executor.

The built-in **Investigate nightly CI** action demonstrates the generic path.
Its manual trigger is enabled for `ptc_runner`; its schedule starts paused. The
agent uses a stable invocation marker when searching for or creating a failure
issue, which makes a retry deduplicate against GitHub rather than trusting local
memory.

To onboard another private repository:

1. create a dedicated clone on the worker and authenticate the existing `gh`
   CLI identity for it;
2. commit a `.ptc-manager.yml` contract whose bootstrap command prepares that
   repository; add broker verification only if PtcManager will publish for the agent;
3. use **Configuration → Add another GitHub repository** to register the exact
   absolute checkout path; it starts disabled;
4. verify checkout, GitHub, and gate health, then review or copy the desired
   definitions on **Automations**;
5. enable only the definitions and schedules that repository needs, then test a
   read-only action before approving implementation work.

`ptc_manager` intentionally receives daily updates and scheduled nightly checks
disabled. Its checked-in pre-publication contract runs the same ExDNA
duplication ratchet policy used by `ptc_runner`: known clones live in
`.duplication-baseline.json`, while `scripts/duplication_gate.sh check` rejects
new duplication.

## Verify

```sh
mix precommit
```

This formats the project, compiles with warnings treated as errors, and runs
the deployment-critical suite across three isolated SQLite partitions. The
test phase has a hard wall-clock budget of less than 60 seconds; a failed,
hung, or slower run fails the gate. Real filesystem, Git-worktree, cache,
process-timeout, and disposable-migration lifecycle tests carry the `nightly`
tag. They remain part of a normal unfiltered `mix test` and run every night in
GitHub Actions through `.github/workflows/nightly.yml`; the workflow can also
be started manually. Set `PTC_TEST_BUDGET_SECONDS` or `PTC_TEST_PARTITIONS`
only for local diagnosis—the checked-in defaults are the publication and
deployment contract.

## Production configuration

Production requires these environment variables:

- `DATABASE_PATH`: absolute path to the SQLite database;
- `SECRET_KEY_BASE`: Phoenix signing/encryption secret;
- `PTC_MANAGER_PASSWORD`: unique maintainer password of at least 16 nonblank characters;
- `PHX_HOST`: external hostname shown in generated URLs;
- `PORT`: local listening port, normally `4000`.

The adapter variables and safe starting values are documented in
[`deploy/ptc_manager.env.example`](deploy/ptc_manager.env.example).

Generate a secret with:

```sh
mix phx.gen.secret
```

The production endpoint binds to `127.0.0.1`, not the public network. The
intended first deployment exposes it only through Tailscale (for example,
Tailscale Serve), so the same UI is available privately from a Mac and iPhone.

Build a release with:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

For subsequent deployments to the configured Herdr machine, deploy the exact
clean Git commit with:

```sh
mix ptc.deploy
```

That command is also the one-time bootstrap for deployment from PtcManager
itself. It installs the host-owned runner and an immutable release revision
marker. After that release is running:

1. add `andreasronge/ptc_manager` as an enabled repository in Configuration;
2. point it at the trusted server checkout containing its checked-in
   `.ptc-manager.yml`;
3. open **Deploy** in PtcManager.

The Deploy page compares the SHA recorded in the running release with the
latest SHA on the repository's default branch. It shows **Update available**
when they differ, and **Up to date** when they match. **Check for updates**
refreshes the comparison. The private repository is read using the existing
`GITHUB_READ_TOKEN`; no separate GitHub account is introduced.

**Deploy when safe** records an audited request and enters drain mode: existing
managed work may finish, but no new work starts. When the managed-agent count
reaches zero, PtcManager hands the exact default-branch SHA to a narrowly
authorized systemd service. That service survives the application restart,
rechecks that the SHA is still the branch head, builds and installs it, and
reports completion back through a bounded status file. The new release remains
drained until that completion is recorded. A failure is shown in deployment
history and follows the same fail-closed maintenance behavior as `mix
ptc.deploy`.

Repository deployment is opt-in. Its strict repository-owned contract is:

```yaml
deployment:
  command: ./scripts/ptc/deploy
  timeout_minutes: 20
```

The command is extracted from the requested Git archive and receives only
`PTC_DEPLOY_SHA`, `PTC_DEPLOY_SOURCE_ARCHIVE`, and `PTC_DEPLOYMENT_ID`. A
repository without this section is never offered a deployment button.
The command and timeout are read from `.ptc-manager.yml` at the requested Git
SHA and frozen in the deployment record before draining begins. A stale or
dirty server checkout therefore cannot change what the host runner executes.
Startup and completion deadlines turn a missing unit/status handoff into a
visible terminal failure rather than leaving deployment permanently blocked.

The target defaults to the `herdr-box` SSH host from the local SSH config. Use
`mix ptc.deploy --target another-host` to select a different SSH alias, or
`mix ptc.deploy --dry-run` to show the resolved commit and release identifier
without running checks or changing either machine.

The task runs the checked-in bootstrap and pre-publication scripts locally,
uploads a Git archive rather than uncommitted files, and builds the production
release on the server with its mise-managed
Elixir, Erlang, and Node toolchain. Before replacing `/opt/ptc_manager`, it
checks both managed runs and the manual and worker Herdr sessions. Non-idle
agents make deployment stop safely; idle Herdr sessions continue running and
are not restarted. Immediately before the release swap, the task stops the
coordinator and checks the database again so no new managed work can race the
deployment. The new release always starts in maintenance mode: the web UI and
`/health` remain readable, while pollers, button-triggered mutations, agents,
and queued work stay paused.
The deployment writes this override under `/etc/systemd/system`, so a reboot
cannot silently resume work after a failed deployment. If an override already
existed, a pre-effect rollback restores it byte-for-byte.
Steady state relies on the application's `active` default; do not add
`PTC_OPERATIONAL_MODE` to the base environment file because systemd gives
environment-file values precedence over the maintenance override.

The task discovers the coordinator's active systemd environment files and
checks the configured manual Herdr session. If the optional
`ptc_manager-herdr` worker service is running, its live session is checked too;
observation-only installations do not require that worker service.

Deployments also install the pinned Node.js runtime used for release builds
under `/opt/ptc-manager-node-<version>` and expose `node`, `npm`, `npx`, and
`corepack` through `/usr/local/bin`. They install the server's trusted mise
executable as root-owned `/usr/local/bin/mise` as well. Repository-owned
bootstrap scripts can therefore install each project's pinned toolchain into
the persistent worker home without depending on the interactive `agent`
account. The deployment verifies both Node and mise as `ptc-manager-worker`
before replacing the application release. The isolated publication gate uses
mise separately to install pinned Erlang and Elixir builds directly under a
root-owned `/opt/ptc-manager-gate-mise` prefix, rejects symlinks escaping that
prefix, and installs only Hex and Rebar under
`/opt/ptc-manager-gate-mix`. This toolchain is used later by credential-free
agent publication gates. Deployment does not rerun the test suite on the
server: the local pre-deploy gate is authoritative, while the server verifies
the production build, migrations, maintenance startup, canary, and health.

The task reads the actual `DATABASE_PATH` and `PORT` from the running systemd
service, creates a consistent SQLite backup, and replaces `/opt/ptc_manager`.
Starting the new release applies all pending Ecto migrations before the web
endpoint starts. The task requires `/health` to report maintenance mode, then
runs one explicitly allowlisted credential-free canary against an
existing open issue. The canary result is persisted and its run appears in
Operations. The deployment canary does not invoke an external agent. The task
verifies `/health` in canary mode,
removes the persistent systemd maintenance override, and makes exact canary
activation its final transition. Only then do ordinary queues resume.

Before the canary starts, a failure can safely restore both the previous
release and the SQLite backup. The canary itself is the effect boundary because
it records a durable run and proposal. A failure at or after that point never
restores an older database automatically; the new release and current database
remain paused in maintenance mode for forward repair. Successful deployments
report both backup paths, retain the three newest release/database backup
pairs, and prune older successful backups.

The test suite also creates a fully migrated disposable SQLite target. It
proves that a pre-effect failure restores its snapshot, that ordinary manager
work remains paused until the allowlisted canary activates it, and that a
post-effect restart preserves the canary's durable result instead of restoring
older state. This complements the deployment script checks with executable
database and domain behavior.

## Hetzner systemd and Tailscale

Build the release, copy `_build/prod/rel/ptc_manager` to `/opt/ptc_manager`, and
create the dedicated service account and writable database directory:

```sh
sudo groupadd --system ptc-manager
sudo groupadd --system ptc-manager-output
sudo groupadd --system ptc-manager-worker
sudo groupadd --system ptc-manager-external
sudo groupadd --system ptc-manager-repo
sudo groupadd --system ptc-manager-publish
sudo useradd --system --home /var/lib/ptc_manager --gid ptc-manager --groups ptc-manager-output,ptc-manager-repo,ptc-manager-publish --shell /usr/sbin/nologin ptc-manager
sudo useradd --system --home /var/lib/ptc_manager-worker --gid ptc-manager-worker --groups ptc-manager-repo,ptc-manager-output,ptc-manager-external --shell /usr/sbin/nologin ptc-manager-worker
sudo useradd --system --home /var/lib/ptc_manager-external --gid ptc-manager-external --groups ptc-manager-output --shell /usr/sbin/nologin ptc-manager-external
sudo useradd --system --home /var/lib/ptc_manager-verifier --gid ptc-manager-repo --groups ptc-manager-publish --shell /usr/sbin/nologin ptc-manager-verifier
sudo useradd --system --home /var/lib/ptc_manager-gate --gid ptc-manager-repo --shell /usr/sbin/nologin ptc-manager-gate
sudo install -d -o ptc-manager -g ptc-manager -m 0700 /var/lib/ptc_manager
sudo install -d -o ptc-manager -g ptc-manager-output -m 3770 /var/lib/ptc_manager-output
sudo install -d -o ptc-manager -g ptc-manager-output -m 2750 /var/lib/ptc_manager-output/planning-snapshots
sudo install -d -o ptc-manager-worker -g ptc-manager-output -m 0710 /var/lib/ptc_manager-worker
sudo install -d -o ptc-manager -g ptc-manager-output -m 3770 /var/lib/ptc_manager-worker/agent-results
sudo install -d -o ptc-manager-external -g ptc-manager-external -m 0700 /var/lib/ptc_manager-external
sudo install -d -o ptc-manager-verifier -g ptc-manager-repo -m 0700 /var/lib/ptc_manager-verifier
sudo install -d -o ptc-manager-gate -g ptc-manager-repo -m 0700 /var/lib/ptc_manager-gate
sudo install -d -o ptc-manager -g ptc-manager-publish -m 2750 /var/lib/ptc_manager-publish
sudo install -d -o ptc-manager-worker -g ptc-manager-repo -m 2750 /srv/ptc_manager-worktrees
sudo install -d -o ptc-manager-external -g ptc-manager-external -m 2770 /srv/ptc_manager-external
sudo chown -R ptc-manager-worker:ptc-manager-repo /srv/ptc_runner /srv/ptc_manager
sudo chmod -R g-w,g+rX,o-rwx /srv/ptc_runner /srv/ptc_manager
sudo find /srv/ptc_runner /srv/ptc_manager -type d -exec chmod g+s {} +
sudo install -d -o root -g root -m 0755 /etc/ptc_manager
sudo install -o root -g root -m 0644 deploy/ptc_manager.service /etc/systemd/system/ptc_manager.service
sudo install -o root -g root -m 0644 deploy/ptc_manager-herdr.service /etc/systemd/system/ptc_manager-herdr.service
sudo install -o root -g root -m 0600 deploy/ptc_manager.env.example /etc/ptc_manager/ptc_manager.env
# After downloading the GitHub App PEM to a safe temporary location:
sudo install -o root -g ptc-manager -m 0640 /safe/path/github-app.pem /etc/ptc_manager/github-app.pem
sudo install -o root -g root -m 0600 deploy/ptc_manager-herdr.env.example /etc/ptc_manager/herdr.env
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-git /usr/local/bin/ptc-manager-worker-git
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-bootstrap /usr/local/bin/ptc-manager-worker-bootstrap
sudo install -o root -g root -m 0755 deploy/ptc-operation /usr/local/bin/ptc-operation
sudo install -o root -g root -m 0755 deploy/ptc-manager-operation-recover /usr/local/bin/ptc-manager-operation-recover
sudo install -o root -g root -m 0755 deploy/ptc-manager-herdr-launch /usr/local/bin/ptc-manager-herdr-launch
sudo install -d -o root -g root -m 0755 /usr/local/libexec
sudo install -o root -g root -m 0644 deploy/ptc-manager-agent-context /usr/local/libexec/ptc-manager-agent-context
sudo install -o root -g root -m 0755 deploy/ptc_manager-external-git /usr/local/bin/ptc-manager-external-git
sudo install -o root -g root -m 0755 deploy/ptc_manager-external-push /usr/local/bin/ptc-manager-external-push
sudo install -o root -g root -m 0755 deploy/ptc_manager-external-cleanup /usr/local/bin/ptc-manager-external-cleanup
sudo install -o root -g root -m 0440 deploy/ptc_manager.sudoers /etc/sudoers.d/ptc_manager
sudo visudo -cf /etc/sudoers.d/ptc_manager
```

Edit `/etc/ptc_manager/ptc_manager.env`, replace every placeholder, verify the
binary and checkout paths, then start the release:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ptc_manager-herdr ptc_manager
sudo systemctl status ptc_manager
```

The coordinator, implementation worker, external-PR repairer, and Git verifier
run as separate OS identities. Herdr, implementation agents, and the initial
maintainer-action runner use `ptc-manager-worker`; that account has the
authenticated `gh` session needed by explicitly queued maintainer actions and
the optional agent-publication trial. Outside that explicit mode, the
implementation prompt instructs coding agents not to use it. A later
credential broker can enforce that separation technically. Private read-only
investigations use a generic Herdr agent under the worker identity. Bounded branch verification runs as
`ptc-manager-verifier`; repository-owned pre-publication gates run as
`ptc-manager-gate`. Both use an empty environment and have no credentials.
Unlike the Git verifier, the gate identity is not a member of the
publication-staging group. Gate commands execute in a temporary gate-owned clone
of the exact commit, so they can create build artifacts without receiving write
access to the agent's retained worktree. None of
these accounts can read the root-only coordinator environment or inspect its
process. The `ptc-manager-external` account can write only its disposable
checkout root, has no repository-group membership, and must never be logged in
to `gh`. The coordinator fetches the exact PR head and base into a private,
disposable bare repository—without modifying the worker-owned source checkout—and
exports only those verified commits to a Git bundle,
then performs an ordinary fast-forward push from a fresh bare repository through
a narrow root-owned wrapper running as the authenticated worker; the repair
agent never receives that credential and its repository configuration is never
used by the credential-bearing push process.
Authenticate the worker's configured Herdr agents and required GitHub identities:

```sh
sudo -u ptc-manager-worker -H codex login
sudo -u ptc-manager-worker -H gh auth login
sudo -u ptc-manager-external -H codex login
```

Managed Codex agents trust their repository checkout and worktree through a
per-process configuration override, so no checkout needs a persistent trust
entry in the worker's Codex configuration and no agent waits on Codex's
interactive trust question.

Each checkout persisted as a repository's `local_path` is owned and writable
only by the worker. Both services run with `ProtectSystem=strict`, so every
such checkout must also be listed in `ReadWritePaths` of
`ptc_manager-herdr.service`, and its `.git` directory in `ReadWritePaths` of
`ptc_manager.service`; a checkout outside those lists fails every
implementation dispatch with Git's `cannot lock ref`. After adding a
repository, reinstall both unit files, run `systemctl daemon-reload`, and
restart both services. The deployment refuses to proceed while a configured
checkout is read-only inside a running service.
The `ptc-manager-repo` group gives the coordinator, verifier, and gate
read/execute access without filesystem write access. The worker-owned
`PTC_WORKTREE_ROOT` contains only job worktrees. It and every ancestor must be
non-writable by group and other identities; the deployment enforces mode
`2750` on the worker-owned root and PtcManager refuses new work when that
invariant is broken. This keeps private build artifacts safe while still
allowing the coordinator read-only traversal. PtcManager removes a worktree
through Herdr only after a credential-free Git check proves a non-terminal
checkout is clean and its exact head is on the PR branch. Dirty, missing, or
unpushed non-terminal work is retained for attention. A merged or closed PR is
the explicit exception: its abandoned checkout is removed with Herdr's force
option because GitHub has already made the work terminal.
The separate `ptc-manager-publish` group lets only the coordinator and Git verifier
exchange a bounded Git bundle; the worker cannot access publication staging.
The coordinator and generic Herdr agents exchange task, schema, and result files
only through the setgid directory at `PTC_AGENT_ACTION_OUTPUT_DIR`. The default
`/var/lib/ptc_manager-worker/agent-results` path is writable inside the Herdr
service sandbox; planning snapshots remain read-only to agents. The coordinator
database directory is `0700`.

The verifier runs each fixed Git command with an empty environment, a wall-clock
timeout, a Linux address-space limit, and preflight limits for commits, changed
paths, individual blobs, total blob bytes, and generated diff bytes. A result
outside those limits remains pending for maintainer review; it never becomes PR
eligible automatically. Repository bootstrap and pre-publication commands use
the same empty credential environment and nested OS timeouts; configure their
tool search path with `PTC_PRE_PUBLICATION_PATH` when Elixir, Node, or another
required tool is not installed under `/usr/local/bin`, `/usr/bin`, or `/bin`.
The standard deployment provisions the pinned BEAM tools there and sets the
root-owned archive path with `PTC_PRE_PUBLICATION_MIX_HOME`.

Use the same Herdr session name in the coordinator and dedicated Herdr service.
The coordinator selects it with Herdr's explicit `--session` option after
switching OS identity, so it does not depend on `sudo` preserving environment
variables. An existing Herdr session owned by `root`, `agent`,
or another login account is deliberately not used by automated dispatch;
recreate it under `ptc-manager-worker` before enabling dispatch.

For an observation-only trial, an existing session can instead be exported as
a JSON snapshot. Install `ptc_manager-herdr-observer.service` and its timer as
the session owner, and configure the coordinator with
`PTC_HERDR_BINARY=/usr/local/bin/ptc-manager-herdr-snapshot-read` and no
`PTC_HERDR_RUN_AS_USER`. The coordinator can then list agent status but has no
socket or CLI path with which to prompt or control the observed session. Keep
`PTC_DISPATCH_ENABLED=false` while using this mode.

Ordinary Herdr CLI calls are bounded by `PTC_HERDR_TIMEOUT_MS`. Agent startup
instead uses Herdr's `PTC_IMPLEMENTATION_AGENT_START_TIMEOUT_MS` readiness
limit plus five seconds for the outer command to return its result; the generic
timeout must not cut that longer startup wait short. Codex implementation agents
default to the current unattended CLI flag
`--dangerously-bypass-approvals-and-sandbox`; override
`PTC_IMPLEMENTATION_AGENT_ARGS` only when the installed agent CLI requires a
different supported mode. After
`PTC_HERDR_STALE_AFTER_MS` without a successful snapshot, standalone agents are
shown as `lost`, while managed agents become `unknown` and their jobs remain in
reconciliation so a duplicate cannot start. After
`PTC_DISPATCH_RECONCILE_AFTER_MS`, a successful Herdr snapshot that confirms a
managed attempt never appeared can safely release that attempt.
An implementation agent that returns to an idle prompt without completing gets
one bounded `PTC_IMPLEMENTATION_IDLE_TIMEOUT_MS` deadline (five minutes by
default). When it expires, the execution slot is released and the partial
worktree is kept for inspection instead of blocking queued work indefinitely.
Queued implementation jobs and generic agent actions can also be cancelled
from Operations; cancellation is atomic and fails if a worker already claimed
the item.

PR tracking and worktree allocations live in SQLite and survive process or
server restarts. GitHub synchronization imports every open PR in each enabled
repository; a branch already owned by a PtcManager job remains the managed
record instead of being duplicated as an external PR. If no
explicit `PTC_PR_RECONCILE_ENABLED` value is set, any positive
`PTC_GITHUB_SYNC_INTERVAL_MS` also enables this PR import/reconciliation loop.
The inexpensive list snapshot runs each cycle, while detailed CI and
mergeability health rotates through one open PR per cycle to stay within GitHub
API limits. If no
implementation-capable agent slot is available, the job stays queued. Once a
managed PR is open, its named Herdr session and worktree move to a
passive `waiting` state: they remain available for CI repairs or review feedback
without consuming a CPU-active implementation slot. The Operations and backlog
screens show these retained agents separately from agents that are running now.
Deployments may proceed while agents are only `waiting`; the deploy guard still
stops for queued, starting, working, blocked, or unknown runs.
When GitHub reports the PR merged or closed, the job becomes terminal and the
cleanup worker removes the Herdr worktree and session idempotently. This final
cleanup is authorized to discard a dirty checkout because GitHub has already
made the PR terminal; non-terminal cleanup still requires a clean, verified
head.

External PRs participate in the same CI and conflict lanes, but they do not
create fake issues or jobs. Private merge review is omitted because there is no
original retained implementation context. Repair actions create a named Herdr
agent in a fresh isolated worktree rooted at the exact observed PR head. **Fix**
authorizes that agent to repair and push the existing branch. **Fix and merge**
also authorizes that same agent to watch and repair CI until green and merge only
that exact PR. PtcManager keeps the action durable, reserves repository priority,
records the Herdr identity for read-only output, and independently confirms the
GitHub result before releasing the repository and cleaning the worktree.

The Phoenix endpoint listens only on `127.0.0.1:4000`. Expose it privately over
your tailnet with Tailscale Serve:

```sh
sudo tailscale serve --bg http://127.0.0.1:4000
tailscale serve status
```

Open the HTTPS `*.ts.net` address reported by Tailscale on the Mac or iPhone.
Do not use Tailscale Funnel for this private console.
