defmodule PtcManager.Machine.Inventory do
  @moduledoc """
  Keeps this machine's tool inventory, per execution context, in memory.

  Agents and `$PTC_OPERATION_WRAPPER` commands run in Herdr panes (`pane`);
  workspace setup runs through sudo from the coordinator's own sandbox
  (`setup`). A tool can be reachable in one and not the other, so each context
  is probed as the identity and environment that context really has.

  On a Linux service the pane context is probed by a oneshot systemd unit with
  the Herdr service's sandbox, on a timer and on refresh, and the setup context
  is probed here through the same sudo path as the bootstrap helper. Elsewhere
  (macOS, development) both contexts are the service account, so one probe run
  here is recorded for both. Snapshots land in `tool-inventory-<context>.json`
  and are reread every 30 seconds.

  The parsed inventory lives in an ETS table, so readers never call this
  process and nothing is written per tick. Only a change in the evaluated tool
  lines is persisted, as the audit event `machine.inventory_changed`.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias PtcManager.Machine.{ToolInventory, ToolProbes}
  alias PtcManager.Operations.AuditEvent
  alias PtcManager.{CommandEnvironment, Repo, SystemdUnit}

  @topic "machine_usage"
  @catalog_file "tool-probe-catalog.json"
  @pane_unit "ptc_manager-tool-probe.service"
  @probe_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The current inventory: `%{contexts: %{"pane" => parsed | nil, "setup" => ...},
  errors: %{context => reason}, probing?: boolean}`.
  """
  def current(server \\ __MODULE__) do
    case :ets.whereis(server) do
      :undefined -> empty()
      table -> lookup(table)
    end
  end

  defp lookup(table) do
    case :ets.lookup(table, :inventory) do
      [{:inventory, inventory}] -> inventory
      [] -> empty()
    end
  rescue
    ArgumentError -> empty()
  end

  defp empty do
    %{contexts: Map.new(ToolInventory.contexts(), &{&1, nil}), errors: %{}, probing?: false}
  end

  @doc "Starts a fresh probe of every context; results arrive on the `machine_usage` topic."
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc false
  # Tests and the demo seed set a parsed context directly.
  def put_context(context, parsed, server \\ __MODULE__)
      when context in ["pane", "setup"] do
    GenServer.call(server, {:put_context, context, parsed})
  end

  @doc false
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc """
  Evaluated tool lines: one per context and catalog probe, with the status,
  version, staleness, and capture time the gate and the audit trail use.
  """
  def lines(inventory \\ current(), now \\ DateTime.utc_now()) do
    max_age_ms = ToolInventory.max_age_ms()

    for context <- ToolInventory.contexts(), probe <- ToolProbes.catalog() do
      case inventory.contexts[context] do
        nil ->
          %{
            "context" => context,
            "name" => probe.name,
            "status" => "no_inventory",
            "version" => nil,
            "stale" => false,
            "captured_at" => nil
          }

        parsed ->
          tool = Map.get(parsed.tools, probe.name, %{status: "not_probed", version: nil})

          %{
            "context" => context,
            "name" => probe.name,
            "status" => tool.status,
            "version" => tool.version,
            "stale" => ToolInventory.stale?(parsed, now, max_age_ms),
            "captured_at" => DateTime.to_iso8601(parsed.captured_at)
          }
      end
    end
  end

  defp signature(lines), do: Enum.map(lines, &Map.delete(&1, "captured_at"))

  ## Server

  @impl true
  def init(opts) do
    # An invalid PTC_TOOL_PROBES_JSON stops the boot here rather than at the
    # first probe.
    _catalog = ToolProbes.catalog()

    # The table is named after the process, so readers find it without a call.
    table = Keyword.get(opts, :name, __MODULE__)
    :ets.new(table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(table, {:inventory, empty()})

    enabled? = Keyword.get(opts, :enabled, config(:tool_inventory_enabled, true))

    state = %{
      table: table,
      enabled?: enabled?,
      directory: Keyword.get(opts, :directory, config(:tool_inventory_dir, nil)),
      reload_ms:
        Keyword.get(opts, :reload_ms, config(:tool_inventory_reload_interval_ms, 30_000)),
      probe_ms: Keyword.get(opts, :probe_ms, config(:tool_probe_interval_ms, 600_000)),
      task: nil,
      deadline: nil,
      signature: :unloaded
    }

    if enabled? do
      write_catalog(state)
      send(self(), :reload)
      Process.send_after(self(), :probe, Keyword.get(opts, :first_probe_ms, 5_000))
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    pane =
      case pane_unit_start() do
        :not_configured -> :ok
        result -> result
      end

    state = start_probe(state)
    {:reply, pane, state}
  end

  def handle_call({:put_context, context, parsed}, _from, state) do
    inventory = current(state.table)
    store(state, %{inventory | contexts: Map.put(inventory.contexts, context, parsed)})
    {:reply, :ok, observe_transition(state)}
  end

  def handle_call(:clear, _from, state) do
    store(state, empty())
    {:reply, :ok, %{state | signature: :unloaded}}
  end

  @impl true
  def handle_info(:reload, state) do
    Process.send_after(self(), :reload, state.reload_ms)
    {:noreply, state |> reload() |> observe_transition()}
  end

  def handle_info(:probe, state) do
    Process.send_after(self(), :probe, state.probe_ms)
    {:noreply, start_probe(state)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = finish_probe(state)

    case result do
      {:ok, documents} ->
        Enum.each(documents, fn {context, document} ->
          write_snapshot(state, context, document)
        end)

        {:noreply, state |> clear_error() |> reload(Map.new(documents)) |> observe_transition()}

      {:error, reason} ->
        Logger.warning("tool probe failed: #{inspect(reason)}")
        {:noreply, record_error(state, reason)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("tool probe crashed: #{inspect(reason)}")
    {:noreply, state |> finish_probe() |> record_error(:probe_crashed)}
  end

  def handle_info({:probe_deadline, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(PtcManager.TaskSupervisor, task.pid)
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish_probe() |> record_error(:probe_timeout)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Probing

  defp start_probe(%{task: %Task{}} = state), do: state

  defp start_probe(state) do
    catalog_path = write_catalog(state)
    task = Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn -> probe(catalog_path) end)
    deadline_ms = ToolProbes.max_probes() * @probe_timeout_ms + 10_000
    Process.send_after(self(), {:probe_deadline, task.ref}, deadline_ms)
    set_probing(state, true)
    %{state | task: task}
  end

  defp finish_probe(state) do
    set_probing(state, false)
    %{state | task: nil}
  end

  # On a Linux service the pane context belongs to the systemd unit, and this
  # process probes setup through the worker's sudo rule. Without a job user
  # both contexts are this service account.
  defp probe(nil), do: {:error, :tool_inventory_directory_not_configured}

  defp probe(catalog_path) do
    case config(:herdr_run_as_user, nil) do
      user when is_binary(user) and user != "" ->
        with {:ok, document} <- run_probe_script("setup", catalog_path, user) do
          {:ok, [{"setup", document}]}
        end

      _service_account ->
        with {:ok, document} <- run_probe_script("pane", catalog_path, nil) do
          {:ok, [{"pane", document}, {"setup", Map.put(document, "context", "setup")}]}
        end
    end
  end

  defp run_probe_script(context, catalog_path, user) do
    {executable, args} =
      case user do
        nil ->
          {"/usr/bin/python3",
           ["-I", Application.app_dir(:ptc_manager, "priv/tool_probe.py"), context, catalog_path]}

        user ->
          CommandEnvironment.command(
            config(:tool_probe_script, "/usr/local/bin/ptc-manager-tool-probe"),
            [context, catalog_path],
            user
          )
      end

    case System.cmd(executable, args, env: CommandEnvironment.scrub(), stderr_to_stdout: false) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, document} when is_map(document) -> {:ok, document}
          _invalid -> {:error, :invalid_probe_output}
        end

      {_output, status} ->
        {:error, {:probe_exit, status}}
    end
  rescue
    error -> {:error, {:probe_unavailable, error.__struct__}}
  end

  defp pane_unit_start do
    command = config(:tool_probe_systemctl_command, nil)

    args =
      config(:tool_probe_systemctl_args, [
        "-n",
        "/bin/systemctl",
        "start",
        "--no-block",
        @pane_unit
      ])

    SystemdUnit.start(command, args, :tool_probe_unit_failed)
  end

  ## Snapshot files

  defp write_catalog(%{directory: directory}) when is_binary(directory) and directory != "" do
    path = Path.join(directory, @catalog_file)

    case write_atomically(path, Jason.encode!(ToolProbes.catalog_document())) do
      :ok ->
        path

      {:error, reason} ->
        Logger.warning("tool probe catalog not written: #{inspect(reason)}")
        nil
    end
  end

  defp write_catalog(_state), do: nil

  defp write_snapshot(%{directory: directory}, context, document)
       when is_binary(directory) and directory != "" do
    path = snapshot_path(directory, context)

    case write_atomically(path, Jason.encode!(document)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("tool inventory not written: #{inspect(reason)}")
    end
  end

  defp write_snapshot(_state, _context, _document), do: :ok

  defp snapshot_path(directory, context),
    do: Path.join(directory, "tool-inventory-#{context}.json")

  defp write_atomically(path, contents) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o640),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  # Fresh documents from this process's own probe win over a file write that
  # may have failed; every other context is reread from disk.
  defp reload(state, fresh \\ %{})

  defp reload(%{directory: directory} = state, fresh)
       when is_binary(directory) and directory != "" do
    inventory = current(state.table)

    {contexts, errors} =
      Enum.reduce(ToolInventory.contexts(), {inventory.contexts, inventory.errors}, fn context,
                                                                                       {contexts,
                                                                                        errors} ->
        document =
          case Map.fetch(fresh, context) do
            {:ok, document} -> {:ok, document}
            :error -> read_snapshot(snapshot_path(directory, context))
          end

        case document do
          {:ok, document} ->
            case safe_parse(document, context) do
              {:ok, parsed} -> {Map.put(contexts, context, parsed), Map.delete(errors, context)}
              {:error, reason} -> {contexts, Map.put(errors, context, reason)}
            end

          {:error, :enoent} ->
            {contexts, errors}

          {:error, reason} ->
            {contexts, Map.put(errors, context, reason)}
        end
      end)

    if contexts != inventory.contexts or errors != inventory.errors do
      store(state, %{inventory | contexts: contexts, errors: errors})
    end

    state
  end

  defp reload(state, _fresh), do: state

  # The pane snapshot is written by the job identity, so a document that
  # breaks the parser is an error for that context, never a crash here.
  defp safe_parse(document, context) do
    ToolInventory.parse(document, context)
  rescue
    _error -> {:error, :invalid_snapshot}
  end

  defp read_snapshot(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} <- Jason.decode(contents) do
      {:ok, document}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      error -> error
    end
  end

  defp record_error(state, reason) do
    inventory = current(state.table)
    store(state, %{inventory | errors: Map.put(inventory.errors, "probe", reason)})
    state
  end

  defp clear_error(state) do
    inventory = current(state.table)

    if Map.has_key?(inventory.errors, "probe"),
      do: store(state, %{inventory | errors: Map.delete(inventory.errors, "probe")})

    state
  end

  defp set_probing(state, probing?) do
    inventory = current(state.table)
    if inventory.probing? != probing?, do: store(state, %{inventory | probing?: probing?})
  end

  defp store(state, inventory) do
    :ets.insert(state.table, {:inventory, inventory})
    Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:machine_inventory, inventory})
  end

  ## Transitions

  defp observe_transition(state) do
    lines = lines(current(state.table), DateTime.utc_now())
    signature = signature(lines)
    previous = previous_signature(state)

    cond do
      signature == previous ->
        %{state | signature: signature}

      previous == :none and Enum.all?(lines, &(&1["status"] == "no_inventory")) ->
        %{state | signature: signature}

      true ->
        case record_transition(previous_lines(), lines) do
          :ok -> %{state | signature: signature}
          :error -> state
        end
    end
  end

  # The last persisted lines survive a restart, so a reboot with an unchanged
  # inventory writes nothing.
  defp previous_signature(%{signature: :unloaded}) do
    case previous_lines() do
      nil -> :none
      lines -> signature(lines)
    end
  end

  defp previous_signature(%{signature: signature}), do: signature

  defp previous_lines do
    Repo.one(
      from event in AuditEvent,
        where: event.action == "machine.inventory_changed",
        order_by: [desc: event.id],
        limit: 1,
        select: event.details
    )
    |> case do
      %{"new" => lines} when is_list(lines) -> lines
      _none -> nil
    end
  rescue
    error ->
      Logger.warning("tool inventory history unavailable: #{Exception.message(error)}")
      nil
  end

  defp record_transition(old_lines, new_lines) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: "system",
      action: "machine.inventory_changed",
      target_type: "machine",
      target_id: 0,
      details: %{
        "machine_id" => PtcManager.Machine.id(),
        "old" => old_lines || [],
        "new" => new_lines
      }
    })
    |> Repo.insert()
    |> case do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning("tool inventory transition not recorded: #{inspect(changeset.errors)}")
        :error
    end
  rescue
    error ->
      Logger.warning("tool inventory transition not recorded: #{Exception.message(error)}")
      :error
  end

  defp config(key, default), do: Application.get_env(:ptc_manager, key, default)
end
