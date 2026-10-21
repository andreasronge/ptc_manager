# Several machines: design

This document explains how PtcManager runs on several machines and why. The
README's "Several machines" section is the operator's guide; this is the
maintainer's.

## Model

One PtcManager instance runs per machine. A repository is **homed** on exactly
one machine, which polls GitHub for it, runs its collection runs, and executes
all of its work locally. Every part of execution assumes the database, the
Herdr server, and the worktree share a host (Herdr commands, result JSON,
execution artifacts, the `ptc-operation` broker socket, the pre-publication
gate, the publication broker, lease reconciliation), so remote placement, one
machine coordinating work on another, is out of scope. What it would need is
listed at the end.

Fixed invariants:

1. A repository is claimed by at most one configured member at a time. No
   automatic takeover, ever.
2. Machines never share SQLite, never use Distributed Erlang, and never send
   each other commands. The peer protocol is read-only `GET`s.
3. Secret values never leave the machine that stores them.
4. Nothing is written to a managed repository; requirements are PtcManager
   configuration.
5. Gating is write-free: only transitions are persisted.
6. Network and subprocess work never happens inside a database transaction.
7. With no cluster configuration and no requirements, behaviour is as it was
   on one machine.
8. Model output and peer documents are data, never authority.

## Machine identity and tool inventory

`PtcManager.Machine` holds the id (`PTC_MACHINE_ID`, default `local`) and the
name. The header badge's colour is `:erlang.phash2(id, 360)` as a hue, the same
on every console.

Repository commands run in two **execution contexts**, and a tool reachable in
one may not be in the other:

| Context | Runs | Probed by |
|---|---|---|
| `pane` | agents and `$PTC_OPERATION_WRAPPER` commands in Herdr panes | `ptc_manager-tool-probe.service`, a oneshot with the Herdr unit's user, groups, environment file, and sandbox; `tool_probe_script_test.exs` compares the two unit files |
| `setup` | the workspace setup command | the console, through the same `sudo -u <worker>` path as the bootstrap helper, so it inherits the console's mount sandbox and sudo's `secure_path` |

On macOS both contexts are the service account, so one probe run is recorded
for both. The pre-publication gate's identity is not probed.

`priv/tool_probe.py` (installed on Linux as `/usr/local/bin/ptc-manager-tool-probe`)
runs each catalog probe as an argv list without a shell, stdin closed, with a
5-second timeout and output capped at 4 KiB while it is read. Each probe runs
in a process group led by a sentinel the script reaps last, and the whole group
is killed afterwards, so descendants never outlive a probe and the group id
cannot be reused before the kill. The script records raw results; Elixir
(`ToolInventory`) parses and normalizes versions. The catalog
(`ToolProbes`) is code plus `PTC_TOOL_PROBES_JSON`, validated at boot; the
console writes it to `tool-probe-catalog.json` for the unit to read, so the
console never stores a probe command.

`Machine.Inventory` keeps the parsed inventory in an ETS table named after the
process, rereads the snapshot files every 30 seconds, probes every 10 minutes
and on Refresh, and persists only a change in the evaluated tool lines
(`machine.inventory_changed`), compared against the last such event so a
restart writes nothing. It also asks the worker whether each enabled agent CLI
is signed in, for the status document.

## Requirements and the capability gate

`repositories.machine_requirements` (`%{"tools" => [...]}`) lists tools and
optional version requirements. `Machine.Requirements.evaluate/3` is pure; a
line holds only when every context satisfies it with a fresh inventory.

`Machine.Gate` answers two questions from memory and repository rows, writing
nothing: `unsatisfied_repository_ids/0` for queue queries, and `check/1`
inside the admitting transaction. The admission points are implementation
dispatch (`next_queued_job/1` skips the ids; `lease_job` rolls back), review
claims and assessment retries, review continuations (checked before recovery,
which writes and stops agents, and again at the claim), resuming retained
work, maintainer actions (the candidate query skips the ids; the claim and
the repair-worktree reservation recheck), and the repair priority predicate,
which counts a queued repair only for repositories this machine can run. A
waiting item stays queued; collection runs already treat a queued job as in
progress, so no retry is spent. The reason shown on pages is derived from the
evaluation, never stored; `Stalls` reports a wait over 30 minutes as
`machine_incapable`.

