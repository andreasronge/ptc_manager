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
- an **Approve and start** workflow backed by SQLite transactions;
- one active implementation job per issue, enforced by the database;
- a live agent-activity panel with worker, role, task, start time, elapsed time,
  heartbeat, and Herdr identifiers;
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
- a configurable test command and prompt-only Codex review-skill pass count;
- exact-SHA branch push and draft-PR creation through a GitHub App broker;
- worker-advertised implementation capacity instead of a hard-coded worktree count;
- durable worktree allocation, safe reclamation, and terminal cleanup;
- canonical PR status and GitHub link in the dashboard.
- a generic durable agent-action queue with **Prepare issue**, **Review issue**,
  **PR retrospective**, and **Prepare merge decision** buttons;
- canonical display of the mutually exclusive `ptc:ready`, `ptc:blocked`, and
  `ptc:needs-decision` GitHub labels;
- agent-action attempts, results, and elapsed time in the shared activity view.
- private, phone-friendly PR summaries fenced by GitHub head and base SHAs;
- an **Approve for merge** decision bound to the exact analyzed PR version;
- explicit stale-approval display when the observed head, base, or diff changes.

Dispatch, maintainer actions, and publishing are disabled by default. The
implementation prompt forbids GitHub writes unless the explicit agent-publication
trial mode is enabled. In this initial version the worker
identity also hosts explicitly queued maintainer actions and therefore has an
authenticated `gh` session; technical separation is deferred. The broker can
publish only the fenced, verified job branch and one PR; it does **not** merge,
close issues, edit issue text, or trust labels as commands. See
[PLAN.md](PLAN.md).

## Run locally

Requirements: Elixir, Erlang/OTP, SQLite, and a C compiler toolchain.

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000> and sign in with `ptc-manager-dev`.

To choose a different local password:

```sh
PTC_MANAGER_PASSWORD='choose-a-long-password' mix phx.server
```

To use the real read-only adapters locally:

```sh
PTC_REPOSITORY_PATH=/absolute/path/to/ptc_runner \
PTC_GITHUB_SYNC_INTERVAL_MS=300000 \
PTC_HERDR_SESSION=default \
PTC_HERDR_SYNC_INTERVAL_MS=10000 \
mix phx.server
```

For a public repository, manual GitHub synchronization works without a token.
For a private repository or higher rate limits, set `GITHUB_READ_TOKEN` to a
fine-grained token with repository metadata, Issues read, and Pull Requests read
access. PtcManager uses it only through its GET-only GitHub client.

Automatic draft-PR publishing is a separate, off-by-default capability. Create
a GitHub App installed only on the managed repository with repository
**Contents: Read and write** and **Pull requests: Read and write** permissions.
Store its private key outside the repository, readable only by the coordinator.
Configure the App ID, installation ID, and PEM path, then set
`PTC_PUBLICATION_ENABLED=true`.

In broker mode, the generated task tells the implementation agent to run the
configured tests, invoke the `codex-review` skill the configured number of
times, fix findings, and commit without using GitHub credentials. This review loop is agent-owned
prompt policy: PtcManager does not launch reviewers or store review evidence.
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

Private Codex investigation is off by default. Once Codex is authenticated on
the machine and the configured repository path exists, enable it explicitly:

```sh
PTC_CODEX_MANAGER_ENABLED=true \
PTC_REPOSITORY_PATH=/absolute/path/to/ptc_runner \
mix phx.server
```

The adapter invokes `codex exec` ephemerally, ignores user tool configuration,
uses a read-only sandbox, and requires schema-constrained output. Its result is
stored only as a private PtcManager proposal. The child process receives a
small allowlist of environment variables; application passwords, signing keys,
database settings, and GitHub tokens are removed.

Maintainer actions are separate from private read-only investigation. Pressing
an action button stores that prompt in the durable queue and authorizes one
agent to use the configured checkout and authenticated `gh` CLI. The initial
catalog contains:

- **Prepare issue**, which rewrites or closes the issue and leaves exactly one
  of `ptc:ready`, `ptc:blocked`, or `ptc:needs-decision` on an open issue;
- **Review issue**, which uses up to three fresh independent `codex-review`
  consultations to challenge and improve the issue, stopping early after a
  clean pass and applying the same canonical label rules as **Prepare issue**;
