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

## Execution profiles and review limits

Configuration → **Execution profiles and models** sets the implementation and
reviewer agent, model, reasoning effort, and maximum reviews for three presets:

| Suggestion | Initial implementation model | Maximum reviews |
| --- | --- | --- |
| Small scope and low risk | Codex `gpt-5.4-mini` | 1 |
| Other or unknown scope/risk | Codex `gpt-5.6-sol` | 2 |
| Large scope or high risk | Codex `gpt-6-astra` | 5 |

All three initially use Codex `gpt-5.6-sol` with extra-high (`xhigh`) reasoning
effort as reviewer. **Approve and start**
and **Fix directly** offer a profile override and a 0–5 review limit; leaving
the limit blank uses that preset's maximum. Approval freezes the selected
models and issue context. Editing presets affects future approvals only.
The implementation profile takes precedence over the implementation automation's
agent selector; other maintainer actions keep their existing selection policy.
Pre-upgrade jobs retain their original prompt/count policy.

**Refresh available models** asks the worker's logged-in Codex and Cursor CLI
accounts. Claude currently has no account model-list command; enter a model ID
or alias. Catalogs are hints, not entitlement guarantees. Unsupported models
fail visibly without substituting another model. Cursor encodes effort in its
model ID; leave its separate effort field at Model default.

The implementer commits a clean checkpoint and calls
`$PTC_OPERATION_WRAPPER review`. PtcManager captures the exact patch using the
publication verifier's Git safeguards, launches a separate reviewer, and stores
structured findings. Each completed assessment consumes a round, including assessments
after fixes; fixing findings does not itself consume one. A clean review ends
the loop early. Repeating the same request or reviewing unchanged evidence does
not spend another round. Code changes require another review. Failed attempts (including
reviewer timeouts) remain in the history but do not consume completed review budget.
Failures pause the job; there are no automatic retries. Continue with **0 — unused
budget only** when choosing **Retry review** to retry without increasing the budget.

**Configuration → Execution profiles** includes **Review timeout (minutes)**,
defaulting to 15 and configurable from 1 to 60. Approval freezes this value on the
job. Existing jobs without a saved timeout use 15 minutes. To change a paused
job's timeout, save the desired profile and select it when continuing; keeping
approved models also keeps the approved timeout. Each attempt expires after its
timeout plus 15 minutes for queueing and result handling. The review page shows
completed reviews, failed attempts, active attempts, and the job's timeout separately.

When reviews are exhausted or fail, **Delivery → Reviews** shows the preserved
branch and findings. The Delivery card shows a highlighted **Review findings and decide**
button when a decision is needed, and **View review progress** while review runs.
An active review appears under **In progress** with an **Under review** badge;
the internal review hold does not by itself mean the maintainer needs to act.
Paused decisions, stop reports, and real failures still appear under **Needs attention**. Add +1, +2, or +5 rounds (up to 100 in total), optionally
switch profiles, or take over manually. Continuation starts an agent in the
existing worktree with the frozen issue and latest findings. **Instructions for
continuation (optional)** accepts up to 4,000 characters of additional direction,
such as checking the whole change and its failure paths before editing. It is
available for both paused reviews and manual takeover. The instruction is saved
with the continuation decision, shown on the review page, and sent to the resumed
agent; it does not change review or publication permissions. Blank instructions
mean normal continuation and do not reuse the previous continuation's note.
Manual takeover and cancellation do not send the field to an agent. An idle retained
pane is replaced using an explicitly directed Herdr split; it does not reset
files or start a replacement job. Each continuation receives a fresh stop-report
identity, so an earlier agent’s failure cannot overwrite its successful result. Recovery checks the full retained identity before reserving capacity. An interrupted
identity check pauses after two minutes; stale cancellation cannot stop a newer
continuation. An unavailable or busy retained agent leaves
a visible pause for recovery. Paused and manual-takeover work releases implementation capacity once its
implementer is confirmed stopped. Live, idle, blocked, or unknown agents continue
to occupy capacity until their stopped state is observed. The worktree and review
history stay preserved. **Continue existing work** queues a continuation, which
reserves a slot through the same capacity gate as new implementations and repairs
before launching. Queue waiting has no launch timeout; the bounded launch window
starts only when a slot is reserved. An interrupted or uncertain launch keeps its
slot until reconciliation confirms the outcome. A failed workspace reopen before
an agent starts pauses the review and releases confirmed-stopped capacity. The
console shows “Review paused” and the specific Herdr error code. Continue retries
from the same checkout, using the parent repository to reopen its workspace. Manual takeover requests the retained pane to stop; confirm it has
stopped before editing. Cancellation requires a private reason and preserves
all work. Posting an explanation on GitHub is a separate, editable approval.

