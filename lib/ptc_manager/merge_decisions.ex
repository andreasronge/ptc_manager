defmodule PtcManager.MergeDecisions do
  @moduledoc "Stores private PR analyses and exact-version human merge approvals."

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AuditEvent, MergeApproval, PrAnalysis, PrPublication}
  alias PtcManager.Publications
  alias PtcManager.Repo

  @snapshot_keys ~w(base_repository base_ref base_sha head_repository head_ref head_sha pr_number draft)

  def snapshot(result) when is_map(result) do
    Map.new(@snapshot_keys, fn key -> {key, Map.get(result, String.to_existing_atom(key))} end)
  end

  def store_analysis(%AgentAction{} = action, result, status)
      when is_map(result) and is_map(status) do
    publication =
      PrPublication
      |> Repo.get!(action.target_id)
      |> Repo.preload([:repository, job: :repository])

    with :ok <- valid_analysis_target(action, publication, status),
         attrs <- analysis_attrs(action, publication, result, status) do
      outcome =
        Repo.transaction(fn ->
          case Repo.get_by(PrAnalysis, agent_action_id: action.id) do
            nil ->
              analysis = %PrAnalysis{} |> PrAnalysis.changeset(attrs) |> Repo.insert!()

              %AuditEvent{}
              |> AuditEvent.changeset(%{
                actor: "coordinator",
                action: "pr_analysis.created",
                target_type: "pr_analysis",
                target_id: analysis.id,
                details: %{
                  "publication_id" => publication.id,
                  "outcome" => analysis.outcome,
                  "head_sha" => analysis.head_sha,
                  "reviewed_base_sha" => analysis.reviewed_base_sha,
                  "diff_digest" => analysis.diff_digest
                }
              })
              |> Repo.insert!()

              analysis

            analysis ->
              analysis
          end
        end)

      case outcome do
        {:ok, analysis} ->
          Operations.notify_changed(__MODULE__)
          {:ok, analysis}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def approve(publication_id, actor, opts \\ [])
      when is_integer(publication_id) and is_binary(actor) do
    client =
      Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :pull_request_client))

    publication =
      PrPublication
      |> Repo.get(publication_id)
      |> case do
        nil -> nil
        record -> Repo.preload(record, [:repository, job: :repository])
      end

    with %PrPublication{} <- publication,
         %PrAnalysis{} = analysis <- latest_analysis(publication.id),
         :ok <- ensure_merge_ready(analysis),
         {:ok, status} <- normalize_status_result(client.status(publication)),
         {:ok, _publication} <- Publications.record_remote_status(publication.id, status),
         :ok <- valid_approval_target(publication, analysis, status),
         {:ok, approval} <- insert_approval(publication, analysis, actor) do
      {:ok, approval}
    else
      nil -> {:error, :merge_analysis_missing}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp latest_analysis(publication_id) do
    PrAnalysis
    |> where([analysis], analysis.publication_id == ^publication_id)
    |> order_by([analysis], desc: analysis.analyzed_at, desc: analysis.id)
    |> limit(1)
    |> Repo.one()
  end

  defp valid_analysis_target(action, publication, status) do
    cond do
      action.action_key != "prepare_merge_decision" ->
        {:error, :wrong_agent_action}

      not publication_open?(publication) ->
        {:error, :pull_request_not_open}

      status.state != "open" or status.draft ->
        {:error, :pull_request_not_ready_for_analysis}

      action.target_snapshot != snapshot(status) ->
        {:error, :pull_request_changed_during_analysis}

      status.head_sha != publication.remote_head_sha ->
        {:error, :pull_request_head_changed}

      not intended_base?(status, publication_repository(publication)) ->
        {:error, :pull_request_base_changed}

      true ->
        :ok
    end
  end

  defp valid_approval_target(publication, analysis, status) do
    publication =
      Repo.get!(PrPublication, publication.id)
      |> Repo.preload([:repository, job: :repository])

    cond do
      not publication_open?(publication) ->
        {:error, :pull_request_not_open}

      status.state != "open" ->
        {:error, :pull_request_not_open}

      status.draft ->
        {:error, :pull_request_is_draft}

      status.head_sha != analysis.head_sha or status.head_sha != publication.remote_head_sha ->
        {:error, :merge_analysis_stale}

      status.base_sha != analysis.reviewed_base_sha ->
        {:error, :merge_analysis_stale}

      status.base_ref != analysis.base_ref or
          String.downcase(status.base_repository) != String.downcase(analysis.base_repository) ->
        {:error, :merge_analysis_stale}

      publication.diff_digest != analysis.diff_digest ->
        {:error, :merge_analysis_stale}

      not intended_base?(status, publication_repository(publication)) ->
        {:error, :pull_request_base_changed}

      true ->
        :ok
    end
  end

  defp analysis_attrs(action, publication, result, status) do
    %{
      publication_id: publication.id,
      agent_action_id: action.id,
      outcome: result["outcome"],
      plain_summary: result["private_summary"],
      why_it_matters: result["why_it_matters"],
      scope: result["scope"],
      risk: result["risk"],
      technical_evidence: result["technical_evidence"],
      base_repository: status.base_repository,
      base_ref: status.base_ref,
      reviewed_base_sha: status.base_sha,
      head_repository: status.head_repository,
      head_ref: status.head_ref,
      head_sha: status.head_sha,
      diff_digest: publication.diff_digest,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp ensure_merge_ready(%PrAnalysis{outcome: "merge-ready"}), do: :ok
  defp ensure_merge_ready(%PrAnalysis{}), do: {:error, :merge_not_ready}

  defp publication_open?(%PrPublication{state: "published", pr_state: "open"} = publication) do
    PrPublication.external?(publication) or match?(%{state: "pr_open"}, publication.job)
  end

  defp publication_open?(_publication), do: false

  defp publication_repository(%PrPublication{repository: %{} = repository}), do: repository

  defp publication_repository(%PrPublication{job: %{repository: %{} = repository}}),
    do: repository

  defp normalize_status_result({:ok, status}), do: {:ok, status}

  defp normalize_status_result({:retry, reason}),
    do: {:error, {:github_status_unavailable, reason}}

  defp normalize_status_result({:blocked, reason}),
    do: {:error, {:github_status_unavailable, reason}}

  defp normalize_status_result(other), do: {:error, {:unexpected_status_result, other}}

  defp insert_approval(publication, analysis, actor) do
    attrs = %{
      publication_id: publication.id,
      pr_analysis_id: analysis.id,
      decision: "approve",
      actor: actor,
      base_repository: analysis.base_repository,
      base_ref: analysis.base_ref,
      reviewed_base_sha: analysis.reviewed_base_sha,
      head_sha: analysis.head_sha,
      diff_digest: analysis.diff_digest,
      approved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    outcome =
      Repo.transaction(fn ->
        case Repo.get_by(MergeApproval, pr_analysis_id: analysis.id) do
          nil ->
            case %MergeApproval{}
                 |> MergeApproval.changeset(attrs)
                 |> Repo.insert(
                   on_conflict: :nothing,
                   conflict_target: [:pr_analysis_id]
                 ) do
              {:ok, %{id: nil}} ->
                Repo.get_by!(MergeApproval, pr_analysis_id: analysis.id)

              {:ok, approval} ->
                %AuditEvent{}
                |> AuditEvent.changeset(%{
                  actor: actor,
                  action: "merge_approval.approved",
                  target_type: "merge_approval",
                  target_id: approval.id,
                  details: %{
                    "publication_id" => publication.id,
                    "pr_analysis_id" => analysis.id,
                    "head_sha" => approval.head_sha,
                    "reviewed_base_sha" => approval.reviewed_base_sha,
                    "diff_digest" => approval.diff_digest
                  }
                })
                |> Repo.insert!()

                approval

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          approval ->
            approval
        end
      end)

    case outcome do
      {:ok, approval} ->
        Operations.notify_changed(__MODULE__)
        {:ok, approval}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp intended_base?(status, repository) do
    status.base_ref == repository.default_branch and
      String.downcase(status.base_repository) ==
        String.downcase("#{repository.github_owner}/#{repository.github_name}")
  end
end
