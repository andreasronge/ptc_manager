defmodule PtcManager.ExternalPrSessions do
  @moduledoc "Cleans retained Herdr sessions after imported pull requests become terminal."

  import Ecto.Query

  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun, PrPublication}
  alias PtcManager.Repo

  @action_keys ~w(repair_pr repair_and_merge_pr)

  def cleanup_terminal_once(adapter \\ HerdrAdapter) do
    candidate =
      AgentRun
      |> join(:inner, [run], action in AgentAction, on: action.id == run.agent_action_id)
      |> join(:inner, [run, action], publication in PrPublication,
        on: publication.id == action.target_id
      )
      |> where(
        [run, action, publication],
        action.action_key in ^@action_keys and action.target_type == "pull_request" and
          publication.pr_state in ["merged", "closed"] and not is_nil(run.herdr_workspace)
      )
      |> order_by([run], asc: run.started_at, asc: run.id)
      |> select([run], run)
      |> limit(1)
      |> Repo.one()

    case candidate do
      nil ->
        {:ok, :empty}

      run ->
        case adapter.remove_action_workspace(run.herdr_workspace) do
          :ok -> finish_cleanup(run)
          {:error, reason} -> {:error, {:external_pr_session_cleanup_failed, reason}}
        end
    end
  end

  defp finish_cleanup(run) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      run
      |> AgentRun.changeset(%{
        state: "done",
        status_text: "Pull request closed; retained Herdr workspace removed.",
        last_heartbeat_at: now,
        ended_at: now,
        herdr_workspace: nil,
        herdr_pane: nil,
        external_key: nil
      })
      |> Repo.update()

    case outcome do
      {:ok, cleaned} ->
        Operations.notify_changed(__MODULE__)
        {:ok, cleaned}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
