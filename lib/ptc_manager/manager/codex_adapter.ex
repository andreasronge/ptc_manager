defmodule PtcManager.Manager.CodexAdapter do
  @moduledoc "Runs an ephemeral Codex analysis with a read-only local repository sandbox."

  @behaviour PtcManager.Manager.Adapter

  alias PtcManager.Automations
  alias PtcManager.Operations.{Issue, Repository}
  alias PtcManager.Repo
  alias PtcManager.Repository.Checkout

  @allowed_environment ~w(
    CODEX_HOME HOME USER LOGNAME PATH LANG LC_ALL LC_CTYPE
    TMPDIR TEMP TMP XDG_CONFIG_HOME XDG_CACHE_HOME
    SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY
  )

  @impl true
  def analyze(%Issue{repository: repository} = issue) do
    with true <- Application.get_env(:ptc_manager, :manager_enabled, false),
         {:ok, repository_path} <- Checkout.available_path(repository) do
      run_codex(issue, repository_path)
    else
      false ->
        {:error, :manager_disabled}

      {:error, :repository_path_unavailable} ->
        if is_binary(repository.local_path),
          do: {:error, :repository_path_unavailable},
          else: {:error, :repository_path_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_codex(issue, repository_path) do
    output_directory =
      Application.get_env(:ptc_manager, :manager_output_dir) || System.tmp_dir!()

    File.mkdir_p!(output_directory)

    output_path =
      Path.join(
        output_directory,
        "ptc-manager-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(output_path, "")
    File.chmod!(output_path, 0o660)

    binary = Application.get_env(:ptc_manager, :codex_binary, "codex")
    timeout = Application.get_env(:ptc_manager, :manager_timeout_ms, 120_000)

    args = [
      "exec",
      "--ephemeral",
      "--ignore-user-config",
      "--sandbox",
      "read-only",
      "--output-schema",
      schema_path(),
      "--output-last-message",
      output_path,
      "-C",
      repository_path,
      build_prompt(issue)
    ]

    task =
      Task.async(fn ->
        {command, command_args} =
          codex_command(
            binary,
            args,
            Application.get_env(:ptc_manager, :codex_run_as_user)
          )

        System.cmd(command, command_args,
          env: command_environment(),
          stderr_to_stdout: true
        )
      end)

    try do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, 0}} -> decode_output(output_path)
        {:ok, {output, status}} -> {:error, codex_exit_error(status, output)}
        nil -> {:error, :codex_timeout}
      end
    after
      File.rm(output_path)
    end
  rescue
    error -> {:error, {:codex_command_failed, error.__struct__}}
  end

  @doc false
  def build_prompt(%Issue{repository: %Repository{} = repository} = issue) do
    instructions =
      with :ok <- Automations.ensure_defaults(repository),
           {:ok, version} <- Automations.current_version(repository, "private_issue_analysis") do
        version.prompt
      else
        _unavailable -> nil
      end

    build_prompt(issue, instructions)
  end

  def build_prompt(%Issue{repository_id: repository_id} = issue) when is_integer(repository_id) do
    build_prompt(%{issue | repository: Repo.get!(Repository, repository_id)})
  end

  def build_prompt(issue), do: build_prompt(issue, nil)

  @doc false
  def build_prompt(issue, user_prompt) do
    context =
      """
      <runtime_context action="private_issue_analysis" repository="#{issue.repository.github_owner}/#{issue.repository.github_name}" github_access="none" workspace="read_only" allowed_readiness="ready,needs_information,needs_breakdown,outdated,duplicate" />
      <issue_data>
      Number: #{issue.number}
      Title: #{issue.title}
      Body:
      #{String.slice(issue.body || "", 0, 20_000)}
      </issue_data>
      """

    Automations.compose_prompt(user_prompt, context)
  end

  defp decode_output(path) do
    with {:ok, body} <- File.read(path),
         {:ok, analysis} <- Jason.decode(body) do
      {:ok, analysis}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_codex_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def codex_exit_error(status, _output) when is_integer(status) do
    # Codex's combined transcript may contain the untrusted prompt, including text
    # that looks like an error marker. Keep only a stable classification here.
    {:codex_exit, status, :codex_process_failed}
  end

  @doc false
  def schema_path, do: Application.app_dir(:ptc_manager, "priv/codex/manager_output.schema.json")

  @doc false
  def command_environment(environment \\ System.get_env()) do
    allowed =
      environment
      |> Map.take(@allowed_environment)

    environment
    |> Map.new(fn {key, _value} -> {key, nil} end)
    |> Map.merge(allowed)
    |> Map.to_list()
  end

  @doc false
  def codex_command(binary, args, run_as_user)
      when is_binary(run_as_user) and run_as_user != "" do
    {"/usr/bin/sudo", ["-n", "-H", "-u", run_as_user, "--", binary | args]}
  end

  def codex_command(binary, args, _run_as_user), do: {binary, args}
end
