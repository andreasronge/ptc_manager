defmodule PtcManager.ResourceOperationBroker do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias PtcManager.ManagedOperationContext
  alias PtcManager.Operations.{AgentAction, AgentRun, Job}
  alias PtcManager.Operations.ResourceOperation
  alias PtcManager.Repo
  alias PtcManager.ResourceOperations

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:ptc_manager, :resource_operation_socket_path)

    if is_binary(path) and path != "" do
      ManagedOperationContext.cleanup_expired()
      File.mkdir_p!(Path.dirname(path))
      File.rm(path)

      case :gen_tcp.listen(0, [
             :binary,
             packet: :line,
             active: false,
             reuseaddr: true,
             ifaddr: {:local, path},
             backlog: 64
           ]) do
        {:ok, listener} ->
          File.chmod!(path, 0o660)
          {:ok, acceptor} = Task.start_link(fn -> accept_loop(listener) end)
          schedule_sweep()
          {:ok, %{listener: listener, acceptor: acceptor, path: path}}

        {:error, reason} ->
          {:stop, {:resource_operation_socket_failed, reason}}
      end
    else
      {:ok, %{listener: nil, acceptor: nil, path: nil}}
    end
  end

  @impl true
  def terminate(_reason, %{listener: listener, path: path}) do
    if listener, do: :gen_tcp.close(listener)
    if path, do: File.rm(path)
    :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    ResourceOperations.mark_stale_recovery_pending()
    ManagedOperationContext.cleanup_inactive(&owner_active?/1)
    schedule_sweep()
    {:noreply, state}
  end

  def dispatch(request) when is_map(request) do
    with {:ok, payload} <- ManagedOperationContext.verify(request["token"] || ""),
         :ok <- validate_request_context(payload, request) do
      handle_request(request, payload)
    else
      {:error, reason} -> %{"status" => "error", "error" => to_string(reason)}
    end
  rescue
    error -> %{"status" => "error", "error" => inspect(error.__struct__)}
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Task.start(fn -> serve(socket) end)
        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listener)
    end
  end

  defp serve(socket) do
    response =
      with {:ok, line} <- :gen_tcp.recv(socket, 0, 10_000),
           {:ok, request} when is_map(request) <- Jason.decode(line) do
        dispatch(request)
      else
        _invalid -> %{"status" => "error", "error" => "invalid_request"}
      end

    :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    :gen_tcp.close(socket)
  end

  defp handle_request(%{"operation" => "request"} = request, payload) do
    with {:ok, run} <- active_run(payload),
         {:ok, operation} <-
           ResourceOperations.request(%{
             worker_id: integer(payload, "worker_id"),
             repository_id: integer(payload, "repository_id"),
             job_id: owner_id(payload, "job"),
             agent_action_id: owner_id(payload, "agent_action"),
             agent_run_id: run.id,
             invocation_id: request["invocation_id"],
             label: request["label"],
             priority: operation_priority(run),
             state: "queued"
           }) do
      operation_response(operation)
    else
      {:error, reason} -> error_response(reason)
    end
  end

  defp handle_request(%{"operation" => "acquire", "operation_id" => id}, payload) do
    case active_owned_operation(id, payload) do
      {:ok, _operation} ->
        _ = ResourceOperations.claim_next(integer(payload, "worker_id"))

        case owned_operation(id, payload) do
          %ResourceOperation{} = operation -> operation_response(operation)
          nil -> error_response(:operation_not_found)
        end

      {:cancelled, operation} ->
        operation_response(operation)

      {:error, reason} ->
        error_response(reason)
    end
  end

  defp handle_request(%{"operation" => "running", "operation_id" => id} = request, payload) do
    with {:ok, operation} <- active_owned_operation(id, payload),
         {:ok, operation} <-
           ResourceOperations.mark_running(operation.id, request["attempt_token"], %{
             wrapper_pid: request["wrapper_pid"],
             cgroup_path: request["cgroup_path"]
           }) do
      operation_response(operation)
    else
      {:cancelled, operation} -> operation_response(operation)
      {:error, reason} -> error_response(reason)
    end
  end

  defp handle_request(%{"operation" => "heartbeat", "operation_id" => id} = request, payload) do
    with {:ok, operation} <- active_owned_operation(id, payload),
         {:ok, operation} <- ResourceOperations.heartbeat(operation.id, request["attempt_token"]) do
      operation_response(operation)
    else
      {:cancelled, operation} -> operation_response(operation)
      {:error, reason} -> error_response(reason)
    end
  end

  defp handle_request(%{"operation" => "finish", "operation_id" => id} = request, payload) do
    with %ResourceOperation{} = operation <- owned_operation(id, payload),
         {:ok, operation} <-
           ResourceOperations.finish(operation.id, request["attempt_token"], %{
             exit_status: request["exit_status"],
             peak_memory_bytes: request["peak_memory_bytes"],
             last_error: request["last_error"]
           }) do
      operation_response(operation)
    else
      nil -> error_response(:operation_not_found)
      {:error, reason} -> error_response(reason)
    end
  end

  defp handle_request(_request, _payload), do: error_response(:unsupported_operation)

  defp active_run(payload) do
    owner_type = payload["owner_type"]
    owner_id = integer(payload, "owner_id")
    pane = payload["pane_id"]
    fence = integer(payload, "fencing_token")

    query =
      AgentRun
      |> where([run], is_nil(run.herdr_pane) or run.herdr_pane == ^pane)
      |> where([run], run.fencing_token == ^fence)
      |> where([run], run.state in ~w(queued starting working idle blocked waiting unknown))

    query =
      case owner_type do
        "job" -> where(query, [run], run.job_id == ^owner_id)
        "agent_action" -> where(query, [run], run.agent_action_id == ^owner_id)
        _other -> where(query, [run], false)
      end

    case Repo.one(query) do
      %AgentRun{herdr_pane: nil} = run ->
        run
        |> AgentRun.changeset(%{herdr_pane: pane, last_heartbeat_at: now()})
        |> Repo.update()

      %AgentRun{} = run ->
        {:ok, run}

      nil when owner_type == "job" ->
        %AgentRun{}
        |> AgentRun.changeset(%{
          worker_id: integer(payload, "worker_id"),
          job_id: owner_id,
          role: "implementer",
          state: "starting",
          status_text: "Agent started; waiting for dispatch acknowledgement.",
          started_at: now(),
          last_heartbeat_at: now(),
          herdr_pane: pane,
          fencing_token: fence
        })
        |> Repo.insert()

      nil ->
        {:error, :active_agent_run_not_found}
    end
  end

  defp owned_operation(id, payload) do
    case Integer.parse(to_string(id)) do
      {operation_id, ""} ->
        ResourceOperation
        |> where([operation], operation.id == ^operation_id)
        |> where([operation], operation.worker_id == ^integer(payload, "worker_id"))
        |> where([operation], operation.repository_id == ^integer(payload, "repository_id"))
        |> owner_where(payload)
        |> Repo.one()

      _invalid ->
        nil
    end
  end

  defp active_owned_operation(id, payload) do
    case owned_operation(id, payload) do
      nil ->
        {:error, :operation_not_found}

      %ResourceOperation{} = operation ->
        if owner_active?(payload) do
          {:ok, operation}
        else
          case ResourceOperations.cancel(operation.id, "Owning work is no longer active.") do
            {:ok, cancelled} -> {:cancelled, cancelled}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp owner_active?(%{"owner_type" => "job"} = payload) do
    case Repo.get(Job, integer(payload, "owner_id")) do
      %Job{state: state} ->
        state in ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked)

      nil ->
        false
    end
  end

  defp owner_active?(%{"owner_type" => "agent_action"} = payload) do
    case Repo.get(AgentAction, integer(payload, "owner_id")) do
      %AgentAction{state: state} -> state in ~w(running sync_pending)
      nil -> false
    end
  end

  defp owner_active?(_payload), do: false

  defp owner_where(query, %{"owner_type" => "job"} = payload),
    do: where(query, [operation], operation.job_id == ^integer(payload, "owner_id"))

  defp owner_where(query, %{"owner_type" => "agent_action"} = payload),
    do: where(query, [operation], operation.agent_action_id == ^integer(payload, "owner_id"))

  defp owner_where(query, _payload), do: where(query, [operation], false)

  defp validate_request_context(payload, request) do
    if payload["context_id"] == request["context_id"],
      do: :ok,
      else: {:error, :context_mismatch}
  end

  defp owner_id(payload, type) do
    if payload["owner_type"] == type, do: integer(payload, "owner_id"), else: nil
  end

  defp integer(payload, key) do
    case payload[key] do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
    end
  end

  defp operation_response(operation) do
    %{
      "status" => operation.state,
      "operation_id" => operation.id,
      "slot_number" => operation.slot_number,
      "attempt_token" => operation.attempt_token,
      "cancel_requested" => operation.state == "cancelling"
    }
  end

  defp error_response(reason), do: %{"status" => "error", "error" => inspect(reason)}

  defp operation_priority(%AgentRun{agent_action_id: action_id}) when is_integer(action_id) do
    case Repo.get(AgentAction, action_id) do
      %AgentAction{action_key: "repair_and_merge_pr"} -> 500
      %AgentAction{action_key: "repair_pr"} -> 400
      _action -> 100
    end
  end

  defp operation_priority(%AgentRun{job_id: job_id}) when is_integer(job_id), do: 300
  defp operation_priority(_run), do: 100

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, 10_000)
  end
end
