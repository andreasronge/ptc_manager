defmodule PtcManager.MaintainerActions.ExternalPrRepairAdapter do
  @moduledoc "Runs imported-PR repair and merge work in a named, retained Herdr session."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, PrPublication}
  alias PtcManager.Repo

  @action_keys ~w(repair_pr repair_and_merge_pr)

  @impl true
  def run(%AgentAction{action_key: action_key, target_id: publication_id} = action)
      when action_key in @action_keys do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload(:repository)

    herdr = Application.get_env(:ptc_manager, :external_pr_herdr_adapter, HerdrAdapter)

    with true <- PrPublication.external?(publication),
         %{local_path: repository_path} = repository when is_binary(repository_path) <-
           publication.repository,
         {:ok, dispatch} <-
           herdr.start_pull_request_action(action, publication, repository),
         {:ok, _run} <-
           Operations.attach_agent_action_herdr_run(
             action.id,
             action.attempt_count,
             dispatch
           ),
         {:ok, output} <-
           herdr.prompt_pull_request_action(dispatch.agent_name, action.prompt) do
      settle_action(herdr, action, dispatch, output)
    else
      false -> {:error, :pull_request_is_managed}
      nil -> {:error, :repository_path_unavailable}
      %{} -> {:error, :repository_path_unavailable}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:external_pr_repair_failed, error.__struct__}}
  end

  def run(%AgentAction{}), do: {:error, :unsupported_external_pr_action}

  defp settle_action(herdr, action, dispatch, output) do
    if settled_state(output) == "blocked" do
      {:ok, result("repair-blocked", "The Herdr repair agent needs attention.")}
    else
      with {:ok, head} <- herdr.pull_request_action_head(dispatch.worktree_path),
           true <- head != action.target_snapshot["head_sha"],
           {:ok, _action} <-
             Operations.record_agent_action_repair_intent(
               action.id,
               action.attempt_token,
               head
             ) do
        {:ok,
         result("repaired", "The Herdr repair turn completed.")
         |> Map.put("pushed_head_sha", head)}
      else
        false -> {:error, :repair_agent_did_not_advance_head}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defp result(outcome, summary) do
    %{
      "outcome" => outcome,
      "private_summary" => summary,
      "why_it_matters" =>
        "The imported pull request now has a named, retained Herdr session with visible output.",
      "scope" => "small",
      "risk" => "medium",
      "technical_evidence" =>
        "The action ran in the named Herdr worktree; GitHub state is reconciled independently afterward.",
      "github_changes" => [],
      "evidence" => ["Used a retained Herdr pull-request repair session."],
      "created_issue_numbers" => [],
      "suggestions" => []
    }
  end
end
