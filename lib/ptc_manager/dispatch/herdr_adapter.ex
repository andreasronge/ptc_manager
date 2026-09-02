defmodule PtcManager.Dispatch.HerdrAdapter do
  @moduledoc "Creates an isolated Herdr worktree and starts a named implementation agent."

  @behaviour PtcManager.Dispatch.Adapter

  alias PtcManager.Herdr.Command
  alias PtcManager.Automations
  alias PtcManager.Gateway
  alias PtcManager.CommandEnvironment
  alias PtcManager.Repository.Checkout
  alias PtcManager.Repository.WorkspaceSetup
  alias PtcManager.ReviewPolicy
  alias PtcManager.WorktreeSecurity

  @agent_start_command_grace_ms 5_000
  @agent_action_command_grace_ms 5_000

  @impl true
  def dispatch(context), do: dispatch(context, [])

  @doc false
  def dispatch(%{job: job, issue: issue, repository: repository}, opts) when is_list(opts) do
    command = Keyword.get(opts, :command, Command)

    with :ok <- enabled?(),
         {:ok, path} <- repository_path(repository) do
      dispatch_external(path, repository, job, issue, command)
    else
      {:error, reason} -> {:error, {:safe, reason}}
    end
  end

  @impl true
  def remove_worktree(allocation), do: remove_worktree(allocation, [])

  @doc false
  def remove_worktree(%{herdr_workspace: workspace} = allocation, opts)
      when is_binary(workspace) and is_list(opts) do
    args = remove_worktree_args(allocation)
    command = Keyword.get(opts, :command, Command)

    case run_with(command, args) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        if worktree_missing?(allocation), do: :ok, else: {:error, reason}
    end
  end

  def remove_worktree(_allocation, _opts), do: {:error, :worktree_workspace_missing}

  @doc "Starts a named Herdr agent in a fresh worktree rooted at an imported PR head."
  def start_pull_request_action(action, publication, repository) do
    with :ok <- enabled?(),
         {:ok, repository_path} <- repository_path(repository),
         :ok <- valid_external_pr_context(action, publication, repository),
         {:ok, worktree_path} <- pull_request_worktree_path(repository, action, publication),
         {:ok, ref} <- fetch_pull_request_head(repository_path, action, publication, repository) do
      try do
        create_pull_request_action(action, publication, repository_path, worktree_path, ref)
      after
        _ = delete_temporary_ref(repository_path, ref)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_pull_request_action(action, publication, repository_path, worktree_path, ref) do
    with {:ok, created} <-
           run([
             "worktree",
             "create",
             "--cwd",
             repository_path,
             "--branch",
             pull_request_branch(action, publication),
             "--base",
             ref,
             "--path",
             worktree_path,
             "--label",
             "pr-#{publication.pr_number}",
             "--no-focus"
           ]),
         {:ok, workspace_id, pane_id} <- decode_worktree(created) do
      agent_name = pull_request_agent_name(action, publication)

      case PtcManager.ManagedOperationContext.prepare_action(Command, pane_id, action) do
        {:ok, _context} ->
          start_pull_request_agent(workspace_id, pane_id, agent_name, worktree_path)

        {:error, reason} ->
          _ = remove_action_workspace(workspace_id)
          {:error, reason}
      end
    end
  end

  defp start_pull_request_agent(workspace_id, pane_id, agent_name, worktree_path) do
    case start_agent(agent_name, pane_id) do
      {:ok, agent_key} ->
        session = Application.get_env(:ptc_manager, :herdr_session, "default")

        {:ok,
         %{
           workspace_id: workspace_id,
           pane_id: pane_id,
           session: session,
           external_key: "#{session}:#{agent_key}",
           agent_name: agent_name,
           worktree_path: worktree_path,
           worker_key: "herdr:#{session}"
         }}

      {:error, reason} ->
        _ = remove_action_workspace(workspace_id)
        {:error, reason}
    end
  end

  @doc "Waits for a PR action turn to settle while keeping its Herdr session alive."
  def prompt_pull_request_action(agent_name, prompt)
      when is_binary(agent_name) and is_binary(prompt) do
    timeout = Application.get_env(:ptc_manager, :agent_action_timeout_ms, 7_200_000)

    run(
      [
        "agent",
        "prompt",
        agent_name,
        prompt,
        "--wait",
        "--until",
        "idle",
        "--until",
        "done",
        "--until",
        "blocked",
        "--timeout",
        Integer.to_string(timeout)
      ],
      timeout + @agent_action_command_grace_ms
    )
  end

  @doc "Returns the exact local commit produced by a PR-action agent."
  def pull_request_action_head(worktree_path) when is_binary(worktree_path) do
    with {:ok, head} <- capture_git(["-C", worktree_path, "rev-parse", "HEAD"]),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, head) do
      {:ok, head}
    else
      false -> {:error, :invalid_pull_request_action_head}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Validates the private root before an imported-PR action is claimed."
  def validate_pull_request_worktree_root(repository) do
    with {:ok, root} <- pull_request_worktree_root(repository) do
      WorktreeSecurity.validate_configured_root(root)
    end
  end

  @doc "Removes a retained PR-action workspace after its PR is terminal."
  def remove_action_workspace(workspace) when is_binary(workspace) and workspace != "" do
    case run(["worktree", "remove", "--workspace", workspace, "--force"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def remove_worktree_args(%{herdr_workspace: workspace} = allocation) do
    ["worktree", "remove", "--workspace", workspace] ++
      if(terminal_pull_request?(allocation), do: ["--force"], else: [])
  end

  defp dispatch_external(path, repository, job, issue, command) do
    started = System.monotonic_time(:millisecond)

    with {:ok, created} <- create_worktree(command, path, repository, job),
         {:ok, workspace_id, pane_id} <- decode_worktree(created) do
      worktree_duration_ms = max(System.monotonic_time(:millisecond) - started, 0)
      setup = Application.get_env(:ptc_manager, :workspace_setup, WorkspaceSetup)

      case Gateway.call(setup, :run, [job.worktree_allocation.path, job]) do
        {:ok, report} ->
          report =
            report
            |> Map.put(:worktree_created_duration_ms, worktree_duration_ms)
            |> Map.put(:workspace_id, workspace_id)

          start_implementation_agent(command, workspace_id, pane_id, job, issue, report)

        {:error, report} when is_map(report) ->
          report =
            report
            |> Map.put(:worktree_created_duration_ms, worktree_duration_ms)
            |> Map.put(:workspace_id, workspace_id)

          case remove_action_workspace_with(command, workspace_id) do
            :ok ->
              {:error, {:safe, {:workspace_setup_failed, report}}}

            {:error, reason} ->
              {:error, {:uncertain, {:workspace_setup_cleanup_failed, reason, report}}}
          end

        {:error, reason} ->
          {:error, {:uncertain, reason}}

        other ->
          {:error, {:uncertain, {:unexpected_workspace_setup_result, other}}}
      end
    else
      {:error, reason} -> {:error, {:uncertain, reason}}
    end
  end

  defp start_implementation_agent(command, workspace_id, pane_id, job, issue, setup_report) do
    agent_name = agent_name(job)

    with {:ok, _context} <-
           PtcManager.ManagedOperationContext.prepare_job(command, pane_id, job),
         {:ok, agent_key} <- start_agent(command, agent_name, pane_id),
         :ok <- prompt_agent(command, agent_name, issue, job) do
      session = Application.get_env(:ptc_manager, :herdr_session, "default")

      {:ok,
       %{
         workspace_id: workspace_id,
         pane_id: pane_id,
         session: session,
         external_key: "#{session}:#{agent_key}",
         agent_name: agent_name,
         worktree_path: job.worktree_allocation.path,
         agent_kind: job.worktree_allocation.agent_kind,
         workspace_setup: setup_report
       }}
    else
      {:error, reason} ->
        {:error, {:uncertain, {:agent_launch_after_workspace_setup, reason, setup_report}}}
    end
  end

  @doc false
  def decode_worktree(output) do
    with {:ok, decoded} <- Jason.decode(output),
         workspace_id when is_binary(workspace_id) <-
           get_in(decoded, ["result", "workspace", "workspace_id"]),
         pane_id when is_binary(pane_id) <- get_in(decoded, ["result", "root_pane", "pane_id"]) do
      {:ok, workspace_id, pane_id}
    else
      _ -> {:error, :unexpected_herdr_worktree_response}
    end
  end

  defp enabled? do
    cond do
      not Application.get_env(:ptc_manager, :dispatch_enabled, false) ->
        {:error, :dispatch_disabled}

      true ->
        :ok
    end
  end

  defp repository_path(repository) do
    Checkout.available_path(repository)
  end

  defp create_worktree(command, path, repository, job) do
    args = [
      "worktree",
      "create",
      "--cwd",
      path,
      "--branch",
      job.branch_name,
      "--base",
      repository.default_branch,
      "--path",
      job.worktree_allocation.path,
      "--label",
      "issue-#{job.issue.number}",
      "--no-focus"
    ]

    case run_with(command, args) do
      {:ok, _output} = created ->
        created

      {:error, create_error} ->
        with {:ok, base_sha} <- capture_git(["-C", path, "rev-parse", repository.default_branch]) do
          adopt_created_worktree(command, path, job, base_sha, create_error)
        end
    end
  end

  defp adopt_created_worktree(command, repository_path, job, base_sha, create_error) do
    worktree_path = job.worktree_allocation.path

    with :ok <-
           exact_created_worktree(
             repository_path,
             worktree_path,
             job.branch_name,
             base_sha
           ),
         {:ok, output} <-
           run_with(command, [
             "worktree",
             "open",
             "--cwd",
             repository_path,
             "--path",
             worktree_path,
             "--label",
             "issue-#{job.issue.number}",
             "--no-focus"
           ]) do
      {:ok, output}
    else
      {:error, recovery_error} ->
        {:error, {:worktree_create_unconfirmed, create_error, recovery_error}}
    end
  end

  defp exact_created_worktree(repository_path, path, branch, base_sha) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, repository_common_dir} <-
           capture_git([
             "-C",
             repository_path,
             "rev-parse",
             "--path-format=absolute",
             "--git-common-dir"
           ]),
         {:ok, ^repository_common_dir} <-
           capture_git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, ^path} <-
           capture_git(["-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel"]),
         {:ok, ^branch} <- capture_git(["-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"]),
         {:ok, ^base_sha} <- capture_git(["-C", path, "rev-parse", "HEAD"]),
         {:ok, ""} <-
           capture_git(["-C", path, "status", "--porcelain=v1", "--untracked-files=all"]) do
      :ok
    else
      {:ok, %{type: :symlink}} -> {:error, :unsafe_worktree_symlink}
      {:ok, _other} -> {:error, :worktree_create_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pull_request_head(repository_path, action, publication, repository) do
    ref =
      "refs/ptc-manager/pull-request-actions/#{publication.id}/#{action.id}/#{action.attempt_count}"

    remote =
      "https://github.com/#{repository.github_owner}/#{repository.github_name}.git"

    result =
      with :ok <-
             run_git([
               "-C",
               repository_path,
               "fetch",
               "--no-tags",
               remote,
               "+refs/pull/#{publication.pr_number}/head:#{ref}"
             ]),
           {:ok, fetched_head} <- capture_git(["-C", repository_path, "rev-parse", ref]),
           true <- fetched_head == action.target_snapshot["head_sha"] do
        {:ok, ref}
      else
        false -> {:error, :external_pull_request_version_changed}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, ^ref} = fetched ->
        fetched

      {:error, _reason} = error ->
        _ = delete_temporary_ref(repository_path, ref)
        error
    end
  end

  defp delete_temporary_ref(repository_path, ref),
    do: run_git(["-C", repository_path, "update-ref", "-d", ref])

  defp pull_request_worktree_path(repository, action, publication) do
    with {:ok, root} <- pull_request_worktree_root(repository),
         :ok <- WorktreeSecurity.validate_configured_root(root) do
      {:ok,
       Path.join(
         Path.expand(root),
         Checkout.external_worktree_name(
           repository,
           publication.pr_number,
           action.id,
           action.attempt_count
         )
       )}
    end
  end

  defp pull_request_worktree_root(_repository) do
    root = Application.get_env(:ptc_manager, :worktree_root)

    case is_binary(root) and Path.type(root) == :absolute do
      true -> {:ok, root}
      false -> {:error, :worktree_root_unavailable}
    end
  end

  defp valid_external_pr_context(action, publication, repository) do
    sha = action.target_snapshot["head_sha"]
    repo = "#{repository.github_owner}/#{repository.github_name}"

    cond do
      publication.pr_state != "open" ->
        {:error, :pull_request_not_open}

      publication.head_repository != repo ->
        {:error, :fork_pull_request_repair_not_supported}

      not (is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)) ->
        {:error, :external_pull_request_version_unavailable}

      true ->
        :ok
    end
  end

  defp pull_request_branch(action, publication),
    do: "ptc-manager/repair-pr-#{publication.pr_number}-action-#{action.id}"

  defp pull_request_agent_name(action, publication) do
    prefix = if action.action_key == "repair_and_merge_pr", do: "merge", else: "repair"
    "#{prefix}_pr#{publication.pr_number}_a#{action.id}_f#{action.attempt_count}"
  end

  defp run_git(args) do
    case git_command(args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_command_failed, status, bounded(output)}}
    end
  end

  defp capture_git(args) do
    case git_command(args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_command_failed, status, bounded(output)}}
    end
  end

  @doc false
  def git_command(args) do
    {command, command_args} = git_command_spec(args)

    System.cmd(command, command_args,
      env: CommandEnvironment.scrub(),
      stderr_to_stdout: true
    )
  rescue
    error -> {inspect(error.__struct__), 127}
  end

  @doc false
  def git_command_spec(args) do
    binary =
      Application.get_env(
        :ptc_manager,
        :herdr_git_binary,
        Application.get_env(:ptc_manager, :git_binary, "git")
      )

    CommandEnvironment.command(
      binary,
      args,
      Application.get_env(:ptc_manager, :herdr_run_as_user)
    )
  end

  defp start_agent(name, pane_id), do: start_agent(Command, name, pane_id)

  defp start_agent(command, name, pane_id) do
    kind = Application.get_env(:ptc_manager, :implementation_agent_kind, "codex")

    agent_args =
      Application.get_env(:ptc_manager, :implementation_agent_args, [
        "--dangerously-bypass-approvals-and-sandbox"
      ])

    timeout = Application.get_env(:ptc_manager, :implementation_agent_start_timeout_ms, 120_000)
    command_timeout = timeout + @agent_start_command_grace_ms

    case run_with(
           command,
           [
             "agent",
             "start",
             name,
             "--kind",
             kind,
             "--pane",
             pane_id,
             "--timeout",
             to_string(timeout),
             "--" | agent_args
           ],
           command_timeout
         ) do
      {:ok, output} -> {:ok, decode_agent_key(output, pane_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_agent_key(output, fallback) do
    with {:ok, decoded} <- Jason.decode(output),
         value when is_binary(value) <-
           get_in(decoded, ["result", "agent", "agent_session", "value"]) do
      value
    else
      _ -> fallback
    end
  end

  defp prompt_agent(command, name, issue, job) do
    case run_with(command, ["agent", "prompt", name, build_prompt(job.repository, issue, job)]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def build_prompt(repository, issue, job) do
    required_reviews = ReviewPolicy.job_count(job, repository)

    github_instruction =
      if job.publication_source == "agent" do
        "Read the issue, its comments, linked issues, and relevant pull requests as needed. Push this branch and create a pull request. Do not merge."
      else
        "Read the issue, its comments, linked issues, and relevant pull requests as needed. Commit the result locally; PtcManager will publish it. Do not push, create a pull request, or merge."
      end

    context =
      """
      <context>
      Repository: #{repository.github_owner}/#{repository.github_name}
      Issue: ##{issue.number}
      Branch: #{job.branch_name} → #{repository.default_branch}
      Reviews: #{required_reviews}
      GitHub: #{github_instruction}
      Expensive commands: when PTC_OPERATION_WRAPPER is set, run it as `\$PTC_OPERATION_WRAPPER run --label <build|test|lint|verify> -- <command>`; otherwise run the command directly.
      </context>
      <issue_data>
      Number: #{issue.number}
      Title: #{issue.title}
      Body:
      #{String.slice(issue.body || "", 0, 20_000)}
      </issue_data>
      """

    Automations.compose_prompt(job.prompt_instructions, context)
  end

  defp agent_name(job), do: "impl_j#{job.id}_f#{job.fencing_token}"

  defp terminal_pull_request?(%{
         job: %{state: job_state, pr_publication: %{pr_state: pr_state}}
       })
       when job_state in ["done", "cancelled"] and pr_state in ["merged", "closed"],
       do: true

  defp terminal_pull_request?(_allocation), do: false

  defp worktree_missing?(%{path: path}) when is_binary(path), do: not File.exists?(path)
  defp worktree_missing?(_allocation), do: false

  defp run(args, timeout \\ nil), do: Command.run(args, timeout)
  defp run_with(command, args, timeout \\ nil), do: Gateway.call(command, :run, [args, timeout])

  defp remove_action_workspace_with(command, workspace) do
    case run_with(command, ["worktree", "remove", "--workspace", workspace, "--force"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
