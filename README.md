# PtcManager

PtcManager is a private maintainer console for GitHub repositories and the
Codex or Claude agents working on them. A maintainer reads plain-language
summaries of issues and pull requests, presses one named button to start
bounded agent work, and decides when a pull request may merge. Deterministic
code owns every state transition; agent output is validated data, never
authority. The product principles are in [PLAN.md](PLAN.md).

The console has six views:

- **Planning** — the issue backlog grouped by what you can do next, with
  private summaries, the canonical `ptc:ready`, `ptc:blocked`, and
  `ptc:needs-decision` labels, `Blocked by #<number>` dependencies, your own
  triage labels, and the contextual issue actions;
- **Delivery** — the approval-to-merge Kanban fed by read-only GitHub check,
  status, draft, and mergeability signals, with **Fix**, **Fix and merge**, and
  **Cancel agent** actions and an **Approve for merge** decision bound to the
  exact PR version;
- **Updates** — private daily briefings of merged pull requests and commits;
- **Operations** — machine capacity, the agent and expensive-command timeline,
  and bounded read-only terminal panels;
- **Automations** — one editable, versioned prompt per repository automation,
  with its triggers, schedules, agent policy, and run history;
- **Configuration** — repository onboarding, checkout health, and agent
  capacity.

Implementation work runs in an isolated Herdr worktree that the repository's
own `.ptc-manager.yml` bootstrap prepares. The agent implements, validates,
runs the number of independent reviews frozen on the job, and either pushes
its branch and opens the pull request itself (agent publication) or commits
locally for PtcManager's credential-isolated GitHub App broker to verify and
publish. The maintainer's next consequential decision is whether that pull
request may merge.

Dispatch, maintainer actions, and publishing are disabled by default. The
implementation prompt forbids GitHub writes unless agent publication is
enabled. The worker identity also hosts explicitly queued maintainer actions
and therefore has an authenticated `gh` session; technical separation is
deferred. The broker can publish only the fenced, verified job branch and one
PR; it does **not** merge, close issues, edit issue text, or trust labels as
commands.

Upgrades still honor the former `PTC_REQUIRED_PRE_PR_REVIEWS` value when this
release first backfills already-existing jobs; it no longer overrides new
per-task choices after that migration.

### Machine usage history

PtcManager samples the host every 30 seconds and stores CPU, memory, build-disk
and 1-minute load together with the light, heavy, and expensive-operation slots
occupied at that moment. Samples older than 14 days are pruned. The Operations
chart draws bucket averages (30 seconds for the last hour, 5 minutes for the
last day, 1 hour for the last week) and leaves a visible gap wherever no sample
exists, for example across a deploy restart. The chart is server-rendered SVG:
no JavaScript chart library is bundled.

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
Planning, Delivery, and Operations. The demo seed fills every Planning group, so
the groups, the collapsed cards, the two ages, the external-author badge, the
triage-label chips, and one suggested follow-up are all visible without GitHub.
Label writes are deliberately refused in demo mode. No GitHub, Herdr, or LLM credentials are
used, even if effectful PtcManager variables exist in your shell. To restore
the exact starting state, stop the demo Phoenix server, run the reset command
again, and then restart it. The reset also refuses to continue when `lsof`
reports that another process still has the demo database open.

The authenticated routes are:

