defmodule PtcManager.DeliveryEvidence do
  @moduledoc "Versioned, read-only delivery evidence over a captured GitHub selection and one database snapshot."
  import Ecto.Query
  alias PtcManager.{Repo, DeliveryReport}
  alias PtcManager.Operations.{Repository, Job, PrPublication}
  alias PtcManager.DeliveryEvidence.{Fields, Selection, Records}
  alias Fields, as: F

  @schema_version 1
  @max_bytes 240_000
  @max_jobs 200
  @max_attempts 20

  @doc "Builds evidence without network/filesystem access. Requires :observed_at; :max_bytes may lower the 240,000-byte ceiling."
  def build(%Repository{} = repository, window, selection, opts \\ []) do
    limit = Keyword.get(opts, :max_bytes, @max_bytes)
    F.require!(is_integer(limit) and limit > 0 and limit <= @max_bytes, :invalid_byte_limit)
    captured = Selection.validate!(repository, window, selection, Keyword.get(opts, :observed_at))

    Repo.transaction(
      fn ->
        {pulls, _remaining} =
          Enum.map_reduce(captured["pull_requests"], @max_jobs, fn pull, remaining ->
            enriched = enrich(pull, repository, remaining)
            {enriched, remaining - length(enriched["attempts"]["data"])}
          end)

        direct =
          Enum.map(captured["direct_commits"], fn commit ->
            F.family(
              "observed",
              "complete",
              commit,
              [
                %{
                  "type" => "github_commit",
                  "id" => commit["sha"],
                  "repository_id" => repository.id
                }
              ],
              head: commit["sha"]
            )
          end)

        projection = %{
          "schema_version" => @schema_version,
          "repository" => %{
            "id" => repository.id,
            "full_name" => "#{repository.github_owner}/#{repository.github_name}"
          },
          "window" => captured["window"],
          "github_observed_at" => captured["observed_at"],
          "source_head_sha" => captured["source_head_sha"],
          "default_branch" => captured["default_branch"],
          "database_view" => "current_snapshot_not_historical_as_of",
          "change_count" => captured["change_count"],
          "pull_requests" =>
            F.family("computed", "complete", pulls, [F.source("repositories", repository.id)]),
          "direct_commits" =>
            F.family("observed", "complete", direct, [F.source("repositories", repository.id)]),
          "limits" => %{
            "encoded_bytes" => limit,
            "pull_requests" => 50,
            "direct_commits" => 50,
            "attempts_per_pull_request" => @max_attempts,
            "jobs" => @max_jobs,
            "rows_per_job_family" => 100
          }
        }

        F.require!(byte_size(Jason.encode!(projection)) <= limit, :encoded_byte_limit)
        projection
      end,
      mode: :deferred
    )
  catch
    {:delivery_evidence, reason} -> {:error, reason}
  end

  defp enrich(pull, repository, remaining) do
    ref = %{
      "type" => "github_pull_request",
      "id" => pull["number"],
      "repository_id" => repository.id
    }

    publication = publication(repository.id, pull["number"])
    merged_at = F.datetime(pull["merged_at"])
    jobs = attempts(publication, repository.id, merged_at)
    F.require!(length(jobs) <= remaining, :collection_limit)

    attempts =
      Enum.map(jobs, fn job ->
        Records.build(job, pull["head_sha"], merged_at)
        |> Map.put(
          "inclusion_reason",
          if(job.id == publication.job_id,
            do: "producing_job",
            else: "same_issue_created_before_merge"
          )
        )
      end)

    source = if publication, do: [F.source("pr_publications", publication.id), ref], else: [ref]
    coverage = if jobs == [], do: "unavailable", else: "complete"
    producer = Enum.find(attempts, &(&1["inclusion_reason"] == "producing_job"))
    metadata = Map.drop(pull, ~w(body body_coverage))

    missing =
      Enum.filter(
        ~w(head_sha author_login labels additions deletions changed_files commits),
        &is_nil(metadata[&1])
      )

    %{
      "number" => pull["number"],
      "github" =>
        F.family(
          "observed",
          if(missing == [], do: "complete", else: "partial"),
          Map.put(metadata, "missing_fields", missing),
          [ref],
          reason: if(missing != [], do: "optional_github_fields_not_captured")
        ),
      "publication" =>
        F.family(
          "computed",
          if(publication, do: "complete", else: "unavailable"),
          if(publication,
            do: %{
              "id" => publication.id,
              "producing_job_id" => publication.job_id,
              "source" => publication.source,
              "head_sha" => F.sha(publication.head_sha),
              "observed_pr_head_sha" => F.sha(publication.remote_head_sha)
            }
          ),
          source,
          reason: if(is_nil(publication), do: "no_matching_publication")
        ),
      "completion" =>
        F.family(
          "reported",
          if(pull["body"], do: "partial", else: "unavailable"),
          %{"sections" => pull["body"], "retention" => pull["body_coverage"]},
          [ref],
          binding: "unavailable",
          reason: "historical_pr_sections"
        ),
      "attempts" =>
        F.family("computed", coverage, attempts, source,
          reason: if(jobs == [], do: "no_managed_producing_job")
        ),
      "health" => health(attempts, producer, source)
    }
  end

  defp publication(repository_id, number) do
    rows =
      Repo.all(
        from p in PrPublication,
          left_join: j in Job,
          on: j.id == p.job_id,
          where:
            p.pr_number == ^number and
              ((p.repository_id == ^repository_id and
                  (is_nil(p.job_id) or j.repository_id == ^repository_id)) or
                 (is_nil(p.repository_id) and j.repository_id == ^repository_id)),
          order_by: p.id,
          limit: 2
      )

    F.require!(length(rows) <= 1, :ambiguous_publication)
    List.first(rows)
  end

  defp attempts(%{job_id: id}, repository_id, merged_at) when is_integer(id) do
    job = Repo.get_by(Job, id: id, repository_id: repository_id)

    if job && DateTime.compare(job.inserted_at, merged_at) != :gt do
      rows =
        Repo.all(
          from j in Job,
            where:
              j.repository_id == ^repository_id and
                j.issue_id == ^job.issue_id and j.inserted_at <= ^merged_at,
            order_by: [j.inserted_at, j.id],
            limit: ^(@max_attempts + 1)
        )

      F.list!(rows, @max_attempts)
    else
      []
    end
  end

  defp attempts(_, _, _), do: []

  defp health(attempts, producer, sources) do
    complete = attempts != [] and Enum.all?(attempts, &(&1["source_epoch"] != nil))
    rounds = Enum.flat_map(attempts, & &1["reviews"]["data"])
    operations = Enum.flat_map(attempts, & &1["managed_operations"]["data"])
    ready_ms = producer && producer["timings"]["data"]["time_to_ready_ms"]
    durations = Enum.map(operations, & &1["run_duration_ms"])
    duration_complete = complete and Enum.all?(durations, &is_integer/1)

    duration =
      if duration_complete, do: Enum.sum(durations), else: DeliveryReport.sum_known(durations)

    metric_coverage = %{
      "review_round_count" => if(complete, do: "complete", else: "unavailable"),
      "failed_managed_operation_count" => if(complete, do: "complete", else: "unavailable"),
      "time_to_ready_ms" => if(ready_ms, do: "complete", else: "unavailable"),
      "managed_run_duration_ms" =>
        cond do
          duration_complete -> "complete"
          is_integer(duration) -> "partial"
          true -> "unavailable"
        end
    }

    record_sources =
      Enum.flat_map(attempts, fn attempt ->
        Enum.flat_map(~w(reviews managed_operations timings), &attempt[&1]["source_ids"])
      end)

    F.family(
      "computed",
      if(Enum.all?(Map.values(metric_coverage), &(&1 == "complete")),
        do: "complete",
        else: "partial"
      ),
      %{
        "review_round_count" => if(complete, do: length(rounds)),
        "failed_managed_operation_count" =>
          if(complete, do: Enum.count(operations, &(&1["state"] == "failed"))),
        "time_to_ready_ms" => ready_ms,
        "managed_run_duration_ms" => duration,
        "metric_coverage" => metric_coverage,
        "duration_semantics" => "sum_of_measured_operations_not_elapsed"
      },
      sources ++ Enum.map(attempts, &F.source("jobs", &1["job_id"])) ++ record_sources,
      reason:
        if(!complete, do: "historical_coverage_unknown", else: "readiness_may_be_unavailable")
    )
  end
end
