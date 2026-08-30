defmodule PtcManager.MaintainerActions.ExternalPrRepairAdapter do
  @moduledoc "Repairs an imported PR through a credential-free disposable checkout."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.GitHub.ExternalRepairPushBroker
  alias PtcManager.MaintainerActions.CodexAdapter
  alias PtcManager.Manager.CodexAdapter, as: PrivateCodexAdapter
  alias PtcManager.Operations.{AgentAction, PrPublication}
  alias PtcManager.Repo

  @impl true
  def run(%AgentAction{action_key: "repair_pr", target_id: publication_id} = action) do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload(:repository)

    with true <- PrPublication.external?(publication),
         %{local_path: repository_path} = repository when is_binary(repository_path) <-
           publication.repository,
         {:ok, identity} <- external_identity(),
         {:ok, checkout} <-
           prepare_checkout(publication, repository, repository_path, identity, action) do
      result =
        try do
          run_repair(action, publication, repository, checkout, identity)
        rescue
          error -> {:error, {:external_pr_repair_failed, error.__struct__}}
        catch
          kind, reason -> {:error, {:external_pr_repair_failed, kind, inspect(reason)}}
        end

      cleanup_result = cleanup_checkout(identity, checkout.root, checkout.path)
      combine(result, cleanup_result)
    else
      false -> {:error, :pull_request_is_managed}
      nil -> {:error, :repository_path_unavailable}
      %{} -> {:error, :repository_path_unavailable}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:external_pr_repair_failed, error.__struct__}}
  end

  def run(%AgentAction{}), do: {:error, :unsupported_external_pr_action}

  defp run_repair(action, publication, repository, checkout, identity) do
    codex_adapter = Application.get_env(:ptc_manager, :external_pr_codex_adapter, CodexAdapter)

    case codex_adapter.run_at(action, checkout.path,
           sandboxed: true,
           run_as_user: identity.user
         ) do
      {:ok, %{"outcome" => "repaired"} = result} ->
        with {:ok, pushed_head} <-
               commit_and_push(action, publication, repository, checkout, identity) do
          {:ok, Map.put(result, "pushed_head_sha", pushed_head)}
        end

      result ->
        result
    end
  end

  defp prepare_checkout(publication, repository, repository_path, identity, action) do
    with true <- File.dir?(repository_path),
         true <- valid_sha?(preflight_head(action)),
         true <- valid_sha?(publication.remote_base_sha),
         :ok <- valid_repository(repository),
         :ok <- valid_head_ref(publication.head_ref),
         :ok <- valid_head_ref(repository.default_branch),
         {:ok, root} <- checkout_root(repository_path),
         :ok <- ensure_root(root),
         path <- checkout_path(root, publication),
         {:ok, prepared} <-
           prepare_from_disposable_source(
             path,
             publication,
             repository,
             preflight_head(action),
             identity
           ) do
      {:ok, Map.put(prepared, :root, root)}
    else
      false -> {:error, :external_pull_request_version_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_from_disposable_source(
         checkout_path,
         publication,
         repository,
         head_sha,
         identity
       ) do
    source_path =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-external-source-#{random_suffix()}"
      )

    bundle = checkout_path <> ".bundle"
    head_ref = temporary_ref(publication, "head")
    base_ref = temporary_ref(publication, "base")

    try do
      with :ok <- run(git(), ["init", "--bare", "--template=/dev/null", source_path]),
           {:ok, remote} <- source_remote(repository),
           :ok <-
             fetch_exact_inputs(source_path, remote, publication, repository, head_ref, base_ref),
           {:ok, prepared} <-
             create_checkout(
               source_path,
               checkout_path,
               bundle,
               head_ref,
               base_ref,
               head_sha,
               publication.remote_base_sha,
               identity
             ) do
        {:ok, prepared}
      end
    after
      File.rm_rf(source_path)
    end
  end

  defp fetch_exact_inputs(source_path, remote, publication, repository, head_ref, base_ref) do
    with_fetch_auth(fn fetch_env ->
      with :ok <-
             run(
               git(),
               [
                 "-C",
                 source_path,
                 "fetch",
                 "--no-tags",
                 remote,
                 "+refs/pull/#{publication.pr_number}/head:#{head_ref}",
                 "+refs/heads/#{repository.default_branch}:#{base_ref}"
               ],
               fetch_env
             ),
           {:ok, head} <- capture(git(), ["-C", source_path, "rev-parse", head_ref]),
           {:ok, base} <- capture(git(), ["-C", source_path, "rev-parse", base_ref]),
           true <- head == publication.remote_head_sha,
           true <- base == publication.remote_base_sha do
        :ok
      else
        false -> {:error, :external_pull_request_version_changed}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp create_checkout(
         repository_path,
         path,
         bundle,
         head_ref,
         base_ref,
         head_sha,
         base_sha,
         identity
       ) do
    result =
      try do
        with :ok <-
               run(git(), [
                 "-C",
                 repository_path,
                 "bundle",
                 "create",
                 bundle,
                 head_ref,
                 base_ref
               ]),
             :ok <- grant_bundle(identity.group, bundle),
             :ok <- external_git(identity, ["init", "--template=/dev/null", path]),
             :ok <- external_git(identity, ["-C", path, "bundle", "unbundle", bundle]),
             :ok <-
               external_git(identity, [
                 "-C",
                 path,
                 "update-ref",
                 "refs/ptc-manager/reviewed-head",
                 head_sha
               ]),
             :ok <- external_git(identity, ["-C", path, "checkout", "--detach", head_sha]),
             :ok <-
               external_git(identity, [
                 "-C",
                 path,
                 "update-ref",
                 "refs/ptc-manager/reviewed-base",
                 base_sha
               ]) do
          {:ok, %{path: path, base_sha: base_sha}}
        end
      rescue
        error -> {:error, {:external_checkout_failed, error.__struct__}}
      after
        File.rm(bundle)
      end

    if match?({:error, _reason}, result),
      do: cleanup_checkout(identity, Path.dirname(path), path)

    result
  end

  defp commit_and_push(action, publication, repository, checkout, identity) do
    expected_head = preflight_head(action)
    path = checkout.path

    with {:ok, ^expected_head} <- external_capture(identity, ["-C", path, "rev-parse", "HEAD"]),
         {:ok, true} <- external_changed?(identity, path),
         :ok <- external_git(identity, ["-C", path, "add", "-A"]),
         :ok <-
           external_git(identity, [
             "-c",
             "core.hooksPath=/dev/null",
             "-c",
             "user.name=PtcManager Repair",
             "-c",
             "user.email=ptc-manager@localhost",
             "-C",
             path,
             "commit",
             "-m",
             "Repair PR ##{publication.pr_number}"
           ]),
         {:ok, repaired_head} <- external_capture(identity, ["-C", path, "rev-parse", "HEAD"]),
         true <- valid_sha?(repaired_head),
         :ok <- external_ancestor?(identity, path, expected_head, repaired_head),
         :ok <-
           verify_conflict_base(identity, path, publication, checkout.base_sha, repaired_head),
         :ok <- create_repair_bundle(identity, path, repaired_head),
         {:ok, _action} <-
           PtcManager.Operations.record_agent_action_repair_intent(
             action.id,
             action.attempt_token,
             repaired_head
           ),
         :ok <-
           push_repair(
             path,
             repository,
             publication,
             expected_head,
             repaired_head,
             required_conflict_base(publication, checkout.base_sha)
           ) do
      {:ok, repaired_head}
    else
      {:ok, false} -> {:error, :repair_agent_made_no_changes}
      {:ok, _other_head} -> {:error, :external_pull_request_head_changed}
      false -> {:error, :invalid_repair_head}
      {:blocked, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_conflict_base(_identity, _path, %{mergeability: mergeability}, _base, _head)
       when mergeability != "conflicting",
       do: :ok

  defp verify_conflict_base(identity, path, _publication, base, head),
    do: external_ancestor?(identity, path, base, head)

  defp required_conflict_base(%{mergeability: "conflicting"}, base), do: base
  defp required_conflict_base(_publication, _base), do: nil

  defp create_repair_bundle(identity, path, repaired_head) do
    with :ok <-
           external_git(identity, [
             "-C",
             path,
             "update-ref",
             "refs/ptc-manager/repaired-head",
             repaired_head
           ]),
         :ok <-
           external_git(identity, [
             "-C",
             path,
             "bundle",
             "create",
             Path.join(path, ".ptc-manager-repair.bundle"),
             "refs/ptc-manager/repaired-head",
             "refs/ptc-manager/reviewed-base"
           ]) do
      :ok
    end
  end

  defp push_repair(
         path,
         repository,
         publication,
         expected_head,
         repaired_head,
         required_base
       ) do
    broker =
      Application.get_env(
        :ptc_manager,
        :external_pr_push_broker,
        ExternalRepairPushBroker
      )

    broker.push_external_repair(
      path,
      repository,
      publication,
      expected_head,
      repaired_head,
      required_base
    )
  end

  defp external_identity do
    user = Application.get_env(:ptc_manager, :external_pr_run_as_user)
    group = Application.get_env(:ptc_manager, :external_pr_group)
    default_user = Application.get_env(:ptc_manager, :agent_action_run_as_user)
    custom_adapter = Application.get_env(:ptc_manager, :external_pr_codex_adapter)
    root = Application.get_env(:ptc_manager, :external_pr_worktree_root)
    push_user = Application.get_env(:ptc_manager, :external_pr_push_run_as_user)

    cond do
      not is_nil(custom_adapter) ->
        {:ok, %{user: nil, group: nil}}

      is_nil(custom_adapter) and
          {user, group, root, push_user} !=
            {"ptc-manager-external", "ptc-manager-external", "/srv/ptc_manager-external",
             "ptc-manager-worker"} ->
        {:error, :external_repair_deployment_misconfigured}

      is_binary(user) and user != "" and is_binary(group) and group != "" and user != default_user ->
        {:ok, %{user: user, group: group}}

      true ->
        {:error, :external_repair_identity_not_configured}
    end
  end

  defp checkout_root(repository_path) do
    root =
      Application.get_env(:ptc_manager, :external_pr_worktree_root) ||
        Path.join(Path.dirname(Path.expand(repository_path)), ".ptc-manager-external")

    if is_binary(root) and Path.type(root) == :absolute,
      do: {:ok, Path.expand(root)},
      else: {:error, :external_repair_root_unavailable}
  end

  defp ensure_root(root) do
    case File.stat(root) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :external_repair_root_unavailable}
      {:error, :enoent} -> File.mkdir_p(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp grant_bundle(nil, _bundle), do: :ok

  defp grant_bundle(group, bundle) do
    with :ok <- run("/usr/bin/chgrp", [group, bundle]),
         :ok <- run("/usr/bin/chmod", ["0660", bundle]) do
      :ok
    end
  end

  defp external_git(identity, args), do: command_result(external_command(identity, args))

  defp external_capture(identity, args) do
    case external_command(identity, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:command_failed, status, bounded(output)}}
    end
  end

  defp external_command(%{user: nil}, args), do: command(git(), args)

  defp external_command(identity, args) do
    wrapper =
      Application.get_env(
        :ptc_manager,
        :external_pr_git_wrapper,
        "/usr/local/bin/ptc-manager-external-git"
      )

    {command, command_args} = PrivateCodexAdapter.codex_command(wrapper, args, identity.user)
    command(command, command_args)
  end

  defp external_changed?(identity, path) do
    case external_command(identity, [
           "-C",
           path,
           "status",
           "--porcelain=v1",
           "--untracked-files=all"
         ]) do
      {"", 0} -> {:ok, false}
      {output, 0} -> {:ok, String.trim(output) != ""}
      {output, status} -> {:error, {:command_failed, status, bounded(output)}}
    end
  end

  defp external_ancestor?(identity, path, ancestor, descendant) do
    case external_command(identity, [
           "-C",
           path,
           "merge-base",
           "--is-ancestor",
           ancestor,
           descendant
         ]) do
      {_output, 0} -> :ok
      {_output, 1} -> {:error, :repair_head_not_descendant}
      {output, status} -> {:error, {:command_failed, status, bounded(output)}}
    end
  end

  defp cleanup_checkout(%{user: nil}, root, path) do
    if Path.dirname(path) == root do
      case File.rm_rf(path) do
        {:ok, _paths} -> :ok
        {:error, _file, reason} -> {:error, {:external_checkout_cleanup_failed, reason}}
      end
    else
      {:error, :invalid_external_checkout_path}
    end
  end

  defp cleanup_checkout(identity, root, path) do
    if Path.dirname(path) == root do
      wrapper =
        Application.get_env(
          :ptc_manager,
          :external_pr_cleanup_wrapper,
          "/usr/local/bin/ptc-manager-external-cleanup"
        )

      {command, args} = PrivateCodexAdapter.codex_command(wrapper, [path], identity.user)
      command_result(command(command, args))
    else
      {:error, :invalid_external_checkout_path}
    end
  end

  defp combine(result, :ok), do: result
  defp combine({:error, reason}, {:error, cleanup}), do: {:error, {reason, cleanup}}

  defp combine({:ok, result}, {:error, cleanup}) do
    {:ok, Map.put(result, "cleanup_warning", inspect(cleanup))}
  end

  defp checkout_path(root, publication) do
    Path.join(root, "external-pr-#{publication.id}-attempt-#{random_suffix()}")
  end

  defp temporary_ref(publication, kind) do
    attempt = System.unique_integer([:positive, :monotonic])
    "refs/ptc-manager/external-repairs/#{publication.id}/#{attempt}/#{kind}"
  end

  defp valid_head_ref(ref) when is_binary(ref) do
    case command(git(), ["check-ref-format", "refs/heads/#{ref}"]) do
      {_output, 0} -> :ok
      _failure -> {:error, :invalid_external_pull_request_head_ref}
    end
  end

  defp valid_head_ref(_ref), do: {:error, :invalid_external_pull_request_head_ref}

  defp valid_repository(%{github_owner: owner, github_name: name}) do
    if valid_repository_component?(owner) and valid_repository_component?(name),
      do: :ok,
      else: {:error, :invalid_external_pull_request_repository}
  end

  defp valid_repository_component?(component),
    do: is_binary(component) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, component)

  defp source_remote(repository) do
    case Application.get_env(:ptc_manager, :external_pr_source_remote) do
      nil ->
        {:ok, "https://github.com/#{repository.github_owner}/#{repository.github_name}.git"}

      remote when is_binary(remote) ->
        if Application.get_env(:ptc_manager, :external_pr_codex_adapter),
          do: {:ok, remote},
          else: {:error, :external_repair_deployment_misconfigured}

      _invalid ->
        {:error, :external_repair_deployment_misconfigured}
    end
  end

  defp run(binary, args, extra_env \\ []), do: command_result(command(binary, args, extra_env))

  defp capture(binary, args) do
    case command(binary, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:command_failed, status, bounded(output)}}
    end
  end

  defp command_result({_output, 0}), do: :ok
  defp command_result({output, status}), do: {:error, {:command_failed, status, bounded(output)}}

  defp command(binary, args, extra_env \\ []) do
    {executable, command_args} = bounded_command(binary, args)

    environment =
      PrivateCodexAdapter.command_environment()
      |> Map.new()
      |> Map.merge(Map.new(extra_env))
      |> Map.to_list()

    System.cmd(executable, command_args,
      env: environment,
      stderr_to_stdout: true
    )
  rescue
    error -> {inspect(error.__struct__), 127}
  end

  defp preflight_head(%{target_snapshot: snapshot}) when is_map(snapshot),
    do: snapshot["head_sha"]

  defp preflight_head(_action), do: nil
  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)
  defp random_suffix, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

  defp with_fetch_auth(fun) when is_function(fun, 1) do
    case Application.get_env(:ptc_manager, :github_read_token) do
      token when is_binary(token) and token != "" ->
        auth_dir = Path.join(System.tmp_dir!(), "ptc-manager-git-auth-#{random_suffix()}")
        auth_path = Path.join(auth_dir, "config")
        basic = Base.encode64("x-access-token:#{token}")

        try do
          :ok = File.mkdir(auth_dir)
          :ok = File.chmod(auth_dir, 0o700)

          :ok =
            File.write(
              auth_path,
              "[http \"https://github.com/\"]\n\textraHeader = Authorization: Basic #{basic}\n",
              [:write, :exclusive]
            )

          :ok = File.chmod(auth_path, 0o600)
          fun.([{"GIT_CONFIG_GLOBAL", auth_path}, {"GIT_CONFIG_NOSYSTEM", "1"}])
        after
          File.rm_rf(auth_dir)
        end

      _token ->
        fun.([])
    end
  end

  defp bounded_command(binary, args) do
    case Application.get_env(:ptc_manager, :git_timeout_binary) do
      timeout_binary when is_binary(timeout_binary) and timeout_binary != "" ->
        timeout_ms = Application.get_env(:ptc_manager, :external_pr_command_timeout_ms, 180_000)
        timeout_seconds = max(div(timeout_ms + 999, 1_000), 1)

        {timeout_binary,
         ["--signal=TERM", "--kill-after=2s", "#{timeout_seconds}s", binary | args]}

      _timeout_binary ->
        {binary, args}
    end
  end

  defp git, do: Application.get_env(:ptc_manager, :git_binary, "git")
  defp bounded(output), do: output |> String.trim() |> String.slice(-500, 500)
end
