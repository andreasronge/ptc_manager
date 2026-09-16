defmodule PtcManager.DailyDigests do
  @moduledoc "Schedules, stores, and presents private daily repository updates."

  import Ecto.Query

  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.Operations.{AgentAction, AuditEvent, Repository}
  alias PtcManager.Repo

  def enabled? do
    Application.get_env(:ptc_manager, :daily_digest_enabled, false) and
      PtcManager.MaintainerActions.enabled?()
  end

  def list_digests do
    DailyDigest
    |> order_by([digest], desc: digest.digest_date, desc: digest.id)
    |> preload([:repository, :agent_action])
    |> Repo.all()
  end

  def get_digest(id) when is_integer(id) do
    DailyDigest
    |> preload([:repository, :agent_action])
    |> Repo.get(id)
  end

  def get_digest(_id), do: nil

  def enqueue_due(now \\ DateTime.utc_now()) do
    time_zone = Application.get_env(:ptc_manager, :daily_digest_time_zone, "Europe/Stockholm")
    hour = Application.get_env(:ptc_manager, :daily_digest_hour, 2)

    with true <- enabled?(),
         true <- is_integer(hour) and hour in 0..23,
         {:ok, local_now} <- DateTime.shift_zone(now, time_zone, Tz.TimeZoneDatabase),
         true <- local_now.hour >= hour,
         {:ok, window} <- previous_local_day_window(local_now, time_zone) do
      Repository
      |> where([repository], repository.enabled == true)
      |> order_by([repository], asc: repository.id)
      |> Repo.all()
      |> Enum.reduce_while({:ok, []}, fn repository, {:ok, digests} ->
        case enqueue(repository, window) do
          {:ok, digest} -> {:cont, {:ok, [digest | digests]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, digests} -> {:ok, Enum.reverse(digests)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:ok, []}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_daily_digest_schedule}
    end
  end

  def enqueue(%Repository{} = repository, window, opts \\ []) when is_map(window) do
    actor = Keyword.get(opts, :actor, "scheduler")

    result =
      Repo.transaction(
        fn ->
          case Repo.get_by(DailyDigest,
                 repository_id: repository.id,
                 digest_date: window.date
               ) do
            %DailyDigest{} = existing ->
              existing

            nil ->
              digest =
                %DailyDigest{}
                |> DailyDigest.changeset(%{
                  repository_id: repository.id,
                  digest_date: window.date,
                  window_started_at: window.started_at,
                  window_ended_at: window.ended_at,
                  time_zone: window.time_zone
                })
                |> Repo.insert!()

              {:ok, action_attrs} =
                Catalog.build("daily_digest", %{repository: repository, digest: digest})

              {:ok, action_attrs} =
                PtcManager.Automations.snapshot_attrs(repository, "daily_digest", action_attrs)

              now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

              action =
                %AgentAction{}
                |> AgentAction.changeset(
                  Map.merge(action_attrs, %{
                    action_key: "daily_digest",
                    actor: actor,
                    state: "queued",
                    attempt_count: 0,
                    requested_at: now
                  })
                )
                |> Repo.insert!()

              %AuditEvent{}
              |> AuditEvent.changeset(%{
                actor: actor,
                action: "agent_action.queued",
                target_type: "agent_action",
                target_id: action.id,
                details: %{
                  "action_key" => action.action_key,
                  "prompt_version" => action.prompt_version,
                  "target_type" => action.target_type,
                  "target_id" => action.target_id,
                  "target_label" => action.target_label,
                  "digest_date" => Date.to_iso8601(digest.digest_date)
                }
              })
              |> Repo.insert!()

              digest
              |> DailyDigest.changeset(%{agent_action_id: action.id})
              |> Repo.update!()
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, digest} ->
        PtcManager.Operations.notify_changed(:daily_digest)
        {:ok, Repo.preload(digest, [:repository, :agent_action], force: true)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [Ecto.InvalidChangesetError, Exqlite.Error] -> {:error, error}
  end

  def previous_day_window(now, time_zone) when is_binary(time_zone) do
    with {:ok, local_now} <- DateTime.shift_zone(now, time_zone, Tz.TimeZoneDatabase) do
      previous_local_day_window(local_now, time_zone)
    end
  end

  def publish(%AgentAction{action_key: "daily_digest", target_id: digest_id} = action, result)
      when is_map(result) do
    with %DailyDigest{
           repository_id: repository_id,
           agent_action_id: agent_action_id,
           published_at: nil
         } = digest <-
           Repo.get(DailyDigest, digest_id),
         true <- repository_id == action.repository_id and agent_action_id == action.id,
         :ok <- validate_result_window(digest, result),
         {:ok, updated} <-
           digest
           |> DailyDigest.changeset(%{
             title: result["title"],
             summary: result["summary"],
             markdown: result["markdown"],
             source_head_sha: result["source_head_sha"],
             change_count: result["change_count"],
             pull_request_numbers: %{"numbers" => result["pull_request_numbers"]},
             published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
           })
           |> Repo.update() do
      PtcManager.Operations.notify_changed(:daily_digest)
      {:ok, updated}
    else
      nil -> {:error, :daily_digest_not_found}
      false -> {:error, :daily_digest_action_mismatch}
      %DailyDigest{} -> {:error, :daily_digest_already_published}
      {:error, reason} -> {:error, reason}
    end
  end

  def publish(_action, _result), do: {:error, :invalid_daily_digest}

  def published?(%DailyDigest{published_at: %DateTime{}, markdown: markdown})
      when is_binary(markdown),
      do: true

  def published?(_digest), do: false

  def status(%DailyDigest{} = digest) do
    cond do
      published?(digest) ->
        "published"

      match?(
        %AgentAction{state: state} when state in ["queued", "running", "sync_pending"],
        digest.agent_action
      ) ->
        digest.agent_action.state

      match?(
        %AgentAction{state: state} when state in ["failed", "cancelled"],
        digest.agent_action
      ) ->
        digest.agent_action.state

      true ->
        "pending"
    end
  end

  defp previous_local_day_window(local_now, time_zone) do
    date = local_now |> DateTime.to_date() |> Date.add(-1)

    with {:ok, local_start} <- local_day_boundary(date, time_zone),
         {:ok, local_end} <- local_day_boundary(Date.add(date, 1), time_zone) do
      {:ok,
       %{
         date: date,
         time_zone: time_zone,
         started_at: DateTime.shift_zone!(local_start, "Etc/UTC"),
         ended_at: DateTime.shift_zone!(local_end, "Etc/UTC")
       }}
    else
      _invalid -> {:error, :invalid_daily_digest_window}
    end
  end

  defp local_day_boundary(date, time_zone) do
    case DateTime.new(date, ~T[00:00:00], time_zone, Tz.TimeZoneDatabase) do
      {:ok, boundary} -> {:ok, boundary}
      {:ambiguous, first_boundary, _second_boundary} -> {:ok, first_boundary}
      {:gap, _before_gap, first_boundary} -> {:ok, first_boundary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_result_window(digest, result) do
    expected_start = DateTime.to_iso8601(digest.window_started_at)
    expected_end = DateTime.to_iso8601(digest.window_ended_at)

    if result["window_started_at"] == expected_start and
         result["window_ended_at"] == expected_end,
       do: :ok,
       else: {:error, :daily_digest_window_mismatch}
  end
end
