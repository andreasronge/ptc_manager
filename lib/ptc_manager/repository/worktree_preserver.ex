defmodule PtcManager.Repository.WorktreePreserver do
  @moduledoc "Creates a recoverable Git bundle and binary patch before retained work is removed."

  alias PtcManager.CommandEnvironment

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def preserve(allocation, token)
      when is_binary(allocation.path) and is_binary(token) and
             is_binary(allocation.job.branch_name) do
    root = Application.fetch_env!(:ptc_manager, :worktree_root) |> Path.expand()

    artifact_root =
      Application.get_env(:ptc_manager, :retained_artifact_root) || default_artifact_root()

    args = [
      root,
      allocation.path,
      artifact_root,
      to_string(allocation.id),
      token,
      allocation.job.branch_name
    ]

    expected_path = Path.join(artifact_root, "allocation-#{allocation.id}-#{token}")
    {command, command_args} = command(args)

    with {output, 0} <-
           System.cmd(command, command_args,
             env: CommandEnvironment.scrub(),
             stderr_to_stdout: true
           ),
         {:ok, result} <- decode(output, expected_path),
         :ok <- seal(artifact_root, expected_path) do
      {:ok, result}
    else
      {:error, _reason} = error -> error
      {_output, 2} -> {:error, :invalid_worktree_preservation_target}
      {_output, _status} -> {:error, :worktree_preservation_failed}
    end
  rescue
    _error -> {:error, :worktree_preservation_unavailable}
  end

  def preserve(_allocation, _token), do: {:error, :invalid_worktree_preservation_context}

  defp command(args) do
    case Application.get_env(:ptc_manager, :herdr_run_as_user) do
      user when is_binary(user) and user != "" ->
        CommandEnvironment.command(
          "/usr/local/bin/ptc-manager-worker-worktree-preserve",
          args,
          user
        )

      _user ->
        {"/usr/bin/python3",
         ["-I", Application.app_dir(:ptc_manager, "priv/worktree_preserve.py") | args]}
    end
  end

  defp seal(root, path) do
    {command, args} = seal_command([root, path])

    case System.cmd(command, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:worktree_preservation_seal_failed, status, String.slice(output, 0, 500)}}
    end
  end

  defp seal_command(args) do
    case Application.get_env(:ptc_manager, :herdr_run_as_user) do
      user when is_binary(user) and user != "" ->
        CommandEnvironment.command(
          "/usr/local/bin/ptc-manager-worker-worktree-seal",
          args,
          "root"
        )

      _user ->
        {"/usr/bin/python3",
         ["-I", Application.app_dir(:ptc_manager, "priv/worktree_seal.py") | args]}
    end
  end

  defp decode(output, expected_path) do
    with {:ok, value} <- Jason.decode(output),
         %{
           "artifact_path" => path,
           "bundle_sha256" => bundle,
           "patch_sha256" => patch,
           "head_sha" => head,
           "tree_sha" => tree
         } <- value,
         true <- path == expected_path,
         true <- Enum.all?([bundle, patch, head, tree], &Regex.match?(@sha, &1)) do
      {:ok,
       %{
         preserved_artifact_path: path,
         preserved_bundle_sha256: bundle,
         preserved_patch_sha256: patch,
         preserved_head_sha: head,
         preserved_tree_sha: tree
       }}
    else
      _invalid -> {:error, :invalid_worktree_preservation_result}
    end
  end

  defp default_artifact_root do
    if Application.get_env(:ptc_manager, :herdr_run_as_user) in [nil, ""],
      do: Path.join(System.tmp_dir!(), "ptc-manager-retained"),
      else: "/var/lib/ptc_manager-worker/retained"
  end
end