- **PR retrospective**, shown after a PR finishes, which may create concrete,
  non-duplicate follow-up issues. New follow-ups intentionally start without a
  managed `ptc:*` label;
- **Prepare merge decision**, shown for an open PR, which returns a private
  simplified summary and readiness outcome. The maintainer can approve only a
  merge-ready analysis whose head SHA, reviewed base SHA, base target, and
  verified diff still match. This increment records approval but does not merge.

Prepare merge decision is instructed to be read-only, but it currently shares
the unrestricted authenticated maintainer-action runner. The result is fenced
before and after execution, which prevents a changed PR from being approved,
but it does not technically prevent other repository or GitHub mutations. A
GET-only credential and filesystem-read-only runner remain explicitly deferred.

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

## Verify

```sh
mix precommit
```

This formats the project, compiles with warnings treated as errors, and runs
the test suite.

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

The target defaults to the `herdr-box` SSH host from the local SSH config. Use
`mix ptc.deploy --target another-host` to select a different SSH alias, or
`mix ptc.deploy --dry-run` to show the resolved commit and release identifier
without running checks or changing either machine.

The task runs `mix precommit`, uploads a Git archive rather than uncommitted
files, and builds the production release on the server with its mise-managed
Elixir, Erlang, and Node toolchain. Before replacing `/opt/ptc_manager`, it
checks both managed runs and the manual and worker Herdr sessions. Non-idle
agents make deployment stop safely; idle Herdr sessions continue running and
are not restarted. Immediately before the release swap, the task stops the
coordinator and checks the database again so no new managed work can race the
deployment. Queued work resumes after startup.

The task discovers the coordinator's active systemd environment files and
checks the configured manual Herdr session. If the optional
`ptc_manager-herdr` worker service is running, its live session is checked too;
observation-only installations do not require that worker service.

The task reads the actual `DATABASE_PATH` and `PORT` from the running systemd
service, creates a consistent SQLite backup, and replaces `/opt/ptc_manager`.
Starting the new release applies all pending Ecto migrations before the web
endpoint starts. The task then checks the local HTTP endpoint and reports both
the release and database backup paths. If the new service does not become
healthy, it restores both backups automatically and retains the failed
artifacts for investigation. Successful deployments retain the three newest
release/database backup pairs and prune older successful backups.

## Hetzner systemd and Tailscale

Build the release, copy `_build/prod/rel/ptc_manager` to `/opt/ptc_manager`, and
create the dedicated service account and writable database directory:

```sh
sudo groupadd --system ptc-manager
sudo groupadd --system ptc-manager-codex
sudo groupadd --system ptc-manager-output
sudo groupadd --system ptc-manager-worker
sudo groupadd --system ptc-manager-repo
sudo groupadd --system ptc-manager-publish
sudo useradd --system --home /var/lib/ptc_manager --gid ptc-manager --groups ptc-manager-output,ptc-manager-repo,ptc-manager-publish --shell /usr/sbin/nologin ptc-manager
sudo useradd --system --home /var/lib/ptc_manager-codex --gid ptc-manager-codex --groups ptc-manager-output,ptc-manager-repo --shell /usr/sbin/nologin ptc-manager-codex
sudo useradd --system --home /var/lib/ptc_manager-worker --gid ptc-manager-worker --groups ptc-manager-repo,ptc-manager-output --shell /usr/sbin/nologin ptc-manager-worker
sudo useradd --system --home /var/lib/ptc_manager-verifier --gid ptc-manager-repo --groups ptc-manager-publish --shell /usr/sbin/nologin ptc-manager-verifier
sudo install -d -o ptc-manager -g ptc-manager -m 0700 /var/lib/ptc_manager
sudo install -d -o ptc-manager -g ptc-manager-output -m 2770 /var/lib/ptc_manager-output
sudo install -d -o ptc-manager-codex -g ptc-manager-codex -m 0700 /var/lib/ptc_manager-codex
sudo install -d -o ptc-manager-worker -g ptc-manager-worker -m 0700 /var/lib/ptc_manager-worker
sudo install -d -o ptc-manager-verifier -g ptc-manager-repo -m 0700 /var/lib/ptc_manager-verifier
sudo install -d -o ptc-manager -g ptc-manager-publish -m 2750 /var/lib/ptc_manager-publish
sudo install -d -o ptc-manager-worker -g ptc-manager-repo -m 2770 /srv/ptc_manager-worktrees
sudo chown -R ptc-manager-worker:ptc-manager-repo /srv/ptc_runner
sudo chmod -R g+rX,o-rwx /srv/ptc_runner
sudo find /srv/ptc_runner -type d -exec chmod g+s {} +
sudo install -d -o root -g root -m 0755 /etc/ptc_manager
sudo install -o root -g root -m 0644 deploy/ptc_manager.service /etc/systemd/system/ptc_manager.service
sudo install -o root -g root -m 0644 deploy/ptc_manager-herdr.service /etc/systemd/system/ptc_manager-herdr.service
sudo install -o root -g root -m 0600 deploy/ptc_manager.env.example /etc/ptc_manager/ptc_manager.env
# After downloading the GitHub App PEM to a safe temporary location:
sudo install -o root -g ptc-manager -m 0640 /safe/path/github-app.pem /etc/ptc_manager/github-app.pem
sudo install -o root -g root -m 0600 deploy/ptc_manager-herdr.env.example /etc/ptc_manager/herdr.env
sudo install -o root -g root -m 0755 deploy/ptc_manager-codex-exec /usr/local/bin/ptc-manager-codex-exec
sudo install -o root -g root -m 0440 deploy/ptc_manager-codex.sudoers /etc/sudoers.d/ptc_manager-codex
sudo visudo -cf /etc/sudoers.d/ptc_manager-codex
```

