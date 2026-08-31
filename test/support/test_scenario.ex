defmodule PtcManager.TestScenario do
  @moduledoc """
  Stateful GitHub and Herdr boundary for deterministic integration scenarios.

  The scenario is passed explicitly as a gateway value. Tests advance one real
  coordinator stage at a time and can inspect an ordered external-event trace.
  No LLM, public network, maintainer repository, poller timing, or process-global
  adapter configuration is involved.
  """

  use GenServer

  alias PtcManager.Dispatch
  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Herdr.Sync, as: HerdrSync
  alias PtcManager.MaintainerActions.ExternalPrRepairAdapter
  alias PtcManager.Operations
  alias PtcManager.Operations.Worker
  alias PtcManager.OperationsFixtures
  alias PtcManager.Repo

  defstruct [:pid]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def gateway(pid) when is_pid(pid), do: %__MODULE__{pid: pid}

  def approved_implementation!(%__MODULE__{} = scenario, opts \\ []) do
    number = Keyword.get(opts, :number, System.unique_integer([:positive]))
    title = Keyword.get(opts, :title, "Implement deterministic scenario support")

    repository =
      OperationsFixtures.repository_fixture(%{
        local_path: Keyword.get(opts, :local_path, "/tmp/ptc-manager-test-scenario")
      })

    remote_issue = %{
      "number" => number,
      "title" => title,
      "html_url" =>
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{number}",
      "body" => "Exercise one deterministic implementation lifecycle.",
      "state" => "open",
      "updated_at" => "2026-08-31T09:00:00Z"
    }

    issue =
      OperationsFixtures.issue_fixture(
        repository,
        IssueSnapshot.normalize!(remote_issue, repository.id)
      )

    proposal = OperationsFixtures.proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "scenario-maintainer")

    worker =
      Repo.get_by(Worker, worker_key: "herdr:scenario") ||
        OperationsFixtures.worker_fixture(%{
          worker_key: "herdr:scenario",
          name: "Scenario worker",
          capabilities: %{"herdr" => true, "implementation_slots" => 1}
        })

    :ok = put_issue(scenario, repository, remote_issue)

    %{
      repository: repository,
      issue: issue,
      proposal: proposal,
      job: job,
      worker: worker,
      remote_issue: remote_issue
    }
  end

  def put_issue(%__MODULE__{} = scenario, repository, issue) when is_map(issue) do
    GenServer.call(scenario.pid, {:put_issue, repository.id, issue})
  end

  def dispatch_outcome(%__MODULE__{} = scenario, outcome)
      when outcome in [:ok, :fail_before, :effect_then_error, :pause_after_effect] do
    GenServer.call(scenario.pid, {:dispatch_outcome, outcome})
  end

  def cleanup_outcome(%__MODULE__{} = scenario, outcome)
      when outcome in [:ok, :fail_before, :effect_then_error, :pause_after_effect] do
    GenServer.call(scenario.pid, {:cleanup_outcome, outcome})
  end

  def operation_outcome(%__MODULE__{} = scenario, operation, outcome)
      when operation in [
             :list_open_issues,
             :get_issue,
             :start_pull_request_action,
             :prompt_pull_request_action,
             :pull_request_action_head,
             :sync_action_postflight
           ] and outcome in [:ok, :fail_before, :effect_then_error, :pause_after_effect] do
    GenServer.call(scenario.pid, {:operation_outcome, operation, outcome})
  end

  def repair_statuses(%__MODULE__{} = scenario, preflight, postflight) do
    GenServer.call(scenario.pid, {:repair_statuses, preflight, postflight})
  end

  def resume(%__MODULE__{} = scenario, reference) when is_reference(reference) do
    send(scenario.pid, {:resume_after_effect, reference})
    :ok
  end

  def herdr_transport(%__MODULE__{} = scenario, transport)
      when transport in [:online, :offline] do
    GenServer.call(scenario.pid, {:herdr_transport, transport})
  end

  def set_agent_state(%__MODULE__{} = scenario, agent_name, state)
      when is_binary(agent_name) and is_binary(state) do
    GenServer.call(scenario.pid, {:set_agent_state, agent_name, state})
  end

  def agents(%__MODULE__{} = scenario), do: GenServer.call(scenario.pid, :agents)
  def trace(%__MODULE__{} = scenario), do: GenServer.call(scenario.pid, :trace)

  def advance(scenario, stage, opts \\ [])

  def advance(%__MODULE__{} = scenario, :dispatch, opts) do
    defaults = [github: scenario, adapter: scenario, worker_key: "herdr:scenario"]
    Dispatch.run_once(Keyword.merge(opts, defaults))
  end

  def advance(%__MODULE__{} = scenario, :herdr_sync, opts) do
    HerdrSync.sync(Keyword.merge(opts, client: scenario, session: "scenario"))
  end

  def advance(%__MODULE__{} = scenario, {:github_sync, repository}, opts) do
    GitHubSync.sync_repository(repository, Keyword.merge(opts, client: scenario))
  end

  # Stateful GitHub gateway callbacks.

  def list_open_issues(%__MODULE__{} = scenario, repository) do
    GenServer.call(scenario.pid, {:list_open_issues, repository.id})
  end

  def get_issue(%__MODULE__{} = scenario, repository, number) do
    GenServer.call(scenario.pid, {:get_issue, repository.id, number})
  end

  # Stateful dispatch and Herdr gateway callbacks.

  def dispatch(%__MODULE__{} = scenario, context) do
    GenServer.call(scenario.pid, {:dispatch, context})
  end

  def remove_worktree(%__MODULE__{} = scenario, allocation) do
    GenServer.call(scenario.pid, {:remove_worktree, allocation})
  end

  def remove_action_workspace(%__MODULE__{} = scenario, workspace) do
    GenServer.call(scenario.pid, {:remove_action_workspace, workspace})
  end

  def start_pull_request_action(%__MODULE__{} = scenario, action, publication, repository) do
    GenServer.call(scenario.pid, {:start_pull_request_action, action, publication, repository})
  end

  def prompt_pull_request_action(%__MODULE__{} = scenario, agent_name, prompt) do
    GenServer.call(scenario.pid, {:prompt_pull_request_action, agent_name, prompt})
  end

  def pull_request_action_head(%__MODULE__{} = scenario, worktree_path) do
    GenServer.call(scenario.pid, {:pull_request_action_head, worktree_path})
  end

  def run(%__MODULE__{} = scenario, action) do
    ExternalPrRepairAdapter.run(action, scenario)
  end

  def sync_action(%__MODULE__{} = scenario, action) do
    GenServer.call(scenario.pid, {:sync_action, action, nil})
  end

  def sync_action(%__MODULE__{} = scenario, action, result) do
    GenServer.call(scenario.pid, {:sync_action, action, result})
  end

  def list_agents(%__MODULE__{} = scenario) do
    GenServer.call(scenario.pid, :list_agents)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       issues: %{},
       agents: [],
       dispatch_outcome:
         outcome_setting(Keyword.get(opts, :dispatch_outcome, :ok), opts[:pause_owner]),
       cleanup_outcome:
         outcome_setting(Keyword.get(opts, :cleanup_outcome, :ok), opts[:pause_owner]),
       operation_outcomes: %{},
       repair_statuses: nil,
       herdr_transport: Keyword.get(opts, :herdr_transport, :online),
       paused_calls: %{},
       trace: [],
       next_sequence: 1
     }}
  end

  @impl true
  def handle_call({:put_issue, repository_id, issue}, _from, state) do
    key = {repository_id, issue["number"]}
    {:reply, :ok, put_in(state, [:issues, key], issue)}
  end

  def handle_call({:dispatch_outcome, outcome}, {caller, _tag}, state) do
    {:reply, :ok, %{state | dispatch_outcome: outcome_setting(outcome, caller)}}
  end

  def handle_call({:cleanup_outcome, outcome}, {caller, _tag}, state) do
    {:reply, :ok, %{state | cleanup_outcome: outcome_setting(outcome, caller)}}
  end

  def handle_call({:operation_outcome, operation, outcome}, {caller, _tag}, state) do
    {:reply, :ok,
     %{
       state
       | operation_outcomes:
           Map.put(state.operation_outcomes, operation, outcome_setting(outcome, caller))
     }}
  end

  def handle_call({:repair_statuses, preflight, postflight}, _from, state) do
    {:reply, :ok, %{state | repair_statuses: {preflight, postflight}}}
  end

  def handle_call({:herdr_transport, transport}, _from, state) do
    {:reply, :ok, %{state | herdr_transport: transport}}
  end

  def handle_call({:set_agent_state, agent_name, agent_state}, _from, state) do
    agents =
      Enum.map(state.agents, fn agent ->
        if agent["name"] == agent_name do
          Map.put(agent, "agent_status", agent_state)
        else
          agent
        end
      end)

    {:reply, :ok, %{state | agents: agents}}
  end

  def handle_call(:agents, _from, state), do: {:reply, state.agents, state}
  def handle_call(:trace, _from, state), do: {:reply, Enum.reverse(state.trace), state}

  def handle_call({:list_open_issues, repository_id}, from, state) do
    issues =
      state.issues
      |> Enum.filter(fn {{stored_repository_id, _number}, issue} ->
        stored_repository_id == repository_id and issue["state"] == "open"
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(& &1["number"])

    external_operation_reply(
      state,
      state,
      from,
      :list_open_issues,
      repository_id,
      {:ok, issues}
    )
  end

  def handle_call({:get_issue, repository_id, number}, from, state) do
    result =
      case Map.fetch(state.issues, {repository_id, number}) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :not_found}
      end

    external_operation_reply(state, state, from, :get_issue, {repository_id, number}, result)
  end

  def handle_call({:dispatch, context}, from, state) do
    dispatch = dispatch_metadata(context)

    {mode, pause_owner} = state.dispatch_outcome

    state =
      case mode do
        :fail_before -> state
        _applied -> %{state | agents: upsert_agent(state.agents, remote_agent(context, dispatch))}
      end

    result =
      case mode do
        :ok ->
          {:ok, dispatch}

        :fail_before ->
          {:error, {:safe, :scenario_dispatch_failed}}

        :effect_then_error ->
          {:error, {:uncertain, :scenario_dispatch_ack_lost}}

        :pause_after_effect ->
          {:ok, dispatch}
      end

    state =
      record(
        state,
        :herdr,
        :dispatch,
        context.job.id,
        %{mode: mode, result: summarize(result)}
      )

    if mode == :pause_after_effect do
      {:noreply, park_after_effect(state, from, pause_owner, :dispatch, context.job.id, result)}
    else
      {:reply, result, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    result =
      case state.herdr_transport do
        :online -> {:ok, state.agents}
        :offline -> {:error, :offline}
      end

    state = record(state, :herdr, :list_agents, "scenario", summarize(result))
    {:reply, result, state}
  end

  def handle_call({:remove_worktree, allocation}, from, state) do
    {mode, pause_owner, result, state} = remove_workspace(state, allocation.herdr_workspace)
    state = record(state, :herdr, :remove_worktree, allocation.id, summarize(result))

    maybe_pause_reply(
      mode,
      state,
      from,
      pause_owner,
      :remove_worktree,
      allocation.id,
      result
    )
  end

  def handle_call({:remove_action_workspace, workspace}, from, state) do
    {mode, pause_owner, result, state} = remove_workspace(state, workspace)
    state = record(state, :herdr, :remove_action_workspace, workspace, summarize(result))

    maybe_pause_reply(
      mode,
      state,
      from,
      pause_owner,
      :remove_action_workspace,
      workspace,
      result
    )
  end

  def handle_call({:start_pull_request_action, action, publication, repository}, from, state) do
    attempt = "pr#{publication.pr_number}_a#{action.id}_f#{action.attempt_count}"

    dispatch = %{
      workspace_id: "scenario-#{attempt}",
      pane_id: "scenario-#{attempt}:p1",
      session: "scenario",
      external_key: "scenario:agent-#{attempt}",
      agent_name: "repair_#{attempt}",
      worktree_path: Path.join(repository.local_path, ".scenario/#{attempt}"),
      worker_key: "herdr:scenario"
    }

    agent = %{
      "name" => dispatch.agent_name,
      "agent" => dispatch.agent_name,
      "agent_status" => "working",
      "status_text" => "Scenario agent is repairing PR ##{publication.pr_number}.",
      "pane_id" => dispatch.pane_id,
      "workspace_id" => dispatch.workspace_id,
      "agent_session" => %{"value" => "agent-#{attempt}"}
    }

    applied = %{state | agents: upsert_agent(state.agents, agent)}

    external_operation_reply(
      state,
      applied,
      from,
      :start_pull_request_action,
      action.id,
      {:ok, dispatch}
    )
  end

  def handle_call({:prompt_pull_request_action, agent_name, prompt}, from, state) do
    external_operation_reply(
      state,
      state,
      from,
      :prompt_pull_request_action,
      agent_name,
      {:ok, Jason.encode!(%{"agent_status" => "idle", "prompt" => prompt})}
    )
  end

  def handle_call({:pull_request_action_head, worktree_path}, from, state) do
    head = String.duplicate("e", 40)

    external_operation_reply(
      state,
      state,
      from,
      :pull_request_action_head,
      worktree_path,
      {:ok, head}
    )
  end

  def handle_call({:sync_action, _action, result}, from, %{repair_statuses: statuses} = state)
      when not is_nil(statuses) do
    {preflight, postflight} = statuses

    if is_nil(result) do
      {:reply, {:ok, %{pull_request: preflight}}, state}
    else
      external_operation_reply(
        state,
        state,
        from,
        :sync_action_postflight,
        "repair",
        {:ok, %{pull_request: postflight}}
      )
    end
  end

  @impl true
  def handle_info({:resume_after_effect, reference}, state) do
    case Map.pop(state.paused_calls, reference) do
      {nil, _paused_calls} ->
        {:noreply, state}

      {{from, result}, paused_calls} ->
        GenServer.reply(from, result)
        {:noreply, %{state | paused_calls: paused_calls}}
    end
  end

  defp remove_workspace(state, workspace) do
    applied = %{state | agents: Enum.reject(state.agents, &(&1["workspace_id"] == workspace))}

    {mode, pause_owner} = state.cleanup_outcome

    case mode do
      :ok ->
        {:ok, pause_owner, :ok, applied}

      :fail_before ->
        {:fail_before, pause_owner, {:error, :scenario_cleanup_failed}, state}

      :effect_then_error ->
        {:effect_then_error, pause_owner, {:error, :scenario_cleanup_ack_lost}, applied}

      :pause_after_effect ->
        {:pause_after_effect, pause_owner, :ok, applied}
    end
  end

  defp external_operation_reply(state, applied, from, operation, target, success) do
    {mode, pause_owner} = Map.get(state.operation_outcomes, operation, {:ok, nil})

    {result, next_state} =
      case mode do
        :ok -> {success, applied}
        :fail_before -> {{:error, {operation, :scenario_failed_before}}, state}
        :effect_then_error -> {operation_ack_lost(operation), applied}
        :pause_after_effect -> {success, applied}
      end

    source = operation_source(operation)

    next_state =
      record(next_state, source, operation, target, %{mode: mode, result: summarize(result)})

    maybe_pause_reply(mode, next_state, from, pause_owner, operation, target, result)
  end

  defp maybe_pause_reply(
         :pause_after_effect,
         state,
         from,
         pause_owner,
         operation,
         target,
         result
       ) do
    {:noreply, park_after_effect(state, from, pause_owner, operation, target, result)}
  end

  defp maybe_pause_reply(_mode, state, _from, _owner, _operation, _target, result) do
    {:reply, result, state}
  end

  defp park_after_effect(state, from, pause_owner, operation, target, result) do
    reference = make_ref()

    if is_pid(pause_owner) do
      send(pause_owner, {:scenario_paused_after_effect, reference, operation, target})
    end

    %{state | paused_calls: Map.put(state.paused_calls, reference, {from, result})}
  end

  defp outcome_setting(:pause_after_effect, owner), do: {:pause_after_effect, owner}
  defp outcome_setting(mode, _owner), do: {mode, nil}

  defp operation_source(operation) when operation in [:list_open_issues, :get_issue], do: :github
  defp operation_source(:pull_request_action_head), do: :git
  defp operation_source(:sync_action_postflight), do: :github
  defp operation_source(_operation), do: :herdr

  defp operation_ack_lost(operation), do: {:error, {operation, :scenario_ack_lost}}

  defp dispatch_metadata(context) do
    attempt = "j#{context.job.id}-f#{context.job.fencing_token}"

    %{
      workspace_id: "scenario-#{attempt}",
      pane_id: "scenario-#{attempt}:p1",
      session: "scenario",
      external_key: "scenario:agent-#{attempt}",
      agent_name: "impl_j#{context.job.id}_f#{context.job.fencing_token}"
    }
  end

  defp remote_agent(context, dispatch) do
    %{
      "name" => dispatch.agent_name,
      "agent" => dispatch.agent_name,
      "agent_status" => "working",
      "status_text" => "Scenario agent is implementing issue ##{context.issue.number}.",
      "pane_id" => dispatch.pane_id,
      "workspace_id" => dispatch.workspace_id,
      "agent_session" => %{
        "value" => String.replace_prefix(dispatch.external_key, "scenario:", "")
      }
    }
  end

  defp upsert_agent(agents, new_agent) do
    [new_agent | Enum.reject(agents, &(&1["name"] == new_agent["name"]))]
  end

  defp record(state, source, operation, target, outcome) do
    event = %{
      sequence: state.next_sequence,
      source: source,
      operation: operation,
      target: target,
      outcome: outcome
    }

    %{state | trace: [event | state.trace], next_sequence: state.next_sequence + 1}
  end

  defp summarize({:ok, values}) when is_list(values), do: {:ok, length(values)}
  defp summarize({:ok, _value}), do: :ok
  defp summarize({:error, reason}), do: {:error, reason}
  defp summarize(:ok), do: :ok
end