Review preparation and reviewer execution failures are separate durable attempts.
The review page preserves the stage, error, and exit status when available; replaying
an acknowledged request returns that attempt even if the working tree changes.
Admission records a preparation worker in the same transaction. Database
contention or an interrupted caller resumes that attempt without spending a
new assessment or needing another maintainer retry.
**Retry review** stops the retained implementer and assesses its committed work
without starting another implementer. A clean result queues a continuation to
publish that exact commit; findings pause for a decision. **Continue existing
work** instead starts an implementer to address the failure or change the code.
Unacknowledged partial failures that permit retry can also continue their retained
work, provided no newer job supersedes them. Unsafe stop reports retain their
existing restriction on restarting.
A failed broker publication check offers continuation from the review page; the
old publication remains blocked while the implementation is repaired.

Before review, the implementation prompt requires all repository validation,
including checks normally run by commit and pre-push hooks. Then it commits,
requests review, and publishes the reviewed commit. If a later check requires
edits, that new commit needs a new review. A green historical review remains
visible but does not approve later edits.

The reviewer gets an independent, coordinator-owned, read-only clone of the exact
commit, including its local callers and tests. Ownership is saved before cloning;
a background cleanup worker reclaims snapshots after interrupted reviews and
retries failed cleanup, with errors visible in review history. Patches up to 500 KB are inline;
larger patches are supplied as a complete local file under the same 50 MB bound
and SHA-256 digest as publication verification. Git snapshot commands have a
two-minute timeout and require GNU `timeout` (Homebrew coreutils supplies it on
macOS). Requirements stay in the GitHub issue and its links. Before review,
PtcManager uses its authenticated read-only GitHub client to capture the issue,
recent comments, and linked GitHub issues, pull requests and text documents within
the job's approved repository (up to nine sources total, with explicit text/comment
limits). Links cannot widen the token's repository scope; out-of-repository links
are identified as not fetched. Put essential cross-repository requirements in the
approved issue. Document links support encoded paths and branch names containing
slashes. Blob sizes are
checked before reading their text, and the resolved object is immutable. Private
document links require Contents read permission on that token. Missing GitHub
context pauses preparation rather than becoming a completed review. Repository
documents remain available in the local snapshot; other external sites are not
fetched. The reviewer reports missing essential context instead of assuming it.
Codex web search is disabled and its sandbox is read-only; Claude uses restricted
Read/Glob/Grep tools; Cursor uses read-only ask mode. Reviewers receive the fetched
text, never the coordinator's GitHub token.

Each job keeps its reviewer's own session across rounds, including maintainer
continuations. The coding agent and reviewer have separate sessions. Changing the
reviewer model, provider, or effort starts a fresh session with the last useful
review and handoff. A missing native session permits one fresh start within the
original timeout; other execution failures still pause. The review history shows
when this fallback was needed. Session IDs come from the CLI's structured metadata,
never from model-authored review text or a machine-wide “last session.” Codex
progress events are streamed and discarded after extracting bounded session
metadata, so verbose tool output cannot exhaust the transcript capture limit.
Diagnostics retain only a bounded tail; the deadline, exit-status check, and
separate bounded assessment file still apply.

The coding agent can pass a short plain-text note with
`$PTC_OPERATION_WRAPPER review --handoff-file /absolute/path/to/note.txt`.
The file can live outside the worktree and is optional, UTF-8, and limited to 20 KB.
No template is required: explain changes, validation, and responses to findings.
The review page keeps this note expanded across live refreshes until you close it.
The reviewer's summary serves as its return
handoff. These notes explain the work; they do not add requirements or approve it.
Resumed reviewers receive the current note rather than a replay of all reviews.
A restarted coding agent receives the last completed assessment and useful note;
a later timeout or preparation failure does not replace that assessment with null.
Copied handoffs have a UTF-8 byte limit and a visible shortening notice; full notes
and assessments remain in review history. Continuation prompts stay below the
Linux single-argument limit.
A cached review is reused only when its issue and fetched requirements evidence
also match. Every round still assesses the current exact commit; session memory does not extend
a previous green result to changed code.

The schema and helper contract version are frozen with the attempt. An incompatible
helper deployment fails explicitly and requires a new attempt.
Reviews run in a dedicated Oban queue with the configured timeout plus 15 minutes
for queueing and result handling. The helper caps combined stdout/stderr at 1 MB
and retains bounded diagnostics; it does not limit the CLI's database/WAL files.
Only validated structured results complete assessments; failed attempts do not
consume completed review budget. The deployed root-owned
`ptc-manager-worker-review` helper runs as the worker; the normal deployment
script installs it and its exact sudo rule. Browser demo mode never starts
these reviewers or continuations. Repository test commands and coding
conventions stay in `AGENTS.md`; managed review orchestration comes from the
PtcManager task prompt, so managed jobs do not need repository-specific review
counts, tools, or session instructions. This does not isolate hostile agents
that share the same worker account or direct GitHub credentials.

Agent-created PR discovery uses the publication retry budget (five attempts by
default), then preserves the job under Needs attention. An explicit retry resets
that budget; missing PRs cannot loop forever.

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
  checkouts, your own triage labels and write-only encrypted implementation-agent
  variables per repository, the **Integrations** section describing what GitHub
  synchronization, publication, private analysis, and the dispatcher currently
  reach, and direct links to each repository's prompt and automation settings.
  Repository variables are sourced from protected per-pane files after setup
  completes; they are never supplied to bootstrap or maintainer-action agents.

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

