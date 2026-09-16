defmodule PtcManager.DeliveryHistory do
  @moduledoc "Projects atomic database snapshots through the same lane rules as Delivery."
  import Ecto.Query
  alias PtcManager.{Repo, DeliveryEvent}
  alias PtcManager.Operations.{AuditEvent, Job, PrPublication, DeliveryLane}

  @job_fields ~w(state review_state review_resume_mode review_resume_expires_at stop_reported_at stop_acknowledged_at last_error)a
  @pub_fields ~w(state pr_state draft checks_state mergeability remote_head_sha)a

  def events(job_id) do
    Repo.all(records_query(job_id))
    |> Enum.flat_map(&project/1)
  end

  @doc false
  def records_query(job_id),
    do: from(e in DeliveryEvent, where: e.job_id == ^job_id, order_by: [e.inserted_at, e.id])

  def project(event) do
    before = context(event.before_state)
    after_state = context(event.after_state)
    from = phase(before)
    to = phase(after_state)

    changed =
      if from != to,
        do: [audit(event, "job.phase_changed", %{"from" => from, "to" => to})],
        else: []

    was_ready = ready?(before)
    now_ready = ready?(after_state)
    head = after_state.publication && after_state.publication.remote_head_sha
    old_head = before.publication && before.publication.remote_head_sha

    if was_ready != now_ready or (now_ready and head != old_head) do
      changed ++
        [
          audit(
            event,
            if(now_ready, do: "delivery.ready_entered", else: "delivery.ready_left"),
            %{"head_sha" => head}
          )
        ]
    else
      changed
    end
  end

  defp audit(event, action, details),
    do: %AuditEvent{
      id: event.id,
      actor: "coordinator",
      action: action,
      target_type: "job",
      target_id: event.job_id,
      details: details,
      inserted_at: event.inserted_at
    }

  defp context(nil), do: %{active_job: nil, publication: nil}

  defp context(snapshot) do
    job = snapshot["job"]
    pub = snapshot["publication"]

    %{
      active_job: if(job, do: struct(Job, fields(job, @job_fields))),
      publication: if(pub, do: struct(PrPublication, fields(pub, @pub_fields)))
    }
  end

  defp fields(map, keys) do
    Enum.map(keys, fn key ->
      value = map[Atom.to_string(key)]

      value =
        cond do
          key == :draft ->
            value in [true, 1]

          key in [:review_resume_expires_at, :stop_reported_at, :stop_acknowledged_at] and
              is_binary(value) ->
            case DateTime.from_iso8601(value) do
              {:ok, dt, _} -> dt
              _ -> nil
            end

          true ->
            value
        end

      {key, value}
    end)
  end

  defp ready?(%{active_job: nil}), do: false

  defp ready?(%{active_job: %{state: state}}) when state in ~w(done failed cancelled lost),
    do: false

  defp ready?(%{publication: nil}), do: false
  defp ready?(context), do: DeliveryLane.lane_for(context) == :ready
  defp phase(%{active_job: nil}), do: nil

  defp phase(%{active_job: job} = context) do
    cond do
      ready?(context) ->
        "ready_to_merge"

      job.state in ~w(done cancelled failed lost publish_blocked) ->
        job.state

      job.state == "queued" ->
        "implementation_queue"

      job.review_state == "resume_pending" and is_nil(job.review_resume_expires_at) ->
        "continuation_queue"

      job.review_state in ~w(paused manual) ->
        "maintainer_decision"

      job.review_state == "running" ->
        "review"

      job.state == "starting" ->
        "workspace_and_startup"

      job.state == "reconciling" ->
        "reconciliation"

      true ->
        job.state
    end
  end
end
