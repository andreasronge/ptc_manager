# PtcManager

PtcManager is a private maintainer console for reviewing GitHub work, approving
agent jobs, and seeing what Codex or Claude agents are doing and how long they
have been running.

The current first slice is deliberately local and safe:

- a responsive issue inbox with private plain-language summaries;
- an **Approve and start** workflow backed by SQLite transactions;
- one active implementation job per issue, enforced by the database;
- a live agent-activity panel with worker, role, task, start time, elapsed time,
  heartbeat, and Herdr identifiers;
- password authentication, CSRF protection, and approval audit events;
- deterministic demo data so the UI works without GitHub or model credentials.

It does **not** yet poll GitHub, start real Herdr sessions, push branches, create
pull requests, or write to issues. Those capabilities are planned in later
slices and remain behind explicit maintainer approval. See [PLAN.md](PLAN.md).

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

Deployment and the real GitHub/Herdr adapters are intentionally deferred until
the corresponding delivery slices in the plan.
