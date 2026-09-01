defmodule PtcManager.ManagedOperationContext do
  @moduledoc false

  @max_age_seconds 7 * 24 * 60 * 60

  alias PtcManager.Operations.AgentRun
  alias PtcManager.Repo

  def prepare_job(command, pane_id, job) do
    prepare(command, pane_id, %{
      owner_type: "job",
      owner_id: job.id,
      repository_id: job.repository_id,
      worker_id: job.worktree_allocation.worker_id,
      pane_id: pane_id,
      fencing_token: job.fencing_token
    })
  end

  def prepare_action(command, pane_id, action) do
    run =
      Repo.get_by!(AgentRun,
        agent_action_id: action.id,
        fencing_token: action.attempt_count
      )

    prepare(command, pane_id, %{
      owner_type: "agent_action",
      owner_id: action.id,
      repository_id: action.repository_id,
      worker_id: run.worker_id,
      pane_id: pane_id,
      fencing_token: action.attempt_count
    })
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
        "operation_memory_max_bytes" =>
          Application.get_env(:ptc_manager, :operation_memory_max_bytes, 2_684_354_560)
      })

    token = sign(payload)
    path = Path.join(directory, "#{id}.json")
    body = Jason.encode!(Map.put(payload, "token", token))

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o2750),
         :ok <- File.write(path, body, [:exclusive]),
         :ok <- File.chmod(path, 0o440) do
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

  def shell_command(path, payload) do
    marker = "PTC_OPERATION_CONTEXT_READY:#{payload["context_id"]}"

    if payload["cgroups"] do
      ". " <>
        shell_quote(agent_context_path()) <>
        " " <>
        Enum.map_join(
          [
            path,
            payload["context_id"],
            Application.get_env(:ptc_manager, :agent_memory_high_bytes, 2_684_354_560),
            Application.get_env(:ptc_manager, :agent_memory_max_bytes, 3_221_225_472),
            wrapper_path()
          ],
          " ",
          &(to_string(&1) |> shell_quote())
        ) <>
        " && printf '\\n#{marker}\\n'"
    else
      "export PTC_MANAGED_OPERATION_CONTEXT=" <>
        shell_quote(path) <>
        " PTC_OPERATION_WRAPPER=" <>
        shell_quote(wrapper_path()) <> " && printf '\\n#{marker}\\n'"
    end
  end

  def cleanup_expired(directory \\ context_directory()) do
    cutoff = System.os_time(:second) - @max_age_seconds

    case File.ls(directory) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          path = Path.join(directory, name)

          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} when mtime < cutoff -> File.rm(path)
            _other -> :ok
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
            File.rm(path)
          else
            _active_or_unreadable -> :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp prepare(command, pane_id, attrs) do
    if enabled?() do
      with {:ok, context} <- issue(attrs),
           marker = "PTC_OPERATION_CONTEXT_READY:#{context.payload["context_id"]}",
           {:ok, _output} <-
             command.run(["pane", "run", pane_id, shell_command(context.path, context.payload)]),
           {:ok, _output} <-
             command.run([
               "pane",
               "wait-output",
               pane_id,
               "--match",
               marker,
               "--source",
               "recent",
               "--lines",
               "20",
               "--timeout",
               "10000"
             ]) do
        {:ok, context}
      end
    else
      {:ok, nil}
    end
  end

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
