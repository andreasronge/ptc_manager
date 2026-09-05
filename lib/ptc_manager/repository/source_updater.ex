defmodule PtcManager.Repository.SourceUpdater do
  @moduledoc "Fetches and pins a repository's current remote default-branch commit."

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.{Checkout, WorkerGit}

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def refresh(%Repository{} = repository, opts \\ []) when is_list(opts) do
    with {:ok, path} <- Checkout.available_path(repository) do
      refresh(repository, path, opts)
    end
  end

  def refresh(%Repository{} = repository, path, opts)
      when is_binary(path) and is_list(opts) do
    lock_id = {{__MODULE__, Path.expand(path)}, self()}

    case :global.trans(lock_id, fn -> do_refresh(repository, path, opts) end) do
      :aborted -> {:error, :repository_source_refresh_lock_failed}
      {:aborted, reason} -> {:error, {:repository_source_refresh_lock_failed, reason}}
      result -> result
    end
  end

  defp do_refresh(repository, path, opts) do
    branch = repository.default_branch
    remote_ref = "refs/remotes/origin/#{branch}"
    branch_ref = "refs/heads/#{branch}"
    remote = Keyword.get(opts, :remote, github_remote(repository))
    git = Keyword.get(opts, :git, WorkerGit)

    timeout_ms =
      Keyword.get(
        opts,
        :timeout_ms,
        Application.get_env(:ptc_manager, :source_refresh_timeout_ms, 60_000)
      )

    with :ok <- valid_ref(git, branch_ref, timeout_ms),
         :ok <-
           run(
             git,
             [
               "-C",
               path,
               "--no-optional-locks",
               "-c",
               "core.hooksPath=/dev/null",
               "fetch",
               "--no-tags",
               "--no-write-fetch-head",
               "--",
               remote,
               "+#{branch_ref}:#{remote_ref}"
             ],
             timeout_ms
           ),
         {:ok, sha} <- revision(git, path, remote_ref, timeout_ms),
         true <- Regex.match?(@sha, sha) do
      {:ok, %{path: Path.expand(path), sha: sha, ref: remote_ref}}
    else
      false -> {:error, :repository_source_invalid_sha}
      {:error, _reason} = error -> error
    end
  end

  defp valid_ref(git, ref, timeout_ms) do
    run(git, ["check-ref-format", ref], timeout_ms)
  end

  defp revision(git, path, ref, timeout_ms) do
    case git.run(
           ["-C", path, "--no-optional-locks", "rev-parse", "--verify", "#{ref}^{commit}"],
           timeout_ms
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:repository_source_revision_failed, status, bounded(output)}}
    end
  end

  defp run(git, args, timeout_ms) do
    case git.run(args, timeout_ms) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:repository_source_fetch_failed, status, bounded(output)}}
    end
  end

  defp github_remote(repository) do
    "https://github.com/#{repository.github_owner}/#{repository.github_name}.git"
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
