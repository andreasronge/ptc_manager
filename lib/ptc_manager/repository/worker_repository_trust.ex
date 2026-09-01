defmodule PtcManager.Repository.WorkerRepositoryTrust do
  @moduledoc "Grants the dedicated Herdr worker temporary Git trust for one managed snapshot."

  alias PtcManager.Dispatch.HerdrAdapter

  def allow(path) when is_binary(path) do
    if worker_boundary?() and managed_snapshot_path?(path) do
      case git(["config", "--global", "--add", "safe.directory", Path.expand(path)]) do
        {_output, 0} -> {:ok, :trusted}
        {output, status} -> {:error, {:worker_repository_trust_failed, status, bounded(output)}}
      end
    else
      {:ok, :not_required}
    end
  end

  def revoke(path) when is_binary(path) do
    if worker_boundary?() and managed_snapshot_path?(path) do
      case git([
             "config",
             "--global",
             "--fixed-value",
             "--unset-all",
             "safe.directory",
             Path.expand(path)
           ]) do
        {_output, status} when status in [0, 5] -> :ok
        {output, status} -> {:error, {:worker_repository_untrust_failed, status, bounded(output)}}
      end
    else
      :ok
    end
  end

  @doc false
  def managed_snapshot_path?(path) when is_binary(path) do
    case Application.get_env(:ptc_manager, :planning_snapshot_root) do
      root when is_binary(root) and root != "" ->
        expanded = Path.expand(path)
        Path.dirname(expanded) == Path.expand(root)

      _root ->
        false
    end
  end

  defp worker_boundary?,
    do: Application.get_env(:ptc_manager, :herdr_run_as_user) not in [nil, ""]

  defp git(args) do
    command =
      Application.get_env(
        :ptc_manager,
        :worker_repository_trust_command,
        HerdrAdapter
      )

    command.git_command(args)
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
