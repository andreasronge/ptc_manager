# Host profiles

PtcManager runs on two kinds of agent host: a Linux release under systemd,
where agents may run under their own account inside cgroups, and a macOS
release under launchd, where agents run as the maintainer's own account
without containment. One host profile, resolved at boot, answers every
platform question, so the difference lives in one place.

## Resolution

`config/runtime.exs` selects the profile once:

| Profile | Selected when |
|---|---|
| `:linux` | a production release on Linux |
| `:macos` | a production release on Darwin; it needs `PTC_MACOS_SERVICE_ROOT` |
| `:development` | anything else (`mix phx.server`, `mix test`) |

A Darwin release refuses to boot without an absolute
`PTC_MACOS_SERVICE_ROOT`, with `PTC_HERDR_RUN_AS_USER` set, or with
`PTC_OPERATION_CGROUPS=true`, naming the setting.

`PtcManager.Host` reads the profile and is the only module that reads the
agent account setting (`herdr_run_as_user`), the OS type, or
`PTC_MACOS_SERVICE_ROOT`; `test/ptc_manager/host_test.exs` enforces this.

## What the profile decides

| Question | `:linux` | `:macos` | `:development` |
|---|---|---|---|
| Agent identity (`Host.agent_identity/0`) | `{:separate, user}` with `PTC_HERDR_RUN_AS_USER`, else `:service_account` | `:service_account` | as configured |
| Trusted owners above a worktree root | root only for a separate account; root and the service account otherwise | root and the service account | as identity |
| Containment (`Host.containment/0`) | `:cgroup` when `PTC_OPERATION_CGROUPS` is on (the release default) | `:none` | `:none` unless configured |
| Uncertain operations (`Host.uncertain_operation_policy/0`) | `:escalate`: cgroup recovery, otherwise maintenance after the retry bound | `:fence` | `:fence` |
| Wrapper looks for leftover processes | no | yes | yes |
| Service manager | systemd | launchd | none |
| Readiness failures block admission | no, reported only | yes | yes |
| Own release deployable while disabled | no | the `PTC_MACOS_SOURCE` checkout | no |

Helper commands come from `Host.agent_command/2` and
`Host.helper_command/2`. With a separate agent account they go through the
worker's sudo rule exactly as before (the worktree seal as root); with the
service account the packaged `priv/*.py` scripts run directly.

## Host paths

Each path has an application key and an environment variable that wins over
the profile's default. On macOS every default lives under the service root.

| `Host.path/1` key | Variable | Kind | macOS default |
|---|---|---|---|
| `operation_wrapper` | `PTC_OPERATION_WRAPPER` | executable | `bin/ptc-operation` |
| `operation_socket` | `PTC_OPERATION_SOCKET_PATH` | socket | `run/operations.sock` |
| `operation_context_dir` | `PTC_OPERATION_CONTEXT_DIR` | writable directory | `data/operation-contexts` |
| `execution_artifact_root` | `PTC_EXECUTION_ARTIFACT_ROOT` | writable directory | `data/execution-artifacts` |
| `planning_snapshot_root` | `PTC_PLANNING_SNAPSHOT_ROOT` | created on first use | `data/planning-snapshots` |
| `daily_digest_bundle_root` | `PTC_DAILY_DIGEST_BUNDLE_ROOT` | created on first use | `data/daily-digest-bundles` |
| `tool_inventory_dir` | `PTC_TOOL_INVENTORY_DIR` | created on first use | `data/tool-inventory` |
| `health_output` | `PTC_HEALTH_OUT` | output file | `data/health.json` |

## Operations without containment

A cgroup proves that an abandoned command stopped; nothing on macOS does for
an unprivileged service. The design keeps that uncertainty contained and
visible instead of guessing:

1. The wrapper (`deploy/ptc-operation`) starts a command only after the
   coordinator acknowledges that exact operation as running, with its signal
   handlers already installed. Every command carries
   `PTC_OPERATION_ATTEMPT=<operation>-<attempt>`. A failed signal is logged,
   never taken as proof that the group is gone.
2. After the command exits, the wrapper kills its process group and looks for
   leftovers: same-account processes whose environment carries the marker
   (`ps -E` on macOS, `/proc/<pid>/environ` on Linux) and anything still
   holding the command's output. macOS hides the environment of Apple
   platform binaries such as `/bin/sh`, which is why the output check exists.
   A leftover, or a listing that fails, finishes the operation with
   `processes_remaining`: it stays `recovery_pending` and keeps its slot.
3. The broker never releases such an operation by itself and never enters
   maintenance for it. Recovery returns `{:fenced, evidence}` (the marker
   listing, whether the wrapper pid exists, whether the slot lock is free),
   the broker records it when it changes, and an `operation_fenced` stall
   names the operation, its job and its slot.
4. A maintainer releases it on the Operations page, also in maintenance mode.
   PtcManager signals no process; it lists a `kill <pid>` line per process to
   copy after checking. Release needs the slot lock to be free, asks to accept
   any listed processes, and is one guarded update from the inspected
   revision to `lost`, audited as `resource_operation.released`. A wrapper
   that resumes afterwards is refused and stops its command.

The residual risk: a descendant that escapes the process group, does not hold
the command's output, and either clears its environment or hides it (an Apple
platform binary on macOS, a non-dumpable process on Linux) is not detected,
and its command finishes normally.

## Readiness

`PtcManager.Machine.Readiness` evaluates at boot, with every tool-inventory
refresh, and from the banner's **Recheck**: host paths, the service-root
helpers against SHA-256 digests compiled from `deploy/`
(`PtcManager.Machine.HelperManifest`), `ptc-operation self-test`, an
authenticated broker `ping` with a readiness-only context, result
reconciliation while dispatching, the publication mode, and agent logins. A
failing check on macOS or in development makes `Machine.Gate` refuse with
`:host_not_ready`; Linux reports it in the banner only. Queued jobs record
why they wait in `jobs.dispatch_blocked_reason`.

## Ownership of agent runs

Only runs bound to a job or an agent action carry operational weight. Herdr
panes PtcManager did not start are stored with the role `observed`: they are
listed as "Other Herdr panes" and never hold a drain, use a slot, raise an
agent stall or offer a cancel.

## Setting up a macOS host

1. Create the service root with `bin`, `run`, `logs`, `releases`, `config`
   and `data`, owned by the maintainer account.
2. Install `deploy/ptc-operation`, `deploy/ptc-manager-worker-review`,
   `deploy/ptc-manager-worker-agent-login` and `deploy/macos-deploy-host` in
   `bin`, executable. Reinstall them from each deployed revision: readiness
   compares them with the release and admits no work while one differs.
3. Copy `deploy/ptc_manager-macos.env.example` to `config/manager.env` and
   fill it in.
4. Install the launchers `deploy/launchd/run-*.example` as `bin/run-*`, and
   the plists from `deploy/launchd/` in `/Library/LaunchDaemons` with the
   account name filled in; bootstrap them with `launchctl`. `run-herdr`
   starts Herdr with a clean environment because agent panes inherit it:
   never source `manager.env` into the Herdr server.
5. Open the console; the readiness banner names anything left to fix.
