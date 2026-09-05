defmodule PtcManager.TestSourceUpdater do
  @moduledoc false

  def refresh(repository) do
    path = repository.local_path || System.tmp_dir!()
    remote_ref = "refs/remotes/origin/#{repository.default_branch}"
    branch_ref = "refs/heads/#{repository.default_branch}"

    sha =
      case System.cmd("git", ["-C", path, "rev-parse", branch_ref], stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        {_output, _status} -> String.duplicate("a", 40)
      end

    ref = if revision?(path, remote_ref), do: remote_ref, else: branch_ref
    {:ok, %{path: path, sha: sha, ref: ref}}
  rescue
    _error ->
      {:ok,
       %{
         path: repository.local_path || System.tmp_dir!(),
         sha: String.duplicate("a", 40),
         ref: "refs/remotes/origin/main"
       }}
  end

  defp revision?(path, ref) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", path, "rev-parse", "--verify", ref], stderr_to_stdout: true)
    )
  end
end
