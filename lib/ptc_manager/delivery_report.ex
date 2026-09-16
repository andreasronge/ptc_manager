defmodule PtcManager.DeliveryReport do
  @moduledoc "Read-only delivery evidence. Aggregated operation time is never called elapsed time."
  import Ecto.Query
  alias PtcManager.{Repo, Reviews}
  alias PtcManager.Operations.{Job, AuditEvent, ResourceOperation, PrPublication}

  def load(id) do
    {:ok, report} = Repo.transaction(fn -> load_snapshot(id) end, mode: :deferred)
    report
  end

  defp load_snapshot(id) do
    job =
      Repo.get!(Job, id) |> Repo.preload([:issue, :repository, :approval, :worktree_allocation])

    records = records(job)
    rounds = records.rounds
    operations = records.operations
    publication = records.publication

    audits =
      Enum.sort_by(
        records.audits ++
          Enum.flat_map(records.delivery_events, &PtcManager.DeliveryHistory.project/1),
        &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}
      )

    attempts =
      Repo.all(from j in Job, where: j.issue_id == ^job.issue_id, order_by: j.inserted_at)

    %{
      job: job,
      rounds: rounds,
      operations: operations,
      audits: audits,
      publication: publication,
      attempts: attempts,
      overrides: Reviews.Override.list(job.id),
      groups: operation_groups(operations),
      events: events(job, rounds, operations, audits, publication),
      models: Enum.sort_by(models(job, audits, rounds), &DateTime.to_unix(&1.at, :microsecond)),
      phases: phase_intervals(audits),
      ready_at: ready_at(audits, publication),
      ready_ms: duration(job.approval && job.approval.approved_at, ready_at(audits, publication)),
      elapsed_ms:
        duration(
          job.approval && job.approval.approved_at,
          publication && publication.published_at
        ),
      usage: usage(rounds),
      captured_at: DateTime.utc_now()
    }
  end

  @doc "Shared record queries. Call inside a read transaction; a limit bounds each collection."
  def records(job, row_limit \\ nil) do
    job = Repo.preload(job, :worktree_allocation)
    publication = Repo.get_by(PrPublication, job_id: job.id)
    rounds = read_rows(Reviews.rounds_query(job.id), row_limit)

    operations =
      read_rows(
        from(o in ResourceOperation, where: o.job_id == ^job.id, order_by: [o.queued_at, o.id]),
        row_limit
      )

    targets = [
      {"job", job},
      {"worktree_allocation", job.worktree_allocation},
      {"pr_publication", publication}
    ]

    predicate =
      Enum.reduce(targets, dynamic(false), fn
        {_type, nil}, query ->
          query

        {type, record}, query ->
          dynamic([a], ^query or (a.target_type == ^type and a.target_id == ^record.id))
      end)

    audits =
      read_rows(
        from(a in AuditEvent, where: ^predicate, order_by: [a.inserted_at, a.id]),
        row_limit
      )

    %{
      rounds: rounds,
      operations: operations,
      audits: audits,
      publication: publication,
      delivery_events: read_rows(PtcManager.DeliveryHistory.records_query(job.id), row_limit)
    }
  end

  defp read_rows(query, nil), do: Repo.all(query)
  defp read_rows(query, row_limit), do: Repo.all(limit(query, ^row_limit))

  def validation_status(job, publication) do
    cond do
      is_nil(publication) or is_nil(publication.remote_head_sha) ->
        "Current PR head not recorded"

      job.pre_publication_verified_sha != publication.remote_head_sha ->
        "Historical or missing validation — does not cover the current PR head"

      true ->
        human(job.pre_publication_status)
    end
  end

  @doc false
  def ready_at(audits, publication) do
    if publication do
      audits
      |> Enum.reverse()
      |> Enum.find(fn a ->
        a.action == "delivery.ready_entered" and
          a.details["head_sha"] == publication.remote_head_sha
      end)
      |> case do
        nil -> nil
        event -> event.inserted_at
      end
    end
  end

  def duration(%DateTime{} = start, %DateTime{} = finish) do
    if DateTime.compare(finish, start) == :lt,
      do: nil,
      else: DateTime.diff(finish, start, :millisecond)
  end

  def duration(_, _), do: nil

  def sum_known(values) do
    known = Enum.filter(values, &is_integer/1)
    if known == [], do: nil, else: Enum.sum(known)
  end

  defp operation_groups(operations) do
    operations
    |> Enum.group_by(& &1.label)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {label, rows} ->
      %{
        label: label,
        count: length(rows),
        failed: Enum.count(rows, &(&1.state == "failed")),
        run_ms: sum_known(Enum.map(rows, & &1.run_duration_ms)),
        wait_ms: sum_known(Enum.map(rows, & &1.wait_duration_ms)),
        measured: Enum.count(rows, &is_integer(&1.run_duration_ms)),
        peak:
          rows
          |> Enum.map(& &1.peak_memory_bytes)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end)
      }
    end)
  end

  defp usage(rounds) do
    measured = Enum.filter(rounds, &is_map(&1.usage))

    %{
      measured: length(measured),
      total: length(rounds),
      input: sum_known(Enum.map(measured, & &1.usage["input_tokens"])),
      cached: sum_known(Enum.map(measured, & &1.usage["cached_input_tokens"])),
      output: sum_known(Enum.map(measured, & &1.usage["output_tokens"]))
    }
  end

  defp models(job, audits, rounds) do
    initial = Enum.find(audits, &is_map(&1.details["execution_settings"]))

    initial_settings =
      if initial, do: initial.details["execution_settings"], else: job.execution_settings

    [
      %{
        at: job.inserted_at,
        role:
          if(initial,
            do: "Implementation approved",
            else: "Current implementation settings (initial history unavailable)"
          ),
        settings: initial_settings
      }
    ] ++
      Enum.flat_map(audits, fn a ->
        if is_map(a.details["settings"]),
          do: [
            %{at: a.inserted_at, role: "Continuation approved", settings: a.details["settings"]}
          ],
          else: []
      end) ++
      Enum.map(
        rounds,
        &%{
          at: &1.inserted_at,
          role: "Reviewer · attempt #{&1.number}",
          settings: &1.input["settings"]
        }
      )
  end

  def phase_intervals(audits) do
    audits
    |> Enum.filter(&(&1.action == "job.phase_changed"))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      %{
        phase: a.details["to"],
        start: a.inserted_at,
        finish: b.inserted_at,
        ms: duration(a.inserted_at, b.inserted_at)
      }
    end)
  end

  defp event(at, title, source, detail \\ nil),
    do: %{at: at, title: title, source: source, detail: detail}

  defp events(job, rounds, operations, audits, publication) do
    base = [
      event(job.issue.github_created_at, "Issue filed", "GitHub"),
      event(
        job.approval && job.approval.approved_at,
        "Implementation approved",
        "Approval record",
        job.approval && job.approval.actor
      ),
      event(
        publication && publication.published_at,
        "Pull request published",
        "Publication record"
      )
    ]

    audit_events =
      Enum.map(audits, fn a ->
        title =
          if a.action == "job.phase_changed",
            do: "#{human(a.details["from"])} → #{human(a.details["to"])}",
            else: human(a.action)

        event(
          a.inserted_at,
          title,
          "Audit · #{a.actor}",
          Map.take(
            a.details,
            ~w(reason instructions head_sha round state duration_ms worktree_created_duration_ms cache_state phase_durations)
          )
        )
      end)

    reviews =
      Enum.map(
        rounds,
        &event(
          &1.inserted_at,
          "Review attempt #{&1.number} requested (now #{&1.state})",
          "Review record",
          &1.error
        )
      )

    commands =
      Enum.map(
        operations,
        &event(
          &1.finished_at || &1.started_at || &1.queued_at,
          "#{human(&1.label)} command · #{&1.state}",
          "Operation ##{&1.id}",
          "Queue: #{milliseconds(&1.wait_duration_ms)} · run: #{milliseconds(&1.run_duration_ms)}"
        )
      )

    setup =
      case job.worktree_allocation do
        nil ->
          []

        w ->
          [
            event(
              w.workspace_setup_started_at,
              "Repository setup started",
              "Workspace report",
              "Worktree creation: #{milliseconds(w.worktree_created_duration_ms)}"
            ),
            event(
              w.workspace_setup_ended_at,
              "Repository setup #{w.workspace_setup_state}",
              "Workspace report",
              "Duration: #{milliseconds(w.workspace_setup_duration_ms)}"
            )
          ]
      end

    (base ++ audit_events ++ reviews ++ commands ++ setup)
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
  end

  def human(nil), do: "Not recorded"
  def human(text), do: text |> String.replace(["_", "."], " ") |> String.capitalize()
  def milliseconds(nil), do: "Not recorded"
  def milliseconds(n) when n < 1000, do: "#{n}ms"
  def milliseconds(n) when n < 60_000, do: "#{Float.round(n / 1000, 1)}s"
  def milliseconds(n), do: "#{div(n, 60_000)}m #{div(rem(n, 60_000), 1000)}s"
  def bytes(nil), do: "Not recorded"
  def bytes(n), do: "#{Float.round(n / 1_048_576, 1)} MiB"
  def timestamp(nil), do: "Not recorded"
  def timestamp(dt), do: Calendar.strftime(dt, "%d %b %Y %H:%M:%S UTC")
end
