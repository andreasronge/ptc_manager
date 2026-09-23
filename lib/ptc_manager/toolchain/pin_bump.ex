defmodule PtcManager.Toolchain.PinBump do
  @moduledoc "Freezes a pin bump and verifies the exact draft PR produced for it."

  alias PtcManager.Deployments.GitHubRevisionSource
  alias PtcManager.Gateway
  alias PtcManager.GitHub.Client
  alias PtcManager.Toolchain.{Check, Manifest}
  alias PtcManager.Toolchain
  alias PtcManager.Repo

  @path "deploy/toolchain-versions"
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  def prepare(repository, program)
      when program in ["codex", "claude_code", "pnpm", "node", "herdr", "mise", "cursor_agent"] do
    source = source()

    with %Check{
           status: "ok",
           version: version,
           digest: digest,
           protocol: protocol,
           checked_at: checked_at
         } <-
           Repo.get_by(Check, program: program),
         :ok <- ensure_own_repository(repository),
         age = DateTime.diff(DateTime.utc_now(), checked_at, :second),
         true <- age >= 0 and age < 86_400,
         :ok <- valid_metadata(program, digest, protocol),
         {:ok, sha} <- Gateway.call(source, :latest, [repository]),
         {:ok, content} <- Gateway.call(source, :content, [repository, sha, @path]),
         {:ok, _changes} <- Toolchain.preview(content),
         {:ok, current} <- pin(content, program),
         :ok <- allowed_update(program, current, version),
         {:ok, expected} <- replace_pin(content, program, version, digest, protocol) do
      {:ok,
       %{
         "program" => program,
         "current" => current,
         "version" => version,
         "digest" => digest,
         "protocol" => protocol,
         "source_sha" => sha,
         "expected_manifest" => expected
       }}
    else
      nil -> {:error, :upstream_check_missing}
      false -> {:error, :upstream_check_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(_repository, _program), do: {:error, :unsupported_program}

  def preflight(%{repository: repository, target_snapshot: %{"source_sha" => expected_sha}}) do
    if Toolchain.own_repository?(repository) do
      case Gateway.call(source(), :latest, [repository]) do
        {:ok, ^expected_sha} -> :ok
        {:ok, _other} -> {:error, :toolchain_source_moved}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :toolchain_repository_mismatch}
    end
  end

  def verify(%{repository: repository, target_snapshot: snapshot}, %{"pr_number" => number})
      when is_integer(number) and number > 0 do
    owner = URI.encode_www_form(repository.github_owner)
    name = URI.encode_www_form(repository.github_name)
    base = "https://api.github.com/repos/#{owner}/#{name}/pulls/#{number}"
    client = Application.get_env(:ptc_manager, :toolchain_pr_client, Client)

    with :ok <- ensure_own_repository(repository),
         {:ok, pr} <- Gateway.call(client, :get_json, [base]),
         :ok <- verify_pr(pr, repository, snapshot),
         {:ok, [%{"filename" => @path, "status" => "modified"}]} <-
           Gateway.call(client, :get_json, [base <> "/files?per_page=100"]),
         head_sha when is_binary(head_sha) <- get_in(pr, ["head", "sha"]),
         true <- Regex.match?(@sha, head_sha),
         {:ok, manifest} <- Gateway.call(source(), :content, [repository, head_sha, @path]),
         true <- manifest == snapshot["expected_manifest"] do
      {:ok, %{pull_request: number, head_sha: head_sha}}
    else
      {:terminal_error, reason} ->
        {:terminal_error, reason}

      {:error, :toolchain_repository_mismatch} ->
        {:terminal_error, :toolchain_repository_mismatch}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:terminal_error, :toolchain_pull_request_mismatch}
    end
  end

  def verify(_action, _result), do: {:terminal_error, :toolchain_result_missing_pull_request}

  defp verify_pr(pr, repository, snapshot) do
    expected_repo = repository.github_owner <> "/" <> repository.github_name

    if pr["state"] == "open" and pr["draft"] == true and pr["changed_files"] == 1 and
         get_in(pr, ["base", "sha"]) == snapshot["source_sha"] and
         get_in(pr, ["base", "ref"]) == repository.default_branch and
         get_in(pr, ["base", "repo", "full_name"]) == expected_repo and
         get_in(pr, ["head", "repo", "full_name"]) == expected_repo do
      :ok
    else
      {:terminal_error, :toolchain_pull_request_mismatch}
    end
  end

  defp pin(content, program) do
    try do
      {:ok, Manifest.parse!(content) |> Map.fetch!(program)}
    rescue
      _ -> {:error, :invalid_toolchain_manifest}
    end
  end

  defp allowed_update(current, version) do
    with {:ok, from} <- Version.parse(current),
         {:ok, to} <- Version.parse(version),
         :gt <- Version.compare(to, from),
         true <- from.major == to.major do
      :ok
    else
      _ -> {:error, :toolchain_update_not_eligible}
    end
  end

  defp allowed_update("cursor_agent", current, version) do
    with {:ok, from} <- cursor_date(current),
         {:ok, to} <- cursor_date(version),
         :gt <- Date.compare(to, from),
         true <- from.year == to.year do
      :ok
    else
      _ -> {:error, :toolchain_update_not_eligible}
    end
  end

  defp allowed_update(_program, current, version), do: allowed_update(current, version)

  defp cursor_date(version) do
    case Regex.run(~r/\A([0-9]{4})\.([0-9]{2})\.([0-9]{2})-[0-9a-f]+\z/, version,
           capture: :all_but_first
         ) do
      [year, month, day] -> Date.from_iso8601("#{year}-#{month}-#{day}")
      _ -> {:error, :invalid_cursor_version}
    end
  end

  defp replace_pin(content, program, version, digest, protocol) do
    changes =
      [{program, version}] ++
        case program do
          "herdr" -> [{"herdr_protocol", Integer.to_string(protocol)}, {"herdr_sha256", digest}]
          "mise" -> [{"mise_sha256", digest}]
          "cursor_agent" -> [{"cursor_agent_sha256", digest}]
          _ -> []
        end

    pinned = Manifest.parse!(content)

    Enum.reduce_while(changes, {:ok, content}, fn {key, value}, {:ok, current_content} ->
      old_line = "#{key}=#{Map.fetch!(pinned, key)}"
      new_line = "#{key}=#{value}"
      lines = String.split(current_content, "\n")

      if is_binary(value) and Enum.count(lines, &(&1 == old_line)) == 1 do
        updated =
          lines |> Enum.map(&if(&1 == old_line, do: new_line, else: &1)) |> Enum.join("\n")

        {:cont, {:ok, updated}}
      else
        {:halt, {:error, :invalid_toolchain_manifest}}
      end
    end)
  end

  defp source,
    do: Application.get_env(:ptc_manager, :deployment_revision_source, GitHubRevisionSource)

  defp valid_metadata("herdr", digest, protocol)
       when is_binary(digest) and is_integer(protocol) and protocol > 0 do
    if Regex.match?(@digest, digest), do: :ok, else: {:error, :invalid_toolchain_digest}
  end

  defp valid_metadata("mise", digest, nil) when is_binary(digest) do
    if Regex.match?(@digest, digest), do: :ok, else: {:error, :invalid_toolchain_digest}
  end

  defp valid_metadata("cursor_agent", digest, nil) when is_binary(digest) do
    if Regex.match?(@digest, digest), do: :ok, else: {:error, :invalid_toolchain_digest}
  end

  defp valid_metadata(program, nil, nil) when program in ["codex", "claude_code", "pnpm", "node"],
    do: :ok

  defp valid_metadata(_program, _digest, _protocol), do: {:error, :invalid_toolchain_metadata}

  defp ensure_own_repository(repository) do
    if Toolchain.own_repository?(repository),
      do: :ok,
      else: {:error, :toolchain_repository_mismatch}
  end
end
