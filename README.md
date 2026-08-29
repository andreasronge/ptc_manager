# PtcManager

PtcManager is a private maintainer console for reviewing GitHub work, approving
agent jobs, and seeing what Codex or Claude agents are doing and how long they
have been running.

The current second slice is deliberately read-only at its external boundaries:

- a responsive issue inbox with private plain-language summaries;
- an **Approve and start** workflow backed by SQLite transactions;
- one active implementation job per issue, enforced by the database;
- a live agent-activity panel with worker, role, task, start time, elapsed time,
  heartbeat, and Herdr identifiers;
- password authentication, CSRF protection, and approval audit events;
- deterministic demo data so the UI works without GitHub or model credentials;
- manual or periodic read-only GitHub issue synchronization;
- read-only Herdr agent reconciliation with lost-agent detection;
- optional private Codex investigations in an ephemeral read-only sandbox.

It does **not** start Herdr sessions, dispatch queued jobs, push branches, create
pull requests, close issues, or write to GitHub. Those capabilities remain in
later slices behind explicit maintainer approval. See [PLAN.md](PLAN.md).

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
fine-grained token with repository metadata and Issues read access only.

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

## Hetzner systemd and Tailscale

Build the release, copy `_build/prod/rel/ptc_manager` to `/opt/ptc_manager`, and
create the dedicated service account and writable database directory:

```sh
sudo groupadd --system ptc-manager
sudo groupadd --system ptc-manager-codex
sudo groupadd --system ptc-manager-output
sudo useradd --system --home /var/lib/ptc_manager --gid ptc-manager --groups ptc-manager-output --shell /usr/sbin/nologin ptc-manager
sudo useradd --system --home /var/lib/ptc_manager-codex --gid ptc-manager-codex --groups ptc-manager-output --shell /usr/sbin/nologin ptc-manager-codex
sudo install -d -o ptc-manager -g ptc-manager -m 0700 /var/lib/ptc_manager
sudo install -d -o ptc-manager -g ptc-manager-output -m 2770 /var/lib/ptc_manager-output
sudo install -d -o ptc-manager-codex -g ptc-manager-codex -m 0700 /var/lib/ptc_manager-codex
sudo install -d -o root -g root -m 0755 /etc/ptc_manager
sudo install -o root -g root -m 0644 deploy/ptc_manager.service /etc/systemd/system/ptc_manager.service
sudo install -o root -g root -m 0600 deploy/ptc_manager.env.example /etc/ptc_manager/ptc_manager.env
sudo install -o root -g root -m 0440 deploy/ptc_manager-codex.sudoers /etc/sudoers.d/ptc_manager-codex
sudo visudo -cf /etc/sudoers.d/ptc_manager-codex
```

Edit `/etc/ptc_manager/ptc_manager.env`, replace every placeholder, verify the
binary and checkout paths, then start the release:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ptc_manager
sudo systemctl status ptc_manager
```

The coordinator and Herdr run as `ptc-manager`. Codex runs as the separate
`ptc-manager-codex` account, which cannot read the root-only service environment
or inspect the coordinator process. Authenticate Codex as that account:

```sh
sudo -u ptc-manager-codex -H codex login
```

The checkout at `PTC_REPOSITORY_PATH` must be readable by
`ptc-manager-codex`, but it does not need to be writable. The two accounts share
only the setgid `ptc-manager-output` directory at `PTC_CODEX_OUTPUT_DIR`; the
coordinator database directory is `0700`, and the coordinator creates each
`0660` output file before launching Codex.

Use the same `HERDR_SESSION` and `HERDR_SOCKET_PATH` values whenever you start
or connect to Herdr as `ptc-manager`. An existing Herdr session owned by `root`
or another login account is deliberately not visible to this isolated service;
restart or recreate that session under `ptc-manager` before enabling polling.
The CLI is bounded by `PTC_HERDR_TIMEOUT_MS`; after
`PTC_HERDR_STALE_AFTER_MS` without a successful snapshot, active agents are
shown as `lost` rather than working forever.

The Phoenix endpoint listens only on `127.0.0.1:4000`. Expose it privately over
your tailnet with Tailscale Serve:

```sh
sudo tailscale serve --bg http://127.0.0.1:4000
tailscale serve status
```

Open the HTTPS `*.ts.net` address reported by Tailscale on the Mac or iPhone.
Do not use Tailscale Funnel for this private console.
