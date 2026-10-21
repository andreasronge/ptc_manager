defmodule PtcManager.Machine.Readiness do
  @moduledoc """
  Whether this host can run the whole job lifecycle before work is admitted.

  Each check has a key, a status and one sentence. The report is evaluated at
  boot, again whenever the tool inventory is refreshed, and on request from
  the console banner. A failing blocking check keeps `PtcManager.Machine.Gate`
  from admitting work (`:host_not_ready`); inspection, deployment,
  configuration and releasing a fenced operation stay available.

  On a `:linux` host every check is reported but none blocks, so Linux
  admission is unchanged. On `:macos` and `:development` a failing check
  blocks. Until the first evaluation finishes the host is not ready.
  """

  use GenServer

  require Logger

  alias PtcManager.{CommandEnvironment, Host, ManagedOperationContext}
  alias PtcManager.Machine.{HelperManifest, Inventory}

  @topic "host_readiness"
  @report_key {__MODULE__, :report}
  @self_test_timeout_ms 30_000

  @type check :: %{
          key: atom(),
          status: :ok | :failed | :skipped,
          blocking: boolean(),
          sentence: String.t()
        }

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Whether readiness is evaluated at all; tests turn it off unless they exercise it."
  def enabled?, do: Application.get_env(:ptc_manager, :host_readiness, true)

  @doc "The last report: `%{checks: [check], evaluated_at: DateTime | nil}`."
  def current, do: :persistent_term.get(@report_key, %{checks: [], evaluated_at: nil})

  @doc "True when no blocking check fails and the host has been evaluated."
  def ready? do
    cond do
      not enabled?() -> true
      is_nil(current().evaluated_at) -> false
      true -> blocking_failures(current()) == []
    end
  end

  @doc "Failing checks, blocking or not, for the console banner."
  def failing(report \\ current()), do: Enum.filter(report.checks, &(&1.status == :failed))

  def blocking_failures(report \\ current()), do: Enum.filter(failing(report), & &1.blocking)

  @doc "Evaluates again in the background; the result is broadcast on `subscribe/0`."
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc "Evaluates again and waits for the result, for the banner's Recheck."
  def recheck(server \\ __MODULE__) do
    if enabled?(), do: GenServer.call(server, :refresh, 90_000)
    current()
  end

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  @doc false
  def put_report(report) do
    if current() != report do
      :persistent_term.put(@report_key, report)
      Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:host_readiness, report})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      PtcManager.MachineUsage.subscribe()
      {:ok, %{}, {:continue, :evaluate}}
    else
      {:ok, %{}}
    end
  end

  @impl true
  def handle_continue(:evaluate, state), do: {:noreply, evaluate_and_store(state)}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, evaluate_and_store(state)}

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, evaluate_and_store(state)}

  @impl true
  def handle_info({:machine_inventory, _inventory}, state),
    do: {:noreply, evaluate_and_store(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp evaluate_and_store(state) do
    report = %{checks: evaluate(), evaluated_at: DateTime.utc_now()}

    for check <- failing(report), check not in failing(current()) do
      Logger.warning("Host readiness: #{check.key} failed: #{check.sentence}")
    end

    put_report(report)
    state
  rescue
    error ->
      Logger.error("Host readiness evaluation failed: #{Exception.message(error)}")
      state
  end

  @doc "Runs every check now; `inventory:` replaces the current tool inventory."
  @spec evaluate(keyword()) :: [check()]
  def evaluate(opts \\ []) do
    blocking = Host.profile() != :linux
    inventory = Keyword.get_lazy(opts, :inventory, &Inventory.current/0)

    [
      paths(),
      helpers(),
      operation_wrapper(),
      operation_broker(),
      reconcile(),
      publication(),
      agent_login(inventory)
    ]
    |> Enum.map(&Map.put(&1, :blocking, blocking and &1.status == :failed))
  end

  # Paths ----------------------------------------------------------------------

  @broker_paths [:operation_wrapper, :operation_socket, :operation_context_dir]

  # Development runs on temporary defaults that are created on first use, so
  # only a release's paths are checked; the broker's only when it is configured.
  defp paths do
    if Host.profile() == :development do
      skipped(:paths, "Development uses temporary defaults created on first use.")
    else
      problems =
        for {key, _app_key, env, kind} <- Host.path_specs(),
            key not in @broker_paths or broker_configured?(),
            path = Host.path(key),
            path not in [nil, ""],
            problem = path_problem(path, kind),
            do: "#{key} (#{env}) #{path}: #{problem}"

      if problems == [],
        do: ok(:paths, "Every host path is usable."),
        else: failed(:paths, Enum.join(problems, "; "))
    end
  end

  # Linux worker-owned roots belong to another account, so only their
  # existence is checked there.
  defp path_problem(path, kind) do
    strict? = Host.profile() != :linux

    case kind do
      :executable ->
        unless executable?(path), do: "is not an executable file"

      :socket ->
        unless directory?(Path.dirname(path), strict?), do: "its directory is not writable"

      # Absent, it is created on first use under a usable parent; present, it
      # must be usable itself.
      :created_directory ->
        cond do
          File.exists?(path) ->
            unless directory?(path, strict?), do: "is not a usable directory"

          not directory?(Path.dirname(path), strict?) ->
            "is absent and its parent is not a usable directory"

          true ->
            nil
        end

      :writable_directory ->
        unless directory?(path, strict?), do: "is not a writable directory"

      :directory ->
        unless directory?(path, false), do: "is not a directory"

      :output_file ->
        unless directory?(Path.dirname(path), strict?), do: "its directory is not writable"
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp directory?(path, false), do: File.dir?(path)

  defp directory?(path, true) do
    match?(
      {:ok, %{type: :directory, access: access}} when access in [:write, :read_write],
      File.stat(path)
    )
  end

  # Helpers --------------------------------------------------------------------

  defp helpers do
    if Host.profile() == :macos do
      problems =
        for {name, path} <- service_root_helpers(),
            problem = helper_problem(name, path),
            do: "#{path} #{problem}"

      if problems == [],
        do: ok(:helpers, "The installed host helpers match this release."),
        else:
          failed(
            :helpers,
            Enum.join(problems, "; ") <> ". Install them from the deployed revision."
          )
    else
      skipped(:helpers, "Host helpers are installed by the deployment script.")
    end
  end

  defp service_root_helpers do
    [
      {"ptc-operation", Host.path(:operation_wrapper)},
      {"ptc-manager-worker-review", Application.get_env(:ptc_manager, :review_helper)},
      {"ptc-manager-worker-agent-login",
       Application.get_env(:ptc_manager, :worker_agent_login_helper)},
      {"macos-deploy-host", Application.get_env(:ptc_manager, :deployment_trigger_command)}
    ]
  end

  defp helper_problem(_name, path) when path in [nil, ""], do: "is not configured"

  defp helper_problem(name, path) do
    with true <- executable?(path) || "is missing or not executable",
         {:ok, content} <- File.read(path) do
      if HelperManifest.sha256(content) == HelperManifest.digest(name),
        do: nil,
        else: "differs from the copy packaged in this release"
    else
      message when is_binary(message) -> message
      {:error, reason} -> "cannot be read (#{reason})"
    end
  end

  # Operation wrapper and broker ------------------------------------------------

  defp operation_wrapper do
    if broker_configured?() do
      wrapper = Host.path(:operation_wrapper)

      case run_bounded(wrapper, ["self-test"], @self_test_timeout_ms) do
        {:ok, {_output, 0}} ->
          ok(:operation_wrapper, "ptc-operation self-test passed.")

        {:ok, {output, status}} ->
          failed(
            :operation_wrapper,
            "ptc-operation self-test exited #{status}: #{bounded(output)}"
          )

        {:error, reason} ->
          failed(:operation_wrapper, "ptc-operation self-test could not run: #{reason}")
      end
    else
      skipped(:operation_wrapper, "No operation broker is configured.")
    end
  end

  defp operation_broker do
    if broker_configured?() do
      case ping() do
        :ok -> ok(:operation_broker, "The operation broker answered a ping.")
        {:error, reason} -> failed(:operation_broker, "The operation broker #{reason}.")
      end
    else
      skipped(:operation_broker, "No operation broker is configured.")
    end
  end

  defp broker_configured?,
    do: Host.path(:operation_socket) not in [nil, ""]

  # A readiness-only context proves the context directory is writable and the
  # socket authenticates; it owns nothing, so the broker creates no operation.
  defp ping do
    path = Host.path(:operation_socket)

    with {:ok, issued} <-
           ManagedOperationContext.issue(%{
             owner_type: "readiness",
             owner_id: 0,
             repository_id: 0,
             worker_id: 0,
             pane_id: "readiness",
             fencing_token: 0
           }) do
      try do
        request = %{
          "token" => issued.token,
          "context_id" => issued.payload["context_id"],
          "operation" => "ping"
        }

        case connect(path) do
          {:ok, socket} ->
            try do
              exchange(socket, request)
            after
              :gen_tcp.close(socket)
            end

          {:error, reason} ->
            {:error, "did not answer on #{path} (#{inspect(reason)})"}
        end
      after
        File.rm(issued.path)
      end
    else
      {:error, reason} -> {:error, "context could not be written (#{inspect(reason)})"}
    end
  end

  defp exchange(socket, request) do
    with :ok <- :gen_tcp.send(socket, Jason.encode!(request) <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000) do
      case Jason.decode(line) do
        {:ok, %{"status" => "ok"}} -> :ok
        {:ok, answer} -> {:error, "refused the ping: #{inspect(answer["error"])}"}
        _invalid -> {:error, "answered something other than JSON"}
      end
    else
      {:error, reason} -> {:error, "did not answer the ping (#{inspect(reason)})"}
    end
  end

  # An over-long or malformed socket path makes connect exit rather than
  # return an error; either way the broker cannot be reached.
  defp connect(path) do
    :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  # Configuration ----------------------------------------------------------------

  defp reconcile do
    cond do
      not dispatch_enabled?() ->
        skipped(:reconcile, "Dispatch is disabled.")

      Application.get_env(:ptc_manager, :result_reconcile_interval_ms, 0) > 0 ->
        ok(:reconcile, "Finished jobs are reconciled.")

      true ->
        failed(
          :reconcile,
          "Dispatch is enabled but PTC_RESULT_RECONCILE_INTERVAL_MS is 0, so finished jobs are never reconciled."
        )
    end
  end

  defp publication do
    cond do
      not dispatch_enabled?() ->
        skipped(:publication, "Dispatch is disabled.")

      Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false) ->
        agent_publication()

      true ->
        case PtcManager.GitHub.AppBroker.configuration_status() do
          :ok ->
            ok(:publication, "Brokered publication is configured.")

          {:error, missing} ->
            failed(
              :publication,
              "Brokered publication is selected but #{Enum.join(missing, ", ")} is not set."
            )
        end
    end
  end

  # Agents publish with their own GitHub login, which only the agent identity
  # can show; through a separate account's narrow sudo rule it cannot be asked.
  defp agent_publication do
    if Host.separate_agent_account?() do
      skipped(:publication, "The agent account's GitHub login is checked when it publishes.")
    else
      {binary, args} = Host.agent_command("gh", ["auth", "status"])

      case run_bounded(binary, args, 15_000) do
        {:ok, {_output, 0}} ->
          ok(:publication, "Agents publish with a signed-in GitHub CLI.")

        {:ok, {_output, _status}} ->
          failed(:publication, "Agents publish their pull requests, but `gh` is not signed in.")

        {:error, reason} ->
          failed(:publication, "Agents publish their pull requests, but `gh` #{reason}.")
      end
    end
  end

  defp agent_login(inventory) do
    signed_out =
      for {kind, "signed_out"} <- inventory.agent_logins, do: kind

    if signed_out == [],
      do: ok(:agent_login, "Every enabled agent kind is signed in or not checked."),
      else:
        failed(
          :agent_login,
          "Signed out: #{Enum.join(signed_out, ", ")}. Sign in as the agent identity."
        )
  end

  defp dispatch_enabled?, do: Application.get_env(:ptc_manager, :dispatch_enabled, false)

  defp run_bounded(binary, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(binary, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "did not finish within #{div(timeout_ms, 1_000)} seconds"}
    end
  end

  defp ok(key, sentence), do: %{key: key, status: :ok, sentence: sentence}
  defp failed(key, sentence), do: %{key: key, status: :failed, sentence: sentence}
  defp skipped(key, sentence), do: %{key: key, status: :skipped, sentence: sentence}

  defp bounded(output), do: output |> String.trim() |> String.slice(-300, 300)
end