A review round's deadline now starts at its claim. Previously a round could
expire while queued; now `sweep/0`, `status/2`, and the claim leave queued
rounds alone and `Stalls.review_queued/1` reports long queue waits.

Admissions for a repository with requirements, or on a cluster member, write
`placement.admitted` with the machine, requirements, and evaluated tool lines
in the admitting transaction.

## Membership and the peer protocol

`PTC_CLUSTER_MEMBERS` and `PTC_CLUSTER_SECRET` are identical on every member.
`Cluster.validate!/0` runs first at boot. The membership revision is the
SHA-256 of the canonical map.

Distributed Erlang was rejected: its cookie grants remote code execution on
every node, TLS distribution must be switched on everywhere at once, and node
versions would couple Linux and macOS releases. Nothing needs a shared
registry.

The protocol is `GET /api/peer/v1/...` behind `tailscale serve`. Requests sign
method, path, timestamp, caller, a random nonce, and the body hash; responses
sign status, the request's nonce, timestamp, responder, and body hash, so a
response cannot be replayed to another request. Clock skew is limited to 60
seconds; comparisons are constant-time. Being read-only, it keeps no nonce
store; a write endpoint would need one. An unclustered console answers 404, an
unsigned request 401, and a signed request from a machine outside the map a
signed 403 `{"member": false}`.

`/status` (`Cluster.Status`) carries identity, deployed SHA, membership
revision, mode, inventory per context, agent logins, execution-profile
digests, capacity and load, each repository's claim with its conditions and
requirements, pending intents, and live jobs and runs with console links. It
never carries untrusted operator-state text, prompts, issue text, agent
output, or secrets. Claim predicates are read in one deferred read
transaction, a single WAL snapshot that never takes the write lock.
`Cluster.Peer.fetch_status/2` validates a document before anyone uses it
(canonical, unique repository keys and known claim states) and fails closed,
then `Cluster.StatusShape` normalizes its display fields once, so a member's
malformed data can neither clear a claim nor break a page.

`Cluster.PeerPoller` polls every 15 seconds with a 5-second timeout, keeps
results in ETS, marks members `healthy`, `incompatible`, `refused`, or
`unreachable` (60 seconds without a signed answer), and audits transitions
only. Claim checks always fetch fresh.

## Claims and fencing

A member claims a repository while the row is enabled, a job is not terminal,
an agent action is pending, a collection run is live, a worktree allocation is
not removed, or an unexpired claim intent exists (`Cluster.Claims`). Nothing
stores an owner. Keys are lowercased `owner/name`; a unique index on
`lower(owner), lower(name)` keeps one row per repository.

`Claims.acquire/4` writes an intent (5 minutes) in a short transaction, asks
every peer outside any transaction, and refuses when any peer claims the
repository, has an intent for it, is unreachable or incompatible, refuses this
machine, or reports another membership revision. Otherwise one transaction
checks the intent is still ours and younger than 2.5 minutes, runs the
caller's import, enables the row, deletes the intent, and audits
`repository.enabled` with every peer's answer. Two simultaneous claimants both
announce before they read, so at least one refuses.

On a member, `Operations.set_repository_enabled(_, true, _)` is a claim,
repositories are inserted disabled, and job creation, retries, agent-action
enqueueing, collection runs, and schedule triggers refuse a disabled
repository. `Cluster.Fence` adds to the gate: no admission before the startup
round has heard from every peer (healthy, same revision and protocol, no
conflicting claim; no timeout), none at all while a peer refuses this machine
(the refusal stands through later transport failures), none for a disabled
repository, and none for a repository a peer also claims. Running work is never
touched.

## Moving a repository

