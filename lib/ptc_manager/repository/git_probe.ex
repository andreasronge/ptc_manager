defmodule PtcManager.Repository.GitProbe do
  @moduledoc "Read-only, bounded Git plumbing used to verify an implementation branch."

  @behaviour PtcManager.Repository.ResultProbe

  alias PtcManager.Operations.{Job, Repository}

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @small_output_limit 64 * 1024

  @doc "Reads the bounded repository contract from an immutable commit."
  def repository_contract(path, sha) when is_binary(path) and is_binary(sha) do
    cond do
      Path.type(path) != :absolute or not File.dir?(path) ->
        {:error, :worktree_path_unavailable}

      not Regex.match?(@sha, sha) ->
        {:error, :invalid_sha}

      true ->
        case run_git(path, ["show", "#{sha}:.ptc-manager.yml"], {:collect, @small_output_limit}) do
          {:ok, content} -> {:ok, content}
          {:error, {:git_failed, "show", _status}} -> {:error, :repository_contract_missing}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def repository_contract(_path, _sha), do: {:error, :invalid_repository_contract_context}

  @impl true
  def verify(%Repository{} = repository, %Job{} = job) do
    with {:ok, path} <- repository_path(repository) do
      verify_at(repository, job, path)
    end
  end

  @doc false
  def verify_at(%Repository{} = repository, %Job{} = job, path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and File.dir?(path),
         :ok <- valid_branch(job),
         {:ok, head_sha} <- revision(path, "refs/heads/#{job.branch_name}^{commit}"),
         {:ok, base_ref} <- base_ref(path, repository.default_branch),
         {:ok, base_sha} <- merge_base(path, base_ref, head_sha) do
      verify_range(path, base_sha, head_sha)
    else
      false -> {:error, :repository_path_unavailable}
      error -> error
    end
  end

  @doc "Verifies a repair against the immutable base commit reported by GitHub."
  def verify_repair_at(%Repository{}, %Job{} = job, path, github_base_sha)
      when is_binary(path) and is_binary(github_base_sha) do
    with true <- Path.type(path) == :absolute and File.dir?(path),
         true <- Regex.match?(@sha, github_base_sha),
         :ok <- valid_branch(job),
         {:ok, head_sha} <- revision(path, "refs/heads/#{job.branch_name}^{commit}"),
         :ok <- exact_base_available(path, github_base_sha),
         {:ok, base_sha} <- merge_base(path, github_base_sha, head_sha) do
      verify_range(path, base_sha, head_sha)
    else
      false -> {:error, :invalid_repair_base}
      error -> error
    end
  end

  def verify_repair_at(_repository, _job, _path, _github_base_sha),
    do: {:error, :invalid_repair_base}

  @doc "Reads HEAD only when the retained worktree is still on the job branch."
  def current_job_head(path, %Job{branch_name: branch} = job)
      when is_binary(path) and is_binary(branch) do
    with true <- Path.type(path) == :absolute and File.dir?(path),
         :ok <- valid_branch(job),
         {:ok, ^branch} <- git(path, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         {:ok, head_sha} <- revision(path, "HEAD^{commit}") do
      {:ok, head_sha}
    else
      false -> {:error, :worktree_path_unavailable}
      {:ok, _other_branch} -> {:error, :unexpected_branch}
      error -> error
    end
  end

  def current_job_head(_path, _job), do: {:error, :unexpected_branch}

  defp exact_base_available(path, expected_sha) do
    case revision(path, "#{expected_sha}^{commit}") do
      {:ok, ^expected_sha} -> :ok
      {:ok, _other_sha} -> {:error, :invalid_repair_base}
      {:error, :branch_missing} -> {:error, :repair_base_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_range(path, base_sha, head_sha) do
    with {:ok, commit_count} <- commit_count(path, base_sha, head_sha),
         :ok <- has_commits(commit_count),
         {:ok, changed_paths} <- changed_paths(path, base_sha, head_sha),
         :ok <- within_path_limit(changed_paths),
         :ok <- within_blob_budget(path, base_sha, head_sha, changed_paths),
         {:ok, diff_digest} <- diff_digest(path, base_sha, head_sha) do
      {:ok,
       %{
         base_sha: base_sha,
         head_sha: head_sha,
         diff_digest: diff_digest,
         commit_count: commit_count
       }}
    end
  end

  @doc "Proves that a worktree is clean, on the expected branch, and at the verified PR head."
  def reclaimable(path, branch, expected_head)
      when is_binary(path) and is_binary(branch) and is_binary(expected_head) do
    with true <- Path.type(path) == :absolute and File.dir?(path),
         {:ok, ^branch} <- git(path, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         {:ok, ^expected_head} <- revision(path, "HEAD^{commit}"),
         {:ok, ""} <- git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) do
      :ok
    else
      false -> {:error, :worktree_path_unavailable}
      {:ok, _other} -> {:error, :worktree_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def reclaimable(_path, _branch, _expected_head), do: {:error, :invalid_worktree_identity}

  @doc "Proves that a repaired head preserves the already-published PR history."
  def descendant?(path, ancestor, head)
      when is_binary(path) and is_binary(ancestor) and is_binary(head) do
    cond do
      Path.type(path) != :absolute or not File.dir?(path) ->
        {:error, :worktree_path_unavailable}

      not Regex.match?(@sha, ancestor) or not Regex.match?(@sha, head) ->
        {:error, :invalid_sha}

      true ->
        case run_git(path, ["merge-base", "--is-ancestor", ancestor, head], {:collect, 1_024}) do
          {:ok, _output} -> :ok
          {:error, {:git_failed, "merge-base", 1}} -> {:error, :repair_not_fast_forward}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def descendant?(_path, _ancestor, _head), do: {:error, :invalid_sha}

  defp repository_path(repository) do
    path = Application.get_env(:ptc_manager, :repository_path) || repository.local_path

    if is_binary(path) and File.dir?(path),
      do: {:ok, Path.expand(path)},
      else: {:error, :repository_path_unavailable}
  end

  defp valid_branch(%Job{id: id, issue_id: issue_id, branch_name: branch})
       when is_binary(branch) and is_integer(id) and is_integer(issue_id) do
    if Regex.match?(~r/\Aptc-manager\/issue-\d+-job-#{id}\z/, branch),
      do: :ok,
      else: {:error, :unexpected_branch}
  end

  defp valid_branch(_job), do: {:error, :unexpected_branch}

  defp base_ref(path, branch) when is_binary(branch) do
    candidates = ["refs/remotes/origin/#{branch}^{commit}", "refs/heads/#{branch}^{commit}"]

    Enum.find_value(candidates, {:error, :base_branch_missing}, fn candidate ->
      case revision(path, candidate) do
        {:ok, _sha} -> {:ok, candidate}
        {:error, _reason} -> false
      end
    end)
  end

  defp merge_base(path, base_ref, head_sha) do
    with {:ok, output} <- git(path, ["merge-base", base_ref, head_sha]),
         true <- Regex.match?(@sha, output) do
      {:ok, output}
    else
      false -> {:error, :invalid_merge_base}
      {:error, _reason} -> {:error, :unrelated_branch}
    end
  end

  defp revision(path, revision) do
    case git(path, ["rev-parse", "--verify", revision]) do
      {:ok, output} ->
        if Regex.match?(@sha, output), do: {:ok, output}, else: {:error, :invalid_sha}

      {:error, _reason} ->
        {:error, :branch_missing}
    end
  end

  defp commit_count(path, base_sha, head_sha) do
    case git(path, ["rev-list", "--count", "#{base_sha}..#{head_sha}"]) do
      {:ok, output} ->
        case Integer.parse(output) do
          {count, ""} -> {:ok, count}
          _ -> {:error, :invalid_commit_count}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp has_commits(count) when count <= 0, do: {:error, :no_commits}

  defp has_commits(count) do
    if count <= max_commits(), do: :ok, else: {:error, :too_many_commits}
  end

  defp changed_paths(path, base_sha, head_sha) do
    case run_git(
           path,
           ["diff", "--raw", "-z", "--no-renames", "#{base_sha}..#{head_sha}"],
           {:collect, @small_output_limit}
         ) do
      {:ok, ""} -> {:error, :no_tree_changes}
      {:ok, output} -> parse_changed_paths(output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_changed_paths(output) do
    records = :binary.split(output, <<0>>, [:global]) |> Enum.reject(&(&1 == ""))

    records
    |> Enum.chunk_every(2)
    |> Enum.reduce_while({:ok, []}, fn
      [header, path], {:ok, paths} ->
        if Regex.match?(~r/\A:[0-7]{6} [0-7]{6} [0-9a-f]+ [0-9a-f]+ [A-Z]+\z/, header),
          do: {:cont, {:ok, [path | paths]}},
          else: {:halt, {:error, :invalid_raw_diff}}

      _record, _paths ->
        {:halt, {:error, :invalid_raw_diff}}
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp within_path_limit(paths) do
    if length(paths) <= max_changed_paths(),
      do: :ok,
      else: {:error, :too_many_changed_paths}
  end

  defp within_blob_budget(path, base_sha, head_sha, changed_paths) do
    with {:ok, base_sizes} <- tree_blob_sizes(path, base_sha, changed_paths),
         {:ok, head_sizes} <- tree_blob_sizes(path, head_sha, changed_paths) do
      sizes = base_sizes ++ head_sizes

      cond do
        Enum.any?(sizes, &(&1 > max_blob_bytes())) -> {:error, :git_blob_too_large}
        Enum.sum(sizes) > max_total_blob_bytes() -> {:error, :git_blob_budget_exceeded}
        true -> :ok
      end
    end
  end

  defp tree_blob_sizes(path, revision, changed_paths) do
    args = ["ls-tree", "-rlz", revision, "--" | changed_paths]

    case run_git(path, args, {:collect, @small_output_limit}) do
      {:ok, output} -> parse_tree_sizes(output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_tree_sizes(output) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, sizes} ->
      case :binary.split(record, "\t") do
        [metadata, _path] ->
          case String.split(metadata, " ", trim: true) do
            [_mode, "blob", _sha, size] ->
              case Integer.parse(size) do
                {size, ""} -> {:cont, {:ok, [size | sizes]}}
                _invalid -> {:halt, {:error, :invalid_tree_size}}
              end

            # Submodule entries have no blob payload to include in the budget.
            [_mode, "commit", _sha, "-"] ->
              {:cont, {:ok, sizes}}

            _invalid ->
              {:halt, {:error, :invalid_tree_size}}
          end

        _invalid ->
          {:halt, {:error, :invalid_tree_size}}
      end
    end)
  end

  defp diff_digest(path, base_sha, head_sha) do
    args = [
      "diff",
      "--binary",
      "--no-renames",
      "--no-ext-diff",
      "--no-textconv",
      "#{base_sha}..#{head_sha}"
    ]

    case run_git(path, args, {:digest, diff_limit()}) do
      {:ok, %{bytes: 0}} -> {:error, :no_tree_changes}
      {:ok, %{digest: digest}} -> {:ok, Base.encode16(digest, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(path, args) do
    case run_git(path, args, {:collect, @small_output_limit}) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp run_git(path, args, mode) do
    binary = Application.get_env(:ptc_manager, :git_binary, "git")
    {command, command_args} = command(binary, git_args(path, args))

    port =
      Port.open(
        {:spawn_executable, command},
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: command_args, cd: "/"]
      )

    deadline = System.monotonic_time(:millisecond) + port_timeout_ms()
    receive_port(port, List.first(args), mode_state(mode), deadline)
  rescue
    _error -> {:error, :git_unavailable}
  end

  defp receive_port(port, operation, state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case consume(state, data) do
          {:ok, next_state} -> receive_port(port, operation, next_state, deadline)
          {:error, reason} -> close_port(port, reason)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, finish(state)}

      {^port, {:exit_status, status}} ->
        {:error, {:git_failed, operation, status}}
    after
      remaining -> close_port(port, :git_timeout)
    end
  end

  defp mode_state({:collect, limit}), do: {:collect, limit, ""}
  defp mode_state({:digest, limit}), do: {:digest, limit, 0, :crypto.hash_init(:sha256)}

  defp consume({:collect, limit, output}, data) do
    if byte_size(output) + byte_size(data) <= limit,
      do: {:ok, {:collect, limit, output <> data}},
      else: {:error, :git_output_too_large}
  end

  defp consume({:digest, limit, bytes, digest}, data) do
    next_bytes = bytes + byte_size(data)

    if next_bytes <= limit,
      do: {:ok, {:digest, limit, next_bytes, :crypto.hash_update(digest, data)}},
      else: {:error, :git_diff_too_large}
  end

  defp finish({:collect, _limit, output}), do: output

  defp finish({:digest, _limit, bytes, digest}),
    do: %{bytes: bytes, digest: :crypto.hash_final(digest)}

  defp close_port(port, reason) do
    Port.close(port)
    {:error, reason}
  rescue
    ArgumentError -> {:error, reason}
  end

  defp git_args(path, args) do
    [
      "-C",
      path,
      "--no-optional-locks",
      "-c",
      "safe.directory=#{path}",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false"
      | args
    ]
  end

  @doc false
  def command(binary, git_args) do
    git = ["/bin/sh", "-c", ~s(exec "$@" 2>/dev/null), "ptc-manager-git", binary | git_args]

    timed =
      case Application.get_env(:ptc_manager, :git_timeout_binary) do
        timeout_binary when is_binary(timeout_binary) and timeout_binary != "" ->
          [
            timeout_binary,
            "--signal=TERM",
            "--kill-after=2s",
            timeout_duration()
            | git
          ]

        _timeout_binary ->
          git
      end

    executable =
      case Application.get_env(:ptc_manager, :git_memory_limit_binary) do
        limit_binary when is_binary(limit_binary) and limit_binary != "" ->
          [limit_binary, "--as=#{memory_limit_bytes()}", "--" | timed]

        _limit_binary ->
          timed
      end

    verifier_home =
      Application.get_env(:ptc_manager, :git_verifier_home) || System.tmp_dir!()

    environment = [
      "-i",
      "HOME=#{verifier_home}",
      "PATH=/usr/bin:/bin",
      "LC_ALL=C",
      "GIT_CONFIG_NOSYSTEM=1",
      "GIT_NO_REPLACE_OBJECTS=1",
      "GIT_LITERAL_PATHSPECS=1",
      "GIT_TERMINAL_PROMPT=0"
      | executable
    ]

    case Application.get_env(:ptc_manager, :git_run_as_user) do
      user when is_binary(user) and user != "" ->
        {"/usr/bin/sudo", ["-n", "-H", "-u", user, "--", "/usr/bin/env" | environment]}

      _user ->
        {"/usr/bin/env", environment}
    end
  end

  defp timeout_ms, do: Application.get_env(:ptc_manager, :git_timeout_ms, 15_000)

  @doc false
  def timeout_duration, do: "#{timeout_ms() / 1_000}s"

  defp port_timeout_ms, do: timeout_ms() + 2_500
  defp diff_limit, do: Application.get_env(:ptc_manager, :git_diff_max_bytes, 50_000_000)
  defp max_commits, do: Application.get_env(:ptc_manager, :git_max_commits, 100)
  defp max_changed_paths, do: Application.get_env(:ptc_manager, :git_max_changed_paths, 100)
  defp max_blob_bytes, do: Application.get_env(:ptc_manager, :git_max_blob_bytes, 10_000_000)

  defp max_total_blob_bytes,
    do: Application.get_env(:ptc_manager, :git_max_total_blob_bytes, 50_000_000)

  defp memory_limit_bytes,
    do: Application.get_env(:ptc_manager, :git_memory_limit_bytes, 268_435_456)
end