Issue preparation, daily updates, and repository investigation automations use
`generic_ephemeral` read-only source snapshots and skip the writable build
bootstrap. **Review issue** instead uses an `ephemeral_investigation` worktree:
PtcManager pins the same source evidence, creates a writable disposable
worktree at that exact commit, runs the checked-in bootstrap, and removes the
worktree and its temporary branch after the review. The reviewer may run tests
and create temporary reproduction tests, but must not implement, commit, push,
or open a pull request. Writable implementation jobs also run the full
repository setup. This repository's bootstrap maintains an optional cache
beneath `${XDG_CACHE_HOME:-$HOME/.cache}/ptc-manager/workspaces`, keyed by the
dependency lock, repository setup files, Mix environment, Elixir/OTP, OS, and
architecture. Before a planning snapshot or implementation worktree is
prepared, PtcManager fetches the remote default branch and pins its exact
commit without changing the persistent checkout's working tree. The cache key
is calculated inside the resulting worktree, so a changed lockfile or setup
file selects a new cache entry even when the persistent checkout remains on an
older local commit. A warm cache copies dependency sources, compiled dependency
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

On a paused job's **Reviews** page, **Override review and finish PR** lets a
maintainer accept the displayed reviewed commit with a short reason. The original
review findings or failure remain visible alongside the separate approval record.
Publication waits for worker capacity and still requires the normal validation
gates. This does not approve merging or later edits: a different commit, review
base, or diff needs its own review or approval. No additional review budget is
needed for an override. After manual takeover, you may make a fresh approval of
the displayed reviewed commit; an earlier approval or an old browser form is not
carried forward.

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
change, request independent reviews within the maximum frozen on the job, fix
findings, and commit without using GitHub credentials. PtcManager launches the
reviewer, stores its validated result, and checks that the reviewed head, base,
and patch digest match before allowing publication.
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

Label names are matched case-insensitively everywhere, as GitHub matches them —
in this configuration list, in the chips, in the parked-group check, in the
wrapper, and when synchronization recognizes the three `ptc:` workflow labels.
`PTC:ready` is refused as a triage label for the same reason `ptc:ready` is: it
would reach the same GitHub label, and the workflow labels must keep coming only
from synchronization.

#### Suggested follow-ups

The implementation prompt asks every pull-request description for a
`## Retrospective` section, and asks the agent to add the label `ptc:follow-up`
to its own pull request when that section lists untracked follow-up work.

