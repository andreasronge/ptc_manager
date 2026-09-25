defmodule PtcManager.ManagedOperationContext do
  @moduledoc false

  @max_age_seconds 7 * 24 * 60 * 60
  @pane_handshake_attempts 2

  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.Operations.AgentRun
  alias PtcManager.Repo

  def prepare_job(command, pane_id, job) do
    prepare(
      command,
      pane_id,
      %{
        owner_type: "job",
        owner_id: job.id,
        repository_id: job.repository_id,
        worker_id: job.worktree_allocation.worker_id,
        pane_id: pane_id,
        fencing_token: job.fencing_token
      },
      environment: AgentEnvironmentVariables.list(job.repository_id)
    )
  end

  def prepare_action(command, pane_id, action) do
    prepare(command, pane_id, action_attrs(action, pane_id))
  end

  def rebind_action(pane_id, action) do
    if enabled?() do
      with {:ok, context} <-
             issue(action_attrs(action, pane_id), path: pane_context_path(pane_id)),
           {:ok, nil} <- write_environment(context.path, nil) do
        {:ok, context}
      end
    else
      {:ok, nil}
    end
  end

  def enabled? do
    path = Application.get_env(:ptc_manager, :resource_operation_socket_path)
    is_binary(path) and path != ""
  end

  def issue(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    directory = Keyword.get(opts, :directory, context_directory())
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    payload =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "context_id" => id,
        "issued_at" => DateTime.to_unix(now),
        "socket_path" => socket_path(),
        "wrapper" => wrapper_path(),
        "lock_directory" => lock_directory(),
        "cgroups" => Application.get_env(:ptc_manager, :resource_operation_cgroups, false),
        "operation_memory_high_bytes" =>
          Application.get_env(:ptc_manager, :operation_memory_high_bytes, 2_147_483_648),
        "verify_operation_memory_high_bytes" =>
          Application.get_env(:ptc_manager, :verify_operation_memory_high_bytes, 2_577_399_808),
        "verify_agent_memory_high_bytes" =>
          Application.get_env(:ptc_manager, :verify_agent_memory_high_bytes, 2_952_790_016),
        "operation_memory_max_bytes" =>
          Application.get_env(:ptc_manager, :operation_memory_max_bytes, 2_684_354_560)
      })

    token = sign(payload)
    path = Keyword.get(opts, :path, Path.join(directory, "#{id}.json"))
    body = Jason.encode!(Map.put(payload, "token", token))

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o2750),
         :ok <- write_context(path, body) do
      {:ok, %{path: path, token: token, payload: payload}}
    end
  end

  def verify(token, opts \\ []) when is_binary(token) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with [encoded, supplied_mac] <- String.split(token, ".", parts: 2),
         {:ok, expected_mac} <- decode64(mac(encoded)),
         {:ok, actual_mac} <- decode64(supplied_mac),
         true <- Plug.Crypto.secure_compare(expected_mac, actual_mac),
         {:ok, json} <- decode64(encoded),
         {:ok, payload} when is_map(payload) <- Jason.decode(json),
         issued_at when is_integer(issued_at) <- payload["issued_at"],
         true <- issued_at <= DateTime.to_unix(now),
         true <- DateTime.to_unix(now) - issued_at <= @max_age_seconds do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid_managed_operation_context}
    end
  end

  def shell_command(path, payload, opts \\ []) do
    environment_prefix =
      case Keyword.get(opts, :environment) do
        path when is_binary(path) ->
          "set -a && . " <> shell_quote(path) <> " && set +a && "

        nil ->
          ""
      end

    marker_command =
      "printf '\\n%s:%s\\n' " <>
        shell_quote("PTC_OPERATION_CONTEXT_READY") <>
        " " <>
        shell_quote(payload["context_id"])

    if payload["cgroups"] do
      context_exports =
        [
          {"PTC_CONTEXT_PATH", path},
          {"PTC_CONTEXT_ID", payload["context_id"]},
          {"PTC_AGENT_MEMORY_HIGH",
           max(
             Application.get_env(:ptc_manager, :agent_memory_high_bytes, 2_684_354_560),
             Map.get(payload, "verify_agent_memory_high_bytes", 2_952_790_016)
           )},
          {"PTC_AGENT_MEMORY_MAX",
           Application.get_env(:ptc_manager, :agent_memory_max_bytes, 3_221_225_472)},
          {"PTC_OPERATION_WRAPPER", wrapper_path()}
        ]
        |> Enum.map_join(" ", fn {name, value} ->
          name <> "=" <> shell_quote(to_string(value))
        end)

      environment_prefix <>
        "export " <>
        context_exports <>
        " && . " <>
        shell_quote(agent_context_path()) <>
        " && " <>
        marker_command
    else
      environment_prefix <>
        "export PTC_MANAGED_OPERATION_CONTEXT=" <>
        shell_quote(path) <>
        " PTC_OPERATION_WRAPPER=" <>
        shell_quote(wrapper_path()) <>
        " && " <>
        marker_command
    end
  end

  def cleanup_expired(directory \\ context_directory()) do
    cutoff = System.os_time(:second) - @max_age_seconds

    case File.ls(directory) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          path = Path.join(directory, name)

          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} when mtime < cutoff ->
              remove_context_pair(path)

            _other ->
              :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  def cleanup_inactive(active?, directory \\ context_directory()) when is_function(active?, 1) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          path = Path.join(directory, name)

          with {:ok, body} <- File.read(path),
               {:ok, payload} when is_map(payload) <- Jason.decode(body),
               false <- active?.(payload) do
            remove_context_pair(path)
          else
            _active_or_unreadable -> :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp prepare(command, pane_id, attrs, opts \\ []) do
    if enabled?() do
      case issue(attrs, path: pane_context_path(pane_id)) do
        {:ok, context} ->
          with {:ok, environment_path} <- write_environment(context.path, opts[:environment]),
               {:ok, _output} <-
                 establish_pane_context(
                   command,
                   pane_id,
                   context,
                   environment_path,
                   @pane_handshake_attempts
                 ) do
            {:ok, context}
          else
            {:error, _reason} = error ->
              remove_context_pair(context.path)
              error
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  defp establish_pane_context(command, pane_id, context, environment_path, attempts_left) do
    marker = "PTC_OPERATION_CONTEXT_READY:#{context.payload["context_id"]}"

    with {:ok, _output} <-
           command.run([
             "pane",
             "run",
             pane_id,
             shell_command(context.path, context.payload, environment: environment_path)
           ]) do
      await_pane_context(command, pane_id, marker, attempts_left)
    end
  end

  defp await_pane_context(command, pane_id, marker, attempts_left) do
    case command.run(pane_wait_args(pane_id, marker)) do
      {:error, reason} when attempts_left > 0 ->
        if pane_wait_timeout?(reason) do
          case read_visible_pane(command, pane_id, marker) do
            {:ok, output} ->
              {:ok, output}

            :not_found when attempts_left > 1 ->
              await_pane_context(command, pane_id, marker, attempts_left - 1)

            :not_found ->
              {:error, reason}

            {:error, read_reason} ->
              {:error, read_reason}
          end
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp read_visible_pane(command, pane_id, marker) do
    case command.run([
           "pane",
           "read",
           pane_id,
           "--source",
           "visible",
           "--lines",
           "30",
           "--format",
           "text"
         ]) do
      {:ok, output} when is_binary(output) ->
        if String.contains?(output, marker), do: {:ok, output}, else: :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pane_wait_args(pane_id, marker) do
    [
      "pane",
      "wait-output",
      pane_id,
      "--match",
      marker,
      "--source",
      "visible",
      "--lines",
      "20",
      "--timeout",
      "10000"
    ]
  end

  defp pane_wait_timeout?({:herdr_exit, 1, output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok,
       %{
         "id" => "cli:pane:wait-output",
         "error" => %{"code" => "timeout"}
       }} ->
        true

      _other ->
        false
    end
  end

  defp pane_wait_timeout?(_reason), do: false

  defp action_attrs(action, pane_id) do
    run =
      Repo.get_by!(AgentRun,
        agent_action_id: action.id,
        fencing_token: action.attempt_count
      )

    %{
      owner_type: "agent_action",
      owner_id: action.id,
      repository_id: action.repository_id,
      worker_id: run.worker_id,
      pane_id: pane_id,
      fencing_token: action.attempt_count
    }
  end

  defp pane_context_path(pane_id) do
    digest = :crypto.hash(:sha256, pane_id) |> Base.url_encode64(padding: false)
    Path.join(context_directory(), "pane-#{digest}.json")
  end

  defp write_context(path, body) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, body, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o440),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp write_environment(context_path, nil) do
    File.rm(environment_path(context_path))
    {:ok, nil}
  end

  defp write_environment(context_path, variables) do
    path = environment_path(context_path)

    body =
      Enum.map_join(variables, "", fn variable ->
        variable.name <> "=" <> shell_quote(variable.value) <> "\n"
      end)

    case write_context(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:environment_file_write_failed, reason}}
    end
  end

  defp remove_context_pair(path) do
    File.rm(path)

    if Path.extname(path) == ".json" do
      File.rm(environment_path(path))
    end

    :ok
  end

  defp environment_path(context_path), do: Path.rootname(context_path, ".json") <> ".env"

  defp sign(payload) do
    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    encoded <> "." <> mac(encoded)
  end

  defp mac(encoded) do
    :crypto.mac(:hmac, :sha256, secret(), encoded)
    |> Base.url_encode64(padding: false)
  end

  defp decode64(value), do: Base.url_decode64(value, padding: false)

  defp secret do
    Application.get_env(:ptc_manager, :resource_operation_secret) ||
      PtcManagerWeb.Endpoint.config(:secret_key_base)
  end

  defp socket_path,
    do:
      Application.get_env(
        :ptc_manager,
        :resource_operation_socket_path,
        "/var/lib/ptc_manager-worker/agent-results/operations.sock"
      )

  defp wrapper_path,
    do:
      Application.get_env(
        :ptc_manager,
        :resource_operation_wrapper,
        "/usr/local/bin/ptc-operation"
      )

  defp lock_directory do
    case socket_path() do
      path when is_binary(path) and path != "" -> Path.dirname(path)
      _disabled -> System.tmp_dir!()
    end
  end

  defp context_directory,
    do:
      Application.get_env(
        :ptc_manager,
        :resource_operation_context_dir,
        "/var/lib/ptc_manager-worker/agent-results/operation-contexts"
      )

  defp agent_context_path,
    do:
      Application.get_env(
        :ptc_manager,
        :resource_operation_agent_context,
        "/usr/local/libexec/ptc-manager-agent-context"
      )

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