- `/` — Planning backlog and maintainer actions. See
  [The Planning page](#the-planning-page);
- `/board` — active delivery Kanban;
- `/updates` — easy-to-read daily briefings of merged pull requests and dated direct commits;
- `/operations` — three tabs. **Now** shows live CPU, memory, build-disk and
  slot signals, a machine-usage chart for the last hour, day, or week, the
  agents and expensive commands running at this moment, the work queue, and
  the workers. **Agents** (`/operations/agents`) lists the latest 40 agent runs
  grouped by day, with state filters and a switch for maintenance runs such as
  deployment canaries. **Performance** (`/operations/performance`) shows
  expensive-operation statistics and workspace-preparation timings. Select an
  agent on either tab to open a bounded, read-only terminal panel; active
  panels refresh every five seconds and expose no prompt or input controls;
- `/automations` — one row per automation of the selected repository: enabled
  switch, a plain-language "how it runs" summary, agent policy, last run, and
  next run, plus the five latest runs. `/automations/:id` opens one automation:
  its triggers (Run now, schedules built from presets with a time zone and a
  next-runs preview, contextual buttons), agent kind and GitHub access, the
  complete editable prompt with a runtime preview, advanced settings, its own
  run history, versions, and cross-repository copying. `/automations/new`
  creates a paused custom automation with a key derived from its name;
- `/configuration` — safe registration and health checks for dedicated repository
  checkouts, your own triage labels per repository, the **Integrations** section
  describing what GitHub synchronization, publication, private analysis, and the
  dispatcher currently reach, and direct links to each repository's prompt and
  automation settings.

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

In broker mode, the task prompt tells the implementation agent to validate the
change, run the number of independent reviews frozen on the job, fix findings,
and commit without using GitHub credentials. The review loop is agent-owned
prompt policy: PtcManager does not launch reviewers or store review evidence.
The agent places its retrospective in the final commit message between
`PTC-AGENT-RETROSPECTIVE-BEGIN` and `PTC-AGENT-RETROSPECTIVE-END` lines, and
the broker copies that section into the draft PR description.
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

### The Planning page

Planning groups the open backlog by what the maintainer can do next, instead of
by GitHub's update time. The groups, in order, are **Ready to start**, **Needs
your decision**, **Suggested follow-ups**, **Not prepared**, **Blocked**, **In
delivery**, **Waiting**, and **Stale**. An empty group is not drawn. In
delivery, Waiting, and Stale start collapsed; every other group starts open.
Both the group and the card state live in the page's own memory, so a GitHub
poll or an agent heartbeat cannot close what you just opened.

A card is compact until you press **Expand**: repository and number, title, the
badge row, the two ages, and one primary action. The primary action is the
approve form in Ready to start and Not prepared, the first contextual action in
Needs your decision, Blocked, Waiting, and Stale, and a link to the Delivery
board — carrying that pull request's lane — in In delivery.

Ages read "opened 12 d ago · updated 3 h ago", with the absolute UTC time in the
tooltip. **Updated** means any GitHub activity on the issue, including changes
PtcManager's own agents made.

An issue counts as **In delivery** when PtcManager started it, when its managed
pull request is open, or when an imported open pull request lists its number as
a closing reference. A pull request you opened by hand therefore takes its issue
out of the decision queue exactly as an agent-created one does.

**Stale** means no GitHub activity for 30 days, and only replaces Blocked or Not
prepared. A stale but ready issue stays in Ready to start, because it can still
be started with one click.

**Fix directly** starts implementation without a preparation round. Every
deterministic gate still applies — the issue must be open, unclaimed, projected,
free of a conflicting or blocking workflow label, and free of unresolved
dependencies — and only the two proposal checks are skipped. The click is the
approval, and it freezes the same review count as **Approve and start**. An
ambiguous issue then ends in the Delivery board's **Needs attention** lane like
any other job; use **Prepare issue** first when you are not sure the issue says
what it wants.

Each card shows who opened the issue only when that is somebody else: an
**External · @login** badge appears when GitHub's issue author differs from the
account behind `GITHUB_READ_TOKEN`. Nothing is shown until a synchronization has
recorded that identity, which the Configuration page reports per repository.
Follow-up issues PtcManager creates are opened through the worker's own `gh`, so
GitHub attributes them to the maintainer and they never carry the badge.

#### Your own triage labels

Each repository can configure a short list of GitHub labels with a role. A
**badge** label is shown on the card. A **park** label additionally moves the
issue into the **Waiting** group; it is a placement, never an approval gate, and
an issue can still be approved while parked. Names starting with `ptc:` are
refused, because those three labels are PtcManager's own display projection.
Configure the list under **Configuration → Your triage labels**; the label must
already exist in the GitHub repository, because PtcManager never creates one.

Configured labels render on every Planning card as toggle chips: filled when
GitHub reports the label, outlined when it does not. One click adds or removes
it. This is the single narrow exception to PtcManager's read-only GitHub client:
a root-owned wrapper runs `gh issue edit` as the worker with exactly one
repository, issue number, operation, and label, on a button press, with no agent
and no new credential. A host without that wrapper reports that it cannot write
labels and changes nothing.

Writing a label moves GitHub's `updated_at`, which is part of the issue content
digest, so the latest analysis goes stale and **Approve and start** disappears —
exactly as it would after a comment. PtcManager deliberately does not paper over
that: a comment posted in the same second is indistinguishable from the label
write, and treating the analysis as current would let implementation start on a
question nobody had read. Run **Prepare issue** again, or use **Fix directly**,
which needs no analysis.

Label names are matched case-insensitively everywhere, as GitHub matches them.
`PTC:ready` is refused for the same reason `ptc:ready` is: it would reach the
same GitHub label, and the workflow labels must keep coming only from
synchronization.

#### Suggested follow-ups

The implementation prompt asks every pull-request description for a
`## Retrospective` section, and asks the agent to add the label `ptc:follow-up`
to its own pull request when that section lists untracked follow-up work. Those
pull requests appear in the **Suggested follow-ups** group, before and after
merge, with two buttons: **Run retrospective** queues a read-only agent that
proposes concrete follow-ups, and **Dismiss** removes the card without touching
GitHub. Each proposed follow-up then has its own **Add as GitHub issue** button;
nothing reaches GitHub without that second, explicit click. A card leaves the
group when it is dismissed or when a retrospective reports that there is nothing
to follow up.

Nothing runs a retrospective automatically. The Delivery board shows the same
**Follow-ups suggested** badge and offers the retrospective in every lane for a
labelled pull request. The signal exists only while implementation agents
publish their own pull requests: in broker mode the agent has no GitHub access
and cannot set the label.

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
- **Cancel agent**, on the Delivery board's **In progress** and **Needs
  attention** cards and next to a running agent on Operations. It ends one
  implementation agent the maintainer no longer wants to wait for: the job ends
  as cancelled, its run ends, its Herdr pane is closed, and its partial worktree
  is kept for attention rather than discarded. It takes two clicks and refuses
  the deterministic phases that follow an agent — reconciliation, verification,
  and publication — because PtcManager, not an agent, owns those. If the pane
  cannot be closed, the console says so and the job stays cancelled;
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
while any assignee remains. Implementation agents that publish their own pull
request are told to assign the issue to themselves before work begins, and
`ptc_runner`'s worktree helper does the same for work started by hand; the
periodic issue sync therefore does not need to fetch every comment. Rows
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

The Automations index lists the selected repository's automations with an
enabled switch, a summary of the enabled triggers ("Every day at 02:00 · Run
now"), the agent policy, and the last and next run. Each automation has its own
page. Repository-level automations may hold several schedules; each schedule is
built from a preset (every day, weekdays, a weekday, hourly, or a raw cron
expression), a time, and a time zone, and shows its next three runs in that
zone with the UTC equivalent. Issue and pull-request automations get contextual
buttons on the Planning or Delivery surface instead. The agent kind selector
offers the kinds reported by online workers and the configured agent profiles,
marking profiles no online worker currently reports as offline. Built-in
triggers can be paused but not removed, because the bootstrap would recreate
them. Custom automations run in a read-only snapshot of the default branch; a
writable workspace that can open a pull request is a planned follow-up.

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

To onboard another public or private repository:

1. commit a `.ptc-manager.yml` contract to that repository whose bootstrap
   command prepares it, and an `AGENTS.md` describing its own conventions; add
   broker verification only if PtcManager will publish for the agent;
2. use **Configuration → Add another GitHub repository** to register its exact
   GitHub `owner/name`; PtcManager verifies access with the configured read-only
   GitHub credentials, derives `/srv/<repository-name>` as the checkout path,
   and creates the repository disabled;
3. press **Prepare checkouts** on Configuration, or deploy. Either clones any
   configured checkout that does not exist yet, gives it to the worker identity,
   and regenerates the drop-in that grants every configured checkout to both
   services; the button does it without building a release;
4. verify checkout, GitHub, and gate health, then review or copy the desired
   definitions on **Automations**;
5. enable the repository on **Configuration**, then enable only the definitions
   and schedules it needs and test a read-only action before approving
   implementation work.

A repository is registered disabled so its checkout, contract, and access can be
verified before anything reaches it. Synchronization covers enabled repositories
only, so its GitHub check stays unsynchronized until that step; access itself was
already proven when the repository was added. Enabling and disabling are recorded
in the audit trail and change nothing on GitHub, in the checkout, or in work
already in flight.

PtcManager cannot prepare a checkout itself. The coordinator runs with
`ProtectSystem=strict`, so `/srv` is read-only inside its mount namespace even
for root, and a new path only enters a namespace when the service restarts.
The deployment runs outside that namespace and already restarts the coordinator,
so it is the one place that can do this; onboarding is therefore add, deploy,
enable rather than a hand-run clone and a hand-edited unit.

A grant only enters a service's mount namespace when that service starts. The
deployment restarts the coordinator anyway, and it restarts `ptc_manager-herdr`
too when PtcManager records no live agent run and Herdr reports no live agent:
that restart ends every retained session, so it is taken only when there is
nothing to end. While a session is held the deployment says so and leaves the
service alone, and the **Prepare checkouts** button never restarts anything,
because nothing is drained around it. Each repository's **service access**
health names what is outstanding: a grant that is missing, a grant loaded but
waiting for a service to start, or access already in force.

The Configuration page displays the derived checkout path. A repository can be
removed there after explicit confirmation, but only when all managed jobs,
actions, automation invocations, deployments, resource operations, and worktree
lifecycles are terminal. Removal transactionally deletes PtcManager-owned
configuration and synchronized database records. It never changes the GitHub
repository or deletes server checkouts, worktrees, branches, pull requests, or
issues. Existing configured repository paths are preserved during upgrades.

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
managed work may finish, but no new work starts. The drain waits only for work
PtcManager is driving: runs that are queued, starting, or working, and blocked
or unknown runs whose agent action or job is still in flight. A retained agent
sitting on a prompt for an open pull request, or a stale record of an action
that already finished, does not hold a deployment, because restarting
PtcManager never touches Herdr agents. While waiting, the deployment names the
runs holding it, and **Cancel deployment** lifts the drain. Once a minute the
coordinator rechecks the default-branch head; if it moved past the requested
SHA, the deployment fails at once with a request to deploy the current head.
When nothing holds the drain, PtcManager hands the exact default-branch SHA to
a narrowly authorized systemd service. That service survives the application
restart, rechecks that the SHA is still the branch head, builds and installs
it, and reports completion back through a bounded status file. The new release
remains drained until that completion is recorded. A failure is shown in
deployment history and follows the same fail-closed maintenance behavior as
`mix ptc.deploy`.

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
# The two bootstrap checkouts; every repository added later is prepared by the
# deployment instead.
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
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-claude-trust /usr/local/bin/ptc-manager-worker-claude-trust
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-codex-arm /usr/local/bin/ptc-manager-worker-codex-arm
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-gh-label /usr/local/bin/ptc-manager-worker-gh-label
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
Authenticate the worker's configured Herdr agents and required GitHub identities.
Each login uses the subscription account in a browser on your own machine; the
worker keeps the resulting token under its own home directory, so a login done
as the interactive `agent` user does not count:

```sh
sudo -u ptc-manager-worker -H codex login
sudo -u ptc-manager-worker -H gh auth login
sudo -u ptc-manager-external -H codex login
# Claude Code and the Cursor CLI, once the deployment has exposed them:
ssh -t herdr-box sudo -u ptc-manager-worker -H claude auth login
ssh -t herdr-box sudo -u ptc-manager-worker -H env NO_OPEN_BROWSER=1 cursor-agent login
```

The deployment links `claude` from the worker Node directory and copies the
pinned Cursor CLI from `/home/agent/.local/share/cursor-agent/versions/` into
`/opt/ptc-manager-cursor-agent/` so both are on the worker's service `PATH`.

Node, npm, corepack, and pnpm are provisioned the same way: mise installs the
version this repository pins, the deployment copies it into a root-owned
`/opt/ptc-manager-<tool>-<version>` directory, checks the version it actually
got, and links it onto the worker's `PATH`. An agent therefore cannot rewrite
its own toolchain, and the version in use is whatever the deployed revision
says. Updating one is a change to `deploy/remote-deploy-herdr` and a deployment,
not a command run on the host, so the running toolchain always matches a commit.

pnpm earns its place for repositories that use it: it links a worktree's
`node_modules` into a shared content-addressed store instead of copying a tree
into each one, which is the only way a package cache can be shared while no
agent writes into another's workspace. The store lives in the worker's home,
which is on the same filesystem as the worktree root, so the links are hard
links rather than copies.

Each agent kind has its own way past interactive start-up questions. Codex
receives a per-process `-c projects=...` trust override, the Cursor CLI takes
`--force --trust`, and Claude Code, which asks "Do you trust this folder?" per
exact path with no start-up flag, is pre-answered by the coordinator through
the root-owned `ptc-manager-worker-claude-trust` helper before each managed
agent starts. Claude Code's one-time "Bypass Permissions mode" acknowledgment
must be accepted once as the worker, or skipped with
`{"skipDangerousModePermissionPrompt": true}` in the worker's
`~/.claude/settings.json`.

Managed Codex agents trust their repository checkout and worktree through a
per-process configuration override, so no checkout needs a persistent trust
entry in the worker's Codex configuration and no agent waits on Codex's
interactive trust question.

Approval and sandbox policy cannot stay per-process. A Herdr server restart
restores an agent's pane by running `codex resume <session-id>` with no
arguments, which drops the `--dangerously-bypass-approvals-and-sandbox` that
PtcManager passes at `herdr agent start`. The resumed agent then stops at an
approval prompt that no maintainer is watching for, and every action on its
pull request fails until someone answers it by hand. Before starting a Codex
agent the coordinator therefore records the same policy in the worker's
`~/.codex/config.toml` through the root-owned `ptc-manager-worker-codex-arm`
helper, inside a delimited managed block:

```toml
# BEGIN ptc-manager managed agent policy
approval_policy = "never"
sandbox_mode = "danger-full-access"
# END ptc-manager managed agent policy
```

Codex honours these keys only at the top level, so the block sits above every
table and the helper refuses to run when the file already sets either key
outside it. Arming is idempotent, and
`sudo -u ptc-manager-worker /usr/local/bin/ptc-manager-worker-codex-arm disarm`
removes the block again. The worker account runs managed agents only and
already receives the same arguments on every start, so the recorded policy
widens nothing that was previously narrower; it only stops a resumed agent
from being less capable than the one it replaces.

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
option because GitHub has already made the work terminal. A retained worktree
that no longer exists inside a healthy worktree root, or that a credential-free
Git check proves clean with no commit beyond the default branch, is removed
automatically because nothing can be lost. Every other retained worktree waits
until the maintainer chooses **Discard worktree** on the dashboard, which
force-removes it and records who discarded it. Cancelling a running agent uses
the same path: its worktree is retained for attention so the partial work can be
inspected before it is discarded.
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
Deployments may proceed while agents are only `waiting`. A deployment waits for
every run the coordinator is driving, and for a blocked or unknown run only
while its agent action or its job is still in flight: a retained agent sitting
on a prompt for an open pull request holds nothing, because restarting
PtcManager never touches Herdr agents. The host runner reads the same database
before it installs anything, through the identical rule kept in
`deploy/ptc-manager-active-managed-runs.sql`; a run one guard counts and the
other does not would refuse every deployment the instant it is handed over.
A deployment the host guard does refuse finishes seconds after it is requested,
so the Deployments page reports the last outcome, its exact instant, and the
host's own reason beside the button that asked for it rather than only in the
history below.

Every run also carries a derived health, because a Herdr snapshot refreshes each
agent every few seconds: a live heartbeat proves only that the pane still
exists. An agent parked at a question nobody is watching for keeps that
heartbeat while its pull request stops moving. PtcManager therefore records when
a run last changed state and judges health from the state it holds and how long
it has held it. A run blocked past `PTC_AGENT_BLOCKED_ATTENTION_MS` (ten minutes
by default), or silent past `PTC_AGENT_SILENT_ATTENTION_MS`, or ended as failed,
lost, or unknown, needs a person. Operations lists those under **Needs a
person** on the Agents tab and badges every run card, and the delivery board
names the stalled agent on the pull request it holds instead of blaming the pull
request for standing still. The health is derived on read from the run
PtcManager already reconciled, so no stored copy can disagree with Herdr.
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

A managed pull request is normally repaired by resuming its retained
implementation session. When Herdr no longer reports that session, the repair
still runs: preflight falls back to the way an imported pull request is always
repaired, in a fresh worktree at the exact head GitHub reports. Preflight
decides once and freezes the answer as `repair_mode` in the action's target
snapshot, so the adapter that runs and the postflight that judges the result
cannot disagree about which evidence applies.

The two modes carry different evidence. A retained session produced its commit
in the worktree being inspected, so PtcManager verifies the commit range,
ancestry, and cleanliness locally before recording a repaired status. A fresh
worktree has no local history worth trusting, so the only evidence is the head
that agent pushed matching what GitHub reports — the same guarantee imported
pull requests have always had, including for an authorized merge, which still
waits for GitHub itself to report the pull request merged.

The Phoenix endpoint listens only on `127.0.0.1:4000`. Expose it privately over
your tailnet with Tailscale Serve:

```sh
sudo tailscale serve --bg http://127.0.0.1:4000
tailscale serve status
```

Open the HTTPS `*.ts.net` address reported by Tailscale on the Mac or iPhone.
Do not use Tailscale Funnel for this private console.
