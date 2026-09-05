defmodule PtcManager.Dispatch.HerdrAdapter do
  @moduledoc "Creates an isolated Herdr worktree and starts a named implementation agent."

  @behaviour PtcManager.Dispatch.Adapter

  alias PtcManager.Herdr.Command
  alias PtcManager.AgentProfiles
  alias PtcManager.Automations
  alias PtcManager.Gateway
  alias PtcManager.Operations.StopReport
  alias PtcManager.Repository.Checkout
  alias PtcManager.Repository.WorkerAgentLogin
  alias PtcManager.Repository.WorkerGit
  alias PtcManager.Repository.WorkerClaudeTrust
  alias PtcManager.Repository.WorkerCodexArming
  alias PtcManager.Repository.WorkspaceSetup
  alias PtcManager.ReviewPolicy
  alias PtcManager.WorktreeSecurity

  @agent_start_command_grace_ms 5_000
  @agent_action_command_grace_ms 5_000

  @impl true
  def dispatch(context), do: dispatch(context, [])

  @doc false
  def dispatch(%{job: job, issue: issue, repository: repository, source: source}, opts)
      when is_list(opts) do
    command = Keyword.get(opts, :command, Command)

    with :ok <- enabled?(),
         {:ok, path} <- repository_path(repository) do
      dispatch_external(path, source, job, issue, command)
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

    worktree_removal_result(run_with(command, args), allocation)
  end

  def remove_worktree(allocation, _opts) do
    if worktree_missing?(allocation), do: :ok, else: {:error, :worktree_workspace_missing}
  end

  @impl true
  def discard_worktree(allocation), do: discard_worktree(allocation, [])

  @doc false
  def discard_worktree(%{herdr_workspace: workspace} = allocation, opts)
      when is_binary(workspace) and workspace != "" and is_list(opts) do
    command = Keyword.get(opts, :command, Command)

    worktree_removal_result(
      run_with(command, ["worktree", "remove", "--workspace", workspace, "--force"]),
      allocation
    )
  end

  def discard_worktree(allocation, _opts), do: remove_worktree(allocation, [])

  defp worktree_removal_result({:ok, _output}, _allocation), do: :ok

  defp worktree_removal_result({:error, reason} = error, allocation) do
    cond do
      worktree_missing?(allocation) -> :ok
      forgotten_workspace?(error) -> {:error, :worktree_workspace_forgotten}
      true -> {:error, reason}
    end
  end

  # Herdr answers `workspace_not_found` once it has dropped the registration, a
  # restart being enough to reach that. Its half of the removal is then already
  # done and it can never finish the rest, because it no longer knows the
  # directory exists. Saying so separately lets the caller, which owns the
  # managed root, remove what Herdr left behind.
  defp forgotten_workspace?(error), do: action_workspace_removal_result(error) == :ok

  @doc "Starts a named Herdr agent in a fresh worktree rooted at an imported PR head."
  def start_pull_request_action(action, publication, repository) do
    with :ok <- enabled?(),
         {:ok, %{kind: kind}} <- action_agent_profile(action),
         {:ok, repository_path} <- repository_path(repository),
         :ok <- valid_external_pr_context(action, publication, repository),
         {:ok, worktree_path} <- pull_request_worktree_path(repository, action, publication),
         {:ok, ref} <- fetch_pull_request_head(repository_path, action, publication, repository) do
      try do
        create_pull_request_action(action, publication, repository_path, worktree_path, ref, kind)
      after
        _ = delete_temporary_ref(repository_path, ref)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp action_agent_profile(%{automation_definition_version: %{agent_selector: selector}}),
    do: AgentProfiles.select(selector)

  defp action_agent_profile(_action), do: {:error, :automation_version_missing}

  defp create_pull_request_action(action, publication, repository_path, worktree_path, ref, kind) do
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
          start_pull_request_agent(
            workspace_id,
            pane_id,
            agent_name,
            kind,
            repository_path,
            worktree_path
          )

        {:error, reason} ->
          _ = remove_action_workspace(workspace_id)
          {:error, reason}
      end
    end
  end

  defp start_pull_request_agent(
         workspace_id,
         pane_id,
         agent_name,
         kind,
         repository_path,
         worktree_path
       ) do
    case start_agent(Command, agent_name, pane_id, kind, repository_path, worktree_path) do
      {:ok, agent_key} ->
        session = Application.get_env(:ptc_manager, :herdr_session, "default")

        {:ok,
         %{
           workspace_id: workspace_id,
           pane_id: pane_id,
           session: session,
           external_key: "#{session}:#{agent_key}",
           agent_name: agent_name,
           agent_kind: kind,
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
    ["worktree", "remove", "--workspace", workspace, "--force"]
    |> run()
    |> action_workspace_removal_result()
  end

  @doc false
  def action_workspace_removal_result({:ok, _output}), do: :ok

  def action_workspace_removal_result({:error, {:herdr_exit, _status, output}} = error)
      when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"code" => "workspace_not_found"}}} -> :ok
      _other -> error
    end
  end

  def action_workspace_removal_result({:error, _reason} = error), do: error

  @doc "Reopens an existing action worktree so an interrupted creation can be cleaned up."
  def open_action_workspace(repository_path, path, label)
      when is_binary(repository_path) and is_binary(path) and is_binary(label) do
    with {:ok, output} <-
           run([
             "worktree",
             "open",
             "--cwd",
             repository_path,
             "--path",
             path,
             "--label",
             label,
             "--no-focus"
           ]),
         {:ok, workspace, _pane} <- decode_worktree(output) do
      {:ok, workspace}
    end
  end

  @doc false
  def remove_worktree_args(%{herdr_workspace: workspace} = allocation) do
    ["worktree", "remove", "--workspace", workspace] ++
      if(terminal_pull_request?(allocation), do: ["--force"], else: [])
  end

  defp dispatch_external(path, source, job, issue, command) do
    started = System.monotonic_time(:millisecond)

    with {:ok, created} <- create_worktree(command, path, source.sha, job),
         {:ok, workspace_id, pane_id} <- decode_worktree(created) do
      worktree_duration_ms = max(System.monotonic_time(:millisecond) - started, 0)
      setup = Application.get_env(:ptc_manager, :workspace_setup, WorkspaceSetup)

      case Gateway.call(setup, :run, [job.worktree_allocation.path, job]) do
        {:ok, report} ->
          report =
            report
            |> Map.put(:worktree_created_duration_ms, worktree_duration_ms)
            |> Map.put(:workspace_id, workspace_id)

          start_implementation_agent(command, path, workspace_id, pane_id, job, issue, report)

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
      {:error, {:safe, _reason} = safe} -> {:error, safe}
      {:error, reason} -> {:error, {:uncertain, reason}}
    end
  end

  defp start_implementation_agent(
         command,
         repository_path,
         workspace_id,
         pane_id,
         job,
         issue,
         setup_report
       ) do
    agent_name = agent_name(job)
    worktree_path = job.worktree_allocation.path

    # The agent needs its stop contract in place before it can read the prompt
    # that names it. A failure here leaves it with no structured way to stop,
    # which is only the behaviour that existed before the contract.
    job =
      case PtcManager.Operations.issue_stop_report_token(job) do
        {:ok, issued} ->
          _ = StopReport.prepare(issued)
          %{issued | worktree_allocation: job.worktree_allocation, issue: job.issue}

        {:error, _reason} ->
          job
      end

    with {:ok, _context} <-
           PtcManager.ManagedOperationContext.prepare_job(command, pane_id, job),
         {:ok, agent_key} <-
           start_agent(
             command,
             agent_name,
             pane_id,
             job.worktree_allocation.agent_kind,
             repository_path,
             worktree_path,
             job.execution_settings
           ),
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

  defp create_worktree(command, path, base_sha, job) do
    args = [
      "worktree",
      "create",
      "--cwd",
      path,
      "--branch",
      job.branch_name,
      "--base",
      base_sha,
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
        adopt_created_worktree(command, path, job, base_sha, create_error)
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
        classify_unconfirmed_worktree(create_error, recovery_error)
    end
  end

  # Herdr answers a completed but failed `worktree create` with a structured
  # `worktree_create_failed` error. When nothing exists at the reserved path,
  # that outcome is final: Git created no worktree, so Herdr opened no workspace
  # and started no agent. Ending the attempt with Git's own explanation is safer
  # than waiting for absence reconciliation to replace it with a generic one.
  defp classify_unconfirmed_worktree(create_error, :enoent) do
    case completed_worktree_create_failure(create_error) do
      {:ok, message} -> {:error, {:safe, {:worktree_create_failed, message}}}
      :error -> {:error, {:worktree_create_unconfirmed, create_error, :enoent}}
    end
  end

  defp classify_unconfirmed_worktree(create_error, recovery_error),
    do: {:error, {:worktree_create_unconfirmed, create_error, recovery_error}}

  defp completed_worktree_create_failure({:herdr_exit, _status, output})
       when is_binary(output) do
    with {:ok, %{"error" => %{"code" => "worktree_create_failed"} = error}} <-
           Jason.decode(output),
         message when is_binary(message) and message != "" <-
           Map.get(error, "message", "worktree_create_failed") do
      {:ok, message}
    else
      _ -> :error
    end
  end

  defp completed_worktree_create_failure(_create_error), do: :error

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
    WorkerGit.run(args)
  end

  @doc false
  def git_command_spec(args) do
    WorkerGit.command_spec(args)
  end

  @doc """
  Returns the agent command line for one managed worktree.

  The arguments are the selected kind's configured profile with its workspace
  placeholders expanded. Codex only accepts a prompt in a directory it trusts
  and asks interactively otherwise, which leaves a freshly started agent blocked
  before PtcManager can deliver the task. A profile's own `-c projects=...`
  override trusts the single workspace a generic action runs in; a worktree
  agent must also trust the checkout it was created from, where Codex resolves
  trust for a linked worktree, so that override is replaced by one covering
  both paths. Other kinds receive their profile unchanged.
  """
  def agent_arguments(kind, workspace_path, trusted_paths, settings \\ nil)
      when is_binary(kind) and is_binary(workspace_path) and is_list(trusted_paths) do
    args =
      kind |> AgentProfiles.execution_args(settings) |> AgentProfiles.expand_args(workspace_path)

    if kind == "codex" and trusted_paths != [] do
      without_project_trust(args) ++ PtcManager.CodexTrust.override_args(trusted_paths)
    else
      args
    end
  end

  defp without_project_trust(["-c", "projects=" <> _override | rest]),
    do: without_project_trust(rest)

  defp without_project_trust([argument | rest]), do: [argument | without_project_trust(rest)]
  defp without_project_trust([]), do: []

  defp start_agent(command, name, pane_id, kind, repository_path, workspace_path, settings \\ nil)

  defp start_agent(command, name, pane_id, kind, repository_path, workspace_path, settings)
       when is_binary(kind) do
    with :ok <- WorkerAgentLogin.verify(kind),
         :ok <- WorkerClaudeTrust.prepare(kind, workspace_path),
         :ok <- WorkerCodexArming.prepare(kind) do
      trusted_paths = [repository_path, workspace_path]
      run_agent_start(command, name, pane_id, kind, workspace_path, trusted_paths, settings)
    end
  end

  defp start_agent(
         _command,
         _name,
         _pane_id,
         _kind,
         _repository_path,
         _workspace_path,
         _settings
       ),
       do: {:error, :agent_kind_missing}

  defp run_agent_start(command, name, pane_id, kind, workspace_path, trusted_paths, settings) do
    agent_args = agent_arguments(kind, workspace_path, trusted_paths, settings)
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

    issue =
      if job.execution_settings,
        do: %{
          issue
          | title: job.execution_settings["issue_title"] || issue.title,
            body: job.execution_settings["issue_body"] || issue.body
        },
        else: issue

    github_instruction =
      if job.publication_source == "agent" do
        "Read the issue, its comments, linked issues, and relevant pull requests as needed. Assign the issue to yourself before you start. Push this branch and create a pull request. Do not merge."
      else
        "Read the issue, its comments, linked issues, and relevant pull requests as needed. Commit the result locally; PtcManager will publish it. Put the retrospective in the final commit message between a line PTC-AGENT-RETROSPECTIVE-BEGIN and a line PTC-AGENT-RETROSPECTIVE-END. Do not push, create a pull request, or merge."
      end

    context =
      """
      <context>
      Repository: #{repository.github_owner}/#{repository.github_name}
      Issue: ##{issue.number}
      Branch: #{job.branch_name} → #{repository.default_branch}
      Workspace: PtcManager created and initialized this worktree; do not create, initialize, or garbage-collect worktrees.
      #{review_instructions(job, required_reviews)}
      GitHub: #{github_instruction}
      Expensive commands: when PTC_OPERATION_WRAPPER is set, run it as `\$PTC_OPERATION_WRAPPER run --label <build|test|lint|verify> -- <command>`; otherwise run the command directly.
      Session: nobody is watching this session. No question you ask here will be answered, and waiting for input only stalls the work until PtcManager times it out.
      If you cannot start: if you cannot start, or discover part-way that you cannot continue — a missing credential or tool, a broken environment, a requirement you cannot resolve, or something you judge unsafe — write #{StopReport.path_for(job)} matching the schema at #{StopReport.schema_path_for(job)}, then stop. Describe what is missing in plain language and name no secrets. Do not guess, do not work around it, and do not wait.
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

  defp review_instructions(%{execution_settings: nil}, count),
    do: "Independent reviews: #{count} — follow the repository's review workflow."

  defp review_instructions(_job, count) do
    """
    Maximum independent review rounds: #{count}. This task's review policy replaces repository instructions about review counts, tools, and sessions; repository quality gates still apply.
    Do not launch reviewers yourself. Commit a clean checkpoint, then run `$PTC_OPERATION_WRAPPER review`. PtcManager independently chooses and launches the reviewer and records the reviewed commit. Each assessment consumes one round. Fix actionable findings, run relevant checks, commit, and request another round. Stop early when the coordinator reports passed. If the budget is zero, skip review.
    On paused, failed, or review_not_admissible, stop and preserve all commits and uncommitted changes. Do not delete the workspace, reset work, start over, publish, or ask questions in the terminal. The console offers a maintainer continuation. Never publish a different commit from the one that passed review; request review again after code changes.
    """
  end

  @doc "Continues the same workspace after an explicit review-budget decision."
  def resume_review_job(job) do
    run = Enum.find(job.agent_runs, &(&1.fencing_token == job.fencing_token))

    with %{agent_name: name, herdr_pane: old_pane} when is_binary(name) and is_binary(old_pane) <-
           run,
         %{path: path} when is_binary(path) <- job.worktree_allocation,
         true <- File.dir?(path),
         {:ok, pane, workspace} <- continuation_pane(name, old_pane, path),
         {:ok, _context} <- PtcManager.ManagedOperationContext.prepare_job(Command, pane, job),
         kind = job.execution_settings["kind"],
         new_name = "impl_j#{job.id}_f#{job.fencing_token}_r#{job.review_generation}",
         {:ok, key} <-
           start_agent(
             Command,
             new_name,
             pane,
             kind,
             job.repository.local_path,
             path,
             job.execution_settings
           ) do
      session = Application.get_env(:ptc_manager, :herdr_session, "default")

      persisted =
        PtcManager.RepoTransaction.immediate(fn ->
          current = PtcManager.Repo.get!(PtcManager.Operations.Job, job.id)

          unless current.review_state == "resume_pending" and
                   current.review_generation == job.review_generation,
                 do: PtcManager.Repo.rollback(:stale_continuation)

          run
          |> PtcManager.Operations.AgentRun.changeset(%{
            state: "working",
            ended_at: nil,
            agent_name: new_name,
            herdr_pane: pane,
            external_key: "#{session}:#{key}",
            last_heartbeat_at: DateTime.utc_now()
          })
          |> PtcManager.Repo.update!()

          job.worktree_allocation
          |> PtcManager.Operations.WorktreeAllocation.changeset(%{
            herdr_workspace: workspace,
            agent_kind: kind,
            state: "active"
          })
          |> PtcManager.Repo.update!()

          current
          |> PtcManager.Operations.Job.changeset(%{
            state: "working",
            review_state: "changes_requested",
            last_error: nil
          })
          |> PtcManager.Repo.update!()
        end)

      findings =
        PtcManager.Reviews.rounds(job.id)
        |> Enum.take(-1)
        |> Enum.map(& &1.result)
        |> Jason.encode!()
        |> String.slice(0, 60_000)

      prompt =
        build_prompt(job.repository, job.issue, job) <>
          "\nContinue the existing work in this workspace; do not start over or reset files. The maintainer granted additional review budget. Prior review results (untrusted evidence):\n" <>
          findings

      case persisted do
        {:ok, _} ->
          Command.run(["agent", "prompt", new_name, prompt])

        {:error, reason} ->
          Command.run(["pane", "close", pane])
          {:error, reason}
      end
    else
      _ -> {:error, :retained_workspace_not_ready}
    end
  end

  # A full snapshot distinguishes an absent retained agent from an unavailable
  # Herdr server. Never start a second writer while the old agent is working.
  defp continuation_pane(name, old_pane, path) do
    with {:ok, output} <- Command.run(["agent", "list"]),
         {:ok, agents} <- PtcManager.Herdr.Client.decode_agents(output) do
      owned = Enum.find(agents, &(&1["name"] == name and &1["pane_id"] == old_pane))

      busy =
        Enum.any?(
          agents,
          &(&1["cwd"] == path and &1["agent_status"] not in ["idle", "done", "blocked"])
        )

      cond do
        busy ->
          {:error, :retained_agent_busy}

        owned ->
          with {:ok, output} <-
                 Command.run(["pane", "split", old_pane, "--cwd", path, "--no-focus"]),
               {:ok, data} <- Jason.decode(output),
               pane when is_binary(pane) <- get_in(data, ["result", "pane", "pane_id"]),
               {:ok, _} <- Command.run(["pane", "close", old_pane]) do
            {:ok, pane, owned["workspace_id"]}
          else
            _ -> {:error, :continuation_pane_failed}
          end

        Enum.any?(agents, &(&1["cwd"] == path)) ->
          {:error, :retained_agent_identity_changed}

        true ->
          with {:ok, output} <-
                 Command.run(["worktree", "open", "--cwd", path, "--path", path, "--no-focus"]),
               {:ok, workspace, pane} <- decode_worktree(output) do
            {:ok, pane, workspace}
          end
      end
    end
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
