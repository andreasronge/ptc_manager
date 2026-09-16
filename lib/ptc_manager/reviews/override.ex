defmodule PtcManager.Reviews.Override do
  @moduledoc "An explicit maintainer approval, separate from an agent's review result."
  use Ecto.Schema
  import Ecto.Query
  alias PtcManager.{Repo, RepoTransaction, Reviews, Operations, ExecutionProfiles}
  alias PtcManager.Operations.Job

  schema "review_overrides" do
    belongs_to :job, Job
    belongs_to :round, PtcManager.Reviews.Round
    field :fencing_token, :integer
    field :generation, :integer
    field :head_sha, :string
    field :base_sha, :string
    field :diff_digest, :string
    field :actor, :string
    field :reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def list(job_id), do: Repo.all(from o in __MODULE__, where: o.job_id == ^job_id, order_by: o.id)

  def candidate(job) do
    # Manual takeover advances the decision generation without making a new review.
    # Its evidence remains selectable, but approve/4 requires a fresh decision at
    # the current job generation; no earlier approval is carried forward.
    round = List.last(Reviews.rounds(job.id))

    if is_map(job.execution_settings) and Reviews.active_job?(job) and
         job.review_state in ~w(paused manual) and
         is_nil(job.review_resume_expires_at) and is_nil(job.review_recovery_expires_at) and
         not is_nil(round) and round.fencing_token == job.fencing_token and
         round.state in ~w(completed failed cached not_run) and valid_evidence?(round) do
      round
    end
  end

  def current(%{reviewed_head_sha: head} = job) when is_binary(head),
    do:
      Repo.get_by(__MODULE__,
        job_id: job.id,
        generation: job.review_generation,
        fencing_token: job.fencing_token,
        head_sha: head
      )

  def current(_), do: nil

  def approved?(job, evidence) do
    Repo.exists?(
      from o in __MODULE__,
        where:
          o.job_id == ^job.id and o.generation == ^job.review_generation and
            o.fencing_token == ^job.fencing_token and o.head_sha == ^evidence.head_sha and
            o.base_sha == ^evidence.base_sha and o.diff_digest == ^evidence.diff_digest
    )
  end

  def approve(id, generation, attrs, actor) do
    outcome =
      RepoTransaction.immediate(fn ->
        job = Repo.get!(Job, id)
        round = candidate(job)

        unless not is_nil(round) and job.review_generation == generation and
                 attrs["round_id"] == to_string(round.id) and attrs["head_sha"] == round.head_sha,
               do: Repo.rollback(:review_decision_stale)

        reason = attrs["reason"]

        unless is_binary(reason) and String.trim(reason) != "" and String.length(reason) <= 2000,
          do: Repo.rollback(:override_reason_required)

        unless is_binary(actor) and String.trim(actor) != "", do: Repo.rollback(:invalid_actor)

        allocation = Repo.get_by(PtcManager.Operations.WorktreeAllocation, job_id: id)

        unless allocation && allocation.state != "removed",
          do: Repo.rollback(:retained_workspace_not_ready)

        now = DateTime.utc_now()
        reason = String.trim(reason)

        approval =
          Repo.insert!(%__MODULE__{
            job_id: id,
            round_id: round.id,
            generation: generation + 1,
            fencing_token: job.fencing_token,
            head_sha: round.head_sha,
            base_sha: round.base_sha,
            diff_digest: round.diff_digest,
            actor: actor,
            reason: reason
          })

        saved =
          job
          |> Job.changeset(%{
            state: "blocked",
            review_state: "resume_pending",
            review_resume_mode: "publication",
            review_generation: generation + 1,
            reviewed_head_sha: round.head_sha,
            review_continuation_instructions: nil,
            last_error: nil,
            stop_acknowledged_at:
              if(job.stop_reported_at, do: now, else: job.stop_acknowledged_at),
            stop_report_token: rotated_report_token(job)
          })
          |> Repo.update!()

        %{job_id: id, generation: saved.review_generation}
        |> PtcManager.Reviews.ResumeWorker.new()
        |> Oban.insert!()

        ExecutionProfiles.audit(actor, "review.overridden", id, %{
          override_id: approval.id,
          round_id: round.id,
          head_sha: round.head_sha,
          base_sha: round.base_sha,
          diff_digest: round.diff_digest,
          reason: reason
        })

        saved
      end)

    Operations.notify_changed(__MODULE__)
    outcome
  end

  defp valid_evidence?(round) do
    Enum.all?(
      [round.head_sha, round.base_sha],
      &(is_binary(&1) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, &1))
    ) and
      is_binary(round.diff_digest) and Regex.match?(~r/\A[a-f0-9]{64}\z/, round.diff_digest)
  end

  # Rotating the token makes the previous attempt's report unreachable by the
  # path both sides derive from the job, so the outcome report is removed here
  # rather than left in the output directory every managed agent can read.
  #
  # Only the protocol v2 file: v1 deliberately keeps its stop report after a
  # continuation, which `Reviews` covers, and changing that is a separate step.
  defp rotated_report_token(job) do
    PtcManager.Operations.OutcomeReport.discard(job)
    PtcManager.Operations.ReportFile.new_token()
  end
end
