defmodule PtcManager.GitHub.AppBroker do
  @moduledoc "GitHub App broker for exact-commit draft PR publication and status reads."

  @behaviour PtcManager.GitHub.PublishBroker

  alias PtcManager.Operations.PrPublication
  alias PtcManager.Publications
  alias PtcManager.Repository.{Contract, GitProbe}

  @api "https://api.github.com"
  @api_version "2022-11-28"
  @output_limit 65_536
  @staging_prefix "ptc-manager-publish-"
  @retrospective_limit 4_000

  import Bitwise, only: [band: 2]

  @impl true
  def publish(%PrPublication{job: %{issue: issue, repository: repository}} = publication) do
    with :ok <- configured?(),
         {:ok, source_path} <- valid_context(repository, issue, publication),
         {:ok, token} <- installation_token(),
         {:ok, existing_pull_request} <- existing_pull_request(token, repository, publication),
         {:ok, authoritative_base_sha} <- authoritative_base(token, repository),
         :ok <- renew_claim(publication),
         {:ok, result} <-
           with_trusted_repository(source_path, publication, fn trusted_path ->
             with :ok <- fetch_authoritative_base(trusted_path, token, repository),
                  :ok <- renew_claim(publication),
                  :ok <-
                    authoritative_base_matches(trusted_path, repository, authoritative_base_sha),
                  :ok <- renew_claim(publication),
                  :ok <- trusted_result_matches(trusted_path, repository, publication),
                  :ok <- renew_claim(publication),
                  :ok <- ensure_remote_branch(token, repository, publication, trusted_path),
                  :ok <- renew_claim(publication),
                  {:ok, pull_request} <-
                    existing_pull_request_or_create(
                      existing_pull_request,
                      token,
                      repository,
                      issue,
                      publication,
                      trusted_path
                    ) do
               normalize_pull_request(pull_request, publication.head_sha, repository)
             end
           end) do
      {:ok, result}
    else
      {:blocked, reason} ->
        {:blocked, reason}

      {:error, {:github_http_error, _status, _message, delay_ms} = reason}
      when is_integer(delay_ms) ->
        {:retry, {:after, delay_ms, reason}}

      {:error, {:github_http_error, status, _message, nil} = reason}
      when status in [401, 403, 404] ->
        {:blocked, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  def publish(_publication), do: {:blocked, :invalid_publication_context}

  @impl true
  def status(%PrPublication{job: %{issue: issue, repository: repository}} = publication) do
    with :ok <- configured?(),
         :ok <- valid_target_context(repository, issue, publication),
         true <- is_integer(publication.pr_number) and publication.pr_number > 0,
         {:ok, token} <- installation_token(),
         {:ok, pull_request} <-
           request(
             :get,
             repo_path(repository, "/pulls/#{publication.pr_number}"),
             "Bearer #{token}"
           ),
         {:ok, status} <- normalize_status(pull_request) do
      {:ok, status}
    else
      false ->
        {:blocked, :missing_pull_request_number}

      {:blocked, reason} ->
        {:blocked, reason}

      {:error, {:github_http_error, _status, _message, delay_ms} = reason}
      when is_integer(delay_ms) ->
        {:retry, {:after, delay_ms, reason}}

      {:error, {:github_http_error, status, _message, nil} = reason}
      when status in [401, 403, 404] ->
        {:blocked, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  def status(_publication), do: {:blocked, :invalid_publication_context}

  @doc "Fetches and pins the current default-branch commit for trusted repair verification."
  def fetch_base_for_verification(path, repository, expected_sha)
      when is_binary(path) and is_binary(expected_sha) do
    with :ok <- configured?(),
         :ok <- valid_verification_context(path, repository, expected_sha),
         {:ok, token} <- installation_token(),
         :ok <- fetch_authoritative_base(path, token, repository),
         :ok <- authoritative_base_matches(path, repository, expected_sha) do
      :ok
    else
      {:blocked, reason} -> {:blocked, reason}
      {:error, {:github_http_error, _status, _message, _delay_ms} = reason} -> {:retry, reason}
      {:error, reason} -> {:retry, reason}
    end
  end

  def fetch_base_for_verification(_path, _repository, _expected_sha),
    do: {:blocked, :invalid_repair_verification_context}

  @doc false
  def inspect_staged_repository(source_path, publication, function)
      when is_function(function, 1) do
    with_trusted_repository(source_path, publication, function, fn -> :ok end)
  end

  defp configured? do
    required = [
      Application.get_env(:ptc_manager, :github_app_id),
      Application.get_env(:ptc_manager, :github_app_installation_id),
      Application.get_env(:ptc_manager, :github_app_private_key_path),
      Application.get_env(:ptc_manager, :github_push_timeout_binary),
      Application.get_env(:ptc_manager, :github_publish_staging_root)
    ]

    if Enum.all?(required, &(not is_nil(&1) and &1 != "")),
      do: :ok,
      else: {:blocked, :github_app_not_configured}
  end

  defp valid_context(repository, issue, publication) do
    source_path = Application.get_env(:ptc_manager, :repository_path) || repository.local_path

    with :ok <- valid_target_context(repository, issue, publication) do
      if is_binary(source_path) and Path.type(source_path) == :absolute and File.dir?(source_path),
        do: {:ok, Path.expand(source_path)},
        else: {:blocked, :invalid_repository_path}
    end
  end

  defp valid_target_context(repository, issue, publication) do
    expected_branch = "ptc-manager/issue-#{issue.number}-job-#{publication.job_id}"

    cond do
      not safe_repository_component?(repository.github_owner) ->
        {:blocked, :invalid_repository_owner}

      not safe_repository_component?(repository.github_name) ->
        {:blocked, :invalid_repository_name}

      not safe_ref?(repository.default_branch) ->
        {:blocked, :invalid_default_branch}

      publication.branch_name != expected_branch ->
        {:blocked, :unexpected_job_branch}

      publication.fencing_token != publication.job.fencing_token or
        publication.head_sha != publication.job.result_head_sha or
        publication.base_sha != publication.job.result_base_sha or
          publication.diff_digest != publication.job.result_diff_digest ->
        {:blocked, :stale_publication_context}

      publication.job.pre_publication_status != "passed" or
        publication.job.pre_publication_verified_sha != publication.head_sha or
        publication.job.pre_publication_exit_status != 0 or
        not is_binary(publication.job.pre_publication_bootstrap_command) or
        not is_integer(publication.job.pre_publication_bootstrap_timeout_ms) or
        not is_binary(publication.job.pre_publication_command) or
        not is_integer(publication.job.pre_publication_timeout_ms) or
        not is_binary(publication.job.pre_publication_config_digest) or
          not Contract.frozen_publication_digest_matches?(publication.job) ->
        {:blocked, :pre_publication_gate_not_passed}

      true ->
        :ok
    end
  end

  defp valid_verification_context(path, repository, expected_sha) do
    cond do
      Path.type(path) != :absolute or not File.dir?(path) ->
        {:blocked, :invalid_repository_path}

      not safe_repository_component?(repository.github_owner) ->
        {:blocked, :invalid_repository_owner}

      not safe_repository_component?(repository.github_name) ->
        {:blocked, :invalid_repository_name}

      not safe_ref?(repository.default_branch) ->
        {:blocked, :invalid_default_branch}

      not Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, expected_sha) ->
        {:blocked, :invalid_repair_base}

      true ->
        :ok
    end
  end

  defp installation_token do
    installation_id = Application.fetch_env!(:ptc_manager, :github_app_installation_id)

    with {:ok, jwt} <- app_jwt(),
         {:ok, response} <-
           request(
             :post,
             "/app/installations/#{installation_id}/access_tokens",
             "Bearer #{jwt}",
             %{}
           ),
         token when is_binary(token) <- response["token"] do
      {:ok, token}
    else
      nil -> {:error, :github_installation_token_missing}
      error -> error
    end
  end

  defp app_jwt do
    app_id = Application.fetch_env!(:ptc_manager, :github_app_id)
    path = Application.fetch_env!(:ptc_manager, :github_app_private_key_path)
    now = System.system_time(:second)

    try do
      with {:ok, pem} <- read_private_key(path),
           {:ok, key} <- decode_private_key(pem) do
        header = base64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))

        payload =
          base64url(Jason.encode!(%{"iat" => now - 30, "exp" => now + 540, "iss" => app_id}))

        signing_input = header <> "." <> payload
        signature = signing_input |> :public_key.sign(:sha256, key) |> base64url()
        {:ok, signing_input <> "." <> signature}
      end
    rescue
      _error -> {:error, :github_app_signing_failed}
    end
  end

  defp read_private_key(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= 65_536 -> File.read(path)
      {:ok, _stat} -> {:error, :invalid_github_app_private_key_file}
      {:error, _reason} -> {:error, :github_app_private_key_unavailable}
    end
  end

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry] -> {:ok, :public_key.pem_entry_decode(entry)}
      _entries -> {:error, :invalid_github_app_private_key}
    end
  rescue
    _error -> {:error, :invalid_github_app_private_key}
  end

  defp existing_pull_request(token, repository, publication) do
    with {:ok, pull_requests} <- list_pull_requests(token, repository, publication) do
      select_pull_request(pull_requests, publication)
    end
  end

  defp list_pull_requests(token, repository, publication) do
    head = URI.encode_www_form("#{repository.github_owner}:#{publication.branch_name}")

    request(
      :get,
      repo_path(repository, "/pulls?state=all&head=#{head}&per_page=10"),
      "Bearer #{token}"
    )
  end

  defp select_pull_request(pull_requests, publication) when is_list(pull_requests) do
    open_pull_requests = Enum.filter(pull_requests, &(&1["state"] == "open"))

    case open_pull_requests do
      [] ->
        if pull_requests == [], do: {:ok, nil}, else: {:blocked, :pull_request_already_closed}

      [%{"head" => %{"sha" => head_sha}} = pull_request] when head_sha == publication.head_sha ->
        {:ok, pull_request}

      [_pull_request] ->
        {:blocked, :pull_request_head_changed}

      _many ->
        {:blocked, :multiple_pull_requests_for_branch}
    end
  end

  defp select_pull_request(_response, _publication),
    do: {:error, :invalid_github_pull_list_response}

  defp authoritative_base(token, repository) do
    case remote_branch(token, repository, repository.default_branch) do
      {:ok, nil} -> {:blocked, :github_base_branch_missing}
      {:ok, sha} -> {:ok, sha}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_branch(token, repository, branch_name) do
    encoded_branch = URI.encode_www_form(branch_name)

    case request(
           :get,
           repo_path(repository, "/git/ref/heads/#{encoded_branch}"),
           "Bearer #{token}"
         ) do
      {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, _response} -> {:error, :invalid_github_ref_response}
      {:error, {:github_http_error, 404, _message, nil}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_trusted_repository(source_path, publication, function, renewer \\ nil) do
    root = Application.fetch_env!(:ptc_manager, :github_publish_staging_root) |> Path.expand()
    renewer = renewer || fn -> renew_claim(publication) end

    with :ok <- safe_staging_root(root),
         :ok <- cleanup_stale_staging(root),
         {:ok, paths} <- create_staging_directory(root) do
      try do
        with {:ok, _output} <- export_worker_bundle(source_path, publication, paths.export_bundle),
             :ok <- renewer.(),
             :ok <- copy_worker_bundle(paths.export_bundle, paths.trusted_bundle),
             {:ok, _output} <-
               run_git(paths.trusted, ["init", "--bare", "--template=/dev/null", "."]),
             :ok <- renewer.(),
             {:ok, _output} <-
               run_git(paths.trusted, ["bundle", "unbundle", paths.trusted_bundle]),
             :ok <- renewer.(),
             {:ok, _output} <-
               run_git(paths.trusted, [
                 "update-ref",
                 "refs/heads/#{publication.branch_name}",
                 publication.head_sha
               ]),
             {:ok, head_sha} <-
               revision(paths.trusted, "refs/heads/#{publication.branch_name}"),
             :ok <- renewer.(),
             true <- head_sha == publication.head_sha do
          function.(paths.trusted)
        else
          false -> {:blocked, :worker_branch_changed_during_staging}
          error -> error
        end
      after
        remove_staging_directory(root, paths.root)
      end
    end
  end

  defp safe_staging_root(root) do
    case {Path.type(root), File.stat(root)} do
      {:absolute, {:ok, %{type: :directory, mode: mode}}} when band(mode, 0o022) == 0 ->
        :ok

      _untrusted_or_missing ->
        {:blocked, :github_staging_root_unavailable}
    end
  end

  defp create_staging_directory(root) do
    name = @staging_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    path = Path.join(root, name)
    quarantine = Path.join(path, "quarantine")
    trusted = Path.join(path, "trusted")

    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o2710),
         :ok <- File.mkdir(quarantine),
         :ok <- File.chmod(quarantine, 0o2770),
         :ok <- File.mkdir(trusted),
         :ok <- File.chmod(trusted, 0o2750) do
      {:ok,
       %{
         root: path,
         trusted: trusted,
         export_bundle: Path.join(quarantine, "worker.bundle"),
         trusted_bundle: Path.join(trusted, "worker.bundle")
       }}
    else
      _reason ->
        remove_staging_directory(root, path)
        {:error, :github_staging_directory_unavailable}
    end
  end

  defp export_worker_bundle(source_path, publication, export_path) do
    git = Application.get_env(:ptc_manager, :git_binary, "git")

    git_args = [
      "-C",
      source_path,
      "--no-optional-locks",
      "-c",
      "safe.directory=#{source_path}",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "bundle",
      "create",
      export_path,
      "refs/heads/#{publication.branch_name}"
    ]

    {command, args} = GitProbe.command(git, git_args)

    run_command(
      command,
      args,
      scrubbed_environment(%{"PATH" => "/usr/bin:/bin", "LC_ALL" => "C"}),
      Application.get_env(:ptc_manager, :git_timeout_ms, 15_000) + 2_500
    )
  end

  defp copy_worker_bundle(export_path, trusted_path) do
    max_bytes = Application.get_env(:ptc_manager, :github_publish_bundle_max_bytes, 250_000_000)

    with {:ok, %{type: :regular, size: size}} when size > 0 and size <= max_bytes <-
           File.stat(export_path),
         :ok <- File.cp(export_path, trusted_path),
         :ok <- File.chmod(trusted_path, 0o640) do
      :ok
    else
      _invalid_or_failed -> {:blocked, :worker_bundle_invalid}
    end
  end

  defp cleanup_stale_staging(root) do
    cutoff =
      System.os_time(:second) -
        div(
          Application.get_env(:ptc_manager, :github_publish_staging_stale_ms, 3_600_000),
          1_000
        )

    with {:ok, %{uid: owner_uid}} <- File.stat(root),
         {:ok, entries} <- File.ls(root) do
      Enum.each(entries, fn entry ->
        path = Path.join(root, entry)

        case File.stat(path, time: :posix) do
          {:ok, %{type: :directory, uid: ^owner_uid, mtime: mtime}}
          when mtime <= cutoff ->
            if String.starts_with?(entry, @staging_prefix),
              do: remove_staging_directory(root, path)

          _fresh_or_unowned ->
            :ok
        end
      end)

      :ok
    else
      _reason -> {:blocked, :github_staging_root_unavailable}
    end
  end

  defp remove_staging_directory(root, path) do
    expanded_path = Path.expand(path)

    if Path.dirname(expanded_path) == root and
         String.starts_with?(Path.basename(expanded_path), @staging_prefix) do
      File.rm_rf(expanded_path)
    end

    :ok
  end

  defp fetch_authoritative_base(path, token, repository) do
    case run_git(
           path,
           [
             "fetch",
             "--no-tags",
             "--no-write-fetch-head",
             "--force",
             repository_url(repository),
             "refs/heads/#{repository.default_branch}:refs/remotes/origin/#{repository.default_branch}"
           ],
           token
         ) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authoritative_base_matches(path, repository, expected_sha) do
    case revision(path, "refs/remotes/origin/#{repository.default_branch}") do
      {:ok, ^expected_sha} -> :ok
      {:ok, _changed_sha} -> {:error, :github_base_changed_during_publication}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trusted_result_matches(path, repository, publication) do
    trusted_repository = %{repository | local_path: path}

    case GitProbe.verify_at(trusted_repository, publication.job, path) do
      {:ok, result} ->
        if result.base_sha == publication.base_sha and result.head_sha == publication.head_sha and
             result.diff_digest == publication.diff_digest and
             result.commit_count == publication.job.result_commit_count do
          :ok
        else
          {:blocked, :github_authoritative_diff_changed}
        end

      {:error, reason} ->
        {:blocked, {:trusted_revalidation_failed, reason}}
    end
  end

  defp renew_claim(publication) do
    Publications.renew_claim(
      publication.id,
      publication.fencing_token,
      publication.attempt_token
    )
  end

  defp ensure_remote_branch(token, repository, publication, trusted_path) do
    case remote_branch(token, repository, publication.branch_name) do
      {:ok, nil} -> push_exact_commit(token, repository, publication, trusted_path)
      {:ok, remote_sha} when remote_sha == publication.head_sha -> :ok
      {:ok, _other_sha} -> {:blocked, :remote_branch_diverged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp push_exact_commit(token, repository, publication, trusted_path) do
    case run_git(
           trusted_path,
           [
             "push",
             "--porcelain",
             repository_url(repository),
             "#{publication.head_sha}:refs/heads/#{publication.branch_name}"
           ],
           token
         ) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_pull_request_or_create(
         nil,
         token,
         repository,
         issue,
         publication,
         trusted_path
       ),
       do: create_pull_request(token, repository, issue, publication, trusted_path)

  defp existing_pull_request_or_create(
         pull_request,
         _token,
         _repository,
         _issue,
         _publication,
         _trusted_path
       ),
       do: {:ok, pull_request}

  defp create_pull_request(token, repository, issue, publication, trusted_path) do
    title = "Implement ##{issue.number}: #{String.slice(issue.title, 0, 180)}"
    retrospective = agent_retrospective(trusted_path, publication.head_sha)
    body = pull_request_body(issue.number, retrospective)

    request(
      :post,
      repo_path(repository, "/pulls"),
      "Bearer #{token}",
      %{
        "title" => title,
        "body" => body,
        "head" => publication.branch_name,
        "base" => repository.default_branch,
        "draft" => true
      }
    )
  end

  @doc false
  def pull_request_body(issue_number, retrospective) do
    """
    Automated implementation for ##{issue_number}.

    Ptc Manager verified the committed branch before publishing it. This pull request remains a draft until review is complete.

    ## Agent retrospective

    #{retrospective}
    """
  end

  @doc false
  def agent_retrospective(path, head_sha) when is_binary(path) and is_binary(head_sha) do
    with true <- Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, head_sha),
         {:ok, message} <- run_git(path, ["show", "-s", "--format=%B", head_sha]),
         [_, retrospective] <-
           Regex.run(
             ~r/PTC-AGENT-RETROSPECTIVE-BEGIN\s*\n(.*?)\nPTC-AGENT-RETROSPECTIVE-END/s,
             message
           ),
         retrospective when retrospective != "" <- String.trim(retrospective) do
      String.slice(retrospective, 0, @retrospective_limit)
    else
      _missing -> "No agent retrospective was supplied."
    end
  end

  def agent_retrospective(_path, _head_sha), do: "No agent retrospective was supplied."

  defp normalize_pull_request(
         %{
           "number" => number,
           "html_url" => url,
           "head" => %{"sha" => head_sha},
           "base" => %{"ref" => base_ref, "repo" => %{"full_name" => base_repository}}
         },
         expected_head,
         repository
       )
       when is_integer(number) and number > 0 and is_binary(url) and head_sha == expected_head and
              is_binary(base_ref) and is_binary(base_repository) do
    if base_ref == repository.default_branch and
         String.downcase(base_repository) ==
           String.downcase("#{repository.github_owner}/#{repository.github_name}") do
      {:ok, %{pr_number: number, pr_url: url, head_sha: head_sha}}
    else
      {:blocked, :pull_request_base_changed}
    end
  end

  defp normalize_pull_request(%{"head" => %{"sha" => _head_sha}}, _expected_head, _repository),
    do: {:blocked, :pull_request_head_changed}

  defp normalize_pull_request(_pull_request, _expected_head, _repository),
    do: {:error, :invalid_github_pull_response}

  defp normalize_status(
         %{
           "state" => state,
           "html_url" => url,
           "head" => %{
             "sha" => head_sha,
             "ref" => head_ref,
             "repo" => %{"full_name" => head_repository}
           },
           "base" => %{
             "sha" => base_sha,
             "ref" => base_ref,
             "repo" => %{"full_name" => base_repository}
           }
         } = pull_request
       )
       when state in ["open", "closed"] and is_binary(url) and is_binary(head_sha) and
              is_binary(head_ref) and is_binary(head_repository) and is_binary(base_sha) and
              is_binary(base_ref) and is_binary(base_repository) do
    state =
      cond do
        is_binary(pull_request["merged_at"]) -> "merged"
        state == "closed" -> "closed"
        true -> "open"
      end

    {:ok,
     %{
       state: state,
       pr_url: url,
       draft: pull_request["draft"] == true,
       body: pull_request["body"] || "",
       head_sha: head_sha,
       head_ref: head_ref,
       head_repository: head_repository,
       base_sha: base_sha,
       base_ref: base_ref,
       base_repository: base_repository
     }}
  end

  defp normalize_status(_pull_request), do: {:error, :invalid_github_pull_response}

  defp revision(path, ref) do
    case run_git(path, ["rev-parse", "--verify", "#{ref}^{commit}"]) do
      {:ok, output} ->
        sha = String.trim(output)

        if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, sha),
          do: {:ok, sha},
          else: {:error, :invalid_git_revision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_git(path, args, token \\ nil) do
    git = Application.get_env(:ptc_manager, :git_binary, "git")
    timeout_binary = Application.fetch_env!(:ptc_manager, :github_push_timeout_binary)
    timeout_ms = Application.get_env(:ptc_manager, :github_push_timeout_ms, 60_000)

    fixed_args = [
      "-C",
      path,
      "--no-optional-locks",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "credential.helper="
      | args
    ]

    command_args = [
      "--signal=TERM",
      "--kill-after=2s",
      "#{timeout_ms / 1_000}s",
      git
      | fixed_args
    ]

    allowed = %{
      "HOME" => Application.get_env(:ptc_manager, :github_broker_home) || System.tmp_dir!(),
      "PATH" => "/usr/bin:/bin",
      "LC_ALL" => "C",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_ALLOW_PROTOCOL" => "https:file"
    }

    allowed =
      if is_binary(token) do
        authorization = Base.encode64("x-access-token:#{token}")

        Map.merge(allowed, %{
          "GIT_CONFIG_COUNT" => "1",
          "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
          "GIT_CONFIG_VALUE_0" => "Authorization: Basic #{authorization}"
        })
      else
        Map.put(allowed, "GIT_CONFIG_COUNT", "0")
      end

    run_command(
      timeout_binary,
      command_args,
      scrubbed_environment(allowed),
      timeout_ms + 2_500
    )
  end

  defp request(method, path, authorization, body \\ nil) do
    url = @api <> path

    headers = [
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"authorization", String.to_charlist(authorization)},
      {~c"user-agent", ~c"ptc-manager-github-app-broker"},
      {~c"x-github-api-version", String.to_charlist(@api_version)}
    ]

    request =
      case method do
        :get ->
          {String.to_charlist(url), headers}

        :post ->
          {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body || %{})}
      end

    ssl_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    http_options = [timeout: 20_000, connect_timeout: 5_000, ssl: ssl_options]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        decode_json(response_body)

      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        message =
          case Jason.decode(response_body) do
            {:ok, %{"message" => value}} when is_binary(value) -> String.slice(value, 0, 300)
            _response -> "GitHub returned HTTP #{status}"
          end

        {:error,
         {:github_http_error, status, message,
          rate_limit_delay_ms(status, message, response_headers)}}

      {:error, reason} ->
        {:error, {:github_transport_error, reason}}
    end
  end

  defp decode_json(body) when byte_size(body) <= 2_000_000 do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_github_json, reason}}
    end
  end

  defp decode_json(_body), do: {:error, :github_response_too_large}

  defp rate_limit_delay_ms(status, message, headers) when status in [403, 429] do
    retry_after = parse_positive_integer(response_header(headers, "retry-after"))
    reset_at = parse_positive_integer(response_header(headers, "x-ratelimit-reset"))
    remaining = response_header(headers, "x-ratelimit-remaining")

    rate_limited =
      status == 429 or is_integer(retry_after) or remaining == "0" or
        String.contains?(String.downcase(message), "rate limit")

    if rate_limited do
      reset_delay = if reset_at, do: max(reset_at - System.system_time(:second), 1)
      seconds = retry_after || reset_delay || 60
      min(max(seconds * 1_000, 1_000), 86_400_000)
    end
  end

  defp rate_limit_delay_ms(_status, _message, _headers), do: nil

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp response_header(headers, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if name |> List.to_string() |> String.downcase() == expected_name,
        do: List.to_string(value)
    end)
  end

  defp run_command(command, args, environment, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, command},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: args,
          env: environment,
          cd: "/"
        ]
      )

    receive_command(port, "", System.monotonic_time(:millisecond) + timeout_ms)
  rescue
    _error -> {:error, :git_command_unavailable}
  end

  defp receive_command(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= @output_limit ->
        receive_command(port, output <> data, deadline)

      {^port, {:data, _data}} ->
        close_port(port, :git_output_too_large)

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, {:git_command_failed, status}}
    after
      remaining -> close_port(port, :git_command_timeout)
    end
  end

  defp close_port(port, reason) do
    Port.close(port)
    {:error, reason}
  rescue
    ArgumentError -> {:error, reason}
  end

  defp scrubbed_environment(allowed) do
    System.get_env()
    |> Map.new(fn {key, _value} -> {key, false} end)
    |> Map.merge(allowed)
    |> Enum.map(fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp safe_repository_component?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value) and value not in [".", ".."]

  defp safe_repository_component?(_value), do: false

  defp safe_ref?(value) when is_binary(value) do
    byte_size(value) in 1..240 and Regex.match?(~r/\A[A-Za-z0-9._\/-]+\z/, value) and
      not String.starts_with?(value, ["-", "/"]) and not String.ends_with?(value, [".", "/"]) and
      not String.contains?(value, ["..", "@{"])
  end

  defp safe_ref?(_value), do: false

  defp repository_url(repository),
    do: "https://github.com/#{repository.github_owner}/#{repository.github_name}.git"

  defp repo_path(repository, suffix),
    do: "/repos/#{repository.github_owner}/#{repository.github_name}#{suffix}"

  defp base64url(value), do: Base.url_encode64(value, padding: false)
end
