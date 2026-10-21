defmodule PtcManager.Host do
  @moduledoc """
  The host this console runs on, resolved once at boot.

  `config/runtime.exs` selects one profile and fills its paths: `:linux` for a
  Linux release, `:macos` for a Darwin release with `PTC_MACOS_SERVICE_ROOT`,
  and `:development` without a release. Every platform decision reads this
  module; nothing else reads the agent account setting or the OS type.

  | | `:linux` | `:macos` | `:development` |
  |---|---|---|---|
  | agent identity | `{:separate, user}` with `PTC_HERDR_RUN_AS_USER`, else `:service_account` | `:service_account` | as configured |
  | containment | `:cgroup` when enabled, else `:none` | `:none` | `:none` unless configured |
  | uncertain operations | `:escalate` to maintenance | `:fence` the slot | `:fence` |
  | service manager | systemd | launchd | none |
  """

  alias PtcManager.CommandEnvironment

  @profiles [:linux, :macos, :development]

  @doc "`:linux`, `:macos` or `:development`."
  def profile do
    case Application.get_env(:ptc_manager, :host_profile, :development) do
      profile when profile in @profiles -> profile
    end
  end

  @doc "The operating system as the inventory reports it."
  def os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      {family, name} -> "#{family}-#{name}"
    end
  end

  @doc "Whether agents run as a separate OS account or as this service account."
  def agent_identity do
    case Application.get_env(:ptc_manager, :herdr_run_as_user) do
      user when is_binary(user) and user != "" -> {:separate, user}
      _service_account -> :service_account
    end
  end

  @doc "True when agents run under a separate worker account."
  def separate_agent_account?, do: match?({:separate, _user}, agent_identity())

  @doc """
  Builds a command that runs as the agent identity: through the worker's sudo
  rule on a separate-account host, directly otherwise.
  """
  def agent_command(binary, args) when is_binary(binary) and is_list(args) do
    case agent_identity() do
      {:separate, user} -> CommandEnvironment.command(binary, args, user)
      :service_account -> {binary, args}
    end
  end

  @doc """
  The owners trusted above a managed worktree root besides its own owner:
  root alone when agents have their own account, root and the service account
  when agents run as it (it may already write anything it owns).
  """
  def trusted_ancestor_owners(service_uid) do
    case agent_identity() do
      {:separate, _user} -> [0]
      :service_account -> [0, service_uid]
    end
  end

  @doc "`:cgroup` when operations run in their own cgroup, otherwise `:none`."
  def containment do
    if Application.get_env(:ptc_manager, :resource_operation_cgroups, false),
      do: :cgroup,
      else: :none
  end

  @doc """
  What happens to an operation nothing proves has stopped. Linux keeps today's
  recovery and escalation to maintenance; elsewhere the operation stays fenced
  until a maintainer releases it.
  """
  def uncertain_operation_policy do
    if profile() == :linux, do: :escalate, else: :fence
  end

  @doc "Whether a wrapper looks for processes that outlive its command."
  def check_remaining_processes?,
    do: uncertain_operation_policy() == :fence and containment() == :none

  @doc "`:systemd`, `:launchd` or `:none`."
  def service_manager do
    case profile() do
      :linux -> :systemd
      :macos -> :launchd
      :development -> :none
    end
  end

  @doc """
  The checkout this member deploys its own release from, or nil. Only a macOS
  member builds its release from a local checkout (`PTC_MACOS_SOURCE`).
  """
  def self_source_path do
    case {profile(), Application.get_env(:ptc_manager, :host_self_source)} do
      {:macos, path} when is_binary(path) and path != "" -> Path.expand(path)
      _other -> nil
    end
  end

  @paths [
    {:operation_wrapper, :resource_operation_wrapper, "PTC_OPERATION_WRAPPER", :executable},
    {:operation_socket, :resource_operation_socket_path, "PTC_OPERATION_SOCKET_PATH", :socket},
    {:operation_context_dir, :resource_operation_context_dir, "PTC_OPERATION_CONTEXT_DIR",
     :writable_directory},
    {:execution_artifact_root, :execution_artifact_root, "PTC_EXECUTION_ARTIFACT_ROOT",
     :writable_directory},
    {:planning_snapshot_root, :planning_snapshot_root, "PTC_PLANNING_SNAPSHOT_ROOT",
     :created_directory},
    {:daily_digest_bundle_root, :daily_digest_bundle_root, "PTC_DAILY_DIGEST_BUNDLE_ROOT",
     :created_directory},
    {:tool_inventory_dir, :tool_inventory_dir, "PTC_TOOL_INVENTORY_DIR", :created_directory},
    {:health_output, :health_snapshot_path, "PTC_HEALTH_OUT", :output_file}
  ]

  @doc """
  The host paths as `{key, application key, environment variable, kind}`. An
  explicit environment variable wins over the profile's default.
  """
  def path_specs, do: @paths

  @doc "The configured value of one host path."
  def path(key) do
    {^key, app_key, _env, _kind} = List.keyfind(@paths, key, 0)
    Application.get_env(:ptc_manager, app_key)
  end

  @helpers %{
    worktree_cleanup:
      {"/usr/local/bin/ptc-manager-worker-worktree-cleanup", "priv/worktree_cleanup.py"},
    worktree_preserve:
      {"/usr/local/bin/ptc-manager-worker-worktree-preserve", "priv/worktree_preserve.py"},
    worktree_seal: {"/usr/local/bin/ptc-manager-worker-worktree-seal", "priv/worktree_seal.py"},
    tool_probe: {"/usr/local/bin/ptc-manager-tool-probe", "priv/tool_probe.py"}
  }

  @doc """
  The command for one host helper. A separate-account host runs the installed
  helper through sudo (the worktree seal as root); a service-account host runs
  the packaged Python script directly.
  """
  def helper_command(key, args) when is_map_key(@helpers, key) and is_list(args) do
    {installed, script} = Map.fetch!(@helpers, key)

    case agent_identity() do
      {:separate, user} ->
        CommandEnvironment.command(
          installed(key, installed),
          args,
          if(key == :worktree_seal, do: "root", else: user)
        )

      :service_account ->
        {"/usr/bin/python3", ["-I", Application.app_dir(:ptc_manager, script) | args]}
    end
  end

  defp installed(:tool_probe, default),
    do: Application.get_env(:ptc_manager, :tool_probe_script, default)

  defp installed(_key, default), do: default
end