That label has to exist in the repository already, like every other `ptc:`
label; `gh` fails against one that does not, and no pull request ever reaches
this group. Creating them is step 2 of
[onboarding a repository](#generic-automations-and-additional-repositories).

A labelled pull request appears in the **Suggested follow-ups** group, before
and after merge, with two buttons: **Run retrospective** queues a read-only
agent that proposes concrete follow-ups, and **Dismiss** removes the card
without touching GitHub. Each proposed follow-up then has its own **Add as GitHub issue** button;
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
- **Review issue**, which gives a configured Herdr agent a bootstrapped,
  disposable worktree in which it can run tests or create temporary regression
  tests, then asks it to challenge and improve issue readiness and apply the
  same canonical label rules as **Prepare issue**;
- **Apply decision**, shown after an issue action returns a schema-validated
  question with two to four plain-language choices. A maintainer can choose an
  option or enter a custom answer; a queued agent then records that decision on
  GitHub and normally moves the issue to `ptc:ready`. Choices are tied to the
  exact synchronized issue version, so an edit requires a fresh analysis;
- **Abandon**, on a Delivery board card whose job is stuck in a phase
  PtcManager owns — checking a committed branch, verifying it, or a blocked
  publication with no pull request yet. **Cancel agent** deliberately refuses
  those, because there is no agent to cancel; without this the card could repeat
  the same failure forever.
  An agent that committed nothing, for example, leaves `:no_commits` and the
  check can never pass. The card shows that reason in PtcManager's own words,
  takes two clicks to abandon, keeps the worktree for attention, and refuses
  while a verifier still holds a live claim, once a pull request exists, or
  while the agent's remote state is merely unknown — **Cancel agent** closes the
  pane in that case, which abandoning would not;
- **Cancel agent**, on the Delivery board's **In progress** and **Needs
  attention** cards and next to a running agent on Operations. It ends one
  implementation agent the maintainer no longer wants to wait for: the job ends
  as cancelled, its run ends, its Herdr pane is closed, and its partial worktree
  is kept for attention rather than discarded. It takes two clicks and refuses
  the deterministic phases that follow an agent — reconciliation, verification,
  and publication — because PtcManager, not an agent, owns those. If the pane
  cannot be closed, the console says so and the job stays cancelled. Managed
  jobs retry the stop durably until it is confirmed; their worktree can then
  be explicitly discarded from retained worktrees;
- **Approve and merge**, which has the highest heavy-work queue priority.
  PtcManager prevents new writing agents from starting in that repository while
  the action is queued, running, or awaiting GitHub confirmation. The Herdr
  agent—not PtcManager—repairs and pushes the branch, watches required CI,
  resolves any newly introduced conflict, and merges that exact PR with the
  authenticated `gh` CLI. PtcManager verifies the resulting GitHub state and
  retains the session until the PR is merged or closed. Imported PRs can still
  be reviewed and repaired, but do not receive a generated implementation
  retrospective because PtcManager did not start their agent.

### When an agent cannot finish

Nothing watches a managed pane. An agent that asks a question there is asking
nobody, and PtcManager never parses terminal output, so the question is
invisible by design. Every agent is therefore told, in the runtime context it
cannot edit away, that its session is unattended and that if it cannot start —
or discovers part-way that it cannot continue — it must write a **stop report**
and exit rather than wait.

The report is a small JSON file validated against
`priv/codex/agent_stop_report.schema.json`: a `reason_code`, one plain sentence,
a detail paragraph, optionally the exact `prerequisite` that is missing, and
whether anything was committed. It is data. It records a reason and never causes
a state transition by itself. Once you acknowledge the report or continue the
retained work, its explanation and recovery buttons disappear from the live card.
The report remains stored; a later stop produces a new actionable report.

When one arrives, the attempt ends the way every unfinished attempt does: the
job ends, its run ends, and the partial worktree is kept for attention. The
heavy slot is released immediately, because an agent waiting on a person must
not hold capacity other work needs. The card stays in the Delivery board's
**Needs attention** lane, showing the agent's own explanation instead of a
technical branch error, until you answer it with one of three buttons:

- **Try again** queues a fresh attempt on the same approval, with the same
  frozen prompt and review count. The decision to implement the issue has not
  changed; only the environment did;
- **Ask on the issue** queues **Report implementation blocker** with the stop
  report as evidence, so the question is written onto GitHub and the issue comes
  back through Planning's **Needs your decision** group and its existing
  decision form;
- **Stop** sets the card aside. The worktree stays on Operations until you
  discard it.

`reason_code` decides which of those PtcManager offers: a missing prerequisite
or broken environment defaults to **Try again**, an ambiguous requirement to
**Ask on the issue**, and an agent that judged something **unsafe** is offered
neither. That last one is a refusal, not a default — the buttons are absent and
the server refuses the action, because restarting the work and asking an agent
to reword it are both ways of proceeding anyway. Only **Stop** remains, and you
read the evidence.

The report is written by a model, so it is treated as untrusted throughout.
Recording one takes the same fencing token and result-attempt token as any other
result write, so a stale verifier cannot overwrite a newer result or an
already-published job. Reading one is bounded and deadlined, so an oversized or
endless file cannot exhaust or stall the coordinator. **Ask on the issue**
queues a dedicated **Report implementation blocker** action rather than ordinary
issue preparation. That distinction matters: preparation's prompt tells the
agent it may mark the issue ready or close it, and a check on the returned
result would arrive after the agent had already used its `gh` session. The
blocker action's own prompt permits only a comment and a blocked or
needs-decision label, and the same set is persisted on the action and checked
again on the result. The stop text reaches it as fenced JSON with its delimiter
characters stripped, framed as a claim to verify.

One limit is worth stating plainly: the report's file name carries a random
per-attempt token, but that is defence in depth and not a capability. Every
managed agent runs as the same worker identity and can list the shared results
directory, so a hostile agent can still find and forge another job's report.
That is the same deferred technical separation described above for the
authenticated `gh` session, and per-agent OS identities are the only thing that
would close it. What a forged report can do is bounded: end one attempt whose
verifier currently holds it, preserve its worktree, and show text to a
maintainer. It cannot approve, publish, merge, or write to GitHub.

An agent that crashes or wedges writes no report, so the contract does not
replace the timeouts. A run that sits `blocked` or `idle` past the grace period
is reported as **Waiting for a person** on both the Delivery board and
Operations, and an implementation job that stays idle past its deadline is
released with its worktree preserved.

Maintainer actions use two deliberately separate resource pools. Heavy delivery
work is ordered **merge → repair → new implementation**, with oldest work first
inside each priority. Test-capable issue reviews share that heavy pool and yield
to queued merge or repair work. A merge action still serializes repository
writers, so agents do not race to rewrite or merge branches. Light issue
preparation, decision, investigation, and summary work can continue
independently. The two limits are persisted and editable under **Configuration
→ Concurrent agents**;
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
remote default-branch ref and exact Git commit SHA. The action details show the
source ref and SHA. Read-only planning agents run from a separate
coordinator-owned Git clone whose complete tree is made read-only before the
worker can see it. An issue reviewer receives a second, writable worktree at
the same SHA after the repository bootstrap succeeds. Concurrent build agents
therefore cannot alter the pinned evidence. Both temporary trees are removed
when the agent exits, while
its provenance remains in the action record. A durable reaper retries cleanup
after an interrupted or expired run. Worktree reconciliation continues this
cleanup while new agent actions are disabled or the system is draining. Codex
review agents trust both the parent checkout and their disposable worktree so
startup does not wait for an interactive trust decision. This makes a review's issue and code
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

### Automatically implementing ready issues

Under **Configuration**, each repository has **Automatically implement ready
issues**, off by default. Enable it for `andreasronge/ptc_manager` to authorize
implementation without a separate approval click for every issue. Other
repositories remain off unless explicitly enabled. Anyone or any preparation
agent with permission to apply `ptc:ready` can make an issue eligible under this
policy. Merge and deployment approval rules are unchanged.

After a successful GitHub synchronization, deterministic code admits open,
unassigned `ptc:ready` issues with resolved dependencies and no conflicting
workflow labels. Queued, running, or synchronizing issue actions defer admission
until their assessment has been stored and the action finishes; the next
successful synchronization then selects the profile. Existing backlog issues are included; a single-issue refresh
only considers that issue. No selector model or new coding workflow is involved.
The existing execution profile selection uses a current assessment's scope and
risk; an absent or stale assessment uses the existing `standard` fallback.
Models, review budgets, publication, and worker capacity follow the existing
implementation pipeline.

Any previous implementation job (including a manual, failed, or cancelled job)
or a known linked pull request prevents automatic admission. Open pull requests
are refreshed before admission; unavailable PR discovery defers automatic work. Retrying requires
an explicit manual action; removing/reapplying the label, editing the issue, or
disabling/re-enabling the setting does not reset its history. Admission and job
creation share one write transaction. At most five automatic jobs per repository
are admitted per UTC day, including failed and cancelled jobs; subsequent syncs
pick up the remaining backlog after the budget resets. Existing capacity limits
bound how many run concurrently.

Dispatch re-reads GitHub and checks the frozen issue version, readiness,
assignment, dependencies, and repository setting. Disabling automatic
implementation prevents queued automatic jobs from starting and leaves running
jobs alone. Policy changes and automatic approvals are recorded in the audit
log. This setting grants no sudo access: machine changes still go through an
approved deployment.

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
marking profiles no online worker currently reports as offline. Every
automation starts the kind its selector resolves to with that profile's
arguments, the implementation job and pull-request repairs included; a job
records the kind when it is leased, and a job whose required kind has no
enabled profile is cancelled with `no_healthy_agent_profile` instead of
starting a different agent. `PTC_IMPLEMENTATION_AGENT_KIND` is only the kind
tried first when an automation accepts any capable agent. Built-in
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
2. create the four `ptc:` labels on GitHub. PtcManager never creates a label, and
   `gh` fails against one that does not exist, so a missing label makes the agent
   step that writes it fail:

   ```sh
   repo='<owner>/<name>'
   gh label create 'ptc:ready' --repo "$repo" --color 0E8A16 \
     --description 'Maintainer decision is resolved and the issue is ready for implementation'
   gh label create 'ptc:blocked' --repo "$repo" --color B60205 \
     --description 'Implementation is blocked by an unresolved dependency or external condition'
   gh label create 'ptc:needs-decision' --repo "$repo" --color D93F0B \
     --description 'A specific maintainer decision is required before implementation'
   gh label create 'ptc:follow-up' --repo "$repo" --color 5319E7 \
     --description 'The pull-request retrospective lists untracked follow-up work'
   ```

   The first three are what **Prepare issue** and **Review issue** leave on an
   issue; the fourth is how an implementation agent marks its own pull request as
   having left work behind. Any triage label configured under **Your triage
   labels** has to exist on GitHub for the same reason. Configuration health
   names whichever are still missing, so this can be done after registering the
   repository and checked before enabling it;
3. use **Configuration → Add another GitHub repository** to register its exact
   GitHub `owner/name`; PtcManager verifies access with the configured read-only
   GitHub credentials, derives `/srv/<repository-name>` as the checkout path,
   and creates the repository disabled;
4. press **Prepare checkouts** on Configuration, or deploy. Either clones any
   configured checkout that does not exist yet, gives it to the worker identity,
   and regenerates the drop-in that grants every configured checkout to both
   services; the button does it without building a release;
5. verify checkout, GitHub, and gate health, then review or copy the desired
   definitions on **Automations**;
6. enable the repository on **Configuration**, then enable only the definitions
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
the deployment-critical suite across three isolated SQLite partitions. Each
partition gets its own temporary directory, removed with the suite's staging
files, so fixture names cannot collide across partitions or repeated runs. The
test phase has a hard wall-clock budget of less than 60 seconds; a failed,
hung, or slower run fails the gate. Real filesystem, Git-worktree, cache,
process-timeout, and disposable-migration lifecycle tests carry the `nightly`
tag. They remain part of a normal unfiltered `mix test` and run every night in
GitHub Actions through `.github/workflows/nightly.yml`; the workflow can also
be started manually. Set `PTC_TEST_BUDGET_SECONDS` or `PTC_TEST_PARTITIONS`
only for local diagnosis—the checked-in defaults are the publication and
deployment contract. CI runs the three partitions on separate runners using
`PTC_TEST_PARTITION_ONLY`; every matrix job is required and retains the same
60-second budget. Local precommit runs all three partitions together.

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
agents make deployment stop safely, and a retained agent session keeps
`ptc_manager-herdr` running even when it is idle. When no run and no agent is
retained there is nothing to lose, so the deployment restarts it, which is also
the moment a pinned Herdr takes effect. Immediately before the release swap, the task stops the
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
sudo install -o root -g root -m 0755 priv/worktree_cleanup.py /usr/local/bin/ptc-manager-worker-worktree-cleanup
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-bootstrap /usr/local/bin/ptc-manager-worker-bootstrap
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-claude-trust /usr/local/bin/ptc-manager-worker-claude-trust
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-codex-arm /usr/local/bin/ptc-manager-worker-codex-arm
sudo install -o root -g root -m 0755 deploy/ptc-manager-worker-gh-label /usr/local/bin/ptc-manager-worker-gh-label
sudo install -o root -g root -m 0755 deploy/ptc-operation /usr/local/bin/ptc-operation
sudo install -o root -g root -m 0755 deploy/ptc-manager-operation-recover /usr/local/bin/ptc-manager-operation-recover
sudo install -o root -g root -m 0755 deploy/ptc-manager-herdr-launch /usr/local/bin/ptc-manager-herdr-launch
sudo install -o root -g root -m 0755 deploy/ptc-manager-health-snapshot /usr/local/bin/ptc-manager-health-snapshot
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

`ptc-manager-health-snapshot` runs as root, on demand or from a timer, and
writes `/var/lib/ptc_manager-output/ptc-health.json`. It exports capacity settings,
record IDs, states and timings, plus counts from at most 10,000 service journal
lines. Live record lists are limited to 500 rows; a list at that limit may be
incomplete. The log counts include a limit indicator. Raw journal messages,
agent status text, labels and names stay private because they can contain secrets
or agent-controlled instructions.

The final file is readable by `ptc-manager-output`; staging files are private
and exclusively created. Atomic replacement never follows an output symlink.
Keep the output directory owned by the coordinator with its documented sticky
bit, and its ancestors unwritable by agents. Environment overrides are for the trusted root
invoker only. Database or journal read failures preserve the previous snapshot;
consumers must check `captured_at` and treat a stale snapshot as unavailable,
never as healthy. Snapshot data cannot authorize an action.

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

Every program the deployment installs on the machine is pinned in
`deploy/toolchain-versions`, and that file is the only place one of their
versions is written. The asset build tools, esbuild and Tailwind, are the
exception: `config/config.exs` pins them the way Phoenix does and the release
build installs them, so they match a commit too, just not in this file. The
deployment installs
exactly what it names into a root-owned `/opt/ptc-manager-<program>-<version>`
directory, checks the version it actually got, and links the entry point onto
the worker's service `PATH`. Codex and Claude Code are installed from their npm
packages with the pinned Node, and Codex is linked to the native binary its
platform package carries rather than to the Node shim in front of it. Node, npm,
corepack, pnpm, Erlang, and Elixir come through mise, and the worker's own mise
is itself a pinned download rather than a copy of whatever the deploying user
has. An agent therefore cannot rewrite the CLI it runs, and updating any of them
is a change to `deploy/toolchain-versions` and a deployment, never a command run
on the host, so the running program always matches a commit.

A version a program reports is that program's own claim, so every download that
does not come from npm carries a pinned sha256 that is checked before anything
is unpacked or installed: the Cursor CLI archive, the Herdr release asset named
by `https://herdr.dev/latest.json`, and the mise release binary. Herdr and mise
are single files, so the deployment re-checks the digest of what stands at the
pinned path on every run rather than trusting the run that installed it. The
pre-publication gate pins its build tools the same way: Hex by version, and
Rebar by the sha512 of the script Hex's CDN serves, hashed after installation
because `mix local.rebar` accepts a mismatched `--sha512` once `--force` is
given.

Herdr is the one program that does not take effect at once. A client whose
protocol does not match the running server breaks the coordinator's view of
every agent, so the deployment installs the pinned build but moves
`/usr/local/bin/herdr` only where it already restarts `ptc_manager-herdr`
because nothing is retained. Until that restart happens the pinned build sits
installed beside the running one. The interactive client in the `agent` account
belongs to the person rather than to the deployment, which reports when it has
drifted instead of replacing it.

The Deployments page reads link targets and never runs the programs it reports
on. To ask the machine what its agent CLIs actually are, run

```sh
mix ptc.agents
mix ptc.agents --target another-host
```

which prints, for each agent CLI, the version this release pins beside the
version the program reports when `ptc-manager-worker` runs it, and whether that
identity is still signed in — a linked binary matching the manifest can be
signed out, and a signed-out agent stalls on its login prompt rather than
failing. It also prints the live agent and live run counts that decide whether
the next deployment may move Herdr's link, and the repository variables an
implementation agent is given, by name. The report is read-only and pipes its
probe over SSH rather than installing it, so it needs no deployment of its own
and always runs the revision checked out locally.

PtcManager refuses to start a pane with an agent kind whose worker identity is
signed out, rather than letting the CLI print its login prompt and wait for
nobody until the run times out. The check runs immediately before the pane, in
the same place the workspace trust and the Codex policy are recorded, so an
implementation job and a maintainer action refuse alike; the wrapper answers in
its exit status and its output is never parsed. Sign the identity back in with
the commands above, as `ptc-manager-worker`. The Herdr server also runs its
panes with `DISABLE_AUTOUPDATER=1`, because Claude Code updates itself by
default and the root-owned tree it is installed into exists precisely so an
agent cannot rewrite the CLI it runs: the attempt can only fail, and versions
come from the manifest.

What pinning ends is drift, not the deploying account. A deployment runs as the
`agent` user with passwordless `sudo`, so everything on this machine is
downstream of that account: the toolchain trees mise installed before the
deployment used a pinned mise of its own keep whatever provenance that account
gave them, and they are recreated only when their pinned version changes. The
pins say which version runs and prove each download against a digest; they do
not make the machine safe from the person deploying to it.

The Deployments page reports, for each program, the version this release pins
beside the version `/usr/local/bin` links, so something installed by hand is
visible without logging in to the machine. It reads link targets rather than
running any of these programs, and it never changes them: the fix for drift is a
commit and a deployment, which the same page offers.

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
`PTC_WORKTREE_ROOT` contains implementation-job and disposable investigation
worktrees. It and every ancestor must be
non-writable by group and other identities; the deployment enforces mode
`2750` on the worker-owned root and PtcManager refuses new work when that
invariant is broken. This keeps private build artifacts safe while still
allowing the coordinator read-only traversal. For retained implementation and
pull-request worktrees, PtcManager removes a worktree through Herdr only after a
credential-free Git check proves a non-terminal checkout is clean and its exact
head is on the PR branch. Dirty, missing, or unpushed non-terminal work is
retained for attention. A merged or closed PR is the explicit exception: its
abandoned checkout is removed with Herdr's force option because GitHub has
already made the work terminal. Disposable investigation worktrees are also
force-removed when their action ends; any temporary reproduction tests or
other review changes are intentionally discarded. Cleanup is bound to the run's
fencing token: a late attempt can remove only its own workspace, even if the
action has already retried. The database record is the single cleanup authority;
there is no fallback deletion outside its cleanup claim. An old run can still be
cleaned after the action's source snapshot changes or is cleared. A retained worktree
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
service sandbox; planning snapshots remain read-only to agents. Before Herdr
opens a coordinator-owned snapshot, the adapter grants the worker Git trust for
that exact path and revokes it during cleanup, including when opening fails.
The coordinator database directory is `0700`.
When Herdr has forgotten a retained worktree, discard uses the root-owned
`ptc-manager-worker-worktree-cleanup` helper as the worker account. The helper
pins the validated root and removes only its direct child without following
symlinks; it never falls back to deletion as the coordinator.

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
timeout must not cut that longer startup wait short. Default-branch refreshes
use the worker Git identity and fail closed after `PTC_SOURCE_REFRESH_TIMEOUT_MS`
(60 seconds by default), so a stalled remote cannot hold a dispatch poller
indefinitely. Every agent starts with
the arguments of its profile in `PTC_AGENT_PROFILES_JSON`; without that
setting the only profile is `PTC_IMPLEMENTATION_AGENT_KIND` started with
`PTC_IMPLEMENTATION_AGENT_ARGS`, which default to Codex and its current
unattended CLI flag `--dangerously-bypass-approvals-and-sandbox`. Override the
arguments only when the installed agent CLI requires a different supported
mode.

A profile also names the model that kind runs, as `"model"` alongside its
`"args"`. Left unset each kind takes its default from
`PtcManager.AgentProfiles` — Codex `gpt-5.6-sol`, Claude `opus`, Cursor
`cursor-grok-4.6-high` — because an agent given no model reaches for the
strongest one its account offers, which is more than routine maintenance work
needs. The model is passed as `--model` at startup, and for Codex it is also
recorded in the worker's `config.toml`, since Herdr restores a pane with
`codex resume` and no arguments. A profile that already passes `--model` in
its own arguments keeps that choice. After
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

Publication writes acquire SQLite's write lock before reading their transition
state. They can wait for the connection's busy timeout (currently the adapter's
2-second default), including button-triggered retries. Busy repair postflight and
gate-recording writes remain retryable; contention is not evidence of a failed
repair or gate. No GitHub or process calls run inside publication transactions.

