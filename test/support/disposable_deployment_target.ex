defmodule PtcManager.DisposableDeploymentTarget do
  @moduledoc """
  A migrated, isolated SQLite target for deployment-boundary tests.

  The target uses Ecto's dynamic-repository support, so production schemas and
  domain modules run unchanged while the normal test database remains isolated.
  A stopped target can be snapshotted, restored before an effect, or restarted
  without restore after an effect.
  """

  alias PtcManager.Repo

  @directory_prefix "ptc-manager-deployment-target-"

  @failure_policy Path.expand("../../deploy/deployment-failure-policy", __DIR__)

  defstruct [
    :directory,
    :database,
    :backup,
    :repo,
    :lifecycle,
    :previous_dynamic_repo,
    trace: []
  ]

  def start!(opts \\ []) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    directory =
      Path.join(
        System.tmp_dir!(),
        @directory_prefix <> suffix
      )

    database = Path.join(directory, "target.db")
    backup = Path.join(directory, "pre-effect.db")
    previous_dynamic_repo = Repo.get_dynamic_repo()

    File.mkdir!(directory)
    {:ok, lifecycle} = Agent.start(fn -> nil end)

    target = %__MODULE__{
      directory: directory,
      database: database,
      backup: backup,
      lifecycle: lifecycle,
      previous_dynamic_repo: previous_dynamic_repo,
      trace: [:target_created]
    }

    try do
      target
      |> start_repo!()
      |> migrate!(opts)
    rescue
      exception ->
        cleanup_failed_start(target)
        reraise exception, __STACKTRACE__
    end
  end

  def snapshot!(%__MODULE__{} = target) do
    remove_file_if_present!(target.backup)
    escaped_backup = String.replace(target.backup, "'", "''")
    Repo.query!("VACUUM INTO '#{escaped_backup}'")

    target
    |> trace(:pre_effect_snapshot_taken)
  end

  def restore_pre_effect!(%__MODULE__{} = target) do
    unless File.regular?(target.backup) do
      raise "cannot restore disposable deployment target without a snapshot"
    end

    target = stop_repo!(target)
    remove_file_if_present!(target.database)
    remove_sqlite_sidecars(target.database)
    File.cp!(target.backup, target.database)

    target
    |> trace(:pre_effect_snapshot_restored)
    |> start_repo!()
  end

  def restart_post_effect!(%__MODULE__{} = target) do
    target
    |> stop_repo!()
    |> trace(:post_effect_database_preserved)
    |> start_repo!()
  end

  def recover_failure!(%__MODULE__{} = target, phase) when is_atom(phase) do
    {output, 0} = System.cmd(@failure_policy, [Atom.to_string(phase)], stderr_to_stdout: true)

    case String.trim(output) do
      "restore_snapshot" ->
        restore_pre_effect!(target)

      "preserve_current" ->
        :ok = PtcManager.OperationalMode.enter_maintenance("deploy")
        restart_post_effect!(target)

      action ->
        raise "unsupported disposable deployment recovery action: #{inspect(action)}"
    end
  end

  def migrate_remaining!(%__MODULE__{} = target, opts \\ [all: true]),
    do: migrate!(target, opts)

  def rollback!(%__MODULE__{} = target, opts \\ [step: 1]) do
    run_migrations!(target, :down, opts)
    trace(target, :migrations_rolled_back)
  end

  def record(%__MODULE__{} = target, event) when is_atom(event), do: trace(target, event)
  def trace(%__MODULE__{trace: events}), do: Enum.reverse(events)

  def close!(%__MODULE__{} = target) do
    target = stop_repo!(target)
    validate_directory!(target.directory)
    File.rm_rf!(target.directory)
    if Process.alive?(target.lifecycle), do: Agent.stop(target.lifecycle)
    :ok
  end

  defp start_repo!(%__MODULE__{repo: nil} = target) do
    {:ok, repo} =
      Repo.start_link(
        database: target.database,
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    Repo.put_dynamic_repo(repo)
    Agent.update(target.lifecycle, fn _old_repo -> repo end)
    target |> Map.put(:repo, repo) |> trace(:repository_started)
  end

  defp migrate!(target, opts) do
    run_migrations!(target, :up, opts)
    trace(target, :migrations_applied)
  end

  defp run_migrations!(target, direction, opts) do
    previous_ignore_module_conflict = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      strategy =
        opts
        |> Keyword.take([:all, :to, :to_exclusive, :step])

      strategy = if strategy == [], do: [all: true], else: strategy

      migration_opts =
        strategy
        |> Keyword.put(:dynamic_repo, target.repo)
        |> Keyword.put(:log, false)

      Ecto.Migrator.run(Repo, Ecto.Migrator.migrations_path(Repo), direction, migration_opts)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous_ignore_module_conflict)
    end

    :ok
  end

  defp stop_repo!(%__MODULE__{repo: nil} = target) do
    stop_current_repo!(target)
  end

  defp stop_repo!(%__MODULE__{} = target) do
    stop_current_repo!(target)
  end

  defp stop_current_repo!(target) do
    Repo.put_dynamic_repo(target.previous_dynamic_repo)
    repo = Agent.get(target.lifecycle, & &1)

    if is_pid(repo) and Process.alive?(repo) do
      monitor = Process.monitor(repo)

      try do
        Supervisor.stop(repo)
      catch
        :exit, _reason -> :ok
      end

      receive do
        {:DOWN, ^monitor, :process, ^repo, _reason} -> :ok
      after
        1_000 ->
          Process.demonitor(monitor, [:flush])

          if Process.alive?(repo) do
            raise "disposable deployment repository did not stop"
          end
      end
    end

    Agent.update(target.lifecycle, fn _repo -> nil end)
    target |> Map.put(:repo, nil) |> trace(:repository_stopped)
  end

  defp cleanup_failed_start(target) do
    target = stop_repo!(target)
    validate_directory!(target.directory)
    File.rm_rf!(target.directory)
    if Process.alive?(target.lifecycle), do: Agent.stop(target.lifecycle)
  end

  defp remove_sqlite_sidecars(database) do
    remove_file_if_present!(database <> "-wal")
    remove_file_if_present!(database <> "-shm")
  end

  defp remove_file_if_present!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "could not remove #{path}: #{:file.format_error(reason)}"
    end
  end

  defp validate_directory!(directory) do
    basename = Path.basename(directory)

    unless Path.expand(Path.dirname(directory)) == Path.expand(System.tmp_dir!()) and
             String.starts_with?(basename, @directory_prefix) do
      raise "refusing to remove unexpected disposable deployment directory"
    end
  end

  defp trace(target, event), do: %{target | trace: [event | target.trace]}
end