The source serves `/repositories/:owner/:name/settings` only for a repository
it has disabled and no longer claims. `Cluster.RepositorySettings` exports the
transferable fields of the repository row (a test pins that every changeset
field is either transferred or deliberately excluded), each automation's
current version and triggers by key, and the agent environment variable names,
with a digest. The target's claim page (`ClusterClaimLive`) checks readiness,
shows the diff, and claims with the digest the maintainer saw; settings are
fetched again outside the transaction and a changed digest asks for another
look. The import runs inside the claim's final transaction, never raises on a
malformed document, and leaves every automation and trigger paused.

## Tests

Unit tests fake peers through `PtcManager.TestPeerClient`, swapped in with
`PtcManager.Gateway`, and configure the test run as a member with
`PtcManager.ClusterCase`. `test/ptc_manager/cluster/multi_member_test.exs`
(tagged `:nightly`, so `scripts/ci/test-suite` skips it and `mix test` runs it)
starts real members as `:peer` nodes, each running the whole application with
its own SQLite file, HTTP port, machine id, and member map, and drives them
through seven scenarios: mutual health, claim refusal and a move with its
settings, simultaneous claims, a partition, restart from a stale database, a
member at another protocol version, and a machine removed from the others'
maps. Plain HTTP on loopback is allowed only by a test-only flag; signing stays
on. The poller's unreachable bound (`cluster_unreachable_after_ms`) and the
protocol version (`cluster_protocol_version`) can be overridden only in a test
build (`cluster_test_overrides`, read with `Application.compile_env`); a
release compiles the constants in.

## Decisions made while implementing the plan

| Decision | Alternatives | Reason |
|---|---|---|
| One Python probe script for both contexts and both OSes | an Elixir runner on macOS | macOS deploys already depend on `/usr/bin/python3`; one implementation of the bounds |
| The console writes the probe catalog file the unit reads | a catalog inside the script | keeps the catalog in one place (code plus env) |
| Probes run under a sentinel-led process group, killed unconditionally | killing the probe's own group | macOS Python 3.9 has neither `process_group` nor `waitid`; a sentinel keeps the group id reserved |
| `docker` is probed with `docker --version` | `docker version --format '{{.Client.Version}}'` | the latter contacts the daemon and fails with `docker-daemon` |
| The pane `PATH` is documented in `herdr.env.example`, not written by deploys | deploy appends `PATH` | both units read the same file, so parity holds without editing host configuration |
| Placement evidence only with requirements or on a member | on every admission | invariant 7 |
| Every agent action of an incapable repository waits | only actions that run commands | every action runs an agent in the repository |
| Resume is refused on an incapable machine | queue it to wait | it is a button; refusing says why at once |
| Claim intents are a table with a unique key | a column on repositories | an intent exists before, and independently of, the enabled row |
| Gate state is computed per check from ETS and repository rows | a cached set | reads are cheap and cannot go stale |
| Startup also requires every peer at the same protocol version | revision only | an incompatible peer's claims may be unreadable |
| Status reads use a deferred transaction | the default immediate one | serving peers must never take the write lock |
| Plan commits 3 and 4 are one commit, and the Cluster page skeleton lands with the switcher | as planned | the status document's claim section and the claim protocol are one contract |
| Drift lists differing deployed SHAs without "more than one release apart" or "behind the default branch" | ordering releases | a member cannot order SHAs without the repository's history |
| `mix ptc.cluster check` signs as `--as`, `PTC_MACHINE_ID`, or the first member | a reserved non-member caller | holders of the secret can sign as any member anyway |
| The integration harness uses `:peer` nodes over standard IO | OS processes running `mix phx.server` | separate VMs give each member its own application singletons, with no distribution or epmd, and the test can call into each member |
| Peer documents are normalized once at fetch (`StatusShape`) | defensive code in every consumer | one place decides what another machine's data may look like |
| The README and this document replace the plan | keeping the plan | the plan described intent; this describes what shipped |

## Deferred: remote placement

Running work on a machine other than the repository's home would need a
remote dispatch command with idempotency keys and cross-machine fencing;
result JSON, artifacts, and stop reports returned to the coordinator; the
pre-publication gate and publication broker on the executing machine with the
exact verified commit; lease renewal across partitions; and per-machine
broker credentials.
