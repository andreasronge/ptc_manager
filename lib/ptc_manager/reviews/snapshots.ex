defmodule PtcManager.Reviews.Snapshots do
  @moduledoc "Persists snapshot ownership before cloning and retries cleanup after interrupted reviews."
  import Ecto.Query
  alias PtcManager.{Repo, RepoTransaction, Reviews}
  alias PtcManager.Operations.Job
  alias PtcManager.Reviews.Round
  alias PtcManager.Repository.SourceSnapshot

  def prepare(round, repository) do
    with {:ok, ownership} <- SourceSnapshot.review_identity(repository, round.id, round.head_sha),
         {:ok, job} <-
           RepoTransaction.immediate(fn ->
             current = Repo.get!(Round, round.id)
             job = Repo.get!(Job, round.job_id)

             unless current.state == "running" and Reviews.active_job?(job) and
                      job.review_generation == round.generation and
                      job.fencing_token == round.fencing_token and
                      DateTime.compare(current.expires_at, DateTime.utc_now()) == :gt,
                    do: Repo.rollback(:stale_review)

             current
             |> Round.changeset(%{input: Map.put(current.input, "source_snapshot", ownership)})
             |> Repo.update!()

             job
           end) do
      SourceSnapshot.prepare_review(
        repository,
        round.id,
        "refs/heads/#{job.branch_name}",
        round.head_sha
      )
    end
  end

  def cleanup(id, source \\ SourceSnapshot) do
    round = Repo.get!(Round, id)

    case round.input["source_snapshot"] do
      ownership when is_map(ownership) ->
        result =
          try do
            source.release_review_owned(id, ownership)
          rescue
            error -> {:error, {:snapshot_cleanup_failed, error.__struct__}}
          end

        case RepoTransaction.immediate(fn ->
               current = Repo.get!(Round, id)

               if current.input["source_snapshot"] == ownership do
                 input =
                   case result do
                     :ok ->
                       Map.drop(current.input, ["source_snapshot", "snapshot_cleanup_error"])

                     {:error, reason} ->
                       Map.put(
                         current.input,
                         "snapshot_cleanup_error",
                         Reviews.failure_message(reason)
                       )
                   end

                 current
                 |> Round.changeset(%{input: input})
                 |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
                 |> Repo.update!()
               end
             end) do
          {:ok, _} -> result
          error -> error
        end

      _ ->
        :ok
    end
  end

  def sweep do
    Repo.all(
      from r in Round,
        where:
          r.state in ~w(completed cached failed not_run) and
            fragment("json_extract(?, '$.source_snapshot') IS NOT NULL", r.input),
        order_by: r.updated_at,
        limit: 20
    )
    |> Enum.each(fn round ->
      %{round_id: round.id} |> PtcManager.Reviews.SnapshotCleanupWorker.new() |> Oban.insert()
    end)

    :ok
  end
end