Forgotten managed worktrees can be deleted locally only at normalized, absolute,
direct-child paths of the validated managed root, with no symlink at the child.
Deletion uses Python's descriptor-based `shutil.rmtree` and refuses platforms
without symlink-attack protection.

A merged repair must still match its frozen preflight head, verified retained
commit range, or recorded intended head for a fresh repair, even when status
reconciliation recorded the merge first. This confirms the authorized outcome;
it does not attribute which GitHub actor performed the merge.

Implementation dispatch refreshes the repository source before its final GitHub
issue read, so a slow fetch cannot hide an issue change from approval validation.
The lease clock starts after those reads.

The Phoenix endpoint listens only on `127.0.0.1:4000`. Expose it privately over
your tailnet with Tailscale Serve:

```sh
sudo tailscale serve --bg http://127.0.0.1:4000
tailscale serve status
```

Open the HTTPS `*.ts.net` address reported by Tailscale on the Mac or iPhone.
Do not use Tailscale Funnel for this private console.

### Recovering implementation startup failures

A safe dispatch failure stays on Delivery under **Needs attention**, with the
startup error and **Try again** / **Set aside** actions. No agent needs to start
for this card to appear. Try again preserves the original approval, profile,
prompt and review budget; closed issues and issues with newer attempts cannot
be retried. Retries are explicit, never an automatic failure loop. Upgrading
also restores missing cards for unresolved historical dispatch failures.

