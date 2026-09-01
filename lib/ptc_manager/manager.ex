defmodule PtcManager.Manager do
  @moduledoc "Stores normalized private issue-analysis proposals."

  alias PtcManager.{Operations, Repo}
  alias PtcManager.Operations.Proposal

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