Edit `/etc/ptc_manager/ptc_manager.env`, replace every placeholder, verify the
binary and checkout paths, then start the release:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ptc_manager-herdr ptc_manager
sudo systemctl status ptc_manager
```

The coordinator, implementation worker, private manager, and Git verifier run
as four different OS identities. Herdr, implementation agents, and the initial
maintainer-action runner use `ptc-manager-worker`; that account has the
authenticated `gh` session needed by explicitly queued maintainer actions and
the optional agent-publication trial. Outside that explicit mode, the
implementation prompt instructs coding agents not to use it. A later
credential broker can enforce that separation technically. Private read-only manager investigations run as
`ptc-manager-codex`. Bounded branch verification runs as
`ptc-manager-verifier` with an empty environment and no credentials. None of
these accounts can read the root-only coordinator environment or inspect its
process. Authenticate the two agent accounts:

```sh
sudo -u ptc-manager-codex -H codex login
sudo -u ptc-manager-worker -H codex login
sudo -u ptc-manager-worker -H gh auth login
```

The checkout at `PTC_REPOSITORY_PATH` is owned and writable only by the worker.
The `ptc-manager-repo` group gives the coordinator, manager, and verifier
read/execute access without filesystem write access. The worker-owned
`PTC_WORKTREE_ROOT` contains only job worktrees. PtcManager removes a worktree
through Herdr only after the PR branch matches its exact head and a
credential-free Git check proves the checkout is clean. Dirty, missing, or
unpushed work is retained for attention.
The separate `ptc-manager-publish` group lets only the coordinator and verifier
exchange a bounded Git bundle; the worker cannot access publication staging.
The coordinator and private manager share only the setgid
`ptc-manager-output` directory at `PTC_CODEX_OUTPUT_DIR`; the
coordinator database directory is `0700`, and the coordinator creates each
`0660` output file before launching Codex.

The verifier runs each fixed Git command with an empty environment, a wall-clock
timeout, a Linux address-space limit, and preflight limits for commits, changed
paths, individual blobs, total blob bytes, and generated diff bytes. A result
outside those limits remains pending for maintainer review; it never becomes PR
eligible automatically.

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

PR tracking and worktree allocations live in SQLite and survive process or
server restarts. If no implementation-capable agent slot is available, the job
stays queued. Terminal worktrees are removed promptly. When all advertised slots
are occupied, the least-recently-used worktree whose clean head is already on
GitHub may be reclaimed; otherwise new work remains queued.

The Phoenix endpoint listens only on `127.0.0.1:4000`. Expose it privately over
your tailnet with Tailscale Serve:

```sh
sudo tailscale serve --bg http://127.0.0.1:4000
tailscale serve status
```

Open the HTTPS `*.ts.net` address reported by Tailscale on the Mac or iPhone.
Do not use Tailscale Funnel for this private console.