Git verification defaults to a 512 MiB virtual-address-space limit, configurable
with `PTC_GIT_MEMORY_LIMIT_BYTES`. Git maps packfiles into virtual memory, so a
`Cannot allocate memory` error can mean this limit is too small even when the
machine has free RAM. Failed commands retain bounded diagnostic text; successful
stderr remains excluded from parsed Git output and patch hashes.

### Delivery reports and local report testing

Every managed job on Delivery has a **Delivery report** link (`/jobs/:id/report`).
The report has Merge summary, Time & resources, Logbook, and Data coverage tabs.
It reads persisted evidence without calling GitHub or a model and without approving
any action. It loads a snapshot on navigation or **Refresh report**; notifications
do not replace expanded evidence while it is being read. Other attempts for the
same issue remain accessible, with metrics scoped to the selected attempt.

The merge view keeps coding handoffs separate from reviewer findings and shows
exact reviewed and validated commits. It does not infer that a finding was fixed
merely because a later review omitted it. Model history describes requested
settings, including continuation changes and each reviewer attempt. GitHub issue
comment counts are captured during sync; the last known count and its observation
time are frozen at implementation submission (not presented as a fresh GitHub read);
PR discussion and inline-comment counts are separate observations.

Lifecycle snapshots are captured atomically by SQLite triggers, including fenced
bulk updates. The report derives phase changes and entering/leaving Ready to merge
from those snapshots using the same lane rules as the board. Ready observations are tied to the remote PR head.
Historical states cannot be reconstructed reliably: old gaps and open intervals
remain unmeasured. An interval labelled Working includes command/tool waits and
must not be interpreted as CPU time. Accumulated command durations can overlap
one another and the job timeline. A `verify` invocation may include build, test,
and lint, so the report never invents constituent invocation counts.

