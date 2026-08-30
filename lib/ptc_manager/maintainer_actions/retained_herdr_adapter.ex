defmodule PtcManager.MaintainerActions.RetainedHerdrAdapter do
  @moduledoc "Resumes the original Herdr implementation session for PR repair work."

  @behaviour PtcManager.MaintainerActions.Adapter

  import Ecto.Query

  alias PtcManager.Herdr.Command
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun, PrPublication}
  alias PtcManager.Repo

  @command_grace_ms 5_000

  @impl true
  def run(%AgentAction{action_key: action_key, target_id: publication_id} = action)
      when action_key in ["repair_pr", "repair_and_merge_pr"] do
    with %PrPublication{} = publication <-
           PrPublication
           |> Repo.get(publication_id)
           |> Repo.preload(job: [:worktree_allocation]),
         :ok <- retained_context_open(publication),
         %AgentRun{} = retained_run <- retained_run(publication.job),
         :ok <- retained_worktree_available(publication),
         {:ok, resumed_run} <- mark_resumed(retained_run, action),
         :ok <- retained_context_still_open(publication.id) do
      case prompt(resumed_run, action.prompt) do
        {:ok, output} ->
          finish_result(resumed_run, publication.id, output)

        {:error, reason} ->
          _ = mark_uncertain(resumed_run, publication.job.worktree_allocation, reason)
          {:error, reason}
      end
    else
      nil -> {:error, :retained_herdr_agent_unavailable}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:retained_herdr_repair_failed, error.__struct__}}
  end

  def run(%AgentAction{}), do: {:error, :unsupported_retained_herdr_action}

  defp retained_run(job) do
    AgentRun
    |> where(
      [run],
      run.job_id == ^job.id and run.fencing_token == ^job.fencing_token and
        not is_nil(run.agent_name) and run.state == "waiting"
    )
    |> order_by([run], desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  defp retained_worktree_available(%{job: %{worktree_allocation: %{path: path}}})
       when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, :repair_worktree_unavailable}
  end

  defp retained_worktree_available(_publication), do: {:error, :repair_worktree_unavailable}

  defp retained_context_open(%{
         pr_state: "open",
         job: %{state: "pr_open", worktree_allocation: %{state: "active"}}
       }),
       do: :ok

  defp retained_context_open(_publication), do: {:error, :retained_herdr_context_not_open}

  defp retained_context_still_open(publication_id) do
    publication =
      PrPublication
      |> Repo.get(publication_id)
      |> Repo.preload(job: :worktree_allocation)

    retained_context_open(publication)
  end

  defp mark_resumed(retained_run, action) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        publication =
          PrPublication
          |> Repo.get!(action.target_id)
          |> Repo.preload(job: :worktree_allocation)

        if retained_context_open(publication) != :ok,
          do: Repo.rollback(:retained_herdr_context_not_open)

        {resumed_count, _rows} =
          AgentRun
          |> where([run], run.id == ^retained_run.id and run.state == "waiting")
          |> Repo.update_all(
            set: [
              state: "working",
              status_text: "Resumed for #{String.replace(action.action_key, "_", " ")}.",
              last_heartbeat_at: now,
              ended_at: nil,
              updated_at: now
            ]
          )

        if resumed_count != 1, do: Repo.rollback(:retained_herdr_agent_not_waiting)

        {action_run_count, _rows} =
          AgentRun
          |> where(
            [run],
            run.agent_action_id == ^action.id and run.fencing_token == ^action.attempt_count and
              run.state in ["starting", "working"]
          )
          |> Repo.update_all(
            set: [
              agent_name: retained_run.agent_name,
              herdr_workspace: retained_run.herdr_workspace,
              herdr_pane: retained_run.herdr_pane,
              herdr_session: retained_run.herdr_session,
              status_text: "Resuming #{retained_run.agent_name} in its retained Herdr session.",
              last_heartbeat_at: now,
              updated_at: now
            ]
          )

        if action_run_count != 1, do: Repo.rollback(:agent_action_run_not_active)

        Repo.get!(AgentRun, retained_run.id)
      end)

    case outcome do
      {:ok, run} ->
        Operations.notify_changed(__MODULE__)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prompt(run, prompt) do
    timeout = Application.get_env(:ptc_manager, :agent_action_timeout_ms, 7_200_000)
    command = Application.get_env(:ptc_manager, :herdr_command, Command)

    continuation = """
    Continue in your existing implementation session. You already worked on this pull request, so reuse your prior context and inspect the retained worktree before changing anything.

    #{prompt}

    PtcManager independently verifies the pushed branch after this turn. Leave the Herdr session available when you finish so it can wait for CI, review feedback, or the final merge decision.
    """

    command.run(
      [
        "agent",
        "prompt",
        run.agent_name,
        continuation,
        "--wait",
        "--until",
        "idle",
        "--until",
        "done",
        "--until",
        "blocked",
        "--timeout",
        Integer.to_string(timeout)
      ],
      timeout + @command_grace_ms
    )
  end

  defp finish_result(run, publication_id, output) do
    blocked? = settled_state(output) == "blocked"
    _ = settle_run_if_open(run, publication_id, blocked?)

    if blocked? do
      {:ok, result("repair-blocked", "The retained implementation agent needs attention.")}
    else
      {:ok, result("repaired", "The retained implementation agent completed its repair turn.")}
    end
  end

  defp settle_run_if_open(run, publication_id, blocked?) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      if blocked? do
        %{
          state: "blocked",
          status_text: "The retained implementation agent is blocked and needs attention.",
          last_heartbeat_at: now,
          ended_at: nil
        }
      else
        %{
          state: "waiting",
          status_text: "Repair turn finished; retained while the PR remains open.",
          last_heartbeat_at: now,
          ended_at: nil
        }
      end

    outcome =
      Repo.transaction(fn ->
        case retained_context_still_open(publication_id) do
          :ok ->
            {updated, _rows} =
              AgentRun
              |> where([candidate], candidate.id == ^run.id and candidate.state == "working")
              |> Repo.update_all(set: Map.to_list(Map.put(attrs, :updated_at, now)))

            if updated == 1, do: :settled, else: :unchanged

          {:error, :retained_herdr_context_not_open} ->
            :terminal
        end
      end)

    Operations.notify_changed(__MODULE__)
    outcome
  end

  defp mark_uncertain(run, allocation, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    message = "Herdr could not confirm the repair turn: #{bounded(reason)}"

    Repo.transaction(fn ->
      AgentRun
      |> where([candidate], candidate.id == ^run.id and candidate.state == "working")
      |> Repo.update_all(
        set: [
          state: "unknown",
          status_text: String.slice(message, 0, 240),
          last_heartbeat_at: now,
          ended_at: nil,
          updated_at: now
        ]
      )

      PtcManager.Operations.WorktreeAllocation
      |> where(
        [candidate],
        candidate.id == ^allocation.id and candidate.state == "active"
      )
      |> Repo.update_all(set: [last_error: String.slice(message, 0, 500), updated_at: now])
    end)
    |> tap(fn _outcome -> Operations.notify_changed(__MODULE__) end)
  end

  defp settled_state(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> find_state(decoded)
      _error -> if String.contains?(String.downcase(output), "blocked"), do: "blocked"
    end
  end

  defp find_state(%{} = value) do
    Enum.find_value(["agent_status", "status", "state"], &Map.get(value, &1)) ||
      Enum.find_value(value, fn {_key, nested} -> find_state(nested) end)
  end

  defp find_state([head | tail]), do: find_state(head) || find_state(tail)
  defp find_state([]), do: nil
  defp find_state(_value), do: nil
  defp bounded(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 180)

  defp result(outcome, summary) do
    %{
      "outcome" => outcome,
      "private_summary" => summary,
      "why_it_matters" =>
        "Reusing the original session preserves implementation context while PtcManager verifies GitHub independently.",
      "scope" => "small",
      "risk" => "low",
      "technical_evidence" =>
        "The repair turn ran in the named retained Herdr implementation session; branch and test evidence are verified during reconciliation.",
      "github_changes" => [],
      "evidence" => ["Resumed the original named Herdr implementation agent."],
      "created_issue_numbers" => [],
      "suggestions" => []
    }
  end
end
