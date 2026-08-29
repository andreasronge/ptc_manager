defmodule PtcManager.Manager do
  @moduledoc "Creates private proposals from a configured read-only manager adapter."

  alias PtcManager.{Operations, Repo}
  alias PtcManager.Manager.Gate
  alias PtcManager.Operations.Proposal

  def enabled?, do: Application.get_env(:ptc_manager, :manager_enabled, false)

  def investigate_issue(issue_id, opts \\ []) when is_integer(issue_id) do
    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:ptc_manager, :manager_adapter))
    issue = Operations.get_issue!(issue_id)

    with :ok <- ensure_open(issue),
         {:ok, lease} <- Gate.checkout() do
      try do
        with {:ok, analysis} <- adapter.analyze(issue),
             {:ok, proposal} <- store_analysis(issue, analysis) do
          {:ok, proposal}
        end
      after
        Gate.checkin(lease)
      end
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def store_analysis(issue, analysis) do
    with {:ok, attrs} <- proposal_attrs(issue, analysis) do
      case Repo.get_by(Proposal,
             issue_id: attrs.issue_id,
             proposal_digest: attrs.proposal_digest
           ) do
        nil -> Operations.create_proposal(attrs)
        proposal -> {:ok, proposal}
      end
    end
  end

  defp ensure_open(%{state: "open"}), do: :ok
  defp ensure_open(_issue), do: {:error, :issue_closed}

  defp proposal_attrs(issue, analysis) do
    with {:ok, normalized} <- normalize_analysis(analysis) do
      digest_input =
        normalized
        |> Map.put(:source_digest, issue.content_digest)
        |> Jason.encode!()

      {:ok,
       normalized
       |> Map.merge(%{
         issue_id: issue.id,
         source_updated_at: issue.github_updated_at,
         source_digest: issue.content_digest,
         proposal_digest: digest(digest_input)
       })}
    end
  end

  defp normalize_analysis(analysis) when is_map(analysis) do
    normalized = %{
      plain_summary: value(analysis, :plain_summary),
      why_it_matters: value(analysis, :why_it_matters),
      scope: value(analysis, :scope),
      risk: value(analysis, :risk),
      readiness: value(analysis, :readiness),
      technical_evidence: value(analysis, :technical_evidence)
    }

    if Enum.all?(normalized, fn {_key, value} -> is_binary(value) and value != "" end) do
      {:ok, normalized}
    else
      {:error, :invalid_manager_output}
    end
  end

  defp normalize_analysis(_analysis), do: {:error, :invalid_manager_output}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