On Linux, the managed operation wrapper also reports optional cgroup CPU time,
throttling, memory-pressure/OOM counters, disk bytes, CPU affinity and ancestor
CPU/memory limits before cleaning up the operation cgroup. Average cores used
means CPU-seconds divided by wall-seconds; allowed CPUs and shared ancestor limits
are not actual usage or guaranteed dedicated capacity. Missing counters remain
unknown and telemetry collection failure does not fail a command. Existing peak
memory and worktree/setup timing continue to be used. Repository setup subphases
appear only when the repository emits the existing setup metrics.

Successful Codex reviews capture structured per-turn usage from that invocation,
including cached input as a subset of input. Resuming a session does not add its
prior cumulative usage again. Failed attempts, other providers, and interactive
coding-agent usage are currently unmeasured; the report shows coverage and a
recorded subtotal, never an estimated bill. Herdr metadata `tokens` are display
labels, not usage accounting. Slow compilation files, per-test profiling and
resource time-series graphs need repository/provider instrumentation and are
explicitly listed as unavailable, rather than derived from terminal prose.

To test locally, use the isolated demo commands under **Isolated browser
checkpoint** above. Demo issue **#1318** now has a Ready-to-merge report with
worktree/cache phases, a failed assessment, a changed reviewer model, review
handoffs, command outcomes, partial telemetry, and token-usage coverage. The
existing active/older jobs demonstrate missing data. Follow the issue's Delivery
report link rather than relying on a database ID. All data is synthetic and the
demo remains unable to dispatch work or write to GitHub.

Offline wrapper contracts can also be run directly:

```sh
python3 test/review_worker_contract.py
python3 test/delivery_metrics_contract.py
```

### Claude model discovery

On Configuration → Execution profiles, **Refresh available models** queries the
worker CLI. Claude uses the same initialization response that supplies the Agent
SDK model list; it sends no user prompt and starts no model turn. Discovery runs
in a temporary directory with tools, settings sources and MCP servers disabled,
with a 30-second deadline and bounded output. It needs no additional SDK package.
The returned IDs can be aliases (including `opus[1m]`); they are not a guarantee
of access when an agent launches. A failed or empty catalog shows manual-entry
guidance instead of an empty Available model IDs list. Saved profiles are unchanged.
This requires deploying the updated worker-review helper through the normal deployment.
