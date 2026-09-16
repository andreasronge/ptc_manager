defmodule PtcManager.DeliveryEvidence.Records do
  @moduledoc false
  alias PtcManager.{DeliveryReport, DeliveryHistory, Repo, Reviews}
  alias PtcManager.DeliveryEvidence.Fields, as: F

  @limit 100
  @job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked done failed cancelled lost)
  @review_states ~w(queued preparing running paused completed cached failed cancelled not_run)
  @operation_states ~w(queued starting running cancelling recovery_pending completed failed cancelled lost)

  def build(job, selected_head, merged_at) do
    records = DeliveryReport.records(job, @limit + 1)

    for key <- [:rounds, :operations, :audits, :delivery_events],
        do: F.list!(records[key], @limit)

    job = Repo.preload(job, :approval)
    source = [F.source("jobs", job.id)]
    origin = Enum.find(records.delivery_events, &creation_event?/1)
    epoch = if origin, do: F.source("delivery_events", origin.id)
    coverage = if origin, do: "complete", else: "partial"
    reason = if origin, do: nil, else: "job_creation_not_captured"
    family_opts = [epoch: epoch, reason: reason]

    reviews =
      F.family(
        "computed",
        coverage,
        Enum.map(records.rounds, &review_round/1),
        refs(records.rounds, "review_rounds") ++ source,
        family_opts
      )

    operations =
      F.family(
        "computed",
        coverage,
        Enum.map(records.operations, &operation/1),
        refs(records.operations, "resource_operations") ++ source,
        family_opts
      )

    lifecycle = Enum.flat_map(records.delivery_events, &lifecycle/1)
    projected = Enum.flat_map(records.delivery_events, &DeliveryHistory.project/1)
    ready_events = Enum.filter(projected, &(DateTime.compare(&1.inserted_at, merged_at) != :gt))

    ready_at =
      if selected_head,
        do: DeliveryReport.ready_at(ready_events, %{remote_head_sha: selected_head})

    ready_ms = DeliveryReport.duration(job.approval && job.approval.approved_at, ready_at)

    %{
      "job_id" => job.id,
      "issue_id" => job.issue_id,
      "state" => F.enum(job.state, @job_states),
      "created_at" => F.timestamp(job.inserted_at),
      "heads" => %{
        "implementation" => F.sha(job.result_head_sha),
        "reviewed" => F.sha(job.reviewed_head_sha),
        "published" => records.publication && F.sha(records.publication.head_sha)
      },
      "validation" => validation(job),
      "stop" => stop(job),
      "reviews" => reviews,
      "managed_operations" => operations,
      "lifecycle" =>
        F.family(
          "computed",
          coverage,
          lifecycle,
          refs(records.delivery_events, "delivery_events") ++ source,
          family_opts
        ),
      "audits" =>
        F.family(
          "computed",
          coverage,
          Enum.map(records.audits, &audit/1),
          refs(records.audits, "audit_events") ++ source,
          family_opts
        ),
      "timings" =>
        F.family(
          "computed",
          if(ready_ms && DeliveryReport.duration(job.started_at, job.ended_at),
            do: "complete",
            else: "partial"
          ),
          %{
            "started_at" => F.timestamp(job.started_at),
            "ended_at" => F.timestamp(job.ended_at),
            "elapsed_ms" => DeliveryReport.duration(job.started_at, job.ended_at),
            "ready_at" => F.timestamp(ready_at),
            "time_to_ready_ms" => ready_ms
          },
          source ++ refs(records.delivery_events, "delivery_events") ++ approval_ref(job),
          head: selected_head,
          binding: "unavailable",
          reason: if(ready_ms, do: nil, else: "matching_readiness_not_measured")
        ),
      "source_epoch" => epoch
    }
  end

  defp creation_event?(event) do
    is_nil(event.before_state) and is_map(event.after_state["job"]) and
      is_nil(event.after_state["publication"])
  end

  defp approval_ref(%{approval_id: nil}), do: []
  defp approval_ref(job), do: [F.source("approvals", job.approval_id)]
  defp refs(rows, type), do: Enum.map(rows, &F.source(type, &1.id))

  defp validation(job) do
    status = F.enum(job.pre_publication_status, ~w(pending running passed failed))
    head = F.sha(job.pre_publication_verified_sha)

    F.family(
      "computed",
      cond do
        status && head && job.pre_publication_exit_status && job.pre_publication_duration_ms &&
            job.pre_publication_verified_at ->
          "complete"

        status || head ->
          "partial"

        true ->
          "unavailable"
      end,
      %{
        "state" => status,
        "exit_status" => F.integer(job.pre_publication_exit_status),
        "duration_ms" => F.integer(job.pre_publication_duration_ms),
        "verified_at" => F.timestamp(job.pre_publication_verified_at)
      },
      [F.source("jobs", job.id)],
      head: head,
      binding: "unavailable",
      reason: if(status && head, do: nil, else: "validation_not_recorded")
    )
  end

  defp stop(job) do
    report = job.stop_report || %{}
    code = F.enum(report["reason_code"], PtcManager.Operations.StopReport.reason_codes())

    data =
      if code,
        do: %{
          "reason_code" => code,
          "summary" => F.text(report["summary"], 1_000),
          "progress" => F.enum(report["progress"], ~w(none partial)),
          "reported_at" => F.timestamp(job.stop_reported_at)
        }

    F.family(
      "reported",
      if(data, do: "partial", else: "unavailable"),
      data,
      [F.source("jobs", job.id)],
      binding: "unavailable",
      reason: "bounded_stop_fields_only"
    )
  end

  defp review_round(round) do
    valid = Reviews.valid_result?(round.result)

    result =
      if valid,
        do: %{
          "summary" => F.text(round.result["summary"]),
          "findings" =>
            Enum.map(round.result["findings"], fn finding ->
              %{
                "severity" => finding["severity"],
                "description" => F.text(finding["description"])
              }
            end)
        }

    %{
      "id" => round.id,
      "number" => F.integer(round.number),
      "generation" => F.integer(round.generation),
      "state" => F.enum(round.state, @review_states),
      "head_sha" => F.sha(round.head_sha),
      "base_sha" => F.sha(round.base_sha),
      "requested_at" => F.timestamp(round.inserted_at),
      "result" =>
        F.family(
          "reported",
          if(valid, do: "partial", else: "unavailable"),
          result,
          [F.source("review_rounds", round.id)],
          head: round.head_sha,
          binding: "unavailable",
          reason:
            if(valid, do: "bounded_reported_assessment", else: "valid_assessment_not_recorded")
        ),
      "error_category" => if(round.error, do: "recorded_error")
    }
  end

  defp operation(operation) do
    %{
      "id" => operation.id,
      "state" => F.enum(operation.state, @operation_states),
      "label" =>
        F.family(
          "reported",
          "complete",
          F.text(operation.label, 128),
          [F.source("resource_operations", operation.id)],
          reason: "label_does_not_identify_command"
        ),
      "queued_at" => F.timestamp(operation.queued_at),
      "started_at" => F.timestamp(operation.started_at),
      "finished_at" => F.timestamp(operation.finished_at),
      "wait_duration_ms" => F.integer(operation.wait_duration_ms),
      "run_duration_ms" => F.integer(operation.run_duration_ms),
      "exit_status" => F.integer(operation.exit_status),
      "recovery_state" => F.enum(operation.state, ~w(recovery_pending lost)),
      "timeout" => nil,
      "error_category" => if(operation.last_error, do: "recorded_error")
    }
  end

  defp audit(audit) do
    %{
      "source" => F.source("audit_events", audit.id),
      "action" => F.text(audit.action, 240),
      "at" => F.timestamp(audit.inserted_at),
      "target_type" => F.enum(audit.target_type, ~w(job worktree_allocation pr_publication)),
      "target_id" => audit.target_id
    }
  end

  defp lifecycle(event) do
    Enum.map(DeliveryHistory.project(event), fn projected ->
      %{
        "source" => F.source("delivery_events", event.id),
        "action" => projected.action,
        "at" => F.timestamp(projected.inserted_at),
        "from" => F.text(projected.details["from"], 128),
        "to" => F.text(projected.details["to"], 128),
        "head_sha" => F.sha(projected.details["head_sha"])
      }
    end)
  end
end
